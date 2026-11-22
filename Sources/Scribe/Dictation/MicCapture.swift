// MicCapture.swift
// Records the microphone into memory (not a file) for dictation.
// Same idea as Audio/Recorder.swift, minus the WAV file and minus Apple's voice
// processing (voice processing takes longer to start and would clip your first word).

import AVFoundation

final class MicCapture {
    private var engine: AVAudioEngine?
    private var samples: [Float] = []
    private let lock = NSLock()                 // the audio thread and the main thread both touch `samples`
    /// Called (on the main thread) about 10 times a second with a 0...1 loudness, for the pill's bars.
    var onLevel: ((Float) -> Void)?

    var isRunning: Bool { engine != nil }

    func start() throws {
        stopEngine()
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()

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
            if n > 0, let out = converted.floatChannelData?[0] {
                let chunk = Array(UnsafeBufferPointer(start: out, count: n))
                self.lock.lock(); self.samples.append(contentsOf: chunk); self.lock.unlock()
                // Loudness (RMS in dB, mapped so -60 dB = 0 and 0 dB = 1).
                let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(n))
                let level = min(1, max(0, (20 * log10(max(rms, 1e-6)) + 60) / 60))
                DispatchQueue.main.async { self.onLevel?(level) }
            }
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    /// Stop and hand back everything recorded (16 kHz mono).
    func stop() -> [Float] {
        stopEngine()
        lock.lock(); defer { lock.unlock() }
        let out = samples
        samples = []
        return out
    }

    private func stopEngine() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }
}
