// DictationController.swift
// The dictation "state machine":
//
//   idle ──(hold key down / toggle)──▶ listening ──(key up / toggle)──▶ transcribing ──▶ done ──▶ idle
//                                         │
//                                         └──(Esc, tap too short, key used for a shortcut)──▶ idle
//
// The actual work lives elsewhere:
//   MicCapture (mic) → SpeechEngine.dictate (VAD + Parakeet) → TextCleanup → TextInserter (⌘V)
// The same `Dictation.run` pipeline is used by the self-test on GitHub's Mac.

import AppKit
import Combine

/// The pipeline from audio to finished text, without any UI. Used by the app AND the self-test.
enum Dictation {
    struct Result {
        var transcript: DictationTranscript
        var text: String
        var method: CleanupMethod
        var cleanupSeconds: Double
    }

    static func run(samples: [Float], useAI: Bool, removeFillers: Bool) async throws -> Result {
        let t = try await SpeechEngine.shared.dictate(samples: samples)
        let t0 = Date()
        let (text, method) = await TextCleanup.clean(t.text, useAI: useAI, removeFillers: removeFillers)
        return Result(transcript: t, text: text, method: method, cleanupSeconds: Date().timeIntervalSince(t0))
    }
}

@MainActor
final class DictationController: ObservableObject {
    enum State: Equatable {
        case idle, listening, transcribing
        case done(String), failed(String)
        var isFailure: Bool { if case .failed = self { return true }; return false }
        var isBusy: Bool { self == .listening || self == .transcribing }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: 16)
    @Published private(set) var elapsed: TimeInterval = 0

    let hotkeys = HotkeyManager()
    private let mic = MicCapture()
    private let pill = PillOverlay()
    private weak var store: Store?
    private weak var recorder: Recorder?
    private var startedAt: Date?
    private var ticker: Timer?
    private var hideWork: DispatchWorkItem?

    /// Holding less than this = an accidental tap: ignored (Handy uses 300 ms too).
    static let minimumHold: TimeInterval = 0.3
    /// Safety limit so a stuck key can't record forever.
    static let maximumLength: TimeInterval = 10 * 60

    /// Only for `Scribe --snapshot` (CI screenshots): show the pill in a given state with fake levels.
    func setPreview(state: State, levels: [Float], elapsed: TimeInterval) {
        self.state = state
        self.levels = levels
        self.elapsed = elapsed
    }

    func attach(store: Store, recorder: Recorder) {
        self.store = store
        self.recorder = recorder
        mic.onLevel = { [weak self] level in
            guard let self, self.state == .listening else { return }
            self.levels.removeFirst()
            self.levels.append(level)
        }
        hotkeys.onHoldStart = { [weak self] in self?.begin() }
        hotkeys.onHoldEnd = { [weak self] held in
            guard let self else { return }
            if held < Self.minimumHold { self.cancel(silently: true) } else { self.finish() }
        }
        hotkeys.onHoldInterrupted = { [weak self] in
            guard let self, self.state == .listening else { return }
            self.cancel(silently: true)
        }
        hotkeys.onToggle = { [weak self] in self?.toggle() }
        hotkeys.onEscape = { [weak self] in
            guard let self, self.state == .listening else { return }
            self.cancel(silently: false)
        }
        hotkeys.start()
    }

    /// Menu bar button / toggle shortcut.
    func toggle() {
        switch state {
        case .listening: finish()
        case .transcribing: break
        default: begin()
        }
    }

    // MARK: - Steps

    func begin() {
        guard !state.isBusy else { return }
        guard store?.engineReady == true else {
            flash(.failed("Models are still loading…"))
            return
        }
        guard recorder?.isRecording != true else {
            flash(.failed("A meeting is recording"))
            return
        }
        guard Permissions.microphoneGranted else {
            Task {
                _ = await Recorder.requestPermission()
                if !Permissions.microphoneGranted { self.flash(.failed("Allow the microphone in Settings")) }
            }
            return
        }
        do {
            try mic.start()
        } catch {
            flash(.failed("Mic error: \(error.localizedDescription)"))
            return
        }
        hideWork?.cancel()
        levels = Array(repeating: 0, count: levels.count)
        startedAt = Date()
        elapsed = 0
        state = .listening
        pill.show(self)
        if DictationSettings.sounds { NSSound(named: "Tink")?.play() }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let s = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(s)
                if self.elapsed > Self.maximumLength { self.finish() }
            }
        }
    }

    func cancel(silently: Bool) {
        guard state == .listening else { return }
        ticker?.invalidate()
        _ = mic.stop()
        if silently {
            state = .idle
            pill.hide()
        } else {
            flash(.done("Cancelled"))
        }
    }

    func finish() {
        guard state == .listening else { return }
        ticker?.invalidate()
        state = .transcribing
        if DictationSettings.sounds { NSSound(named: "Pop")?.play() }
        let released = Date()
        Task {
            // Keep listening 150 ms after you let go, so the last sound isn't cut off.
            try? await Task.sleep(nanoseconds: 150_000_000)
            let samples = mic.stop()
            guard Double(samples.count) / 16_000 >= Self.minimumHold else {
                state = .idle
                pill.hide()
                return
            }
            do {
                let r = try await Dictation.run(samples: samples, useAI: DictationSettings.aiCleanup,
                                                removeFillers: DictationSettings.removeFillers)
                guard !r.text.isEmpty else {
                    flash(.done("Didn't catch that"))
                    return
                }
                let text = r.text + (DictationSettings.trailingSpace ? " " : "")
                let outcome = await TextInserter.insert(text, restoreClipboard: DictationSettings.restoreClipboard)
                store?.addDictation(DictationEntry(date: Date(), text: r.text, raw: r.transcript.text, method: r.method,
                                                   audioSeconds: r.transcript.audioSeconds,
                                                   latencySeconds: Date().timeIntervalSince(released)))
                flash(outcome == .pasted ? .done("Done") : .done("Copied – press ⌘V"))
            } catch {
                flash(.failed(error.localizedDescription))
            }
        }
    }

    /// Show a message in the pill for a moment, then hide it.
    private func flash(_ s: State) {
        state = s
        pill.show(self)
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.state.isBusy else { return }
                self.state = .idle
                self.pill.hide()
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (s.isFailure ? 2.5 : 1.0), execute: work)
    }
}
