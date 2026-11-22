// SpeechEngine.swift
// The "brain": turns audio into text.
//
// MEETINGS (whole recording, after you press Stop):
//  1. Diarization  ("who spoke when")   -> FluidAudio OfflineDiarizerManager
//     (pyannote Community-1 segmentation + WeSpeaker voice embeddings + VBx clustering)
//  2. Transcription ("what was said")   -> FluidAudio Parakeet TDT 0.6B (v2 English or v3 multilingual)
//  3. Merge: every word gets the speaker who was talking at that moment.
//  4. Voice embeddings for each speaker -> used by VoiceLibrary to put names on them.
//
// DICTATION (a few seconds, while you hold the hotkey) -> `dictate(samples:)` below:
//  1. Silero VAD finds the parts with speech; silence before/after/between is cut out.
//  2. Parakeet turns the speech into text (it already adds punctuation + capitals).
//  (Cleanup and pasting happen in Dictation/, not here.)
//
// All models run on-device with Core ML (Neural Engine / GPU / CPU).
// They download once (~600 MB + ~2 MB VAD) into Application Support and then work offline.

import Foundation
import FluidAudio

/// How the diarizer should decide how many people there are.
struct DiarizerSetting: Hashable, Sendable {
    /// nil = let the model decide ("Auto"). A number = "there were exactly N people".
    var speakers: Int? = nil
    // Advanced clustering knobs (used by the self-test to compare settings).
    var threshold: Double? = nil
    var fa: Double? = nil
    var fb: Double? = nil

    static let auto = DiarizerSetting()
    static let defaultFa = 0.2

    var label: String {
        var parts: [String] = []
        if let s = speakers { parts.append("exactly\(s)") }
        if let t = threshold { parts.append("thr\(t)") }
        if let a = fa { parts.append("Fa\(a)") }
        if let b = fb { parts.append("Fb\(b)") }
        return parts.isEmpty ? "auto" : parts.joined(separator: "_")
    }

    var config: OfflineDiarizerConfig {
        var c = OfflineDiarizerConfig()
        // One speaker at a time, so every word maps to exactly one person.
        c.exclusiveSegments = true
        if let t = threshold { c.clusteringThreshold = t }
        // Fa = how much the clustering trusts the voice evidence. FluidAudio's default (0.07)
        // merged different people into one speaker on our 5-minute test meetings; 0.2 found
        // more of the real speakers with equal or lower DER (GitHub Mac runner self-test,
        // 3 AMI clips — see BENCHMARKS.md). So "Auto" uses 0.2.
        c.Fa = fa ?? Self.defaultFa
        if let b = fb { c.Fb = b }
        if let s = speakers { c = c.withSpeakers(exactly: s) }
        return c
    }
}

/// Which speech-to-text model to use (Settings > Model). Both are NVIDIA Parakeet TDT 0.6B
/// converted to Core ML by FluidAudio. Why these and not Whisper: see BENCHMARKS.md.
enum SpeechModel: String, CaseIterable, Identifiable, Sendable {
    case english = "v2"        // default: most accurate for English in our tests
    case multilingual = "v3"   // 25 European languages, auto-detected

    var id: String { rawValue }
    var version: AsrModelVersion { self == .english ? .v2 : .v3 }
    var title: String { self == .english ? "Parakeet v2 · English" : "Parakeet v3 · 25 languages" }
    var detail: String {
        self == .english
            ? "Best for English. Measured 3.2% word errors on our test set (sandbox)."
            : "Use if you speak Spanish, German, French… Measured 5.0% word errors on the same English test set (sandbox)."
    }
    /// What the user picked in Settings (stored in UserDefaults under "speechModel").
    static var current: SpeechModel {
        SpeechModel(rawValue: UserDefaults.standard.string(forKey: "speechModel") ?? "") ?? .english
    }
}

/// What one dictation produced, plus timings (the self-test prints these).
struct DictationTranscript: Sendable {
    var text: String
    var audioSeconds: Double      // how long you held the key
    var speechSeconds: Double     // what was left after cutting silence
    var vadSeconds: Double        // time spent finding speech
    var asrSeconds: Double        // time spent transcribing
}

