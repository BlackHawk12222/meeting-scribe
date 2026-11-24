// VoiceEnrollment.swift
// "Add person": the person reads a few short prompts in a quiet room, so Scribe knows their voice
// BEFORE the first meeting. Each prompt asks for a different way of talking (normal, a question,
// loud "across the room", quiet and casual, numbers, free talk), because one voice sounds different
// in each, and the library matches better when it has seen that range.
//
// Per clip:
//   1. Quality check (no AI): too loud / clipped? too quiet? too noisy? enough speech (Silero VAD)?
//      If not, the person is asked to redo that prompt.
//   2. One voice embedding (WeSpeaker, 256 numbers) from the speech parts only.
// The set of embeddings is stored in the person's VoiceLibrary entry (tagged "enroll:<style>"), and
// matching compares a new voice against the whole set (see VoiceMatcher.score).

import Foundation
import FluidAudio

enum EnrollmentStyle: String, CaseIterable, Codable, Sendable {
    case reading, question, loud, quiet, numbers, free

    var title: String {
        switch self {
        case .reading: return "Read this normally"
        case .question: return "Ask it like a real question"
        case .loud: return "Say it louder, like across a room"
        case .quiet: return "Say it quietly and casually"
        case .numbers: return "Count out loud"
        case .free: return "Talk freely for a few seconds"
        }
    }
}

struct EnrollmentPrompt: Identifiable, Sendable {
    var id: EnrollmentStyle { style }
    var style: EnrollmentStyle
    var text: String
}

enum VoiceEnrollment {
    /// Prompts. The reading lines are Harvard sentences (IEEE 1969, public domain): short, natural
    /// sentences that together cover the sounds of English.
    static let prompts: [EnrollmentPrompt] = [
        .init(style: .reading, text: "The birch canoe slid on the smooth planks. Glue the sheet to the dark blue background. It's easy to tell the depth of a well."),
        .init(style: .question, text: "Did you remember to bring the charger for the laptop? And what time does the meeting start tomorrow?"),
        .init(style: .loud, text: "Hey, can everyone hear me in the back? We're starting in two minutes, so grab a seat!"),
        .init(style: .quiet, text: "Yeah, I think that's fine. Honestly, let's just keep it simple and see how it goes."),
        .init(style: .numbers, text: "One, two, three, four, five, six, seven, eight, nine, ten. Twenty-five, forty-two, ninety-nine."),
        .init(style: .free, text: "Tell us about your day: what you did this morning, or what you're working on."),
    ]

    /// Gates (measured or chosen; see BENCHMARKS.md section H for what was tested on the runner).
    static let minSpeechSeconds = 4.0
    static let maxClippedFraction = 0.001       // > 0.1 % of samples at full scale = clipped
    static let minSpeechLevelDB: Float = -42     // speech quieter than this (dBFS) = too far / too quiet
    static let minQuietLevelDB: Float = -50      // the "quiet" prompt is allowed to be softer
    static let minSNRdB: Float = 15              // speech vs. the room between words

    struct ClipCheck: Sendable {
        var speechSeconds: Double
        var speechLevelDB: Float
        var noiseLevelDB: Float
        var snrDB: Float
        var clippedFraction: Double
        var problem: String?            // nil = OK
        var ok: Bool { problem == nil }
    }

    /// Level + noise + clipping + amount of speech. `speech` = the VAD's speech parts (sample ranges).
    static func check(samples: [Float], speech: [Range<Int>], style: EnrollmentStyle) -> ClipCheck {
        let n = samples.count
        var clipped = 0
        for v in samples where abs(v) >= 0.99 { clipped += 1 }
        var inSpeech = [Bool](repeating: false, count: n)
        for r in speech { for i in r.clamped(to: 0..<n) { inSpeech[i] = true } }
        // 20 ms frames: speech level = mean power of speech frames; noise = 20th percentile of the
        // other frames (the room between words). Percentile, so a cough doesn't count as "noise".
        let fl = 320
        var sp = 0.0, spN = 0
        var other: [Double] = []
        var f = 0
        while f + fl <= n {
            var e = 0.0, s = 0
            for i in f..<(f + fl) { e += Double(samples[i] * samples[i]); if inSpeech[i] { s += 1 } }
            e /= Double(fl)
            if s > fl / 2 { sp += e; spN += 1 } else { other.append(e) }
            f += fl
        }
        func db(_ p: Double) -> Float { Float(10 * log10(max(p, 1e-12))) }
        let speechDB = db(spN > 0 ? sp / Double(spN) : 0)
        var noiseDB: Float = -120
        if !other.isEmpty {
            let sorted = other.sorted()
            noiseDB = db(sorted[min(sorted.count - 1, sorted.count / 5)])
        } else if spN > 0 {
            noiseDB = speechDB - 30          // no pause at all: can't measure, assume fine
        }
        let speechSec = Double(speech.reduce(0) { $0 + $1.count }) / 16_000
        let clippedFrac = Double(clipped) / Double(max(n, 1))
        let snr = speechDB - noiseDB
        var problem: String?
        if clippedFrac > maxClippedFraction {
            problem = "Too loud, it distorted. Lean back a little and redo it."
        } else if speechSec < minSpeechSeconds {
            problem = "Too short. Read the whole line, then press Stop."
        } else if speechDB < (style == .quiet ? minQuietLevelDB : minSpeechLevelDB) {
            problem = "Too quiet. Move a little closer to the Mac."
        } else if snr < minSNRdB {
            problem = "Too noisy. Try a quieter spot."
        }
        return ClipCheck(speechSeconds: speechSec, speechLevelDB: speechDB, noiseLevelDB: noiseDB,
                         snrDB: snr, clippedFraction: clippedFrac, problem: problem)
    }

    struct ClipResult: Sendable {
        var check: ClipCheck
        var embedding: [Float]?        // nil when the check failed
    }

    /// Check one recorded prompt and, if it's good, embed its speech.
    static func process(samples: [Float], style: EnrollmentStyle) async throws -> ClipResult {
        let speech = try await SpeechEngine.shared.speechRanges(samples)
        let c = check(samples: samples, speech: speech, style: style)
        guard c.ok else { return ClipResult(check: c, embedding: nil) }
        let audio = speech.flatMap { samples[$0.clamped(to: 0..<samples.count)] }
        let emb = try await SpeechEngine.shared.embedSpans(samples: audio, spans: [0..<(Double(audio.count) / 16_000)])
        return ClipResult(check: c, embedding: emb.first.map(VoiceMath.normalize))
    }

    /// Enrollment samples are tagged with this cluster-key prefix (and no meeting id).
    static let tag = "enroll:"

    static func samples(from clips: [(EnrollmentStyle, [Float])]) -> [VoiceSample] {
        clips.map { VoiceSample(vector: VoiceMath.normalize($0.1), meetingID: nil,
                                clusterKey: tag + $0.0.rawValue, addedAt: Date()) }
    }
}

extension VoiceSample {
    var isEnrollment: Bool { clusterKey?.hasPrefix(VoiceEnrollment.tag) == true }
}
