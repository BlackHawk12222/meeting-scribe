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
// They download once (~465 MB for dictation, +22 MB speaker models for meetings) into
// Application Support and then work offline. Engine/ModelStore.swift decides what to download.

import Foundation
import FluidAudio
import os

/// Timing logs. See them live: Console.app → search "Scribe", or
///   log stream --predicate 'subsystem == "com.blackhawk12222.Scribe"' --level info
/// Signposts show up in Instruments (Points of Interest).
enum Perf {
    static let log = Logger(subsystem: "com.blackhawk12222.Scribe", category: "perf")
    static let signposter = OSSignposter(subsystem: "com.blackhawk12222.Scribe", category: .pointsOfInterest)
}

/// How the diarizer should decide how many people there are.
struct DiarizerSetting: Hashable, Sendable {
    /// nil = let the model decide ("Auto"). A number = "there were exactly N people".
    var speakers: Int? = nil
    // Advanced clustering knobs (used by the self-test to compare settings).
    var threshold: Double? = nil
    var fa: Double? = nil
    var fb: Double? = nil
    /// true = one speaker at a time (every word maps to exactly one person). false = keep
    /// overlapping speech (two people at once), which scores better but needs a "main speaker"
    /// pick before words are attached.
    var exclusive: Bool = true

    static let auto = DiarizerSetting()
    static let defaultFa = 0.2

    var label: String {
        var parts: [String] = []
        if let s = speakers { parts.append("exactly\(s)") }
        if let t = threshold { parts.append("thr\(t)") }
        if let a = fa { parts.append("Fa\(a)") }
        if let b = fb { parts.append("Fb\(b)") }
        if !exclusive { parts.append("overlap") }
        return parts.isEmpty ? "auto" : parts.joined(separator: "_")
    }

