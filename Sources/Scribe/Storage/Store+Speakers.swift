// Store+Speakers.swift
// 0.7.2: one person = one speaker in a meeting.
//
// The diarizer sometimes splits ONE voice into two clusters (say 85 % + 12 %). Before 0.7.2,
// naming the small one after the same person left two cards with the same name. Now:
//  • Naming a speaker after someone who already has a speaker in this meeting MERGES the two
//    (their lines, talk time and voice samples become one speaker), and the person's voiceprint
//    learns from all of it.
//  • Renaming a person to the name of someone who already exists merges the two people.
//  • When a meeting is processed, a leftover speaker whose voice clearly matches a person who
//    already has a speaker here is folded into that speaker automatically (rule below). This
//    rule was NOT measured for accuracy; Re-split ("People talking") undoes it.

import Foundation

extension Store {
    /// Auto-merge rule for a leftover speaker (not confirmed, no name) whose best library match is
    /// a person who already has a speaker in this meeting:
    ///   • match ≥ `VoiceMatcher.autoMatchThreshold` (0.55), or
    ///   • match ≥ `VoiceMatcher.suggestThreshold` (0.40) AND it is a small speaker (≤ 20 % of the
    ///     talk time) AND its voice is close to that person's speaker in this meeting (cosine ≥ 0.5).
    static let mergeSmallShare = 0.20
    static let mergeCentroidSimilarity: Float = 0.5

    // MARK: Meeting titles

    /// Rename a meeting (trimmed; empty = keep the old title). Saved right away.
    func renameMeeting(_ id: UUID, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = index(of: id), !t.isEmpty, t != meetings[i].title else { return }
        meetings[i].title = t
        save()
        syncMeeting(id)
    }

    // MARK: Merging speakers inside one meeting

    /// Fold speaker `fromKey` into speaker `intoKey` in meeting `i`: its lines get the other key,
    /// talk time adds up, the voice average is talk-time weighted, voice samples are combined.
    /// Learning is NOT done here (callers decide); whatever `fromKey` had taught is undone.
    func mergeCluster(meetingIndex i: Int, from fromKey: String, into intoKey: String) {
        guard fromKey != intoKey,
              let a = meetings[i].clusters.firstIndex(where: { $0.key == intoKey }),
              let b = meetings[i].clusters.firstIndex(where: { $0.key == fromKey }) else { return }
        let meetingID = meetings[i].id
        let from = meetings[i].clusters[b]
        var into = meetings[i].clusters[a]
        if let old = from.personID, let o = people.firstIndex(where: { $0.id == old }) {
            VoiceMatcher.unlearn(person: &people[o], meetingID: meetingID, clusterKey: fromKey)
        }
        if into.centroid.count == from.centroid.count, !into.centroid.isEmpty {
            let wa = Float(max(into.talkSeconds, 0.1)), wb = Float(max(from.talkSeconds, 0.1))
            let na = VoiceMath.normalize(into.centroid), nb = VoiceMath.normalize(from.centroid)
            into.centroid = VoiceMath.normalize(zip(na, nb).map { $0 * wa + $1 * wb })
        } else if into.centroid.isEmpty {
            into.centroid = from.centroid
        }
        into.talkSeconds += from.talkSeconds
        into.spanEmbeddings += from.spanEmbeddings
        if into.personID == nil { into.personID = from.personID }
        into.confirmed = into.confirmed || from.confirmed
        into.suggestedPersonID = into.personID == nil ? (into.suggestedPersonID ?? from.suggestedPersonID) : nil
        meetings[i].clusters[a] = into
        meetings[i].clusters.remove(at: b)
        // Lines: re-key, then join back-to-back lines of the same speaker (≤ 1.5 s apart).
        var merged: [Utterance] = []
        for var u in meetings[i].utterances {
            if u.speakerKey == fromKey { u.speakerKey = intoKey }
            if var last = merged.last, last.speakerKey == u.speakerKey, u.start - last.end <= 1.5 {
                last.end = max(last.end, u.end)
                last.text = [last.text, u.text].filter { !$0.isEmpty }.joined(separator: " ")
                merged[merged.count - 1] = last
            } else {
                merged.append(u)
            }
        }
        meetings[i].utterances = merged
    }

