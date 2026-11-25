// TachysEngine.swift
// Tachys: the dictation speed engine (0.7.3 preview). Same model (Parakeet v2), same one-pass
// transcription, less waiting. Three things:
//
//  1. SPECULATIVE FINAL PASS. While you still hold the key, the live voice detector watches for the
//     end of your speech. As soon as ~0.4 s of quiet follows your last word, Tachys builds the exact
//     input the release would build (same VAD trim, same glue, same padding) and transcribes it in
//     the background. When you let go and nothing was said after that point, the input on release
//     is bit-for-bit the same array, so its (already finished or running) result is used: no new
//     ASR pass after release. If you spoke again, the speculation is simply thrown away and the
//     normal one-pass runs. The model never sees a stitched or partial sentence.
//  2. CANONICAL TAIL. The final input always ends 0.4 s after the last slice that sounded like
//     voice (Silero probability ≥ 0.35, well below the 0.75/0.6 the VAD uses to keep speech), so
//     trailing silence after you stop talking no longer changes the input, and when the end was
//     already quiet the 150 ms "keep listening after release" wait is skipped.
//  3. LOAD + WARM. (0.7.2.3) Loading starts at the top of launch, the four Parakeet parts load
//     in parallel, and the models stay resident. Dictation models load with explicit Core ML compute units (Neural Engine by
//     default, the same as FluidAudio's default), a dictation that was pressed while models were
//     loading starts the moment they are loaded (it no longer waits behind the warm-up pass), and
//     the warm-up runs in the background otherwise.
//
// Timing logs (Console.app, search "Tachys", or
//   log stream --predicate 'subsystem == "com.blackhawk12222.Scribe" AND category == "perf"' --level info):
//   "Tachys launch→ready: …"  process start → dictation models loaded (and warmed)
//   "Tachys release→text: …"  key release → text inserted, with hit/miss of the speculative pass
//   "Tachys first press: …"   the first dictation after launch (release → text, models wait)
//   "Parakeet Core ML load: …" parallel (0.7.2.3) or serial, per-part times, compute units
// The last values are also saved in UserDefaults (tachysLastLaunchReadyMs, tachysLastReleaseMs, tachysLastHit,
// tachysFirstPressMs, tachysFirstPressAfterLaunchMs).

import Foundation
import CoreML
import Darwin
import FluidAudio

struct TachysEngine {
    // MARK: Settings

    static let enabledKey = "tachysEnabled"
    /// Settings › Models › "Tachys speed engine" (default on). Off = the 0.7.2 path exactly.
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// Hidden override for testing compute placement: "ane" (default), "all", "gpu", "cpu".
    ///   defaults write com.blackhawk12222.Scribe tachysCompute all
    static var computeUnits: MLComputeUnits {
        switch UserDefaults.standard.string(forKey: "tachysCompute") ?? "ane" {
        case "all": return .all
        case "gpu": return .cpuAndGPU
        case "cpu": return .cpuOnly
        default: return .cpuAndNeuralEngine
        }
    }
    static var computeLabel: String {
        switch computeUnits {
        case .all: return "all"
        case .cpuAndGPU: return "CPU+GPU"
        case .cpuOnly: return "CPU"
        default: return "Neural Engine"
        }
    }

    /// Hidden ENCODER-only override (0.7.2.3), for comparing placements on a real Mac. Unset = the
    /// encoder follows `computeUnits` above (default: Neural Engine, unchanged). Only with Tachys on.
    ///   defaults write com.blackhawk12222.Scribe tachysEncoderCompute all    # or ane / gpu / cpu
    ///   defaults delete com.blackhawk12222.Scribe tachysEncoderCompute       # back to the default
    /// Then quit + reopen Scribe and read "Tachys launch→ready" / "Tachys first press" in Console.
    static var encoderComputeUnits: MLComputeUnits? {
        guard enabled else { return nil }
        switch UserDefaults.standard.string(forKey: "tachysEncoderCompute") {
        case "all": return .all
        case "ane": return .cpuAndNeuralEngine
        case "gpu": return .cpuAndGPU
        case "cpu": return .cpuOnly
        default: return nil
        }
    }
    static var encoderComputeLabel: String {
        switch encoderComputeUnits {
        case nil: return "same (\(computeLabel))"
        case .all?: return "all"
        case .cpuAndGPU?: return "CPU+GPU"
        case .cpuOnly?: return "CPU"
        default: return "Neural Engine"
        }
    }

