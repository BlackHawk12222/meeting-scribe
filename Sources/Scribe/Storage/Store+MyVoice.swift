// Store+MyVoice.swift
// 0.7.3.2 "My voice": the person in the voice library that is YOU (profile.myPersonID).
//  • Set up    – the guided enrollment (six short lines) creates or updates that person.
//  • Train it more – one more short clip is added to the voiceprint (kept like the enrollment
//    clips, tagged "enroll:more-…"; at most `maxExtraClips`, the oldest extra is dropped first).
//  • Test it   – a ~5 s clip is compared with the voiceprint (VoiceMatcher.score) and with
//    everyone else in the library; the verdict is put in plain words (MyVoice.verdict).
//  • Re-record from scratch – the old voiceprint is cleared before the new enrollment is saved.
//  • Delete my voice – every voice sample of that person is removed (meetings keep the name).
// Everything stays on this Mac (voices.json, profile.json). Account sync only uploads
// voiceprints when the user turns that on, and then encrypted (Account/SyncPayload.swift).

import Foundation

enum MyVoice {
    /// Extra "Train it more" clips kept on top of the guided enrollment.
    static let maxExtraClips = 12
    static let extraTag = VoiceEnrollment.tag + "more-"

    /// The score a voice needs to be named automatically in meetings (same rule as VoiceMatcher.match).
    static var threshold: Float { VoiceMatcher.nameLikelyMatches ? VoiceMatcher.suggestThreshold : VoiceMatcher.autoMatchThreshold }
    /// Scores at or above this are a "strong" match.
    static let strongScore: Float = 0.70

    struct Verdict: Equatable {
        var matched: Bool
        /// "Matched you — strong match"
        var headline: String
        /// "Score 0.74 · Scribe names you from 0.40"
        var detail: String
    }

    /// Plain-words result of "Test it". `other` = the best-scoring other person, if they beat you.
    static func verdict(score: Float, other: (name: String, score: Float)? = nil) -> Verdict {
        let t = threshold
        let detail = String(format: "Score %.2f · Scribe names you from %.2f", score, t)
        if let o = other, o.score > score, o.score >= t {
            return Verdict(matched: false, headline: "Sounded more like \(o.name)",
                           detail: detail + " · \(o.name) scored " + String(format: "%.2f", o.score) + ". Train it more.")
        }
        if score >= strongScore { return Verdict(matched: true, headline: "Matched you — strong match", detail: detail) }
        if score >= VoiceMatcher.autoMatchThreshold { return Verdict(matched: true, headline: "Matched you — good match", detail: detail) }
        if score >= t { return Verdict(matched: true, headline: "Matched you — weak match", detail: detail + ". Train it more to make it surer.") }
        return Verdict(matched: false, headline: "Didn't match you", detail: detail + ". Try a quieter spot, or train it more.")
    }
}

extension Store {
    /// You, in the voice library (nil until My voice is set up, or if that person was deleted).
    var myPerson: Person? { person(profile.myPersonID) }

    /// Set up = your person exists and has at least one guided-enrollment clip.
    var myVoiceEnrolled: Bool { myPerson?.samples.contains { $0.isEnrollment } == true }

    /// Same rules as People (VoiceStrength.of).
    var myVoiceStrength: VoiceStrength? {
        guard let me = myPerson, myVoiceEnrolled else { return nil }
        return personSummaries().first { $0.person.id == me.id }?.strength
    }

    /// How many clips taught the voiceprint (guided lines + Train it more).
    var myVoiceClipCount: Int { myPerson?.samples.filter(\.isEnrollment).count ?? 0 }

    /// The name used for you in the library: the Profile name, else "Me".
    var myVoiceName: String {
        let t = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Me" : t
    }

    /// Guided enrollment for you. `fromScratch` drops every earlier sample first (Re-record).
    @discardableResult
    func enrollMe(clips: [(EnrollmentStyle, [Float])], fromScratch: Bool = false) -> UUID? {
        guard !clips.isEmpty else { return nil }
        let samples = VoiceEnrollment.samples(from: clips)
        if let i = people.firstIndex(where: { $0.id == profile.myPersonID }) {
            if fromScratch { people[i].samples.removeAll() }
            VoiceMatcher.enroll(person: &people[i], samples: samples)
            save()
            return people[i].id
        }
        var me = Person(name: uniqueName(myVoiceName), colorIndex: people.count)
        VoiceMatcher.enroll(person: &me, samples: samples)
        people.append(me)
        profile.myPersonID = me.id
        saveProfile()
        save()
        return me.id
    }

    /// "Train it more": add one more clip's embedding to your voiceprint.
    @discardableResult
    func trainMyVoice(embedding: [Float]) -> Bool {
        guard let i = people.firstIndex(where: { $0.id == profile.myPersonID }), !embedding.isEmpty else { return false }
        let n = people[i].samples.filter { $0.clusterKey?.hasPrefix(MyVoice.extraTag) == true }.count
        people[i].samples.append(VoiceSample(vector: VoiceMath.normalize(embedding), meetingID: nil,
                                             clusterKey: MyVoice.extraTag + "\(n + 1)", addedAt: Date()))
        while people[i].samples.filter({ $0.clusterKey?.hasPrefix(MyVoice.extraTag) == true }).count > MyVoice.maxExtraClips,
              let oldest = people[i].samples.firstIndex(where: { $0.clusterKey?.hasPrefix(MyVoice.extraTag) == true }) {
            people[i].samples.remove(at: oldest)
        }
        save()
        return true
    }

    /// "Test it": score a clip's embedding against you and against everyone else.
    func testMyVoice(embedding: [Float]) -> MyVoice.Verdict? {
        guard let me = myPerson, myVoiceEnrolled else { return nil }
        let q = VoiceMath.normalize(embedding)
        let mine = VoiceMatcher.score(q, person: me)
        let best = people.filter { $0.id != me.id && !$0.samples.isEmpty }
            .map { (name: $0.name, score: VoiceMatcher.score(q, person: $0)) }
            .max { $0.score < $1.score }
        return MyVoice.verdict(score: mine, other: best)
    }

    /// "Delete my voice": remove every voice sample of yours. The person (and the name on your
    /// lines in past meetings) stays; My voice goes back to its setup prompt.
    func deleteMyVoice() {
        guard let i = people.firstIndex(where: { $0.id == profile.myPersonID }) else { return }
        people[i].samples.removeAll()
        save()
    }

    private func uniqueName(_ base: String) -> String {
        // Reuse "Robin" if the library already has a Robin with no voiceprint? No: never merge into
        // someone else silently. Add a suffix instead.
        var name = base, k = 2
        while people.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            name = "\(base) (me)"
            if k > 2 { name = "\(base) (me \(k))" }
            k += 1
        }
        return name
    }
}
