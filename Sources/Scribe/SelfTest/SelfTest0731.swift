// SelfTest0731.swift
// Targeted checks for 0.7.3.1 (run inside `--suite targeted`, see SelfTest072.run):
//   consent – the recording-consent notice shows on the first meeting start (the reminder's state
//             AND the rendered notice in the live meeting view has height), × hides it for this
//             meeting only (it is back on the next start), "Don't show again" hides it and it does
//             not come back on later starts or after a relaunch (UserDefaults), and it never
//             shows while nothing is recording. Uses its own UserDefaults suite, so the real
//             setting is untouched.
//   meeting – FluidAudio's text-to-speech data (LuxTTS G2P: eSpeak NG output + FrequencyWords
//             keys) is NOT in Scribe.app (build.sh strips it), and meetings still work without it:
//             real models diarize + transcribe the first 120 s of the AMI test meeting
//             (--meeting-wav) into several speakers and real text. Dictation is checked by the
//             existing dictation_startup check in the same run.
//   credits – licenses.json is in the bundle with the Parakeet v2 (CC BY 4.0, FluidInference,
//             unmodified weights) and FluidAudio (Apache 2.0) entries, every entry's license file
//             loads, and Privacy / Terms have no URL yet ("Coming soon").

import Foundation
import AppKit
import SwiftUI

enum SelfTest0731 {
    @MainActor static func consentCheck() -> ([String: Any], [String]) {
        var r: [String: Any] = [:]
        var fail: [String] = []
        let suiteName = "scribe-selftest-consent-\(UUID().uuidString)"
        guard let d = UserDefaults(suiteName: suiteName) else { return (r, ["consent: no test defaults"]) }
        defer { d.removePersistentDomain(forName: suiteName) }

        func renderedHeight(_ c: ConsentReminder) -> CGFloat {
            let host = NSHostingView(rootView: ConsentNoticeView(reminder: c).frame(width: 760))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }

        let c = ConsentReminder(defaults: d)
        r["idle_showing"] = c.isShowing
        if c.isShowing { fail.append("consent: notice shows while nothing is recording") }

        // 1st meeting: shows.
        c.recordingChanged(true)
        let h1 = renderedHeight(c)
        r["first_start_showing"] = c.isShowing
        r["first_start_height"] = Double(h1)
        if !c.isShowing { fail.append("consent: notice not shown on the first meeting start") }
        if h1 < 20 { fail.append("consent: notice not drawn on the first meeting start (height \(h1))") }
        // × hides it for this meeting; stopping hides it.
        c.close()
        if c.isShowing || renderedHeight(c) > 1 { fail.append("consent: × didn't hide the notice") }
        c.recordingChanged(false)
        // 2nd meeting: back (× is per meeting).
        c.recordingChanged(true)
        r["second_start_after_close_showing"] = c.isShowing
        if !c.isShowing { fail.append("consent: × should only hide it for that meeting") }
        // Don't show again.
        c.dontShowAgain()
        let hDone = renderedHeight(c)
        r["after_dont_show_again_height"] = Double(hDone)
        if c.isShowing || hDone > 1 { fail.append("consent: Don't show again didn't hide the notice") }
        if d.bool(forKey: ConsentReminder.hiddenKey) != true { fail.append("consent: Don't show again not saved") }
        c.recordingChanged(false)
        // 3rd meeting: stays hidden.
        c.recordingChanged(true)
        r["third_start_showing"] = c.isShowing
        if c.isShowing || renderedHeight(c) > 1 { fail.append("consent: notice came back after Don't show again") }
        c.recordingChanged(false)
        // Relaunch (a new reminder on the same defaults): still hidden.
        let relaunch = ConsentReminder(defaults: d)
        relaunch.recordingChanged(true)
        r["after_relaunch_showing"] = relaunch.isShowing
        if relaunch.isShowing { fail.append("consent: notice came back after a relaunch") }
        r["message"] = ConsentReminder.message
        if ConsentReminder.message != "Let everyone know you're recording. Some places require everyone's OK." {
            fail.append("consent: message text changed")
        }
        return (r, fail)
    }

