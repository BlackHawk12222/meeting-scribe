// AccountModel.swift
// 0.7.3.2 optional Scribe account (Profile › Account). Scribe works fully without one.
//
// Why an account: back up and sync your Dictionary, Vocabulary, learned fixes, Styles and
// settings (and, if you turn them on, People and voice profiles) across Macs, restore them after
// a reinstall or on a new Mac, and later unlock Scribe Pro.
//
// Flow: email → 6-digit code (no password) → signed in.
//   • First Mac on this account: a new encryption key is made and a recovery key is shown once.
//   • Another Mac: the recovery key is asked for (checked against the server's key check).
//   • Sync now: download + open + merge, then seal + upload (SyncPayload). Opt-in kinds that are
//     switched off are removed from the server.
//   • Sign out: the session is removed from this Mac (the key stays in the Keychain, so signing
//     back in on this Mac needs no recovery key). Data on this Mac stays.
//   • Delete account and cloud data: every synced row, the key check and the sign-in account
//     are deleted on the server; the session and key are removed from this Mac. Data on this
//     Mac stays.
// Not configured (no Supabase URL/key in the build) = `.unavailable`: no network, no Keychain.

import Foundation
import CryptoKit

@MainActor
final class AccountModel: ObservableObject {
    /// Replaceable so snapshots can show invented account states.
    static var shared = AccountModel()

    enum Phase: Equatable {
        case unavailable                    // "Accounts coming soon"
        case signedOut
        case codeSent(email: String)
        case needsRecoveryKey(email: String)
        case showRecoveryKey(email: String, recoveryKey: String)
        case signedIn(email: String)

        var email: String? {
            switch self {
            case .codeSent(let e), .needsRecoveryKey(let e), .signedIn(let e): return e
            case .showRecoveryKey(let e, _): return e
            default: return nil
            }
        }
    }

    @Published private(set) var phase: Phase
    @Published private(set) var busy = false
    @Published private(set) var lastSynced: Date?
    @Published var error: String?
    @Published var notice: String?
    @Published var syncPeople: Bool { didSet { defaults.set(syncPeople, forKey: SyncOptions.peopleKey) } }
    @Published var syncVoiceprints: Bool { didSet { defaults.set(syncVoiceprints, forKey: SyncOptions.voiceprintsKey) } }

    let config: AccountConfig?
    private let secrets: SecretStore?
    private let defaults: UserDefaults
    private var client: SupabaseClient?
    private var session: SupabaseSession?
    private var key: SymmetricKey?
    /// Set by snapshots: never call the server.
    private var previewOnly = false

    static let lastSyncedKey = "accountLastSynced"
    static let deviceIDKey = "syncDeviceID"
    private static let sessionName = "session"
    private static func keyName(_ user: String) -> String { "syncKey." + user.lowercased() }

    init(config: AccountConfig? = AccountConfig.load(), secrets: SecretStore? = nil, defaults: UserDefaults = .standard) {
        self.config = config
        self.defaults = defaults
        let opts = SyncOptions.load(defaults)
        syncPeople = opts.people
        syncVoiceprints = opts.voiceprints
        guard let config else {
            // Not configured: never touch the Keychain or the network.
            self.secrets = nil
            phase = .unavailable
            return
        }
        let store: SecretStore = secrets ?? KeychainSecretStore()
        self.secrets = store
        phase = .signedOut
        client = SupabaseClient(config: config)
        lastSynced = defaults.object(forKey: Self.lastSyncedKey) as? Date
        if let d = store.data(for: Self.sessionName), let s = try? JSONDecoder().decode(SupabaseSession.self, from: d) {
            session = s
            if let k = store.data(for: Self.keyName(s.userID)) {
                key = SymmetricKey(data: k)
                phase = .signedIn(email: s.email)
            } else {
                phase = .needsRecoveryKey(email: s.email)
            }
        }
    }

