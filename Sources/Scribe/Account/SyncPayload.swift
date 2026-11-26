// SyncPayload.swift
// What an account backs up and syncs, item by item ("kinds"), and how a downloaded item is merged
// into this Mac. Every item is sealed with SyncCrypto before it leaves the Mac.
//
//   dictionary     Dictionary replacements ("heard → written")
//   vocabulary     your words (+ the acoustic-boost switch)
//   learned_fixes  what "Learn from my fixes" learned (+ its counters and Undo blocks)
//   styles         the dictation Style (Natural / Polished / Exact)
//   settings       shortcut, dictation, capsule, meeting and appearance settings
//   people         names in your voice library                      (OFF by default)
//   voiceprints    those people's voice samples (biometric data)      (OFF by default)
// Never synced: audio (recordings, dictation clips, saved corrections), meetings and transcripts,
// dictation history, the profile name and photo.
//
// Merging (v1):
//   • lists (dictionary, vocabulary, learned fixes, people, voiceprints) are UNIONED: nothing on
//     this Mac is dropped. Known limit: a word deleted on one Mac comes back from another.
//   • single values (styles, settings): the cloud copy wins only when it's newer than this Mac's
//     last sync and came from another Mac; otherwise this Mac's values are uploaded.

import Foundation
import CryptoKit

enum SyncKind: String, CaseIterable, Codable {
    case dictionary, vocabulary, learned_fixes, styles, settings, people, voiceprints

    var title: String {
        switch self {
        case .dictionary: return "Dictionary"
        case .vocabulary: return "Vocabulary"
        case .learned_fixes: return "Learned fixes"
        case .styles: return "Styles"
        case .settings: return "Settings"
        case .people: return "People"
        case .voiceprints: return "Voice profiles"
        }
    }

    /// Kinds that are synced unless the user turns them on (biometric / other people's data).
    var optIn: Bool { self == .people || self == .voiceprints }

    /// UserDefaults keys behind the kinds that live there.
    var defaultsKeys: [String] {
        switch self {
        case .dictionary: return [DictionaryReplacements.key]
        case .vocabulary: return [Vocabulary.key, Vocabulary.boostKey]
        case .learned_fixes: return [FixLearner.itemsKey, FixLearner.countsKey, FixLearner.blockedKey]
        case .styles: return [DictationStyle.key]
        case .settings:
            return ["holdKey", "dictationMode", "aiCleanup", "removeFillers", "restoreClipboard", "trailingSpace",
                    "dictationSounds", "doubleTapHandsFree", "pauseWhileThinking", "directInsert",
                    "toggleDisabled", "toggleKeyCode", "toggleModifiers", "toggleLabel",
                    "aiNotes", "noiseCleanup", "showMeetingScroll", "tachysEnabled",
                    "overlayPosition", "appearance", "showInDock"]
        case .people, .voiceprints: return []
        }
    }
}

/// The two opt-in switches. Both OFF unless the user turns them on.
struct SyncOptions: Equatable {
    static let peopleKey = "syncPeople"
    static let voiceprintsKey = "syncVoiceprints"
    var people = false
    var voiceprints = false

    static func load(_ d: UserDefaults = .standard) -> SyncOptions {
        SyncOptions(people: d.object(forKey: peopleKey) as? Bool ?? false,
                    voiceprints: d.object(forKey: voiceprintsKey) as? Bool ?? false)
    }

    func includes(_ k: SyncKind) -> Bool {
        switch k {
        case .people: return people
        case .voiceprints: return voiceprints
        default: return true
        }
    }
    var kinds: [SyncKind] { SyncKind.allCases.filter(includes) }
}

/// A person as synced (no samples).
struct SyncPerson: Codable, Equatable {
    var id: UUID
    var name: String
    var colorIndex: Int
}

/// A person's voice samples as synced (only with "Voice profiles" on).
struct SyncVoiceprint: Codable, Equatable {
    var id: UUID
    var name: String
    var colorIndex: Int
    var samples: [VoiceSample]
}

