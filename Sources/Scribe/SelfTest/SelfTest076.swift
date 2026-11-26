// SelfTest076.swift
// 0.7.6 targeted checks for the "safe" learning features (Engine/Learning.swift), all on plain text:
//   boost   – "Boost my words" fixes "superbase" → Supabase and "swift ui" → SwiftUI, and must NOT
//             change everyday sentences ("the cat sat on the mat", "right", "ride", …) nor any of the
//             40 LibriSpeech reference transcripts (Tests/librispeech/refs.json, when --libri-dir is given).
//   rules   – fix-up extraction (word diff), the 2-sightings / approval thresholds, the common-word rule,
//             on/off, dismiss + no re-learning, and the one-time migration of 0.7.3–0.7.5 data.
//   order   – learned fix-ups run BEFORE Style (Polished capitalizes the fixed word; Exact keeps the fix).
//   log     – scribe.log gets counts only, never the words.
// Every check saves and restores the UserDefaults keys it touches.

import Foundation

enum SelfTest076 {
    static let keys = [FixUps.key, FixUps.migratedKey, FixLearner.blockedKey, FixLearner.countsKey, FixLearner.itemsKey,
                       Vocabulary.key, WordBoost.key, DictionaryReplacements.key, CorrectionStore.key]

    @MainActor static func run() -> ([String: Any], [String]) {
        var out: [String: Any] = [:]
        var fail: [String] = []
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (k, v) in zip(keys, saved) {
                if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
            }
        }
        func clean() { for k in keys { UserDefaults.standard.removeObject(forKey: k) } }
        clean(); let b = boostCheck(); out["boost"] = b.0; fail += b.1
        clean(); let r = rulesCheck(); out["rules"] = r.0; fail += r.1
        clean(); let o = orderCheck(); out["order"] = o.0; fail += o.1
        clean(); let l = logCheck(); out["log"] = l.0; fail += l.1
        return (out, fail)
    }

    static var testTerms: [VocabularyTerm] {
        Vocabulary.terms(from: Vocabulary.defaults + ["Supabase", "Kubernetes", "Ryde", "Wright"])
    }

    // MARK: Boost

    static func boostCheck() -> ([String: Any], [String]) {
        var r: [String: Any] = [:]
        var fail: [String] = []
        let terms = testTerms
        let dict = Vocabulary.englishWords()
        r["mac_word_list_words"] = dict.count
        r["superbase_in_mac_word_list"] = Vocabulary.isEnglishWord("superbase", dict: dict)
        r["default_on"] = WordBoost.enabled
        if !WordBoost.enabled { fail.append("boost: Boost my words must be on by default") }

        let mustFix: [(String, String)] = [
            ("we store it in superbase now", "we store it in Supabase now"),
            ("built with swift ui", "built with SwiftUI"),
            ("Swift UI previews are slow.", "SwiftUI previews are slow."),
            ("Superbase's auth works.", "Supabase's auth works."),
            ("deploy it to kubernetties", "deploy it to Kubernetes"),
        ]
        var fixed: [String: String] = [:]
        for (input, want) in mustFix {
            let got = WordBoost.apply(input, terms: terms, dict: dict).text
            fixed[input] = got
            if got != want { fail.append("boost: \"\(input)\" → \"\(got)\", want \"\(want)\"") }
        }
        r["fixed"] = fixed

        let mustKeep = [
            "the cat sat on the mat", "right", "ride", "Right.", "Ride?", "turn right at the light", "a ride home",
            "write it down", "the right ride", "the super base camp", "That puppy is so cute.", "the notion that it works",
            "figure it out", "sigma", "the rite of spring", "Do you want a ride or should I walk", "Kubernetes and Supabase",
            "Okay so the robot drove to the right side of the field.", "I will practise it. He nods his head.",
        ]
        var changed: [String] = []
        for s in mustKeep {
            let got = WordBoost.apply(s, terms: terms, dict: dict)
            if got.text != s || got.hits > 0 { changed.append("\(s) → \(got.text)") }
        }
        r["kept_count"] = mustKeep.count - changed.count
        if !changed.isEmpty { fail.append("boost: changed everyday text: \(changed.joined(separator: " | "))") }

        // The same sentence with the switch off: untouched.
        let off = Learning.afterRecognition("we store it in superbase now", rules: [], terms: terms, boost: false, log: false)
        if off.text != "we store it in superbase now" || off.boostHits != 0 { fail.append("boost: ran while switched off") }

        // LibriSpeech reference transcripts (GitHub runner copy): none may change.
        if let dir = SelfTest.argValue("--libri-dir"),
           let data = try? Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent("refs.json")),
           let refs = try? JSONDecoder().decode([String: String].self, from: data) {
            var hit: [String] = []
            for (k, v) in refs.sorted(by: { $0.key < $1.key }) {
                let t = v.lowercased()
                let got = WordBoost.apply(t, terms: terms, dict: dict)
                if got.hits > 0 { hit.append("\(k): \(got.text)") }
            }
            r["librispeech_refs"] = refs.count
            r["librispeech_refs_changed"] = hit.count
            if !hit.isEmpty { fail.append("boost: changed \(hit.count) LibriSpeech reference transcript(s): \(hit.prefix(3).joined(separator: " | "))") }
        } else {
            r["librispeech_refs"] = "not run (no --libri-dir)"
        }

        // Speed: 1,000 words with 14 terms (GitHub runner).
        let long = Array(repeating: "we store the robot notes in superbase and build the app with swift ui today", count: 70).joined(separator: " ")
        let t0 = Date()
        _ = WordBoost.apply(long, terms: terms, dict: dict)
        r["ms_for_1000_words"] = (Date().timeIntervalSince(t0) * 1000).rounded()
        return (r, fail)
    }

    // MARK: Rules

    static func rulesCheck() -> ([String: Any], [String]) {
        var r: [String: Any] = [:]
        var fail: [String] = []
        UserDefaults.standard.set(true, forKey: FixUps.migratedKey)

        // Extraction: a phrase fix from a word diff.
        let h = FixLearner.hunks(old: "I use sweet you eye daily.", new: "I use SwiftUI daily.")
        r["phrase_hunk"] = h.map { "\($0.from) → \($0.to)" }
        if h != [FixLearner.Hunk(from: "sweet you eye", to: "SwiftUI")] { fail.append("rules: phrase diff wrong (\(r["phrase_hunk"]!))") }

        // Once = suggestion (not applied); twice = on.
        FixUps.record(old: "teh plan works", new: "the plan works")
        if FixUps.apply("teh robot").text != "teh robot" { fail.append("rules: a fix seen once was applied") }
        if FixUps.suggestions.map(\.label) != ["teh → the"] { fail.append("rules: a fix seen once is not a suggestion (\(FixUps.suggestions.map(\.label)))") }
        // The 2nd time at a sentence start ("Teh" → "The") is the same fix.
        let on = FixUps.record(old: "Teh robot moved.", new: "The robot moved.")
        r["turned_on"] = on.map(\.label)
        let applied = FixUps.apply("teh robot and TEH arm")
        r["after_two"] = applied.text
        if on.map(\.label) != ["teh → the"] || applied.text != "the robot and the arm" || applied.hits != 2 {
            fail.append("rules: teh → the not on after 2 fixes (\(on.map(\.label)), \(applied.text))")
        }

        // A phrase made of everyday words ("sweet you eye"): seen twice it still waits; approved, it applies.
        FixUps.record(old: "I use sweet you eye daily", new: "I use SwiftUI daily")
        FixUps.record(old: "sweet you eye is nice", new: "SwiftUI is nice")
        if FixUps.apply("we like sweet you eye").text != "we like sweet you eye" { fail.append("rules: an everyday-word phrase turned on without approval") }
        if let p = FixUps.rules.first(where: { $0.to == "SwiftUI" }) { FixUps.approve(p.id) } else { fail.append("rules: phrase fix not recorded") }
        let ph = FixUps.apply("we like sweet you eye")
        r["phrase_applied"] = ph.text
        if ph.text != "we like SwiftUI" { fail.append("rules: approved phrase rule not applied (\(ph.text))") }

        // Common words: seen twice still waits for approval; approval turns it on.
        FixUps.record(old: "their car is red", new: "there car is red")
        FixUps.record(old: "is their car here", new: "is there car here")
        guard let common = FixUps.rules.first(where: { $0.from == "their" }) else {
            fail.append("rules: common-word fix not recorded"); return (r, fail)
        }
        r["common_seen"] = common.seen
        if common.isActive || FixUps.apply("their car").text != "their car" { fail.append("rules: a common-word fix turned on without approval") }
        if !FixUps.suggestions.contains(where: { $0.id == common.id }) { fail.append("rules: common-word fix not listed as a suggestion") }
        FixUps.approve(common.id)
        if FixUps.apply("their car").text != "there car" { fail.append("rules: approved common-word fix not applied") }

        // Approve once is enough for a new fix.
        FixUps.record(old: "ask zorvath", new: "ask Zorvath")
        if let z = FixUps.rules.first(where: { $0.to == "Zorvath" }) {
            if z.isActive { fail.append("rules: a name seen once turned on without approval") }
            FixUps.approve(z.id)
            if FixUps.apply("zorvath said").text != "Zorvath said" { fail.append("rules: approved-once name not applied") }
            if !Vocabulary.words.contains("Zorvath") { fail.append("rules: approved name not in Vocabulary") }
            // Off switch.
            FixUps.setEnabled(z.id, false)
            if FixUps.apply("zorvath said").text != "zorvath said" { fail.append("rules: switched-off rule still applied") }
            // Delete: gone, its word taken back, never learned again.
            FixUps.delete(z.id)
            FixUps.record(old: "ask zorvath", new: "ask Zorvath")
            FixUps.record(old: "ask zorvath", new: "ask Zorvath")
            if FixUps.rules.contains(where: { $0.to == "Zorvath" }) || Vocabulary.words.contains("Zorvath") {
                fail.append("rules: a deleted rule came back or left its word")
            }
        } else { fail.append("rules: name fix not recorded") }

        // Long edits (> 3 words a side) and case-only changes are not fixes.
        FixUps.record(old: "alpha beta gamma delta epsilon", new: "one two three four five")
        FixUps.record(old: "the plan", new: "The plan")
        if FixUps.rules.contains(where: { $0.from.contains("alpha") || $0.to == "The" }) { fail.append("rules: a long edit or case-only change became a rule") }

        // Migration of 0.7.3–0.7.5 data (once).
        UserDefaults.standard.set(false, forKey: FixUps.migratedKey)
        FixUps.rules = []
        DictionaryReplacements.pairs = [.init(from: "quor bull weed", to: "Quorbleweed")]
        let legacy = LearnedFix(from: "quor bull weed", to: "Quorbleweed", addedReplacement: true)
        UserDefaults.standard.set(try? JSONEncoder().encode([legacy]), forKey: FixLearner.itemsKey)
        UserDefaults.standard.set(["snazle\u{1F}Snazzle": 1], forKey: FixLearner.countsKey)
        FixUps.migrateIfNeeded()
        let m = FixUps.rules
        r["migrated"] = m.map { "\($0.label) on=\($0.isActive)" }
        if !(m.first(where: { $0.to == "Quorbleweed" })?.isActive ?? false) { fail.append("rules: migrated 0.7.x fix is not on") }
        if !DictionaryReplacements.pairs.isEmpty { fail.append("rules: migrated fix left its Dictionary copy") }
        if !(m.contains { $0.to == "Snazzle" && !$0.learned && $0.seen == 1 }) { fail.append("rules: half-learned 0.7.x fix not a suggestion") }
        if UserDefaults.standard.data(forKey: FixLearner.itemsKey) != nil { fail.append("rules: 0.7.x list not cleared after migration") }
        let before = FixUps.rules.count
        FixUps.migrateIfNeeded()
        if FixUps.rules.count != before { fail.append("rules: migration ran twice") }
        return (r, fail)
    }

    // MARK: Order

    static func orderCheck() -> ([String: Any], [String]) {
        var r: [String: Any] = [:]
        var fail: [String] = []
        let rule = FixUpRule(from: "teh", to: "the", seen: 2)
        let raw = "teh plan is ready"
        let steps = Dictation.textSteps(raw, removeFillers: true, rules: [rule], terms: [], boost: false, log: false)
        let polished = DictationStyle.polished.finish(cleaned: steps.cleaned, raw: steps.heard)
        let exact = DictationStyle.exact.finish(cleaned: steps.cleaned, raw: steps.heard)
        // What the wrong order (Style first, fix-up after) would give, to show the check can tell.
        let wrong = FixUps.apply(DictationStyle.polished.finish(cleaned: TextCleanup.rules(raw), raw: raw), rules: [rule]).text
        r["heard"] = steps.heard
        r["polished"] = polished
        r["exact"] = exact
        r["style_first_would_give"] = wrong
        if steps.heard != "the plan is ready" { fail.append("order: fix-up not applied right after recognition (\(steps.heard))") }
        if polished != "The plan is ready." { fail.append("order: Polished should capitalize the fixed word (\(polished))") }
        if exact != "the plan is ready" { fail.append("order: Exact lost the fix-up (\(exact))") }
        if wrong == polished { fail.append("order: check can't tell the orders apart") }
        // Boost also runs before the clean-up rules (it sees the model's words).
        let b = Dictation.textSteps("we use superbase", removeFillers: true, rules: [], terms: testTerms, boost: true, log: false)
        r["boost_then_rules"] = b.cleaned
        if b.learning.boostHits != 1 || !b.cleaned.contains("Supabase") { fail.append("order: boost didn't run before clean-up (\(b.cleaned))") }
        return (r, fail)
    }

    // MARK: Log

    static func logCheck() -> ([String: Any], [String]) {
        var r: [String: Any] = [:]
        var fail: [String] = []
        let url = AppLog.url
        let start = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
        let rule = FixUpRule(from: "teh", to: "the", seen: 2)
        let o = Learning.afterRecognition("we keep teh notes in superbase", rules: [rule], terms: testTerms, boost: true, log: true)
        r["fix_up_hits"] = o.fixUpHits
        r["boost_hits"] = o.boostHits
        guard let all = try? Data(contentsOf: url) else { fail.append("log: scribe.log not written"); return (r, fail) }
        let added = String(decoding: all.suffix(from: min(start, all.count)), as: UTF8.self)
        let line = added.split(separator: "\n").last(where: { $0.contains("learning:") }).map(String.init) ?? ""
        r["line"] = line.split(separator: " ", maxSplits: 1).last.map(String.init) ?? ""
        if !line.contains("learning: dictation fix-ups 1, boost 1") { fail.append("log: counts line missing (\(line))") }
        for w in ["teh", "notes", "superbase", "Supabase"] where line.contains(w) { fail.append("log: text \"\(w)\" leaked into scribe.log") }
        return (r, fail)
    }
}
