// Learning.swift
// 0.7.6 "safe" learning: two text steps that run right after the speech model and BEFORE
// clean-up and Style (Dictation.textSteps). Neither retrains the speech model.
//
//  1. Learned fix-ups (FixUps): word or phrase replacements taken from your own edits with a word
//     diff ("teh" → "the", "sweet you eye" → "SwiftUI"). A fix becomes a rule only after the same
//     fix was seen twice, or once you approve it in Settings › Learning. A rule that would change an
//     everyday English word (CommonWords) never turns on by itself: it waits for your approval.
//
//  2. "Boost my words" (WordBoost, Settings › Dictation, on by default): a conservative post-pass
//     that matches each heard word or 2–3 word span against the terms in Settings › Vocabulary by
//     sound (Phonetic, a small Metaphone-style key with alternates) AND spelling (normalized
//     Damerau edit distance ≤ 0.30, ≤ 0.25 when the heard word is in the Mac's dictionary), with the
//     same first letter. It never replaces a common English word, never touches a span that already
//     holds one of your terms, and writes the term exactly as you spelled it ("swift ui" → "SwiftUI").
//     Why not FluidAudio's acoustic CTC boosting? FluidAudio 0.18.3 has it (VocabularyBoostingSession
//     + the 110M CTC helper) and Scribe already wires it as the optional "Also match against the
//     audio" switch, but it needs a 100 MB extra model and raised WER on the CI runner (0.5), so it
//     stays off by default; this text pass is the low-risk default.
//
// scribe.log gets COUNTS only ("learning: fix-ups 1, boost 2"), never text.

import Foundation

// MARK: - Phonetic key

/// A compact Metaphone-style sound key. `keys` gives the primary key and an alternate one
/// (hard "c"/"g", "th" as T, no R after a vowel: "superbase" ≈ "supabase").
enum Phonetic {
    static func keys(_ word: String) -> Set<String> {
        Set([key(word, alt: false), key(word, alt: true)].filter { !$0.isEmpty })
    }

    static func key(_ word: String, alt: Bool) -> String {
        var w = Array(word.lowercased().filter { $0.isASCII && $0.isLetter })
        guard !w.isEmpty else { return "" }
        let start = String(w.prefix(2))
        if ["kn", "gn", "pn", "wr", "ps"].contains(start) { w.removeFirst() }
        let n = w.count
        func at(_ k: Int) -> Character? { k >= 0 && k < n ? w[k] : nil }
        func isVowel(_ c: Character?) -> Bool { c.map { "aeiou".contains($0) } ?? false }
        var out: [Character] = []
        var i = 0
        if w[0] == "x" { out.append("S"); i = 1 } else if n >= 2, w[0] == "w", w[1] == "h" { out.append("W"); i = 2 }
        while i < n {
            let c = w[i], nx = at(i + 1), pv = at(i - 1)
            if let pv, c == pv, c != "c" { i += 1; continue }
            switch c {
            case "a", "e", "i", "o", "u":
                if i == 0 { out.append("A") }
            case "y":
                if isVowel(nx) { out.append("Y") }
            case "b":
                if !(pv == "m" && i == n - 1) { out.append("P") }
            case "c":
                if nx == "h" { out.append(alt ? "K" : "X"); i += 1 }
                else if nx == "i" && at(i + 2) == "a" { out.append(alt ? "K" : "X") }
                else if nx == "i" || nx == "e" || nx == "y" { out.append("S") }
                else if nx == "k" { out.append("K"); i += 1 }
                else { out.append("K") }
            case "d":
                if nx == "g", let a = at(i + 2), "eiy".contains(a) { out.append("J"); i += 1 } else { out.append("T") }
            case "f", "v":
                out.append("F")
            case "g":
                if nx == "h", i > 0, !isVowel(at(i + 2)) { i += 1 }
                else if nx == "n", i + 2 == n || (at(i + 2) == "e" && at(i + 3) == "d" && i + 4 == n) { /* silent */ }
                else if nx == "e" || nx == "i" || nx == "y" { out.append(alt ? "K" : "J") }
                else { out.append("K") }
            case "h":
                if isVowel(nx), !(pv.map({ "csptg".contains($0) }) ?? false) { out.append("H") }
            case "j":
                out.append("J")
            case "k":
                if pv != "c" { out.append("K") }
            case "l": out.append("L")
            case "m": out.append("M")
            case "n": out.append("N")
            case "p":
                if nx == "h" { out.append("F"); i += 1 } else { out.append("P") }
            case "q":
                out.append("K")
            case "r":
                if !(alt && isVowel(pv) && !isVowel(nx)) { out.append("R") }
            case "s":
                if nx == "h" { out.append("X"); i += 1 }
                else if nx == "i", at(i + 2) == "o" || at(i + 2) == "a" { out.append("X") }
                else { out.append("S") }
            case "t":
                if nx == "i", at(i + 2) == "o" || at(i + 2) == "a" { out.append("X") }
                else if nx == "h" { out.append(alt ? "T" : "0"); i += 1 }
                else if nx == "c" && at(i + 2) == "h" { /* "tch": the ch speaks */ }
                else { out.append("T") }
            case "w":
                if isVowel(nx) { out.append("W") }
            case "x":
                out.append("K"); out.append("S")
            case "z":
                out.append("S")
            default:
                break
            }
            i += 1
        }
        var s = ""
        for ch in out where s.last != ch { s.append(ch) }
        return s
    }
}

