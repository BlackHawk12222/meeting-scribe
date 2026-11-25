// Store+Fixes.swift
// 0.7.3: editing a dictation's text or a meeting transcript line, and learning from the edit
// (Engine/FixLearner.swift). Speaker fixes keep teaching voiceprints as before (Name voices,
// Name speaker); this file is only about words.

import Foundation

extension Store {
    /// Save an edited dictation. Returns what was learned (also shown in the toast).
    @discardableResult
    func editDictation(_ id: UUID, text: String) -> [LearnedFix] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = dictations.firstIndex(where: { $0.id == id }), !t.isEmpty, t != dictations[i].text else { return [] }
        let old = dictations[i].text
        dictations[i].text = t
        save()
        CorrectionStore.saveDictation(folder, id: id, original: old, corrected: t)
        return learnFrom(old: old, new: t)
    }

    /// Save an edited transcript line. Returns what was learned.
    @discardableResult
    func editUtterance(meetingID: UUID, utteranceID: UUID, text: String) -> [LearnedFix] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = index(of: meetingID), let k = meetings[i].utterances.firstIndex(where: { $0.id == utteranceID }),
              !t.isEmpty, t != meetings[i].utterances[k].text else { return [] }
        let u = meetings[i].utterances[k]
        meetings[i].utterances[k].text = t
        save()
        syncMeeting(meetingID)
        if CorrectionStore.enabled {
            let url = audioURL(for: meetings[i]), base = folder
            Task.detached(priority: .utility) {
                guard let all = try? SpeechEngine.loadSamples(url) else { return }
                let a = max(0, min(all.count, Int(u.start * 16_000))), b = max(a, min(all.count, Int(u.end * 16_000)))
                CorrectionStore.saveClip(base, samples: Array(all[a..<b]), source: "meeting", original: u.text, corrected: t)
            }
        }
        return learnFrom(old: u.text, new: t)
    }

    private func learnFrom(old: String, new: String) -> [LearnedFix] {
        let learned = FixLearner.record(old: old, new: new)
        if !learned.isEmpty {
            learnedToast = learned
            if learned.contains(where: { !$0.addedWords.isEmpty }) { Task { await prepareVocabularyBoost() } }
        }
        return learned
    }

    /// Toast Undo / Settings remove.
    func undoLearned(_ item: LearnedFix) {
        FixLearner.undo(item)
        learnedToast.removeAll { $0.id == item.id }
        if !item.addedWords.isEmpty { Task { await prepareVocabularyBoost() } }
    }
}
