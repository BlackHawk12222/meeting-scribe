// AudioChecks.swift
// 0.7.5 meeting-audio helpers that don't need a device, so the self-test can exercise them:
//   • SourceMonitor   – per source (mic / Mac sound): buffers seen, seconds, the current run of
//                       pure digital silence, when the last buffer came. A real microphone is never
//                       digitally silent; a mic macOS has blocked (permission reset), a muted input
//                       or a broken voice-processing unit delivers exact zeros.
//   • To16kMono       – any input format (mono/stereo, interleaved or not, any rate) → 16 kHz mono.
//   • MeetingMixer    – after the recording: mic file + Mac-sound file (with its start offset) →
//                       one 16 kHz file for transcription.

import AVFoundation

/// Thread-safe: fed on audio threads, read on the main thread.
final class SourceMonitor: @unchecked Sendable {
    /// Peak below this = digital silence (≈ -94 dBFS). Room noise on a live mic is far above it.
    static let silenceFloor: Float = 0.00002
    private let lock = NSLock()
    private(set) var name: String
    private var buffers = 0
    private var seconds: Double = 0
    private var silentRun: Double = 0
    private var loudest: Float = 0
    private var lastBuffer: Date?
    private var started = Date()

    init(name: String) { self.name = name }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        buffers = 0; seconds = 0; silentRun = 0; loudest = 0; lastBuffer = nil; started = Date()
    }

    /// One buffer: its peak and length in seconds.
    func feed(peak: Float, duration: Double, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        buffers += 1
        seconds += duration
        loudest = max(loudest, peak)
        silentRun = peak < Self.silenceFloor ? silentRun + duration : 0
        lastBuffer = now
    }

    struct Snapshot {
        var buffers: Int
        var seconds: Double
        var silentRun: Double
        var loudest: Float
        /// Seconds since the last buffer (or since start when none came yet).
        var sinceLastBuffer: Double
    }

    func snapshot(now: Date = Date()) -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(buffers: buffers, seconds: seconds, silentRun: silentRun, loudest: loudest,
                        sinceLastBuffer: now.timeIntervalSince(lastBuffer ?? started))
    }

    static func peak(_ p: UnsafePointer<Float>, count: Int, stride: Int = 1) -> Float {
        var m: Float = 0
        var i = 0
        while i < count * stride { m = max(m, abs(p[i])); i += stride }
        return m
    }
}

/// Converts buffers of one input format to 16 kHz mono float. Not thread-safe; use from one thread.
final class To16kMono {
    enum Mix { case firstChannel, average }
    let inFormat: AVAudioFormat
    let mix: Mix
    private let monoIn: AVAudioFormat
    private let converter: AVAudioConverter
    static let out16k = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    init?(inFormat: AVAudioFormat, mix: Mix) {
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0, inFormat.commonFormat == .pcmFormatFloat32,
              let monoIn = AVAudioFormat(standardFormatWithSampleRate: inFormat.sampleRate, channels: 1),
              let conv = AVAudioConverter(from: monoIn, to: Self.out16k) else { return nil }
        self.inFormat = inFormat
        self.mix = mix
        self.monoIn = monoIn
        self.converter = conv
    }

    /// The mono (input-rate) version of `buffer` and its peak.
    func mono(_ buffer: AVAudioPCMBuffer) -> (AVAudioPCMBuffer, Float)? {
        let n = Int(buffer.frameLength)
        guard n > 0, let src = buffer.floatChannelData,
              let mono = AVAudioPCMBuffer(pcmFormat: monoIn, frameCapacity: buffer.frameLength),
              let dst = mono.floatChannelData?[0] else { return nil }
        mono.frameLength = buffer.frameLength
        let ch = Int(buffer.format.channelCount)
        let interleaved = buffer.format.isInterleaved && ch > 1
        var peak: Float = 0
        for i in 0..<n {
            var v: Float
            if mix == .firstChannel || ch == 1 {
                v = interleaved ? src[0][i * ch] : src[0][i]
            } else {
                v = 0
                for c in 0..<ch { v += interleaved ? src[0][i * ch + c] : src[c][i] }
                v /= Float(ch)
            }
            dst[i] = v
            peak = max(peak, abs(v))
        }
        return (mono, peak)
    }

