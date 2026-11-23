// Vocabulary.swift
// Your personal word list (Settings › Vocabulary): names and terms the speech model doesn't
// know how to spell — "Onshape", "SwiftUI", "VEX V5"…
//
// Two layers, both conservative (a wrong "fix" is worse than a miss):
//  1. TEXT pass (always on, < 1 ms): spoken spellings of each term become the term.
//     • exact words in any case        "figma" → "Figma", "github" → "GitHub"
//     • split / spaced-out spellings   "on shape" → "Onshape", "swift ui" → "SwiftUI", "c a d" → "CAD"
//     • spoken digits                  "v five" → "V5"
//     • built-in sound-alikes for the defaults ("x code" → "Xcode", "git hub" → "GitHub")
//     • near-misses only for long terms (6+ letters), same first letter, at most 1 typo
//       (2 for 9+ letters) and ONLY if the heard word is not a real English word
//       (checked against macOS's /usr/share/dict/words).
//     • terms that are also everyday words ("Notion", "Scribe") only change after words like
//       "in/on/to/from/open/use/with" ("open notion" → "open Notion"; "the notion that…" stays).
//  2. ACOUSTIC pass (optional, Settings › Vocabulary): FluidAudio's CTC keyword spotter
//     (a 100 MB Parakeet CTC 110M helper model) checks each term against the AUDIO and
//     swaps in the term only when the sound matches better than what was transcribed.
//     See SpeechEngine.loadVocabularyBoost.

import Foundation

struct VocabularyTerm: Hashable, Sendable {
    var text: String
    var aliases: [String] = []
    /// Also an everyday English word: don't capitalize after an article ("the notion").
    var commonWord = false
}

enum Vocabulary {
    static let key = "vocabularyTerms"
    static let boostKey = "vocabularyAcoustic"

    /// Common terms (editable in Settings › Vocabulary).
    static let defaults = ["VEX", "V5", "CAD", "Onshape", "Figma", "Notion", "SwiftUI", "Xcode",
                           "GitHub", "Scribe"]

    /// Extra spoken spellings for the default terms (lowercase).
    static let builtInAliases: [String: [String]] = [
        "VEX": ["vex", "vecs", "vexx"],
        "V5": ["v five", "v 5", "v-5", "vee five", "v. five", "v. 5"],
        "CAD": ["cad", "c a d"],
        "Onshape": ["on shape", "on-shape", "onshape", "on shapes"],
        "Figma": ["figma", "fig ma", "figmah"],
        "SwiftUI": ["swift ui", "swift u i", "swift you i", "swift u.i.", "swiftui", "swift-ui"],
        "Xcode": ["x code", "xcode", "x-code", "ex code", "excode"],
        "GitHub": ["github", "git hub", "git-hub", "get hub", "githubs"],
    ]
    static let commonWords: Set<String> = ["notion", "scribe"]

