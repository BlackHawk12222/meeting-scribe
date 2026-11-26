// FixLearner.swift
// 0.7.3 "Learn from my fixes". When you edit a dictation (Dictation › History) or a meeting
// transcript line, the old and new words are compared (a word diff, any length of text):
//  • the same wrong → right fix seen twice is added to the Dictionary as a replacement;
//  • a fix whose right side is a capitalized name (not an ordinary English word) is learned
//    after one time, and the name also goes into Vocabulary ("your words");
//  • each learned item shows a "Learned: X → Y" toast with Undo, and is listed in
//    Settings › Vocabulary › Learned from your fixes, where it can be removed.
// Undo / remove takes back exactly what was added and stops that same fix from being re-learned.
// Nothing here retrains the speech model: it changes the Dictionary and Vocabulary lists that the
// text pass applies after transcription.
// 0.7.6: the learning moved to Engine/Learning.swift (FixUps). This file keeps the word diff, the
// name check, the "don't learn again" list and the 0.7.3 data types (read once to migrate).

import Foundation

struct LearnedFix: Codable, Hashable, Identifiable {
    var id = UUID()
    var from: String
    var to: String
    var date = Date()
    /// What this item added (removed again on Undo).
    var addedReplacement = false
    var addedWords: [String] = []
    var isName = false

    var label: String { "\(from) → \(to)" }
}

enum FixLearner {
    static let countsKey = "learnedFixCounts"
    static let itemsKey = "learnedFixes"
    static let blockedKey = "learnedFixBlocked"
    /// Same wrong → right fix this many times before it is learned (names: once).
    static let repeatsNeeded = 2

    struct Hunk: Hashable { var from: String; var to: String }

    // MARK: Diff

    /// Words with their surrounding punctuation stripped (inner apostrophes/hyphens kept).
    static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace }).map { w in
            String(w).trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
        }.filter { !$0.isEmpty }
    }

    /// Replaced word runs between old and new text (Myers diff on words; any text length).
    /// Pure insertions or deletions are not fixes; neither are punctuation-only changes.
    static func hunks(old: String, new: String) -> [Hunk] {
        let a = words(old), b = words(new)
        let diff = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for c in diff {
            switch c {
            case .remove(let o, _, _): removed.insert(o)
            case .insert(let o, _, _): inserted.insert(o)
            }
        }
        var out: [Hunk] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            let ri = i < a.count && removed.contains(i), ij = j < b.count && inserted.contains(j)
            if !ri && !ij {
                i += 1; j += 1
                continue
            }
            var from: [String] = [], to: [String] = []
            while i < a.count && removed.contains(i) { from.append(a[i]); i += 1 }
            while j < b.count && inserted.contains(j) { to.append(b[j]); j += 1 }
            guard !from.isEmpty, !to.isEmpty else { continue }
            let f = from.joined(separator: " "), t = to.joined(separator: " ")
            if f != t { out.append(Hunk(from: f, to: t)) }
        }
        return out
    }

    /// "Priya", "Onshape", "Gita Ramos": every word starts with a capital, and it isn't an
    /// ordinary English word (so "The" at a sentence start doesn't count).
    static func isName(_ s: String, dictionary: Set<String> = Vocabulary.englishWords()) -> Bool {
        let parts = s.split(separator: " ").map(String.init)
        guard !parts.isEmpty else { return false }
        for p in parts {
            guard let first = p.first, first.isUppercase, p.contains(where: { $0.isLetter }) else { return false }
        }
        if parts.count == 1, !dictionary.isEmpty, dictionary.contains(parts[0].lowercased()) { return false }
        return true
    }

    // MARK: Learning

    static func key(_ h: Hunk) -> String { h.from.lowercased() + "\u{1F}" + h.to }

    static var counts: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: countsKey) as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: countsKey) }
    }
    static var blocked: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: blockedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: blockedKey) }
    }
    static var learned: [LearnedFix] {
        get {
            guard let d = UserDefaults.standard.data(forKey: itemsKey) else { return [] }
            return (try? JSONDecoder().decode([LearnedFix].self, from: d)) ?? []
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: itemsKey) }
    }

    // 0.7.6: learning itself moved to FixUps (Engine/Learning.swift): rules need 2 sightings or your
    // approval, never change a common word without approval, and are listed in Settings › Learning.
    // `learned` / `counts` above are read once to migrate what 0.7.3–0.7.5 learned.
}

// MARK: - Corrections kept for a future fine-tune (opt-in, off by default)

