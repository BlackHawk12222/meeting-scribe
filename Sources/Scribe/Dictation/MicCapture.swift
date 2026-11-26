// MicCapture.swift
// Records the microphone into memory (not a file) for dictation.
// Same idea as Audio/Recorder.swift, minus the WAV file and minus Apple's voice
// processing (voice processing takes longer to start and would clip your first word).
//
// 0.7.2 "starts fast":
//  • The audio engine + converter + tap are built ONCE (at launch, `prepare()`) and reused, instead
//    of a new AVAudioEngine on every key press. A new one is built only when the Mac's input
//    device or format changes (AirPods connected, a USB mic plugged in…).
//  • Starting and stopping happen on a private queue, never on the main thread, so the hotkey and
//    the capsule react at once even when a Bluetooth mic takes a moment to wake up.
//  • The mic is still OFF between dictations (macOS's orange mic dot only shows while you talk).
//
// 0.7.5 "music sounds distorted while Scribe runs": the engine used to be PREPARED at launch on the
// default input. With AirPods (or any Bluetooth headset) as the default input that can switch the
// headset into its low-quality call mode (HFP) for as long as Scribe runs. Now the mic is chosen by
// MicDevices (Automatic = the built-in mic when the default input is Bluetooth), the engine is only
// warmed up ahead of time on a non-Bluetooth mic, and a Bluetooth mic's engine is torn down after
// every take.

// 0.7.7 "a USB wireless mic (a 2-channel 'Wireless Microphone' receiver) records nothing":
//  • The tap is installed with format nil, so it gets the input node's REAL format, and the 16 kHz
//    converter follows each buffer's actual format (Live16kMono) instead of a format read once at
//    build time. Before, the format was read right after setDeviceID, which can still describe the
//    previous device (e.g. 44.1 kHz for a 48 kHz receiver), and the converter was built for it.
//  • setDeviceID is only called when the chosen mic is NOT already the system default (Automatic
//    with a USB mic as the default input = the plain default path, no device switch at all). Its
//    error is logged, not swallowed.
//  • All channels are used (To16kMono.Mix.voice): a receiver that puts the voice on channel 2 only
//    used to be recorded as silence (channel 0 only).
//  • If no audio arrives within 1.5 s of starting on a device that had to be selected explicitly,
//    the engine is rebuilt once on the system default path (and that device is skipped for the rest
//    of the session). A Bluetooth mic is never second-guessed this way (it can take longer to wake).
//  • scribe.log gets the device (name, transport, hardware rate, channels), the formats the node
//    reports, and per take: first-buffer time, buffer count, peak level. Numbers only, no audio.

import AVFoundation
import CoreAudio
import os

