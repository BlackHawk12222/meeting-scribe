// LegacyMigration.swift
// One-time carry-over from builds that used an older bundle identifier.
//
// Scribe's bundle id changed to com.blackhawk12222.Scribe. macOS keys a few things
// on the bundle id, so on the first launch of the new id we copy them over:
//   • Settings (UserDefaults): copied from any older "<prefix>.Scribe" preferences
//     domain, only for keys the new id doesn't have yet.
//   • The GitHub sync token (Keychain): read from an older "<prefix>.Scribe.github"
//     item, if macOS lets us (it may ask once), and saved under the new service.
// Meetings, voices and dictations are NOT affected: they live in
// ~/Library/Application Support/Scribe/, which doesn't depend on the bundle id.
// Microphone / Accessibility permissions can't be carried over; macOS asks again.
//
// Old ids are discovered by pattern (they all end in ".Scribe"), so no old id is
// hard-coded here.

import Foundation
import Security

enum LegacyMigration {
    private static let doneKey = "migratedLegacyBundleID"

    /// Call once, early at launch, before settings are read.
    static func runOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defer { defaults.set(true, forKey: doneKey) }
        let current = Bundle.main.bundleIdentifier ?? ""
        for old in oldBundleIDs(current: current) {
            copySettings(from: old)
            copyGitHubToken(fromService: old + ".github")
        }
    }

    /// Bundle ids of earlier Scribe builds that left preferences on this Mac.
    static func oldBundleIDs(current: String) -> [String] {
        let prefs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: prefs.path)) ?? []
        return files.compactMap { name -> String? in
            guard name.hasSuffix(".Scribe.plist") else { return nil }
            let id = String(name.dropLast(".plist".count))
            return id == current ? nil : id
        }.sorted()
    }

    private static func copySettings(from oldID: String) {
        guard let old = UserDefaults.standard.persistentDomain(forName: oldID) else { return }
        let defaults = UserDefaults.standard
        for (key, value) in old where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }

    private static func copyGitHubToken(fromService oldService: String) {
        guard GitHubSync.readToken() == nil else { return }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: oldService,
                                kSecAttrAccount as String: "token",
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, !data.isEmpty else { return }
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: GitHubSync.keychainService,
                                  kSecAttrAccount as String: "token",
                                  kSecValueData as String: data]
        SecItemAdd(add as CFDictionary, nil)
    }

    /// Old sandboxed "Meeting Scribe" data folders (any bundle-id prefix).
    static func oldMeetingScribeContainers() -> [URL] {
        let containers = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: containers.path)) ?? []
        return names.filter { $0.hasSuffix(".MeetingScribe") }.sorted().map {
            containers.appendingPathComponent($0)
                .appendingPathComponent("Data/Library/Application Support/MeetingScribe", isDirectory: true)
        }
    }
}
