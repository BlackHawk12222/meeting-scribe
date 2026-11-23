// ModelStore.swift
// Knows which speech models are on this Mac and downloads ONLY what's missing or changed.
//
// The idea ("components + manifest", like a package manager):
//  • The app carries Resources/ModelManifest.json. It lists each model as a *component*
//    (speech model, voice detector, speaker models) with every file's size and hash,
//    pinned to an exact Hugging Face commit. (scripts/make_model_manifest.py writes it.)
//  • The models themselves are NOT in the app. They live in
//    ~/Library/Application Support/FluidAudio/Models/<model>/ and survive app updates,
//    reinstalls and deleting the app.
//  • After installing a component Scribe saves a receipt in
//    ~/Library/Application Support/Scribe/models-installed.json: the component's hash and
//    each file's hash.
//  • On every launch: compare manifest ↔ receipt ↔ files on disk (exists + exact size).
//    Same hash and files present → nothing to do. A file whose hash changed in a new
//    manifest → only that file downloads. A brand-new app version with the same model
//    hashes → zero bytes downloaded.
//  • "Verify" re-hashes every byte (SHA-256 / git SHA-1) to catch a damaged file.

import Foundation
import CryptoKit
import FluidAudio

// MARK: - Manifest

struct ModelManifest: Codable, Sendable {
    var schema: Int
    var fluidAudio: String
    var components: [ModelComponent]

    /// The manifest inside this app.
    static let bundled: ModelManifest? = {
        guard let url = Bundle.main.url(forResource: "ModelManifest", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ModelManifest.self, from: data)
    }()

    func component(_ id: String) -> ModelComponent? { components.first { $0.id == id } }
}

struct ModelComponent: Codable, Sendable, Identifiable, Hashable {
    struct File: Codable, Sendable, Hashable {
        var path: String
        var size: Int64
        var sha256: String?
        var gitSha1: String?
        var hash: String { sha256 ?? gitSha1 ?? "" }
    }
    var id: String
    var title: String
    var group: String              // "dictation" (needed first) or "meetings" (fetched later)
    var repo: String
    var fluidRevision: String      // what FluidAudio expects in its cache marker
    var commit: String             // the exact Hugging Face commit we download from
    var version: String
    var hash: String
    var totalBytes: Int64
    var files: [File]

    /// The FluidAudio repo this component belongs to (its folder name comes from FluidAudio,
    /// so Scribe and FluidAudio always agree on where the files are).
    var fluidRepo: Repo? {
        switch id {
        case "asr-v2": return .parakeetV2
        case "asr-v3": return .parakeetV3
        case "vad": return .vad
        case "diarizer": return .diarizer
        case "asr-ultra": return .parakeetUltra
        case "ctc-110m": return .parakeetCtc110m
        default: return nil
        }
    }

    /// Where FluidAudio loads this component from.
    func folder(root: URL? = nil) -> URL {
        let base = root ?? MLModelConfigurationUtils.defaultModelsDirectory()
        let name = fluidRepo?.folderName ?? repo.split(separator: "/").last.map(String.init) ?? id
        return base.appendingPathComponent(name, isDirectory: true)
    }

    func remoteURL(_ f: File) -> URL {
        let path = f.path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        return URL(string: "https://huggingface.co/\(repo)/resolve/\(commit)/\(path)")!
    }
}

// MARK: - Status

enum ModelState: Equatable, Sendable {
    case missing                 // nothing (or almost nothing) on disk
    case partial                 // an interrupted download — will resume
    case updateAvailable(Int64)  // on disk, but the manifest has changed files (bytes to fetch)
    case downloaded
    case downloading(DownloadProgress)
    case verifying
    case damaged(Int)            // Verify found N bad files (they'll be re-downloaded)
    case failed(String)

    var label: String {
        switch self {
        case .missing: return "Missing"
        case .partial: return "Partly downloaded"
        case .updateAvailable(let b): return "Update available (\(ModelStore.mb(b)))"
        case .downloaded: return "Downloaded"
        case .downloading(let p): return "Downloading · \(p.text)"
        case .verifying: return "Verifying…"
        case .damaged(let n): return "\(n) damaged file\(n == 1 ? "" : "s") — will re-download"
        case .failed(let e): return "Failed: \(e)"
        }
    }
}

/// Receipt of what was installed (per component: its hash and each file's hash).
struct InstallReceipt: Codable, Sendable {
    var hash: String
    var version: String
    var installedAt: Date
    var files: [String: String]   // path -> hash
}

// MARK: - Store

@MainActor
final class ModelStore: ObservableObject {
    static let shared = ModelStore()

    @Published private(set) var states: [String: ModelState] = [:]
    /// Overall progress of the current download (nil when idle). Drives onboarding + banners.
    @Published private(set) var progress: DownloadProgress?

