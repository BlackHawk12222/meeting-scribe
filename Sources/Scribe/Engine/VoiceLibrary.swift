// VoiceLibrary.swift
// The "learning" part of the app. No neural network training happens here:
// the speaker model is frozen. What improves over time is the LIBRARY of voice
// samples we keep for each person. More samples, from more meetings, cover more
// of how someone sounds (tired, excited, far from the mic), so matching gets
// more reliable. This is called "enrollment".

import Foundation

enum VoiceMath {
    /// Scale a vector to length 1 so only its direction matters.
    static func normalize(_ v: [Float]) -> [Float] {
        let len = sqrt(v.reduce(0) { $0 + $1 * $1 })
        guard len > 0 else { return v }
        return v.map { $0 / len }
    }

    /// Cosine similarity: 1 = same direction (same voice), ~0 = unrelated.
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (sqrt(na) * sqrt(nb))
    }

    /// Average of several vectors, normalized.
    static func mean(_ vs: [[Float]]) -> [Float] {
        guard let first = vs.first else { return [] }
        var sum = [Float](repeating: 0, count: first.count)
        for v in vs where v.count == sum.count {
            for i in 0..<v.count { sum[i] += v[i] }
        }
        return normalize(sum)
    }
}

enum VoiceMatcher {
    // These numbers were picked from measurements (see README "How the numbers
    // were measured"). Change them here if the app is too eager or too shy.

    /// Auto-label a speaker when the best match scores at least this.
    static let autoMatchThreshold: Float = 0.55
    /// Between this and the auto threshold we only *suggest* a name ("Maybe Taylor?").
    static let suggestThreshold: Float = 0.40
    /// Keep at most this many samples per person (oldest are dropped first).
    static let maxSamplesPerPerson = 80
    /// Score = average of the K most similar samples (a "k-nearest-neighbours" vote).
    static let topK = 5

    /// How a voice is compared with a person's set of samples.
    enum ScoreMode: String, CaseIterable, Sendable {
        case topK        // mean of the K most similar samples (default)
        case max         // the single most similar sample
        case mean        // mean over all samples
        case centroid    // similarity to the average of all samples
    }
    static var scoreMode: ScoreMode = .topK

    /// How much does voice `query` sound like `person`?
    static func score(_ query: [Float], person: Person) -> Float {
        score(query, samples: person.samples.map(\.vector), mode: scoreMode)
    }

    static func score(_ query: [Float], samples: [[Float]], mode: ScoreMode) -> Float {
        guard !samples.isEmpty else { return 0 }
        if mode == .centroid { return VoiceMath.cosine(query, VoiceMath.mean(samples)) }
        let sims = samples.map { VoiceMath.cosine(query, $0) }.sorted(by: >)
        switch mode {
        case .max: return sims[0]
        case .mean: return sims.reduce(0, +) / Float(sims.count)
        default:
            let k = min(topK, sims.count)
            return sims.prefix(k).reduce(0, +) / Float(k)
        }
    }

    /// Guided enrollment ("Add person"): replace this person's earlier enrollment clips with new ones.
    static func enroll(person: inout Person, samples: [VoiceSample]) {
        person.samples.removeAll { $0.isEnrollment }
        person.samples.append(contentsOf: samples)
    }

    struct Match {
        var personID: UUID
        var score: Float
        var isConfident: Bool
    }

    /// Match every speaker cluster in a meeting to the library.
    /// Rule: one person can only be ONE cluster per meeting, so we hand out the
    /// strongest (cluster, person) pairs first ("greedy assignment").
    static func match(clusters: [SpeakerCluster], people: [Person]) -> [String: Match] {
        var pairs: [(key: String, person: UUID, score: Float)] = []
        for c in clusters {
            for p in people where !p.samples.isEmpty {
                pairs.append((c.key, p.id, score(c.centroid, person: p)))
            }
        }
        pairs.sort { $0.score > $1.score }

        var result: [String: Match] = [:]
        var usedPeople = Set<UUID>()
        for pair in pairs where pair.score >= suggestThreshold {
            if result[pair.key] != nil || usedPeople.contains(pair.person) { continue }
            result[pair.key] = Match(personID: pair.person, score: pair.score,
                                     isConfident: pair.score >= autoMatchThreshold)
            usedPeople.insert(pair.person)
        }
        // Second pass: the diarizer sometimes splits ONE person into two clusters.
        // A leftover cluster that strongly matches an already-used person gets a
        // *suggestion* ("maybe Sam?") instead of an automatic label.
        for pair in pairs where pair.score >= autoMatchThreshold && result[pair.key] == nil {
            result[pair.key] = Match(personID: pair.person, score: pair.score, isConfident: false)
        }
        return result
    }

    /// Teach the library: add this cluster's voice samples to `person`.
    static func learn(person: inout Person, from cluster: SpeakerCluster, meetingID: UUID) {
        // Remove anything we learned earlier from this same cluster (no double counting).
        person.samples.removeAll { $0.meetingID == meetingID && $0.clusterKey == cluster.key }
        let vectors = cluster.spanEmbeddings.isEmpty ? [cluster.centroid] : cluster.spanEmbeddings
        for v in vectors where !v.isEmpty {
            person.samples.append(VoiceSample(vector: VoiceMath.normalize(v), meetingID: meetingID,
                                              clusterKey: cluster.key, addedAt: Date()))
        }
        // Over the limit: drop the oldest MEETING samples first; guided-enrollment clips are kept.
        while person.samples.count > maxSamplesPerPerson,
              let oldest = person.samples.firstIndex(where: { !$0.isEnrollment }) {
            person.samples.remove(at: oldest)
        }
    }

    /// Undo `learn` (used when you re-label a speaker).
    static func unlearn(person: inout Person, meetingID: UUID, clusterKey: String) {
        person.samples.removeAll { $0.meetingID == meetingID && $0.clusterKey == clusterKey }
    }
}
