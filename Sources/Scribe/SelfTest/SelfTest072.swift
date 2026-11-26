// SelfTest072.swift
// `Scribe --selftest --suite targeted`: ONLY the checks for what 0.7.2 changed (the long dictation /
// meeting / voice benchmarks don't run for this release):
//   theme      – light ("Daylight") and dark tokens resolve differently; text and accent contrast
//   speakers   – a split-off speaker is merged into its person (one entry, 100 %), lines re-keyed,
//                the person's voiceprint learns the merged piece; renaming a person to an existing
//                name merges the two people; all of it survives a reload from disk
//   rename     – a meeting title is saved and survives a reload; an empty name is ignored
//   dictation  – press→listening and release→text timings: mic engine start (if the runner has a
//                mic), release→text while the models are STILL LOADING (first press after launch),
//                launch→ready, then warm release→text. Runner = virtual M1, no Neural Engine.
//   tachys     – (0.7.3 preview) release→text with the Tachys speculative pass on vs off, same
//                audio (speech + 1 s quiet while held); the text must be identical.
//                0.7.2.3: Parakeet's parts load in parallel; parallel vs FluidAudio's serial load
//                times on the same runner, and the text from both loads must be identical.
// The app icon's appearance variants are checked by the workflow with `assetutil --info`.

import Foundation
import FluidAudio
import AppKit
import SwiftUI

enum SelfTest072 {
    static func log(_ s: String) { SelfTest.log(s) }

    static func run() async -> [String: Any] {
        var out: [String: Any] = [:]
        var failures: [String] = []
        let theme = await MainActor.run { themeCheck() }
        out["theme"] = theme.0; failures += theme.1
        let spk = await MainActor.run { speakerCheck() }
        out["speakers"] = spk.0; failures += spk.1
        let ren = await MainActor.run { renameCheck() }
        out["rename"] = ren.0; failures += ren.1
        // 0.7.3: "Name voices" editor (range assign, voiceprint learning, Vocabulary, Space key).
        let ve = await MainActor.run { SelfTest073.voiceEditorCheck() }
        out["voice_editor"] = ve.0; failures += ve.1
        let fx = await MainActor.run { SelfTest073.fixCheck() }
        out["learn_from_fixes"] = fx.0; failures += fx.1
        // 0.7.3.1: recording-consent notice + Credits & licenses.
        let cn = await MainActor.run { SelfTest0731.consentCheck() }
        out["consent_notice"] = cn.0; failures += cn.1
        let cr = await MainActor.run { SelfTest0731.creditsCheck() }
        out["credits"] = cr.0; failures += cr.1
        // 0.7.3.2: accounts (crypto, payload, signed-out), My voice, Meetings dashboard + navigation.
        let a0732 = await SelfTest0732.run()
        out["v0732"] = a0732.0; failures += a0732.1
        // 0.7.5: signature identity, meeting audio (silence check, mixer), sign-in link.
        let a075 = await SelfTest075.run()
        out["v075"] = a075.0; failures += a075.1
        // 0.7.6: Boost my words, learned fix-ups (thresholds, common words, migration), order before Style, log.
        let a076 = await MainActor.run { SelfTest076.run() }
        out["v076_learning"] = a076.0; failures += a076.1
        // 0.7.7: USB wireless mic receivers (voice on one channel, real format vs stale format).
        let a077 = SelfTest077.run()
        out["v077_usb_mic"] = a077.0; failures += a077.1
        let dict = await dictationCheck()
        out["dictation_startup"] = dict.0; failures += dict.1
        // 0.7.3.1: meetings still work with FluidAudio's TTS data stripped from the app.
        let mt = await SelfTest0731.meetingCheck()
        out["meeting_after_tts_strip"] = mt.0; failures += mt.1
        out["failures"] = failures
        out["pass"] = failures.isEmpty
        for f in failures { log("FAIL: \(f)") }
        log(failures.isEmpty ? "targeted checks: ALL PASS" : "targeted checks: \(failures.count) failed")
        return out
    }

    // MARK: Theme

