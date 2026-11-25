// Store+VoiceEdit.swift
// 0.7.3 "Name voices" editor: the logic behind it (the view is Views/VoiceEditorView.swift).
//
//  • VoiceEdit.assign(meeting, range, key) relabels a time range: every transcript line inside the
//    range gets the new speaker key; a line that crosses the range edge is split at the words
//    (timed words from the speech model), or, for files without word times, goes to whichever
//    side holds most of it. Back-to-back lines of one speaker are joined; talk time is recounted;
//    speakers left without lines are dropped. Pure: works on a copy (the editor's draft + undo).
//  • Store.commitVoiceEdit saves the draft: new names become people (or the existing person with
//    that name), what the old speakers taught is undone, and every confirmed speaker re-teaches
//    its person through VoiceMatcher.learn (the same path naming / merging uses). The voice
//    embeddings of the ranges you confirmed are added to that speaker and weighted ×2 in its voice
//    average. Every typed name is added to Vocabulary so the transcriber's text pass spells it.
//    The speech model itself is not retrained; only the voice library and word list change.
//  • Dictations don't keep their audio, so the editor is for meetings only.

import Foundation

enum VoiceEdit {
    /// Confirmed audio counts this much more than the rest in a speaker's voice average.
    static let confirmedWeight: Float = 2
    /// Lines of the same speaker at most this far apart are joined (same as merging speakers).
    static let joinGap = 1.5

    /// A key for a speaker the editor adds ("E1", "E2"…), unused in this meeting.
    static func newKey(in m: Meeting, avoiding extra: Set<String> = []) -> String {
        let used = Set(m.clusters.map(\.key)).union(extra)
        var n = 1
        while used.contains("E\(n)") { n += 1 }
        return "E\(n)"
    }

    /// Relabel `range` (seconds) to speaker `key`. The cluster for `key` must exist or be added by
    /// the caller (`ensureCluster`). Returns the changed copy.
    static func assign(_ m: Meeting, range: ClosedRange<Double>, toKey key: String) -> Meeting {
        var out = m
        let lo = max(0, range.lowerBound), hi = max(lo, range.upperBound)
        let words = (m.words ?? []).sorted { $0.start < $1.start }
        var lines: [Utterance] = []
        for u in m.utterances {
            let overlap = min(u.end, hi) - max(u.start, lo)
            guard overlap > 0 else { lines.append(u); continue }
            if u.start >= lo && u.end <= hi { var x = u; x.speakerKey = key; lines.append(x); continue }
            let inLine = words.filter { w in let mid = (w.start + w.end) / 2; return mid >= u.start && mid <= u.end }
            if inLine.isEmpty {
                // No word times: the side with most of the line wins.
                var x = u
                if overlap >= (u.end - u.start) / 2 { x.speakerKey = key }
                lines.append(x)
                continue
            }
            // Split at the words: runs of words inside / outside the range.
            var runs: [(inside: Bool, words: [Word])] = []
            for w in inLine {
                let mid = (w.start + w.end) / 2
                let inside = mid >= lo && mid <= hi
                if let last = runs.last, last.inside == inside { runs[runs.count - 1].words.append(w) }
                else { runs.append((inside, [w])) }
            }
            for (n, r) in runs.enumerated() {
                let start = n == 0 ? u.start : r.words.first!.start
                let end = n == runs.count - 1 ? u.end : r.words.last!.end
                lines.append(Utterance(start: start, end: end, speakerKey: r.inside ? key : u.speakerKey,
                                       text: r.words.map(\.text).joined(separator: " ")))
            }
        }
        out.utterances = join(lines.sorted { $0.start < $1.start })
        recount(&out, keep: key)
        return out
    }

    /// Joins back-to-back lines of one speaker.
    static func join(_ lines: [Utterance]) -> [Utterance] {
        var merged: [Utterance] = []
        for u in lines {
            if var last = merged.last, last.speakerKey == u.speakerKey, u.start - last.end <= joinGap {
                last.end = max(last.end, u.end)
                last.text = [last.text, u.text].filter { !$0.isEmpty }.joined(separator: " ")
                merged[merged.count - 1] = last
            } else {
                merged.append(u)
            }
        }
        return merged
    }

