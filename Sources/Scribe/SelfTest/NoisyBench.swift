// NoisyBench.swift
// `Scribe --selftest --suite noisy --noise-wav Tests/noise/crowd_noise_16k.wav --meeting-wav Tests/ES2004a_first300s.wav`
//
// How well do voice detection (VAD) and "who spoke when" (diarization) hold up in a noisy crowd?
//
// Test set (built on the fly, nothing big stored in the repo):
//   • 3 real meetings, AMI ES2004a/b/c, first 300 s each (CC-BY 4.0), same 4 people.
//   • Crowd noise: 184 s of a busy cafeteria + a university restaurant from the DEMAND noise
//     database (Tests/noise/README.md has the credit and license).
//   • Mixed at a signal-to-noise ratio (SNR) of 10, 5 and 0 dB. SNR = how much louder the meeting
//     speech is than the noise. 10 dB ≈ a lively café, 0 dB = the crowd is as loud as the talkers.
//     Speech loudness is measured only where the reference says someone is talking.
//   • AMI already has real overlapping speech (people talking at once); we score with it AND
//     without it, so you can see how much of the error comes from overlap.
//
// What each variant is (all on the same mixed audio):
//   baseline          Scribe 0.5 as shipped: pyannote Community-1 + WeSpeaker + VBx (Fa 0.2),
//                     one speaker at a time (exclusive).
//   overlap           Same, but keeps overlapping speakers (exclusiveSegments = false).
//   gate_t<x>         Baseline, then drop diarized speech where Silero VAD says "no speech"
//                     (threshold x, 0.3 s padding = "hangover").
//   vqe_*             LocalVQE (Apache-2.0, in FluidAudio 0.18.3) cleans the audio first, then the
//                     same diarizer. v1.2 = 5.5 MB, v1.3 = 19.6 MB.
//   sortformer_*      NVIDIA Sortformer (offline, 4 speaker slots) instead of pyannote.
//   lib_merge         Baseline + the voice library from the CLEAN first meeting: clusters that
//                     match the same enrolled person are merged into one speaker.
//   lib_segments      Baseline + every turn ≥ 1.5 s re-scored against the library and moved to the
//                     enrolled person it clearly matches.
//
// Metrics: DER (diarization error rate, no collar, overlap scored) = missed speech + false alarm +
// speaker confusion, as % of reference speech. "no-overlap" = same, scored only where at most one
// reference person talks. VAD: missed = % of reference speech marked silent; false alarm = % of
// non-speech marked as speech.

import Foundation
import FluidAudio

enum NoisyBench {
    typealias Seg = (start: Double, end: Double, label: String)

    static let sr = 16_000
    static let hop = 0.01        // 10 ms scoring frames

    // MARK: - Scoring

    /// DER via FluidAudio's scorer (same as the earlier BENCHMARKS numbers), plus the same score
    /// restricted to frames with ≤ 1 reference speaker (using the same speaker mapping).
    static func score(ref: [SelfTest.RefSeg], hyp: [Seg], limit: Double) -> [String: Any] {
        let r = DiarizationDER.compute(
            ref: ref.map { DERSpeakerSegment(speaker: $0.speaker, start: $0.start, end: $0.end) },
            hyp: hyp.filter { $0.end > $0.start }.map { DERSpeakerSegment(speaker: $0.label, start: $0.start, end: $0.end) })
        let n = Int(limit / hop)
        var refF = [[String]](repeating: [], count: n)
        var hypF = [[String]](repeating: [], count: n)
        func frames(_ a: Double, _ b: Double) -> Range<Int> {
            let lo = min(n, max(0, Int((a / hop).rounded())))
            return lo..<max(lo, min(n, Int((b / hop).rounded())))
        }
        for s in ref { for f in frames(s.start, s.end) where !refF[f].contains(s.speaker) { refF[f].append(s.speaker) } }
        for s in hyp {
            let m = r.mapping[s.label] ?? ("?" + s.label)
            for f in frames(s.start, s.end) where !hypF[f].contains(m) { hypF[f].append(m) }
        }
        var tot = 0, miss = 0, fa = 0, conf = 0, ovFrames = 0, refSpeakerFrames = 0
        for f in 0..<n {
            let nr = refF[f].count
            refSpeakerFrames += nr
            if nr >= 2 { ovFrames += nr; continue }
            let nh = hypF[f].count
            tot += nr
            miss += max(0, nr - nh); fa += max(0, nh - nr)
            let correct = refF[f].filter { hypF[f].contains($0) }.count
            conf += min(nr, nh) - correct
        }
        let t = Double(max(tot, 1))
        return [
            // DiarizationDER reports miss/fa/confusion in SECONDS; divide by the reference speech time.
            "der": r.der, "miss": r.miss / max(r.totalRefSpeech, 1e-9), "fa": r.falseAlarm / max(r.totalRefSpeech, 1e-9),
            "conf": r.confusion / max(r.totalRefSpeech, 1e-9),
            "der_no_overlap": Double(miss + fa + conf) / t,
            "miss_no_overlap": Double(miss) / t, "fa_no_overlap": Double(fa) / t, "conf_no_overlap": Double(conf) / t,
            "overlap_share_of_ref_speech": Double(ovFrames) / Double(max(refSpeakerFrames, 1)),
            "speakers": Set(hyp.map { $0.label }).count,
        ]
    }

