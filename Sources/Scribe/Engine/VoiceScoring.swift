// VoiceScoring.swift
// Scores a transcript against what was read, two ways (Test my voice + the voice benchmark):
//  • Word errors (WER): lowercase words, punctuation ignored — did it hear the right WORDS?
//  • Formatting errors: the same, but a word only counts as right if its capitals AND the
//    punctuation stuck to it match too ("Friday." vs "friday," = 1 error). Also split out:
//    capital-letter mistakes on correctly heard words, and punctuation F1 (. , ? ! : ;).

import Foundation

struct VoiceScore: Sendable {
    var refWords = 0
    var wordEdits = 0            // substitutions + deletions + insertions, normalized words
    var formatEdits = 0          // same on case-sensitive tokens with punctuation attached
    var matchedWords = 0         // words heard right (normalized)
    var capErrors = 0            // of those: capitalization differs
    var punctRef = 0, punctHyp = 0, punctHit = 0

    var wer: Double { refWords == 0 ? 0 : Double(wordEdits) / Double(refWords) }
    var formattedErrorRate: Double { refWords == 0 ? 0 : Double(formatEdits) / Double(refWords) }
    var capErrorRate: Double { matchedWords == 0 ? 0 : Double(capErrors) / Double(matchedWords) }
    var punctF1: Double {
        let p = punctHyp == 0 ? (punctRef == 0 ? 1 : 0) : Double(punctHit) / Double(punctHyp)
        let r = punctRef == 0 ? 1 : Double(punctHit) / Double(punctRef)
        return p + r == 0 ? 0 : 2 * p * r / (p + r)
    }

    static func + (a: VoiceScore, b: VoiceScore) -> VoiceScore {
        var c = a
        c.refWords += b.refWords; c.wordEdits += b.wordEdits; c.formatEdits += b.formatEdits
        c.matchedWords += b.matchedWords; c.capErrors += b.capErrors
        c.punctRef += b.punctRef; c.punctHyp += b.punctHyp; c.punctHit += b.punctHit
        return c
    }
}

enum VoiceScoring {
    private static let punctMarks: Set<Character> = [".", ",", "?", "!", ":", ";"]

    /// One written token: the word as typed (with its capitals) + its punctuation, the bare
    /// lowercase word, and the punctuation mark right after it ("" if none).
    struct Token { var raw: String; var norm: String; var punct: String }

    static func tokens(_ text: String) -> [Token] {
        let quotes = CharacterSet(charactersIn: "\"“”‘()[]")
        var out: [Token] = []
        for piece in text.split(whereSeparator: { $0.isWhitespace }) {
            var w = String(piece).trimmingCharacters(in: quotes)
            var p = ""
            while let last = w.last, punctMarks.contains(last) { p = String(last) + p; w.removeLast() }
            w = w.trimmingCharacters(in: quotes)
            let norm = String(w.lowercased().replacingOccurrences(of: "’", with: "'")
                .filter { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "%" || $0 == "$" || $0 == ":" || $0 == "." })
            let mark = String(p.prefix(1))
            if norm.isEmpty {     // a lone "—" or "-": its punctuation belongs to the previous word
                if !mark.isEmpty, !out.isEmpty, out[out.count - 1].punct.isEmpty {
                    out[out.count - 1].punct = mark
                    out[out.count - 1].raw += mark
                }
                continue
            }
            out.append(Token(raw: w + mark, norm: norm, punct: mark))
        }
        return out
    }

    /// Edit distance + the aligned pairs (ref index, hyp index) of words that matched.
    static func align(_ r: [String], _ h: [String]) -> (edits: Int, matches: [(Int, Int)]) {
        let n = r.count, m = h.count
        if n == 0 { return (m, []) }
        if m == 0 { return (n, []) }
        var d = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }
        for i in 1...n {
            for j in 1...m {
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
            }
        }
        var matches: [(Int, Int)] = []
        var i = n, j = m
        while i > 0 && j > 0 {
            if r[i - 1] == h[j - 1] && d[i][j] == d[i - 1][j - 1] {
                matches.append((i - 1, j - 1)); i -= 1; j -= 1
            } else if d[i][j] == d[i - 1][j - 1] + 1 {
                i -= 1; j -= 1
            } else if d[i][j] == d[i - 1][j] + 1 {
                i -= 1
            } else {
                j -= 1
            }
        }
        return (d[n][m], Array(matches.reversed()))
    }

    static func score(reference: String, hypothesis: String) -> VoiceScore {
        let r = tokens(reference), h = tokens(hypothesis)
        var s = VoiceScore()
        s.refWords = r.count
        let aligned = align(r.map(\.norm), h.map(\.norm))
        s.wordEdits = aligned.edits
        s.formatEdits = align(r.map(\.raw), h.map(\.raw)).edits
        s.matchedWords = aligned.matches.count
        for (i, j) in aligned.matches {
            let a = r[i].raw.filter { $0.isLetter || $0.isNumber }
            let b = h[j].raw.filter { $0.isLetter || $0.isNumber }
            if a != b { s.capErrors += 1 }
            if !r[i].punct.isEmpty, r[i].punct == h[j].punct { s.punctHit += 1 }
        }
        s.punctRef = r.filter { !$0.punct.isEmpty }.count
        s.punctHyp = h.filter { !$0.punct.isEmpty }.count
        return s
    }
}
