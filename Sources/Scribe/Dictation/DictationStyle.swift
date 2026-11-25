// DictationStyle.swift
// 0.7.3: the Dictation page's Style presets and the Dictionary's replacements.
//
//  • Natural  = what Scribe already did: filler/false-start cleanup (if "Clean up filler words" is
//               on) and Apple Intelligence polish for longer dictations (if that toggle is on).
//  • Polished = filler cleanup + Apple Intelligence when the Mac has it (same 8 s minimum and
//               1.2 s cap as before), THEN a rule-based polish pass (no model): sentence capitals,
//               end punctuation, "?" on questions, common contractions, a leading "so/okay/well"
//               dropped. Scribe has no local grammar model besides Apple Intelligence, so on Macs
//               without it Polished is rules only.
//  • Exact    = word for word: the speech model's text with only your Dictionary applied.
//
// Replacements ("sweet UI → SwiftUI") run after everything else, whole words, any case.

import Foundation

enum DictationStyle: String, CaseIterable, Identifiable {
    case natural, polished, exact
    var id: String { rawValue }
    static let key = "dictationStyle"
    static var current: DictationStyle {
        DictationStyle(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .natural
    }
    var title: String {
        switch self {
        case .natural: return "Natural"
        case .polished: return "Polished"
        case .exact: return "Exact"
        }
    }
    var detail: String {
        switch self {
        case .natural: return "Light cleanup, keeps your voice"
        case .polished: return "Fixes grammar and flow"
        case .exact: return "Word for word"
        }
    }
    /// A before → after line for the Style card.
    var example: String {
        switch self {
        case .natural: return "“So um, can we move it to Thursday” → the “um” goes, your wording stays."
        case .polished: return "“So um, can we move it to Thursday” → “Can we move it to Thursday?”"
        case .exact: return "“So um, can we move it to Thursday” stays exactly as heard."
        }
    }

    /// What the pipeline gets for this style.
    var useAI: Bool {
        switch self {
        case .natural: return DictationSettings.aiCleanup
        case .polished: return true
        case .exact: return false
        }
    }
    var removeFillers: Bool {
        switch self {
        case .natural: return DictationSettings.removeFillers
        case .polished: return true
        case .exact: return false
        }
    }

    /// The final text for this style. `cleaned` is the pipeline's text, `raw` the model's.
    func finish(cleaned: String, raw: String) -> String {
        let base: String
        switch self {
        case .natural: base = cleaned
        case .polished: base = Self.polish(cleaned)
        case .exact: base = Vocabulary.apply(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return DictionaryReplacements.apply(base)
    }

    // MARK: Rule-based polish (no model)

    private static let questionStarts: Set<String> = [
        "can", "could", "would", "will", "should", "shall", "do", "does", "did", "is", "are", "was", "were",
        "what", "why", "how", "when", "where", "who", "which", "have", "has", "may", "might", "am", "isn't",
        "aren't", "don't", "doesn't", "didn't", "can't", "won't", "wouldn't", "couldn't", "shouldn't",
    ]
    private static let openers: Set<String> = ["so", "okay", "ok", "well", "alright", "right", "anyway"]
    private static let contractions: [String: String] = [
        "dont": "don't", "doesnt": "doesn't", "didnt": "didn't", "cant": "can't", "wont": "won't",
        "isnt": "isn't", "arent": "aren't", "wasnt": "wasn't", "werent": "weren't", "wouldnt": "wouldn't",
        "couldnt": "couldn't", "shouldnt": "shouldn't", "im": "I'm", "ive": "I've", "youre": "you're",
        "theyre": "they're", "thats": "that's", "whats": "what's", "hasnt": "hasn't",
        "havent": "haven't",
    ]

    static func polish(_ input: String) -> String {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return s }
        // Contractions written without the apostrophe (whole words only).
        var words = s.components(separatedBy: " ")
        for i in words.indices {
            let w = words[i]
            let core = w.trimmingCharacters(in: .punctuationCharacters)
            guard !core.isEmpty, let fix = contractions[core.lowercased()] else { continue }
            let capital = core.first?.isUppercase == true && fix.first?.isLowercase == true
            let fixed: String = capital ? fix.prefix(1).uppercased() + String(fix.dropFirst()) : fix
            words[i] = w.replacingOccurrences(of: core, with: fixed)
        }
        s = words.joined(separator: " ")
        // Sentence by sentence: drop a leading "so/okay/well," opener, capitalize, end punctuation.
        var out: [String] = []
        for var sentence in splitSentences(s) {
            sentence = sentence.trimmingCharacters(in: .whitespaces)
            guard !sentence.isEmpty else { continue }
            var parts = sentence.components(separatedBy: " ")
            if parts.count > 3, let first = parts.first {
                let bare = first.trimmingCharacters(in: .punctuationCharacters).lowercased()
                if openers.contains(bare) { parts.removeFirst() }
            }
            sentence = parts.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
            guard !sentence.isEmpty else { continue }
            sentence = sentence.prefix(1).uppercased() + sentence.dropFirst()
            let firstWord = parts.first.map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() } ?? ""
            let isQuestion = questionStarts.contains(firstWord)
            if let last = sentence.last, ".!?".contains(last) {
                if isQuestion && last == "." { sentence = String(sentence.dropLast()) + "?" }
            } else if let last = sentence.last, last == "," || last == ";" || last == ":" {
                sentence = String(sentence.dropLast()) + (isQuestion ? "?" : ".")
            } else {
                sentence += isQuestion ? "?" : "."
            }
            out.append(sentence)
        }
        s = out.joined(separator: " ")
        // Tidy: doubled punctuation and spaces.
        s = s.replacingOccurrences(of: " ,", with: ",").replacingOccurrences(of: ",,", with: ",")
            .replacingOccurrences(of: "..", with: ".").replacingOccurrences(of: "  ", with: " ")
        return s
    }

    /// Splits after . ! ? followed by a space (keeps the punctuation).
    private static func splitSentences(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        let chars = Array(s)
        for (i, c) in chars.enumerated() {
            cur.append(c)
            if ".!?".contains(c), i + 1 < chars.count, chars[i + 1] == " " {
                out.append(cur)
                cur = ""
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}

/// The Dictionary's "heard → written" replacements (Dictation page › Dictionary,
/// Settings › Vocabulary). Plain words live in Vocabulary.words, as before.
enum DictionaryReplacements {
    static let key = "dictionaryReplacements"

    struct Pair: Hashable, Identifiable {
        var from: String
        var to: String
        var id: String { from.lowercased() }
    }

    static var pairs: [Pair] {
        get {
            let raw = UserDefaults.standard.array(forKey: key) as? [[String]] ?? []
            return raw.compactMap { $0.count == 2 ? Pair(from: $0[0], to: $0[1]) : nil }
        }
        set {
            UserDefaults.standard.set(newValue.map { [$0.from, $0.to] }, forKey: key)
        }
    }

    /// "sweet UI -> SwiftUI" / "sweet UI → SwiftUI" → a pair; anything else → nil.
    static func parse(_ text: String) -> Pair? {
        for sep in ["→", "->", "=>"] {
            let parts = text.components(separatedBy: sep)
            if parts.count == 2 {
                let a = parts[0].trimmingCharacters(in: .whitespaces), b = parts[1].trimmingCharacters(in: .whitespaces)
                if !a.isEmpty, !b.isEmpty { return Pair(from: a, to: b) }
            }
        }
        return nil
    }

    static func add(_ p: Pair) {
        var list = pairs.filter { $0.id != p.id }
        list.append(p)
        pairs = list
    }

    static func remove(_ p: Pair) { pairs = pairs.filter { $0.id != p.id } }

    /// Whole-word, case-insensitive replacement of every pair.
    static func apply(_ text: String, pairs list: [Pair] = DictionaryReplacements.pairs) -> String {
        var s = text
        for p in list {
            let pattern = "(?i)(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: p.from) + "(?![\\p{L}\\p{N}])"
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s),
                                            withTemplate: NSRegularExpression.escapedTemplate(for: p.to))
        }
        return s
    }
}