// MARK: - Boost my words

enum WordBoost {
    static let key = "boostMyWords"
    /// Settings › Dictation › "Boost my words". On by default.
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    /// Max normalized edit distance between the heard text and a term.
    static let maxDistance = 0.30
    /// …when every heard word is a real dictionary word (rarer words: be stricter).
    static let maxDistanceRealWord = 0.25
    /// Fuzzy (non-exact) matches only for terms of at least this many letters.
    static let minFuzzyTermLength = 5
    static let maxSpan = 3

    struct Candidate: Hashable {
        let text: String
        let core: String
        let keys: Set<String>
    }

    /// Terms the pass may write: letters (and spaces) only, not an everyday word themselves.
    static func candidates(_ terms: [VocabularyTerm]) -> [Candidate] {
        terms.compactMap { t in
            guard !t.commonWord, t.text.allSatisfy({ $0.isLetter || $0 == " " }) else { return nil }
            let core = String(t.text.lowercased().filter(\.isLetter))
            guard core.count >= 2, !CommonWords.contains(core) else { return nil }
            return Candidate(text: t.text, core: core, keys: Phonetic.keys(core))
        }
    }

    /// How well the heard words match a term (0 = same spelling), or nil when they must not be replaced.
    static func score(_ words: [String], _ c: Candidate, dict: Set<String>) -> Double? {
        let lw = words.map { $0.lowercased() }
        let joined = lw.joined()
        // The term split up or in another case ("swift ui", "supabase"): always safe.
        if words.count >= 2, joined == c.core { return 0 }
        // Never replace an everyday English word.
        if lw.contains(where: { CommonWords.contains($0) }) { return nil }
        if words.count == 1, joined == c.core { return words[0] == c.text ? nil : 0 }
        guard joined.count >= 4, c.core.count >= minFuzzyTermLength,
              !lw.contains(where: { $0.count < 2 }) else { return nil }
        guard joined.first == c.core.first, abs(joined.count - c.core.count) <= 3 else { return nil }
        let n = max(joined.count, c.core.count)
        let d = Double(Vocabulary.editDistance(joined, c.core, limit: n)) / Double(n)
        let allReal = lw.allSatisfy { Vocabulary.isEnglishWord($0, dict: dict) }
        guard d <= (allReal ? maxDistanceRealWord : maxDistance) else { return nil }
        guard !Phonetic.keys(joined).isDisjoint(with: c.keys) else { return nil }
        return d
    }