@MainActor
enum SyncPayload {
    static func jsonEncoder() -> JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }
    static func jsonDecoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }

    // MARK: Collect (this Mac → plaintext items, sealed right after)

    static func collect(store: Store, options: SyncOptions, defaults: UserDefaults = .standard) -> [SyncKind: Data] {
        var out: [SyncKind: Data] = [:]
        for k in options.kinds {
            if let d = plaintext(k, store: store, defaults: defaults) { out[k] = d }
        }
        return out
    }

    static func plaintext(_ k: SyncKind, store: Store, defaults: UserDefaults) -> Data? {
        switch k {
        case .people:
            return try? jsonEncoder().encode(store.people.map { SyncPerson(id: $0.id, name: $0.name, colorIndex: $0.colorIndex) })
        case .voiceprints:
            let list = store.people.filter { !$0.samples.isEmpty }
                .map { SyncVoiceprint(id: $0.id, name: $0.name, colorIndex: $0.colorIndex, samples: $0.samples) }
            return try? jsonEncoder().encode(list)
        default:
            var dict: [String: Any] = [:]
            for key in k.defaultsKeys { if let v = defaults.object(forKey: key) { dict[key] = v } }
            return try? PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
        }
    }

    /// Seal every item. Only these rows go to the server.
    static func rows(_ items: [SyncKind: Data], key: SymmetricKeyBox, user: String, deviceID: String) throws -> [UploadRow] {
        try items.keys.sorted { $0.rawValue < $1.rawValue }.map { k in
            UploadRow(user_id: user, kind: k.rawValue,
                      ciphertext: try SyncCrypto.seal(items[k]!, key: key.key, user: user, kind: k.rawValue),
                      device_id: deviceID)
        }
    }

    // MARK: Apply (downloaded + opened item → this Mac)

    static func apply(_ k: SyncKind, data: Data, remoteWins: Bool, store: Store, defaults: UserDefaults = .standard) {
        switch k {
        case .people:
            guard let list = try? jsonDecoder().decode([SyncPerson].self, from: data) else { return }
            mergePeople(list.map { SyncVoiceprint(id: $0.id, name: $0.name, colorIndex: $0.colorIndex, samples: []) }, store: store)
        case .voiceprints:
            guard let list = try? jsonDecoder().decode([SyncVoiceprint].self, from: data) else { return }
            mergePeople(list, store: store)
        default:
            guard let remote = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return }
            switch k {
            case .dictionary: mergeDictionary(remote, defaults: defaults)
            case .vocabulary: mergeVocabulary(remote, defaults: defaults)
            case .learned_fixes: mergeFixes(remote, defaults: defaults)
            default:
                // styles / settings: single values.
                for key in k.defaultsKeys {
                    guard let v = remote[key] else { continue }
                    if remoteWins || defaults.object(forKey: key) == nil { defaults.set(v, forKey: key) }
                }
            }
        }
    }

    static func mergeDictionary(_ remote: [String: Any], defaults: UserDefaults) {
        let key = DictionaryReplacements.key
        var local = defaults.array(forKey: key) as? [[String]] ?? []
        let have = Set(local.compactMap { $0.first?.lowercased() })
        for pair in remote[key] as? [[String]] ?? [] where pair.count == 2 && !have.contains(pair[0].lowercased()) {
            local.append(pair)
        }
        defaults.set(local, forKey: key)
    }

    static func mergeVocabulary(_ remote: [String: Any], defaults: UserDefaults) {
        let key = Vocabulary.key
        var local = defaults.stringArray(forKey: key) ?? Vocabulary.defaults
        let have = Set(local.map { $0.lowercased() })
        for w in remote[key] as? [String] ?? [] where !have.contains(w.lowercased()) { local.append(w) }
        defaults.set(local, forKey: key)
        if defaults.object(forKey: Vocabulary.boostKey) == nil, let b = remote[Vocabulary.boostKey] {
            defaults.set(b, forKey: Vocabulary.boostKey)
        }
    }

    static func mergeFixes(_ remote: [String: Any], defaults: UserDefaults) {
        // Counters: the higher count wins. Blocks: union. Learned items: union by id.
        var counts = defaults.dictionary(forKey: FixLearner.countsKey) as? [String: Int] ?? [:]
        for (k, v) in remote[FixLearner.countsKey] as? [String: Int] ?? [:] { counts[k] = max(counts[k] ?? 0, v) }
        defaults.set(counts, forKey: FixLearner.countsKey)
        let blocked = Set(defaults.stringArray(forKey: FixLearner.blockedKey) ?? [])
            .union(remote[FixLearner.blockedKey] as? [String] ?? [])
        defaults.set(Array(blocked).sorted(), forKey: FixLearner.blockedKey)
        let dec = JSONDecoder()
        var items = (defaults.data(forKey: FixLearner.itemsKey)).flatMap { try? dec.decode([LearnedFix].self, from: $0) } ?? []
        let remoteItems = (remote[FixLearner.itemsKey] as? Data).flatMap { try? dec.decode([LearnedFix].self, from: $0) } ?? []
        let ids = Set(items.map(\.id))
        for it in remoteItems where !ids.contains(it.id) && !blocked.contains(it.label) { items.append(it) }
        if let d = try? JSONEncoder().encode(items) { defaults.set(d, forKey: FixLearner.itemsKey) }
    }

    /// People by id (a different id with the same name on this Mac is treated as the same person);
    /// samples unioned (same source + same time = same sample).
    static func mergePeople(_ list: [SyncVoiceprint], store: Store) {
        var changed = false
        for r in list {
            let i = store.people.firstIndex { $0.id == r.id }
                ?? store.people.firstIndex { $0.name.caseInsensitiveCompare(r.name) == .orderedSame }
            if let i {
                for s in r.samples where !store.people[i].samples.contains(where: { Self.same($0, s) }) {
                    store.people[i].samples.append(s)
                    changed = true
                }
            } else {
                store.people.append(Person(id: r.id, name: r.name, samples: r.samples, colorIndex: r.colorIndex))
                changed = true
            }
        }
        if changed { store.save() }
    }

    private static func same(_ a: VoiceSample, _ b: VoiceSample) -> Bool {
        a.meetingID == b.meetingID && a.clusterKey == b.clusterKey && abs(a.addedAt.timeIntervalSince(b.addedAt)) < 0.001
    }
}

/// Wraps the key so callers outside this file don't need CryptoKit.
struct SymmetricKeyBox { var key: SymmetricKey }
