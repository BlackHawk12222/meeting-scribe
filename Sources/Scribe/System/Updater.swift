// Updater.swift
// "Check for Updates…": in-app updates that fetch ONLY what changed.
//
// Two kinds of parts, updated separately ("dependency mapping"):
//  1. The app itself (Scribe.app, ~15 MB zipped). From the newest GitHub Release, Scribe
//     downloads just Scribe.zip — never the .dmg, and never the models.
//  2. The models (~490 MB). They live outside the app. Each release also carries
//     components.json (the model manifest). Scribe compares it with what's installed and
//     shows which models (if any) would change. Usually: none, so an update is ~15 MB.
//     After the new app starts, ModelStore downloads only files whose hash changed.
//
// Install: unzip → check the new app's code signature and version → a tiny shell script
// waits for Scribe to quit, swaps the app in place, and reopens it.
//
// 0.5: automatic — checks at launch and every 6 h, downloads + verifies (SHA-256, code signature,
// version) in the background, then shows "Update ready — Restart" in the menu bar. It installs
// when you press Restart or the next time Scribe quits; it never restarts by itself, so it can
// never interrupt a recording or a dictation.
//
// 0.7 hardening (an update kept re-offering "Restart" on a real Mac before it finally landed):
//  • App Translocation: an app opened straight from Downloads/a disk image runs from a random
//    read-only "/AppTranslocation/" mount, so swapping that path can never work. Scribe resolves
//    the real path (SecTranslocateCreateOriginalPathForURL, looked up at run time) and swaps that;
//    if there's no writable real path it says "Move Scribe to Applications to update" instead.
//  • The swap script logs every step to ~/Library/Logs/Scribe/update.log. If a move fails it puts
//    the old app back and reopens it with --update-failed, which shows "Update couldn't install —
//    see log" once instead of offering Restart forever.
//  • Restart says why when it can't run now (recording/dictating), and can be pressed again.
//  • At launch: a staged update that is not newer than this app is deleted, and after a real
//    update a one-time "Updated to X" note appears.

import AppKit
import Foundation
import Darwin

