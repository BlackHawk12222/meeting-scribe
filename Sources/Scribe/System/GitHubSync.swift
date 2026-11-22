// GitHubSync.swift
// Saves every dictation and every meeting's notes as Markdown in YOUR OWN private GitHub
// repo (default BlackHawk12222/scribe-notes — never the app's code repo).
//
//   meetings/2026-11-22-1530-team-project-planning.md   summary, key points, action items,
//                                                          who talked, transcript with speakers
//   dictations/2026-11-22.md                               one file per day; each dictation is
//                                                          appended with its time
//
// How:
//  • GitHub's "contents" REST API (PUT /repos/{owner}/{repo}/contents/{path}) with a fine-grained
//    personal access token you paste once in Settings → Sync. The token is kept in the macOS
//    Keychain, not in a file.
//  • Nothing waits for GitHub. Items go into a queue on disk (sync-queue.json); a worker sends
//    them in the background, retries with growing pauses when offline, and keeps them across
//    restarts. Dictations are batched: at most one commit per day-file every ~2 minutes.
//  • A meeting keeps the same file when its notes or speaker names change later (the file is
//    updated, not duplicated).

import Foundation
import Security

@MainActor
final class GitHubSync: ObservableObject {
    static let shared = GitHubSync()

    enum Status: Equatable {
        case off                     // no token
        case idle(Date?)             // last success
        case syncing
        case waiting(String)         // will retry (offline, rate limit…)
        case problem(String)         // needs you (bad token, repo missing)
    }

    struct Item: Codable, Identifiable {
        enum Kind: String, Codable { case meeting, dictation }
        var id = UUID()
        var kind: Kind
        var path: String
        var content: String          // meeting: whole file; dictation: the block to append
        var meetingID: UUID?
        var created = Date()
        var attempts = 0
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var pending: Int = 0

    @Published var repo: String = UserDefaults.standard.string(forKey: "syncRepo") ?? "BlackHawk12222/scribe-notes" {
        didSet { UserDefaults.standard.set(repo.trimmingCharacters(in: .whitespaces), forKey: "syncRepo") }
    }
    @Published var syncDictations: Bool = UserDefaults.standard.object(forKey: "syncDictations") as? Bool ?? true {
        didSet { UserDefaults.standard.set(syncDictations, forKey: "syncDictations") }
    }
    @Published var syncMeetings: Bool = UserDefaults.standard.object(forKey: "syncMeetings") as? Bool ?? true {
        didSet { UserDefaults.standard.set(syncMeetings, forKey: "syncMeetings") }
    }

    private var queue: [Item] = []
    private var meetingPaths: [UUID: String] = [:]
    private var worker: Task<Void, Never>?
    private var nextTry = Date.distantPast
    private var backoff: TimeInterval = 30
    private let folder: URL
    static let dictationBatchSeconds: TimeInterval = 120

    init(folder: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.folder = folder ?? support.appendingPathComponent("Scribe", isDirectory: true)
        load()
        status = hasToken ? .idle(nil) : .off
        pending = queue.count
    }

    // MARK: Token (Keychain)

    private static let keychainService = "com.blackhawk12222.Scribe.github"

    var hasToken: Bool { Self.readToken() != nil }

