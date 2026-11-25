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
import os
import Combine
import FluidAudio

/// The pipeline from audio to finished text, without any UI. Used by the app AND the self-test.
enum Dictation {
    struct Result {
        var transcript: DictationTranscript
        var text: String
        var method: CleanupMethod
        var cleanupSeconds: Double
    }

    /// Short dictations (under this) never wait for Apple Intelligence: rules only, instant.
    static let aiMinimumSeconds = 8.0
    /// Longer ones give Apple Intelligence at most this long, then paste the rule-cleaned text.
    static let aiTimeout: Double = 1.2

    /// `engine`: which dictation engine (nil = the one picked in Settings). A Whisper engine that
    /// isn't loaded yet falls back to Parakeet for this dictation instead of making you wait.
    static func run(samples: [Float], useAI: Bool, removeFillers: Bool, live: Bool = false,
                    session: UUID? = nil, asrOverride: AsrManager? = nil,
                    engine: DictationEngine? = nil) async throws -> Result {
        let chosen = engine ?? DictationEngine.current
        var external: (@Sendable ([Float]) async throws -> String)? = nil
        var useWhisper = false
        if chosen.isWhisper, asrOverride == nil {
            if engine != nil { useWhisper = true } else { useWhisper = await WhisperEngine.shared.isLoaded(chosen) }
        }
        if useWhisper {
            external = { audio in try await WhisperEngine.shared.transcribe(audio, engine: chosen) }
        }
        let t = try await SpeechEngine.shared.dictate(samples: samples, live: live, session: session,
                                                      asrOverride: asrOverride, external: external)
        let t0 = Date()
        // Rules (fillers, false starts, numbers, capitals) then your vocabulary list. Both < 20 ms.
        let rulesText = Vocabulary.apply(removeFillers ? TextCleanup.rules(t.text) : TextCleanup.light(t.text))
        var text = rulesText
        var method: CleanupMethod = removeFillers ? .rules : .none
        if useAI, AppleIntelligence.isAvailable, t.audioSeconds >= aiMinimumSeconds, !t.text.isEmpty {
            // Race Apple Intelligence against a timer: the paste never waits longer than aiTimeout.
            let raw = t.text
            let smart: (String, CleanupMethod)? = await withTaskGroup(of: (String, CleanupMethod)?.self) { group in
                group.addTask { await TextCleanup.clean(raw, useAI: true, removeFillers: removeFillers) }
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(aiTimeout * 1_000_000_000))
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            if let smart { text = Vocabulary.apply(smart.0); method = smart.1 }
        }
        return Result(transcript: t, text: text, method: method, cleanupSeconds: Date().timeIntervalSince(t0))
    }
}

@MainActor
final class DictationController: ObservableObject {
    enum State: Equatable {
        case idle, listening, transcribing
        case done(String), failed(String)
        /// Text was copied, but typing needs Accessibility (capsule shows a Fix button).
        case needsAccess
        var isFailure: Bool {
            switch self { case .failed, .needsAccess: return true; default: return false }
        }
        var isBusy: Bool { self == .listening || self == .transcribing }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: 16)
    @Published private(set) var elapsed: TimeInterval = 0

    let hotkeys = HotkeyManager()
    private let mic = MicCapture()
    private let overlay = OverlayPanel()
    /// Mic level history that the overlay's bars are drawn from.
    let tape = LevelTape()
    /// Microphone audio on its way to the live voice detector, in order.
    private let liveFeedBox = LiveFeedBox()
    private var liveFeed: AsyncStream<[Float]>.Continuation? {
        get { liveFeedBox.get() }
        set { liveFeedBox.set(newValue) }
    }
    private var liveConsumer: Task<Void, Never>?
    /// Each recording gets a fresh id; audio, live VAD state and the result are tied to it, so
    /// an old recording's text can never be inserted for a new one.
    private var session = UUID()
    private weak var store: Store?
    private weak var recorder: Recorder?
    private var startedAt: Date?
    private var ticker: Timer?
    private var hideWork: DispatchWorkItem?
    /// Where the text goes: the app + text box in front when you started talking.
    private var target: FocusTarget?

    /// Holding less than this = an accidental tap: ignored (Handy uses 300 ms too).
    static let minimumHold: TimeInterval = 0.3
    /// Safety limit so a stuck key can't record forever.
    static let maximumLength: TimeInterval = 10 * 60

    /// Only for `Scribe --snapshot` (CI screenshots): show the overlay in a given state with fake levels.
    func setPreview(state: State, levels: [Float], elapsed: TimeInterval) {
        self.state = state
        self.levels = levels
        self.elapsed = elapsed
    }

    /// Stack the dictation capsule next to the meeting capsule while a meeting records.
    var overlayLift: CGFloat {
        get { overlay.lift }
        set { overlay.lift = newValue }
    }

    private func showOverlay() {
        overlay.lift = recorder?.isRecording == true ? 40 : 0
        overlay.show(DictationOverlayView().environmentObject(self))
    }