    var isAvailable: Bool { phase != .unavailable }
    var isSignedIn: Bool { if case .signedIn = phase { return true }; return false }
    var options: SyncOptions { SyncOptions(people: syncPeople, voiceprints: syncVoiceprints) }

    var deviceID: String {
        if let d = defaults.string(forKey: Self.deviceIDKey) { return d }
        let d = UUID().uuidString.lowercased()
        defaults.set(d, forKey: Self.deviceIDKey)
        return d
    }

    // MARK: Sign in

    func sendCode(email raw: String) async {
        let email = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.looksLikeEmail(email) else { error = "That doesn't look like an email address."; return }
        guard let client else { return }
        await run {
            try await client.sendCode(email: email)
            self.phase = .codeSent(email: email)
            self.notice = "We sent a 6-digit code to \(email)."
        }
    }

    func verify(code raw: String) async {
        guard case .codeSent(let email) = phase, let client else { return }
        let code = raw.filter(\.isNumber)
        guard code.count >= 6 else { error = "Type the 6-digit code from the email."; return }
        await run {
            let s = try await client.verify(email: email, code: code)
            self.adopt(s)
            try await self.setUpKey()
        }
    }

    func useDifferentEmail() {
        guard !previewOnly else { return }
        session = nil
        secrets?.set(nil, for: Self.sessionName)
        phase = .signedOut
        error = nil; notice = nil
    }

    /// After sign-in: first Mac → new key + recovery key; key in Keychain → signed in; else ask.
    private func setUpKey() async throws {
        guard let client, let s = try await validSession() else { return }
        let existing = try await client.fetchKeyCheck(s)
        if let check = existing {
            if let k = secrets?.data(for: Self.keyName(s.userID)), SyncCrypto.verify(key: SymmetricKey(data: k), keyCheck: check, user: s.userID) {
                key = SymmetricKey(data: k)
                phase = .signedIn(email: s.email)
                notice = "Signed in."
            } else {
                phase = .needsRecoveryKey(email: s.email)
            }
            return
        }
        let k = SyncCrypto.newKey()
        try await client.putKeyCheck(s, keyCheck: try SyncCrypto.keyCheck(key: k, user: s.userID))
        secrets?.set(SyncCrypto.keyData(k), for: Self.keyName(s.userID))
        key = k
        phase = .showRecoveryKey(email: s.email, recoveryKey: SyncCrypto.recoveryKey(k))
    }

    /// "I saved it" on the recovery-key screen → signed in, first backup.
    func recoveryKeySaved(store: Store) async {
        guard case .showRecoveryKey(let email, _) = phase else { return }
        phase = .signedIn(email: email)
        await syncNow(store: store)
    }

    /// Second Mac: the typed recovery key must open the server's key check.
    func enterRecoveryKey(_ text: String, store: Store) async {
        guard case .needsRecoveryKey(let email) = phase, let client else { return }
        guard let k = SyncCrypto.parseRecoveryKey(text) else {
            error = "That isn't a recovery key. It's 52 letters and numbers, in groups of 4."
            return
        }
        await run {
            guard let s = try await self.validSession(), let check = try await client.fetchKeyCheck(s) else {
                self.error = "This account has no backup yet."
                return
            }
            guard SyncCrypto.verify(key: k, keyCheck: check, user: s.userID) else {
                self.error = "That recovery key doesn't belong to this account."
                return
            }
            self.secrets?.set(SyncCrypto.keyData(k), for: Self.keyName(s.userID))
            self.key = k
            self.phase = .signedIn(email: email)
        }
        if isSignedIn { await syncNow(store: store) }
    }

    // MARK: Sync

