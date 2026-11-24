// EnrollBench.swift
// Simulated guided enrollment on AMI (part of `--suite noisy`, variant "enroll").
//
// Real enrollment = a person reads 6 prompts in a quiet room. We can't record that on a CI runner,
// so we SIMULATE it with real speech of the same 4 people from meeting ES2004a (clean):
//   • multi6     6 separate clips per person (3–8 s each, no overlap), picked across the loudness
//                range of that person's turns (quietest … loudest) and spread over the meeting —
//                a stand-in for "normal / question / loud / quiet / numbers / free talk".
//                One embedding per clip → 6 samples.
//   • single30   the SAME 6 clips glued together → ONE embedding (≈ a single 30 s enrollment).
//   • single5    ONE embedding from one ~5 s clip (the median-loudness clip).
//   • meeting    what 0.5 does today: the diarizer's clusters from the clean first 300 s of
//                ES2004a, named with the reference, ≤ 8 longest turns each (only 3 of the 4 people
//                talk in those 300 s, so the 4th person is missing from this library).
// Test on ES2004b and ES2004c (first 300 s, clean and with crowd noise at 10/5/0 dB):
//   • turn ID: every reference turn ≥ 1.5 s with one person talking is embedded from the (noisy)
//     audio and given the best-matching person (closed set of 4) → % correct. Also "open set":
//     % of turns named correctly at the app's suggest threshold (0.40) — wrong names count as errors.
//   • cluster ID: the app's flow — diarizer clusters matched with VoiceMatcher → ID accuracy
//     (frames carrying the right name) and DER after merging clusters that match the same person.
// Limits: AMI meeting speech is not prompted reading, and the "styles" are only loudness variety.

import Foundation
import FluidAudio

enum EnrollBench {
    struct Library { var name: String; var people: [Person] }

    /// Build the enrollment libraries from one meeting's clean audio + reference turns.
    static func build(audio: [Float], ref: [SelfTest.RefSeg]) async throws -> ([Library], [String: Any]) {
        let sr = 16_000.0
        let speakers = Array(Set(ref.map(\.speaker))).sorted()
        func overlapped(_ s: SelfTest.RefSeg) -> Bool {
            ref.contains { $0.speaker != s.speaker && $0.start < s.end && $0.end > s.start }
        }
        var multi: [Person] = [], single30: [Person] = [], single5: [Person] = []
        var info: [String: Any] = [:]
        for spk in speakers {
            var cands = ref.filter { $0.speaker == spk && $0.end - $0.start >= 3 && !overlapped($0) }
                .map { s -> (Double, Double) in (s.start, min(s.end, s.start + 8)) }
                .filter { Int($0.1 * sr) <= audio.count }
            guard cands.count >= 2 else { info[spk] = "only \(cands.count) clean turns"; continue }
            func rms(_ c: (Double, Double)) -> Float {
                let a = Int(c.0 * sr), b = Int(c.1 * sr)
                var e: Float = 0; for i in a..<b { e += audio[i] * audio[i] }
                return sqrt(e / Float(max(b - a, 1)))
            }
            cands.sort { rms($0) < rms($1) }
            let k = min(6, cands.count)
            let picks = (0..<k).map { cands[($0 * (cands.count - 1)) / max(k - 1, 1)] }
            let embs = try await SpeechEngine.shared.embedSpans(samples: audio, spans: picks.map { $0.0..<$0.1 })
            let styles = EnrollmentStyle.allCases
            let samples = embs.enumerated().map { pair in
                VoiceSample(vector: VoiceMath.normalize(pair.element), meetingID: nil,
                            clusterKey: VoiceEnrollment.tag + styles[pair.offset % styles.count].rawValue, addedAt: Date())
            }
            multi.append(Person(name: spk, samples: samples))
            // Same audio glued → one embedding.
            var glued: [Float] = []
            for p in picks { glued += audio[Int(p.0 * sr)..<Int(p.1 * sr)] }
            let g = try await SpeechEngine.shared.embedSpans(samples: glued, spans: [0..<(Double(glued.count) / sr)])
            single30.append(Person(name: spk, samples: g.map { VoiceSample(vector: VoiceMath.normalize($0), meetingID: nil, clusterKey: "enroll:single", addedAt: Date()) }))
            // One ~5 s clip, median loudness.
            let mid = cands[cands.count / 2]
            let s5 = (mid.0, min(mid.1, mid.0 + 5))
            let e5 = try await SpeechEngine.shared.embedSpans(samples: audio, spans: [s5.0..<s5.1])
            single5.append(Person(name: spk, samples: e5.map { VoiceSample(vector: VoiceMath.normalize($0), meetingID: nil, clusterKey: "enroll:single", addedAt: Date()) }))
            info[spk] = ["clips": k, "clip_seconds": picks.map { (($0.1 - $0.0) * 10).rounded() / 10 },
                         "glued_seconds": Double(glued.count) / sr] as [String: Any]
        }
        return ([Library(name: "multi6", people: multi), Library(name: "single30", people: single30),
                 Library(name: "single5", people: single5)], info)
    }

