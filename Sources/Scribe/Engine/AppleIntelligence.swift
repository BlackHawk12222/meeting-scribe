// AppleIntelligence.swift
// A tiny wrapper around Apple's on-device language model (the Foundation Models
// framework, macOS 26+ on a Mac with Apple Intelligence turned on).
//
// Two "gates" keep the app working everywhere:
//  1. `#if canImport(FoundationModels)` — the code is only compiled if the Xcode
//     that builds the app has the macOS 26 SDK. Older Xcode: this file compiles
//     to "not available" and the app uses the simple rule-based cleanup.
//  2. `#available(macOS 26.0, *)` + `SystemLanguageModel.default.availability` —
//     checked while the app runs: older macOS, an Intel Mac, Apple Intelligence
//     switched off, or the model still downloading all mean "not available".
//
// Nothing here goes to the internet. The model runs on this Mac and is free.

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum AppleIntelligence {
    /// true when we can use the on-device model right now.
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// A short human sentence for Settings ("Ready", "Turn on Apple Intelligence…").
    static var statusText: String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return "Ready (on-device)"
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return "This Mac can't run Apple Intelligence"
                case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence in System Settings"
                case .modelNotReady: return "Apple Intelligence is still downloading its model"
                @unknown default: return "Apple Intelligence is not available"
                }
            }
        }
        return "Needs macOS 26 (Tahoe) with Apple Intelligence"
        #else
        return "This copy of Scribe was built without the macOS 26 SDK"
        #endif
    }

    /// Ask the model for plain text. Returns nil if it isn't available or fails
    /// (callers always have a non-AI fallback).
    static func respond(instructions: String, prompt: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard isAvailable else { return nil }
            do {
                let session = LanguageModelSession(instructions: instructions)
                // Greedy = always pick the most likely word, so the same input gives the same output.
                let response = try await session.respond(to: prompt, options: GenerationOptions(sampling: .greedy))
                return response.content
            } catch {
                print("Apple Intelligence failed: \(error)")
                return nil
            }
        }
        #endif
        return nil
    }
}
