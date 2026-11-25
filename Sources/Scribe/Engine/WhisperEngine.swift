// WhisperEngine.swift
// Optional Whisper dictation engines through WhisperKit (Argmax, MIT license, Core ML).
// The model files come from ModelStore (pinned in Resources/ModelManifest.json); WhisperKit is
// told to NEVER download anything itself (download: false, local model + tokenizer folders).
// Only this file imports WhisperKit, so its type names never clash with FluidAudio's.

import Foundation
import CoreML
import WhisperKit

actor WhisperEngine {
    static let shared = WhisperEngine()

    private var kits: [DictationEngine: WhisperKit] = [:]
    /// The self-test sets this on GitHub's runner (no Neural Engine there): the audio encoder runs
    /// on the GPU instead of falling back to the CPU. On a real Mac WhisperKit's defaults are used.
    static var encoderOnGPU = false

    func isLoaded(_ engine: DictationEngine) -> Bool { kits[engine] != nil }

    /// Where ModelStore put this engine's files.
    static func folders(_ engine: DictationEngine) -> (model: URL, tokenizer: URL)? {
        guard let sub = engine.whisperSubfolder,
              let model = ModelManifest.bundled?.component(engine.componentIDs[0]),
              let tok = ModelManifest.bundled?.component("whisper-tokenizer") else { return nil }
        return (model.folder().appendingPathComponent(sub, isDirectory: true), tok.folder())
    }

    /// Load (the files must already be on disk: ModelStore.ensure(engine.componentIDs)).
    func load(_ engine: DictationEngine) async throws {
        guard engine.isWhisper, kits[engine] == nil else { return }
        guard let f = Self.folders(engine) else { throw WhisperEngineError.noManifest }
        let compute = Self.encoderOnGPU
            ? ModelComputeOptions(melCompute: .cpuAndGPU, audioEncoderCompute: .cpuAndGPU, textDecoderCompute: .cpuAndGPU)
            : nil
        let config = WhisperKitConfig(modelFolder: f.model.path, tokenizerFolder: f.tokenizer,
                                      computeOptions: compute, verbose: false,
                                      prewarm: false, load: true, download: false)
        let kit = try await WhisperKit(config)
        kits[engine] = kit
        // One short call so Core ML finishes its one-time setup now, not on the first dictation.
        _ = try? await kit.transcribe(audioArray: [Float](repeating: 0, count: 16_000), decodeOptions: Self.options)
    }

    func unload(_ engine: DictationEngine) async {
        if let k = kits[engine] { await k.unloadModels() }
        kits[engine] = nil
    }

    static var options: DecodingOptions {
        DecodingOptions(verbose: false, task: .transcribe, language: "en", temperature: 0,
                        temperatureFallbackCount: 3, usePrefillPrompt: true, detectLanguage: false,
                        skipSpecialTokens: true, withoutTimestamps: true)
    }

    /// 16 kHz mono speech → text (one pass; WhisperKit windows audio longer than 30 s itself).
    func transcribe(_ samples: [Float], engine: DictationEngine) async throws -> String {
        if kits[engine] == nil { try await load(engine) }
        guard let kit = kits[engine] else { throw WhisperEngineError.notLoaded }
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: Self.options)
        return Self.clean(results.map(\.text).joined(separator: " "))
    }

    /// Drop any special tokens ("<|endoftext|>") or bracketed non-speech tags ("[BLANK_AUDIO]").
    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\[(?:BLANK_AUDIO|MUSIC|NOISE|SILENCE)[^\\]]*\\]", with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum WhisperEngineError: LocalizedError {
    case noManifest, notLoaded
    var errorDescription: String? {
        switch self {
        case .noManifest: return "This Whisper model isn't in the model list."
        case .notLoaded: return "The Whisper model isn't loaded."
        }
    }
}
