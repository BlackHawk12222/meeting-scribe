// SelfTest.swift
// Headless test used on the GitHub Actions Mac runner:
//   Scribe.app/Contents/MacOS/Scribe --selftest [--suite quick|full] [--seconds 300]
//
// QUICK suite (every CI build):
//   • Dictation: the bundled 16 s clip (2 LibriSpeech sentences with silence around them)
//     goes through the SAME pipeline as the hotkey: Silero VAD trim -> Parakeet -> cleanup.
//     Records word error rate (WER) and speed (real-time factor).
//   • Rule-based cleanup on a few made-up sentences with "um"/"uh".
//   • Meeting notes on 300 s of AMI meeting ES2004a (Apple Intelligence if the runner has it,
//     otherwise the no-AI quick notes).
//
// FULL suite (adds the speaker-ID test below):
// It uses three real meetings with the SAME four people (AMI corpus ES2004a/b/c,
// CC-BY 4.0) and their reference "who spoke when" labels, then:
//   1. meeting A: diarize + transcribe, score DER, "name" each speaker using the
//      reference labels (pretending to be the user clicking names) -> library learns.
//   2. meeting B: identify speakers with the library, score accuracy, then learn B.
//   3. meeting C: identify with library(A) and with library(A+B) -> does more
//      enrollment help?
// It prints one JSON line starting with SELFTEST_JSON: so CI can save the numbers.

import Foundation
import FluidAudio

enum SelfTest {
    static func runAndExit() -> Never {
        Task.detached {
            let code = await run()
            exit(code)
        }
        dispatchMain()
    }

    /// Downloads the DICTATION models (Parakeet v2 + VAD) from scratch into a temporary
    /// folder with Scribe's parallel downloader and times it. Numbers are from wherever this
    /// runs (on CI: a GitHub macOS runner in a data center, not a home connection).
    static func measureDownload() async -> [String: Any] {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dl-measure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = await MainActor.run {
            ModelStore(root: tmp.appendingPathComponent("Models"), receiptsURL: tmp.appendingPathComponent("receipts.json"))
        }
        let ids = await MainActor.run { store.dictationComponents(.english) }
        let bytes = await MainActor.run { ids.compactMap { store.manifest?.component($0)?.totalBytes }.reduce(0, +) }
        let t0 = Date()
        do {
            try await store.ensure(ids)
            let sec = Date().timeIntervalSince(t0)
            // Second ensure must download nothing ("never re-download what's present").
            let t1 = Date()
            try await store.ensure(ids)
            let recheck = Date().timeIntervalSince(t1)
            log(String(format: "download measurement: %.1f MB in %.1f s (%.1f MB/s), recheck %.3f s",
                       Double(bytes) / 1e6, sec, Double(bytes) / 1e6 / sec, recheck))
            return ["where": "GitHub Actions macOS runner (data-center network)",
                    "what": "dictation models: Parakeet v2 + Silero VAD, parallel 8 MB range pieces, 8 at once, incl. SHA-256 check",
                    "bytes": bytes, "seconds": sec, "mb_per_s": Double(bytes) / 1e6 / sec,
                    "recheck_seconds": recheck]
        } catch {
            return ["error": "\(error)"]
        }
    }