    /// Talk time per speaker from its lines; speakers with no lines left are dropped (except `keep`).
    static func recount(_ m: inout Meeting, keep: String? = nil) {
        var talk: [String: Double] = [:]
        for u in m.utterances { talk[u.speakerKey, default: 0] += max(0, u.end - u.start) }
        m.clusters = m.clusters.compactMap { c in
            guard talk[c.key] != nil || c.key == keep else { return nil }
            var x = c
            x.talkSeconds = talk[c.key] ?? 0
            return x
        }
    }

    /// The speaker for `personID` in this meeting (the one with most talk time), or a new empty one.
    /// `draftName` is for a name typed in the editor that isn't a person yet.
    static func ensureCluster(_ m: inout Meeting, personID: UUID?, draftKeyFor name: String? = nil,
                              existingDraftKey: String? = nil) -> String {
        if let personID, let c = m.clusters.filter({ $0.personID == personID }).max(by: { $0.talkSeconds < $1.talkSeconds }) {
            return c.key
        }
        if let k = existingDraftKey, m.clusters.contains(where: { $0.key == k }) { return k }
        let key = newKey(in: m)
        m.clusters.append(SpeakerCluster(key: key, talkSeconds: 0, centroid: [], spanEmbeddings: [],
                                         personID: personID, matchScore: nil, confirmed: true, suggestedPersonID: nil))
        return key
    }

    /// Confirmed ranges cut into 1.5–10 s pieces for the voice model (shorter pieces are skipped).
    static func embeddingSpans(_ ranges: [ClosedRange<Double>], maxPiece: Double = 10, minPiece: Double = 1.5) -> [Range<Double>] {
        var out: [Range<Double>] = []
        for r in ranges {
            var a = r.lowerBound
            while r.upperBound - a >= minPiece {
                let b = min(r.upperBound, a + maxPiece)
                out.append(a..<b)
                a = b
            }
        }
        return out
    }
}

/// What the editor hands to the store when you press Save.
struct VoiceEditCommit {
    /// The edited meeting (lines + speakers). Speakers for typed names have personID nil here.
    var draft: Meeting
    /// Speaker key → typed name (people to create, or match by name).
    var newNames: [String: String]
    /// Speaker key → voice embeddings of the ranges you confirmed for it.
    var embeddings: [String: [[Float]]]
    /// Every name typed in the editor (added to Vocabulary).
    var typedNames: [String]
    /// Speaker keys you assigned ranges to (they become confirmed).
    var confirmedKeys: Set<String>
}