    func convert(_ mono: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount(Double(mono.frameLength) * 16_000 / monoIn.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.out16k, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return mono
        }
        return out.frameLength > 0 ? out : nil
    }

    static func level(peakOrRMS v: Float) -> Float { min(1, max(0, (20 * log10(max(v, 1e-6)) + 60) / 60)) }
}

enum MeetingMixer {
    /// The WAV settings every meeting file uses (16 kHz mono 16-bit, ~115 MB per hour).
    static let wavSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
    ]

    struct Result { var frames: Int64; var micPeak: Float; var systemPeak: Float }

    /// mic + system (starting `systemOffset` seconds after the mic file starts; negative = before)
    /// → `out`. Summed and soft-limited so two loud sources don't clip.
    static func mix(mic: URL, system: URL, systemOffset: Double, out: URL) throws -> Result {
        let a = try AVAudioFile(forReading: mic, commonFormat: .pcmFormatFloat32, interleaved: false)
        let b = try AVAudioFile(forReading: system, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard a.processingFormat.sampleRate == 16_000, b.processingFormat.sampleRate == 16_000 else {
            throw NSError(domain: "Scribe.Mixer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unexpected sample rate"])
        }
        let shift = Int64((systemOffset * 16_000).rounded())          // system frame i lands at mic frame i + shift
        let total = max(a.length, b.length + shift)
        let w = try AVAudioFile(forWriting: out, settings: wavSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk: AVAudioFrameCount = 16_000
        let fmt = To16kMono.out16k
        guard let bufA = AVAudioPCMBuffer(pcmFormat: a.processingFormat, frameCapacity: chunk),
              let bufB = AVAudioPCMBuffer(pcmFormat: b.processingFormat, frameCapacity: chunk),
              let outBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else {
            throw NSError(domain: "Scribe.Mixer", code: 2, userInfo: [NSLocalizedDescriptionKey: "No buffers"])
        }
        var pos: Int64 = 0
        var micPeak: Float = 0, sysPeak: Float = 0
        // Drop the part of the system file that lies before the mic file starts.
        if shift < 0 { b.framePosition = min(b.length, -shift) }
        while pos < total {
            let n = AVAudioFrameCount(min(Int64(chunk), total - pos))
            outBuf.frameLength = n
            let o = outBuf.floatChannelData![0]
            for i in 0..<Int(n) { o[i] = 0 }
            if pos < a.length {
                bufA.frameLength = 0
                try a.read(into: bufA, frameCount: n)
                let p = bufA.floatChannelData![0]
                for i in 0..<Int(bufA.frameLength) { o[i] += p[i]; micPeak = max(micPeak, abs(p[i])) }
            }
            // System audio for this window: mic frames [pos, pos+n) ↔ system frames [pos-shift, …).
            let sysStart = pos - shift
            let lead = sysStart < 0 ? Int(min(Int64(n), -sysStart)) : 0
            if Int(n) > lead, b.framePosition < b.length {
                bufB.frameLength = 0
                try b.read(into: bufB, frameCount: n - AVAudioFrameCount(lead))
                let p = bufB.floatChannelData![0]
                for i in 0..<Int(bufB.frameLength) { o[lead + i] += p[i]; sysPeak = max(sysPeak, abs(p[i])) }
            }
            for i in 0..<Int(n) where abs(o[i]) > 0.95 { o[i] = o[i] > 0 ? 0.95 + 0.05 * tanh((o[i] - 0.95) * 20) : -0.95 - 0.05 * tanh((-o[i] - 0.95) * 20) }
            try w.write(from: outBuf)
            pos += Int64(n)
        }
        return Result(frames: total, micPeak: micPeak, systemPeak: sysPeak)
    }
}