    func syncNow(store: Store) async {
        guard isSignedIn, let client, let key, !previewOnly else { return }
        await run {
            guard let s = try await self.validSession() else { return }
            let opts = self.options
            let since = self.lastSynced ?? .distantPast
            let device = self.deviceID
            // 1. Download, open, merge.
            for item in try await client.fetchItems(s) {
                guard let kind = SyncKind(rawValue: item.kind), opts.includes(kind) else { continue }
                let plain = try SyncCrypto.open(item.ciphertext, key: key, user: s.userID, kind: kind.rawValue)
                let remoteWins = (item.updatedAt ?? .distantPast) > since && item.deviceID != device
                SyncPayload.apply(kind, data: plain, remoteWins: remoteWins, store: store, defaults: self.defaults)
            }
            // 2. Seal and upload this Mac's (merged) copy.
            let items = SyncPayload.collect(store: store, options: opts, defaults: self.defaults)
            let rows = try SyncPayload.rows(items, key: SymmetricKeyBox(key: key), user: s.userID, deviceID: device)
            try await client.upsert(s, rows: rows)
            // 3. Opt-in kinds that are off: not in the cloud.
            let off = SyncKind.allCases.filter { $0.optIn && !opts.includes($0) }.map(\.rawValue)
            try await client.deleteKinds(s, kinds: off)
            let now = Date()
            self.lastSynced = now
            self.defaults.set(now, forKey: Self.lastSyncedKey)
            self.notice = "Synced."
        }
    }

    // MARK: Sign out / delete

    func signOut() async {
        guard !previewOnly else { return }
        if let client, let s = session { await client.signOut(s) }
        session = nil
        key = nil
        secrets?.set(nil, for: Self.sessionName)
        phase = isAvailable ? .signedOut : .unavailable
        notice = "Signed out. Everything on this Mac stays."
        error = nil
    }

    func deleteAccount() async {
        guard let client, !previewOnly else { return }
        var done = false
        await run {
            guard let s = try await self.validSession() else { return }
            try await client.deleteAccount(s)
            self.secrets?.set(nil, for: Self.keyName(s.userID))
            done = true
        }
        guard done else { return }
        session = nil
        key = nil
        secrets?.set(nil, for: Self.sessionName)
        lastSynced = nil
        defaults.removeObject(forKey: Self.lastSyncedKey)
        phase = .signedOut
        notice = "Your account and its cloud data are deleted. Everything on this Mac stays."
    }

    // MARK: Helpers

    private func adopt(_ s: SupabaseSession) {
        session = s
        if let d = try? JSONEncoder().encode(s) { secrets?.set(d, for: Self.sessionName) }
    }

    /// The session, refreshed if it's about to expire. A refused refresh = signed out.
    private func validSession() async throws -> SupabaseSession? {
        guard let s = session, let client else { return nil }
        guard s.expiresSoon else { return s }
        do {
            let fresh = try await client.refresh(s)
            adopt(fresh)
            return fresh
        } catch let e as SupabaseClient.ClientError where e.status == 400 || e.status == 401 {
            session = nil
            secrets?.set(nil, for: Self.sessionName)
            phase = .signedOut
            error = "You were signed out. Sign in again to keep syncing."
            return nil
        }
    }

    private func run(_ work: () async throws -> Void) async {
        busy = true
        error = nil
        notice = nil
        defer { busy = false }
        do { try await work() } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    static func looksLikeEmail(_ s: String) -> Bool {
        let parts = s.split(separator: "@")
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !s.contains(" ")
    }

    // MARK: Preview (snapshots only, invented email; never talks to a server)

    static func preview(_ phase: Phase, lastSynced: Date? = nil, people: Bool = false, voiceprints: Bool = false) -> AccountModel {
        let suite = UserDefaults(suiteName: "scribe-account-preview-\(UUID().uuidString)") ?? .standard
        let cfg = AccountConfig(url: URL(string: "https://preview.invalid")!, anonKey: "preview-anon-key-not-real-000000")
        let m = AccountModel(config: phase == .unavailable ? nil : cfg, secrets: MemorySecretStore(), defaults: suite)
        m.previewOnly = true
        m.phase = phase
        m.lastSynced = lastSynced
        m.syncPeople = people
        m.syncVoiceprints = voiceprints
        return m
    }
}
