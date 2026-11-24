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
//   • turn ID: every reference turn ≥ 1.5 s with one person talking (word pieces joined into turns)
//     is embedded from the (noisy) audio → closed-set % correct, and right/wrong names at 0.40 and 0.55.
//   • cluster ID: the app's flow — diarizer clusters matched with VoiceMatcher. Of the frames where
//     one person talks: share with the RIGHT name, with a WRONG name, and unnamed; for the strict rule
//     (name only ≥ 0.55, as shipped) and the loose rule (also name the 0.40–0.55 "maybe" suggestions).
//     DER with same-named clusters merged.
// Limits: AMI meeting speech is not prompted reading, and the "styles" are only loudness variety.

import Foundation
import FluidAudio

enum EnrollBench {
    struct Library { var name: String; var people: [Person] }

    /// The AMI reference is split at every word gap; join a person's pieces < `gap` s apart into turns.
    static func joinTurns(_ ref: [SelfTest.RefSeg], gap: Double = 0.5) -> [SelfTest.RefSeg] {
        var last: [String: Int] = [:]
        var out: [SelfTest.RefSeg] = []
        for s in ref.sorted(by: { $0.start < $1.start }) {
            if let i = last[s.speaker], s.start - out[i].end < gap {
                out[i].end = max(out[i].end, s.end)
            } else {
                last[s.speaker] = out.count
                out.append(s)
            }
        }
        return out
    }

    /// Seconds of `s` during which somebody else is talking.
    static func otherTalk(_ s: SelfTest.RefSeg, ref: [SelfTest.RefSeg]) -> Double {
        var other = 0.0
        for o in ref where o.speaker != s.speaker && o.start < s.end && o.end > s.start {
            other += min(o.end, s.end) - max(o.start, s.start)
        }
        return other
    }

    /// Each person's turns (pieces < 1 s apart joined) with every moment someone else talks cut out:
    /// the stretches where ONLY that person is heard. Backchannels ("yeah", "mm") are common in AMI,
    /// so rejecting whole turns that contain one leaves almost nothing.
    static func cleanPieces(_ ref: [SelfTest.RefSeg], minSeconds: Double) -> [SelfTest.RefSeg] {
        var out: [SelfTest.RefSeg] = []
        for t in joinTurns(ref, gap: 1.0) {
            let others = ref.filter { $0.speaker != t.speaker && $0.start < t.end && $0.end > t.start }
                .sorted { $0.start < $1.start }
            var cur = t.start
            for o in others {
                if o.start - cur >= minSeconds { out.append(.init(start: cur, end: o.start, speaker: t.speaker)) }
                cur = max(cur, o.end)
            }
            if t.end - cur >= minSeconds { out.append(.init(start: cur, end: t.end, speaker: t.speaker)) }
        }
        return out
    }

    /// Of the frames where exactly one person talks: share labelled with the RIGHT name, with a WRONG
    /// name (another enrolled person's name), and with no name (unknown speaker, or no speech found).
    static func nameShares(ref: [SelfTest.RefSeg], hyp: [(Double, Double, String)], limit: Double,
                           names: Set<String>) -> [String: Double] {
        let n = Int(limit * 100)
        var refLab = [[String]](repeating: [], count: n)
        func frames(_ a: Double, _ b: Double) -> Range<Int> {
            let lo = min(n, max(0, Int(a * 100)))
            return lo..<max(lo, min(n, Int(b * 100)))
        }
        for r in ref { for f in frames(r.start, r.end) { refLab[f].append(r.speaker) } }
        var hypLab = [String?](repeating: nil, count: n)
        for h in hyp { for f in frames(h.0, h.1) { hypLab[f] = h.2 } }
        var total = 0, right = 0, wrong = 0
        for f in 0..<n where Set(refLab[f]).count == 1 {
            total += 1
            guard let h = hypLab[f], names.contains(h) else { continue }
            if h == refLab[f][0] { right += 1 } else { wrong += 1 }
        }
        let t = Double(max(total, 1))
        return ["right": Double(right) / t, "wrong": Double(wrong) / t, "unnamed": Double(total - right - wrong) / t]
    }

