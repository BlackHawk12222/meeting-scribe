// Recorder.swift
// Records a meeting to a 16 kHz mono WAV file: the Mac's microphone, and (0.7.5) the sound the
// Mac plays (SystemAudioTap: the other people on a call), mixed when you stop.
//
// Noise cleanup: Apple's "voice processing" (the audio unit FaceTime uses) removes steady
// background noise and echo. 0.7.5: OFF by default — voice processing also takes over the output
// side (lowers and processes other apps' sound, and puts AirPods in call mode), which made music
// and videos sound distorted during meetings. Ducking is set to the minimum when it's on. Its echo cancellation also removes what the speakers play, which is
// why the call itself is recorded separately from the Mac's sound now.
//
// 0.7.5 "the audio isn't working" hardening:
//  • Each source has a SourceMonitor. A mic that delivers no buffers for 3 s, or pure digital
//    silence for 10 s, is not a quiet room: macOS has blocked the mic (a permission reset), the
//    input is muted, or voice processing broke. With noise cleanup on, Scribe first restarts the
//    mic WITHOUT voice processing (keeps recording into the same file); if it's still silent the
//    meeting view says so, with a button to the right Settings page.
//  • The input device changing mid-meeting (AirPods, USB mic) restarts the mic on the new device
//    instead of silently ending the recording; the gap is filled with silence so the Mac's sound
//    stays in sync.
//  • Mac sound silent for 10 s while macOS says "System Audio Recording" isn't allowed → a notice.
//  • Everything is logged to ~/Library/Logs/Scribe/scribe.log (no audio).

import AVFoundation
import Combine