    /// Key-release → text latency, as the app does it: the clip is fed to the live voice detector
    /// in 100 ms slices first (that happens WHILE you talk in the app), then the clock starts
    /// at "release". Cold = first call after loading (no prewarm); warm = later calls.
    static func latencyTest() async throws -> [String: Any] {
        guard let wav = Bundle.main.url(forResource: "dictation_sample", withExtension: "wav") else { return [:] }
        let clip = try SpeechEngine.loadSamples(wav)
        func release(_ samples: [Float], live: Bool) async throws -> (Double, Dictation.Result) {
            if live {
                await SpeechEngine.shared.liveVadStart()
                var i = 0
                while i < samples.count {
                    await SpeechEngine.shared.liveVadFeed(Array(samples[i..<min(samples.count, i + 1600)]))
                    i += 1600
                }
            }
            let t0 = Date()
            let r = try await Dictation.run(samples: samples, useAI: false, removeFillers: true, live: live)
            return (Date().timeIntervalSince(t0), r)
        }
        let (cold, coldR) = try await release(clip, live: true)
        var warm: [Double] = []
        var warmR: Dictation.Result?
        for _ in 0..<3 {
            let (t, r) = try await release(clip, live: true)
            warm.append(t); warmR = r
        }
        let (batch, batchR) = try await release(clip, live: false)
        let short = Array(clip.prefix(16_000 * 2))           // 2 s: skips the voice detector
        let (shortT, shortR) = try await release(short, live: false)
        let ms = { (x: Double) in (x * 1000).rounded() }
        log("latency cold \(ms(cold)) ms, warm \(warm.map(ms)) ms, one-pass VAD \(ms(batch)) ms, 2 s clip \(ms(shortT)) ms")
        return [
            "measured_on": "GitHub Actions macOS runner (virtual Mac, no Neural Engine); a real Apple Silicon Mac should be faster",
            "clip_seconds": Double(clip.count) / 16_000,
            "cold_release_to_text_ms": ms(cold),
            "cold_breakdown_ms": ["vad": ms(coldR.transcript.vadSeconds), "asr": ms(coldR.transcript.asrSeconds),
                                  "vad_mode": coldR.transcript.vadMode] as [String: Any],
            "warm_release_to_text_ms": warm.map(ms),
            "warm_breakdown_ms": ["vad": ms(warmR?.transcript.vadSeconds ?? 0), "asr": ms(warmR?.transcript.asrSeconds ?? 0),
                                  "vad_mode": warmR?.transcript.vadMode ?? ""] as [String: Any],
            "warm_one_pass_vad_ms": ms(batch), "one_pass_vad_part_ms": ms(batchR.transcript.vadSeconds),
            "short_2s_clip_ms": ms(shortT), "short_clip_vad_mode": shortR.transcript.vadMode,
            "same_text_live_vs_one_pass": (warmR?.text ?? "") == batchR.text,
            "note": "Excludes the 150 ms the app keeps listening after release and the paste itself.",
        ]
    }

    struct RefSeg { var start: Double; var end: Double; var speaker: String }

    static let base = "https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus"
    static let rttmBase = "https://raw.githubusercontent.com/pyannote/AMI-diarization-setup/main/only_words/rttms/test"

    static func log(_ s: String) {
        FileHandle.standardError.write(("[selftest] " + s + "\n").data(using: .utf8)!)
    }

    static func argValue(_ name: String) -> String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    static func download(_ url: URL, to dest: URL) async throws {
        if FileManager.default.fileExists(atPath: dest.path) { return }
        let (tmp, resp) = try await URLSession.shared.download(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "selftest", code: 1, userInfo: [NSLocalizedDescriptionKey: "download failed \(url)"])
        }
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    static func parseRTTM(_ text: String, limit: Double) -> [RefSeg] {
        text.split(separator: "\n").compactMap { line in
            let p = line.split(separator: " ")
            guard p.count > 7, let s = Double(p[3]), let d = Double(p[4]), s < limit else { return nil }
            return RefSeg(start: s, end: min(s + d, limit), speaker: String(p[7]))
        }
    }

    /// Fraction of 10 ms frames (where exactly ONE reference person talks) that got that person's name.
    static func idAccuracy(ref: [RefSeg], hyp: [(Double, Double, String)], limit: Double) -> Double {
        let n = Int(limit * 100)
        var refLab = [[String]](repeating: [], count: n)
        func frames(_ a: Double, _ b: Double) -> Range<Int> {
            let lo = min(n, max(0, Int(a * 100)))
            return lo..<max(lo, min(n, Int(b * 100)))
        }
        for r in ref { for f in frames(r.start, r.end) { refLab[f].append(r.speaker) } }
        var hypLab = [String?](repeating: nil, count: n)
        for h in hyp { for f in frames(h.0, h.1) { hypLab[f] = h.2 } }
        var total = 0, ok = 0
        for f in 0..<n where Set(refLab[f]).count == 1 {
            total += 1
            if hypLab[f] == refLab[f][0] { ok += 1 }
        }
        return total == 0 ? 0 : Double(ok) / Double(total)
    }

    // MARK: - Word error rate

    /// Lowercase words without punctuation, so "Correct." and "correct" match.
    static func normWords(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
    }

    /// WER = (substitutions + deletions + insertions) / reference words (classic edit distance).
    static func wer(ref: String, hyp: String) -> Double {
        let r = normWords(ref), h = normWords(hyp)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        var prev = Array(0...h.count)
        for i in 1...r.count {
            var cur = [i] + Array(repeating: 0, count: h.count)
            if !h.isEmpty {
                for j in 1...h.count {
                    cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
                }
            }
            prev = cur
        }
        return Double(prev[h.count]) / Double(r.count)
    }

    // MARK: - Dictation test