extension Store {
    /// Save a "Name voices" edit. Returns the names that were new to the Vocabulary list.
    @discardableResult
    func commitVoiceEdit(meetingID: UUID, _ c: VoiceEditCommit) -> [String] {
        guard let i = index(of: meetingID) else { return [] }
        var draft = c.draft
        // 1. Typed names → people (an existing person with that name is reused).
        for (key, raw) in c.newNames {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let k = draft.clusters.firstIndex(where: { $0.key == key }) else { continue }
            let pid: UUID
            if let p = people.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                pid = p.id
            } else {
                let p = Person(name: name, colorIndex: people.count)
                people.append(p)
                pid = p.id
            }
            draft.clusters[k].personID = pid
            draft.clusters[k].suggestedPersonID = nil
        }
        // 2. Undo what this meeting's speakers taught (re-taught below from the final state).
        for old in meetings[i].clusters {
            guard let pid = old.personID, let p = people.firstIndex(where: { $0.id == pid }) else { continue }
            VoiceMatcher.unlearn(person: &people[p], meetingID: meetingID, clusterKey: old.key)
        }
        // 3. One person = one speaker: fold duplicates (a typed name that matched an existing person).
        var byPerson: [UUID: String] = [:]
        var keys = draft.clusters.map(\.key)
        for key in keys {
            guard let k = draft.clusters.firstIndex(where: { $0.key == key }), let pid = draft.clusters[k].personID else { continue }
            if let into = byPerson[pid] {
                for u in draft.utterances.indices where draft.utterances[u].speakerKey == key { draft.utterances[u].speakerKey = into }
                if let a = draft.clusters.firstIndex(where: { $0.key == into }) {
                    draft.clusters[a].spanEmbeddings += draft.clusters[k].spanEmbeddings
                    draft.clusters[a].confirmed = true
                }
                draft.clusters.remove(at: k)
            } else {
                byPerson[pid] = key
            }
        }
        draft.utterances = VoiceEdit.join(draft.utterances)
        VoiceEdit.recount(&draft)
        keys = draft.clusters.map(\.key)
        // 4. Confirmed audio → the speaker's samples + a ×2 weight in its voice average.
        var embeddings = c.embeddings
        for (key, _) in c.embeddings where !keys.contains(key) {
            // Folded into the person's surviving speaker in step 3.
            if let pid = c.draft.clusters.first(where: { $0.key == key })?.personID ?? personFor(newName: c.newNames[key]),
               let into = byPerson[pid] {
                embeddings[into, default: []] += embeddings[key] ?? []
            }
            embeddings[key] = nil
        }
        for k in draft.clusters.indices {
            let key = draft.clusters[k].key
            if c.confirmedKeys.contains(key) || embeddings[key] != nil || c.newNames[key] != nil {
                draft.clusters[k].confirmed = true
                draft.clusters[k].suggestedPersonID = nil
            }
            let conf = (embeddings[key] ?? []).filter { !$0.isEmpty }
            guard !conf.isEmpty else { continue }
            draft.clusters[k].spanEmbeddings = conf + draft.clusters[k].spanEmbeddings
            let dim = conf[0].count
            var sum = [Float](repeating: 0, count: dim)
            let oldC = draft.clusters[k].centroid
            if oldC.count == dim {
                let w = Float(max(draft.clusters[k].talkSeconds, 0.1)) / 10
                let n = VoiceMath.normalize(oldC)
                for d in 0..<dim { sum[d] += n[d] * w }
            }
            for v in conf where v.count == dim {
                let n = VoiceMath.normalize(v)
                for d in 0..<dim { sum[d] += n[d] * VoiceEdit.confirmedWeight }
            }
            draft.clusters[k].centroid = VoiceMath.normalize(sum)
        }
        // 5. Save the lines and speakers, then every confirmed speaker re-teaches its person.
        meetings[i].utterances = draft.utterances
        meetings[i].clusters = draft.clusters
        for c2 in meetings[i].clusters where c2.confirmed {
            guard let pid = c2.personID, let p = people.firstIndex(where: { $0.id == pid }) else { continue }
            VoiceMatcher.learn(person: &people[p], from: c2, meetingID: meetingID)
            voiceprintUpdates += 1
        }
        applyLibrary(to: meetingID)   // the new samples may name the rest
        let added = Self.addToVocabulary(c.typedNames)
        save()
        syncMeeting(meetingID)
        if !added.isEmpty { Task { await prepareVocabularyBoost() } }
        return added
    }

    private func personFor(newName: String?) -> UUID? {
        guard let n = newName?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty else { return nil }
        return people.first { $0.name.caseInsensitiveCompare(n) == .orderedSame }?.id
    }

    /// Adds names to the Vocabulary list (skips ones already there, any case). Returns what was added.
    @discardableResult
    nonisolated static func addToVocabulary(_ names: [String]) -> [String] {
        var list = Vocabulary.words
        var added: [String] = []
        for raw in names {
            let n = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard n.count >= 2, n.count <= 40,
                  !list.contains(where: { $0.caseInsensitiveCompare(n) == .orderedSame }) else { continue }
            list.append(n)
            added.append(n)
        }
        if !added.isEmpty { Vocabulary.words = list }
        return added
    }

    /// Voice embeddings for confirmed ranges (needs the speaker models; empty if they can't load).
    func embedRanges(meetingID: UUID, _ ranges: [ClosedRange<Double>]) async -> [[Float]] {
        guard let m = meetings.first(where: { $0.id == meetingID }) else { return [] }
        let spans = VoiceEdit.embeddingSpans(ranges)
        guard !spans.isEmpty, await prepareMeetingModels() else { return [] }
        do {
            let samples = try SpeechEngine.loadSamples(audioURL(for: m))
            return try await SpeechEngine.shared.embedSpans(samples: samples, spans: spans)
        } catch {
            return []
        }
    }
}
