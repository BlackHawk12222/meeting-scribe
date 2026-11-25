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

import AVFoundation
import os

final class MicCapture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "scribe.mic", qos: .userInteractive)
    private var engine: AVAudioEngine?          // built once, reused (touched only on `queue`)
    private var engineFormat: AVAudioFormat?
    private var running = false
    private var needsRebuild = false
    private var configObserver: NSObjectProtocol?

    private var samples: [Float] = []
    private let lock = NSLock()                 // the audio thread and other threads both touch these
    private var firstBufferPending = false

    /// Called (on the main thread) about 10 times a second with a 0...1 loudness, for the pill's bars.
    var onLevel: ((Float) -> Void)?
    /// Called on the AUDIO thread with each new slice of 16 kHz audio (for the live voice detector).
    var onSamples: (([Float]) -> Void)?
    /// Called (on the main thread) once per take, when the first slice of real mic audio arrives.
    var onFirstAudio: (() -> Void)?

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    /// Build the engine ahead of time (cheap; the mic stays off). Safe to call many times.
    func prepare() {
        queue.async { [self] in
            if engine == nil || needsRebuild { try? build() }
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
                if engine == nil || needsRebuild { try build() }
                guard let engine else { throw Recorder.RecorderError.noMicrophone }
                lock.lock(); running = true; lock.unlock()      // before start: keep the very first buffer
                if !engine.isRunning {
                    do { try engine.start() } catch {
                        // A stale graph (device changed while idle): rebuild once and retry.
                        try build()
                        try self.engine?.start()
                    }
                }
                DispatchQueue.main.async { completion(nil) }
            } catch {
                lock.lock(); running = false; lock.unlock()
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    /// Start and wait until the mic runs (voice enrollment / Test my voice, which aren't timing-critical).
    func start() throws {
        lock.lock(); samples.removeAll(keepingCapacity: true); firstBufferPending = true; lock.unlock()
        try queue.sync {
            if engine == nil || needsRebuild { try build() }
            guard let engine else { throw Recorder.RecorderError.noMicrophone }
            lock.lock(); running = true; lock.unlock()
            do { if !engine.isRunning { try engine.start() } } catch {
                lock.lock(); running = false; lock.unlock()
                throw error
            }
        }
    }

    /// Stop and hand back everything recorded (16 kHz mono). Waits for a start still in progress.
    func stop() -> [Float] {
        queue.sync {
            engine?.stop()                      // stop() not pause(): the mic really turns off
            lock.lock(); running = false; lock.unlock()
        }
        lock.lock(); defer { lock.unlock() }
        let out = samples
        samples = []
        return out
    }

    /// Build engine + converter + tap for the CURRENT input device. Runs on `queue`.
    private func build() throws {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        engine = nil
        needsRebuild = false

        let t0 = Date()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw Recorder.RecorderError.noMicrophone }
        guard let monoIn = AVAudioFormat(standardFormatWithSampleRate: inFormat.sampleRate, channels: 1),
              let out16k = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: monoIn, to: out16k)
        else { throw Recorder.RecorderError.formatProblem }

        // ~100 ms chunks at 48 kHz.
        input.installTap(onBus: 0, bufferSize: 4800, format: inFormat) { [weak self] buffer, _ in
            guard let self, let src = buffer.floatChannelData, buffer.frameLength > 0,
                  let mono = AVAudioPCMBuffer(pcmFormat: monoIn, frameCapacity: buffer.frameLength) else { return }
            mono.frameLength = buffer.frameLength
            mono.floatChannelData![0].update(from: src[0], count: Int(buffer.frameLength))

            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / inFormat.sampleRate) + 64
            guard let converted = AVAudioPCMBuffer(pcmFormat: out16k, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return mono
            }
            let n = Int(converted.frameLength)
            guard n > 0, let out = converted.floatChannelData?[0] else { return }
            let chunk = Array(UnsafeBufferPointer(start: out, count: n))
            self.lock.lock()
            guard self.running else { self.lock.unlock(); return }
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
        engine.prepare()
        self.engine = engine
        self.engineFormat = inFormat
        // Input device changed (AirPods, USB mic…): rebuild before the next take.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.needsRebuild = true }
        }
        Perf.log.info("mic engine built in \(Date().timeIntervalSince(t0) * 1000, format: .fixed(precision: 0))ms (\(inFormat.sampleRate, format: .fixed(precision: 0)) Hz)")
    }
}