@MainActor
final class Recorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0          // 0...1 for the meter
    @Published private(set) var noiseCleanupActive = false
    /// 0.7.5: the Mac's sound (calls) is being recorded too.
    @Published private(set) var systemAudioActive = false
    /// 0.7.5: what's wrong with a source right now (nil = fine). Shown on the live meeting view.
    @Published private(set) var problem: AudioProblem?

    enum AudioProblem: Equatable {
        case micSilent, micNoAudio, micDenied, systemSilent, systemFailed(String)

        var title: String {
            switch self {
            case .micSilent: return "Scribe isn't hearing the microphone"
            case .micNoAudio: return "The microphone stopped sending audio"
            case .micDenied: return "Scribe can't use the microphone"
            case .systemSilent: return "Scribe can't hear the Mac's sound"
            case .systemFailed: return "Scribe couldn't record the Mac's sound"
            }
        }
        var detail: String {
            switch self {
            case .micSilent: return "It has recorded pure silence for over 10 seconds. Check that Scribe is allowed in Microphone settings and that the input isn't muted."
            case .micNoAudio: return "Check the input device in Sound settings, or stop and start the meeting again."
            case .micDenied: return "Turn on Scribe in System Settings › Privacy & Security › Microphone."
            case .systemSilent: return "If a call is playing, allow Scribe under System Audio Recording Only in Settings. Until then only your microphone is recorded."
            case .systemFailed(let why): return "Only the microphone is being recorded (\(why))."
            }
        }
        var pane: Permissions.Pane? {
            switch self {
            case .micSilent, .micDenied: return .microphone
            case .systemSilent, .systemFailed: return .systemAudio
            case .micNoAudio: return nil
            }
        }
    }

    private var engine: AVAudioEngine?
    private var micConverter: To16kMono?
    private var systemConverter: To16kMono?
    private var systemTap: AnyObject?                    // SystemAudioTap on macOS 14.4+
    private var file: AVAudioFile?
    private var systemFile: AVAudioFile?
    private var systemURL: URL?
    private var startDate: Date?
    private var timer: Timer?
    private var configObserver: NSObjectProtocol?
    private var wantsNoiseCleanup = false
    private var vpFallbackDone = false
    private(set) var currentURL: URL?
    let micMonitor = SourceMonitor(name: "mic")
    let systemMonitor = SourceMonitor(name: "system")
    /// Written on audio threads, read when mixing.
    private let clock = RecordingClock()

    /// Ask macOS for microphone permission (shows the system prompt the first time).
    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// Settings › Meetings › "Also record the Mac's sound" (default on).
    static var recordSystemAudio: Bool { UserDefaults.standard.object(forKey: "meetingSystemAudio") as? Bool ?? true }

    func start(to url: URL, noiseCleanup: Bool) throws {
        problem = nil
        wantsNoiseCleanup = noiseCleanup
        vpFallbackDone = false
        micMonitor.reset(); systemMonitor.reset(); clock.reset()
        let file = try AVAudioFile(forWriting: url, settings: MeetingMixer.wavSettings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        self.file = file
        self.currentURL = url
        AppLog.log("meeting start: mic=\(Permissions.micName(AVCaptureDevice.authorizationStatus(for: .audio))) noiseCleanup=\(noiseCleanup) systemAudio=\(Self.recordSystemAudio) (\(Permissions.systemAudioStatus().rawValue))")
        do {
            try startMic(voiceProcessing: noiseCleanup)
        } catch {
            AppLog.log("meeting mic start failed: \(error.localizedDescription)")
            if noiseCleanup {
                // Voice processing can't run on some devices: record without it.
                try startMic(voiceProcessing: false)
                vpFallbackDone = true
            } else {
                self.file = nil
                throw error
            }
        }
        if Self.recordSystemAudio { startSystemAudio(next: url) }

        startDate = Date()
        elapsed = 0
        isRecording = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let start = self.startDate else { return }
                self.elapsed = Date().timeIntervalSince(start)
                self.watchdog()
            }
        }
    }

    // MARK: Microphone

    private func startMic(voiceProcessing: Bool) throws {
        stopMicEngine()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        noiseCleanupActive = false
        // 0.7.5: the chosen mic (Automatic = built-in when the default input is a Bluetooth headset,
        // so AirPods keep their music-quality mode). Voice processing uses the system devices.
        let dev = MicDevices.current()
        if !voiceProcessing, let dev {
            do { try input.auAudioUnit.setDeviceID(dev.id) } catch { AppLog.log("meeting: couldn't select \(dev.name): \(error.localizedDescription)") }
        }
        if voiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(true)
                // Don't make other apps' sound quieter while we record.
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
                noiseCleanupActive = true
            } catch {
                AppLog.log("voice processing unavailable: \(error.localizedDescription)")
            }
        }
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw RecorderError.noMicrophone }
        guard let conv = To16kMono(inFormat: inFormat, mix: .firstChannel) else { throw RecorderError.formatProblem }
        micConverter = conv
        let file = self.file
        let monitor = micMonitor
        let clock = self.clock
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            guard let (mono, peak) = conv.mono(buffer) else { return }
            monitor.feed(peak: peak, duration: Double(buffer.frameLength) / inFormat.sampleRate)
            if let out = conv.convert(mono), let file {
                // After a restart, fill the gap with silence so the Mac's sound stays in sync.
                let gap = clock.micGap(adding: Int64(out.frameLength))
                if gap > 0, let pad = AVAudioPCMBuffer(pcmFormat: To16kMono.out16k, frameCapacity: AVAudioFrameCount(gap)) {
                    pad.frameLength = AVAudioFrameCount(gap)
                    for i in 0..<Int(gap) { pad.floatChannelData![0][i] = 0 }
                    try? file.write(from: pad)
                }
                try? file.write(from: out)
            }
            let meter = To16kMono.level(peakOrRMS: Self.rms(mono))
            DispatchQueue.main.async { self?.level = meter }
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.inputChanged() }
        }
        AppLog.log("meeting mic running: \(voiceProcessing ? "system default" : dev?.name ?? "system default"), \(Int(inFormat.sampleRate)) Hz × \(inFormat.channelCount) ch, voiceProcessing=\(noiseCleanupActive)")
    }

    private func stopMicEngine() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if noiseCleanupActive { try? engine.inputNode.setVoiceProcessingEnabled(false) }
        self.engine = nil
    }

    /// The input device or its format changed (AirPods connected, USB mic…): restart on the new one.
    private func inputChanged() {
        guard isRecording else { return }
        AppLog.log("meeting: input device changed, restarting the mic")
        do { try startMic(voiceProcessing: wantsNoiseCleanup && !vpFallbackDone) } catch {
            AppLog.log("meeting: mic restart failed: \(error.localizedDescription)")
            problem = .micNoAudio
        }
    }

    nonisolated static func rms(_ b: AVAudioPCMBuffer) -> Float {
        guard let p = b.floatChannelData?[0], b.frameLength > 0 else { return 0 }
        var s: Float = 0
        for i in 0..<Int(b.frameLength) { s += p[i] * p[i] }
        return sqrt(s / Float(b.frameLength))
    }

    // MARK: The Mac's sound

    private func startSystemAudio(next url: URL) {
        systemAudioActive = false
        guard #available(macOS 14.4, *) else {
            AppLog.log("meeting: system audio needs macOS 14.4+; mic only")
            return
        }
        let sURL = url.deletingPathExtension().appendingPathExtension("system.wav")
        do {
            let sFile = try AVAudioFile(forWriting: sURL, settings: MeetingMixer.wavSettings,
                                        commonFormat: .pcmFormatFloat32, interleaved: false)
            let tap = SystemAudioTap()
            let monitor = systemMonitor
            let clock = self.clock
            var conv: To16kMono?
            try tap.start { buffer in
                if conv == nil { conv = To16kMono(inFormat: buffer.format, mix: .average) }
                guard let conv, let (mono, peak) = conv.mono(buffer) else { return }
                monitor.feed(peak: peak, duration: Double(buffer.frameLength) / buffer.format.sampleRate)
                clock.markSystemStart(now: Date().addingTimeInterval(-Double(buffer.frameLength) / buffer.format.sampleRate))
                if let out = conv.convert(mono) { try? sFile.write(from: out) }
            }
            systemTap = tap
            systemFile = sFile
            systemURL = sURL
            systemAudioActive = true
            AppLog.log("meeting: system audio tap running (\(tap.format.map { "\(Int($0.sampleRate)) Hz × \($0.channelCount) ch" } ?? "?"))")
        } catch {
            AppLog.log("meeting: system audio failed: \(error.localizedDescription)")
            problem = .systemFailed(error.localizedDescription)
            try? FileManager.default.removeItem(at: sURL)
        }
    }

    private func stopSystemAudio() {
        if #available(macOS 14.4, *), let tap = systemTap as? SystemAudioTap { tap.stop() }
        systemTap = nil
        systemFile = nil                 // closes the WAV
        systemAudioActive = false
    }

    // MARK: Watchdog (every 0.25 s while recording)

    private func watchdog() {
        guard isRecording else { return }
        let mic = micMonitor.snapshot()
        let micBad = mic.sinceLastBuffer > 3 || mic.silentRun > 10
        if micBad {
            if noiseCleanupActive && !vpFallbackDone {
                vpFallbackDone = true
                AppLog.log("meeting: mic \(mic.buffers == 0 ? "sent no audio" : "silent \(Int(mic.silentRun)) s") with voice processing; restarting without it")
                micMonitor.reset()
                do { try startMic(voiceProcessing: false) } catch {
                    AppLog.log("meeting: restart without voice processing failed: \(error.localizedDescription)")
                }
                return
            }
            let p: AudioProblem = AVCaptureDevice.authorizationStatus(for: .audio) != .authorized ? .micDenied
                : (mic.sinceLastBuffer > 3 ? .micNoAudio : .micSilent)
            if problem != p {
                problem = p
                AppLog.log("meeting: \(p) (buffers=\(mic.buffers), silentRun=\(Int(mic.silentRun)) s, sinceLast=\(String(format: "%.1f", mic.sinceLastBuffer)) s, mic=\(Permissions.micName(AVCaptureDevice.authorizationStatus(for: .audio))))")
            }
            return
        }
        if problem == .micSilent || problem == .micNoAudio || problem == .micDenied {
            problem = nil
            AppLog.log("meeting: mic audio back")
        }
        if systemAudioActive {
            let sys = systemMonitor.snapshot()
            let status = Permissions.systemAudioStatus()
            // Silence from the Mac is normal when nothing plays; only flag it when macOS doesn't
            // say the permission is granted (or the tap sends nothing at all).
            if (sys.silentRun > 10 && status != .authorized) || sys.sinceLastBuffer > 5 {
                if problem == nil {
                    problem = .systemSilent
                    AppLog.log("meeting: system audio silent (buffers=\(sys.buffers), silentRun=\(Int(sys.silentRun)) s, permission=\(status.rawValue))")
                }
            } else if problem == .systemSilent, sys.silentRun == 0 {
                problem = nil
                AppLog.log("meeting: system audio back")
            }
        }
    }

    // MARK: Stop

    /// Stop now (the UI updates at once), then mix the Mac's sound into the meeting file off the
    /// main thread. Returns the file + its length in seconds.
    func finish() async -> (URL, TimeInterval)? {
        guard isRecording, let url = currentURL else { return nil }
        stopMicEngine()
        stopSystemAudio()
        timer?.invalidate()
        let duration = elapsed
        file = nil                       // closing the AVAudioFile finishes the WAV header
        isRecording = false
        level = 0
        problem = nil
        let mic = micMonitor.snapshot(), sys = systemMonitor.snapshot()
        AppLog.log("meeting stop: \(Int(duration)) s; mic \(String(format: "%.0f", mic.seconds)) s peak \(String(format: "%.4f", mic.loudest)); system \(String(format: "%.0f", sys.seconds)) s peak \(String(format: "%.4f", sys.loudest))")
        guard let sURL = systemURL else { return (url, duration) }
        systemURL = nil
        let offset = clock.systemOffset
        let hasSound = sys.loudest >= SourceMonitor.silenceFloor
        await Task.detached(priority: .userInitiated) {
            defer { try? FileManager.default.removeItem(at: sURL) }
            guard hasSound else { return }
            let tmp = url.deletingPathExtension().appendingPathExtension("mixed.wav")
            do {
                let r = try MeetingMixer.mix(mic: url, system: sURL, systemOffset: offset, out: tmp)
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
                AppLog.log("meeting: mixed mic + Mac sound (\(r.frames / 16_000) s, offset \(String(format: "%.2f", offset)) s)")
            } catch {
                try? FileManager.default.removeItem(at: tmp)
                AppLog.log("meeting: mixing failed, keeping the mic recording: \(error.localizedDescription)")
            }
        }.value
        return (url, duration)
    }

    enum RecorderError: LocalizedError {
        case noMicrophone, formatProblem
        var errorDescription: String? {
            switch self {
            case .noMicrophone: return "No microphone input found."
            case .formatProblem: return "Couldn't set up the audio format."
            }
        }
    }
}

