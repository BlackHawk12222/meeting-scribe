// SecretStore.swift
// Where the account's secrets live on this Mac: the sign-in session and the sync encryption key.
// The real app uses the macOS Keychain (generic passwords, service com.blackhawk12222.Scribe.account,
// not synchronized to iCloud Keychain). Self-tests and snapshots use the in-memory store so they
// never touch the Keychain.

import Foundation
import Security

protocol SecretStore: AnyObject {
    func data(for name: String) -> Data?
    func set(_ data: Data?, for name: String)
}

final class KeychainSecretStore: SecretStore {
    let service: String
    init(service: String = "com.blackhawk12222.Scribe.account") { self.service = service }

    private func query(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: name,
         kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
    }

    func data(for name: String) -> Data? {
        var q = query(name)
        q[kSecReturnData as String] = kCFBooleanTrue
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    func set(_ data: Data?, for name: String) {
        SecItemDelete(query(name) as CFDictionary)
        guard let data else { return }
        var q = query(name)
        q[kSecValueData as String] = data
        q[kSecAttrLabel as String] = "Scribe account (\(name))"
        SecItemAdd(q as CFDictionary, nil)
    }
}

final class MemorySecretStore: SecretStore {
    private var items: [String: Data] = [:]
    func data(for name: String) -> Data? { items[name] }
    func set(_ data: Data?, for name: String) { items[name] = data }
    var names: [String] { Array(items.keys) }
}