    /// Tachys (0.7.2.3): start loading the dictation models at the very top of launch (Main.main,
    /// before SwiftUI builds the window), but only when ModelStore's quick size check says every
    /// dictation file is already on disk and current; otherwise the normal startup (download
    /// first, then load) runs as before. The startup call joins this load.
    @MainActor static func startEarlyLoad() {
        guard enabled else { return }
        let speech = SpeechModel.current
        let store = ModelStore.shared
        guard store.manifest != nil,
              store.dictationComponents(speech).allSatisfy({ store.isInstalled($0) }) else { return }
        Perf.log.info("Tachys: early model load started \(Date().timeIntervalSince(processStart) * 1000, format: .fixed(precision: 0))ms after process start")
        Task.detached(priority: .userInitiated) {
            try? await SpeechEngine.shared.prepareDictation(model: speech) { _, _ in }
        }
    }

    // MARK: First press (log once per process)

    @MainActor static var firstPressLogged = false
    /// "Tachys first press: …" — the first dictation after launch: when it was released (after
    /// process start), how long it waited for the models, and release → text.
    @MainActor static func logFirstPress(releasedAt: Date, releaseToTextMs: Double, waitedMs: Double) {
        guard !firstPressLogged else { return }
        firstPressLogged = true
        let after = releasedAt.timeIntervalSince(processStart) * 1000
        Perf.log.info("Tachys first press: release→text \(releaseToTextMs, format: .fixed(precision: 0))ms (released \(after, format: .fixed(precision: 0))ms after process start, waited \(waitedMs, format: .fixed(precision: 0))ms for the models)")
        UserDefaults.standard.set(Int(releaseToTextMs.rounded()), forKey: "tachysFirstPressMs")
        UserDefaults.standard.set(Int(after.rounded()), forKey: "tachysFirstPressAfterLaunchMs")
    }

    /// Core ML configuration for the Parakeet dictation models (FluidAudio's default config with
    /// the compute units above; FluidAudio keeps the preprocessor on the CPU either way).
    static func modelConfiguration() -> MLModelConfiguration? {
        guard enabled else { return nil }       // off: FluidAudio's own default, as in 0.7.2
        let c = AsrModels.defaultConfiguration()
        c.computeUnits = computeUnits
        return c
    }

    /// Audio kept after the last slice that sounded like voice.
    static let tailPadSamples = 16_000 * 4 / 10
    /// A VAD slice at or above this probability counts as "maybe voice" (conservative: the VAD
    /// itself needs 0.75 to start speech and 0.6 to keep it).
    static let voiceProbability: Float = 0.35
    /// No speculation for very long inputs (those use the early-sentence path anyway).
    static let maxSpeculativeSamples = 16_000 * 25

    // MARK: Per-recording state (owned by SpeechEngine)

    struct Speculation {
        let cut: Int
        let input: [Float]
        let task: Task<ASRResult, Error>
        let startedAt: Date
    }

    var active = false
    /// Samples the live VAD has looked at.
    var processed = 0
    /// End (sample index) of the newest VAD slice that sounded like voice.
    var lastVoiceEnd: Int?
    var speculation: Speculation?
    var speculationsStarted = 0

    mutating func reset(active: Bool) {
        self.active = active
        processed = 0
        lastVoiceEnd = nil
        speculation = nil          // a running pass just finishes; its result is never used
        speculationsStarted = 0
    }

    mutating func observe(sliceEnd: Int, probability: Float) {
        processed = max(processed, sliceEnd)
        if probability >= Self.voiceProbability { lastVoiceEnd = sliceEnd }
    }

    /// Where the final input ends, once ≥ tailPad of quiet follows the last voice; nil = not yet
    /// (or no voice at all), so the whole recording is used, as before.
    func cut(available: Int) -> Int? {
        guard active, let v = lastVoiceEnd else { return nil }
        let c = v + Self.tailPadSamples
        return c <= min(available, processed) ? c : nil
    }

    /// The end of the recording was already quiet (the user had stopped talking).
    var quietAtEnd: Bool { cut(available: processed) != nil }

    // MARK: Launch clock

    /// When this process started (kernel start time; falls back to first use).
    static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        if sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 {
            let tv = info.kp_proc.p_un.__p_starttime
            let d = Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
            if d.timeIntervalSinceNow < 0, d.timeIntervalSinceNow > -3600 { return d }
        }
        return Date()
    }()

    /// Saved so the numbers can be read without Console:
    ///   defaults read com.blackhawk12222.Scribe | grep tachys
    static func record(launchReadyMs: Double) {
        UserDefaults.standard.set(Int(launchReadyMs.rounded()), forKey: "tachysLastLaunchReadyMs")
    }
    static func record(releaseToTextMs: Double, hit: Bool) {
        UserDefaults.standard.set(Int(releaseToTextMs.rounded()), forKey: "tachysLastReleaseMs")
        UserDefaults.standard.set(hit, forKey: "tachysLastHit")
    }
}