    func attach(store: Store, recorder: Recorder) {
        self.store = store
        self.recorder = recorder
        mic.onLevel = { [weak self] level in
            guard let self, self.state == .listening else { return }
            self.levels.removeFirst()
            self.levels.append(level)
            self.tape.add(level)
        }
        // Every slice of mic audio also goes to the live voice detector (see SpeechEngine).
        let box = liveFeedBox
        mic.onSamples = { @Sendable chunk in box.get()?.yield(chunk) }
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
        FocusTracker.start()
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
        // Start the live voice detector before the mic so no audio is missed.
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        liveFeed = continuation
        session = UUID()
        let mySession = session
        liveConsumer = Task.detached(priority: .userInitiated) {
            await SpeechEngine.shared.liveVadStart(session: mySession, earlyParts: !DictationEngine.current.isWhisper)
            for await chunk in stream { await SpeechEngine.shared.liveVadFeed(chunk) }
        }
        do {
            try mic.start()
        } catch {
            stopLiveFeed(cancel: true)
            flash(.failed("Mic error: \(error.localizedDescription)"))
            return
        }
        hideWork?.cancel()
        // Remember where you are NOW (app + text box), so the words go there even if focus moves.
        target = FocusTracker.capture()
        if !Permissions.accessibilityGranted {
            FocusTracker.log.info("dictation started without Accessibility: text will be copied, not typed")
        }
        levels = Array(repeating: 0, count: levels.count)
        startedAt = Date()
        elapsed = 0
        tape.reset()
        state = .listening
        showOverlay()
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
        stopLiveFeed(cancel: true)
        if silently {
            state = .idle
            overlay.hide()
        } else {
            flash(.done("Cancelled"))
        }
    }

    func finish() {
        guard state == .listening else { return }
        ticker?.invalidate()
        tape.stop()
        state = .transcribing
        if DictationSettings.sounds { NSSound(named: "Pop")?.play() }
        let released = Date()
        let mySession = session
        Task {
            // Keep listening 150 ms after you let go, so the last sound isn't cut off.
            try? await Task.sleep(nanoseconds: 150_000_000)
            let samples = mic.stop()
            let consumer = stopLiveFeed(cancel: false)
            guard Double(samples.count) / 16_000 >= Self.minimumHold else {
                await SpeechEngine.shared.liveVadCancel()
                state = .idle
                overlay.hide()
                return
            }
            await consumer?.value          // the live VAD has seen every slice (takes ~ms)
            Perf.log.info("key release → mic stopped + live VAD caught up: \(Date().timeIntervalSince(released) * 1000, format: .fixed(precision: 0))ms")
            do {
                let r = try await Dictation.run(samples: samples, useAI: DictationSettings.aiCleanup,
                                                removeFillers: DictationSettings.removeFillers, live: true,
                                                session: mySession)
                guard mySession == session else { return }      // a newer recording started: drop this one
                guard !r.text.isEmpty else {
                    flash(.done("Didn't catch that"))
                    return
                }
                let text = r.text + (DictationSettings.trailingSpace ? " " : "")
                let paste = await TextInserter.insert(text, target: target, restoreClipboard: DictationSettings.restoreClipboard)
                let outcome = paste.outcome
                store?.addDictation(DictationEntry(date: Date(), text: r.text, raw: r.transcript.text, method: r.method,
                                                   audioSeconds: r.transcript.audioSeconds,
                                                   latencySeconds: Date().timeIntervalSince(released)))
                Perf.log.info("key release → text inserted: \(Date().timeIntervalSince(released) * 1000, format: .fixed(precision: 0))ms")
                switch outcome {
                case .typedDirectly, .pasted: flash(.done("Done"))
                case .noTextBox: flash(.done("Copied — no text box selected"))
                case .needsAccessibility: flash(.needsAccess)
                case .copiedOnly: flash(.done("Copied — press ⌘V"))
                }
            } catch {
                flash(.failed(error.localizedDescription))
            }
        }
    }

    /// Ends the live VAD feed. Returns the consumer task so the caller can wait for it.
    @discardableResult
    private func stopLiveFeed(cancel: Bool) -> Task<Void, Never>? {
        liveFeed?.finish()
        liveFeed = nil
        let c = liveConsumer
        liveConsumer = nil
        if cancel {
            c?.cancel()
            Task { await SpeechEngine.shared.liveVadCancel() }
        }
        return c
    }

    /// Show a message in the overlay for a moment, then hide it.
    private func flash(_ s: State) {
        state = s
        showOverlay()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.state.isBusy else { return }
                self.state = .idle
                self.overlay.hide()
            }
        }
        hideWork = work
        let seconds: Double
        switch s {
        case .needsAccess: seconds = 7          // long enough to click Fix
        case .done(let m) where m.hasPrefix("Copied"): seconds = 2.5
        case .failed: seconds = 2.5
        default: seconds = 1.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

/// Holds the live-VAD stream so the audio thread can reach it without touching the main actor.
final class LiveFeedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: AsyncStream<[Float]>.Continuation?
    func get() -> AsyncStream<[Float]>.Continuation? { lock.lock(); defer { lock.unlock() }; return cont }
    func set(_ c: AsyncStream<[Float]>.Continuation?) { lock.lock(); cont = c; lock.unlock() }
}
