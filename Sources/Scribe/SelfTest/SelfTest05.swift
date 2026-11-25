// SelfTest05.swift
// 0.5 self-tests (GitHub Actions macOS runner — a virtual Mac without the Neural Engine, and
// WITHOUT Accessibility permission for Scribe, so the real paste into another app can't run):
//  • paste logic that doesn't need Accessibility (focus classification, ⌘V event shape,
//    non-activating overlay, copy fallback, sentence joining, stray capitals, vocabulary, speed)
//  • pause test: a clip with a 2.5 s pause spliced mid-sentence must come out as ONE sentence
//    with no lost words and no capital letter after the pause
//  • vocabulary on synthetic speech (macOS `say`), with/without the acoustic helper
//  • LibriSpeech (40 test-clean clips in Tests/librispeech): WER + release-to-text time, for
//    Parakeet v2 and (with --compare-models) Parakeet Ultra

import Foundation
import AppKit
import FluidAudio

extension SelfTest {
    // MARK: Helpers

    /// Feed `samples` to the live voice detector in 100 ms slices (as the mic would), then
    /// "release the key" and time Dictation.run.
    static func releaseLive(_ samples: [Float], removeFillers: Bool = true) async throws -> (Double, Dictation.Result) {
        let session = UUID()
        await SpeechEngine.shared.liveVadStart(session: session)
        var i = 0
        while i < samples.count {
            await SpeechEngine.shared.liveVadFeed(Array(samples[i..<min(samples.count, i + 1600)]))
            i += 1600
        }
        let t0 = Date()
        let r = try await Dictation.run(samples: samples, useAI: false, removeFillers: removeFillers, live: true, session: session)
        return (Date().timeIntervalSince(t0), r)
    }

    /// (edits, reference words)
    static func editCount(ref: String, hyp: String) -> (Int, Int) {
        let n = normWords(ref).count
        return (Int((wer(ref: ref, hyp: hyp) * Double(n)).rounded()), n)
    }

    /// Words after the first that start with a capital and aren't "I"/"I'm"… (mid-sentence capitals).
    static func midSentenceCapitals(_ text: String) -> [String] {
        var out: [String] = []
        var sentenceStart = true
        for raw in text.split(separator: " ") {
            let w = raw.trimmingCharacters(in: .punctuationCharacters)
            if !sentenceStart, let f = w.first, f.isUppercase, w != "I", !w.hasPrefix("I'") { out.append(w) }
            sentenceStart = raw.last.map { ".!?".contains($0) } ?? false
        }
        return out
    }

    /// Runs `body` on the main thread (the self-test runs NSApplication's run loop on thread 1).
    static func onMainThread<T: Sendable>(_ body: @escaping @MainActor () -> T) async -> T {
        await withCheckedContinuation { (c: CheckedContinuation<T, Never>) in
            DispatchQueue.main.async { c.resume(returning: MainActor.assumeIsolated { body() }) }
        }
    }

    // MARK: Paste logic (no Accessibility needed)