    let manifest: ModelManifest?
    let root: URL                       // FluidAudio's models folder
    private let receiptsURL: URL
    private var receipts: [String: InstallReceipt] = [:]
    private var running: [String: Task<Void, Error>] = [:]

    init(manifest: ModelManifest? = .bundled, root: URL? = nil, receiptsURL: URL? = nil) {
        self.manifest = manifest
        self.root = root ?? MLModelConfigurationUtils.defaultModelsDirectory()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.receiptsURL = receiptsURL ?? support.appendingPathComponent("Scribe/models-installed.json")
        loadReceipts()
        refresh()
    }

    var components: [ModelComponent] { manifest?.components ?? [] }

    /// Which components dictation needs with the chosen speech model.
    func dictationComponents(_ model: SpeechModel) -> [String] {
        [model.componentID, "vad"]
    }
    let meetingComponents = ["diarizer"]
    /// The vocabulary helper (fetched in the background after dictation works, only if
    /// Settings › Vocabulary › "Match against the audio" is on).
    let vocabularyComponents = ["ctc-110m"]

    /// Optional components nobody chose (another speech model, the helper while it's off) are
    /// hidden from the list unless they're on disk, so the list shows what matters.
    func isRelevant(_ c: ModelComponent) -> Bool {
        if states[c.id] == .downloaded { return true }
        switch c.id {
        case "asr-ultra": return SpeechModel.offerAccurate
        case "ctc-110m": return Vocabulary.acousticBoost
        default: return true
        }
    }

    nonisolated static func mb(_ bytes: Int64) -> String {
        bytes >= 1_000_000 ? String(format: "%.0f MB", Double(bytes) / 1_000_000)
                           : String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }

    // MARK: Checking (cheap: file sizes only)

    /// Re-check every component against the disk. Runs at launch and after downloads.
    func refresh() {
        for c in components where !isBusy(c.id) {
            states[c.id] = quickState(c)
        }
    }

    private func isBusy(_ id: String) -> Bool {
        switch states[id] {
        case .downloading, .verifying: return true
        default: return false
        }
    }

    /// The files that must be downloaded for `c` (missing, wrong size, or changed hash).
    func filesToFetch(_ c: ModelComponent) -> [ModelComponent.File] {
        let folder = c.folder(root: root)
        let receipt = receipts[c.id]
        let fm = FileManager.default
        return c.files.filter { f in
            let url = folder.appendingPathComponent(f.path)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  (attrs[.size] as? NSNumber)?.int64Value == f.size else { return true }
            // On disk with the right size. If we installed it, the hash must still match the manifest.
            if let receipt, let had = receipt.files[f.path], had != f.hash { return true }
            return false
        }
    }