    /// The user's list (defaults until they edit it).
    static var words: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? defaults }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Acoustic matching with the helper model (Settings › Vocabulary). Default on.
    static var acousticBoost: Bool { UserDefaults.standard.object(forKey: boostKey) as? Bool ?? true }

    static var terms: [VocabularyTerm] { terms(from: words) }

    static func terms(from list: [String]) -> [VocabularyTerm] {
        var seen = Set<String>()
        return list.compactMap { raw in
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, seen.insert(t.lowercased()).inserted else { return nil }
            return VocabularyTerm(text: t, aliases: builtInAliases[t] ?? [],
                                  commonWord: commonWords.contains(t.lowercased()))
        }
    }

    // MARK: - Text pass

    struct Rule {
        let regex: NSRegularExpression
        let replacement: String
        let commonWord: Bool
    }

    /// Spoken forms of a term (lowercase), generated from its spelling.
    static func spokenForms(_ term: VocabularyTerm) -> [String] {
        let t = term.text
        var forms = Set(term.aliases.map { $0.lowercased() })
        forms.insert(t.lowercased())
        // "SwiftUI" → "swift ui", "GitHub" → "git hub", "iPhone" stays (lowercase start).
        var split = ""
        let chars = Array(t)
        for (i, c) in chars.enumerated() {
            if i > 0, c.isUppercase, chars[i - 1].isLowercase { split += " " }
            if i > 0, c.isUppercase, i + 1 < chars.count, chars[i + 1].isLowercase, chars[i - 1].isUppercase { split += " " }
            split.append(c)
        }
        forms.insert(split.lowercased())
        // "CAD" → "c a d" (acronyms 2-5 letters).
        if t.count >= 2, t.count <= 5, t.allSatisfy({ $0.isUppercase && $0.isLetter }) {
            forms.insert(t.lowercased().map(String.init).joined(separator: " "))
        }
        // "V5" → "v five"; "3D" → "three d".
        let digitWords = ["0": "zero", "1": "one", "2": "two", "3": "three", "4": "four", "5": "five",
                          "6": "six", "7": "seven", "8": "eight", "9": "nine"]
        if t.contains(where: \.isNumber), t.count <= 6 {
            var spoken: [String] = []
            for c in t.lowercased() {
                if let w = digitWords[String(c)] { spoken.append(w) } else if c.isLetter { spoken.append(String(c)) }
            }
            forms.insert(spoken.joined(separator: " "))
        }
        // Multi-word terms: also the words run together ("grandforks").
        return forms.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
    }

    nonisolated(unsafe) private static var cache: (list: [VocabularyTerm], rules: [Rule])?
    private static let lock = NSLock()

    static func rules(for terms: [VocabularyTerm]) -> [Rule] {
        lock.lock(); defer { lock.unlock() }
        if let c = cache, c.list == terms { return c.rules }
        var out: [Rule] = []
        // Longest terms first, so "VEX V5" wins over a shorter term inside it.
        for term in terms.sorted(by: { $0.text.count > $1.text.count }) {
            let forms = spokenForms(term).map { form -> String in
                // Spaces/hyphens/dots between parts are interchangeable; punctuation is escaped.
                form.split(whereSeparator: { $0 == " " || $0 == "-" })
                    .map { NSRegularExpression.escapedPattern(for: String($0)) }
                    .joined(separator: "[\\s\\-]+")
            }
            let pattern = "(?i)(?<![\\w'’])(?:" + forms.joined(separator: "|") + ")(?![\\w’]|'(?!s\\b))"
            if let re = try? NSRegularExpression(pattern: pattern) {
                out.append(Rule(regex: re, replacement: term.text, commonWord: term.commonWord))
            }
        }
        cache = (terms, out)
        return out
    }

    /// An everyday-word term ("notion") becomes the app name only right after one of these.
    static let appContext: Set<String> = ["in", "into", "on", "onto", "to", "from", "open", "opened", "opening",
                                          "use", "used", "using", "with", "at", "via", "through", "inside", "check"]

    /// Apply the list to `text`. Pure and fast (regexes are cached per list).
    static func apply(_ text: String, terms: [VocabularyTerm] = Vocabulary.terms) -> String {
        guard !terms.isEmpty, !text.isEmpty else { return text }
        var s = text
        for rule in rules(for: terms) {
            let ns = s as NSString
            let matches = rule.regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            var result = ""
            var last = 0
            for m in matches {
                let found = ns.substring(with: m.range)
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                var keep = false
                if rule.commonWord {
                    // "the notion that" / "a scribe" stay everyday words; "in notion" → "in Notion".
                    let before = ns.substring(to: m.range.location)
                    let prev = before.split(whereSeparator: { !$0.isLetter }).last.map { $0.lowercased() } ?? ""
                    if !appContext.contains(prev) { keep = true }
                }
                result += keep ? found : rule.replacement
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            s = result
        }
        return fuzzy(s, terms: terms)
    }

    // MARK: - Near-misses (long single-word terms only)

    /// macOS's word list, to avoid "fixing" real words. Loaded once, lazily (~0.1 s).
    nonisolated(unsafe) private static var dictionary: Set<String>?
    nonisolated(unsafe) static var dictionaryPath = "/usr/share/dict/words"
    static func englishWords() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        if let d = dictionary { return d }
        let text = (try? String(contentsOfFile: dictionaryPath, encoding: .utf8)) ?? ""
        let d = Set(text.split(separator: "\n").map { $0.lowercased() })
        dictionary = d
        return d
    }
    static func preload() { _ = englishWords() }

    static func fuzzy(_ text: String, terms: [VocabularyTerm]) -> String {
        let candidates = terms.filter { !$0.text.contains(" ") && $0.text.count >= 6 && $0.text.allSatisfy(\.isLetter) }
        guard !candidates.isEmpty else { return text }
        let dict = englishWords()
        guard !dict.isEmpty else { return text }           // no word list: no guessing
        var out = ""
        var word = ""
        func flush() {
            defer { word = "" }
            guard word.count >= 5 else { out += word; return }
            let lw = word.lowercased()
            if dict.contains(lw) || candidates.contains(where: { $0.text == word }) { out += word; return }
            for t in candidates {
                let lt = t.text.lowercased()
                // Same word in another case is the exact pass's job (it knows "the notion" rules).
                guard lt != lw, lt.first == lw.first, abs(lt.count - lw.count) <= 2 else { continue }
                let maxD = lt.count >= 9 ? 2 : 1
                if editDistance(lw, lt, limit: maxD) <= maxD { out += t.text; return }
            }
            out += word
        }
        for ch in text {
            if ch.isLetter { word.append(ch) } else { flush(); out.append(ch) }
        }
        flush()
        return out
    }

    /// Damerau-Levenshtein (optimal string alignment) with an early exit.
    static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev2 = [Int](repeating: 0, count: y.count + 1)
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [i] + [Int](repeating: 0, count: y.count)
            var rowMin = cur[0]
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                if i > 1, j > 1, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] { cur[j] = min(cur[j], prev2[j - 2] + 1) }
                rowMin = min(rowMin, cur[j])
            }
            if rowMin > limit { return limit + 1 }
            prev2 = prev
            prev = cur
        }
        return prev[y.count]
    }
}
