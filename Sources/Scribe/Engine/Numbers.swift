// Numbers.swift
// Spoken numbers → digits, only where it's obvious (rule-based, microseconds).
//   "twenty five"           → "25"         (compound numbers, and anything 10 or more)
//   "one hundred and five"  → "105"
//   "twenty five percent"   → "25%"        "five percent" → "5%"
//   "fifty dollars"         → "$50"        "three pm" → "3 PM"
// Left alone: small numbers on their own ("one of us", "two ideas", "no one"), which read
// better as words, and anything ambiguous.

import Foundation

enum Numbers {
    static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    static let tens: [String: Int] = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
                                      "seventy": 70, "eighty": 80, "ninety": 90]
    static let scales: [String: Int] = ["hundred": 100, "thousand": 1000, "million": 1_000_000]

    static func isNumberWord(_ w: String) -> Bool {
        units[w] != nil || tens[w] != nil || scales[w] != nil
    }

    /// Parse a run of number words ("twenty five", "one hundred five"). nil if it isn't one number.
    static func value(_ words: [String]) -> Int? {
        var total = 0, current = 0
        var lastWasTens = false, lastWasUnit = false, any = false
        for w in words {
            if let u = units[w] {
                if lastWasUnit { return nil }                         // "five six" is two numbers
                if lastWasTens, u >= 10 { return nil }               // "twenty twelve"
                current += u; lastWasUnit = true; lastWasTens = false
            } else if let t = tens[w] {
                if lastWasTens || lastWasUnit || current % 100 != 0 { return nil }
                current += t; lastWasTens = true; lastWasUnit = false
            } else if let sc = scales[w] {
                if current == 0 { return nil }                        // "hundred" alone
                if sc == 100 {
                    if current >= 100 { return nil }
                    current *= 100
                } else {
                    total += current * sc; current = 0
                }
                lastWasTens = false; lastWasUnit = false
            } else { return nil }
            any = true
        }
        return any ? total + current : nil
    }

    static let percentWords: Set<String> = ["percent", "per cent"]
    static let moneyWords: Set<String> = ["dollars", "dollar", "bucks"]
    static let clockWords: Set<String> = ["am", "pm", "a.m.", "p.m."]

    private static let reDottedMid = try! NSRegularExpression(pattern: "(?i)\\b([ap])\\.\\s?m\\.(?=\\s+[a-z0-9])")
    private static let reDotted = try! NSRegularExpression(pattern: "(?i)\\b([ap])\\.\\s?m\\.")

    static func normalize(_ input: String) -> String {
        // "p.m." → "pm" first (its dots would otherwise look like sentence ends).
        var text = input
        if text.contains(".m.") || text.contains(". m.") {
            text = TextCleanup.replace(text, reDottedMid, with: "$1m")
            text = TextCleanup.replace(text, reDotted, with: "$1m.")
        }
        // Tokenize: leading non-letters, then (word, separator-after-it) pairs. Hyphens and
        // apostrophes between letters stay inside the word ("twenty-five", "don't").
        let chars = Array(text)
        var tokens: [(word: String, sep: String)] = []
        var k = 0
        var lead = ""
        while k < chars.count, !chars[k].isLetter { lead.append(chars[k]); k += 1 }
        while k < chars.count {
            var word = ""
            while k < chars.count, chars[k].isLetter
                    || ((chars[k] == "-" || chars[k] == "'") && k + 1 < chars.count && chars[k + 1].isLetter && !word.isEmpty) {
                word.append(chars[k]); k += 1
            }
            var sep = ""
            while k < chars.count, !chars[k].isLetter { sep.append(chars[k]); k += 1 }
            tokens.append((word, sep))
        }
        guard tokens.contains(where: { isNumberWord(parts($0.word).first ?? "") }) else { return text }

        var out = lead
        var i = 0
        while i < tokens.count {
            // Longest run of number words joined only by spaces/hyphens ("and" allowed after "hundred").
            var j = i
            var words: [String] = []
            while j < tokens.count {
                let ws = parts(tokens[j].word)
                if ws.allSatisfy(isNumberWord) && !ws.isEmpty {
                    words += ws
                } else if tokens[j].word.lowercased() == "and", words.last == "hundred", j + 1 < tokens.count,
                          parts(tokens[j + 1].word).allSatisfy(isNumberWord) {
                    // "one hundred and five": skip the "and"
                } else { break }
                let sepOK = tokens[j].sep.allSatisfy({ $0 == " " })
                j += 1
                if !sepOK { break }
            }
            if j > i, let v = value(words) {
                let lastSep = tokens[j - 1].sep
                let nextWord = j < tokens.count ? tokens[j].word.lowercased() : ""
                let compound = words.count > 1
                if lastSep == " ", percentWords.contains(nextWord) {
                    out += "\(v)%" + tokens[j].sep; i = j + 1; continue
                }
                if lastSep == " ", moneyWords.contains(nextWord), compound || v >= 10 || words.count == 1 {
                    out += "$\(v)" + tokens[j].sep; i = j + 1; continue
                }
                if lastSep == " ", v >= 1, v <= 12, clockWords.contains(nextWord) {
                    out += "\(v) " + (nextWord.hasPrefix("a") ? "AM" : "PM") + tokens[j].sep; i = j + 1; continue
                }
                if compound || v >= 10 {
                    out += "\(v)" + lastSep; i = j; continue
                }
            }
            out += tokens[i].word + tokens[i].sep
            i += 1
        }
        return out
    }

    /// "twenty-five" → ["twenty", "five"]; lowercase.
    private static func parts(_ w: String) -> [String] {
        w.lowercased().split(separator: "-").map(String.init)
    }
}