    /// Text runs: letters, or anything else.
    static func tokens(_ text: String) -> [String] {
        var toks: [String] = []
        var cur = ""
        var curIsWord = false
        for ch in text {
            let isW = ch.isLetter
            if cur.isEmpty { cur.append(ch); curIsWord = isW }
            else if isW == curIsWord { cur.append(ch) }
            else { toks.append(cur); cur = String(ch); curIsWord = isW }
        }
        if !cur.isEmpty { toks.append(cur) }
        return toks
    }

    static func apply(_ text: String, terms: [VocabularyTerm] = Vocabulary.terms,
                      dict: Set<String>? = nil) -> (text: String, hits: Int) {
        let cands = candidates(terms)
        guard !cands.isEmpty, !text.isEmpty else { return (text, 0) }
        let d = dict ?? Vocabulary.englishWords()
        let exactTerms = Set(terms.map(\.text))
        let termCores = Set(terms.map { String($0.text.lowercased().filter { $0.isLetter || $0.isNumber }) })
        let toks = tokens(text)
        func isWord(_ s: String) -> Bool { s.first?.isLetter ?? false }
        var out = ""
        var hits = 0
        var i = 0
        while i < toks.count {
            guard isWord(toks[i]) else { out += toks[i]; i += 1; continue }
            var best: (score: Double, text: String, last: Int)?
            for n in stride(from: maxSpan, through: 1, by: -1) {
                var idx = [i]
                var k = i
                while idx.count < n, k + 2 < toks.count, (toks[k + 1] == " " || toks[k + 1] == "-"), isWord(toks[k + 2]) {
                    k += 2
                    idx.append(k)
                }
                guard idx.count == n else { continue }
                let words = idx.map { toks[$0] }
                // Never overwrite a term that is already there (or merge it with its neighbours).
                if words.contains(where: { exactTerms.contains($0) }) { continue }
                if n >= 2, words.contains(where: { termCores.contains($0.lowercased()) }) { continue }
                for c in cands {
                    guard let s = score(words, c, dict: d) else { continue }
                    if best == nil || s < best!.score { best = (s, c.text, idx.last!) }
                }
            }
            if let b = best {
                out += b.text
                hits += 1
                i = b.last + 1
            } else {
                out += toks[i]
                i += 1
            }
        }
        return (out, hits)
    }
}

// MARK: - Learned fix-ups

struct FixUpRule: Codable, Hashable, Identifiable {
    var id = UUID()
    var from: String
    var to: String
    var seen = 1
    /// You approved it in Settings › Learning (or it was learned by Scribe 0.7.3–0.7.5).
    var approved = false
    /// Your on/off switch.
    var enabled = true
    var firstSeen = Date()
    var lastSeen = Date()
    /// Names added to Vocabulary when the rule turned on (taken back when it is deleted).
    var addedWords: [String] = []
    var isName = false

    var key: String { FixLearner.key(.init(from: from, to: to)) }
    var label: String { "\(from) → \(to)" }
    /// The heard side contains an everyday English word: never turns on by itself.
    var touchesCommonWord: Bool { FixUps.touchesCommon(from) }
    /// Learned = approved, or seen often enough and safe to apply without asking.
    var learned: Bool { approved || (seen >= FixUps.repeatsNeeded && !touchesCommonWord) }
    var isActive: Bool { enabled && learned }
}

enum FixUps {
    static let key = "fixUpRules"
    static let migratedKey = "fixUpsMigrated076"
    /// The same fix this many times before it turns on by itself (approval: once).
    static let repeatsNeeded = 2
    /// Fixes longer than this (either side) are edits, not word fixes.
    static let maxWords = 3

    static var rules: [FixUpRule] {
        get {
            guard let d = UserDefaults.standard.data(forKey: key) else { return [] }
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            return (try? dec.decode([FixUpRule].self, from: d)) ?? []
        }
        set {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            UserDefaults.standard.set(try? enc.encode(newValue), forKey: key)
        }
    }