    /// Frame mask of "someone is talking" from the reference.
    static func refSpeech(_ ref: [SelfTest.RefSeg], limit: Double) -> [Bool] {
        let n = Int(limit / hop)
        var m = [Bool](repeating: false, count: n)
        for s in ref {
            let lo = max(0, Int(s.start / hop)), hi = min(n, Int(s.end / hop))
            if hi > lo { for f in lo..<hi { m[f] = true } }
        }
        return m
    }

    static func mask(_ segs: [(Double, Double)], n: Int) -> [Bool] {
        var m = [Bool](repeating: false, count: n)
        for (a, b) in segs {
            let lo = max(0, Int(a / hop)), hi = min(n, Int(b / hop))
            if hi > lo { for f in lo..<hi { m[f] = true } }
        }
        return m
    }

    static func vadScore(ref: [Bool], hyp: [Bool]) -> [String: Double] {
        var sp = 0, ns = 0, miss = 0, fa = 0
        for i in 0..<min(ref.count, hyp.count) {
            if ref[i] { sp += 1; if !hyp[i] { miss += 1 } } else { ns += 1; if hyp[i] { fa += 1 } }
        }
        return ["missed_speech": Double(miss) / Double(max(sp, 1)),
                "false_alarm_of_nonspeech": Double(fa) / Double(max(ns, 1)),
                "speech_share_ref": Double(sp) / Double(max(sp + ns, 1))]
    }

    // MARK: - Mixing

    /// Speech + noise at `snr` dB. Speech power is measured over reference speech frames only.
    /// The noise bed starts at a different offset per meeting and loops.
    static func mix(_ x: [Float], noise: [Float], offset: Int, snr: Double, speech: [Bool]) -> [Float] {
        var ps = 0.0, cnt = 0
        let fs = Int(hop * Double(sr))
        for (f, on) in speech.enumerated() where on {
            let a = f * fs, b = min(x.count, a + fs)
            if a >= b { continue }
            for i in a..<b { ps += Double(x[i] * x[i]) }
            cnt += b - a
        }
        ps /= Double(max(cnt, 1))
        var nseg = [Float](repeating: 0, count: x.count)
        var pn = 0.0
        for i in 0..<x.count {
            let v = noise[(offset + i) % noise.count]
            nseg[i] = v; pn += Double(v * v)
        }
        pn /= Double(max(x.count, 1))
        let g = Float(sqrt(ps / (pn * pow(10, snr / 10))))
        var y = [Float](repeating: 0, count: x.count)
        var peak: Float = 0
        for i in 0..<x.count { y[i] = x[i] + g * nseg[i]; peak = max(peak, abs(y[i])) }
        if peak > 0.99 { let s = 0.99 / peak; for i in 0..<y.count { y[i] *= s } }   // scaling both keeps the SNR
        return y
    }

    // MARK: - Helpers

    static func segs(_ d: SpeechEngine.Diarized) -> [Seg] {
        d.segments.map { (Double($0.startTimeSeconds), Double($0.endTimeSeconds), $0.speakerId) }
    }

