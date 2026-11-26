// AccountConfig.swift
// 0.7.3.2 Accounts are optional, and off until a backend is configured.
//
// Where the Supabase project URL + anon (public) key come from, first match wins:
//   1. environment SCRIBE_SUPABASE_URL + SCRIBE_SUPABASE_ANON_KEY (local development)
//   2. Supabase.plist in the app bundle (keys SupabaseURL, SupabaseAnonKey). The committed file
//      holds placeholders only; scripts/build.sh fills it from the SUPABASE_URL /
//      SUPABASE_ANON_KEY build secrets when they're set.
// Placeholders, empty values or a non-https URL = not configured → the Profile page shows
// "Accounts coming soon" (disabled) and nothing account-related runs: no network, no Keychain.
// The anon key is public by design (it's in every client); row-level security protects the data.

import Foundation

struct AccountConfig: Equatable {
    var url: URL
    var anonKey: String

    static func load(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) -> AccountConfig? {
        if let c = parse(url: environment["SCRIBE_SUPABASE_URL"], key: environment["SCRIBE_SUPABASE_ANON_KEY"]) { return c }
        guard let path = bundle.path(forResource: "Supabase", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path) as? [String: Any] else { return nil }
        return parse(url: dict["SupabaseURL"] as? String, key: dict["SupabaseAnonKey"] as? String)
    }

    /// nil for empty values, placeholders ("YOUR_…", "$(…)", "<…>") or anything but https.
    static func parse(url: String?, key: String?) -> AccountConfig? {
        guard let u = url?.trimmingCharacters(in: .whitespacesAndNewlines),
              let k = key?.trimmingCharacters(in: .whitespacesAndNewlines),
              !u.isEmpty, !k.isEmpty else { return nil }
        for bad in ["YOUR_", "$(", "<", "PLACEHOLDER", "example"] where u.contains(bad) || k.contains(bad) { return nil }
        guard let parsed = URL(string: u.hasSuffix("/") ? String(u.dropLast()) : u),
              parsed.scheme == "https", parsed.host != nil, k.count >= 20 else { return nil }
        return AccountConfig(url: parsed, anonKey: k)
    }
}