    static var learnedRules: [FixUpRule] { rules.filter(\.learned) }
    static var suggestions: [FixUpRule] { rules.filter { !$0.learned } }

    static func touchesCommon(_ s: String) -> Bool {
        FixLearner.words(s).contains { CommonWords.contains($0) }
    }

    /// Record one edit. Returns the rules that just turned on, and new suggestions for names
    /// (both are shown in the toast).
    @discardableResult
    static func record(old: String, new: String) -> [FixUpRule] {
        migrateIfNeeded()
        var list = rules
        let block = FixLearner.blocked
        var out: [FixUpRule] = []
        for raw in FixLearner.hunks(old: old, new: new) {
            let h = sentenceCaseFolded(raw)
            let k = FixLearner.key(h)
            guard !block.contains(k) else { continue }
            guard FixLearner.words(h.from).count <= maxWords, FixLearner.words(h.to).count <= maxWords else { continue }
            let name = FixLearner.isName(h.to)
            // A case-only change of an ordinary word (a sentence start) is not a fix.
            if h.from.lowercased() == h.to.lowercased() && !name { continue }
            if let i = list.firstIndex(where: { $0.key == k }) {
                let was = list[i].learned
                list[i].seen += 1
                list[i].lastSeen = Date()
                if !was && list[i].learned {
                    turnedOn(&list[i])
                    out.append(list[i])
                }
            } else {
                let r = FixUpRule(from: h.from, to: h.to, isName: name)
                list.append(r)
                if name { out.append(r) }
            }
        }
        rules = list
        return out
    }

    /// "Teh robot" → "The robot" at a sentence start is the same fix as "teh" → "the": fold the
    /// capital away unless the right side is a name ("Zorvath" stays).
    static func sentenceCaseFolded(_ h: FixLearner.Hunk) -> FixLearner.Hunk {
        guard let f = h.from.first, let t = h.to.first, f.isUppercase, t.isUppercase, !FixLearner.isName(h.to) else { return h }
        func lowerFirst(_ s: String) -> String { s.prefix(1).lowercased() + s.dropFirst() }
        return FixLearner.Hunk(from: lowerFirst(h.from), to: lowerFirst(h.to))
    }

    /// A name rule that turns on also puts the name into Vocabulary (so the boost and the
    /// acoustic helper know it), as 0.7.3 did.
    private static func turnedOn(_ r: inout FixUpRule) {
        if r.isName, r.addedWords.isEmpty { r.addedWords = Store.addToVocabulary([r.to]) }
    }

    @discardableResult
    static func approve(_ id: UUID) -> FixUpRule? {
        var list = rules
        guard let i = list.firstIndex(where: { $0.id == id }) else { return nil }
        list[i].approved = true
        list[i].enabled = true
        turnedOn(&list[i])
        rules = list
        return list[i]
    }