/// Keeps the mic file and the Mac-sound file in step (audio threads).
final class RecordingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var micStart: Date?
    private var micFrames: Int64 = 0
    private var systemStart: Date?

    func reset() { lock.lock(); micStart = nil; micFrames = 0; systemStart = nil; lock.unlock() }

    /// Called with each mic chunk about to be written; returns how many silent frames to write
    /// first (only after a restart left a gap of more than 0.5 s; smaller differences are clock jitter).
    func micGap(adding frames: Int64, now: Date = Date()) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        // The chunk that just arrived started `frames` earlier: the file's frame 0 is at that time.
        guard let start = micStart else { micStart = now.addingTimeInterval(-Double(frames) / 16_000); micFrames = frames; return 0 }
        let expected = Int64(now.timeIntervalSince(start) * 16_000) - frames
        let gap = expected - micFrames
        let pad = gap > 8_000 ? gap : 0
        micFrames += pad + frames
        return pad
    }

    func markSystemStart(now: Date = Date()) {
        lock.lock(); if systemStart == nil { systemStart = now }; lock.unlock()
    }

    /// Seconds from the mic file's first frame to the Mac-sound file's first frame.
    var systemOffset: Double {
        lock.lock(); defer { lock.unlock() }
        guard let m = micStart, let s = systemStart else { return 0 }
        return s.timeIntervalSince(m)
    }
}