/// Settings › Models › "Save my corrections for future training". When on, each corrected dictation
/// or transcript line is kept as an audio clip (16 kHz mono WAV) + a JSON file with the original
/// and corrected text, in ~/Library/Application Support/Scribe/Corrections. Never uploaded.
/// Dictations only keep audio while this is on (Corrections/pending, the newest 200); a dictation
/// made while it was off has no clip, so its correction is skipped.
enum CorrectionStore {
    static let key = "saveCorrections"
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    static let pendingLimit = 200

    static func folder(_ base: URL) -> URL { base.appendingPathComponent("Corrections", isDirectory: true) }
    static func pending(_ base: URL) -> URL { folder(base).appendingPathComponent("pending", isDirectory: true) }

    struct Pair: Codable {
        var id: UUID
        var source: String       // "dictation" or "meeting"
        var original: String
        var corrected: String
        var seconds: Double
        var savedAt: Date
    }

    /// Saved pairs (JSON files next to their WAV).
    static func count(_ base: URL) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder(base), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.count
    }

    /// Minutes of audio saved so far (the `seconds` of every pair), for Settings › Learning.
    static func totalSeconds(_ base: URL) -> Double {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder(base), includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return files.filter { $0.pathExtension == "json" }.reduce(0) { sum, f in
            guard let d = try? Data(contentsOf: f), let p = try? dec.decode(Pair.self, from: d) else { return sum }
            return sum + max(0, p.seconds)
        }
    }
    /// The amount of your own corrected speech a personal model would want (a goal; no model yet).
    static let personalModelGoalMinutes = 60.0

    static func deleteAll(_ base: URL) {
        try? FileManager.default.removeItem(at: folder(base))
    }

    /// While on: keep a dictation's audio until it is corrected (or pushed out by newer ones).
    static func keepPending(_ base: URL, id: UUID, samples: [Float]) {
        guard enabled, !samples.isEmpty else { return }
        let dir = pending(base)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        writeWAV(samples, to: dir.appendingPathComponent("\(id.uuidString).wav"))
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .sorted { ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
                    > ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
        for f in files.dropFirst(pendingLimit) { try? FileManager.default.removeItem(at: f) }
    }

    /// A corrected dictation: move its pending clip in and write the text pair. False = no clip.
    @discardableResult
    static func saveDictation(_ base: URL, id: UUID, original: String, corrected: String) -> Bool {
        guard enabled else { return false }
        let src = pending(base).appendingPathComponent("\(id.uuidString).wav")
        guard FileManager.default.fileExists(atPath: src.path) else { return false }
        let pid = UUID()
        let dst = folder(base).appendingPathComponent("\(pid.uuidString).wav")
        try? FileManager.default.removeItem(at: dst)
        guard (try? FileManager.default.copyItem(at: src, to: dst)) != nil else { return false }
        let size = ((try? FileManager.default.attributesOfItem(atPath: dst.path))?[.size] as? Int) ?? 0
        let secs = Double(max(0, size - 44)) / 32_000     // 16 kHz × 2 bytes
        writePair(base, Pair(id: pid, source: "dictation", original: original, corrected: corrected, seconds: secs, savedAt: Date()))
        return true
    }

    /// A corrected meeting line: its stretch of the recording + the text pair.
    @discardableResult
    static func saveClip(_ base: URL, samples: [Float], source: String, original: String, corrected: String) -> Bool {
        guard enabled, !samples.isEmpty else { return false }
        let pid = UUID()
        try? FileManager.default.createDirectory(at: folder(base), withIntermediateDirectories: true)
        guard writeWAV(samples, to: folder(base).appendingPathComponent("\(pid.uuidString).wav")) else { return false }
        writePair(base, Pair(id: pid, source: source, original: original, corrected: corrected,
                             seconds: Double(samples.count) / 16_000, savedAt: Date()))
        return true
    }

    private static func writePair(_ base: URL, _ p: Pair) {
        try? FileManager.default.createDirectory(at: folder(base), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(p) { try? d.write(to: folder(base).appendingPathComponent("\(p.id.uuidString).json"), options: .atomic) }
    }

    /// 16 kHz mono 16-bit PCM WAV.
    @discardableResult
    static func writeWAV(_ samples: [Float], to url: URL, rate: Int = 16_000) -> Bool {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let dataBytes = UInt32(samples.count * 2)
        d.append("RIFF".data(using: .ascii)!); u32(36 + dataBytes); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(dataBytes)
        d.reserveCapacity(d.count + samples.count * 2)
        for s in samples {
            var v = Int16(max(-1, min(1, s)) * 32767).littleEndian
            d.append(Data(bytes: &v, count: 2))
        }
        return (try? d.write(to: url, options: .atomic)) != nil
    }
}