final class MicCapture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "scribe.mic", qos: .userInteractive)
    private static let logQueue = DispatchQueue(label: "scribe.mic.log", qos: .utility)
    private var engine: AVAudioEngine?          // built once, reused (touched only on `queue`)
    private var engineFormat: AVAudioFormat?
    private var running = false
    private var needsRebuild = false
    private var configObserver: NSObjectProtocol?
    private var builtDevice: AudioDeviceID?
    private var builtBluetooth = false
    /// The engine was built with an explicit setDeviceID (not the system default path).
    private var builtExplicit = false
    /// 0.7.7: a device that sent no audio when selected explicitly; use the system default path
    /// instead for the rest of this session.
    private var skipDevice: AudioDeviceID?

    private var samples: [Float] = []
    private let lock = NSLock()                 // the audio thread and other threads both touch these
    private var firstBufferPending = false
    // Per-take diagnostics (under `lock`).
    private var take = 0
    private var takeStart: Date?
    private var takeFirstBuffer: Date?
    private var takeBuffers = 0
    private var takePeak: Float = 0
    private var takeFormat = ""
    private var takeFormatChanges = 0
    private var takeFallback = false

    /// Called (on the main thread) about 10 times a second with a 0...1 loudness, for the pill's bars.
    var onLevel: ((Float) -> Void)?
    /// Called on the AUDIO thread with each new slice of 16 kHz audio (for the live voice detector).
    var onSamples: (([Float]) -> Void)?
    /// Called (on the main thread) once per take, when the first slice of real mic audio arrives.
    var onFirstAudio: (() -> Void)?

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    private static func log(_ s: String) { logQueue.async { AppLog.log(s) } }

    /// Build the engine ahead of time (cheap; the mic stays off). Safe to call many times.
    func prepare() {
        queue.async { [self] in
            guard let dev = MicDevices.current(), !dev.isBluetooth else { return }   // never warm a headset mic
            if engine == nil || needsRebuild || builtDevice != dev.id { try? build() }
        }
    }

    /// The mic to use changed (setting, default device, unplugged) → rebuild before this take.
    private var deviceChanged: Bool { MicDevices.current()?.id != builtDevice }

    private func beginTake() {
        lock.lock()
        take += 1
        takeStart = Date(); takeFirstBuffer = nil; takeBuffers = 0; takePeak = 0
        takeFormatChanges = 0; takeFallback = false
        running = true                          // before start: keep the very first buffer
        lock.unlock()
    }

    /// Start the engine; one rebuild + retry when it fails (a stale graph after a device change).
    private func startEngine() throws {
        guard let engine else { throw Recorder.RecorderError.noMicrophone }
        if engine.isRunning { return }
        do { try engine.start() } catch {
            Self.log("dictation mic: engine start failed (\((error as NSError).domain) \((error as NSError).code)); rebuilding once")
            try build()
            do { try self.engine?.start() } catch {
                Self.log("dictation mic: engine start failed again (\((error as NSError).domain) \((error as NSError).code))")
                throw error
            }
        }
    }

    /// Start recording. Returns at once; the engine starts on the mic queue. `completion` runs on
    /// the main thread with nil (recording) or the error. Audio from the moment the engine runs
    /// is kept; nothing before it is lost on purpose, there just isn't any yet.
    func start(completion: @escaping @Sendable (Error?) -> Void) {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        firstBufferPending = true
        lock.unlock()
        queue.async { [self] in
            do {
                if engine == nil || needsRebuild || deviceChanged { try build() }
                guard engine != nil else { throw Recorder.RecorderError.noMicrophone }
                beginTake()
                try startEngine()
                scheduleWatchdog()
                DispatchQueue.main.async { completion(nil) }
            } catch {
                lock.lock(); running = false; lock.unlock()
                Self.log("dictation mic: couldn't start (\(error.localizedDescription))")
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    /// Start and wait until the mic runs (voice enrollment / Test my voice, which aren't timing-critical).
    func start() throws {
        lock.lock(); samples.removeAll(keepingCapacity: true); firstBufferPending = true; lock.unlock()
        try queue.sync {
            if engine == nil || needsRebuild || deviceChanged { try build() }
            guard engine != nil else { throw Recorder.RecorderError.noMicrophone }
            beginTake()
            do { try startEngine() } catch {
                lock.lock(); running = false; lock.unlock()
                throw error
            }
            scheduleWatchdog()
        }
    }

    /// 0.7.7: 1.5 s after a take starts, check that audio buffers arrive. None on an explicitly
    /// selected (non-default, non-Bluetooth) device → rebuild once on the system default path.
    private func scheduleWatchdog() {
        lock.lock(); let myTake = take; lock.unlock()
        queue.asyncAfter(deadline: .now() + 1.5) { [self] in
            lock.lock()
            let same = running && take == myTake
            let buffers = takeBuffers, peak = takePeak, fellBack = takeFallback
            lock.unlock()
            guard same else { return }
            if buffers > 0 {
                if peak < SourceMonitor.silenceFloor {
                    Self.log("dictation mic: \(buffers) buffers in 1.5 s but digital silence (peak \(String(format: "%.6f", peak)))")
                }
                return
            }
            Self.log("dictation mic: no audio buffers 1.5 s after start (explicit=\(builtExplicit), bluetooth=\(builtBluetooth))")
            guard !fellBack, !builtBluetooth else { return }
            if builtExplicit, let d = builtDevice { skipDevice = d }
            lock.lock(); takeFallback = true; lock.unlock()
            do {
                try build(systemPath: true)
                lock.lock(); takeStart = Date(); lock.unlock()
                try engine?.start()
                Self.log("dictation mic: rebuilt on the system default path and restarted")
            } catch {
                Self.log("dictation mic: fallback to the system default failed (\((error as NSError).domain) \((error as NSError).code))")
            }
        }
    }

    /// Stop and hand back everything recorded (16 kHz mono). Waits for a start still in progress.
    func stop() -> [Float] {
        queue.sync {
            engine?.stop()                      // stop() not pause(): the mic really turns off
            lock.lock(); running = false; lock.unlock()
            // A Bluetooth headset mic: let go of it completely so the headset returns to music mode.
            if builtBluetooth, let e = engine {
                e.inputNode.removeTap(onBus: 0)
                if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
                configObserver = nil
                engine = nil
            }
        }
        lock.lock(); defer { lock.unlock() }
        if let t0 = takeStart {
            let first = takeFirstBuffer.map { String(format: "%.0f ms", $0.timeIntervalSince(t0) * 1000) } ?? "never"
            Self.log("dictation take: first audio \(first), \(takeBuffers) buffers, peak \(String(format: "%.4f", takePeak)), format \(takeFormat.isEmpty ? "-" : takeFormat), format changes \(takeFormatChanges)\(takeFallback ? ", used system-default fallback" : "")")
            takeStart = nil
        }
        let out = samples
        samples = []
        return out
    }

    /// Build engine + converter + tap for the CURRENT input device. Runs on `queue`.
    /// `systemPath`: don't select a device; use whatever the system default input is.
    private func build(systemPath: Bool = false) throws {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        engine = nil
        needsRebuild = false

        let t0 = Date()
        let chosen = MicDevices.current()
        let all = MicDevices.inputs()
        let defID = MicDevices.defaultInputID()
        let useSystem = systemPath || (chosen != nil && chosen?.id == skipDevice)
        // The device that will actually be opened.
        let dev: MicDevice? = useSystem ? (all.first { $0.id == defID } ?? chosen) : chosen

        var eng = AVAudioEngine()
        var explicit = false
        var outFormat: AVAudioFormat!
        var hwFormat: AVAudioFormat!
        let nominal = dev.flatMap { MicDevices.nominalSampleRate($0.id) }
        // Up to two tries: a fresh engine if the node's format disagrees with the device's real rate.
        for attempt in 0..<2 {
            if attempt > 0 { eng = AVAudioEngine() }
            let input = eng.inputNode
            explicit = false
            if let dev, !useSystem, dev.id != defID {
                do { try input.auAudioUnit.setDeviceID(dev.id); explicit = true } catch {
                    Self.log("dictation mic: setDeviceID(\(dev.name)) failed (\((error as NSError).domain) \((error as NSError).code)); using the system default")
                }
            }
            hwFormat = input.inputFormat(forBus: 0)
            outFormat = input.outputFormat(forBus: 0)
            if let nominal, abs(outFormat.sampleRate - nominal) > 1 || abs(hwFormat.sampleRate - nominal) > 1 {
                Self.log("dictation mic: format mismatch (try \(attempt + 1)): node in \(Int(hwFormat.sampleRate)) Hz / out \(Int(outFormat.sampleRate)) Hz, device runs at \(Int(nominal)) Hz")
                continue
            }
            break
        }
        builtDevice = chosen?.id
        builtExplicit = explicit
        builtBluetooth = dev?.isBluetooth ?? false
        guard outFormat.sampleRate > 0, outFormat.channelCount > 0 else {
            Self.log("dictation mic: no input format (\(Int(outFormat.sampleRate)) Hz × \(outFormat.channelCount) ch)")
            throw Recorder.RecorderError.noMicrophone
        }
        let input = eng.inputNode

        // format nil = the node's real output format; the converter follows each buffer's format.
        let conv = Live16kMono(mix: .voice)
        input.installTap(onBus: 0, bufferSize: 4800, format: nil) { [weak self] buffer, _ in
            guard let self, buffer.frameLength > 0 else { return }
            let changesBefore = conv.formatChanges
            guard let r = conv.process(buffer) else { return }
            let fmt = buffer.format
            self.lock.lock()
            guard self.running else { self.lock.unlock(); return }
            if self.takeFirstBuffer == nil {
                self.takeFirstBuffer = Date()
                self.takeFormat = "\(Int(fmt.sampleRate)) Hz × \(fmt.channelCount) ch"
            }
            self.takeBuffers += 1
            self.takePeak = max(self.takePeak, r.peak)
            if conv.formatChanges != changesBefore {
                self.takeFormatChanges += 1
                self.takeFormat = "\(Int(fmt.sampleRate)) Hz × \(fmt.channelCount) ch"
            }
            guard let converted = r.out, converted.frameLength > 0, let out = converted.floatChannelData?[0] else {
                self.lock.unlock(); return
            }
            let n = Int(converted.frameLength)
            let chunk = Array(UnsafeBufferPointer(start: out, count: n))
            self.samples.append(contentsOf: chunk)
            let first = self.firstBufferPending
            self.firstBufferPending = false
            self.lock.unlock()
            self.onSamples?(chunk)
            if first { DispatchQueue.main.async { self.onFirstAudio?() } }
            // Loudness (RMS in dB, mapped so -60 dB = 0 and 0 dB = 1).
            let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(n))
            let level = min(1, max(0, (20 * log10(max(rms, 1e-6)) + 60) / 60))
            DispatchQueue.main.async { self.onLevel?(level) }
        }
        // Warm up (allocate the input unit) only on a non-Bluetooth mic; a headset mic is opened by start().
        if !builtBluetooth { eng.prepare() }
        self.engine = eng
        self.engineFormat = outFormat
        let what = dev.map { MicDevices.describe($0) } ?? "system default (no device found)"
        Self.log("dictation mic: \(what)\(builtBluetooth ? " (Bluetooth: opened only while dictating)" : "") \(Int(outFormat.sampleRate)) Hz, node in \(Int(hwFormat.sampleRate)) Hz × \(hwFormat.channelCount) ch / out \(Int(outFormat.sampleRate)) Hz × \(outFormat.channelCount) ch, path=\(explicit ? "selected" : "system default")\(useSystem && !systemPath ? " (skipping a device that sent no audio)" : ""), setting=\(MicDevices.setting)")
        // Input device changed (AirPods, USB mic…): rebuild before the next take.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: eng, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.needsRebuild = true }
        }
        Perf.log.info("mic engine built in \(Date().timeIntervalSince(t0) * 1000, format: .fixed(precision: 0))ms (\(outFormat.sampleRate, format: .fixed(precision: 0)) Hz)")
    }
}