    /// Keep only the parts of `hyp` where `keep` is true.
    static func gate(_ hyp: [Seg], keep: [Bool]) -> [Seg] {
        var out: [Seg] = []
        let n = keep.count
        for s in hyp {
            var f = max(0, Int(s.start / hop))
            let e = min(n, Int(s.end / hop))
            while f < e {
                while f < e && !keep[f] { f += 1 }
                let a = f
                while f < e && keep[f] { f += 1 }
                if f > a { out.append((Double(a) * hop, Double(f) * hop, s.label)) }
            }
        }
        return out
    }

    static func sileroMask(_ vad: VadManager, results: [VadResult], total: Int, threshold: Float,
                           padding: Double, minSilence: Double, n: Int) async -> [Bool] {
        var cfg = VadSegmentationConfig.default
        cfg.minSpeechDuration = 0.3
        cfg.minSilenceDuration = minSilence
        cfg.maxSpeechDuration = 600
        cfg.speechPadding = padding
        cfg.negativeThreshold = max(0.01, threshold - 0.15)
        cfg.negativeThresholdOffset = 0.15
        let s = await vad.segmentSpeech(from: results, totalSamples: total, config: cfg)
        return mask(s.map { ($0.startTime, $0.endTime) }, n: n)
    }

    static func r3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }

    // MARK: - Run

    static func run(seconds: Double) async throws -> [String: Any] {
        guard let noisePath = SelfTest.argValue("--noise-wav") else {
            throw NSError(domain: "noisy", code: 1, userInfo: [NSLocalizedDescriptionKey: "--noise-wav missing"])
        }
        let wanted = Set((SelfTest.argValue("--variants") ?? "all").split(separator: ",").map(String.init))
        func on(_ v: String) -> Bool { wanted.contains("all") || wanted.contains(v) }
        let snrs: [Double?] = (SelfTest.argValue("--snrs") ?? "clean,10,5,0").split(separator: ",").map {
            $0 == "clean" ? nil : Double($0)
        }
        let meetings = (SelfTest.argValue("--meetings") ?? "ES2004a,ES2004b,ES2004c").split(separator: ",").map(String.init)

        let noise = try SpeechEngine.loadSamples(URL(fileURLWithPath: noisePath))
        var out: [String: Any] = [
            "measured_on": "GitHub Actions macOS runner (virtual M1, no Neural Engine) — not a real Mac",
            "noise": "DEMAND PCAFETER + PRESTO, channel 1, 184 s, looped (Tests/noise/README.md)",
            "noise_seconds": Double(noise.count) / Double(sr),
            "seconds_per_meeting": seconds,
        ]

        // Models
        let vad = try await VadManager(config: VadConfig(defaultThreshold: 0.75))
        var vqe12: LocalVqeManager?, vqe13: LocalVqeManager?
        var loadErrors: [String: String] = [:]
        if on("vqe12") {
            do { vqe12 = try await LocalVqeManager(config: LocalVqeConfig(variant: .v12)) } catch { loadErrors["vqe12"] = "\(error)" }
        }
        if on("vqe13") {
            do { vqe13 = try await LocalVqeManager(config: LocalVqeConfig(variant: .v13)) } catch { loadErrors["vqe13"] = "\(error)" }
        }
        var sortformers: [(String, OfflineSortformerDiarizer)] = []
        for (name, prec) in [("sortformer_fp16", ModelNames.Sortformer.ModelPrecision.fp16),
                             ("sortformer_pal", ModelNames.Sortformer.ModelPrecision.palettized)] where on(name) {
            do {
                let t = Date()
                let s = OfflineSortformerDiarizer(config: OfflineSortformerConfig(precision: prec))
                try await s.initializeFromHuggingFace()
                out["\(name)_load_seconds"] = Date().timeIntervalSince(t)
                sortformers.append((name, s))
            } catch { loadErrors[name] = "\(error)" }
        }
        out["load_errors"] = loadErrors
        SelfTest.log("noisy: models ready (\(sortformers.count) sortformer, vqe12 \(vqe12 != nil), vqe13 \(vqe13 != nil))")

        let base = DiarizerSetting.auto
        let overlapSetting = DiarizerSetting(exclusive: false)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("selftest", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var library: [Person] = []          // learned from CLEAN ES2004a, baseline clusters
        var enrollLibs: [EnrollBench.Library] = []   // simulated guided enrollment (EnrollBench.swift)
        var results: [[String: Any]] = []

        for (mi, name) in meetings.enumerated() {
            let wav: URL
            if name == "ES2004a", let local = SelfTest.argValue("--meeting-wav") {
                wav = URL(fileURLWithPath: local)
            } else {
                wav = dir.appendingPathComponent("\(name).wav")
                try await SelfTest.download(URL(string: "\(SelfTest.base)/\(name)/audio/\(name).Mix-Headset.wav")!, to: wav)
            }
            let rttm = try String(contentsOf: URL(string: "\(SelfTest.rttmBase)/\(name).rttm")!, encoding: .utf8)
            let ref = SelfTest.parseRTTM(rttm, limit: seconds)
            let clean = Array(try SpeechEngine.loadSamples(wav).prefix(Int(seconds * Double(sr))))
            let limit = Double(clean.count) / Double(sr)
            let n = Int(limit / hop)
            let speech = refSpeech(ref, limit: limit)

            for snr in snrs {
                let cond = snr.map { "snr\(Int($0))" } ?? "clean"
                SelfTest.log("noisy: \(name) \(cond)")
                let y = snr.map { mix(clean, noise: noise, offset: mi * 61 * sr, snr: $0, speech: speech) } ?? clean
                var r: [String: Any] = ["meeting": name, "condition": cond, "audio_seconds": limit]
                var variants: [String: Any] = [:]

                // --- Silero VAD on this audio (what dictation uses to trim silence) ---
                let tv = Date()
                let vres = try await vad.process(y)
                r["silero_seconds"] = Date().timeIntervalSince(tv)
                var vadOut: [String: Any] = [:]
                for t in [Float(0.5), 0.75, 0.85] {
                    // raw per-256 ms decision, no smoothing
                    var raw = [Bool](repeating: false, count: n)
                    for f in 0..<n {
                        let c = (f * Int(hop * Double(sr))) / VadManager.chunkSize
                        raw[f] = c < vres.count && vres[c].probability >= t
                    }
                    vadOut["raw_t\(t)"] = vadScore(ref: speech, hyp: raw)
                }
                // The dictation segmentation as shipped (threshold 0.75, 0.3 s padding, 1.3 s min silence)
                let dictMask = await sileroMask(vad, results: vres, total: y.count, threshold: 0.75, padding: 0.3, minSilence: 1.3, n: n)
                vadOut["dictation_segments_t0.75"] = vadScore(ref: speech, hyp: dictMask)
                for t in [Float(0.5), 0.6] {
                    let m = await sileroMask(vad, results: vres, total: y.count, threshold: t, padding: 0.3, minSilence: 1.3, n: n)
                    vadOut["dictation_segments_t\(t)"] = vadScore(ref: speech, hyp: m)
                }
                r["silero_vad"] = vadOut

                // --- Diarizer (pyannote Community-1) ---
                let tp = Date()
                let prepared = try await SpeechEngine.shared.prepareDiarization(samples: y)
                let prepSec = Date().timeIntervalSince(tp)
                let dBase = try await SpeechEngine.shared.cluster(prepared, samples: y, setting: base)
                var b = score(ref: ref, hyp: segs(dBase), limit: limit)
                b["seconds"] = prepSec + dBase.seconds
                b["rtf"] = (prepSec + dBase.seconds) / limit
                b["clusters"] = dBase.clusters.count
                variants["baseline"] = b
                // Diarizer's own speech detection, as a VAD
                variants["baseline_as_vad"] = vadScore(ref: speech, hyp: mask(segs(dBase).map { ($0.start, $0.end) }, n: n))

                if on("overlap") {
                    let d = try await SpeechEngine.shared.cluster(prepared, samples: y, setting: overlapSetting)
                    variants["overlap"] = score(ref: ref, hyp: segs(d), limit: limit)
                }
                if on("knobs") {
                    // Clustering knobs (cheap: same prepared embeddings).
                    for (k, st) in [("fa0.07", DiarizerSetting(fa: 0.07)), ("fa0.3", DiarizerSetting(fa: 0.3)),
                                    ("thr0.5", DiarizerSetting(threshold: 0.5)), ("exactly4", DiarizerSetting(speakers: 4))] {
                        let d = try await SpeechEngine.shared.cluster(prepared, samples: y, setting: st)
                        var v = score(ref: ref, hyp: segs(d), limit: limit)
                        v["clusters"] = d.clusters.count
                        variants[k] = v
                    }
                }
                if on("gate") {
                    for t in [Float(0.3), 0.5] {
                        let m = await sileroMask(vad, results: vres, total: y.count, threshold: t, padding: 0.3, minSilence: 0.5, n: n)
                        variants["gate_t\(t)"] = score(ref: ref, hyp: gate(segs(dBase), keep: m), limit: limit)
                    }
                }

                // --- Voice library (enrolled from the clean first meeting) ---
                if mi == 0 && snr == nil {
                    let der = DiarizationDER.compute(
                        ref: ref.map { DERSpeakerSegment(speaker: $0.speaker, start: $0.start, end: $0.end) },
                        hyp: segs(dBase).map { DERSpeakerSegment(speaker: $0.label, start: $0.start, end: $0.end) })
                    let mid = UUID()
                    for c in dBase.clusters {
                        guard let truth = der.mapping[c.key] else { continue }
                        if let p = library.firstIndex(where: { $0.name == truth }) {
                            VoiceMatcher.learn(person: &library[p], from: c, meetingID: mid)
                        } else {
                            var p = Person(name: truth)
                            VoiceMatcher.learn(person: &p, from: c, meetingID: mid)
                            library.append(p)
                        }
                    }
                    out["library"] = library.map { "\($0.name):\($0.samples.count)" }.joined(separator: " ")
                    if on("enroll") {
                        // Enrollment clips come from the WHOLE clean ES2004a (all 4 people talk in it).
                        do {
                            let full = dir.appendingPathComponent("ES2004a_full.wav")
                            try await SelfTest.download(URL(string: "\(SelfTest.base)/ES2004a/audio/ES2004a.Mix-Headset.wav")!, to: full)
                            let fullAudio = try SpeechEngine.loadSamples(full)
                            let fullRef = SelfTest.parseRTTM(rttm, limit: Double(fullAudio.count) / Double(sr))
                            let (libs, info) = try await EnrollBench.build(audio: fullAudio, ref: fullRef)
                            enrollLibs = libs + [EnrollBench.Library(name: "meeting", people: library)]
                            out["enroll_build"] = info
                            out["enroll_gate_test"] = await EnrollBench.gateTest(audio: fullAudio, ref: fullRef, noise: noise)
                        } catch { out["enroll_build_error"] = "\(error)" }
                    }
                } else if mi > 0 && !library.isEmpty && (on("lib_merge") || on("lib_segments")) {
                    let matches = VoiceMatcher.match(clusters: dBase.clusters, people: library)
                    let nameOf: [UUID: String] = Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0.name) })
                    // Any match (confident, suggestion, or a split cluster's second-pass suggestion) → that person.
                    var label: [String: String] = [:]
                    for c in dBase.clusters { label[c.key] = matches[c.key].flatMap { nameOf[$0.personID] } ?? c.key }
                    let merged = segs(dBase).map { (s: Seg) -> Seg in (s.start, s.end, label[s.label] ?? s.label) }
                    if on("lib_merge") {
                        var m = score(ref: ref, hyp: merged, limit: limit)
                        m["id_accuracy"] = SelfTest.idAccuracy(ref: ref, hyp: merged.map { ($0.start, $0.end, $0.label) }, limit: limit)
                        // For comparison: what the 0.5 app shows (only confident matches named).
                        let shipped = segs(dBase).map { (s: Seg) -> (Double, Double, String) in
                            let mt = matches[s.label]
                            return (s.start, s.end, (mt?.isConfident == true) ? (nameOf[mt!.personID] ?? "unknown") : "unknown")
                        }
                        m["id_accuracy_shipped_rule"] = SelfTest.idAccuracy(ref: ref, hyp: shipped, limit: limit)
                        variants["lib_merge"] = m
                    }
                    if on("lib_segments") {
                        let tl = Date()
                        let long = merged.enumerated().filter { $0.element.end - $0.element.start >= 1.5 }
                        let embs = try await SpeechEngine.shared.embedSpans(samples: y, spans: long.map { $0.element.start..<$0.element.end })
                        var relabeled = merged
                        var moved = 0
                        for (k, (idx, s)) in long.enumerated() where k < embs.count {
                            let scores = library.map { (p: Person) -> (String, Float) in
                                (p.name, VoiceMatcher.score(VoiceMath.normalize(embs[k]), person: p))
                            }.sorted { $0.1 > $1.1 }
                            guard let best = scores.first else { continue }
                            let second = scores.count > 1 ? scores[1].1 : 0
                            if best.1 >= 0.45 && best.1 - second >= 0.10 && best.0 != s.label {
                                relabeled[idx] = (s.start, s.end, best.0); moved += 1
                            }
                        }
                        var m = score(ref: ref, hyp: relabeled, limit: limit)
                        m["id_accuracy"] = SelfTest.idAccuracy(ref: ref, hyp: relabeled.map { ($0.start, $0.end, $0.label) }, limit: limit)
                        m["turns_scored"] = long.count
                        m["turns_moved"] = moved
                        m["extra_seconds"] = Date().timeIntervalSince(tl)
                        variants["lib_segments"] = m
                    }
                }

                // --- Simulated guided enrollment vs meeting-learned library ---
                if mi > 0 && on("enroll") && !enrollLibs.isEmpty {
                    do {
                        variants["enroll_eval"] = try await EnrollBench.evaluate(
                            libraries: enrollLibs, audio: y, ref: ref, limit: limit, diarized: dBase)
                    } catch { variants["enroll_eval_error"] = "\(error)" }
                }

                // --- Speech enhancement first (LocalVQE), then the same diarizer ---
                for (vname, mgr) in [("vqe12", vqe12), ("vqe13", vqe13)] {
                    guard let mgr else { continue }
                    do {
                        let te = Date()
                        let z = try await mgr.process(mic: y)
                        let enhSec = Date().timeIntervalSince(te)
                        let tp2 = Date()
                        let p2 = try await SpeechEngine.shared.prepareDiarization(samples: z)
                        let d2 = try await SpeechEngine.shared.cluster(p2, samples: z, setting: base)
                        var v = score(ref: ref, hyp: segs(d2), limit: limit)
                        v["enhance_seconds"] = enhSec
                        v["enhance_rtf"] = enhSec / limit
                        v["diarize_seconds"] = Date().timeIntervalSince(tp2)
                        v["clusters"] = d2.clusters.count
                        variants[vname] = v
                        let vz = try await vad.process(z)
                        let mz = await sileroMask(vad, results: vz, total: z.count, threshold: 0.75, padding: 0.3, minSilence: 1.3, n: n)
                        variants["\(vname)_silero_dictation_segments_t0.75"] = vadScore(ref: speech, hyp: mz)
                    } catch { variants["\(vname)_error"] = "\(error)" }
                }

                // --- Sortformer instead of pyannote ---
                for (sname, s) in sortformers {
                    do {
                        let ts = Date()
                        let tl = try s.processComplete(y)
                        let sec = Date().timeIntervalSince(ts)
                        var hyp: [Seg] = []
                        for (idx, spk) in tl.speakers {
                            for g in spk.finalizedSegments { hyp.append((Double(g.startTime), Double(g.endTime), "SF\(idx)")) }
                        }
                        var v = score(ref: ref, hyp: hyp, limit: limit)
                        v["seconds"] = sec
                        v["rtf"] = sec / limit
                        variants[sname] = v
                    } catch { variants["\(sname)_error"] = "\(error)" }
                }

                r["variants"] = variants
                results.append(r)
                let brief = variants.compactMap { kv -> String? in
                    guard let d = (kv.value as? [String: Any])?["der"] as? Double else { return nil }
                    return "\(kv.key)=\(String(format: "%.3f", d))"
                }.sorted().joined(separator: " ")
                SelfTest.log("noisy: \(name) \(cond): \(brief)")
                out["results"] = results
                SelfTest.checkpoint(["noisy": out])
            }
        }
        out["results"] = results
        if on("dictation"), let libri = SelfTest.argValue("--libri-dir") {
            do { out["dictation_in_noise"] = try await DictationNoiseBench.run(libriDir: libri, noise: noise, snrs: snrs, vad: vad) }
            catch { out["dictation_in_noise_error"] = "\(error)" }
        }
        return out
    }
}
