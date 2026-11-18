// SpeechEngine.swift
// The "brain": turns an audio recording into a speaker-labeled transcript.
//
//  1. Diarization  ("who spoke when")   -> FluidAudio OfflineDiarizerManager
//     (pyannote Community-1 segmentation + WeSpeaker voice embeddings + VBx clustering)
//  2. Transcription ("what was said")   -> FluidAudio Parakeet TDT 0.6B v2 (English)
//  3. Merge: every word gets the speaker who was talking at that moment.
//  4. Voice embeddings for each speaker -> used by VoiceLibrary to put names on them.
//
// All models run on-device with Core ML (Neural Engine / GPU / CPU).
// They download once (~600 MB) into Application Support and then work offline.

import Foundation
import FluidAudio

actor SpeechEngine {
    static let shared = SpeechEngine()

    private var asr: AsrManager?
    private var diarizer: OfflineDiarizerManager?

    var isReady: Bool { asr != nil && diarizer != nil }

    /// Download (first launch only) and load the models.
    func prepare(status: @escaping @Sendable (String) -> Void) async throws {
        if diarizer == nil {
            status("Loading speaker models…")
            var config = OfflineDiarizerConfig()
            // One speaker at a time, so every word maps to exactly one person.
            config.exclusiveSegments = true
            let d = OfflineDiarizerManager(config: config)
            try await d.prepareModels()
            diarizer = d
        }
        if asr == nil {
            status("Loading speech-to-text model (first time downloads ~500 MB)…")
            let models = try await AsrModels.downloadAndLoad(version: .v2)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            asr = manager
        }
        status("Ready")
    }

    struct Output {
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

    /// Run the whole pipeline on 16 kHz mono samples.
    func process(samples: [Float], transcribe: Bool = true) async throws -> Output {
        guard let diarizer, let asr else { throw EngineError.notReady }
        guard samples.count > 16_000 * 2 else { throw EngineError.tooShort }

        // 1) Who spoke when.
        let t0 = Date()
        let diarization = try await diarizer.process(audio: samples)
        let segments = diarization.segments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }
        let diarizeSeconds = Date().timeIntervalSince(t0)

        // 2) Voice embeddings per speaker, from that speaker's longest turns.
        let clusters = try await buildClusters(segments: segments, database: diarization.speakerDatabase,
                                               samples: samples, diarizer: diarizer)

        // 3) What was said (with a timestamp on every token).
        var tokens: [TokenTiming] = []
        var transcribeSeconds = 0.0
        if transcribe {
            let t1 = Date()
            var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
            let result = try await asr.transcribe(samples, decoderState: &state)
            tokens = result.tokenTimings ?? []
            transcribeSeconds = Date().timeIntervalSince(t1)
        }

        // 4) Glue words to speakers.
        let utterances = Self.mergeWords(tokens: tokens, segments: segments)
        return Output(utterances: utterances, clusters: clusters, diarizeSeconds: diarizeSeconds,
                      transcribeSeconds: transcribeSeconds, rawSegments: segments)
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

    /// Turn timed tokens + speaker turns into readable lines.
    /// A new line starts when the speaker changes, after a pause > 1.2 s, or after ~25 s.
    static func mergeWords(tokens: [TokenTiming], segments: [TimedSpeakerSegment]) -> [Utterance] {
        func speaker(at t: Double) -> String {
            if let s = segments.first(where: { Double($0.startTimeSeconds) <= t && t <= Double($0.endTimeSeconds) }) {
                return s.speakerId
            }
            // Word fell in a gap: use the closest turn.
            let nearest = segments.min {
                distance(t, $0) < distance(t, $1)
            }
            return nearest?.speakerId ?? "S?"
        }
        func distance(_ t: Double, _ s: TimedSpeakerSegment) -> Double {
            max(Double(s.startTimeSeconds) - t, t - Double(s.endTimeSeconds), 0)
        }

        var lines: [Utterance] = []
        var current: Utterance?
        for tok in tokens {
            let piece = tok.token
            if piece.isEmpty { continue }
            let startsWord = piece.hasPrefix(" ") || current == nil
            let who = speaker(at: (tok.startTime + tok.endTime) / 2)
            if var cur = current {
                let gap = tok.startTime - cur.end
                let tooLong = tok.startTime - cur.start > 25
                // Only break between words (never in the middle of one).
                if startsWord && (who != cur.speakerKey || gap > 1.2 || tooLong) {
                    cur.text = cur.text.trimmingCharacters(in: .whitespaces)
                    lines.append(cur)
                    current = Utterance(start: tok.startTime, end: tok.endTime, speakerKey: who, text: piece)
                } else {
                    cur.text += piece
                    cur.end = tok.endTime
                    current = cur
                }
            } else {
                current = Utterance(start: tok.startTime, end: tok.endTime, speakerKey: who, text: piece)
            }
        }
        if var cur = current {
            cur.text = cur.text.trimmingCharacters(in: .whitespaces)
            lines.append(cur)
        }
        return lines.filter { !$0.text.isEmpty }
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