    /// The enrollment quality gate on real clips: a clean single-speaker stretch should pass; the same
    /// stretch with crowd noise at 10/5/0 dB, clipped (×30 gain), or cut to 2 s should be rejected.
    static func gateTest(audio: [Float], ref: [SelfTest.RefSeg], noise: [Float]) async -> [String: Any] {
        let sr = 16_000.0
        // Longest single-speaker turn, up to 8 s, with 0.5 s of room before it if possible.
        guard let t = ref.filter({ s in !ref.contains { $0.speaker != s.speaker && $0.start < s.end + 0.5 && $0.end > s.start - 0.5 } })
            .max(by: { $0.end - $0.start < $1.end - $1.start }) else { return ["error": "no clean turn"] }
        let a = Int(max(0, t.start - 0.5) * sr), b = min(audio.count, Int(min(t.end, t.start + 8) * sr))
        let clip = Array(audio[a..<b])
        var cases: [(String, [Float])] = [("clean", clip)]
        let speech = [Bool](repeating: true, count: Int(Double(clip.count) / sr / NoisyBench.hop))
        for snr in [10.0, 5.0, 0.0] {
            cases.append(("crowd_\(Int(snr))dB", NoisyBench.mix(clip, noise: noise, offset: 0, snr: snr, speech: speech)))
        }
        cases.append(("clipped_x30", clip.map { max(-1, min(1, $0 * 30)) }))
        cases.append(("too_short_2s", Array(clip.prefix(32_000))))
        var out: [String: Any] = ["turn_seconds": Double(clip.count) / sr]
        for (name, c) in cases {
            do {
                let r = try await VoiceEnrollment.process(samples: c, style: .reading)
                out[name] = ["accepted": r.check.ok, "problem": r.check.problem ?? "",
                             "speech_s": r.check.speechSeconds, "speech_db": Double(r.check.speechLevelDB),
                             "snr_db": Double(r.check.snrDB), "clipped": r.check.clippedFraction] as [String: Any]
            } catch { out[name] = ["error": "\(error)"] }
        }
        return out
    }

