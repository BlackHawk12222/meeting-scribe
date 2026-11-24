// VoiceBench.swift
// `Scribe --selftest --suite voicebench` (GitHub Actions macOS runner: a virtual M1 with NO Neural
// Engine, so every number here is a runner number, not a real-Mac number).
//
// Compares dictation engines on dictation-style speech and prints every transcript, so the
// numbers can be re-scored offline:
//  • "dictation": 30 casual sentences (VoicePrompts.all), each spoken by 2-3 macOS `say` voices
//    (synthetic voices — NOT real people), 0.4 s of room before/after.
//  • "noisy10": the same clips (2 voices) with café/cafeteria crowd noise (DEMAND, CC BY-SA 3.0)
//    mixed in at 10 dB SNR.
//  • "pauses": 8 dictations with thinking pauses (1.4-2.2 s, inside and between sentences),
//    3 of them longer than 25 s of speech (Parakeet's incremental early-parts path). Three paths:
//    app (what Scribe does now), full (one pass over the raw clip, no voice detector), split
//    (each pause-separated piece transcribed alone, then TextCleanup.joinChunks).
//  • "librispeech": the 40 LibriSpeech test-clean clips (word errors only: no casing/punctuation).
// Engines: Parakeet v2, Parakeet v3, Whisper large-v3 turbo (632 MB), Whisper distil-large-v3.
// Every row: raw model text, final text (cleanup + vocabulary, as pasted), release-to-text ms.

import Foundation
import FluidAudio

enum VoiceBench {
    static let started = Date()
    /// Stop starting new work after this long (the CI step has a hard timeout).
    static var budgetSeconds: Double = 60 * 60
    static func overBudget() -> Bool { Date().timeIntervalSince(started) > budgetSeconds }

    struct Clip {
        var set: String
        var id: String
        var voice: String
        var reference: String
        var samples: [Float]
    }

    /// Spoken text ([[slnc ms]] = a silent pause inside `say`) → reference (what should be typed).
    static let pauseScripts: [(String, String)] = [
        ("p1", "I need to finish the [[slnc 1800]] physics homework before Friday."),
        ("p2", "So the plan is [[slnc 1600]] we test the robot on Tuesday [[slnc 2000]] and then fix whatever breaks."),
        ("p3", "Can you ask Priya [[slnc 1700]] if she has the Onshape files?"),
        ("p4", "The app works on my laptop. [[slnc 1800]] But it crashes when I open settings [[slnc 1500]] on the old one."),
        ("p5", "We should probably [[slnc 2200]] add a second motor to the lift."),
        ("long1", "Okay, so for the robotics notes. [[slnc 1600]] The intake is working again after we replaced the rubber bands. [[slnc 1700]] The drivetrain still pulls to the left, [[slnc 1500]] so we need to check the gear ratio on that side. [[slnc 1800]] For next week, [[slnc 1500]] Alex is going to rewrite the autonomous code in Python, [[slnc 1600]] and I will update the Onshape model and push everything to GitHub. [[slnc 1700]] Also, remind everyone that the competition is on Saturday morning."),
        ("long2", "For tonight I have three things to do. [[slnc 1600]] First, read the next chapter in the history book [[slnc 1500]] and write a short summary. [[slnc 1700]] Second, finish the math worksheet [[slnc 1600]] because it is due tomorrow morning. [[slnc 1500]] Third, study for the biology quiz on cells. [[slnc 1800]] If I have time after that, [[slnc 1500]] I want to work on my SwiftUI app [[slnc 1400]] and fix the bug in the settings screen."),
        ("long3", "Hey, just wanted to let you know [[slnc 1700]] that practice is moved to Thursday this week. [[slnc 1600]] Coach said we need to be there right after lunch [[slnc 1500]] and bring water because the gym is really hot. [[slnc 1700]] If you can't make it, [[slnc 1500]] text me or send a message in the group chat [[slnc 1600]] so I can tell everyone. [[slnc 1500]] See you there."),
    ]