    private func quickState(_ c: ModelComponent) -> ModelState {
        let need = filesToFetch(c)
        if need.isEmpty {
            // Everything's there. No receipt yet = models from an older Scribe (FluidAudio's own
            // download): sizes match the manifest, so adopt them instead of downloading again.
            if receipts[c.id]?.hash != c.hash { writeReceipt(for: c) }
            return .downloaded
        }
        let folder = c.folder(root: root)
        let anyPart = c.files.contains {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.path).appendingPathExtension("scribepart").path)
        }
        if anyPart { return .partial }
        let needBytes = need.reduce(Int64(0)) { $0 + $1.size }
        if receipts[c.id] != nil || needBytes < c.totalBytes / 2 { return .updateAvailable(needBytes) }
        return .missing
    }

    func isInstalled(_ id: String) -> Bool { states[id] == .downloaded }

    // MARK: Downloading

    /// Make sure these components are on disk, downloading only what's missing/changed.
    /// Several callers asking for the same component share one download.
    func ensure(_ ids: [String]) async throws {
        guard manifest != nil else { return }      // no manifest: FluidAudio downloads by itself
        let wanted = ids.compactMap { manifest?.component($0) }
        var tasks: [Task<Void, Error>] = []
        let todo = wanted.filter { !filesToFetch($0).isEmpty }
        if !todo.isEmpty {
            let key = todo.map(\.id).sorted().joined(separator: "+")
            if let t = running[key] {
                tasks.append(t)
            } else {
                let t = Task { try await self.download(todo) }
                running[key] = t
                tasks.append(t)
            }
        }
        for c in wanted where todo.isEmpty || !todo.contains(c) { states[c.id] = quickState(c) }
        for t in tasks {
            defer { running = running.filter { $0.value != t } }
            try await t.value
        }
    }

    private func download(_ comps: [ModelComponent]) async throws {
        var jobs: [DownloadJob] = []
        var perComponent: [(ModelComponent, [ModelComponent.File])] = []
        for c in comps {
            let need = filesToFetch(c)
            perComponent.append((c, need))
            let folder = c.folder(root: root)
            jobs += need.map { DownloadJob(url: c.remoteURL($0), destination: folder.appendingPathComponent($0.path), size: $0.size) }
            states[c.id] = .downloading(DownloadProgress(doneBytes: 0, totalBytes: need.reduce(0) { $0 + $1.size }, bytesPerSecond: 0))
        }
        let ids = comps.map(\.id)
        do {
            try await ModelDownloader().run(jobs) { p in
                Task { @MainActor in
                    self.progress = p
                    for id in ids { self.states[id] = .downloading(p) }
                }
            }
            // Check the new files' hashes before trusting them (a few seconds for 450 MB).
            for (c, files) in perComponent {
                let folder = c.folder(root: root)
                let bad = await Self.badFiles(files, in: folder)
                if !bad.isEmpty {
                    for f in bad { try? FileManager.default.removeItem(at: folder.appendingPathComponent(f.path)) }
                    throw NSError(domain: "Scribe", code: 1, userInfo: [NSLocalizedDescriptionKey:
                        "\(bad.count) downloaded file(s) of \(c.title) didn't match the manifest. Press Retry."])
                }
                writeRevisionMarker(c)
                writeReceipt(for: c)
                states[c.id] = .downloaded
            }
            progress = nil
        } catch {
            progress = nil
            for c in comps { states[c.id] = .failed(error.localizedDescription) }
            throw error
        }
    }

    /// FluidAudio keeps a ".fluidaudio-revision" note in pinned repos (the speaker models);
    /// without the right one it would think the cache is from another version and re-download.
    private func writeRevisionMarker(_ c: ModelComponent) {
        guard c.fluidRevision != "main" else { return }
        let marker = c.folder(root: root).appendingPathComponent(".fluidaudio-revision")
        try? Data((c.fluidRevision + "\n").utf8).write(to: marker, options: .atomic)
    }

    // MARK: Verify (full hash of every byte)

    func verify(_ id: String) async {
        guard let c = manifest?.component(id) else { return }
        states[id] = .verifying
        let folder = c.folder(root: root)
        let present = c.files.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.path).path) }
        let bad = await Self.badFiles(present, in: folder)
        if bad.isEmpty {
            states[id] = quickState(c)
        } else {
            // Forget those files' hashes so the next ensure() downloads just them.
            if var r = receipts[id] {
                for f in bad { r.files[f.path] = "bad" }
                receipts[id] = r
                saveReceipts()
            }
            for f in bad { try? FileManager.default.removeItem(at: folder.appendingPathComponent(f.path)) }
            states[id] = .damaged(bad.count)
        }
    }

    /// Hash files off the main thread; return the ones that don't match.
    nonisolated static func badFiles(_ files: [ModelComponent.File], in folder: URL) async -> [ModelComponent.File] {
        await Task.detached(priority: .utility) {
            files.filter { f in
                let url = folder.appendingPathComponent(f.path)
                guard let got = try? fileHash(url, size: f.size, git: f.sha256 == nil) else { return true }
                return got != f.hash
            }
        }.value
    }

    /// SHA-256 of the content (big files), or git's blob SHA-1 ("blob <size>\0" + content) for small ones.
    nonisolated static func fileHash(_ url: URL, size: Int64, git: Bool) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        func hex<D: Digest>(_ d: D) -> String { d.map { String(format: "%02x", $0) }.joined() }
        if git {
            var sha = Insecure.SHA1()
            sha.update(data: Data("blob \(size)\0".utf8))
            while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty { sha.update(data: chunk) }
            return hex(sha.finalize())
        }
        var sha = SHA256()
        while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty { sha.update(data: chunk) }
        return hex(sha.finalize())
    }

    // MARK: Receipts

    private func loadReceipts() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: receiptsURL), let r = try? dec.decode([String: InstallReceipt].self, from: d) {
            receipts = r
        }
    }

    private func saveReceipts() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: receiptsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? enc.encode(receipts).write(to: receiptsURL, options: .atomic)
    }

    private func writeReceipt(for c: ModelComponent) {
        receipts[c.id] = InstallReceipt(hash: c.hash, version: c.version, installedAt: Date(),
                                        files: Dictionary(uniqueKeysWithValues: c.files.map { ($0.path, $0.hash) }))
        saveReceipts()
    }

    /// For the updater: which components of a *new* manifest differ from what's installed.
    func changes(in other: ModelManifest) -> [(ModelComponent, Int64)] {
        other.components.compactMap { c in
            guard let r = receipts[c.id] else { return nil }      // not installed here = not needed
            guard r.hash != c.hash else { return nil }
            let bytes = c.files.filter { r.files[$0.path] != $0.hash }.reduce(Int64(0)) { $0 + $1.size }
            return (c, bytes)
        }
    }

    /// Only for `Scribe --snapshot`: show given states in Settings without touching the disk.
    func setPreview(_ s: [String: ModelState]) { states = s }
}
