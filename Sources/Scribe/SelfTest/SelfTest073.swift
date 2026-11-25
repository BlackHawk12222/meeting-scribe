// SelfTest073.swift
// Targeted checks for 0.7.3 "Name voices" (run inside `--suite targeted`, see SelfTest072.run):
//   range      – assigning a time range relabels only the lines in it (a line crossing the edge is
//                split at the words), talk time is recounted, Undo restores the draft,
//                "Assign all to…" leaves one speaker
//   learn      – Save creates the typed person, re-teaches the voiceprint through VoiceMatcher.learn
//                (counter + the confirmed embedding is in the person's samples), survives a reload
//   vocabulary – a typed name is added to Vocabulary once (the user's list is restored afterwards)
//   space      – the Space key toggles playback unless a text field is focused or a modifier is
//                held; the editor installs and removes its key monitor
//   fixes      – "Learn from my fixes": a wrong→right word fix is learned as a replacement after
//                2 fixes (not 1), a capitalized name after 1 (also into Vocabulary), Undo removes
//                both and blocks re-learning, a case-only change of an ordinary word is ignored,
//                a 5,000-word text diffs fine (no length limit), "Save my corrections" is off by
//                default and saves nothing while off
// All names are invented sample data.

import Foundation
import AppKit

enum SelfTest073 {
    @MainActor static func voiceEditorCheck() -> ([String: Any], [String]) {
        var r: [String: Any] = [:]
        var fail: [String] = []
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("st073-ve-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let savedVocab = UserDefaults.standard.object(forKey: Vocabulary.key)
        defer {
            if let savedVocab { UserDefaults.standard.set(savedVocab, forKey: Vocabulary.key) }
            else { UserDefaults.standard.removeObject(forKey: Vocabulary.key) }
        }
        let store = Store(folder: tmp)
        let a = SelfTest072.vec(11), b = SelfTest072.vec(12), confirmed = SelfTest072.vec(13)
        let known = Person(name: "Tamsin Rowe", colorIndex: 0)
        store.people = [known]

        // 0–30 s: S1 0–10, S2 10–20 (one word per second), S1 20–30.
        var m = Meeting(title: "Sample sync", date: Date(), duration: 30, audioFileName: "none.wav")
        m.status = .done
        m.words = (0..<30).map { Word(start: Double($0), end: Double($0) + 0.8, text: "w\($0)") }
        m.utterances = [
            Utterance(start: 0, end: 9.8, speakerKey: "S1", text: (0..<10).map { "w\($0)" }.joined(separator: " ")),
            Utterance(start: 10, end: 19.8, speakerKey: "S2", text: (10..<20).map { "w\($0)" }.joined(separator: " ")),
            Utterance(start: 20, end: 29.8, speakerKey: "S1", text: (20..<30).map { "w\($0)" }.joined(separator: " ")),
        ]
        m.clusters = [
            SpeakerCluster(key: "S1", talkSeconds: 19.6, centroid: a, spanEmbeddings: [a], personID: known.id, confirmed: true),
            SpeakerCluster(key: "S2", talkSeconds: 9.8, centroid: b, spanEmbeddings: [b]),
        ]
        store.meetings = [m]

        // --- range: 12.0–15.9 → a typed new name, through the editor's own model.
        let model = VoiceEditorModel(meeting: m, audioURL: nil, preview: true)
        model.selection = 12.0...15.9
        let newName = "Zorvath Quill"
        let key = model.assign(.name(newName), people: store.people)
        let d = model.draft
        let mine = d.utterances.filter { $0.speakerKey == key }
        r["range_lines"] = d.utterances.map { "\($0.speakerKey) \(String(format: "%.1f-%.1f", $0.start, $0.end)): \($0.text)" }
        if key == nil { fail.append("voice editor: assign returned no speaker") }
        if mine.count != 1 || mine.first?.text != "w12 w13 w14 w15" {
            fail.append("voice editor: range 12–15.9 should hold exactly w12…w15 (got \(mine.map(\.text)))")
        }
        let s2 = d.utterances.filter { $0.speakerKey == "S2" }.map(\.text)
        if s2 != ["w10 w11", "w16 w17 w18 w19"] { fail.append("voice editor: S2 should keep w10–11 and w16–19 (got \(s2))") }
        if d.utterances.filter({ $0.speakerKey == "S1" }).count != 2 { fail.append("voice editor: S1 lines must be untouched") }
        if let k = key, let c = d.clusters.first(where: { $0.key == k }), abs(c.talkSeconds - (15.8 - 12.0)) > 0.01 {
            fail.append("voice editor: talk time not recounted (\(c.talkSeconds))")
        }
        if model.newNames[key ?? ""] != newName { fail.append("voice editor: typed name not attached to its speaker") }
        // Undo
        model.assignAll(.person(known.id), people: store.people)
        let allOne = Set(model.draft.utterances.map(\.speakerKey))
        if allOne.count != 1 || model.draft.clusters.count != 1 { fail.append("voice editor: Assign all should leave one speaker (got \(allOne))") }
        model.undo()
        if model.draft.utterances != d.utterances { fail.append("voice editor: Undo didn't restore the previous draft") }

        // --- learn + vocabulary: Save with a confirmed embedding for the new speaker.
        Vocabulary.words = ["Scribe"]
        let before = store.voiceprintUpdates
        let commit = model.commit(embeddings: [key ?? "": [confirmed]])
        let added = store.commitVoiceEdit(meetingID: m.id, commit)
        let zp = store.people.first { $0.name == newName }
        r["learn"] = ["people": store.people.map(\.name), "voiceprint_updates": store.voiceprintUpdates - before,
                      "new_person_samples": zp?.samples.count ?? 0, "vocabulary_added": added]
        if zp == nil { fail.append("voice editor: Save didn't create the typed person") }
        if store.voiceprintUpdates - before < 2 { fail.append("voice editor: voiceprint learning wasn't called for each confirmed speaker") }
        let norm = VoiceMath.normalize(confirmed)
        if let zp, !zp.samples.contains(where: { $0.meetingID == m.id && VoiceMath.cosine($0.vector, norm) > 0.999 }) {
            fail.append("voice editor: the confirmed audio's voiceprint isn't in the person's samples")
        }
        if let zp, let c = store.meetings[0].clusters.first(where: { $0.personID == zp.id }) {
            if !c.confirmed { fail.append("voice editor: assigned speaker not marked confirmed") }
            if VoiceMath.cosine(c.centroid, norm) < 0.99 { fail.append("voice editor: confirmed audio should lead the voice average") }
        } else { fail.append("voice editor: the new person has no speaker in the meeting") }
        if !Vocabulary.words.contains(newName) || added != [newName] { fail.append("voice editor: typed name not added to Vocabulary (\(Vocabulary.words))") }
        // Same name again → not added twice.
        if !Store.addToVocabulary([newName.lowercased()]).isEmpty { fail.append("voice editor: Vocabulary got a duplicate name") }
        // Survives a reload.
        let again = Store(folder: tmp)
        let saved = again.meetings.first?.utterances.filter { again.displayName(again.meetings[0], key: $0.speakerKey) == newName }.map(\.text)
        if saved != ["w12 w13 w14 w15"] { fail.append("voice editor: saved transcript lost the new speaker (\(saved ?? []))") }

        // --- space bar
        let tv = NSTextView()
        let checks: [(String, Bool, Bool)] = [
            ("space, nothing focused", VoiceEditorKeys.togglesPlayback(keyCode: 49, modifiers: [], firstResponder: nil), true),
            ("space, text field focused", VoiceEditorKeys.togglesPlayback(keyCode: 49, modifiers: [], firstResponder: tv), false),
            ("⌘space", VoiceEditorKeys.togglesPlayback(keyCode: 49, modifiers: [.command], firstResponder: nil), false),
            ("other key", VoiceEditorKeys.togglesPlayback(keyCode: 0, modifiers: [], firstResponder: nil), false),
        ]
        var sp: [String: Bool] = [:]
        for (n, got, want) in checks { sp[n] = got; if got != want { fail.append("voice editor: \(n) → \(got), want \(want)") } }
        let live = VoiceEditorModel(meeting: m, audioURL: nil)
        live.installKeys()
        sp["monitor_installed"] = live.keysInstalled
        if !live.keysInstalled { fail.append("voice editor: Space key monitor not installed") }
        live.stop()
        if live.keysInstalled { fail.append("voice editor: Space key monitor not removed on close") }
        r["space"] = sp
        return (r, fail)
    }

    @MainActor static func fixCheck() -> ([String: Any], [String]) {
        var r: [String: Any] = [:]
        var fail: [String] = []
        let keys = [Vocabulary.key, DictionaryReplacements.key, FixLearner.countsKey, FixLearner.itemsKey,
                    FixLearner.blockedKey, CorrectionStore.key]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (k, v) in zip(keys, saved) {
                if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
            }
        }
        for k in keys { UserDefaults.standard.removeObject(forKey: k) }
        Vocabulary.words = ["Scribe"]
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("st073-fix-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = Store(folder: tmp)
        func entry(_ t: String) -> DictationEntry {
            DictationEntry(date: Date(), text: t, raw: t, method: .none, audioSeconds: 2, latencySeconds: 0.2)
        }
        let d1 = entry("we fixed teh bug today"), d2 = entry("teh robot moved"), d3 = entry("ask zorvath about the plan")
        store.dictations = [d1, d2, d3]

        // Opt-in is off by default and saves nothing while off.
        r["save_corrections_default"] = CorrectionStore.enabled
        if CorrectionStore.enabled { fail.append("fixes: Save my corrections must be off by default") }

        // Replacement: learned on the 2nd identical fix, not the 1st.
        let first = store.editDictation(d1.id, text: "we fixed the bug today")
        let hasPair = { DictationReplacementsHas("teh", "the") }
        if !first.isEmpty || hasPair() { fail.append("fixes: a word fix was learned after 1 time (needs 2)") }
        let second = store.editDictation(d2.id, text: "the robot moved")
        r["after_two"] = second.map(\.label)
        if second.map(\.label) != ["teh → the"] || !hasPair() { fail.append("fixes: teh → the not learned after 2 fixes (\(second.map(\.label)))") }
        if store.learnedToast.map(\.label) != ["teh → the"] { fail.append("fixes: no toast for the learned fix") }

        // Name: learned after 1 fix, and added to Vocabulary.
        let name = store.editDictation(d3.id, text: "ask Zorvath about the plan")
        r["name"] = name.map(\.label)
        guard let nameItem = name.first, name.count == 1, nameItem.isName else {
            fail.append("fixes: capitalized name not learned after 1 fix (\(name.map(\.label)))")
            return (r, fail)
        }
        if !Vocabulary.words.contains("Zorvath") { fail.append("fixes: learned name not added to Vocabulary") }
        if !DictationReplacementsHas("zorvath", "Zorvath") { fail.append("fixes: learned name has no replacement") }
        if !FixLearner.learned.contains(where: { $0.id == nameItem.id }) { fail.append("fixes: learned list (Settings) misses the name") }

        // Undo removes it and blocks re-learning.
        store.undoLearned(nameItem)
        if Vocabulary.words.contains("Zorvath") || DictationReplacementsHas("zorvath", "Zorvath")
            || FixLearner.learned.contains(where: { $0.id == nameItem.id }) {
            fail.append("fixes: Undo didn't remove the name / replacement / list entry")
        }
        if !FixLearner.record(old: "ask zorvath now", new: "ask Zorvath now").isEmpty { fail.append("fixes: an undone fix was learned again") }
        if FixLearner.learned.count != 1 { fail.append("fixes: learned list should hold only teh → the (\(FixLearner.learned.map(\.label)))") }

        // Case-only change of an ordinary word is not a fix.
        _ = FixLearner.record(old: "the plan works", new: "The plan works")
        if !FixLearner.record(old: "the plan works", new: "The plan works").isEmpty { fail.append("fixes: sentence-start capital was learned") }

        // No length limit: 5,000 words, one changed.
        let long = (0..<5000).map { "word\($0)" }
        var fixed = long; fixed[4321] = "replaced"
        let h = FixLearner.hunks(old: long.joined(separator: " "), new: fixed.joined(separator: " "))
        r["long_text_hunks"] = h.count
        if h != [FixLearner.Hunk(from: "word4321", to: "replaced")] { fail.append("fixes: 5,000-word diff wrong (\(h.count) hunks)") }

        // Nothing saved for training while the option is off.
        if FileManager.default.fileExists(atPath: CorrectionStore.folder(tmp).path) || CorrectionStore.count(tmp) != 0 {
            fail.append("fixes: corrections were saved while the option was off")
        }
        // On: a meeting-style clip + text pair is written (local folder), Delete all clears it.
        CorrectionStore.enabled = true
        let ok = CorrectionStore.saveClip(tmp, samples: [Float](repeating: 0.1, count: 16_000), source: "meeting",
                                          original: "teh plan", corrected: "the plan")
        r["opt_in_saved"] = CorrectionStore.count(tmp)
        if !ok || CorrectionStore.count(tmp) != 1 { fail.append("fixes: opt-in didn't save a correction pair") }
        CorrectionStore.deleteAll(tmp)
        if CorrectionStore.count(tmp) != 0 { fail.append("fixes: Delete all left files") }
        return (r, fail)
    }

    static func DictationReplacementsHas(_ from: String, _ to: String) -> Bool {
        DictionaryReplacements.pairs.contains { $0.from.caseInsensitiveCompare(from) == .orderedSame && $0.to == to }
    }
}