    /// Build the enrollment libraries from one meeting's clean audio + reference turns.
    static func build(audio: [Float], ref: [SelfTest.RefSeg]) async throws -> ([Library], [String: Any]) {
        let sr = 16_000.0
        let speakers = Array(Set(ref.map(\.speaker))).sorted()
        let turnsBy = Dictionary(grouping: cleanPieces(ref, minSeconds: 2.5), by: \.speaker)
        var multi: [Person] = [], single30: [Person] = [], single5: [Person] = []
        var info: [String: Any] = [:]
        for spk in speakers {
            var cands = (turnsBy[spk] ?? [])
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
        // A close-mic style clip: the bundled dictation sample (2 LibriSpeech sentences with 1.5–2 s of
        // faint hiss around them, 15.7 s). (AMI's room-mix is recorded too quietly for a level gate.)
        guard let url = Bundle.main.url(forResource: "dictation_sample", withExtension: "wav"),
              let clip = try? SpeechEngine.loadSamples(url) else { return ["error": "dictation_sample missing"] }
        var cases: [(String, [Float])] = [("clean", clip)]
        let ranges = (try? await SpeechEngine.shared.speechRanges(clip)) ?? []
        var speech = [Bool](repeating: false, count: Int(Double(clip.count) / sr / NoisyBench.hop))
        for r in ranges {
            let lo = Int(Double(r.lowerBound) / sr / NoisyBench.hop), hi = min(speech.count, Int(Double(r.upperBound) / sr / NoisyBench.hop))
            if hi > lo { for i in lo..<hi { speech[i] = true } }
        }
        // Also an AMI room-mix turn, for reference.
        if let t = ref.filter({ s in s.end - s.start >= 5 }).first {
            let a = Int(t.start * sr), b = min(audio.count, Int(min(t.end, t.start + 8) * sr))
            if b > a { cases.append(("ami_roommix_turn", Array(audio[a..<b]))) }
        }
        for snr in [10.0, 5.0, 0.0] {
            cases.append(("crowd_\(Int(snr))dB", NoisyBench.mix(clip, noise: noise, offset: 0, snr: snr, speech: speech)))
        }
        let peak = clip.map { abs($0) }.max() ?? 1
        cases.append(("clipped", clip.map { max(-1, min(1, $0 * 3 / max(peak, 1e-6))) }))
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
        // Test turns: stretches ≥ 1.5 s where only one person talks (long ones: their middle 8 s).
        let turns = cleanPieces(ref, minSeconds: 1.5).filter { $0.end <= limit }.map { s -> (Double, Double, String) in
            let d = s.end - s.start
            if d <= 8 { return (s.start, s.end, s.speaker) }
            let m = (s.start + s.end) / 2
            return (m - 4, m + 4, s.speaker)
        }
        let te = Date()
        let embs = try await SpeechEngine.shared.embedSpans(samples: audio, spans: turns.map { $0.0..<$0.1 })
            .map(VoiceMath.normalize)
        var out: [String: Any] = ["test_turns": turns.count, "embed_seconds": Date().timeIntervalSince(te),
                                  "clusters": diarized.clusters.count]
        for lib in libraries where !lib.people.isEmpty {
            var r: [String: Any] = ["people": lib.people.count]
            let names = Set(lib.people.map(\.name))
            for mode in VoiceMatcher.ScoreMode.allCases {
                var correct = 0
                var openRight: [Float: Int] = [:], openWrong: [Float: Int] = [:]
                for (i, t) in turns.enumerated() where i < embs.count {
                    let scored = lib.people.map { ($0.name, VoiceMatcher.score(embs[i], samples: $0.samples.map(\.vector), mode: mode)) }
                    guard let best = scored.max(by: { $0.1 < $1.1 }) else { continue }
                    if best.0 == t.2 { correct += 1 }
                    for th in [VoiceMatcher.suggestThreshold, VoiceMatcher.autoMatchThreshold] where best.1 >= th {
                        if best.0 == t.2 { openRight[th, default: 0] += 1 } else { openWrong[th, default: 0] += 1 }
                    }
                }
                let n = Double(max(turns.count, 1))
                r["turn_id_\(mode.rawValue)"] = Double(correct) / n
                r["turn_right_at055_\(mode.rawValue)"] = Double(openRight[VoiceMatcher.autoMatchThreshold] ?? 0) / n
                r["turn_wrong_at055_\(mode.rawValue)"] = Double(openWrong[VoiceMatcher.autoMatchThreshold] ?? 0) / n
                r["turn_right_at040_\(mode.rawValue)"] = Double(openRight[VoiceMatcher.suggestThreshold] ?? 0) / n
                r["turn_wrong_at040_\(mode.rawValue)"] = Double(openWrong[VoiceMatcher.suggestThreshold] ?? 0) / n
            }
            // Cluster level = the app's flow: diarizer clusters matched to the library.
            //   strict = 0.5/0.6 rule: a name is shown only for a confident match (≥ 0.55).
            //   loose  = also auto-name the "maybe …?" suggestions (first-pass 0.40–0.55, and a split
            //            cluster's ≥ 0.55 second-pass match).
            for mode in [VoiceMatcher.ScoreMode.topK, .max] {
                let saved = VoiceMatcher.scoreMode
                VoiceMatcher.scoreMode = mode
                let matches = VoiceMatcher.match(clusters: diarized.clusters, people: lib.people)
                VoiceMatcher.scoreMode = saved
                let nameOf = Dictionary(uniqueKeysWithValues: lib.people.map { ($0.id, $0.name) })
                for (rule, loose) in [("strict", false), ("loose", true)] {
                    let named = diarized.segments.map { s -> (Double, Double, String) in
                        let m = matches[s.speakerId]
                        // strict = a first-pass match ≥ 0.55 (what 0.5 labels); loose = any match.
                        let use = m.map { loose || ($0.isConfident && $0.score >= VoiceMatcher.autoMatchThreshold) } ?? false
                        return (Double(s.startTimeSeconds), Double(s.endTimeSeconds), use ? (nameOf[m!.personID] ?? "?") : "spk_\(s.speakerId)")
                    }
                    let sh = nameShares(ref: ref, hyp: named, limit: limit, names: names)
                    r["\(rule)_right_\(mode.rawValue)"] = sh["right"]
                    r["\(rule)_wrong_\(mode.rawValue)"] = sh["wrong"]
                    r["\(rule)_unnamed_\(mode.rawValue)"] = sh["unnamed"]
                    // Clusters given the same name count as one speaker.
                    let segsNamed: [NoisyBench.Seg] = named.map { (start: $0.0, end: $0.1, label: $0.2) }
                    r["\(rule)_der_\(mode.rawValue)"] = NoisyBench.score(ref: ref, hyp: segsNamed, limit: limit)["der"]
                }
                r["clusters_confident_\(mode.rawValue)"] = matches.values.filter(\.isConfident).count
                r["clusters_suggested_\(mode.rawValue)"] = matches.values.filter { !$0.isConfident }.count
                r["match_scores_\(mode.rawValue)"] = matches.map { kv in
                    "\(kv.key)->\(nameOf[kv.value.personID] ?? "?"):\((kv.value.score * 1000).rounded() / 1000)"
                }.sorted().joined(separator: " ")
            }
            out[lib.name] = r
        }
        return out
    }
}