    /// Evaluate every library on one (possibly noisy) test meeting.
    static func evaluate(libraries: [Library], audio: [Float], ref: [SelfTest.RefSeg], limit: Double,
                         diarized: SpeechEngine.Diarized) async throws -> [String: Any] {
        // Test turns: one person talking, ≥ 1.5 s (long turns: their middle 8 s).
        let turns = ref.filter { s in
            s.end - s.start >= 1.5 && !ref.contains { $0.speaker != s.speaker && $0.start < s.end && $0.end > s.start }
        }.map { s -> (Double, Double, String) in
            let d = s.end - s.start
            if d <= 8 { return (s.start, s.end, s.speaker) }
            let m = (s.start + s.end) / 2
            return (m - 4, m + 4, s.speaker)
        }
        let te = Date()
        let embs = try await SpeechEngine.shared.embedSpans(samples: audio, spans: turns.map { $0.0..<$0.1 })
            .map(VoiceMath.normalize)
        var out: [String: Any] = ["test_turns": turns.count, "embed_seconds": Date().timeIntervalSince(te)]
        for lib in libraries where !lib.people.isEmpty {
            var r: [String: Any] = ["people": lib.people.count]
            for mode in VoiceMatcher.ScoreMode.allCases {
                var correct = 0, openCorrect = 0, openWrong = 0
                for (i, t) in turns.enumerated() where i < embs.count {
                    let scored = lib.people.map { ($0.name, VoiceMatcher.score(embs[i], samples: $0.samples.map(\.vector), mode: mode)) }
                    guard let best = scored.max(by: { $0.1 < $1.1 }) else { continue }
                    if best.0 == t.2 { correct += 1 }
                    if best.1 >= VoiceMatcher.suggestThreshold { if best.0 == t.2 { openCorrect += 1 } else { openWrong += 1 } }
                }
                let n = Double(max(turns.count, 1))
                r["turn_id_\(mode.rawValue)"] = Double(correct) / n
                r["turn_open_correct_\(mode.rawValue)"] = Double(openCorrect) / n
                r["turn_open_wrong_\(mode.rawValue)"] = Double(openWrong) / n
            }
            // Cluster-level (app flow), default scoring and max scoring.
            for mode in [VoiceMatcher.ScoreMode.topK, .max] {
                let saved = VoiceMatcher.scoreMode
                VoiceMatcher.scoreMode = mode
                let matches = VoiceMatcher.match(clusters: diarized.clusters, people: lib.people)
                VoiceMatcher.scoreMode = saved
                let nameOf = Dictionary(uniqueKeysWithValues: lib.people.map { ($0.id, $0.name) })
                let confident = diarized.segments.map { s -> (Double, Double, String) in
                    let m = matches[s.speakerId]
                    return (Double(s.startTimeSeconds), Double(s.endTimeSeconds),
                            m?.isConfident == true ? (nameOf[m!.personID] ?? "unknown") : "unknown")
                }
                let merged: [NoisyBench.Seg] = diarized.segments.map { s in
                    (Double(s.startTimeSeconds), Double(s.endTimeSeconds),
                     matches[s.speakerId].flatMap { nameOf[$0.personID] } ?? s.speakerId)
                }
                r["cluster_id_accuracy_\(mode.rawValue)"] = SelfTest.idAccuracy(ref: ref, hyp: confident, limit: limit)
                let split = diarized.segments.map { s -> (Double, Double, String) in
                    let m = matches[s.speakerId]
                    let ok = m.map { $0.score >= VoiceMatcher.autoMatchThreshold } ?? false
                    return (Double(s.startTimeSeconds), Double(s.endTimeSeconds), ok ? (nameOf[m!.personID] ?? "unknown") : "unknown")
                }
                let anyName = diarized.segments.map { s -> (Double, Double, String) in
                    (Double(s.startTimeSeconds), Double(s.endTimeSeconds), matches[s.speakerId].flatMap { nameOf[$0.personID] } ?? "unknown")
                }
                r["cluster_id_accuracy_split_merge_\(mode.rawValue)"] = SelfTest.idAccuracy(ref: ref, hyp: split, limit: limit)
                r["cluster_id_accuracy_all_suggestions_\(mode.rawValue)"] = SelfTest.idAccuracy(ref: ref, hyp: anyName, limit: limit)
                r["cluster_named_\(mode.rawValue)"] = matches.values.filter(\.isConfident).count
                r["der_after_merge_\(mode.rawValue)"] = NoisyBench.score(ref: ref, hyp: merged, limit: limit)["der"]
            }
            out[lib.name] = r
        }
        return out
    }
}
