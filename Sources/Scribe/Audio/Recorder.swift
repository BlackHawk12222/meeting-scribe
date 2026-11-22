// Recorder.swift
// Records the Mac's microphone to a 16 kHz mono WAV file.
//
// Noise cleanup: Apple's "voice processing" (the same audio unit FaceTime uses)
// is switched on with one line: inputNode.setVoiceProcessingEnabled(true).
// It removes steady background noise (fans, HVAC, robot motors idling) and echo.
// It is NOT magic: loud, sudden noises (a robot hitting the field wall) still get through.

import AVFoundation
import Combine

@MainActor
final class Recorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0          // 0...1 for the meter
    @Published private(set) var noiseCleanupActive = false

    private var engine: AVAudioEngine?
    private var file: AVAudioFile?
    private var startDate: Date?
    private var timer: Timer?
    private(set) var currentURL: URL?

    /// Ask macOS for microphone permission (shows the system prompt the first time).
    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start(to url: URL, noiseCleanup: Bool) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode

        // 1) Noise suppression + echo cancellation from Apple.
        noiseCleanupActive = false
        if noiseCleanup {
            do {
                try input.setVoiceProcessingEnabled(true)
                // Don't make other apps' sound quieter while we record.
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
                noiseCleanupActive = true
            } catch {
                // Some audio interfaces don't support it; record without it.
                print("Voice processing unavailable: \(error)")
            }
        }

        // 2) Formats: whatever the mic gives us -> 16 kHz mono (what the models want).
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw RecorderError.noMicrophone }
        guard let monoIn = AVAudioFormat(standardFormatWithSampleRate: inFormat.sampleRate, channels: 1),
              let out16k = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: monoIn, to: out16k)
        else { throw RecorderError.formatProblem }

        // 3) The WAV file on disk (16-bit PCM keeps it small: ~115 MB per hour).
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)

        // 4) A "tap" hands us every chunk of microphone audio as it arrives.
        //    This closure runs on an audio thread, not the main thread.
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            guard let src = buffer.floatChannelData, buffer.frameLength > 0,
                  let mono = AVAudioPCMBuffer(pcmFormat: monoIn, frameCapacity: buffer.frameLength)
            else { return }
            // Keep channel 0 only (voice processing can report several channels).
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
            if converted.frameLength > 0 { try? file.write(from: converted) }

            // Loudness for the level meter (RMS -> rough 0...1).
            var sum: Float = 0
            for i in 0..<Int(mono.frameLength) { sum += src[0][i] * src[0][i] }
            let rms = sqrt(sum / Float(max(mono.frameLength, 1)))
            let meter = min(1, max(0, (20 * log10(max(rms, 1e-6)) + 60) / 60))
            DispatchQueue.main.async { self?.level = meter }
        }

        engine.prepare()
        try engine.start()

        self.engine = engine
        self.file = file
        self.currentURL = url
        startDate = Date()
        elapsed = 0
        isRecording = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startDate else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
        }
    }

    /// Stop and return the file + its length in seconds.
    func stop() -> (URL, TimeInterval)? {
        guard isRecording, let engine, let url = currentURL else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if noiseCleanupActive { try? engine.inputNode.setVoiceProcessingEnabled(false) }
        timer?.invalidate()
        let duration = elapsed
        self.engine = nil
        self.file = nil       // closing the AVAudioFile finishes the WAV header
        isRecording = false
        level = 0
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
