// DictationNoiseBench.swift
// Dictation in a crowd (part of `--suite noisy`, variant "dictation").
// 20 LibriSpeech test-clean sentences (CC-BY 4.0), each with 1.5 s of room before and after (like a
// real hold-to-talk clip), mixed with the DEMAND crowd noise at 10/5/0 dB. For each clip the Silero
// voice detector trims the audio the way dictation does (0.3 s padding, splits only at ≥ 1.3 s of
// silence, pauses glued as 0.3 s), at different thresholds, then Parakeet v2 transcribes it.
// "none" = no trimming at all. Word error rate (WER) shows whether trimming drops words in noise.

import Foundation
import FluidAudio

enum DictationNoiseBench {
    static func run(libriDir: String, noise: [Float], snrs: [Double?], vad: VadManager) async throws -> [String: Any] {
        try await SpeechEngine.shared.prepareDictation(model: .english, prewarm: false) { _, _ in }
        let refsURL = URL(fileURLWithPath: libriDir).appendingPathComponent("refs.json")
        let refs = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: refsURL))
        let files = Array(refs.keys.sorted().prefix(20))
        let pad = 24_000
        let thresholds: [Float?] = [nil, 0.75, 0.5, 0.3]
        var out: [String: Any] = ["clips": files.count, "padding_seconds": 1.5]
        for snr in snrs {
            let cond = snr.map { "snr\(Int($0))" } ?? "clean"
            var edits = [Int](repeating: 0, count: thresholds.count)
            var kept = [Double](repeating: 0, count: thresholds.count)
            var words = 0, total = 0.0
            for (fi, f) in files.enumerated() {
                let s = try SpeechEngine.loadSamples(URL(fileURLWithPath: libriDir).appendingPathComponent(f))
                let x = [Float](repeating: 0, count: pad) + s + [Float](repeating: 0, count: pad)
                var speech = [Bool](repeating: false, count: Int(Double(x.count) / 16_000 / NoisyBench.hop))
                let a = Int(Double(pad) / 16_000 / NoisyBench.hop), b = min(speech.count, a + Int(Double(s.count) / 16_000 / NoisyBench.hop))
                if b > a { for i in a..<b { speech[i] = true } }
                let y = snr.map { NoisyBench.mix(x, noise: noise, offset: fi * 7 * 16_000, snr: $0, speech: speech) } ?? x
                total += Double(y.count) / 16_000
                let vres = try await vad.process(y)
                let ref = refs[f] ?? ""
                for (ti, t) in thresholds.enumerated() {
                    var audio = y
                    if let t {
                        var cfg = SpeechEngine.segmentation(pauseTolerant: true)
                        cfg.negativeThreshold = max(0.01, t - 0.15)
                        cfg.negativeThresholdOffset = 0.15
                        let segs = await vad.segmentSpeech(from: vres, totalSamples: y.count, config: cfg)
                        let parts = segs.compactMap { seg -> [Float]? in
                            let lo = max(0, min(seg.startSample(sampleRate: 16_000), y.count))
                            let hi = max(lo, min(seg.endSample(sampleRate: 16_000), y.count))
                            return hi > lo ? Array(y[lo..<hi]) : nil
                        }
                        if !parts.isEmpty { audio = SpeechEngine.glue(parts) }   // nothing found → keep raw (as the app does)
                    }
                    kept[ti] += Double(audio.count) / 16_000
                    if audio.count < 16_000 { audio += [Float](repeating: 0, count: 16_000 - audio.count) }
                    let tr = try await SpeechEngine.shared.transcribe(samples: audio)
                    let (e, n) = SelfTest.editCount(ref: ref, hyp: tr.words.map(\.text).joined(separator: " "))
                    edits[ti] += e
                    if ti == 0 { words += n }
                }
            }
            var c: [String: Any] = ["words": words, "audio_seconds": total]
            for (ti, t) in thresholds.enumerated() {
                let k = t.map { "vad_t\($0)" } ?? "no_vad"
                c[k] = ["wer": Double(edits[ti]) / Double(max(words, 1)), "audio_kept_seconds": kept[ti]] as [String: Any]
            }
            out[cond] = c
            SelfTest.log("dictation-noise \(cond): \(c)")
        }
        return out
    }
}
