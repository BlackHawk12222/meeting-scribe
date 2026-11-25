// SyncCrypto.swift
// 0.7.3.2 Accounts: end-to-end encryption for everything Scribe syncs.
//
//  • One 256-bit key per account, made on the first Mac that signs in (CryptoKit SymmetricKey).
//    It lives in this Mac's Keychain. The server never sees it.
//  • Every synced item is sealed with AES-GCM (random 96-bit nonce, 128-bit tag). The account id
//    and the item's kind are bound in as associated data, so a row can't be swapped onto another
//    account or another kind without failing to open.
//  • A recovery key (the same 32 bytes written as 52 Crockford base-32 characters in groups of 4)
//    is shown once for the user to save. A second Mac needs it to read the data.
//  • The server keeps a "key check" (a fixed phrase sealed with the key) so a typed recovery key
//    can be checked before anything is downloaded. It tells the server nothing about the key.
// Wire format of a sealed item: "v1." + base64(nonce ‖ ciphertext ‖ tag).

import Foundation
import CryptoKit

enum SyncCrypto {
    enum CryptoError: LocalizedError {
        case badFormat, sealFailed
        var errorDescription: String? {
            switch self {
            case .badFormat: return "That synced item isn't in a format this version of Scribe can read."
            case .sealFailed: return "Couldn't encrypt that item."
            }
        }
    }

    static let prefix = "v1."
    static let keyCheckKind = "key_check"
    static let keyCheckPlaintext = Data("scribe-key-check-v1".utf8)

    static func newKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    static func keyData(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

    /// Associated data: binds a sealed item to one account and one kind.
    static func aad(user: String, kind: String) -> Data { Data("scribe-sync-v1|\(user.lowercased())|\(kind)".utf8) }

    static func seal(_ plaintext: Data, key: SymmetricKey, user: String, kind: String) throws -> String {
        let box = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(), authenticating: aad(user: user, kind: kind))
        guard let combined = box.combined else { throw CryptoError.sealFailed }
        return prefix + combined.base64EncodedString()
    }

    static func open(_ sealed: String, key: SymmetricKey, user: String, kind: String) throws -> Data {
        guard sealed.hasPrefix(prefix), let data = Data(base64Encoded: String(sealed.dropFirst(prefix.count))) else {
            throw CryptoError.badFormat
        }
        let box = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(box, using: key, authenticating: aad(user: user, kind: kind))
    }

    /// The key check stored on the server.
    static func keyCheck(key: SymmetricKey, user: String) throws -> String {
        try seal(keyCheckPlaintext, key: key, user: user, kind: keyCheckKind)
    }

    /// true when `key` is the account's key.
    static func verify(key: SymmetricKey, keyCheck: String, user: String) -> Bool {
        (try? open(keyCheck, key: key, user: user, kind: keyCheckKind)) == keyCheckPlaintext
    }

    // MARK: Recovery key

    /// Crockford base 32: no I, L, O, U (so 1/I/L and 0/O can't be confused).
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// "7M2Q-9XKD-…" (13 groups of 4).
    static func recoveryKey(_ key: SymmetricKey) -> String {
        let bytes = [UInt8](keyData(key))
        var out: [Character] = []
        var buffer = 0, bits = 0
        for b in bytes {
            buffer = (buffer << 8) | Int(b)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(buffer >> (bits - 5)) & 31])
                bits -= 5
            }
            buffer &= (1 << bits) - 1
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
        var groups: [String] = []
        var i = 0
        while i < out.count {
            groups.append(String(out[i..<min(i + 4, out.count)]))
            i += 4
        }
        return groups.joined(separator: "-")
    }

    /// Reads a typed or pasted recovery key (any case, spaces or dashes, O→0, I/L→1). nil = not a key.
    static func parseRecoveryKey(_ text: String) -> SymmetricKey? {
        var values: [Int] = []
        for ch in text.uppercased() {
            if ch == "-" || ch == " " || ch == "\n" || ch == "\t" { continue }
            let c: Character = ch == "O" ? "0" : (ch == "I" || ch == "L") ? "1" : ch
            guard let v = alphabet.firstIndex(of: c) else { return nil }
            values.append(v)
        }
        guard values.count == 52 else { return nil }
        var bytes: [UInt8] = []
        var buffer = 0, bits = 0
        for v in values {
            buffer = (buffer << 5) | v
            bits += 5
            if bits >= 8 {
                bytes.append(UInt8((buffer >> (bits - 8)) & 0xFF))
                bits -= 8
                buffer &= (1 << bits) - 1
            }
        }
        // 52 × 5 = 260 bits: 32 bytes + 4 padding bits, which must be zero.
        guard bytes.count == 32, buffer == 0 else { return nil }
        return SymmetricKey(data: Data(bytes))
    }
}