    static func setEnabled(_ id: UUID, _ on: Bool) {
        var list = rules
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].enabled = on
        rules = list
    }

    /// Delete a rule or dismiss a suggestion: take back what it added, and don't learn it again.
    static func delete(_ id: UUID) {
        var list = rules
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        let r = list.remove(at: i)
        takeBack(r)
        rules = list
        var b = FixLearner.blocked
        b.insert(r.key)
        FixLearner.blocked = b
    }

    /// Settings › Learning › Delete all: every rule and suggestion (they can be learned again).
    static func deleteAll() {
        for r in rules { takeBack(r) }
        rules = []
    }

    private static func takeBack(_ r: FixUpRule) {
        guard !r.addedWords.isEmpty else { return }
        let drop = Set(r.addedWords.map { $0.lowercased() })
        Vocabulary.words = Vocabulary.words.filter { !drop.contains($0.lowercased()) }
    }

    /// Apply the rules that are on: whole words, any case, longest first.
    static func apply(_ text: String, rules list: [FixUpRule]? = nil) -> (text: String, hits: Int) {
        let active = (list ?? rules).filter(\.isActive).sorted { $0.from.count > $1.from.count }
        guard !active.isEmpty, !text.isEmpty else { return (text, 0) }
        var s = text
        var hits = 0
        for r in active {
            let parts = r.from.split(whereSeparator: { $0 == " " }).map { NSRegularExpression.escapedPattern(for: String($0)) }
            guard !parts.isEmpty else { continue }
            let pattern = "(?i)(?<![\\p{L}\\p{N}])" + parts.joined(separator: "[\\s\\-]+") + "(?![\\p{L}\\p{N}])"
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(s.startIndex..., in: s)
            let n = re.numberOfMatches(in: s, range: range)
            guard n > 0 else { continue }
            hits += n
            s = re.stringByReplacingMatches(in: s, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: r.to))
        }
        return (s, hits)
    }

    /// Once, on the first 0.7.6 launch: what 0.7.3–0.7.5 learned (Dictionary replacements + names)
    /// becomes approved rules here, so Settings › Learning can switch them off or delete them, and
    /// their half-counted fixes become suggestions.
    static func migrateIfNeeded() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: migratedKey) else { return }
        d.set(true, forKey: migratedKey)
        var list = rules
        func has(_ k: String) -> Bool { list.contains { $0.key == k } }
        for item in FixLearner.learned {
            let k = FixLearner.key(.init(from: item.from, to: item.to))
            guard !has(k) else { continue }
            if item.addedReplacement {
                for p in DictionaryReplacements.pairs where p.from.caseInsensitiveCompare(item.from) == .orderedSame && p.to == item.to {
                    DictionaryReplacements.remove(p)
                }
            }
            list.append(FixUpRule(from: item.from, to: item.to, seen: repeatsNeeded, approved: true,
                                  firstSeen: item.date, lastSeen: item.date,
                                  addedWords: item.addedWords, isName: item.isName))
        }
        for (k, n) in FixLearner.counts where n > 0 && !has(k) {
            let parts = k.components(separatedBy: "\u{1F}")
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { continue }
            list.append(FixUpRule(from: parts[0], to: parts[1], seen: n, isName: FixLearner.isName(parts[1])))
        }
        rules = list
        d.removeObject(forKey: FixLearner.itemsKey)
        d.removeObject(forKey: FixLearner.countsKey)
    }
}

// MARK: - The step the dictation pipeline calls

enum Learning {
    struct Outcome: Equatable {
        var text: String
        var fixUpHits: Int
        var boostHits: Int
    }

    /// Right after recognition, before clean-up and Style: learned fix-ups, then "Boost my words".
    static func afterRecognition(_ raw: String, rules: [FixUpRule]? = nil,
                                 terms: [VocabularyTerm] = Vocabulary.terms,
                                 boost: Bool = WordBoost.enabled, log: Bool = true) -> Outcome {
        let f = FixUps.apply(raw, rules: rules)
        let b = boost ? WordBoost.apply(f.text, terms: terms) : (text: f.text, hits: 0)
        if log, f.hits + b.hits > 0 { logCounts(fixUps: f.hits, boost: b.hits) }
        return Outcome(text: b.text, fixUpHits: f.hits, boostHits: b.hits)
    }

    /// Counts only. Never the words.
    static func logCounts(fixUps: Int, boost: Int) {
        AppLog.log("learning: dictation fix-ups \(fixUps), boost \(boost)")
    }

    /// At launch: migrate 0.7.3–0.7.5 data once, preload the word list, log the counts.
    static func startup() {
        FixUps.migrateIfNeeded()
        let r = FixUps.rules
        AppLog.log("learning: \(r.filter(\.isActive).count) fix-ups on, \(r.filter { !$0.learned }.count) suggestions, boost \(WordBoost.enabled ? "on" : "off")")
    }
}