    static func meetingCheck() async -> ([String: Any], [String]) {
        var r: [String: Any] = [:]
        var fail: [String] = []
        // 1. The TTS resources are gone from the app.
        var found: [String] = []
        if let e = FileManager.default.enumerator(atPath: Bundle.main.bundlePath) {
            for case let rel as String in e {
                let l = rel.lowercased()
                if l.contains("luxtts") || l.contains("espeak") || l.contains("en_full") { found.append(rel) }
            }
        }
        r["tts_files_in_app"] = found
        if !found.isEmpty { fail.append("meeting: TTS resources still in Scribe.app: \(found.prefix(5))") }
        // 2. A real meeting still diarizes + transcribes.
        guard let wavPath = SelfTest.argValue("--meeting-wav") else {
            r["skipped"] = "no --meeting-wav"
            return (r, fail)
        }
        do {
            let tl = Date()
            try await SpeechEngine.shared.prepare { _, _ in }
            r["load_seconds"] = Date().timeIntervalSince(tl)
            let samples = Array(try SpeechEngine.loadSamples(URL(fileURLWithPath: wavPath)).prefix(120 * 16_000))
            let t0 = Date()
            let out = try await SpeechEngine.shared.process(samples: samples)
            let words = out.utterances.map { $0.text.split(separator: " ").count }.reduce(0, +)
            let speakers = Set(out.utterances.map(\.speakerKey)).count
            r["audio_seconds"] = Double(samples.count) / 16_000
            r["process_seconds"] = Date().timeIntervalSince(t0)
            r["utterances"] = out.utterances.count
            r["words"] = words
            r["speakers"] = speakers
            r["first_lines"] = out.utterances.prefix(3).map { "\($0.speakerKey): \($0.text.prefix(80))" }
            if words < 100 { fail.append("meeting: only \(words) words from 120 s of meeting audio") }
            if speakers < 2 { fail.append("meeting: only \(speakers) speaker(s) found in a 4-person meeting") }
        } catch {
            fail.append("meeting: \(error)")
        }
        return (r, fail)
    }

    @MainActor static func creditsCheck() -> ([String: Any], [String]) {
        var r: [String: Any] = [:]
        var fail: [String] = []
        let entries = LicenseCatalog.entries()
        r["entries"] = entries.map(\.id)
        r["folder"] = LicenseCatalog.folder?.path ?? "nil"
        if entries.isEmpty { return (r, ["credits: licenses.json missing from the app bundle"]) }
        if let p = entries.first(where: { $0.id == "parakeet-tdt-0.6b-v2" }) {
            if p.license != "CC BY 4.0" { fail.append("credits: Parakeet v2 license is \(p.license)") }
            if !p.what.contains("FluidInference") || !p.what.contains("unmodified weights") {
                fail.append("credits: Parakeet v2 must say converted to Core ML by FluidInference, unmodified weights")
            }
            if p.url?.contains("nvidia/parakeet-tdt-0.6b-v2") != true { fail.append("credits: Parakeet v2 link") }
        } else { fail.append("credits: no Parakeet TDT 0.6B v2 entry") }
        if let f = entries.first(where: { $0.pin == "fluidaudio" }) {
            if f.license != "Apache 2.0" { fail.append("credits: FluidAudio license is \(f.license)") }
        } else { fail.append("credits: no FluidAudio entry") }
        var missing: [String] = []
        for e in entries {
            var files: [String] = e.notices ?? []
            if let f = e.file { files.insert(f, at: 0) }
            for f in files where (LicenseCatalog.text(f)?.count ?? 0) < 200 { missing.append(f) }
        }
        r["missing_texts"] = missing
        if !missing.isEmpty { fail.append("credits: license texts missing from the bundle: \(missing)") }
        let pins = LicenseCatalog.resolvedPins()
        r["resolved_pins"] = pins
        for id in pins.keys where !entries.contains(where: { $0.pin == id }) {
            fail.append("credits: resolved package \(id) has no license entry")
        }
        r["privacy_url"] = LegalLinks.privacyURL?.absoluteString ?? "coming soon"
        r["terms_url"] = LegalLinks.termsURL?.absoluteString ?? "coming soon"
        return (r, fail)
    }
}
