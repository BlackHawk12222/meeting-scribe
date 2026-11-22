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
// Planned next (needs a one-time setup by the repo owner, see README → Updates): Sparkle 2 with
// EdDSA-signed appcast + binary delta updates (only the changed bytes of the app).

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
        case failed(String)
    }

    struct Release: Equatable {
        var version: String
        var tag: String
        var notes: String
        var zipURL: URL
        var zipBytes: Int64
        var modelChanges: [String]      // human-readable lines ("Speech model · English — 12 MB")
    }

    @Published private(set) var phase: Phase = .idle

    /// Where to ask "what's the newest release?" (GitHub's API). Can be changed in Info.plist
    /// (key ScribeReleasesURL), e.g. to a public mirror repo.
    var feedURL: URL {
        if let s = Bundle.main.object(forInfoDictionaryKey: "ScribeReleasesURL") as? String, let u = URL(string: s) { return u }
        return URL(string: "https://api.github.com/repos/BlackHawk12222/meeting-scribe/releases/latest")!
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    @Published var autoCheck: Bool = UserDefaults.standard.object(forKey: "autoUpdateCheck") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoCheck, forKey: "autoUpdateCheck") }
    }

    /// Quietly once a day at launch.
    func checkInBackgroundIfDue() {
        guard autoCheck else { return }
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        guard Date().timeIntervalSince1970 - last > 86_400 else { return }
        check(userInitiated: false)
    }

    func check(userInitiated: Bool) {
        if case .downloading = phase { return }
        phase = .checking
        Task {
            do {
                let r = try await fetchLatest()
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
                if Self.isNewer(r.version, than: Self.currentVersion) {
                    phase = .available(r)
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
            throw UpdateError.message("Couldn't see the release feed (404). The GitHub repo is private, so the app can't read its releases without a login. See README → Updates.")
        }
        guard code == 200 else { throw UpdateError.message("Update server answered \(code).") }
        struct GHAsset: Decodable { var name: String; var browser_download_url: URL; var size: Int64 }
        struct GHRelease: Decodable { var tag_name: String; var body: String?; var assets: [GHAsset] }
        let gh = try JSONDecoder().decode(GHRelease.self, from: data)
        guard let zip = gh.assets.first(where: { $0.name == "Scribe.zip" }) else {
            throw UpdateError.message("The newest release has no Scribe.zip.")
        }
        var changes: [String] = []
        if let comp = gh.assets.first(where: { $0.name == "components.json" }),
           let fetched = try? await URLSession.shared.data(from: comp.browser_download_url),
           let manifest = try? JSONDecoder().decode(ModelManifest.self, from: fetched.0) {
            changes = ModelStore.shared.changes(in: manifest).map { "\($0.0.title) — \(ModelStore.mb($0.1))" }
        }
        let version = gh.tag_name.hasPrefix("v") ? String(gh.tag_name.dropFirst()) : gh.tag_name
        return Release(version: version, tag: gh.tag_name, notes: gh.body ?? "", zipURL: zip.browser_download_url,
                       zipBytes: zip.size, modelChanges: changes)
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

    /// Download Scribe.zip only, check it, swap the app, relaunch.
    func install(_ r: Release) {
        phase = .downloading(nil)
        Task {
            do {
                let (tmpZip, resp) = try await URLSession.shared.download(from: r.zipURL)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.message("Download failed.") }
                phase = .installing
                let work = FileManager.default.temporaryDirectory.appendingPathComponent("ScribeUpdate-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                try Self.run("/usr/bin/ditto", ["-x", "-k", tmpZip.path, work.path])
                let newApp = work.appendingPathComponent("Scribe.app")
                guard FileManager.default.fileExists(atPath: newApp.path) else { throw UpdateError.message("The zip had no Scribe.app.") }
                try Self.run("/usr/bin/codesign", ["--verify", "--deep", newApp.path])
                let plist = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist"))
                let newVersion = plist?["CFBundleShortVersionString"] as? String ?? "?"
                guard newVersion == r.version else { throw UpdateError.message("Version mismatch (\(newVersion) vs \(r.version)).") }
                try relaunch(replacingWith: newApp)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func relaunch(replacingWith newApp: URL) throws {
        let current = Bundle.main.bundleURL
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(current.path).old"
        mv "\(current.path)" "\(current.path).old" && mv "\(newApp.path)" "\(current.path)" && rm -rf "\(current.path).old"
        xattr -dr com.apple.quarantine "\(current.path)" 2>/dev/null
        open "\(current.path)"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try p.run()
        NSApp.terminate(nil)
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