    func setToken(_ token: String?) {
        Self.deleteToken()
        if let t = token?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: Self.keychainService,
                                    kSecAttrAccount as String: "token",
                                    kSecValueData as String: Data(t.utf8)]
            SecItemAdd(q as CFDictionary, nil)
        }
        status = hasToken ? .idle(nil) : .off
        kick()
    }

    nonisolated static func readToken() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: keychainService,
                                kSecAttrAccount as String: "token",
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    nonisolated static func deleteToken() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: keychainService,
                                kSecAttrAccount as String: "token"]
        SecItemDelete(q as CFDictionary)
    }

    // MARK: Adding things (instant; never blocks)

    func add(dictation d: DictationEntry) {
        guard hasToken, syncDictations else { return }
        let day = Self.dayFormatter.string(from: d.date)
        let time = Self.timeFormatter.string(from: d.date)
        let block = "### \(time)\n\n\(d.text)\n\n"
        queue.append(Item(kind: .dictation, path: "dictations/\(day).md", content: block))
        saveQueue()
        kick(after: Self.dictationBatchSeconds)
    }

    func add(meeting m: Meeting, markdown: String) {
        guard hasToken, syncMeetings, m.status == .done else { return }
        let path = meetingPaths[m.id] ?? "meetings/\(Self.stampFormatter.string(from: m.date))-\(Self.slug(m.title)).md"
        meetingPaths[m.id] = path
        // Newer notes replace an older queued copy of the same meeting.
        queue.removeAll { $0.meetingID == m.id }
        queue.append(Item(kind: .meeting, path: path, content: markdown, meetingID: m.id))
        saveQueue()
        kick(after: 5)
    }

    // MARK: Worker

    /// Start (or nudge) the background sender.
    func kick(after delay: TimeInterval = 0) {
        pending = queue.count
        guard hasToken, !queue.isEmpty else { return }
        if worker != nil { return }
        worker = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            await self?.drain()
            self?.worker = nil
            if let self, !self.queue.isEmpty {
                let wait = max(5, self.nextTry.timeIntervalSinceNow)
                self.kick(after: wait)
            }
        }
    }

    private func drain() async {
        guard let token = Self.readToken() else { status = .off; return }
        guard Date() >= nextTry else { return }
        status = .syncing
        // Group dictations by file so one day's dictations become one commit.
        var groups: [String: [Item]] = [:]
        for item in queue { groups[item.path, default: []].append(item) }
        for (path, items) in groups.sorted(by: { $0.key < $1.key }) {
            do {
                if items.first?.kind == .meeting {
                    let latest = items.max { $0.created < $1.created }!
                    try await put(path: path, content: latest.content, append: false, token: token,
                                  message: "Meeting notes: \((path as NSString).lastPathComponent)")
                } else {
                    let blocks = items.sorted { $0.created < $1.created }.map(\.content).joined()
                    try await put(path: path, content: blocks, append: true, token: token,
                                  message: "Dictations \((path as NSString).lastPathComponent) (+\(items.count))")
                }
                let ids = Set(items.map(\.id))
                queue.removeAll { ids.contains($0.id) }
                saveQueue()
                backoff = 30
                status = .idle(Date())
            } catch SyncError.needsUser(let msg) {
                status = .problem(msg)
                nextTry = Date().addingTimeInterval(600)
                pending = queue.count
                return
            } catch {
                status = .waiting("Will retry: \(error.localizedDescription)")
                nextTry = Date().addingTimeInterval(backoff)
                backoff = min(backoff * 2, 1800)
                pending = queue.count
                return
            }
        }
        pending = queue.count
    }

    enum SyncError: LocalizedError {
        case needsUser(String), http(Int)
        var errorDescription: String? {
            switch self {
            case .needsUser(let m): return m
            case .http(let c): return "GitHub answered \(c)"
            }
        }
    }

    private func request(_ method: String, _ path: String, token: String, body: Data? = nil) -> URLRequest {
        let encoded = path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        var r = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/\(encoded)")!)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        r.setValue("Scribe", forHTTPHeaderField: "User-Agent")
        r.timeoutInterval = 30
        if let body { r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }

    /// Create or update one file. `append`: add `content` to the end of what's there.
    private func put(path: String, content: String, append: Bool, token: String, message: String) async throws {
        // Current version (needed to update a file): its sha and, for appends, its text.
        let (data, resp) = try await URLSession.shared.data(for: request("GET", "contents/" + path, token: token))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        var sha: String?
        var existing = ""
        if code == 200 {
            struct File: Decodable { var sha: String; var content: String? }
            let f = try JSONDecoder().decode(File.self, from: data)
            sha = f.sha
            if append, let c = f.content, let d = Data(base64Encoded: c.replacingOccurrences(of: "\n", with: "")) {
                existing = String(data: d, encoding: .utf8) ?? ""
            }
        } else if code == 401 {
            throw SyncError.needsUser("GitHub rejected the token (401). Paste a new one in Settings → Sync.")
        } else if code == 403 && (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "x-ratelimit-remaining") != "0" {
            throw SyncError.needsUser("The token can't read \(repo) (403). Give it Contents: Read and write on that repo.")
        } else if code != 404 {
            throw SyncError.http(code)
        }
        var text = content
        if append {
            if existing.isEmpty {
                let day = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                existing = "# Dictations — \(day)\n\n"
            }
            text = existing + content
        }
        var body: [String: Any] = ["message": message, "content": Data(text.utf8).base64EncodedString()]
        if let sha { body["sha"] = sha }
        let (_, putResp) = try await URLSession.shared.data(
            for: request("PUT", "contents/" + path, token: token, body: try JSONSerialization.data(withJSONObject: body)))
        let putCode = (putResp as? HTTPURLResponse)?.statusCode ?? 0
        switch putCode {
        case 200, 201: return
        case 401: throw SyncError.needsUser("GitHub rejected the token (401). Paste a new one in Settings → Sync.")
        case 403: throw SyncError.needsUser("The token isn't allowed to write to \(repo) (403). It needs Contents: Read and write.")
        case 404: throw SyncError.needsUser("Repo \(repo) not found (404). Create it (private) or fix the name in Settings → Sync.")
        case 409, 422: throw SyncError.http(putCode)    // file changed meanwhile: retry re-reads the sha
        default: throw SyncError.http(putCode)
        }
    }

    /// Settings → Sync → "Test connection".
    func testConnection() async -> String {
        guard let token = Self.readToken() else { return "Paste a token first." }
        var r = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)")!)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("Scribe", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: r) else { return "Couldn't reach GitHub (offline?)." }
        switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200:
            struct R: Decodable { var `private`: Bool; var full_name: String; var permissions: [String: Bool]? }
            guard let info = try? JSONDecoder().decode(R.self, from: data) else { return "Connected." }
            if info.full_name.lowercased().hasSuffix("/meeting-scribe") { return "That's the app's code repo — pick a separate notes repo." }
            let canWrite = info.permissions?["push"] ?? true
            return "Connected to \(info.full_name) (\(info.private ? "private" : "PUBLIC — consider making it private"))"
                + (canWrite ? ". Ready to save." : ", but the token can't write. Give it Contents: Read and write.")
        case 401: return "GitHub rejected the token (401)."
        case 404: return "Repo \(repo) not found — create it (private), or the token can't see it."
        case let c: return "GitHub answered \(c)."
        }
    }

    // MARK: Persistence

    private var queueURL: URL { folder.appendingPathComponent("sync-queue.json") }

    private struct Saved: Codable { var queue: [Item]; var meetingPaths: [String: String] }

    private func load() {
        guard let d = try? Data(contentsOf: queueURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let s = try? dec.decode(Saved.self, from: d) {
            queue = s.queue
            meetingPaths = Dictionary(uniqueKeysWithValues: s.meetingPaths.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
        }
    }

    private func saveQueue() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let s = Saved(queue: queue, meetingPaths: Dictionary(uniqueKeysWithValues: meetingPaths.map { ($0.key.uuidString, $0.value) }))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? enc.encode(s).write(to: queueURL, options: .atomic)
        pending = queue.count
    }

    // MARK: Names

    static let dayFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
    static let timeFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
    static let stampFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"; return f }()

    /// "Team – project planning!" -> "team-project-planning"
    nonisolated static func slug(_ s: String) -> String {
        let lowered = s.lowercased().folding(options: .diacriticInsensitive, locale: .current)
        let parts = lowered.split { !($0.isLetter || $0.isNumber) }
        let joined = parts.joined(separator: "-")
        return joined.isEmpty ? "meeting" : String(joined.prefix(60))
    }
}
