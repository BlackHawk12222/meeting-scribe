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

import AppKit
import Foundation

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

    /// Where to ask "what's the newest release?" (GitHub's API). 0.5: the PUBLIC releases-only
    /// repo BlackHawk12222/scribe-releases (the code repo is private, so the app couldn't read
    /// its releases). Info.plist key ScribeReleasesURL.
    var feedURL: URL {
        if let s = Bundle.main.object(forInfoDictionaryKey: "ScribeReleasesURL") as? String, let u = URL(string: s) { return u }
        return URL(string: "https://api.github.com/repos/BlackHawk12222/scribe-releases/releases/latest")!
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
        case .downloading, .installing, .ready: return
        default: break
        }
        phase = .checking
        Task {
            do {
                let r = try await fetchLatest()
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
                if Self.isNewer(r.version, than: Self.currentVersion) {
                    phase = .available(r)
                    if autoCheck && !userInitiated { download(r, thenRestart: false) }
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
    static func isNewer(_ a: String, than b: String) -> Bool {
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
                let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                let work = support.appendingPathComponent("Scribe/Update", isDirectory: true)
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
                phase = .ready(r)
                if thenRestart { restartNow() }
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// "Restart" in the menu bar / Settings. Never while a meeting records or you dictate.
    func restartNow() {
        guard let app = stagedApp, !isBusy() else { return }
        try? swap(in: app, relaunch: true)
        NSApp.terminate(nil)
    }

    /// Called when Scribe quits: a ready update is swapped in quietly (no relaunch).
    func installOnQuitIfReady() {
        guard let app = stagedApp, case .ready = phase else { return }
        try? swap(in: app, relaunch: false)
    }

    private var swapStarted = false
    /// A tiny shell script waits for Scribe to quit, swaps the app in place, optionally reopens it.
    private func swap(in newApp: URL, relaunch: Bool) throws {
        guard !swapStarted else { return }
        swapStarted = true
        let current = Bundle.main.bundleURL
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(current.path).old"
        mv "\(current.path)" "\(current.path).old" && mv "\(newApp.path)" "\(current.path)" && rm -rf "\(current.path).old"
        xattr -dr com.apple.quarantine "\(current.path)" 2>/dev/null
        \(relaunch ? "open \"\(current.path)\"" : "true")
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try p.run()
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
