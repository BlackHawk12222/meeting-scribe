// SupabaseClient.swift
// The few Supabase REST calls Scribe needs, over URLSession (no SDK):
//   Auth (GoTrue):  POST /auth/v1/otp      email a 6-digit code (creates the user the first time)
//                   POST /auth/v1/verify   code → session (access + refresh token)
//                   POST /auth/v1/token?grant_type=refresh_token
//                   POST /auth/v1/logout
//   Data (PostgREST, row-level security = only your own rows; backend/supabase/):
//                   sync_items  (user_id, kind, ciphertext, device_id, updated_at)
//                   sync_keys   (user_id, key_check)
//                   rpc/delete_my_account
// Only ciphertext (SyncCrypto) and a few labels (item kind, a random device id) are ever sent.

import Foundation

struct SupabaseSession: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var userID: String
    var email: String

    var expiresSoon: Bool { expiresAt.timeIntervalSinceNow < 60 }
}

struct RemoteSyncItem: Equatable {
    var kind: String
    var ciphertext: String
    var deviceID: String?
    var updatedAt: Date?
}

/// One row as uploaded. Field names match the SQL table.
struct UploadRow: Codable, Equatable {
    var user_id: String
    var kind: String
    var ciphertext: String
    var device_id: String
}

final class SupabaseClient: @unchecked Sendable {
    enum ClientError: LocalizedError {
        case http(Int, String)
        case badResponse
        var errorDescription: String? {
            switch self {
            case .http(let code, let msg): return msg.isEmpty ? "The account server answered \(code)." : msg
            case .badResponse: return "The account server sent something unexpected."
            }
        }
        var status: Int? { if case .http(let c, _) = self { return c }; return nil }
    }

    let config: AccountConfig
    let urlSession: URLSession

    init(config: AccountConfig, urlSession: URLSession = .shared) {
        self.config = config
        self.urlSession = urlSession
    }

    // MARK: Auth

    func sendCode(email: String) async throws {
        _ = try await send("POST", "/auth/v1/otp", json: ["email": email, "create_user": true])
    }

    func verify(email: String, code: String) async throws -> SupabaseSession {
        let d = try await send("POST", "/auth/v1/verify", json: ["type": "email", "email": email, "token": code])
        return try Self.session(from: d, fallbackEmail: email)
    }

    func refresh(_ s: SupabaseSession) async throws -> SupabaseSession {
        let d = try await send("POST", "/auth/v1/token?grant_type=refresh_token", json: ["refresh_token": s.refreshToken])
        return try Self.session(from: d, fallbackEmail: s.email)
    }

    func signOut(_ s: SupabaseSession) async {
        _ = try? await send("POST", "/auth/v1/logout", json: [:], token: s.accessToken)
    }

    static func session(from data: Data, fallbackEmail: String) throws -> SupabaseSession {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = o["access_token"] as? String, let refresh = o["refresh_token"] as? String,
              let user = o["user"] as? [String: Any], let id = user["id"] as? String else { throw ClientError.badResponse }
        let expiresIn = (o["expires_in"] as? Double) ?? Double((o["expires_in"] as? Int) ?? 3600)
        return SupabaseSession(accessToken: access, refreshToken: refresh,
                               expiresAt: Date().addingTimeInterval(expiresIn),
                               userID: id, email: (user["email"] as? String) ?? fallbackEmail)
    }

    // MARK: Data

    func fetchItems(_ s: SupabaseSession) async throws -> [RemoteSyncItem] {
        let d = try await send("GET", "/rest/v1/sync_items?select=kind,ciphertext,device_id,updated_at", token: s.accessToken)
        guard let rows = try JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { throw ClientError.badResponse }
        return rows.compactMap { r in
            guard let k = r["kind"] as? String, let c = r["ciphertext"] as? String else { return nil }
            return RemoteSyncItem(kind: k, ciphertext: c, deviceID: r["device_id"] as? String,
                                  updatedAt: (r["updated_at"] as? String).flatMap(Self.parseDate))
        }
    }

    func upsert(_ s: SupabaseSession, rows: [UploadRow]) async throws {
        guard !rows.isEmpty else { return }
        let body = try JSONEncoder().encode(rows)
        _ = try await send("POST", "/rest/v1/sync_items?on_conflict=user_id,kind", body: body, token: s.accessToken,
                           prefer: "resolution=merge-duplicates,return=minimal")
    }

    func deleteKinds(_ s: SupabaseSession, kinds: [String]) async throws {
        guard !kinds.isEmpty else { return }
        _ = try await send("DELETE", "/rest/v1/sync_items?kind=in.(\(kinds.joined(separator: ",")))", token: s.accessToken,
                           prefer: "return=minimal")
    }

    func fetchKeyCheck(_ s: SupabaseSession) async throws -> String? {
        let d = try await send("GET", "/rest/v1/sync_keys?select=key_check", token: s.accessToken)
        let rows = try JSONSerialization.jsonObject(with: d) as? [[String: Any]]
        return rows?.first?["key_check"] as? String
    }

    func putKeyCheck(_ s: SupabaseSession, keyCheck: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: [["user_id": s.userID, "key_check": keyCheck]])
        _ = try await send("POST", "/rest/v1/sync_keys?on_conflict=user_id", body: body, token: s.accessToken,
                           prefer: "resolution=merge-duplicates,return=minimal")
    }

    /// Deletes every synced row, the key check and the sign-in account itself (SQL function).
    func deleteAccount(_ s: SupabaseSession) async throws {
        _ = try await send("POST", "/rest/v1/rpc/delete_my_account", json: [:], token: s.accessToken)
    }

    // MARK: Plumbing

    private func send(_ method: String, _ path: String, json: [String: Any]? = nil, body: Data? = nil,
                      token: String? = nil, prefer: String? = nil) async throws -> Data {
        guard let url = URL(string: config.url.absoluteString + path) else { throw ClientError.badResponse }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = method
        req.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token ?? config.anonKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let prefer { req.setValue(prefer, forHTTPHeaderField: "Prefer") }
        if let json { req.httpBody = try JSONSerialization.data(withJSONObject: json) }
        if let body { req.httpBody = body }
        if req.httpBody != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, resp) = try await urlSession.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ClientError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.http(http.statusCode, Self.message(data))
        }
        return data
    }

    /// The human part of a Supabase error body.
    static func message(_ data: Data) -> String {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        for k in ["msg", "message", "error_description", "error"] {
            if let m = o[k] as? String, !m.isEmpty { return m }
        }
        return ""
    }

    /// Postgres timestamptz ("2026-11-25T23:41:02.123456+00:00"), with or without fractions.
    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        // Drop the fraction (some formatters reject 6 digits) and try again.
        var t = s
        if let dot = t.firstIndex(of: ".") {
            let rest = t[dot...].drop(while: { $0 == "." || $0.isNumber })
            t = String(t[..<dot]) + rest
        }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: t)
    }
}