    var config: OfflineDiarizerConfig {
        var c = OfflineDiarizerConfig()
        // One speaker at a time, so every word maps to exactly one person.
        c.exclusiveSegments = exclusive
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

/// Which speech-to-text model to use (Settings > Model). All are NVIDIA Parakeet TDT 0.6B
/// variants converted to Core ML by FluidAudio. Why these and not Whisper: see BENCHMARKS.md.
enum SpeechModel: String, CaseIterable, Identifiable, Sendable {
    case english = "v2"        // default ("Fast"): most accurate for English in our tests so far
    case multilingual = "v3"   // 25 European languages, auto-detected
    case accurate = "ultra"    // Parakeet Ultra (post-trained v3); offered only if it measured better

    var id: String { rawValue }
    var version: AsrModelVersion {
        switch self {
        case .english: return .v2
        case .multilingual: return .v3
        case .accurate: return .ultra
        }
    }
    var componentID: String {
        switch self {
        case .english: return "asr-v2"
        case .multilingual: return "asr-v3"
        case .accurate: return "asr-ultra"
        }
    }
    var title: String {
        switch self {
        case .english: return "Fast · Parakeet v2 (English)"
        case .multilingual: return "Parakeet v3 · 25 languages"
        case .accurate: return "Accurate · Parakeet Ultra"
        }
    }
    var detail: String {
        switch self {
        case .english: return SpeechModel.fastDetail
        case .multilingual: return "Use if you speak Spanish, German, French… Measured 5.0% word errors on our English test set (sandbox)."
        case .accurate: return SpeechModel.accurateDetail
        }
    }
    /// Filled in from the runner measurements (BENCHMARKS.md, section G).
    static let fastDetail = "Best speed. Default for English."
    static let accurateDetail = "Larger model (+630 MB download). Measured on GitHub's Mac runner — see BENCHMARKS.md."
    /// Whether Settings shows the "Accurate" choice. Set from the measured comparison (0.5).
    static let offerAccurate = false
    static var choices: [SpeechModel] { offerAccurate ? [.english, .accurate, .multilingual] : [.english, .multilingual] }

    /// What the user picked in Settings (stored in UserDefaults under "speechModel").
    static var current: SpeechModel {
        let m = SpeechModel(rawValue: UserDefaults.standard.string(forKey: "speechModel") ?? "") ?? .english
        return choices.contains(m) ? m : .english
    }
}

/// Builds the meeting status line from the two parallel jobs.
actor MeetingProgress {
    let report: (@Sendable (String) -> Void)?
    private var speakerFraction: Double = 0
    private var transcriptDone = false
    init(report: (@Sendable (String) -> Void)?) { self.report = report }
    func speakers(_ done: Int, _ total: Int) {
        speakerFraction = total > 0 ? Double(done) / Double(total) : 0
        send()
    }
    func transcribed() { transcriptDone = true; send() }
    private func send() {
        if speakerFraction < 1 {
            report?("Finding speakers \(Int(speakerFraction * 100))% · then the transcript")
        } else {
            report?(transcriptDone ? "Writing notes…" : "Speakers found · transcribing…")
        }
    }
}

/// What one dictation produced, plus timings (the self-test prints these).
struct DictationTranscript: Sendable {
    var text: String
    var audioSeconds: Double      // how long you held the key
    var speechSeconds: Double     // what was left after cutting silence
    var vadSeconds: Double        // time spent finding speech
    var asrSeconds: Double        // time spent transcribing
    var vadMode: String = ""      // "single pass (live VAD)", "one pass", "incremental…" or "skipped (short clip)"
    var boostSeconds: Double = 0  // time the vocabulary helper (CTC) took
    var boostReplacements: [String] = []
    /// Tachys: "hit" (speculative pass reused), "miss", "full" (end not quiet yet), "off".
    var tachys: String = "off"
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
    var isMeetingReady: Bool { asr != nil && diarizers[.auto] != nil }

    /// Load everything (dictation + meeting models). Used by the self-test.
    func prepare(model: SpeechModel = .current,
                 status: @escaping @Sendable (String, Double?) -> Void) async throws {
        try await prepareDictation(model: model, status: status)
        try await prepareMeetings(status: status)
        status("Ready", 1)
    }

    /// Step 1 — what dictation needs: Parakeet + the voice detector.
    /// The files are normally already on disk (ModelStore downloads them in parallel first),
    /// so FluidAudio only LOADS them here. If they're not, FluidAudio downloads them itself.
    func prepareDictation(model: SpeechModel = .current, prewarm warm: Bool = true,
                          status: @escaping @Sendable (String, Double?) -> Void) async throws {
        let t0 = Date()
        var changed = false
        if asr == nil || loadedModel != model {
            changed = true
            status("Loading \(model.title)…", nil)
            // 0.7.2: the voice detector loads at the same time as Parakeet (both from disk).
            let needVad = vad == nil
            async let vadLoad: VadManager? = needVad ? (try? await VadManager(config: VadConfig(defaultThreshold: 0.75))) : nil
            let tm = Date()
            // Tachys: explicit Core ML compute units (Neural Engine by default = FluidAudio's default).
            let models = try await AsrModels.downloadAndLoad(configuration: TachysEngine.modelConfiguration(),
                                                             version: model.version, progressHandler: { p in
                switch p.phase {
                case .listing: status("Finding speech model files…", p.fractionCompleted)
                case .downloading: status("Downloading speech model…", p.fractionCompleted)
                case .compiling: status("Optimizing speech model for this Mac…", nil)
                }
            })
            Perf.log.info("Parakeet Core ML load: \(Date().timeIntervalSince(tm) * 1000, format: .fixed(precision: 0))ms (compute: \(TachysEngine.computeLabel, privacy: .public))")
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            let second = AsrManager(config: .default)
            try await second.loadModels(models)
            asr = manager
            dictationAsr = second
            loadedModel = model
            if vad == nil, let v = await vadLoad { vad = v }
        }
        if vad == nil {
            status("Loading voice detector…", nil)
            // 0.75 = how sure Silero must be that a 256 ms slice is speech (FluidAudio's doc example).
            vad = try await VadManager(config: VadConfig(defaultThreshold: 0.75))
            changed = true
        }
        Perf.log.info("dictation models loaded in \(Date().timeIntervalSince(t0) * 1000, format: .fixed(precision: 0))ms")
        // Tachys: a dictation pressed while the models were loading starts NOW (its own pass warms
        // the model), instead of waiting behind the synthetic warm-up below.
        let fast = TachysEngine.enabled
        let someoneWaiting = fast && !dictationWaiters.isEmpty
        if fast { resumeDictationWaiters() }
        if warm && changed {
            status("Warming up…", nil)
            await prewarm(skipAsr: someoneWaiting)
        }
        resumeDictationWaiters()
        if changed && !tachysLaunchLogged {        // once per process: the launch, not a later model switch
        tachysLaunchLogged = true
        TachysEngine.record(launchReadyMs: Date().timeIntervalSince(TachysEngine.processStart) * 1000)
        Perf.log.info("Tachys launch→ready: \(Date().timeIntervalSince(TachysEngine.processStart) * 1000, format: .fixed(precision: 0))ms (process start → dictation models loaded\(warm && changed ? " + warmed" : "", privacy: .public))")
        }
    }

    // MARK: Waiting for the models (a dictation that started while they were loading)

    private var dictationWaiters: [CheckedContinuation<Void, Never>] = []

    private func resumeDictationWaiters() {
        guard dictationAsr != nil else { return }
        let w = dictationWaiters
        dictationWaiters = []
        for c in w { c.resume() }
    }

    /// Waits until the dictation model is loaded (true) or `timeout` seconds pass (false).
    func waitUntilDictationReady(timeout: Double) async -> Bool {
        if dictationAsr != nil { return true }
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await self?.timeoutDictationWaiters()
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in dictationWaiters.append(c) }
        timer.cancel()
        return dictationAsr != nil
    }

    private func timeoutDictationWaiters() {
        let w = dictationWaiters
        dictationWaiters = []
        for c in w { c.resume() }
    }

    /// Step 2 — what meetings add: the speaker (diarization) models. Loaded in the background
    /// after dictation is ready, or when the first meeting needs them.
    func prepareMeetings(status: @escaping @Sendable (String, Double?) -> Void) async throws {
        status("Loading speaker models…", nil)
        _ = try await diarizer(.auto)
    }

    // MARK: - Dictation

    // MARK: Live voice detection (runs WHILE you talk)
    //
    // v0.2 ran Silero VAD over the whole clip after you let go of the key. Now every
    // 256 ms slice of audio goes through the voice detector as it arrives, so when you
    // release the key only the last slice is left — the trim is basically done already.
    // The results are identical to the old one-pass VAD (same model, same order, same
    // state carried from slice to slice); only the timing changes.

    private var liveState = VadStreamState.initial()
    private var liveResults: [VadResult] = []
    private var livePending: [Float] = []
    private var liveActive = false
    private var liveDraining = false
    private var liveSession: UUID?
    /// All audio fed so far this session (to cut out finished sentences while you still talk).
    private var liveAudio: [Float] = []
    private var liveSegmentStart: Int?
    /// Sentences already transcribed WHILE the key was still held: (where it ended, its text).
    private var liveEarly: [(end: Int, task: Task<String, Error>)] = []
    /// Tachys: the speculative final pass (see TachysEngine.swift).
    private var tachys = TachysEngine()
    /// True while dictate() catches the VAD up after release (no new speculation then).
    private var tachysReleasing = false
    private var tachysLaunchLogged = false

    /// How the voice detector cuts speech while you hold the key.
    /// 0.5 ("I pause while thinking", default on): a split needs ≥ 1.3 s of silence (0.4 used
    /// 0.5 s, which split sentences at every thinking pause), 0.3 s of audio is kept on each side
    /// of every speech part, and no part is ever force-cut at 14 s (FluidAudio's default cut point
    /// can fall inside a word). The parts are only used to trim silence: on release the whole
    /// utterance is transcribed in ONE pass (see `dictate`).
    static func segmentation(pauseTolerant: Bool = DictationSettings.pauseWhileThinking) -> VadSegmentationConfig {
        var seg = VadSegmentationConfig.default
        seg.minSpeechDuration = 0.3
        seg.speechPadding = 0.3
        seg.minSilenceDuration = pauseTolerant ? 1.3 : 0.5
        seg.maxSpeechDuration = 120
        return seg
    }
    static var vadSegmentation: VadSegmentationConfig { segmentation() }
    /// Silence put between speech parts when they're glued back together (pauses → ~0.3 s).
    static let glueGapSamples = 16_000 * 3 / 10
    /// Up to this much speech (after trimming), release = one pass over everything, so the model
    /// sees the whole sentence across your pauses. Longer: sentences finished while you talked
    /// are reused and joined with `TextCleanup.joinChunks` (splits only happen in ≥ 1.3 s silences).
    static let singlePassMaxSpeechSeconds = 25.0
    /// Sentences are transcribed early (while you still talk) only once this much audio exists,
    /// because anything up to `singlePassMaxSpeechSeconds` is redone in one pass anyway.
    static let earlyTranscribeAfterSeconds = 20.0

    /// Clips shorter than this skip the voice detector entirely (nothing much to trim, and
    /// running it would only add time).
    static let skipVadBelowSeconds = 5.0

    /// Fixed per recording (so a Settings change mid-recording can't mix two configs).
    private var liveConfig = SpeechEngine.segmentation()

    /// false = don't transcribe finished sentences while you talk (a Whisper engine is chosen:
    /// it always does one pass after release, so early Parakeet work would be wasted).
    private var liveEarlyEnabled = true

    func liveVadStart(session: UUID? = nil, earlyParts: Bool = true) {
        liveEarlyEnabled = earlyParts
        liveConfig = Self.segmentation()
        liveState = VadStreamState.initial()
        liveResults = []
        livePending = []
        liveAudio = []
        liveSegmentStart = nil
        for e in liveEarly { e.task.cancel() }
        liveEarly = []
        liveSession = session
        liveActive = vad != nil
        tachys.reset(active: liveActive && earlyParts && TachysEngine.enabled)
    }

    func liveVadCancel() {
        liveActive = false
        livePending = []
        liveResults = []
        liveAudio = []
        liveSegmentStart = nil
        for e in liveEarly { e.task.cancel() }
        liveEarly = []
        liveSession = nil
        tachys.reset(active: false)
    }

    /// Feed microphone audio (16 kHz mono) as it's recorded.
    func liveVadFeed(_ samples: [Float]) async {
        guard liveActive else { return }
        livePending += samples
        liveAudio += samples
        guard !liveDraining else { return }        // another call is already working through the queue
        liveDraining = true
        defer { liveDraining = false }
        while liveActive, livePending.count >= VadManager.chunkSize, let vad {
            let chunk = Array(livePending.prefix(VadManager.chunkSize))
            livePending.removeFirst(VadManager.chunkSize)
            await vadStep(vad, chunk)
        }
    }

    private func vadStep(_ vad: VadManager, _ chunk: [Float], end: Int? = nil) async {
        guard let r = try? await vad.processStreamingChunk(chunk, state: liveState, config: liveConfig) else {
            liveActive = false          // fall back to the one-pass VAD for this clip
            return
        }
        liveState = r.state
        liveResults.append(VadResult(probability: r.probability, isVoiceActive: r.probability >= 0.5,
                                     processingTime: 0, outputState: r.state.modelState))
        if tachys.active {
            tachys.observe(sliceEnd: end ?? min(liveResults.count * VadManager.chunkSize, liveAudio.count), probability: r.probability)
            await tachysSpeculate()
        }
        // A sentence just ended (≥ 0.5 s of silence) while you're still holding the key:
        // transcribe it NOW, so at release only the last bit is left.
        if let ev = r.event {
            if ev.isStart {
                liveSegmentStart = ev.sampleIndex
            } else if ev.isEnd, let start = liveSegmentStart, let asr = dictationAsr {
                liveSegmentStart = nil
                // From where the previous early part ended (or the start), so nothing is skipped.
                _ = start
                let begin = liveEarly.last?.end ?? 0
                let end = min(ev.sampleIndex, liveAudio.count)
                if liveEarlyEnabled, end - begin >= 16_000 * 3 / 4, liveAudio.count >= Int(Self.earlyTranscribeAfterSeconds * 16_000) {
                    let audio = Array(liveAudio[begin..<end])
                    let task = Task { try await Self.transcribeShort(asr, audio) }
                    liveEarly.append((end: end, task: task))
                    Perf.log.info("early sentence: \(Double(end - begin) / 16_000, format: .fixed(precision: 1))s sent to ASR while still talking")
                }
            }
        }
    }

    // MARK: Tachys (speculative final pass, see TachysEngine.swift)

    /// The exact array the one-pass release path feeds Parakeet for `samples` (VAD trim from the
    /// live results, glue, pad to 1 s). Used for the speculative pass; dictate() builds the same.
    private func tachysInput(_ samples: [Float], results: [VadResult], config: VadSegmentationConfig) async -> [Float] {
        var segments: [VadSegment] = []
        if let vad, Double(samples.count) / 16_000 >= Self.skipVadBelowSeconds {
            let chunk = VadManager.chunkSize
            let n = (samples.count + chunk - 1) / chunk
            guard results.count >= n else { return [] }
            segments = await vad.segmentSpeech(from: Array(results.prefix(n)), totalSamples: samples.count, config: config)
        }
        var parts: [[Float]] = []
        for seg in segments {
            let a = max(0, min(seg.startSample(sampleRate: 16_000), samples.count))
            let b = max(a, min(seg.endSample(sampleRate: 16_000), samples.count))
            if b > a { parts.append(Array(samples[a..<b])) }
        }
        var speech = parts.isEmpty ? samples : Self.glue(parts)
        if speech.count < 16_000 { speech += [Float](repeating: 0, count: 16_000 - speech.count) }
        return speech
    }

    /// Called after every live VAD slice: once the end of speech has been quiet for the tail pad,
    /// transcribe what the release would transcribe, in the background.
    private func tachysSpeculate() async {
        guard tachys.active, !tachysReleasing, liveEarlyEnabled, let asr = dictationAsr,
              let c = tachys.cut(available: liveAudio.count), c <= TachysEngine.maxSpeculativeSamples,
              tachys.speculation?.cut != c else { return }
        let mySession = liveSession
        let audio = Array(liveAudio[..<c])
        let input = await tachysInput(audio, results: liveResults, config: liveConfig)
        // The recording may have been cancelled/restarted (or sped past) while we awaited.
        guard tachys.active, liveSession == mySession, !input.isEmpty, tachys.speculation?.cut != c else { return }
        let task = Task { () throws -> ASRResult in
            var st = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
            return try await asr.transcribe(input, decoderState: &st)
        }
        tachys.speculation = TachysEngine.Speculation(cut: c, input: input, task: task, startedAt: Date())
        tachys.speculationsStarted += 1
        Perf.log.info("Tachys: speculative pass #\(self.tachys.speculationsStarted) on \(Double(c) / 16_000, format: .fixed(precision: 2))s while the key is held")
    }

    /// The user had already stopped talking when they let go (so the 150 ms tail wait is useless).
    func tachysQuietNow() -> Bool { liveActive && tachys.active && tachys.quietAtEnd }

    /// Self-test: wait for the running speculative pass (simulates the user still holding the key).
    func tachysWaitForSpeculation() async -> Bool {
        guard let spec = tachys.speculation else { return false }
        _ = try? await spec.task.value
        return true
    }

    /// Why a 2 s clip costs about as much as a 15 s one: FluidAudio 0.18.3 pads every Parakeet
    /// call up to its fixed 15 s encoder window (AsrManager+Transcription: padAudioIfNeeded to
    /// ASRConstants.maxModelSamples). Parakeet v2's Encoder.mlmodelc has ONE shape, so there is
    /// no shorter window to pick. FluidAudio does run shorter windows ("encoder ladder":
    /// enc_5040ms / enc_10160ms / enc_15000ms) but only for models that ship a multifunction
    /// encoder — today that's Phonon-2 (English re-train of v3, ~360 MB, macOS 15+, ~3 min first
    /// ANE compile). The streaming variants (Parakeet EOU 120M, Unified 0.6B 320–2080 ms) are
    /// separate models too. Switching = a model change, not a code tweak; not done in 0.3.
    private static func transcribeShort(_ asr: AsrManager, _ audio: [Float]) async throws -> String {
        var a = audio
        if a.count < 16_000 { a += [Float](repeating: 0, count: 16_000 - a.count) }
        var st = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        return try await asr.transcribe(a, decoderState: &st).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Hold-to-talk audio -> text. Steps: VAD trim (mostly done live) -> Parakeet (one pass) ->
    /// vocabulary helper.
    /// `live`: the clip's audio was also fed to liveVadFeed while recording.
    /// `external`: another engine (Whisper) does step 2 on the trimmed speech instead of Parakeet;
    /// then everything is always ONE pass (no early sentences) and the vocabulary helper is skipped.
    func dictate(samples rawSamples: [Float], live requestedLive: Bool = false, session: UUID? = nil,
                 asrOverride: AsrManager? = nil,
                 external: (@Sendable ([Float]) async throws -> String)? = nil) async throws -> DictationTranscript {
        var samples = rawSamples        // Tachys may end it 0.4 s after the last voice (below)
        let resolvedAsr = asrOverride ?? dictationAsr
        guard external != nil || resolvedAsr != nil else { throw EngineError.notReady }
        // Live state from a different recording must never be used for this one.
        let live = requestedLive && (session == nil || session == liveSession)
        let audioSeconds = Double(samples.count) / 16_000
        let signpost = Perf.signposter.beginInterval("dictate")
        defer { Perf.signposter.endInterval("dictate", signpost) }
        let config = live ? liveConfig : Self.segmentation()

        // 1) Find the speech with Silero VAD (like Handy does). Less audio = faster, and the
        //    model can't "hear" words in background hiss. Pauses are squeezed to ~0.3 s.
        let t0 = Date()
        while liveDraining { try? await Task.sleep(nanoseconds: 2_000_000) }   // let the queue finish
        // Tachys: catch the live VAD up on every slice (short clips too), then end the input 0.4 s
        // after the last voice, exactly as the speculative pass did (TachysEngine.swift).
        let useTachys = external == nil && live && liveActive && tachys.active
        var tachysMode = "off"
        if useTachys, let vad {
            tachysReleasing = true
            let chunk = VadManager.chunkSize
            var offset = liveResults.count * chunk
            while offset < samples.count {
                let end = min(samples.count, offset + chunk)
                await vadStep(vad, Array(samples[offset..<end]), end: end)
                offset += chunk
            }
            tachysReleasing = false
            if let c = tachys.cut(available: samples.count), c < samples.count {
                samples = Array(samples[..<c])
                tachysMode = "miss"
            } else {
                tachysMode = "full"
            }
        }
        var speech = samples
        var vadMode = "skipped (short clip)"
        var segments: [VadSegment] = []
        if let vad, Double(samples.count) / 16_000 >= Self.skipVadBelowSeconds {
            let chunk = VadManager.chunkSize
            let n = (samples.count + chunk - 1) / chunk
            if live, liveActive, liveResults.count * chunk <= samples.count || (useTachys && liveResults.count >= n) {
                // Only the slices recorded after the last live step are left.
                var offset = liveResults.count * chunk
                while offset < samples.count {
                    await vadStep(vad, Array(samples[offset..<min(samples.count, offset + chunk)]))
                    offset += chunk
                }
                segments = await vad.segmentSpeech(from: Array(liveResults.prefix(n)), totalSamples: samples.count, config: config)
                vadMode = "single pass (live VAD)"
            } else {
                segments = try await vad.segmentSpeech(samples, config: config)
                vadMode = "single pass"
            }
        }
        var parts: [(start: Int, audio: [Float])] = []
        for seg in segments {
            let a = max(0, min(seg.startSample(sampleRate: 16_000), samples.count))
            let b = max(a, min(seg.endSample(sampleRate: 16_000), samples.count))
            if b > a { parts.append((start: a, audio: Array(samples[a..<b]))) }
        }
        let speechSamples = parts.reduce(0) { $0 + $1.audio.count }

        // Long dictation (> 25 s of speech) with sentences already transcribed while talking:
        // reuse them, transcribe only the tail, and join without fake sentence breaks.
        if external == nil, let dictationAsr = resolvedAsr,
           live, liveActive, !liveEarly.isEmpty, (liveEarly.last?.end ?? 0) < samples.count,
           Double(speechSamples) / 16_000 > Self.singlePassMaxSpeechSeconds {
            let early = liveEarly
            liveEarly = []
            let tailStart = early.last!.end
            let tail = Array(samples[tailStart...])
            let t1 = Date()
            var tailText = ""
            let tailParts = parts.filter { $0.start + $0.audio.count > tailStart }.map { p -> [Float] in
                p.start >= tailStart ? p.audio : Array(p.audio[(tailStart - p.start)...])
            }.filter { !$0.isEmpty }
            if !tailParts.isEmpty {
                tailText = try await Self.transcribeShort(dictationAsr, Self.glue(tailParts))
            } else if tail.count > 16_000 / 2 {
                tailText = try await Self.transcribeShort(dictationAsr, tail)
            }
            var texts: [String] = []
            for e in early { texts.append(try await e.task.value) }
            texts.append(tailText)
            liveVadCancel()
            let text = TextCleanup.joinChunks(texts)
            let asrSeconds = Date().timeIntervalSince(t1)
            Perf.log.info("dictate (incremental): \(early.count) early parts, tail \(Double(tail.count) / 16_000, format: .fixed(precision: 1))s, after release \(asrSeconds * 1000, format: .fixed(precision: 0))ms")
            return DictationTranscript(text: text, audioSeconds: audioSeconds, speechSeconds: Double(speechSamples) / 16_000,
                                       vadSeconds: 0, asrSeconds: asrSeconds,
                                       vadMode: "incremental (\(early.count) early + tail, joined)")
        }
        // Normal case: ONE pass over the whole utterance, so the model has the context on both
        // sides of every pause (0.4 stitched separately transcribed pieces → stray capitals).
        if !parts.isEmpty { speech = Self.glue(parts.map { $0.audio }) }
        // No speech found at all? Keep the raw audio rather than risk dropping a quiet voice.
        let speculation = useTachys ? tachys.speculation : nil
        liveVadCancel()
        let vadSeconds = Date().timeIntervalSince(t0)

        // Parakeet needs a little audio to work with: pad very short clips to 1 s.
        if speech.count < 16_000 { speech += [Float](repeating: 0, count: 16_000 - speech.count) }

        // 2b) Another engine (Whisper): one pass over the trimmed speech, nothing else.
        if let external {
            let t1 = Date()
            let text = try await external(speech).trimmingCharacters(in: .whitespacesAndNewlines)
            let asrSeconds = Date().timeIntervalSince(t1)
            return DictationTranscript(text: text, audioSeconds: audioSeconds,
                                       speechSeconds: Double(speech.count) / 16_000,
                                       vadSeconds: vadSeconds, asrSeconds: asrSeconds, vadMode: vadMode)
        }
        guard let dictationAsr = resolvedAsr else { throw EngineError.notReady }

        // 2) Speech -> text.
        let t1 = Date()
        // Tachys: the same input was already transcribed while the key was held → reuse it.
        var reused: ASRResult? = nil
        if let spec = speculation, spec.cut == samples.count, spec.input == speech {
            reused = try? await spec.task.value
            if reused != nil { tachysMode = "hit" }
        }
        let result: ASRResult
        if let reused {
            result = reused
        } else {
            var state = TdtDecoderState.make(decoderLayers: await dictationAsr.decoderLayerCount)
            result = try await dictationAsr.transcribe(speech, decoderState: &state)
        }
        var text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let asrSeconds = Date().timeIntervalSince(t1)

        // 3) Vocabulary helper: check the user's terms against the audio (optional, ~100 MB model).
        var boostSeconds = 0.0
        var replaced: [String] = []
        if let boost = vocabularyBoost, Vocabulary.acousticBoost, let timings = result.tokenTimings, !timings.isEmpty {
            let t2 = Date()
            if let out = await boost.rescore(text: result.text, tokenTimings: timings, audioSamples: speech), out.wasModified {
                // Keep only swaps that can't turn an everyday word into a term ("cute" → "CAD").
                let swaps = out.replacements.filter(\.shouldReplace).map { (from: $0.originalWord, to: $0.replacementWord ?? "") }
                let guarded = Vocabulary.guardAcoustic(original: text,
                                                       rescored: out.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                                       replacements: swaps)
                text = guarded.text
                replaced = guarded.accepted.map { "\($0.from) → \($0.to)" }
                    + guarded.rejected.map { "refused: \($0.from) → \($0.to)" }
            }
            boostSeconds = Date().timeIntervalSince(t2)
        }
        Perf.log.info("dictate: audio \(audioSeconds, format: .fixed(precision: 2))s, VAD \(vadMode, privacy: .public) \(vadSeconds * 1000, format: .fixed(precision: 0))ms, ASR \(asrSeconds * 1000, format: .fixed(precision: 0))ms (Tachys \(tachysMode, privacy: .public)), vocab \(boostSeconds * 1000, format: .fixed(precision: 0))ms")
        return DictationTranscript(text: text, audioSeconds: audioSeconds,
                                   speechSeconds: Double(speech.count) / 16_000,
                                   vadSeconds: vadSeconds, asrSeconds: asrSeconds, vadMode: vadMode,
                                   boostSeconds: boostSeconds, boostReplacements: replaced, tachys: tachysMode)
    }

    /// The voice benchmark's "one full-utterance pass": the whole clip, no voice detector, no
    /// early parts, straight into the loaded dictation Parakeet model.
    func transcribeFull(_ samples: [Float]) async throws -> String {
        guard let dictationAsr else { throw EngineError.notReady }
        return try await Self.transcribeShort(dictationAsr, samples)
    }

    /// Speech parts back to back with ~0.3 s of silence between them.
    static func glue(_ parts: [[Float]]) -> [Float] {
        guard let first = parts.first else { return [] }
        let gap = [Float](repeating: 0, count: glueGapSamples)
        return parts.dropFirst().reduce(first) { $0 + gap + $1 }
    }

    // MARK: Vocabulary helper (FluidAudio CTC keyword boosting)

    private var vocabularyBoost: VocabularyBoostingSession?
    private var vocabularyBoostTerms: [VocabularyTerm] = []
    private var ctcModels: CtcModels?
    var isVocabularyBoostReady: Bool { vocabularyBoost != nil }

    /// Load the 100 MB CTC helper (already downloaded by ModelStore) and build a boosting
    /// session for `terms`. Thresholds follow FluidAudio's advice for dictation (#967): a term
    /// must beat the transcribed words on the audio alone (cbw 0) and be ≥ 70 % similar in
    /// spelling, so correctly heard words are rarely replaced.
    func loadVocabularyBoost(terms: [VocabularyTerm]) async throws {
        if vocabularyBoost != nil, terms == vocabularyBoostTerms { return }
        // Short acronyms ("CAD", "VEX", "V5") never go to the helper: on sound alone they matched
        // everyday words ("cute", "head", "practise" → "CAD"). The text pass still spells them.
        let helperTerms = Vocabulary.acousticTerms(terms)
        guard !helperTerms.isEmpty else { vocabularyBoost = nil; vocabularyBoostTerms = []; return }
        if ctcModels == nil { ctcModels = try await CtcModels.downloadAndLoad(variant: .ctc110m) }
        guard let ctcModels else { return }
        let context = CustomVocabularyContext(terms: helperTerms.map {
            CustomVocabularyTerm(text: $0.text, weight: nil, aliases: $0.aliases.isEmpty ? nil : $0.aliases)
        })
        vocabularyBoost = try await VocabularyBoostingSession(
            vocabulary: context, ctcModels: ctcModels,
            thresholds: .init(cbw: 0, minSimilarity: 0.7))
        vocabularyBoostTerms = terms
        Perf.log.info("vocabulary helper ready: \(helperTerms.count) terms")
        await prewarmVocabulary()
    }

    func unloadVocabularyBoost() { vocabularyBoost = nil; vocabularyBoostTerms = [] }

    /// A separate Parakeet manager for another model (self-test model comparison).
    static func loadManager(_ model: SpeechModel) async throws -> AsrManager {
        let models = try await AsrModels.downloadAndLoad(version: model.version)
        let m = AsrManager(config: .default)
        try await m.loadModels(models)
        return m
    }

    /// Run each dictation model once on silence so Core ML finishes its one-time setup
    /// ("specialization" for this Mac's Neural Engine) at launch, not on your first dictation.
    func prewarm(skipAsr: Bool = false) async {
        let t0 = Date()
        if let vad { _ = try? await vad.process([Float](repeating: 0, count: VadManager.chunkSize * 2)) }
        if !skipAsr, let dictationAsr {
            // Real speech (the bundled 16 s test clip's first 3 s) if we have it, so the decoder
            // path is warmed too, not only the encoder on silence.
            var st = TdtDecoderState.make(decoderLayers: await dictationAsr.decoderLayerCount)
            _ = try? await dictationAsr.transcribe(Self.warmupAudio(), decoderState: &st)
        }
        Perf.log.info("prewarm (dictation): \(Date().timeIntervalSince(t0) * 1000, format: .fixed(precision: 0))ms")
    }

    /// The meeting copy of Parakeet, warmed in the background once dictation is ready (0.7.2:
    /// this used to happen before dictation was allowed to start).
    func prewarmMeetings() async {
        guard let asr, !meetingsWarmed else { return }
        meetingsWarmed = true
        let t0 = Date()
        var st = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        _ = try? await asr.transcribe([Float](repeating: 0, count: 16_000), decoderState: &st)
        Perf.log.info("prewarm (meetings): \(Date().timeIntervalSince(t0) * 1000, format: .fixed(precision: 0))ms")
    }
    private var meetingsWarmed = false

    /// 3 s of real speech for warming up (falls back to 1 s of silence).
    static func warmupAudio() -> [Float] {
        if let url = Bundle.main.url(forResource: "dictation_sample", withExtension: "wav"),
           let clip = try? loadSamples(url) {
            let onset = clip.firstIndex { abs($0) > 0.02 }.map { max(0, $0 - 1600) } ?? 0
            let a = Array(clip[onset..<min(clip.count, onset + 48_000)])
            if a.count >= 16_000 { return a }
        }
        return [Float](repeating: 0, count: 16_000)
    }

    /// Run the vocabulary helper once on the warm-up clip so its Core ML setup happens in the
    /// background, not inside your first dictation.
    func prewarmVocabulary() async {
        guard let boost = vocabularyBoost, let dictationAsr else { return }
        let t0 = Date()
        let audio = Self.warmupAudio()
        var st = TdtDecoderState.make(decoderLayers: await dictationAsr.decoderLayerCount)
        if let r = try? await dictationAsr.transcribe(audio, decoderState: &st), let timings = r.tokenTimings, !timings.isEmpty {
            _ = await boost.rescore(text: r.text, tokenTimings: timings, audioSamples: audio)
        }
        Perf.log.info("prewarm (vocabulary helper): \(Date().timeIntervalSince(t0) * 1000, format: .fixed(precision: 0))ms")
    }

    private func diarizer(_ setting: DiarizerSetting) async throws -> OfflineDiarizerManager {
        if let d = diarizers[setting] { return d }
        let d = OfflineDiarizerManager(config: setting.config)
        try await d.prepareModels()      // loads from the on-disk cache after the first time
        diarizers[setting] = d
        return d
    }

    /// Where the speech is (Silero VAD), as sample ranges. Used by voice enrollment's quality check.
    func speechRanges(_ samples: [Float]) async throws -> [Range<Int>] {
        if vad == nil { vad = try await VadManager(config: VadConfig(defaultThreshold: 0.75)) }
        guard let vad else { return [] }
        var cfg = VadSegmentationConfig.default
        cfg.minSpeechDuration = 0.2
        cfg.minSilenceDuration = 0.3
        cfg.maxSpeechDuration = 600
        cfg.speechPadding = 0.05
        cfg.negativeThreshold = 0.35        // enter speech at 0.5, leave below 0.35
        cfg.negativeThresholdOffset = 0.15
        let segs = try await vad.segmentSpeech(samples, config: cfg)
        return segs.compactMap { seg -> Range<Int>? in
            let a = max(0, min(seg.startSample(sampleRate: 16_000), samples.count))
            let b = max(a, min(seg.endSample(sampleRate: 16_000), samples.count))
            return b > a ? a..<b : nil
        }
    }

    /// Voice embeddings for arbitrary time spans (self-test: re-scoring turns against the library).
    func embedSpans(samples: [Float], spans: [Range<Double>]) async throws -> [[Float]] {
        guard !spans.isEmpty else { return [] }
        let d = try await diarizer(.auto)
        return try await d.embedSpans(audioSource: ArrayAudioSampleSource(samples: samples), spans: spans)
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
    func prepareDiarization(samples: [Float],
                            progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> PreparedDiarization {
        guard samples.count > 16_000 * 2 else { throw EngineError.tooShort }
        let d = try await diarizer(.auto)
        return try await d.prepare(audio: samples, progressCallback: progress)
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
    func diarize(samples: [Float], setting: DiarizerSetting = .auto,
                 progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> Diarized {
        let t0 = Date()
        let prepared = try await prepareDiarization(samples: samples, progress: progress)
        var out = try await cluster(prepared, samples: samples, setting: setting)
        out.seconds = Date().timeIntervalSince(t0)
        return out
    }

    private func transcribeTracked(samples: [Float], tracker: MeetingProgress) async throws -> (words: [Word], seconds: Double) {
        let r = try await transcribe(samples: samples)
        await tracker.transcribed()
        return r
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
    /// Speaker detection, then transcription, in the background with a live status line
    /// ("Finding speakers 40% · transcribing…"). (Running both at once was tried in 0.3 and was
    /// SLOWER on the CI Mac — 116 s vs 87 s for a 5-minute meeting — so they run one after the other.)
    func process(samples: [Float], setting: DiarizerSetting = .auto,
                 progress: (@Sendable (String) -> Void)? = nil) async throws -> Output {
        guard asr != nil else { throw EngineError.notReady }
        let signpost = Perf.signposter.beginInterval("meeting")
        defer { Perf.signposter.endInterval("meeting", signpost) }
        let t0 = Date()
        let tracker = MeetingProgress(report: progress)
        let d = try await diarize(samples: samples, setting: setting) { done, total in
            Task { await tracker.speakers(done, total) }
        }
        let t = try await transcribeTracked(samples: samples, tracker: tracker)
        Perf.log.info("meeting \(Double(samples.count) / 16_000, format: .fixed(precision: 0))s: speakers \(d.seconds, format: .fixed(precision: 1))s, transcript \(t.seconds, format: .fixed(precision: 1))s, wall \(Date().timeIntervalSince(t0), format: .fixed(precision: 1))s")
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
