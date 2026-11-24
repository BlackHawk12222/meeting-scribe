// DictationEngine.swift
// Which speech model turns your DICTATION into text (Settings › Model, or "Use this model" in
// Test my voice). Meetings always use Parakeet (they need word timings for the speakers).
//
//  • Parakeet v2 / v3: NVIDIA Parakeet TDT 0.6B through FluidAudio (the default is v2).
//  • Whisper large-v3 turbo / distil-large-v3: OpenAI Whisper through WhisperKit (Argmax, MIT),
//    Core ML, quantized (~600 MB each). Optional, downloaded only when you pick or test one.
// Every model downloads through ModelStore (Resources/ModelManifest.json), pinned to one commit.

import Foundation

enum DictationEngine: String, CaseIterable, Identifiable, Sendable {
    case parakeetV2 = "parakeet-v2"
    case parakeetV3 = "parakeet-v3"
    case whisperTurbo = "whisper-turbo"
    case whisperDistil = "whisper-distil"

    static let key = "dictationEngine"
    /// The default until a benchmark clearly says otherwise (see BENCHMARKS.md, voice test).
    static let standard: DictationEngine = .parakeetV2

    var id: String { rawValue }

    var title: String {
        switch self {
        case .parakeetV2: return "Parakeet v2 (English)"
        case .parakeetV3: return "Parakeet v3 (25 languages)"
        case .whisperTurbo: return "Whisper large-v3 turbo"
        case .whisperDistil: return "Whisper distil-large-v3"
        }
    }

    var shortTitle: String {
        switch self {
        case .parakeetV2: return "Parakeet v2"
        case .parakeetV3: return "Parakeet v3"
        case .whisperTurbo: return "Whisper turbo"
        case .whisperDistil: return "Whisper distil"
        }
    }

    var detail: String {
        switch self {
        case .parakeetV2: return "Default. Fast, English only."
        case .parakeetV3: return "Also Spanish, German, French and 21 more."
        case .whisperTurbo: return "OpenAI Whisper via WhisperKit. Slower; optional download."
        case .whisperDistil: return "Smaller, English-tuned Whisper. Optional download."
        }
    }

    var isWhisper: Bool { self == .whisperTurbo || self == .whisperDistil }

    /// The Parakeet model this engine uses (nil = a Whisper engine).
    var speechModel: SpeechModel? {
        switch self {
        case .parakeetV2: return .english
        case .parakeetV3: return .multilingual
        default: return nil
        }
    }

    /// ModelManifest components this engine needs (besides the voice detector).
    var componentIDs: [String] {
        switch self {
        case .parakeetV2: return ["asr-v2"]
        case .parakeetV3: return ["asr-v3"]
        case .whisperTurbo: return ["whisper-turbo", "whisper-tokenizer"]
        case .whisperDistil: return ["whisper-distil", "whisper-tokenizer"]
        }
    }

    /// Folder (inside the component's folder) that holds the WhisperKit model.
    var whisperSubfolder: String? {
        switch self {
        case .whisperTurbo: return "openai_whisper-large-v3-v20240930_turbo_632MB"
        case .whisperDistil: return "distil-whisper_distil-large-v3_594MB"
        default: return nil
        }
    }

    /// Download size in bytes (from the bundled manifest).
    var downloadBytes: Int64 {
        componentIDs.compactMap { ModelManifest.bundled?.component($0)?.totalBytes }.reduce(0, +)
    }

    /// What the user picked. Without an explicit choice it follows the older "speechModel" setting.
    static var current: DictationEngine {
        if let raw = UserDefaults.standard.string(forKey: key), let e = DictationEngine(rawValue: raw) { return e }
        return SpeechModel.current == .multilingual ? .parakeetV3 : standard
    }

    /// Make `engine` the dictation engine. A Parakeet choice also sets the Parakeet model
    /// (so meetings and dictation use the same one, as before).
    static func select(_ engine: DictationEngine) {
        UserDefaults.standard.set(engine.rawValue, forKey: key)
        if let m = engine.speechModel { UserDefaults.standard.set(m.rawValue, forKey: "speechModel") }
    }
}