    /// Merge every speaker in meeting `i` that belongs to `personID` into one (the one with the
    /// most talk time keeps its key). Returns the surviving key, or nil if the person has none.
    @discardableResult
    func mergeSpeakers(ofPerson personID: UUID, meetingIndex i: Int) -> String? {
        let owned = meetings[i].clusters.filter { $0.personID == personID }
            .sorted { $0.talkSeconds > $1.talkSeconds }
        guard let keep = owned.first?.key else { return nil }
        for other in owned.dropFirst() { mergeCluster(meetingIndex: i, from: other.key, into: keep) }
        return keep
    }

    /// After matching: fold leftover split-off speakers into the person's speaker (rule at the top).
    /// Returns how many speakers were folded in.
    @discardableResult
    func autoMergeSplitSpeakers(meetingIndex i: Int) -> Int {
        var merged = 0
        var changed = true
        while changed {
            changed = false
            let clusters = meetings[i].clusters
            let total = max(0.1, clusters.reduce(0) { $0 + $1.talkSeconds })
            for c in clusters where c.personID == nil && !c.confirmed {
                // Best person over the WHOLE library (people already used here included).
                var best: (id: UUID, score: Float)?
                for p in people where !p.samples.isEmpty {
                    let s = VoiceMatcher.score(c.centroid, person: p)
                    if best == nil || s > best!.score { best = (p.id, s) }
                }
                guard let best,
                      let owner = clusters.first(where: { $0.personID == best.id && $0.key != c.key }) else { continue }
                let share = c.talkSeconds / total
                let strong = best.score >= VoiceMatcher.autoMatchThreshold
                let smallAndClose = best.score >= VoiceMatcher.suggestThreshold && share <= Self.mergeSmallShare
                    && VoiceMath.cosine(c.centroid, owner.centroid) >= Self.mergeCentroidSimilarity
                if strong || smallAndClose {
                    mergeCluster(meetingIndex: i, from: c.key, into: owner.key)
                    merged += 1
                    changed = true
                    break
                }
            }
        }
        return merged
    }

    // MARK: Merging two people

    /// Move everything of person `fromID` into person `intoID` (voice samples, every meeting's
    /// speakers), merge their speakers per meeting, and delete `fromID`.
    func mergePeople(_ fromID: UUID, into intoID: UUID) {
        guard fromID != intoID, let f = people.firstIndex(where: { $0.id == fromID }),
              people.contains(where: { $0.id == intoID }) else { return }
        let moved = people[f].samples
        people.remove(at: f)
        if let t = people.firstIndex(where: { $0.id == intoID }) {
            people[t].samples += moved
            while people[t].samples.count > VoiceMatcher.maxSamplesPerPerson,
                  let oldest = people[t].samples.firstIndex(where: { !$0.isEnrollment }) {
                people[t].samples.remove(at: oldest)
            }
        }
        for i in meetings.indices {
            var touched = false
            for k in meetings[i].clusters.indices {
                if meetings[i].clusters[k].personID == fromID { meetings[i].clusters[k].personID = intoID; touched = true }
                if meetings[i].clusters[k].suggestedPersonID == fromID { meetings[i].clusters[k].suggestedPersonID = intoID }
            }
            if touched, let keep = mergeSpeakers(ofPerson: intoID, meetingIndex: i),
               let k = meetings[i].clusters.firstIndex(where: { $0.key == keep }), meetings[i].clusters[k].confirmed,
               let t = people.firstIndex(where: { $0.id == intoID }) {
                // Samples were stored under the old keys: re-learn under the surviving key.
                let mid = meetings[i].id
                people[t].samples.removeAll { $0.meetingID == mid }
                VoiceMatcher.learn(person: &people[t], from: meetings[i].clusters[k], meetingID: mid)
            }
        }
    }
}