@MainActor
final class Updater: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate(String)
        case available(Release)
        case downloading(Double?)
        case installing
        /// Downloaded, checked and unpacked: "Update ready — Restart". Installs on restart or quit.
        case ready(Release)
        /// Downloaded, but this copy of Scribe can't replace itself where it runs from (translocated
        /// or a read-only folder): "Move Scribe to Applications to update".
        case needsMove(Release)
        case failed(String)
    }

    struct Release: Equatable {
        var version: String
        var tag: String
        var notes: String
        var zipURL: URL
        var zipBytes: Int64
        var zipSHA256: String?          // from Scribe.zip.sha256 (or GitHub's asset digest)
        var modelChanges: [String]      // human-readable lines ("Speech model · English — 12 MB")
    }

    @Published private(set) var phase: Phase = .idle
    /// A one-line note for the menu bar and Settings ("Updated to 0.7.2", "Update couldn't install —
    /// see log", "Finish the recording first…"). Cleared with dismissNotice().
    @Published var notice: String?
    func dismissNotice() { notice = nil }

    nonisolated static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Scribe/update.log")
    }
    nonisolated static var updateFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scribe/Update", isDirectory: true)
    }
    private static let pendingKey = "pendingUpdateVersion"
    /// A version whose install failed: the automatic check won't re-download it by itself
    /// (Check for Updates… still can), so "Restart" isn't offered over and over.
    private static let failedVersionKey = "failedUpdateVersion"
    private static let failedMarker = "INSTALL_FAILED"

    /// Where to ask "what's the newest release?" (GitHub's API). 0.5: this repo's own releases
    /// (BlackHawk12222/meeting-scribe is public). Info.plist key ScribeReleasesURL.
    var feedURL: URL {
        if let s = Bundle.main.object(forInfoDictionaryKey: "ScribeReleasesURL") as? String, let u = URL(string: s) { return u }
        return URL(string: "https://api.github.com/repos/BlackHawk12222/meeting-scribe/releases/latest")!
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Settings › General › "Update automatically" (default on): check at launch and every 6 h,
    /// download + verify in the background, then offer Restart. Off = check by hand only.
    @Published var autoCheck: Bool = UserDefaults.standard.object(forKey: "autoUpdateCheck") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoCheck, forKey: "autoUpdateCheck")
            if autoCheck { startAutomatic() } else { timer?.invalidate(); timer = nil }
        }
    }
    static let interval: TimeInterval = 6 * 3600
    private var timer: Timer?
    /// The verified new Scribe.app waiting to be swapped in.
    private var stagedApp: URL?
    /// Asked by the restart button: is it safe right now (no recording / dictation)?
    var isBusy: () -> Bool = { false }

    /// At launch: check now, then every 6 hours.
    func startAutomatic() {
        guard autoCheck else { return }
        check(userInitiated: false)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check(userInitiated: false) }
        }
    }

    /// Kept for older callers: same as startAutomatic().
    func checkInBackgroundIfDue() { startAutomatic() }

    func check(userInitiated: Bool) {
        switch phase {
        case .downloading, .installing, .ready, .needsMove: return
        default: break
        }
        phase = .checking
        Task {
            do {
                let r = try await fetchLatest()
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
                if Self.isNewer(r.version, than: Self.currentVersion) {
                    phase = .available(r)
                    let failedBefore = UserDefaults.standard.string(forKey: Self.failedVersionKey) == r.version
                    if autoCheck && !userInitiated && !failedBefore { download(r, thenRestart: false) }
                } else {
                    phase = .upToDate(Self.currentVersion)
                }
            } catch {
                phase = userInitiated ? .failed(error.localizedDescription) : .idle
            }
        }
    }

    private func fetchLatest() async throws -> Release {
        var req = URLRequest(url: feedURL)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Scribe/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 {
            throw UpdateError.message("No releases found yet at the update feed (404).")
        }
        guard code == 200 else { throw UpdateError.message("Update server answered \(code).") }
        struct GHAsset: Decodable { var name: String; var browser_download_url: URL; var size: Int64; var digest: String? }
        struct GHRelease: Decodable { var tag_name: String; var body: String?; var assets: [GHAsset] }
        let gh = try JSONDecoder().decode(GHRelease.self, from: data)
        guard let zip = gh.assets.first(where: { $0.name == "Scribe.zip" }) else {
            throw UpdateError.message("The newest release has no Scribe.zip.")
        }
        // Expected hash: the release's Scribe.zip.sha256 file, else GitHub's own asset digest.
        var sha: String?
        if let f = gh.assets.first(where: { $0.name == "Scribe.zip.sha256" }),
           let (d, _) = try? await URLSession.shared.data(from: f.browser_download_url),
           let line = String(data: d, encoding: .utf8) {
            sha = line.split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map { String($0).lowercased() }
        }
        if sha == nil, let dg = zip.digest, dg.hasPrefix("sha256:") { sha = String(dg.dropFirst(7)).lowercased() }
        var changes: [String] = []
        if let comp = gh.assets.first(where: { $0.name == "components.json" }),
           let fetched = try? await URLSession.shared.data(from: comp.browser_download_url),
           let manifest = try? JSONDecoder().decode(ModelManifest.self, from: fetched.0) {
            changes = ModelStore.shared.changes(in: manifest).map { "\($0.0.title) — \(ModelStore.mb($0.1))" }
        }
        let version = gh.tag_name.hasPrefix("v") ? String(gh.tag_name.dropFirst()) : gh.tag_name
        return Release(version: version, tag: gh.tag_name, notes: gh.body ?? "", zipURL: zip.browser_download_url,
                       zipBytes: zip.size, zipSHA256: sha, modelChanges: changes)
    }

    /// "0.3.12" > "0.3.9" (number by number, not alphabetically).
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Settings button: download (if needed) and restart now.
    func install(_ r: Release) { download(r, thenRestart: true) }

    /// Download Scribe.zip only (never the models), check SHA-256 + code signature + version,
    /// unpack it next to the app's support folder and mark it ready.
    func download(_ r: Release, thenRestart: Bool) {
        if case .ready = phase { if thenRestart { restartNow() }; return }
        phase = .downloading(nil)
        Task {
            do {
                let (tmpZip, resp) = try await URLSession.shared.download(from: r.zipURL)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.message("Download failed.") }
                phase = .installing
                if let want = r.zipSHA256 {
                    let got = try ModelStore.fileHash(tmpZip, size: 0, git: false)
                    guard got == want else { throw UpdateError.message("The download didn't match its SHA-256 checksum.") }
                }
                let work = Self.updateFolder
                try? FileManager.default.removeItem(at: work)
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                try Self.run("/usr/bin/ditto", ["-x", "-k", tmpZip.path, work.path])
                let newApp = work.appendingPathComponent("Scribe.app")
                guard FileManager.default.fileExists(atPath: newApp.path) else { throw UpdateError.message("The zip had no Scribe.app.") }
                try Self.run("/usr/bin/codesign", ["--verify", "--deep", newApp.path])
                let plist = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist"))
                let newVersion = plist?["CFBundleShortVersionString"] as? String ?? "?"
                guard newVersion == r.version else { throw UpdateError.message("Version mismatch (\(newVersion) vs \(r.version)).") }
                stagedApp = newApp
                if Self.installTarget(for: Bundle.main.bundleURL) == nil {
                    phase = .needsMove(r)
                    Self.log("staged \(r.version), but \(Bundle.main.bundleURL.path) can't be replaced in place (translocated or read-only)")
                    return
                }
                phase = .ready(r)
                if thenRestart { restartNow() }
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// "Restart" in the menu bar / Settings. Never while a meeting records or you dictate; then it
    /// says so instead of doing nothing. It can always be pressed again.
    func restartNow() {
        guard let app = stagedApp else {
            notice = "The update isn't downloaded anymore. Checking again…"
            phase = .idle
            check(userInitiated: true)
            return
        }
        if isBusy() {
            notice = "Finish the recording or dictation first, then press Restart."
            return
        }
        guard Self.installTarget(for: Bundle.main.bundleURL) != nil else {
            if case .ready(let r) = phase { phase = .needsMove(r) }
            return
        }
        do {
            try swap(in: app, relaunch: true)
        } catch {
            notice = "Update couldn't start: \(error.localizedDescription). Details in ~/Library/Logs/Scribe/update.log."
            Self.log("swap script failed to start: \(error.localizedDescription)")
            return
        }
        NSApp.terminate(nil)
        // If something kept Scribe from quitting, say so (the button stays live for another try).
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            self?.notice = "Scribe didn't quit, so the update hasn't installed yet. Press Restart to try again."
        }
    }

    /// Called when Scribe quits: a ready update is swapped in quietly (no relaunch).
    func installOnQuitIfReady() {
        guard let app = stagedApp, case .ready = phase else { return }
        try? swap(in: app, relaunch: false)
    }

    /// The running swap script (one at a time; a dead one can be replaced by a new attempt).
    private var swapProcess: Process?

    /// A tiny shell script waits for Scribe to quit, swaps the app in place (the REAL path when
    /// translocated), logs each step, and reopens it. On failure it restores the old app.
    private func swap(in newApp: URL, relaunch: Bool) throws {
        if let p = swapProcess, p.isRunning { return }          // already waiting for us to quit
        guard let target = Self.installTarget(for: Bundle.main.bundleURL) else {
            throw UpdateError.message("Scribe can't replace itself where it runs from. Move it to Applications.")
        }
        let version = (NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String) ?? "?"
        UserDefaults.standard.set(version, forKey: Self.pendingKey)
        Self.log("restart requested: \(Self.currentVersion) → \(version), running from \(Bundle.main.bundleURL.path), installing to \(target.path)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", Self.swapScript(pid: ProcessInfo.processInfo.processIdentifier, current: target.path,
                                             new: newApp.path, log: Self.logURL.path,
                                             marker: Self.updateFolder.appendingPathComponent(Self.failedMarker).path,
                                             relaunch: relaunch)]
        try p.run()
        swapProcess = p
    }

    /// The swap script (a pure function, so the self-test can read it).
    nonisolated static func swapScript(pid: Int32, current: String, new: String, log: String, marker: String, relaunch: Bool) -> String {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return """
        LOG=\(q(log)); CUR=\(q(current)); NEW=\(q(new)); OLD="$CUR.old"; MARK=\(q(marker))
        mkdir -p "$(dirname "$LOG")"
        log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [swap] $*" >> "$LOG"; }
        fail() {
          log "FAILED: $1"
          echo "$1" > "$MARK"
          if [ ! -d "$CUR" ] && [ -d "$OLD" ]; then mv "$OLD" "$CUR" && log "restored the previous app" || log "could NOT restore $OLD"; fi
          \(relaunch ? "open \"$CUR\" --args --update-failed && log \"reopened the previous app\"" : "true")
          exit 1
        }
        log "waiting for Scribe (pid \(pid)) to quit"
        n=0; while kill -0 \(pid) 2>/dev/null; do sleep 0.2; n=$((n+1)); [ $n -gt 600 ] && { log "Scribe never quit; giving up"; exit 1; }; done
        log "Scribe quit; installing $NEW → $CUR"
        [ -d "$NEW" ] || fail "the new app is missing at $NEW"
        rm -rf "$OLD"
        mv "$CUR" "$OLD" || fail "couldn't move the current app aside (mv $CUR → $OLD)"
        log "moved the current app aside"
        mv "$NEW" "$CUR" || fail "couldn't move the new app into place (mv $NEW → $CUR)"
        log "new app in place"
        rm -rf "$OLD"
        xattr -dr com.apple.quarantine "$CUR" 2>/dev/null
        rm -f "$MARK"
        log "done"
        \(relaunch ? "open \"$CUR\" && log \"reopened\"" : "true")
        """
    }

    // MARK: Launch housekeeping

    /// At launch: report how the last update went, and clean up a stale staged update.
    func launchHousekeeping() {
        let fm = FileManager.default
        let current = Self.currentVersion
        let marker = Self.updateFolder.appendingPathComponent(Self.failedMarker)
        let failedFlag = CommandLine.arguments.contains("--update-failed")
        if failedFlag || fm.fileExists(atPath: marker.path) {
            notice = "Update couldn't install — see ~/Library/Logs/Scribe/update.log"
            Self.log("launch \(current): last install failed (\((try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "flag only"))")
            try? fm.removeItem(at: marker)
            if let v = UserDefaults.standard.string(forKey: Self.pendingKey) {
                UserDefaults.standard.set(v, forKey: Self.failedVersionKey)
            }
            UserDefaults.standard.removeObject(forKey: Self.pendingKey)
        } else if let pending = UserDefaults.standard.string(forKey: Self.pendingKey) {
            if pending == current {
                notice = "Updated to \(current)"
                UserDefaults.standard.removeObject(forKey: Self.failedVersionKey)
                Self.log("launch \(current): update installed")
            } else {
                Self.log("launch \(current): expected \(pending) after the update; still on \(current)")
            }
            UserDefaults.standard.removeObject(forKey: Self.pendingKey)
        }
        // A staged app that isn't newer than this one is leftover; delete it.
        let staged = Self.updateFolder.appendingPathComponent("Scribe.app/Contents/Info.plist")
        if let v = NSDictionary(contentsOf: staged)?["CFBundleShortVersionString"] as? String, !Self.isNewer(v, than: current) {
            try? fm.removeItem(at: Self.updateFolder)
            Self.log("launch \(current): removed stale staged update \(v)")
        }
        if Self.isTranslocated(Bundle.main.bundleURL.path) {
            Self.log("launch \(current): running translocated from \(Bundle.main.bundleURL.path); real path \(Self.originalURL(forTranslocated: Bundle.main.bundleURL)?.path ?? "unknown")")
        }
    }

    // MARK: Where to install (App Translocation)

    nonisolated static func isTranslocated(_ path: String) -> Bool { path.contains("/AppTranslocation/") }

    /// The app's real location when macOS runs it from a translocation mount (nil if unknown).
    nonisolated static func originalURL(forTranslocated url: URL) -> URL? {
        typealias Fn = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard let h = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let sym = dlsym(h, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        let fn = unsafeBitCast(sym, to: Fn.self)
        guard let out = fn(url as CFURL, nil)?.takeRetainedValue() else { return nil }
        let real = out as URL
        return isTranslocated(real.path) ? nil : real
    }

    /// Where the update should be swapped in: the app's own path, or its real path when
    /// translocated. nil = no writable place (show "Move Scribe to Applications").
    nonisolated static func installTarget(for bundle: URL) -> URL? {
        var target = bundle
        if isTranslocated(bundle.path) {
            guard let real = originalURL(forTranslocated: bundle) else { return nil }
            target = real
        }
        let parent = target.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: parent) else { return nil }
        return target
    }

    /// Appends one line to ~/Library/Logs/Scribe/update.log.
    nonisolated static func log(_ line: String) {
        let url = logURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) [app] \(line)\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw UpdateError.message("\((tool as NSString).lastPathComponent) failed (\(p.terminationStatus)).")
        }
    }

    enum UpdateError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
    }
}