    static func rgb(_ c: NSColor, dark: Bool) -> (Double, Double, Double, Double) {
        var out = (0.0, 0.0, 0.0, 1.0)
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            let s = c.usingColorSpace(.sRGB) ?? c
            out = (Double(s.redComponent), Double(s.greenComponent), Double(s.blueComponent), Double(s.alphaComponent))
        }
        return out
    }

    static func lum(_ c: (Double, Double, Double, Double)) -> Double {
        func ch(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * ch(c.0) + 0.7152 * ch(c.1) + 0.0722 * ch(c.2)
    }

    static func contrast(_ fg: NSColor, on bg: NSColor, dark: Bool) -> Double {
        let b = rgb(bg, dark: dark)
        var f = rgb(fg, dark: dark)
        // Blend a see-through foreground over the background first.
        f = (f.0 * f.3 + b.0 * (1 - f.3), f.1 * f.3 + b.1 * (1 - f.3), f.2 * f.3 + b.2 * (1 - f.3), 1)
        let l1 = lum(f), l2 = lum(b)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    @MainActor static func themeCheck() -> ([String: Any], [String]) {
        func ns(_ c: Color) -> NSColor { NSColor(c) }
        var r: [String: Any] = [:]
        var fail: [String] = []
        let pairs: [(String, Color, Color, Double)] = [
            ("text_on_canvas", Night.text, Night.canvas, 7),
            ("text2_on_surface", Night.text2, Night.surface, 4.5),
            ("text3_on_canvas", Night.text3, Night.canvas, 4.5),
            ("text3_on_surface", Night.text3, Night.surface, 4.5),
            ("text3_on_rail", Night.text3, Night.rail, 4.5),
            ("text3_on_well", Night.text3, Night.well, 4.5),
            ("accent_on_surface", Night.accent, Night.surface, 4.5),
            ("onAccent_on_accent", Night.onAccent, Night.accent, 4.5),
            ("live_dot_on_surface", Night.live, Night.surface, 3),
            ("live_on_liveSoft_over_surface", Night.live, Night.surface, 3),
        ]
        for dark in [false, true] {
            var d: [String: Double] = [:]
            for (name, fg, bg, need) in pairs {
                let c = contrast(ns(fg), on: ns(bg), dark: dark)
                d[name] = (c * 100).rounded() / 100
                if c < need { fail.append("theme \(dark ? "dark" : "light"): \(name) contrast \(String(format: "%.2f", c)) < \(need)") }
            }
            r[dark ? "dark_contrast" : "light_contrast"] = d
        }
        // Poster (0.7.3): light and dark are each their own design, both flat: no shadow in either
        // mode (hairlines do the work), no inner highlight, and text3 is a step under text2.
        let cl = rgb(ns(Night.canvas), dark: false), cd = rgb(ns(Night.canvas), dark: true)
        if lum(cl) < 0.8 || lum(cd) > 0.05 { fail.append("theme: canvas light/dark not light/dark") }
        let shL = rgb(ns(Night.shadow), dark: false).3, shD = rgb(ns(Night.shadow), dark: true).3
        if shL != 0 || shD != 0 || Night.shadowRadius != 0 || Night.shadowY != 0 {
            fail.append("theme: Poster has no shadow (alpha light \(shL), dark \(shD), radius \(Night.shadowRadius))")
        }
        let hlL = rgb(ns(Night.highlight), dark: false).3, hlD = rgb(ns(Night.highlight), dark: true).3
        if hlL != 0 || hlD != 0 { fail.append("theme: Poster has no inner highlight") }
        for dark in [false, true] {
            let t2 = contrast(ns(Night.text2), on: ns(Night.canvas), dark: dark)
            let t3 = contrast(ns(Night.text3), on: ns(Night.canvas), dark: dark)
            if t3 >= t2 { fail.append("theme \(dark ? "dark" : "light"): text3 should stay a step under text2") }
        }
        r["shadow_alpha"] = ["light": shL, "dark": shD]
        r["sizes"] = ["rail": Night.railWidth, "rail_item": Night.railItem, "rail_icon": Night.railIcon, "meetings_list": Night.meetingsListWidth, "settings_list": Night.settingsListWidth,
                      "header": Night.headerHeight, "control_height": Night.controlHeight, "row_height": Night.rowHeight,
                      "card_padding": Night.cardPadding, "tile": Night.tileHeight, "tile_compact": Night.tileHeightCompact]
        // Poster layout (docs/DESIGN.md § 3): rail 68 (items 44, icons 20), meetings list 300, settings list 196, top bar 52.
        if Night.railWidth != 68 || Night.railItem != 44 || Night.railIcon < 20 || Night.railIcon > 22 || Night.meetingsListWidth != 300 || Night.settingsListWidth != 196 || Night.headerHeight != 52 {
            fail.append("theme: sidebar widths (rail \(Night.railWidth), meetings \(Night.meetingsListWidth), settings \(Night.settingsListWidth), header \(Night.headerHeight))")
        }
        if Night.tileHeight != 186 || Night.controlHeight != 28 || Night.rCard != 8 || Night.rTile != 10 { fail.append("theme: Poster sizes") }
        return (r, fail)
    }

    // MARK: Speakers

    static func vec(_ seed: Int, noise: Float = 0) -> [Float] {
        var rng = SeededRandom(seed: UInt64(seed))
        return VoiceMath.normalize((0..<256).map { _ in Float(rng.next() * 2 - 1) })
    }
    static func jitter(_ v: [Float], _ seed: Int, _ amount: Float) -> [Float] {
        // Same voice + a random direction of length `amount` (cosine to v ≈ 1/√(1+amount²)).
        var rng = SeededRandom(seed: UInt64(seed) &* 7919)
        let noise = VoiceMath.normalize(v.map { _ in Float(rng.next() * 2 - 1) })
        return VoiceMath.normalize(zip(v, noise).map { $0 + amount * $1 })
    }

    @MainActor static func speakerCheck() -> ([String: Any], [String]) {
        var r: [String: Any] = [:]
        var fail: [String] = []
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("st072-spk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = Store(folder: tmp)
        let me = vec(1), other = vec(2)
        var alex = Person(name: "Alex", colorIndex: 0)
        for k in 0..<6 { alex.samples.append(VoiceSample(vector: jitter(me, k, 0.25), meetingID: nil, clusterKey: nil, addedAt: Date())) }
        let sam = Person(name: "Sam", colorIndex: 1)
        store.people = [alex]
        _ = sam

        // Meeting 1: a solo recording split 85 / 12 / 3 by the diarizer. S2 sounds like Alex but not
        // enough for the auto rule (we push it far away) → stays unnamed; the user names it Alex.
        func soloMeeting(title: String, s2: [Float]) -> Meeting {
            var m = Meeting(title: title, date: Date(), duration: 100, audioFileName: "x.wav")
            m.status = .done
            m.clusters = [
                SpeakerCluster(key: "S1", talkSeconds: 85, centroid: jitter(me, 50, 0.2), spanEmbeddings: [jitter(me, 51, 0.2), jitter(me, 52, 0.2)]),
                SpeakerCluster(key: "S2", talkSeconds: 12, centroid: s2, spanEmbeddings: [s2]),
                SpeakerCluster(key: "S3", talkSeconds: 3, centroid: other, spanEmbeddings: [other]),
            ]
            m.utterances = [
                Utterance(start: 0, end: 10, speakerKey: "S1", text: "one"),
                Utterance(start: 10.5, end: 12, speakerKey: "S2", text: "two"),
                Utterance(start: 12.4, end: 30, speakerKey: "S1", text: "three"),
                Utterance(start: 31, end: 33, speakerKey: "S3", text: "four"),
            ]
            return m
        }
        let farS2 = jitter(other, 9, 0.6)          // does not match Alex: no auto merge
        store.meetings = [soloMeeting(title: "Solo A", s2: farS2)]
        let id1 = store.meetings[0].id
        store.applyLibrary(to: id1)
        let afterAuto = store.meetings[0].clusters.map { "\($0.key):\(store.person($0.personID)?.name ?? "-")" }
        r["meeting1_after_library"] = afterAuto
        if store.meetings[0].clusters.count != 3 { fail.append("speakers: far-away S2 must NOT be auto-merged") }
        let samplesBefore = store.people[0].samples.count
        store.assign(meetingID: id1, clusterKey: "S2", to: store.people[0].id)   // user: "Unknown is Alex"
        let m1 = store.meetings[0]
        let alexClusters = m1.clusters.filter { $0.personID == store.people[0].id }
        let total = m1.clusters.reduce(0) { $0 + $1.talkSeconds }
        r["meeting1_after_rename"] = m1.clusters.map { "\($0.key):\(store.person($0.personID)?.name ?? "-"):\(Int(($0.talkSeconds / total * 100).rounded()))%" }
        if alexClusters.count != 1 { fail.append("speakers: Alex should be ONE speaker after naming Unknown, got \(alexClusters.count)") }
        if let a = alexClusters.first, abs(a.talkSeconds - 97) > 0.01 { fail.append("speakers: merged talk time \(a.talkSeconds) != 97") }
        if m1.utterances.contains(where: { $0.speakerKey == "S2" }) { fail.append("speakers: lines still on S2") }
        if m1.utterances.count != 2 { fail.append("speakers: back-to-back lines of one person should join (got \(m1.utterances.count))") }
        let learned = store.people[0].samples.filter { $0.meetingID == id1 }.count
        r["voiceprint_samples_from_meeting"] = learned
        if learned != 3 { fail.append("speakers: voiceprint should learn all 3 merged spans, got \(learned)") }
        if store.people[0].samples.count != samplesBefore + 3 { fail.append("speakers: sample count") }
        // The learned piece now matches Alex better than before.
        let scoreAfter = VoiceMatcher.score(farS2, samples: store.people[0].samples.map(\.vector), mode: .max)
        r["s2_score_after_learning"] = scoreAfter
        if scoreAfter < 0.9 { fail.append("speakers: Alex's voiceprint did not learn the merged piece (score \(scoreAfter))") }

        // Meeting 2: a close split-off piece (small share, voice like Alex) is merged automatically.
        store.meetings.insert(soloMeeting(title: "Solo B", s2: jitter(me, 77, 0.3)), at: 0)
        let id2 = store.meetings[0].id
        store.applyLibrary(to: id2)
        let m2 = store.meetings[0]
        r["meeting2_auto"] = m2.clusters.map { "\($0.key):\(store.person($0.personID)?.name ?? "-")" }
        if m2.clusters.filter({ $0.personID == store.people[0].id }).count != 1 || m2.clusters.count != 2 {
            fail.append("speakers: close split-off piece should be auto-merged into Alex")
        }
        if m2.clusters.contains(where: { $0.key == "S3" && $0.personID != nil }) { fail.append("speakers: a different voice got Alex's name") }

        // Renaming a person to an existing name merges the two people.
        let dup = Person(name: "Al", colorIndex: 2)
        store.people.append(dup)
        if let i = store.index(of: id1), let k = store.meetings[i].clusters.firstIndex(where: { $0.key == "S3" }) {
            store.meetings[i].clusters[k].personID = dup.id
            store.meetings[i].clusters[k].confirmed = true
        }
        store.rename(personID: dup.id, to: "  alex ")
        r["people_after_rename_merge"] = store.people.map(\.name)
        if store.people.count != 1 { fail.append("speakers: renaming 'Al' to 'alex' should merge into Alex (people: \(store.people.count))") }

        // Survives a reload from disk.
        let reloaded = Store(folder: tmp)
        let rm = reloaded.meetings.first { $0.id == id1 }
        if rm?.clusters.count != 1 || reloaded.people.count != 1 { fail.append("speakers: merge not saved to disk") }
        r["reloaded_meeting1_speakers"] = rm?.clusters.count ?? -1
        return (r, fail)
    }

    // MARK: Rename

    @MainActor static func renameCheck() -> ([String: Any], [String]) {
        var fail: [String] = []
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("st072-ren-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = Store(folder: tmp)
        let m = store.addMeeting(audioURL: tmp.appendingPathComponent("a.wav"), duration: 60, title: "Meeting – Tue")
        store.renameMeeting(m.id, to: "  Robot planning  ")
        store.renameMeeting(m.id, to: "   ")
        let reloaded = Store(folder: tmp).meetings.first { $0.id == m.id }?.title
        if reloaded != "Robot planning" { fail.append("rename: got \(reloaded ?? "nil")") }
        return (["title_after_reload": reloaded ?? "nil"], fail)
    }

    // MARK: Dictation startup

    static func ms(_ t: Double) -> Double { (t * 1000).rounded() }

    static func dictationCheck() async -> ([String: Any], [String]) {
        var r: [String: Any] = ["measured_on": "GitHub Actions macOS runner: virtual Apple M1, 3 cores, NO Neural Engine (Core ML runs on CPU/GPU). Not a real Mac."]
        var fail: [String] = []
        // 1) Mic: build the engine (launch), then press → engine running (twice: first + reuse).
        let mic = MicCapture()
        if await MainActor.run(body: { Permissions.microphoneGranted }) == false {
            r["mic"] = "skipped: no microphone permission on the runner"
        } else {
            mic.prepare()
            var starts: [Double] = []
            for _ in 0..<2 {
                let t = Date()
                let err: Error? = await withCheckedContinuation { c in mic.start { c.resume(returning: $0) } }
                if let err { r["mic_error"] = "\(err)"; break }
                starts.append(ms(Date().timeIntervalSince(t)))
                _ = mic.stop()
            }
            r["press_to_mic_running_ms"] = starts
        }
        // 2) First press right after launch: models NOT loaded yet. Listening starts at once (the
        //    app buffers audio); on release we wait for the models, then transcribe.
        guard let wav = Bundle.main.url(forResource: "dictation_sample", withExtension: "wav"),
              let clip = try? SpeechEngine.loadSamples(wav) else {
            return (r, ["dictation: test clip missing"])
        }
        let onset = clip.firstIndex { abs($0) > 0.02 }.map { max(0, $0 - 1600) } ?? 0
        let clip2 = Array(clip[onset..<min(clip.count, onset + 32_000)])
        let clip5 = Array(clip[onset..<min(clip.count, onset + 80_000)])
        let launch = Date()
        let loader = Task { try await SpeechEngine.shared.prepareDictation(model: .current) { _, _ in } }
        let pressReady = Date().timeIntervalSince(launch)     // nothing blocks the press any more
        r["press_to_listening_while_loading_ms"] = ms(pressReady)
        try? await Task.sleep(nanoseconds: 2_000_000_000)     // "talking" for 2 s while it loads
        let released = Date()
        let ok = await SpeechEngine.shared.waitUntilDictationReady(timeout: 120)
        let waited = Date().timeIntervalSince(released)
        do {
            try await loader.value
            let readyAfter = Date().timeIntervalSince(launch)
            let res = try await Dictation.run(samples: clip2, useAI: false, removeFillers: true)
            r["first_press_after_launch"] = [
                "release_to_text_ms": ms(Date().timeIntervalSince(released)),
                "of_which_waiting_for_models_ms": ms(waited),
                "launch_to_dictation_ready_ms": ms(readyAfter),
                "text": res.text, "models_ready": ok,
            ] as [String: Any]
            if res.text.isEmpty { fail.append("dictation: no text from the buffered first press") }
        } catch {
            fail.append("dictation: \(error)")
            return (r, fail)
        }
        // 3) Warm: release → text (VAD fed live like the app, then the clock starts at release).
        func release(_ samples: [Float]) async throws -> Double {
            let session = UUID()
            await SpeechEngine.shared.liveVadStart(session: session)
            var i = 0
            while i < samples.count {
                await SpeechEngine.shared.liveVadFeed(Array(samples[i..<min(samples.count, i + 1600)]))
                i += 1600
            }
            let t0 = Date()
            _ = try await Dictation.run(samples: samples, useAI: false, removeFillers: true, live: true, session: session)
            return ms(Date().timeIntervalSince(t0))
        }
        do {
            var w2: [Double] = [], w5: [Double] = []
            for _ in 0..<3 { w2.append(try await release(clip2)) }
            for _ in 0..<2 { w5.append(try await release(clip5)) }
            r["warm_release_to_text_2s_ms"] = w2
            r["warm_release_to_text_5s_ms"] = w5
        } catch { fail.append("dictation warm: \(error)") }
        // 4) Tachys (0.7.3 preview): speech, then 1 s of quiet while the key is still held. The
        //    speculative pass runs during the quiet; release should reuse it. Compared with Tachys
        //    off (the 0.7.2 path) on the same audio: text must match, timings side by side.
        let tachysKey = TachysEngine.enabledKey
        let before = UserDefaults.standard.object(forKey: tachysKey)
        func held(_ samples: [Float], tachysOn: Bool) async throws -> (ms: Double, text: String, mode: String) {
            UserDefaults.standard.set(tachysOn, forKey: tachysKey)
            let session = UUID()
            await SpeechEngine.shared.liveVadStart(session: session)
            var i = 0
            while i < samples.count {
                await SpeechEngine.shared.liveVadFeed(Array(samples[i..<min(samples.count, i + 1600)]))
                i += 1600
            }
            _ = await SpeechEngine.shared.tachysWaitForSpeculation()   // the user is still holding the key
            let quiet = await SpeechEngine.shared.tachysQuietNow()
            let t0 = Date()
            if !quiet { try? await Task.sleep(nanoseconds: 150_000_000) }   // same as the app's tail wait
            let res = try await Dictation.run(samples: samples, useAI: false, removeFillers: true, live: true, session: session)
            return (ms(Date().timeIntervalSince(t0)), res.text, res.transcript.tachys)
        }
        do {
            var tr: [String: Any] = [:]
            for (name, base) in [("2s", clip2), ("5s", clip5)] {
                let audio = base + [Float](repeating: 0, count: 16_000)
                var on: [Double] = [], off: [Double] = []
                var modes: [String] = []
                var textOn = "", textOff = ""
                for _ in 0..<2 {
                    let a = try await held(audio, tachysOn: true); on.append(a.ms); modes.append(a.mode); textOn = a.text
                    let b = try await held(audio, tachysOn: false); off.append(b.ms); textOff = b.text
                }
                let same = textOn == textOff
                tr[name] = ["tachys_on_release_to_text_ms": on, "tachys_off_release_to_text_ms": off,
                            "speculative_pass": modes, "same_text": same,
                            "text_on": textOn, "text_off": textOff] as [String: Any]
                if !same { fail.append("tachys \(name): text differs from the 0.7.2 path") }
            }
            r["tachys"] = tr
        } catch { fail.append("tachys: \(error)") }
        if let before { UserDefaults.standard.set(before, forKey: tachysKey) } else { UserDefaults.standard.removeObject(forKey: tachysKey) }
        // 5) Tachys (0.7.2.3): how the first load above ran, then the parallel load against
        //    FluidAudio's serial load (same files, same configuration), alternating so neither gets
        //    all the warm-cache benefit, and the text from both must be identical.
        let firstLoad = await SpeechEngine.shared.lastParakeetLoad
        r["first_load_mode"] = firstLoad
        if firstLoad.hasPrefix("serial (parallel failed") { fail.append("tachys load: parallel load failed (\(firstLoad))") }
        do {
            let model = SpeechModel.current
            let config = TachysEngine.modelConfiguration()
            var par: [Double] = [], ser: [Double] = []
            var textPar = "", textSer = "", modePar = ""
            func text(_ models: AsrModels) async throws -> String {
                let m = AsrManager(config: .default)
                try await m.loadModels(models)
                var st = TdtDecoderState.make(decoderLayers: await m.decoderLayerCount)
                return try await m.transcribe(clip5, decoderState: &st).text
            }
            for i in 0..<2 {
                var t = Date()
                let s = try await SpeechEngine.loadParakeet(model, configuration: config, encoderUnits: nil, parallel: false)
                ser.append(ms(Date().timeIntervalSince(t)))
                if i == 0 { textSer = try await text(s.0) }
                t = Date()
                let p = try await SpeechEngine.loadParakeet(model, configuration: config, encoderUnits: nil, parallel: true)
                par.append(ms(Date().timeIntervalSince(t)))
                modePar = p.1
                if i == 0 { textPar = try await text(p.0) }
            }
            r["parakeet_load"] = ["serial_fluidaudio_ms": ser, "parallel_tachys_ms": par, "parallel_mode": modePar,
                                  "same_text": textPar == textSer, "text_parallel": textPar, "text_serial": textSer] as [String: Any]
            if textPar != textSer { fail.append("tachys load: text from the parallel-loaded model differs from FluidAudio's serial load") }
            if textPar.isEmpty { fail.append("tachys load: no text from the parallel-loaded model") }
            if modePar.hasPrefix("serial (parallel failed") { fail.append("tachys load: parallel load failed (\(modePar))") }
        } catch { fail.append("tachys load: \(error)") }
        log("dictation startup: \(r)")
        return (r, fail)
    }
}