    static func reference(_ spoken: String) -> String {
        spoken.replacingOccurrences(of: "\\s*\\[\\[slnc \\d+\\]\\]\\s*", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: Voices + synthesis

    /// English `say` voices on this Mac, best first (up to `max`).
    static func voices(max: Int = 3) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", "?"]
        let pipe = Pipe()
        p.standardOutput = pipe
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        var english: [String] = []
        for line in text.split(separator: "\n") {
            // "Samantha            en_US    # Hello! My name is Samantha."
            guard let r = line.range(of: #"\s+en_[A-Z]{2}\s"#, options: .regularExpression) else { continue }
            english.append(String(line[..<r.lowerBound]).trimmingCharacters(in: .whitespaces))
        }
        let preferred = ["Samantha", "Alex", "Fred", "Karen", "Moira", "Tessa", "Rishi", "Allison", "Ava", "Tom", "Susan", "Victoria"]
        var out = preferred.filter { english.contains($0) }
        let novelty = ["Albert", "Bad News", "Bahh", "Bells", "Boing", "Bubbles", "Cellos", "Good News", "Jester",
                       "Organ", "Superstar", "Trinoids", "Whisper", "Wobble", "Zarvox", "Junior", "Ralph", "Kathy"]
        out += english.filter { !out.contains($0) && !novelty.contains(where: { n in $0.hasPrefix(n) }) }
        return Array(out.prefix(max))
    }

    static func synth(_ text: String, voice: String, to url: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", voice, "-o", url.path, "--data-format=LEI16@16000", text]
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    static let roomPad = 6_400   // 0.4 s before and after, like a real hold-to-talk clip

    // MARK: Noise

    static func mix(_ x: [Float], noise: [Float], offset: Int, snr: Double) -> [Float] {
        // Speech power over 10 ms frames that aren't silent.
        var ps = 0.0, cnt = 0
        var f = 0
        while f + 160 <= x.count {
            var e = 0.0
            for i in f..<(f + 160) { e += Double(x[i] * x[i]) }
            if e / 160 > 1e-6 { ps += e; cnt += 160 }
            f += 160
        }
        ps /= Double(max(cnt, 1))
        var pn = 0.0
        for i in 0..<x.count { let v = noise[(offset + i) % noise.count]; pn += Double(v * v) }
        pn /= Double(max(x.count, 1))
        let g = Float(sqrt(ps / (max(pn, 1e-12) * pow(10, snr / 10))))
        var y = [Float](repeating: 0, count: x.count)
        var peak: Float = 0
        for i in 0..<x.count { y[i] = x[i] + g * noise[(offset + i) % noise.count]; peak = max(peak, abs(y[i])) }
        if peak > 0.99 { let s = 0.99 / peak; for i in 0..<y.count { y[i] *= s } }
        return y
    }

    // MARK: Paths

    /// What the app does: audio fed to the live voice detector in 100 ms slices, then "release".
    static func appPass(_ s: [Float], engine: DictationEngine) async throws -> (Double, Dictation.Result) {
        let session = UUID()
        await SpeechEngine.shared.liveVadStart(session: session, earlyParts: !engine.isWhisper)
        var i = 0
        while i < s.count {
            await SpeechEngine.shared.liveVadFeed(Array(s[i..<min(s.count, i + 1600)]))
            i += 1600
        }
        let t0 = Date()
        let r = try await Dictation.run(samples: s, useAI: false, removeFillers: true, live: true, session: session, engine: engine)
        return (Date().timeIntervalSince(t0), r)
    }

    /// One pass over the whole clip, no voice detector.
    static func fullRaw(_ s: [Float], engine: DictationEngine) async throws -> String {
        if engine.isWhisper { return try await WhisperEngine.shared.transcribe(s, engine: engine) }
        return try await SpeechEngine.shared.transcribeFull(s)
    }

    static func finish(_ raw: String) -> String { Vocabulary.apply(TextCleanup.rules(raw)) }

    /// Cut at silent runs ≥ 1.2 s (`say` pauses are digital silence), in the middle of each run.
    static func splitAtPauses(_ s: [Float]) -> [[Float]] {
        var cuts: [Int] = []
        var runStart: Int? = nil
        for i in 0..<s.count {
            if abs(s[i]) < 0.0005 {
                if runStart == nil { runStart = i }
            } else if let a = runStart {
                if i - a >= 19_200, a > roomPad, i < s.count - roomPad { cuts.append((a + i) / 2) }
                runStart = nil
            }
        }
        var parts: [[Float]] = []
        var prev = 0
        for c in cuts { parts.append(Array(s[prev..<c])); prev = c }
        parts.append(Array(s[prev...]))
        return parts.filter { $0.count > 1_600 }
    }

    /// Who swaps short everyday phrases for terms ("almost done" → "Xcode.", "cute" → "CAD")?
    /// The same clips with the OPTIONAL acoustic vocabulary helper switched on (it's off by default),
    /// so each row has: raw model text, + rules, + vocabulary text pass, + helper (with its swaps).
    static func helperCheck(_ clips: [Clip]) async -> [String: Any] {
        let ms = await MainActor.run { ModelStore.shared }
        do {
            try await ms.ensure(await MainActor.run { ms.vocabularyComponents })
            try await SpeechEngine.shared.loadVocabularyBoost(terms: Vocabulary.terms(from: Vocabulary.defaults))
        } catch { return ["error": "helper unavailable: \(error)"] }
        UserDefaults.standard.set(true, forKey: Vocabulary.boostKey)
        defer { UserDefaults.standard.removeObject(forKey: Vocabulary.boostKey) }
        var rows: [[String: Any]] = []
        for c in clips {
            var row: [String: Any] = ["set": "helper", "id": c.id, "voice": c.voice, "engine": "parakeet-v2",
                                      "path": "app+acoustic_helper", "ref": c.reference]
            do {
                let (t, r) = try await appPass(c.samples, engine: .parakeetV2)
                row["ms"] = (t * 1000).rounded()
                row["raw"] = r.transcript.text
                row["rules_only"] = TextCleanup.rules(r.transcript.text)
                row["final"] = r.text
                row["helper_swaps"] = r.transcript.boostReplacements
            } catch { row["error"] = "\(error)" }
            rows.append(row)
        }
        await SpeechEngine.shared.unloadVocabularyBoost()
        emit(rows, section: "parakeet-v2/helper")
        return ["clips": rows.count, "rows_with_swaps": rows.filter { !(($0["helper_swaps"] as? [String]) ?? []).isEmpty }.count]
    }

    // MARK: Run

    static func emit(_ rows: [[String: Any]], section: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["section": section, "rows": rows], options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return }
        print("VOICEBENCH_ROWS:" + s)
    }

    static func score(_ rows: [[String: Any]], key: String) -> [String: Any] {
        var total = VoiceScore()
        for r in rows {
            guard let ref = r["ref"] as? String, let hyp = r[key] as? String else { continue }
            total = total + VoiceScoring.score(reference: ref, hypothesis: hyp)
        }
        return ["wer": total.wer, "formatted_error_rate": total.formattedErrorRate,
                "cap_error_rate": total.capErrorRate, "punct_f1": total.punctF1, "ref_words": total.refWords]
    }

    static func latency(_ rows: [[String: Any]]) -> [String: Any] {
        let ms = rows.compactMap { $0["ms"] as? Double }.sorted()
        guard !ms.isEmpty else { return [:] }
        return ["mean_ms": (ms.reduce(0, +) / Double(ms.count)).rounded(), "median_ms": ms[ms.count / 2].rounded(),
                "p90_ms": ms[min(ms.count - 1, Int(Double(ms.count) * 0.9))].rounded()]
    }

    static func run() async -> [String: Any] {
        var out: [String: Any] = [
            "measured_on": "GitHub Actions macOS runner (virtual Apple M1, NO Neural Engine: Core ML runs on CPU/GPU). Not a real Mac.",
            "voices_note": "Clips are macOS `say` synthetic voices, not real people.",
        ]
        if let b = SelfTest.argValue("--budget-minutes"), let m = Double(b) { budgetSeconds = m * 60 }
        WhisperEngine.encoderOnGPU = true
        out["whisper_compute"] = "WhisperKit mel + encoder + decoder on .cpuAndGPU (runner has no Neural Engine)"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("voicebench-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 1) Clips.
        let vs = voices()
        out["voices"] = vs
        guard !vs.isEmpty else { out["error"] = "no English `say` voices on this runner"; return out }
        let silence = [Float](repeating: 0, count: roomPad)
        var dictation: [Clip] = [], pauses: [Clip] = []
        var n = 0
        for v in vs {
            for (i, sentence) in VoicePrompts.all.enumerated() {
                let url = tmp.appendingPathComponent("d\(n).wav"); n += 1
                guard synth(sentence, voice: v, to: url), let s = try? SpeechEngine.loadSamples(url) else { continue }
                dictation.append(Clip(set: "dictation", id: "d\(i + 1)", voice: v, reference: sentence, samples: silence + s + silence))
            }
            for (i, sentence) in VoicePrompts.short.enumerated() {
                let url = tmp.appendingPathComponent("d\(n).wav"); n += 1
                guard synth(sentence, voice: v, to: url), let s = try? SpeechEngine.loadSamples(url) else { continue }
                dictation.append(Clip(set: "dictation", id: "s\(i + 1)", voice: v, reference: sentence, samples: silence + s + silence))
            }
            for (id, spoken) in pauseScripts where vs.firstIndex(of: v)! < 2 {
                let url = tmp.appendingPathComponent("p\(n).wav"); n += 1
                guard synth(spoken, voice: v, to: url), let s = try? SpeechEngine.loadSamples(url) else { continue }
                pauses.append(Clip(set: "pauses", id: id, voice: v, reference: reference(spoken), samples: silence + s + silence))
            }
        }
        var noisy: [Clip] = []
        if let nw = SelfTest.argValue("--noise-wav"), let noise = try? SpeechEngine.loadSamples(URL(fileURLWithPath: nw)), !noise.isEmpty {
            let two = Set(vs.prefix(2))
            for (k, c) in dictation.enumerated() where two.contains(c.voice) {
                var m = c
                m.set = "noisy10"
                m.samples = mix(c.samples, noise: noise, offset: (k * 7 * 16_000) % noise.count, snr: 10)
                noisy.append(m)
            }
        } else {
            out["noisy_error"] = "noise file missing (--noise-wav)"
        }
        var libri: [Clip] = []
        if let dir = SelfTest.argValue("--libri-dir"),
           let data = try? Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent("refs.json")),
           let refs = try? JSONDecoder().decode([String: String].self, from: data) {
            for f in refs.keys.sorted() {
                if let s = try? SpeechEngine.loadSamples(URL(fileURLWithPath: dir).appendingPathComponent(f)) {
                    libri.append(Clip(set: "librispeech", id: f, voice: "LibriSpeech reader", reference: refs[f] ?? "", samples: s))
                }
            }
        }
        out["clips"] = ["dictation": dictation.count, "pauses": pauses.count, "noisy10": noisy.count, "librispeech": libri.count]
        out["pause_clip_seconds"] = Dictionary(uniqueKeysWithValues: pauses.filter { $0.voice == vs[0] }.map {
            ($0.id, Double($0.samples.count) / 16_000) })
        SelfTest.log("voicebench: voices \(vs), clips \(out["clips"] ?? "")")

        // 2) Engines, one at a time (load, run every set, unload).
        let ms = await MainActor.run { ModelStore.shared }
        var engines: [String: Any] = [:]
        var skipped: [String] = []
        for engine in DictationEngine.allCases {
            var e: [String: Any] = ["title": engine.title, "download_bytes": engine.downloadBytes]
            if overBudget() { skipped.append("\(engine.rawValue): all sets (time budget)"); continue }
            do {
                let td = Date()
                try await ms.ensure(engine.componentIDs + ["vad"])
                e["download_seconds"] = Date().timeIntervalSince(td)
                if engine.isWhisper {
                    // The voice detector (loaded with Parakeet), not timed.
                    try await SpeechEngine.shared.prepareDictation(model: .english, prewarm: false) { _, _ in }
                }
                let tl = Date()
                if let m = engine.speechModel {
                    try await SpeechEngine.shared.prepareDictation(model: m, prewarm: true) { _, _ in }
                } else {
                    try await WhisperEngine.shared.load(engine)
                }
                e["load_seconds"] = Date().timeIntervalSince(tl)
            } catch {
                e["error"] = "\(error)"
                engines[engine.rawValue] = e
                SelfTest.log("voicebench \(engine.rawValue): load failed \(error)")
                continue
            }
            // Warm-up call (not timed).
            if let c = dictation.first { _ = try? await appPass(c.samples, engine: engine) }

            for (setName, clips) in [("dictation", dictation), ("pauses", pauses), ("librispeech", libri), ("noisy10", noisy)] {
                if clips.isEmpty { continue }
                if overBudget() { skipped.append("\(engine.rawValue): \(setName) (time budget)"); continue }
                var rows: [[String: Any]] = []
                var fullRows: [[String: Any]] = [], splitRows: [[String: Any]] = []
                for c in clips {
                    var row: [String: Any] = ["set": setName, "id": c.id, "voice": c.voice, "engine": engine.rawValue,
                                              "path": "app", "ref": c.reference]
                    do {
                        let (t, r) = try await appPass(c.samples, engine: engine)
                        row["ms"] = (t * 1000).rounded()
                        row["raw"] = r.transcript.text
                        row["rules_only"] = TextCleanup.rules(r.transcript.text)   // cleanup without the vocabulary pass
                        row["final"] = r.text
                        row["mode"] = r.transcript.vadMode
                    } catch { row["error"] = "\(error)" }
                    rows.append(row)
                    if setName == "pauses" {
                        // One full-utterance pass, and pause-split pieces joined.
                        var fr: [String: Any] = ["set": setName, "id": c.id, "voice": c.voice, "engine": engine.rawValue,
                                                 "path": "full", "ref": c.reference]
                        do {
                            let t0 = Date()
                            let raw = try await fullRaw(c.samples, engine: engine)
                            fr["ms"] = (Date().timeIntervalSince(t0) * 1000).rounded()
                            fr["raw"] = raw; fr["final"] = finish(raw)
                        } catch { fr["error"] = "\(error)" }
                        fullRows.append(fr)
                        var sr: [String: Any] = ["set": setName, "id": c.id, "voice": c.voice, "engine": engine.rawValue,
                                                 "path": "split", "ref": c.reference]
                        do {
                            let parts = splitAtPauses(c.samples)
                            var texts: [String] = []
                            for p in parts { texts.append(try await fullRaw(p, engine: engine)) }
                            sr["pieces"] = texts
                            sr["raw"] = texts.joined(separator: " ")
                            sr["final"] = finish(TextCleanup.joinChunks(texts))
                            sr["final_naive"] = finish(texts.joined(separator: " "))
                        } catch { sr["error"] = "\(error)" }
                        splitRows.append(sr)
                    }
                }
                emit(rows + fullRows + splitRows, section: "\(engine.rawValue)/\(setName)")
                var summary: [String: Any] = ["clips": rows.count, "latency": latency(rows),
                                              "app_raw": score(rows, key: "raw"), "app_final": score(rows, key: "final")]
                if setName == "pauses" {
                    summary["full_raw"] = score(fullRows, key: "raw"); summary["full_final"] = score(fullRows, key: "final")
                    summary["split_joined_final"] = score(splitRows, key: "final")
                    summary["split_naive_final"] = score(splitRows, key: "final_naive")
                    summary["modes"] = rows.compactMap { $0["mode"] as? String }
                }
                e[setName] = summary
                SelfTest.log("voicebench \(engine.rawValue) \(setName): \(summary)")
            }
            if engine == .parakeetV2, !overBudget() {
                e["acoustic_helper_short"] = await helperCheck(dictation.filter { $0.id.hasPrefix("s") || $0.reference.contains("cute") })
            }
            engines[engine.rawValue] = e
            if engine.isWhisper { await WhisperEngine.shared.unload(engine) }
        }
        out["engines"] = engines
        out["skipped"] = skipped
        out["elapsed_seconds"] = Date().timeIntervalSince(started)
        return out
    }
}