    static func dictationTest() async throws -> [String: Any] {
        guard let wav = Bundle.main.url(forResource: "dictation_sample", withExtension: "wav"),
              let txt = Bundle.main.url(forResource: "dictation_sample", withExtension: "txt") else {
            throw NSError(domain: "selftest", code: 2, userInfo: [NSLocalizedDescriptionKey: "test clip missing from the app bundle"])
        }
        let reference = try String(contentsOf: txt, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let samples = try SpeechEngine.loadSamples(wav)
        var out: [String: Any] = ["reference": reference, "audio_seconds": Double(samples.count) / 16_000,
                                  "apple_intelligence": AppleIntelligence.statusText]
        // Run 3 times: the first run includes one-time warm-up; runs 2-3 are what you'd feel day to day.
        var runs: [[String: Any]] = []
        for i in 1...3 {
            let t0 = Date()
            let r = try await Dictation.run(samples: samples, useAI: true, removeFillers: true)
            let total = Date().timeIntervalSince(t0)
            runs.append([
                "run": i, "raw_text": r.transcript.text, "final_text": r.text, "cleanup_method": r.method.rawValue,
                "speech_seconds_after_vad": r.transcript.speechSeconds,
                "vad_seconds": r.transcript.vadSeconds, "asr_seconds": r.transcript.asrSeconds,
                "cleanup_seconds": r.cleanupSeconds, "total_seconds": total,
                "rtf": total / r.transcript.audioSeconds,
                "wer_raw": wer(ref: reference, hyp: r.transcript.text),
                "wer_final": wer(ref: reference, hyp: r.text),
            ])
            log("dictation run \(i): \(String(format: "%.2f", total)) s, text: \(r.text)")
        }
        out["runs"] = runs
        // Same clip WITHOUT the VAD trim (meeting transcriber path), to see what the trim changes.
        let noVad = try await SpeechEngine.shared.transcribe(samples: samples)
        let noVadText = noVad.words.map(\.text).joined(separator: " ")
        out["without_vad"] = ["asr_seconds": noVad.seconds, "wer": wer(ref: reference, hyp: noVadText), "text": noVadText] as [String: Any]

        // Rule-based clean-up on made-up sentences (the Mac-independent part).
        let samplesIn = [
            "Um, so I I I think, uh, we should meet on Tuesday.",
            "uh i need the robot by friday um.",
            "The error rate was low.",
            "Hmm, okay, so, uh, the the motor is, um, overheating.",
        ]
        out["rule_cleanup"] = samplesIn.map { ["in": $0, "out": TextCleanup.rules($0)] }
        // Apple Intelligence clean-up (only if this Mac has it; GitHub's virtual Macs normally don't).
        if AppleIntelligence.isAvailable {
            var ai: [[String: Any]] = []
            for text in samplesIn + ["So we need to, no wait, we have to finish the arm by Friday, uh, right?"] {
                let t0 = Date()
                let (cleaned, method) = await TextCleanup.clean(text, useAI: true, removeFillers: true)
                ai.append(["in": text, "out": cleaned, "method": method.rawValue, "seconds": Date().timeIntervalSince(t0)])
            }
            out["ai_cleanup"] = ai
        }
        return out
    }

    // MARK: - Notes test

    static func notesTest(dir: URL, seconds: Double) async throws -> [String: Any] {
        let name = "ES2004a"
        // CI passes a 300 s copy stored in the repo (Tests/), because the AMI server is sometimes down.
        let wav: URL
        if let local = argValue("--meeting-wav") {
            wav = URL(fileURLWithPath: local)
        } else {
            wav = dir.appendingPathComponent("\(name).wav")
            try await download(URL(string: "\(base)/\(name)/audio/\(name).Mix-Headset.wav")!, to: wav)
        }
        let samples = Array(try SpeechEngine.loadSamples(wav).prefix(Int(seconds * 16_000)))
        let t0 = Date()
        let processed = try await SpeechEngine.shared.process(samples: samples)
        let processSeconds = Date().timeIntervalSince(t0)
        let lines = processed.utterances.map {
            NotesLine(speaker: "Speaker " + $0.speakerKey.replacingOccurrences(of: "S", with: ""), text: $0.text)
        }
        func encode(_ n: MeetingNotes) -> [String: Any] {
            ["method": n.method.rawValue, "seconds": n.seconds, "summary": n.summary, "key_points": n.keyPoints,
             "action_items": n.actionItems.map { "\($0.task) [\($0.owner)]" }, "note": n.note ?? ""]
        }
        var out: [String: Any] = [
            "meeting": name, "audio_seconds": Double(samples.count) / 16_000,
            "transcribe_and_diarize_seconds": processSeconds, "utterances": lines.count,
            "quick_notes": encode(NotesMaker.extractive(lines: lines)),
        ]
        if AppleIntelligence.isAvailable {
            out["ai_notes"] = encode(await NotesMaker.make(lines: lines, useAI: true))
        }
        return out
    }

    static func run() async -> Int32 {
        let seconds = Double(argValue("--seconds") ?? "300") ?? 300
        let suite = argValue("--suite") ?? "quick"
        var report: [String: Any] = [
            "measured_on": "GitHub Actions macOS runner (virtual Mac, results may differ from a real Apple Silicon Mac's Neural Engine)",
            "seconds_per_meeting": seconds,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "cpu_count": ProcessInfo.processInfo.processorCount,
            "suite": suite,
            "speech_model": SpeechModel.current.title,
        ]
        do {
            // Models: ModelStore compares the bundled manifest with the disk and downloads only
            // what's missing (CI restores a model cache, so usually nothing).
            let ms = await MainActor.run { ModelStore.shared }
            let needed = await MainActor.run { ms.dictationComponents(.current) + ms.meetingComponents }
            let tm = Date()
            try await ms.ensure(needed)
            report["models_ensure_seconds"] = Date().timeIntervalSince(tm)
            let tm2 = Date()
            try await ms.ensure(needed)                     // must be a no-op now
            report["models_recheck_seconds"] = Date().timeIntervalSince(tm2)
            report["models_states"] = await MainActor.run {
                Dictionary(uniqueKeysWithValues: ms.components.map { ($0.id, ms.states[$0.id]?.label ?? "?") })
            }
            if CommandLine.arguments.contains("--measure-download") {
                report["download_measurement"] = await measureDownload()
            }

            // Load dictation models WITHOUT the launch prewarm, so the first call below is truly cold.
            let t0 = Date()
            try await SpeechEngine.shared.prepareDictation(model: .current, prewarm: false) { msg, _ in log(msg) }
            report["dictation_model_load_seconds"] = Date().timeIntervalSince(t0)
            report["latency"] = try await latencyTest()
            let t0m = Date()
            try await SpeechEngine.shared.prepareMeetings { msg, _ in log(msg) }
            report["meeting_model_load_seconds"] = Date().timeIntervalSince(t0m)
            report["model_prepare_seconds"] = Date().timeIntervalSince(t0)

            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("selftest", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            log("dictation test")
            report["dictation"] = try await dictationTest()
            log("notes test")
            do {
                report["notes"] = try await notesTest(dir: dir, seconds: seconds)
            } catch {
                report["notes_error"] = "\(error)"     // keep the dictation numbers even if this fails
            }

            if suite == "full" {

            // Diarizer settings to compare. "auto" is what the app uses by default;
            // "exactly4" is what you get when you tell the app "4 people talked".
            // ("Fa0.07" = FluidAudio's own default, for comparison.)
            let settings: [DiarizerSetting] = [
                .auto,
                DiarizerSetting(fa: 0.07),
                DiarizerSetting(speakers: 4),
            ]
            var libraries: [String: [Person]] = [:]         // one voice library per setting
            var libraryAfterA: [String: [Person]] = [:]
            var perMeeting: [[String: Any]] = []

            for (idx, name) in ["ES2004a", "ES2004b", "ES2004c"].enumerated() {
                let wav = dir.appendingPathComponent("\(name).wav")
                log("downloading \(name)")
                try await download(URL(string: "\(base)/\(name)/audio/\(name).Mix-Headset.wav")!, to: wav)
                let rttmText = try String(contentsOf: URL(string: "\(rttmBase)/\(name).rttm")!, encoding: .utf8)
                let ref = parseRTTM(rttmText, limit: seconds)

                let all = try SpeechEngine.loadSamples(wav)
                let samples = Array(all.prefix(Int(seconds * 16_000)))
                let audioSec = Double(samples.count) / 16_000
                log("processing \(name) (\(Int(audioSec)) s)")

                let tPrep = Date()
                let prepared = try await SpeechEngine.shared.prepareDiarization(samples: samples)
                let prepSec = Date().timeIntervalSince(tPrep)
                let tr = try await SpeechEngine.shared.transcribe(samples: samples)

                var m: [String: Any] = [
                    "meeting": name,
                    "audio_seconds": audioSec,
                    "reference_speakers": Set(ref.map(\.speaker)).count,
                    "diarize_prepare_seconds": prepSec,
                    "transcribe_seconds": tr.seconds,
                    "transcribe_rtfx": audioSec / max(tr.seconds, 1e-6),
                    "words": tr.words.count,
                    "transcript_preview": String(tr.words.map(\.text).joined(separator: " ").prefix(240)),
                ]
                var bySetting: [String: Any] = [:]
                for setting in settings {
                    let key = setting.label
                    let d = try await SpeechEngine.shared.cluster(prepared, samples: samples, setting: setting)
                    let der = DiarizationDER.compute(
                        ref: ref.map { DERSpeakerSegment(speaker: $0.speaker, start: $0.start, end: $0.end) },
                        hyp: d.segments.map {
                            DERSpeakerSegment(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
                        })
                    let oracle = d.segments.map {
                        (Double($0.startTimeSeconds), Double($0.endTimeSeconds), der.mapping[$0.speakerId] ?? "unmapped")
                    }
                    var r: [String: Any] = [
                        "clusters_found": d.clusters.count,
                        "der": der.der, "der_miss_pct": der.miss, "der_fa_pct": der.falseAlarm, "der_conf_pct": der.confusion,
                        "cluster_seconds": d.seconds,
                        "diarize_rtfx": audioSec / max(prepSec + d.seconds, 1e-6),
                        "id_accuracy_ceiling_with_perfect_naming": idAccuracy(ref: ref, hyp: oracle, limit: seconds),
                    ]

                    func evaluate(with library: [Person]) -> [String: Any] {
                        let matches = VoiceMatcher.match(clusters: d.clusters, people: library)
                        var label: [String: String] = [:]
                        var details: [[String: Any]] = []
                        var correct = 0, decided = 0
                        for c in d.clusters {
                            let mt = matches[c.key]
                            let who = (mt?.isConfident == true) ? library.first { $0.id == mt!.personID }?.name : nil
                            label[c.key] = who ?? "unknown"
                            let truth = der.mapping[c.key] ?? "none"
                            if who != nil { decided += 1; if who == truth { correct += 1 } }
                            var scores: [String: Double] = [:]
                            for p in library { scores[p.name] = Double(VoiceMatcher.score(c.centroid, person: p)) }
                            details.append(["cluster": c.key, "talk_s": c.talkSeconds, "truth": truth,
                                            "named": who ?? "unknown", "scores": scores])
                        }
                        let hyp = d.segments.map {
                            (Double($0.startTimeSeconds), Double($0.endTimeSeconds), label[$0.speakerId] ?? "unknown")
                        }
                        return ["id_accuracy": idAccuracy(ref: ref, hyp: hyp, limit: seconds),
                                "clusters_auto_named": decided, "clusters_named_correctly": correct,
                                "clusters": details]
                    }

                    var people = libraries[key] ?? []
                    if idx == 1 { r["identify_with_library_A"] = evaluate(with: people) }
                    if idx == 2 {
                        r["identify_with_library_A_only"] = evaluate(with: libraryAfterA[key] ?? [])
                        r["identify_with_library_A_plus_B"] = evaluate(with: people)
                    }
                    // "The user names the speakers": confirm each cluster with its true name -> library learns.
                    let meetingID = UUID()
                    for c in d.clusters {
                        guard let truth = der.mapping[c.key] else { continue }
                        if let p = people.firstIndex(where: { $0.name == truth }) {
                            VoiceMatcher.learn(person: &people[p], from: c, meetingID: meetingID)
                        } else {
                            var p = Person(name: truth)
                            VoiceMatcher.learn(person: &p, from: c, meetingID: meetingID)
                            people.append(p)
                        }
                    }
                    libraries[key] = people
                    if idx == 0 { libraryAfterA[key] = people }
                    r["library_after"] = people.map { "\($0.name):\($0.samples.count)" }.joined(separator: " ")
                    bySetting[key] = r
                    log("\(name) [\(key)] clusters \(d.clusters.count) DER \(String(format: "%.3f", der.der))")
                }
                m["settings"] = bySetting
                perMeeting.append(m)
            }
            report["meetings"] = perMeeting

            // Score distributions: same-person vs different-person similarity of cluster centroids
            // are printed per cluster above; thresholds live in VoiceMatcher.
            report["thresholds"] = ["auto": VoiceMatcher.autoMatchThreshold, "suggest": VoiceMatcher.suggestThreshold,
                                    "topK": VoiceMatcher.topK]
            }
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            print("SELFTEST_JSON:" + String(data: data, encoding: .utf8)!)
            return 0
        } catch {
            report["error"] = "\(error)"
            let data = (try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])) ?? Data()
            print("SELFTEST_JSON:" + (String(data: data, encoding: .utf8) ?? "{}"))
            log("FAILED: \(error)")
            return 1
        }
    }
}
