// SelfTest.swift
// Headless test used on the GitHub Actions Mac runner:
//   MeetingScribe.app/Contents/MacOS/MeetingScribe --selftest [--seconds 300]
//
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

    static func run() async -> Int32 {
        let seconds = Double(argValue("--seconds") ?? "300") ?? 300
        var report: [String: Any] = [
            "measured_on": "GitHub Actions macOS runner (virtual Mac, results may differ from a real Apple Silicon Mac's Neural Engine)",
            "seconds_per_meeting": seconds,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "cpu_count": ProcessInfo.processInfo.processorCount,
        ]
        do {
            let t0 = Date()
            try await SpeechEngine.shared.prepare { log($0) }
            report["model_prepare_seconds"] = Date().timeIntervalSince(t0)

            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("selftest", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            var people: [Person] = []          // library, names = AMI speaker IDs
            var libraryAfterA: [Person] = []
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
                let out = try await SpeechEngine.shared.process(samples: samples)

                // Diarization error rate vs reference.
                let der = DiarizationDER.compute(
                    ref: ref.map { DERSpeakerSegment(speaker: $0.speaker, start: $0.start, end: $0.end) },
                    hyp: out.rawSegments.map {
                        DERSpeakerSegment(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
                    })
                var m: [String: Any] = [
                    "meeting": name,
                    "audio_seconds": audioSec,
                    "diarize_seconds": out.diarizeSeconds,
                    "transcribe_seconds": out.transcribeSeconds,
                    "diarize_rtfx": audioSec / max(out.diarizeSeconds, 1e-6),
                    "transcribe_rtfx": audioSec / max(out.transcribeSeconds, 1e-6),
                    "clusters_found": out.clusters.count,
                    "reference_speakers": Set(ref.map(\.speaker)).count,
                    "der": der.der, "der_miss": der.miss, "der_false_alarm": der.falseAlarm, "der_confusion": der.confusion,
                    "transcript_preview": String(out.utterances.map(\.text).joined(separator: " ").prefix(300)),
                ]

                // Best possible labelling of these clusters (= perfect naming).
                let oracle = out.rawSegments.map {
                    (Double($0.startTimeSeconds), Double($0.endTimeSeconds), der.mapping[$0.speakerId] ?? "unmapped")
                }
                m["id_accuracy_ceiling_with_perfect_naming"] = idAccuracy(ref: ref, hyp: oracle, limit: seconds)

                func evaluate(with library: [Person]) -> [String: Any] {
                    let matches = VoiceMatcher.match(clusters: out.clusters, people: library)
                    var label: [String: String] = [:]
                    var details: [[String: Any]] = []
                    var correct = 0, decided = 0
                    for c in out.clusters {
                        let mt = matches[c.key]
                        let who = (mt?.isConfident == true) ? library.first { $0.id == mt!.personID }?.name : nil
                        label[c.key] = who ?? "unknown"
                        let truth = der.mapping[c.key] ?? "none"
                        if who != nil { decided += 1; if who == truth { correct += 1 } }
                        details.append(["cluster": c.key, "talk_s": c.talkSeconds, "truth": truth,
                                        "named": who ?? "unknown", "score": Double(mt?.score ?? 0)])
                    }
                    let hyp = out.rawSegments.map {
                        (Double($0.startTimeSeconds), Double($0.endTimeSeconds), label[$0.speakerId] ?? "unknown")
                    }
                    return ["id_accuracy": idAccuracy(ref: ref, hyp: hyp, limit: seconds),
                            "clusters_auto_named": decided, "clusters_named_correctly": correct,
                            "clusters": details]
                }

                if idx == 1 { m["identify_with_library_A"] = evaluate(with: people) }
                if idx == 2 {
                    m["identify_with_library_A_only"] = evaluate(with: libraryAfterA)
                    m["identify_with_library_A_plus_B"] = evaluate(with: people)
                }

                // "The user names the speakers": confirm each cluster with its true name -> library learns.
                let meetingID = UUID()
                for c in out.clusters {
                    guard let truth = der.mapping[c.key] else { continue }
                    if let p = people.firstIndex(where: { $0.name == truth }) {
                        VoiceMatcher.learn(person: &people[p], from: c, meetingID: meetingID)
                    } else {
                        var p = Person(name: truth)
                        VoiceMatcher.learn(person: &p, from: c, meetingID: meetingID)
                        people.append(p)
                    }
                }
                if idx == 0 { libraryAfterA = people }
                m["library_samples_after"] = people.map { "\($0.name):\($0.samples.count)" }.joined(separator: " ")
                perMeeting.append(m)
                log("done \(name): DER \(String(format: "%.3f", der.der))")
            }
            report["meetings"] = perMeeting

            // Score distributions: same-person vs different-person similarity of cluster centroids
            // are printed per cluster above; thresholds live in VoiceMatcher.
            report["thresholds"] = ["auto": VoiceMatcher.autoMatchThreshold, "suggest": VoiceMatcher.suggestThreshold,
                                    "topK": VoiceMatcher.topK]
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