actor SpeechEngine {
    static let shared = SpeechEngine()

    private var asr: AsrManager?
    /// A second manager on the SAME loaded model, so a dictation never waits
    /// behind a 30-minute meeting being transcribed.
    private var dictationAsr: AsrManager?
    private var loadedModel: SpeechModel?
    private var vad: VadManager?
    /// One diarizer per setting (they share the model files on disk).
    private var diarizers: [DiarizerSetting: OfflineDiarizerManager] = [:]

    var isReady: Bool { asr != nil && diarizers[.auto] != nil }
    var isDictationReady: Bool { dictationAsr != nil }

    /// Download (first launch only) and load the models.
    /// `status` gets a message and, while downloading, a 0...1 fraction for the progress bar.
    func prepare(model: SpeechModel = .current,
                 status: @escaping @Sendable (String, Double?) -> Void) async throws {
        if asr == nil || loadedModel != model {
            status("Downloading \(model.title) (one time, ~500 MB)…", 0)
            let models = try await AsrModels.downloadAndLoad(version: model.version, progressHandler: { p in
                switch p.phase {
                case .listing: status("Finding speech model files…", p.fractionCompleted)
                case .downloading: status("Downloading speech model (one time)…", p.fractionCompleted)
                case .compiling: status("Optimizing speech model for this Mac…", p.fractionCompleted)
                }
            })
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            let second = AsrManager(config: .default)
            try await second.loadModels(models)
            asr = manager
            dictationAsr = second
            loadedModel = model
        }
        if vad == nil {
            status("Loading voice detector…", nil)
            // 0.75 = how sure Silero must be that a 256 ms slice is speech (FluidAudio's doc example).
            vad = try await VadManager(config: VadConfig(defaultThreshold: 0.75))
        }
        status("Loading speaker models…", nil)
        _ = try await diarizer(.auto)
        status("Ready", 1)
    }

    // MARK: - Dictation

    /// Hold-to-talk audio -> text. Steps: VAD trim -> Parakeet.
    func dictate(samples: [Float]) async throws -> DictationTranscript {
        guard let dictationAsr else { throw EngineError.notReady }
        let audioSeconds = Double(samples.count) / 16_000

        // 1) Cut out silence with Silero VAD (like Handy does). Less audio = faster,
        //    and the model can't "hear" words in background hiss.
        let t0 = Date()
        var speech = samples
        if let vad {
            var seg = VadSegmentationConfig.default
            seg.minSpeechDuration = 0.25
            seg.speechPadding = 0.2          // keep 0.2 s around each part so first/last sounds aren't clipped
            seg.minSilenceDuration = 0.5
            let parts = try await vad.segmentSpeechAudio(samples, config: seg)
            if !parts.isEmpty {
                // Glue the speech parts together with a short gap so words don't run into each other.
                let gap = [Float](repeating: 0, count: 16_000 / 5)
                speech = parts.dropFirst().reduce(parts[0]) { $0 + gap + $1 }
            }
            // No speech found at all? Keep the raw audio rather than risk dropping a quiet voice.
        }
        let vadSeconds = Date().timeIntervalSince(t0)

        // Parakeet needs a little audio to work with: pad very short clips to 1 s.
        if speech.count < 16_000 { speech += [Float](repeating: 0, count: 16_000 - speech.count) }

        // 2) Speech -> text.
        let t1 = Date()
        var state = TdtDecoderState.make(decoderLayers: await dictationAsr.decoderLayerCount)
        let result = try await dictationAsr.transcribe(speech, decoderState: &state)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return DictationTranscript(text: text, audioSeconds: audioSeconds,
                                   speechSeconds: Double(speech.count) / 16_000,
                                   vadSeconds: vadSeconds, asrSeconds: Date().timeIntervalSince(t1))
    }

    private func diarizer(_ setting: DiarizerSetting) async throws -> OfflineDiarizerManager {
        if let d = diarizers[setting] { return d }
        let d = OfflineDiarizerManager(config: setting.config)
        try await d.prepareModels()      // loads from the on-disk cache after the first time
        diarizers[setting] = d
        return d
    }

    // MARK: - Pipeline

    struct Diarized {
        var segments: [TimedSpeakerSegment]
        var clusters: [SpeakerCluster]
        var seconds: Double
    }

    struct Output {
        var words: [Word]
        var utterances: [Utterance]
        var clusters: [SpeakerCluster]
        var diarizeSeconds: Double
        var transcribeSeconds: Double
        var rawSegments: [TimedSpeakerSegment]
    }

    /// Load any audio file as 16 kHz mono floats (what the models expect).
    static func loadSamples(_ url: URL) throws -> [Float] {
        try AudioConverter().resampleAudioFile(url)
    }

    /// Step 1 (slow part): segmentation + embeddings. Reusable for several cluster settings.
    func prepareDiarization(samples: [Float]) async throws -> PreparedDiarization {
        guard samples.count > 16_000 * 2 else { throw EngineError.tooShort }
        return try await diarizer(.auto).prepare(audio: samples)
    }

    /// Step 2 (fast part): group the voices into speakers, then embed each speaker's longest turns.
    func cluster(_ prepared: PreparedDiarization, samples: [Float],
                 setting: DiarizerSetting = .auto) async throws -> Diarized {
        let t0 = Date()
        let d = try await diarizer(setting)
        let result = try d.cluster(prepared)
        let segments = result.segments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }
        let clusters = try await buildClusters(segments: segments, database: result.speakerDatabase,
                                               samples: samples, diarizer: d)
        return Diarized(segments: segments, clusters: clusters, seconds: Date().timeIntervalSince(t0))
    }

    /// Who spoke when (both steps).
    func diarize(samples: [Float], setting: DiarizerSetting = .auto) async throws -> Diarized {
        let t0 = Date()
        let prepared = try await prepareDiarization(samples: samples)
        var out = try await cluster(prepared, samples: samples, setting: setting)
        out.seconds = Date().timeIntervalSince(t0)
        return out
    }

    /// What was said, as timed words.
    func transcribe(samples: [Float]) async throws -> (words: [Word], seconds: Double) {
        guard let asr else { throw EngineError.notReady }
        let t0 = Date()
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let result = try await asr.transcribe(samples, decoderState: &state)
        return (Self.words(from: result.tokenTimings ?? []), Date().timeIntervalSince(t0))
    }

    /// Run the whole pipeline on 16 kHz mono samples.
    func process(samples: [Float], setting: DiarizerSetting = .auto) async throws -> Output {
        guard asr != nil else { throw EngineError.notReady }
        let d = try await diarize(samples: samples, setting: setting)
        let t = try await transcribe(samples: samples)
        let utterances = Self.utterances(words: t.words, segments: d.segments)
        return Output(words: t.words, utterances: utterances, clusters: d.clusters,
                      diarizeSeconds: d.seconds, transcribeSeconds: t.seconds, rawSegments: d.segments)
    }

    private func buildClusters(segments: [TimedSpeakerSegment], database: [String: [Float]]?,
                               samples: [Float], diarizer: OfflineDiarizerManager) async throws -> [SpeakerCluster] {
        let keys = Array(Set(segments.map(\.speakerId))).sorted()
        let audioSeconds = Double(samples.count) / 16_000
        let source = ArrayAudioSampleSource(samples: samples)
        var clusters: [SpeakerCluster] = []
        for key in keys {
            let mine = segments.filter { $0.speakerId == key }
            let talk = mine.reduce(0.0) { $0 + Double($1.durationSeconds) }
            // Up to 8 of the longest turns that are at least 1.5 s long.
            var turns = mine.filter { $0.durationSeconds >= 1.5 }
                .sorted { $0.durationSeconds > $1.durationSeconds }
                .prefix(8)
                .map { Double($0.startTimeSeconds)..<min(Double($0.endTimeSeconds), audioSeconds) }
            if turns.isEmpty, let longest = mine.max(by: { $0.durationSeconds < $1.durationSeconds }),
               longest.durationSeconds >= 0.5 {
                turns = [Double(longest.startTimeSeconds)..<min(Double(longest.endTimeSeconds), audioSeconds)]
            }
            turns = turns.filter { $0.upperBound > $0.lowerBound }
            var embeddings: [[Float]] = []
            if !turns.isEmpty {
                embeddings = try await diarizer.embedSpans(audioSource: source, spans: turns)
                    .map(VoiceMath.normalize)
            }
            let centroid = embeddings.isEmpty
                ? VoiceMath.normalize(database?[key] ?? [])
                : VoiceMath.mean(embeddings)
            clusters.append(SpeakerCluster(key: key, talkSeconds: talk, centroid: centroid,
                                           spanEmbeddings: embeddings))
        }
        // Most talkative first.
        return clusters.sorted { $0.talkSeconds > $1.talkSeconds }
    }

    /// Parakeet gives word *pieces* ("▁robot", "ics"). A piece starting with a space starts a new word.
    static func words(from tokens: [TokenTiming]) -> [Word] {
        var words: [Word] = []
        for tok in tokens where !tok.token.isEmpty {
            if tok.token.hasPrefix(" ") || words.isEmpty {
                words.append(Word(start: tok.startTime, end: tok.endTime,
                                  text: tok.token.trimmingCharacters(in: .whitespaces)))
            } else {
                words[words.count - 1].text += tok.token
                words[words.count - 1].end = tok.endTime
            }
        }
        return words.filter { !$0.text.isEmpty }
    }

    /// Glue words to speakers and cut into readable lines.
    /// A new line starts when the speaker changes, after a pause > 1.2 s, or after ~25 s.
    static func utterances(words: [Word], segments: [TimedSpeakerSegment]) -> [Utterance] {
        func distance(_ t: Double, _ s: TimedSpeakerSegment) -> Double {
            max(Double(s.startTimeSeconds) - t, t - Double(s.endTimeSeconds), 0)
        }
        func speaker(at t: Double) -> String {
            if let s = segments.first(where: { Double($0.startTimeSeconds) <= t && t <= Double($0.endTimeSeconds) }) {
                return s.speakerId
            }
            // Word fell in a gap between turns: use the closest turn.
            return segments.min { distance(t, $0) < distance(t, $1) }?.speakerId ?? "S?"
        }

        var lines: [Utterance] = []
        var current: Utterance?
        for w in words {
            let who = speaker(at: (w.start + w.end) / 2)
            if var cur = current, who == cur.speakerKey, w.start - cur.end <= 1.2, w.start - cur.start <= 25 {
                cur.text += " " + w.text
                cur.end = w.end
                current = cur
            } else {
                if let cur = current { lines.append(cur) }
                current = Utterance(start: w.start, end: w.end, speakerKey: who, text: w.text)
            }
        }
        if let cur = current { lines.append(cur) }
        return lines
    }

    enum EngineError: LocalizedError {
        case notReady, tooShort
        var errorDescription: String? {
            switch self {
            case .notReady: return "The speech models are not loaded yet."
            case .tooShort: return "The recording is too short (needs at least 2 seconds)."
            }
        }
    }
}