    static func pasteLogicTest() async -> [String: Any] {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            checks.append(["name": name, "pass": ok, "detail": detail])
            log("paste-logic \(ok ? "PASS" : "FAIL"): \(name) \(detail)")
        }
        // Focus classification.
        check("text field is editable", Editability.classify(role: "AXTextField", selectedTextSettable: false, valueSettable: false, hasEditableAncestor: false) == .yes)
        check("web content-editable is editable", Editability.classify(role: "AXGroup", selectedTextSettable: false, valueSettable: false, hasEditableAncestor: true) == .yes)
        check("list is not a text box", Editability.classify(role: "AXList", selectedTextSettable: false, valueSettable: false, hasEditableAncestor: false) == .no)
        check("button is not a text box", Editability.classify(role: "AXButton", selectedTextSettable: false, valueSettable: false, hasEditableAncestor: false) == .no)
        check("unknown element → paste anyway", Editability.classify(role: "AXGroup", selectedTextSettable: false, valueSettable: false, hasEditableAncestor: false) == .unknown)
        check("no element (Electron) → paste anyway", Editability.classify(role: nil, selectedTextSettable: false, valueSettable: false, hasEditableAncestor: false) == .unknown)
        // ⌘V events.
        let ev = TextInserter.commandVEvents()
        let codes = ev.map { $0.getIntegerValueField(.keyboardEventKeycode) }
        let types = ev.map { $0.type }
        // The Command key itself is a modifier: macOS may report it as .flagsChanged instead of keyDown/keyUp.
        let cmdOK = ev.count == 4 && (types[0] == .keyDown || types[0] == .flagsChanged) && (types[3] == .keyUp || types[3] == .flagsChanged)
            && ev[0].flags.contains(.maskCommand)
        check("⌘V = Cmd↓ V↓ V↑ Cmd↑", codes == [55, 9, 9, 55] && cmdOK && types[1] == .keyDown && types[2] == .keyUp
              && ev[1].flags.contains(.maskCommand) && ev[2].flags.contains(.maskCommand) && !ev[3].flags.contains(.maskCommand),
              "codes \(codes) types \(types.map { $0.rawValue }) flags \(ev.map { $0.flags.rawValue })")
        // Overlay never takes focus.
        let rules: (Bool, Bool, Bool)? = await onMainThread {
            let o = OverlayPanel()
            o.show(OverlayCapsule(mode: .transcribing, tape: LevelTape()))
            defer { o.hide() }
            return o.focusRules.map { ($0.nonActivating, $0.canBecomeKey, $0.canBecomeMain) }
        }
        check("overlay panel is non-activating and never key/main",
              rules.map { $0.0 && !$0.1 && !$0.2 } ?? false, "\(String(describing: rules))")
        // Target capture (on CI: whatever is in front; never Scribe itself).
        let target: (String?, Bool) = await onMainThread {
            FocusTracker.start()
            let t = FocusTracker.capture()
            return (t?.summary, t.map { $0.pid == ProcessInfo.processInfo.processIdentifier } ?? false)
        }
        check("target is never Scribe itself", !target.1, target.0 ?? "no target app")
        let trusted = await MainActor.run { Permissions.accessibilityGranted }
        var out: [String: Any] = ["accessibility_trusted_on_runner": trusted, "target": target.0 ?? "none"]
        if !trusted {
            // Copy fallback: no permission → the text must be on the clipboard, outcome needsAccessibility.
            let text = "Scribe fallback test \(UUID().uuidString.prefix(6))"
            let r = await TextInserter.insert(text, restoreClipboard: false)
            let onClip = await MainActor.run { NSPasteboard.general.string(forType: .string) }
            check("no Accessibility → copied + 'needs Accessibility'", r.outcome == .needsAccessibility && onClip == text,
                  "outcome \(r.outcome.rawValue)")
            out["typing_test"] = "skipped: the runner can't grant Accessibility to Scribe"
        } else {
            let r = await TypingTest.run()
            out["typing_test"] = ["ok": r.ok, "message": r.message]
            check("typing into TextEdit", r.ok, r.message)
        }
        // Joining pieces split at a pause.
        let j1 = TextCleanup.joinChunks(["The discipline of the former parliamentary army.", "Was not contemptible."])
        check("join: pause period removed + lowercased", j1 == "The discipline of the former parliamentary army was not contemptible.", j1)
        let j2 = TextCleanup.joinChunks(["I finished the robot today.", "Tomorrow we test it."])
        check("join: real sentence kept", j2 == "I finished the robot today. Tomorrow we test it.", j2)
        let j3 = TextCleanup.joinChunks(["Then we need to.", "I think fix the intake."])
        check("join: 'I' stays capital", j3 == "Then we need to I think fix the intake.", j3)
        let j4 = TextCleanup.joinChunks(["Send it to.", "Figma tomorrow."], vocabulary: ["Figma"])
        check("join: vocabulary term keeps its capital", j4.contains("Figma"), j4)
        // Pause periods inside one transcript (voice-test): dropped only where the pause cut a sentence.
        let pp: [(String, String, String)] = [
            ("pause: '. And' joins", "Coach said we need to be there right after lunch. And bring water",
             "Coach said we need to be there right after lunch and bring water"),
            ("pause: '…plan is. We' joins", "So the plan is. We test the robot on Tuesday.", "So the plan is we test the robot on Tuesday."),
            ("pause: real sentence ends kept", "I finished the robot today. Tomorrow we test it. Then we fix whatever breaks.",
             "I finished the robot today. Tomorrow we test it. Then we fix whatever breaks."),
            ("pause: 'where it is.' is a real end", "That's where it is. We can go.", "That's where it is. We can go."),
            ("pause: question after 'Was' kept", "I fixed the arm. Was it the motor?", "I fixed the arm. Was it the motor?"),
            ("pause: 'I' keeps its capital", "Then we need to. I think we should ask Priya.", "Then we need to I think we should ask Priya."),
            ("pause: names and terms keep capitals", "Send it to. Priya and push to. GitHub tonight.", "Send it to Priya and push to GitHub tonight."),
            ("pause: abbreviations untouched", "We met Mr. Smith at 3 PM. The U.S. team won.", "We met Mr. Smith at 3 PM. The U.S. team won."),
        ]
        for (name, input, want) in pp {
            let got = TextCleanup.rules(input)
            check(name, got == want, got)
        }
        let pl = TextCleanup.light("we should probably. And then add a motor.")
        check("pause: light() merges too", pl == "We should probably and then add a motor.", pl)
        // Stray capitals.
        let c1 = TextCleanup.rules("we should probably, The motor is hot and We can fix it")
        check("rules: stray mid-sentence capitals lowered", c1 == "We should probably, the motor is hot and we can fix it", c1)
        let c2 = TextCleanup.rules("Then Alex said I will use GitHub.")
        check("rules: names, I and brands untouched", c2 == "Then Alex said I will use GitHub.", c2)
        // Numbers.
        let n1 = TextCleanup.rules("we need twenty five percent more and fifty dollars by three pm.")
        check("rules: numbers", n1 == "We need 25% more and $50 by 3 PM.", n1)
        let n2 = TextCleanup.rules("one of us has two ideas.")
        check("rules: small numbers stay words", n2 == "One of us has two ideas.", n2)
        // Vocabulary text pass.
        let v1 = Vocabulary.apply("update the onshape model in figma, push to git hub from x code, swift ui on the vex v five", terms: Vocabulary.terms(from: Vocabulary.defaults))
        check("vocabulary: spoken forms", v1 == "update the Onshape model in Figma, push to GitHub from Xcode, SwiftUI on the VEX V5", v1)
        let v2 = Vocabulary.apply("the notion that open notion works", terms: Vocabulary.terms(from: Vocabulary.defaults))
        check("vocabulary: everyday 'notion' kept", v2 == "the notion that open Notion works", v2)
        // Everyday words that sound like terms must never become terms (0.5 hotfix: "cute" → "CAD").
        let everydayText = "That puppy is so cute. I will practise it. He nods his head. The scene is absolutely cute? It's a cad."
        let v3 = Vocabulary.apply(TextCleanup.rules(everydayText), terms: Vocabulary.terms(from: Vocabulary.defaults))
        check("vocabulary: text pass leaves everyday words (only 'cad' → 'CAD')",
              v3 == "That puppy is so cute. I will practise it. He nods his head. The scene is absolutely cute? It's a CAD.", v3)
        let dict = Vocabulary.englishWords()
        check("acoustic guard: word list loaded", dict.count > 100_000, "\(dict.count) words")
        let refusals: [(String, String)] = [("cute", "CAD"), ("cute?", "CAD"), ("practise", "CAD"), ("head", "CAD"), ("head", "Onshape"),
                                            ("nods", "Notion"), ("notion", "Notion"), ("scribe", "Scribe"), ("cad", "CAD"), ("vex", "VEX"), ("v five", "V5"),
                                            ("Vex V5", "Xcode"), ("V5", "Xcode"), ("Figma", "Notion")]
        let wrongly = refusals.filter { Vocabulary.acousticReplacementAllowed(original: $0.0, replacement: $0.1, dict: dict) }
        check("acoustic guard: refuses everyday words and short acronyms", wrongly.isEmpty, wrongly.map { "\($0.0)→\($0.1)" }.joined(separator: ", "))
        let wins: [(String, String)] = [("Swift UI", "SwiftUI"), ("OnShade", "Onshape"), ("Figmah", "Figma"), ("git hub", "GitHub"), ("x code", "Xcode")]
        let lost = wins.filter { !Vocabulary.acousticReplacementAllowed(original: $0.0, replacement: $0.1, dict: dict) }
        check("acoustic guard: keeps real fixes", lost.isEmpty, lost.map { "\($0.0)→\($0.1)" }.joined(separator: ", "))
        let g = Vocabulary.guardAcoustic(original: "Open the OnShade file, it is so cute.",
                                         rescored: "Open the Onshape file, it is so CAD.",
                                         replacements: [(from: "OnShade", to: "Onshape"), (from: "cute.", to: "CAD")], dict: dict)
        check("acoustic guard: mixed swaps keep only the real fix", g.text == "Open the Onshape file, it is so cute.", g.text)
        let g2 = Vocabulary.guardAcoustic(original: "He nods his head.", rescored: "He nods his CAD.",
                                          replacements: [(from: "head.", to: "CAD")], dict: dict)
        check("acoustic guard: all refused → model text unchanged", g2.text == "He nods his head.", g2.text)
        // voice-test: swaps need a spelling match ("So cute!" heard as "Sugud." became "Xcode.").
        let acoustic2: [(String, String, String?, Bool)] = [
            ("Sugud.", "Xcode", "Sugud.", false), ("Sugud", "Xcode", nil, false), ("Done", "Xcode", "Done.", false),
            ("One sec", "Onshape", "One sec.", false), ("Vex V5", "Xcode", "The Vex V5 robot.", false),
            ("cute", "CAD", "So cute.", false), ("head", "CAD", "He nods his head.", false), ("practise", "CAD", "I will practise it.", false),
            ("OnShade", "Onshape", "Open the OnShade file.", true), ("OnShade", "Onshape", nil, true),
            ("Swift UI", "SwiftUI", "Swift UI.", true), ("Swift UI", "SwiftUI", "I built it in Swift UI today.", true),
        ]
        for (heard, term, utt, want) in acoustic2 {
            let got = Vocabulary.acousticReplacementAllowed(original: heard, replacement: term, dict: dict, utterance: utt)
            check("acoustic guard: \(heard) → \(term) \(want ? "kept" : "refused")", got == want, "allowed=\(got)")
        }
        check("acoustic guard: spelling similarity", Vocabulary.similarSpelling("onshade", "onshape") && !Vocabulary.similarSpelling("sugud", "xcode")
              && !Vocabulary.similarSpelling("done", "xcode"), "")
        let g3 = Vocabulary.guardAcoustic(original: "Sugud.", rescored: "Xcode.", replacements: [(from: "Sugud.", to: "Xcode")], dict: dict)
        check("acoustic guard: short reply 'Sugud.' stays", g3.text == "Sugud." && g3.accepted.isEmpty, g3.text)
        // Speed: rules + vocabulary on a 200-word dictation.
        let long = String(repeating: "um so I I I think we need twenty five percent more of the onshape thing, uh, and then. The robot works. ", count: 9)
        _ = Vocabulary.apply(TextCleanup.rules(long))
        let t0 = Date()
        for _ in 0..<20 { _ = Vocabulary.apply(TextCleanup.rules(long)) }
        let ms = Date().timeIntervalSince(t0) * 1000 / 20
        check("cleanup + vocabulary < 20 ms (≈200 words)", ms < 20, String(format: "%.2f ms", ms))
        out["cleanup_ms_200_words"] = ms
        out["checks"] = checks
        out["passed"] = checks.filter { $0["pass"] as? Bool == true }.count
        out["failed"] = checks.filter { $0["pass"] as? Bool != true }.map { $0["name"] ?? "" }
        out["limits"] = "Runner can't grant Accessibility: the real ⌘V/AX insert into another app, refocusing, and the TextEdit test only run on a Mac where Scribe has the permission."
        return out
    }

    // MARK: Pause test

    static func pauseTest() async throws -> [String: Any] {
        guard let wav = Bundle.main.url(forResource: "pause_source", withExtension: "wav"),
              let txt = Bundle.main.url(forResource: "pause_source", withExtension: "txt") else { return ["error": "clip missing"] }
        let src = try SpeechEngine.loadSamples(wav)
        let reference = try String(contentsOf: txt, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        // Quietest 100 ms between 35 % and 65 % of the clip = a gap between two words.
        let lo = src.count * 35 / 100, hi = src.count * 65 / 100
        var cut = lo, quietest = Float.infinity, k = lo
        while k + 1600 < hi {
            let e = src[k..<(k + 1600)].reduce(Float(0)) { $0 + $1 * $1 }
            if e < quietest { quietest = e; cut = k + 800 }
            k += 160
        }
        let rms = sqrt(quietest / 1600)
        var noise: [Float] = []
        noise.reserveCapacity(40_000)
        var seed: UInt32 = 12345
        for _ in 0..<40_000 {                    // 2.5 s of room-tone-level noise
            seed = seed &* 1_664_525 &+ 1_013_904_223
            noise.append((Float(seed >> 8) / Float(1 << 24) * 2 - 1) * rms)
        }
        let clip = Array(src[..<cut]) + noise + Array(src[cut...])
        var out: [String: Any] = ["reference": reference, "pause_seconds": 2.5,
                                  "pause_at_seconds": Double(cut) / 16_000, "clip_seconds": Double(clip.count) / 16_000,
                                  "measured_on": "GitHub Actions macOS runner"]
        func judge(_ text: String) -> [String: Any] {
            let inner = text.dropLast().filter { ".!?".contains($0) }.count
            let caps = midSentenceCapitals(text)
            let w = wer(ref: reference, hyp: text)
            return ["text": text, "wer": w, "sentence_breaks_inside": inner, "mid_sentence_capitals": caps,
                    "one_sentence": inner == 0, "no_mid_capitals": caps.isEmpty]
        }
        // 0.5 default ("I pause while thinking" on).
        UserDefaults.standard.set(true, forKey: "pauseWhileThinking")
        let (t, r) = try await releaseLive(clip)
        var on = judge(r.text)
        on["release_to_text_ms"] = (t * 1000).rounded()
        on["mode"] = r.transcript.vadMode
        on["raw_text"] = r.transcript.text
        let srcRun = try await releaseLive(src)
        on["wer_same_clip_without_pause"] = wer(ref: reference, hyp: srcRun.1.text)
        on["pass"] = (on["one_sentence"] as? Bool ?? false) && (on["no_mid_capitals"] as? Bool ?? false)
            && (on["wer"] as? Double ?? 1) <= (on["wer_same_clip_without_pause"] as? Double ?? 0) + 0.05
        out["pause_tolerant_on"] = on
        // Toggle off (0.5 s splits) for comparison.
        UserDefaults.standard.set(false, forKey: "pauseWhileThinking")
        let (_, rOff) = try await releaseLive(clip)
        UserDefaults.standard.removeObject(forKey: "pauseWhileThinking")
        var off = judge(rOff.text); off["mode"] = rOff.transcript.vadMode
        out["pause_tolerant_off"] = off
        // What 0.4 effectively did: the two halves transcribed separately and glued.
        let a = Array(src[..<cut]), b = Array(src[cut...])
        let ta = try await SpeechEngine.shared.dictate(samples: a).text
        let tb = try await SpeechEngine.shared.dictate(samples: b).text
        var old = judge(ta + " " + tb); old["what"] = "0.4-style: halves transcribed separately, glued as-is"
        out["v04_style_stitched"] = old
        var fixed = judge(Vocabulary.apply(TextCleanup.rules(TextCleanup.joinChunks([ta, tb]))))
        fixed["what"] = "same halves through 0.5's joinChunks + rules (used for > 25 s dictations)"
        out["v05_join_of_halves"] = fixed
        log("pause test: \(on)")
        return out
    }

    // MARK: Vocabulary on synthetic speech

    static let vocabSentences: [(String, [String])] = [
        ("I updated the Onshape CAD model for our VEX V5 robot.", ["Onshape", "CAD", "VEX", "V5"]),
        ("Open Figma and Notion, then push the SwiftUI code from Xcode to GitHub.", ["Figma", "Notion", "SwiftUI", "Xcode", "GitHub"]),
        ("Pull the latest Scribe build from GitHub.", ["Scribe", "GitHub"]),
    ]
    /// Everyday words that sound close to terms: no term may appear (0.5 hotfix: "cute" → "CAD").
    static let falseFriendSentences = ["That puppy is so cute.", "I will practise it.", "He nods his head.",
                                       "The scene is absolutely cute."]

    /// Default terms that appear in `text` (whole word, exact case) but not in `reference`.
    static func insertedTerms(_ text: String, reference: String) -> [String] {
        let ref = Set(normWords(reference))
        return Vocabulary.defaults.filter { term in
            guard let re = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: term) + "(?![\\p{L}\\p{N}])") else { return false }
            let found = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            return found && !normWords(term).allSatisfy { ref.contains($0) }
        }
    }

    static func say(_ text: String, to url: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-o", url.path, "--data-format=LEI16@16000", text]
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    static func vocabularyTest(dir: URL) async throws -> [String: Any] {
        var rows: [[String: Any]] = []
        var hits = (raw: 0, text: 0, boosted: 0, old: 0), total = 0
        var inserted = (plain: 0, boosted: 0, old: 0)
        let boostReady = await SpeechEngine.shared.isVocabularyBoostReady
        let all: [(String, [String])] = vocabSentences + falseFriendSentences.map { ($0, []) }
        var clips: [[Float]] = []
        for (i, (sentence, _)) in all.enumerated() {
            let url = dir.appendingPathComponent("vocab\(i).wav")
            guard say(sentence, to: url) else { return ["error": "say failed (no voice on this runner?)"] }
            clips.append(try SpeechEngine.loadSamples(url))
        }
        func run(_ samples: [Float], helper: Bool) async throws -> Dictation.Result {
            UserDefaults.standard.set(helper, forKey: Vocabulary.boostKey)
            defer { UserDefaults.standard.removeObject(forKey: Vocabulary.boostKey) }
            return try await Dictation.run(samples: samples, useAI: false, removeFillers: true)
        }
        // Pass 1: helper off, helper on (guarded = this build).
        var results: [(plain: Dictation.Result, boosted: Dictation.Result?)] = []
        for samples in clips {
            let plain = try await run(samples, helper: false)
            var boosted: Dictation.Result?
            if boostReady { boosted = try await run(samples, helper: true) }
            results.append((plain, boosted))
        }
        // Pass 2: the 0.5.21 helper (all terms, no guard), to show what the guard stops.
        var old: [Dictation.Result?] = Array(repeating: nil, count: clips.count)
        if boostReady {
            Vocabulary.acousticGuard = false
            await SpeechEngine.shared.unloadVocabularyBoost()
            do {
                try await SpeechEngine.shared.loadVocabularyBoost(terms: Vocabulary.terms(from: Vocabulary.defaults))
                for (i, samples) in clips.enumerated() { old[i] = try await run(samples, helper: true) }
            } catch { log("unguarded helper failed: \(error)") }
            Vocabulary.acousticGuard = true
            await SpeechEngine.shared.unloadVocabularyBoost()
            try await SpeechEngine.shared.loadVocabularyBoost(terms: Vocabulary.terms(from: Vocabulary.defaults))
        }
        for (i, (sentence, terms)) in all.enumerated() {
            let (plain, boosted) = results[i]
            func count(_ s: String) -> Int { terms.filter { s.contains($0) }.count }
            hits.raw += count(plain.transcript.text)
            hits.text += count(plain.text)
            hits.boosted += boosted.map { count($0.text) } ?? 0
            hits.old += old[i].map { count($0.text) } ?? 0
            total += terms.count
            let insPlain = insertedTerms(plain.text, reference: sentence)
            let insBoost = boosted.map { insertedTerms($0.text, reference: sentence) } ?? []
            let insOld = old[i].map { insertedTerms($0.text, reference: sentence) } ?? []
            inserted.plain += insPlain.count; inserted.boosted += insBoost.count; inserted.old += insOld.count
            rows.append(["sentence": sentence, "kind": terms.isEmpty ? "everyday words (no term allowed)" : "terms",
                         "raw_model": plain.transcript.text, "with_text_pass": plain.text,
                         "with_acoustic_helper": boosted?.text ?? "not loaded",
                         "with_0.5.21_helper_unguarded": old[i]?.text ?? "not run",
                         "inserted_terms_helper_off": insPlain, "inserted_terms_helper_on": insBoost,
                         "inserted_terms_0.5.21_helper": insOld,
                         "helper_ms": ((boosted?.transcript.boostSeconds ?? 0) * 1000).rounded(),
                         "helper_replacements": boosted?.transcript.boostReplacements ?? [],
                         "0.5.21_helper_replacements": old[i]?.transcript.boostReplacements ?? []])
        }
        var failed: [String] = []
        if inserted.plain > 0 { failed.append("term inserted with helper off") }
        if boostReady, inserted.boosted > 0 { failed.append("term inserted with helper on") }
        if hits.text != total { failed.append("terms right (text pass) \(hits.text)/\(total)") }
        if boostReady, hits.boosted != total { failed.append("terms right (helper on) \(hits.boosted)/\(total)") }
        log("vocabulary: \(failed.isEmpty ? "PASS" : "FAIL \(failed)") inserted off/on/0.5.21 = \(inserted.plain)/\(inserted.boosted)/\(inserted.old)")
        return ["what": "\(all.count) sentences spoken by macOS's synthetic voice (`say`) — NOT a real person: \(vocabSentences.count) with terms spelled exactly right, \(falseFriendSentences.count) with everyday words that sound like terms",
                "measured_on": "GitHub Actions macOS runner",
                "terms_total": total, "terms_right_raw_model": hits.raw, "terms_right_after_text_pass": hits.text,
                "terms_right_with_acoustic_helper": boostReady ? hits.boosted : -1,
                "terms_right_with_0.5.21_helper": boostReady ? hits.old : -1,
                "false_friend_insertions_helper_off": inserted.plain,
                "false_friend_insertions_helper_on": boostReady ? inserted.boosted : -1,
                "false_friend_insertions_0.5.21_helper": boostReady ? inserted.old : -1,
                "pass": failed.isEmpty, "failed": failed, "rows": rows]
    }

    // MARK: LibriSpeech WER + latency

    static func libriTest(dir: String, managers: [(String, AsrManager?, Bool)]) async throws -> [String: Any] {
        let refsURL = URL(fileURLWithPath: dir).appendingPathComponent("refs.json")
        let refs = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: refsURL))
        let files = refs.keys.sorted()
        var clips: [(String, [Float])] = []
        for f in files { clips.append((f, try SpeechEngine.loadSamples(URL(fileURLWithPath: dir).appendingPathComponent(f)))) }
        let audio = clips.reduce(0.0) { $0 + Double($1.1.count) / 16_000 }
        var out: [String: Any] = ["clips": clips.count, "audio_seconds": audio,
                                  "measured_on": "GitHub Actions macOS runner (virtual Mac, no Neural Engine)",
                                  "scoring": "WER on lowercase words without punctuation (simple normalizer, no number normalization), corpus-level"]
        for (name, manager, boost) in managers {
            UserDefaults.standard.set(boost, forKey: Vocabulary.boostKey)
            var editsRaw = 0, editsFinal = 0, words = 0
            var times: [Double] = []
            var worst: [(Double, String, String)] = []
            var insertions: [[String: Any]] = []
            _ = try await Dictation.run(samples: clips[0].1, useAI: false, removeFillers: true, asrOverride: manager)  // warm-up
            for (f, s) in clips {
                let t0 = Date()
                let r = try await Dictation.run(samples: s, useAI: false, removeFillers: true, asrOverride: manager)
                times.append(Date().timeIntervalSince(t0))
                let ref = refs[f] ?? ""
                let (er, n) = editCount(ref: ref, hyp: r.transcript.text)
                let (ef, _) = editCount(ref: ref, hyp: r.text)
                editsRaw += er; editsFinal += ef; words += n
                let ins = insertedTerms(r.text, reference: ref)
                if !ins.isEmpty { insertions.append(["file": f, "terms": ins, "text": r.text]) }
                if er > 0 { worst.append((Double(er) / Double(n), f, r.transcript.text)) }
            }
            UserDefaults.standard.removeObject(forKey: Vocabulary.boostKey)
            let sorted = times.sorted()
            out[name] = [
                "wer_model_output": Double(editsRaw) / Double(words),
                "wer_after_cleanup_and_vocabulary": Double(editsFinal) / Double(words),
                "reference_words": words,
                "vocabulary_terms_inserted": insertions.count, "vocabulary_insertions": insertions,
                "release_to_text_mean_ms": (times.reduce(0, +) / Double(times.count) * 1000).rounded(),
                "release_to_text_median_ms": (sorted[sorted.count / 2] * 1000).rounded(),
                "total_seconds": times.reduce(0, +),
                "rtf": times.reduce(0, +) / audio,
                "worst": worst.sorted { $0.0 > $1.0 }.prefix(5).map { ["file": $0.1, "wer": $0.0, "text": $0.2] },
            ] as [String: Any]
            log("libri \(name): \(String(describing: out[name]))")
        }
        return out
    }

    /// The pause + dictation clips through another model (model comparison).
    static func clipCompare(_ manager: AsrManager?) async throws -> [String: Any] {
        var out: [String: Any] = [:]
        if let wav = Bundle.main.url(forResource: "dictation_sample", withExtension: "wav"),
           let txt = Bundle.main.url(forResource: "dictation_sample", withExtension: "txt") {
            let s = try SpeechEngine.loadSamples(wav)
            let ref = try String(contentsOf: txt, encoding: .utf8)
            _ = try await Dictation.run(samples: s, useAI: false, removeFillers: true, asrOverride: manager)
            let t0 = Date()
            let r = try await Dictation.run(samples: s, useAI: false, removeFillers: true, asrOverride: manager)
            out["dictation_clip"] = ["wer": wer(ref: ref, hyp: r.transcript.text), "ms": (Date().timeIntervalSince(t0) * 1000).rounded(),
                                     "text": r.text]
        }
        return out
    }
}
