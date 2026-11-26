// AudioChecks.swift
// 0.7.5 meeting-audio helpers that don't need a device, so the self-test can exercise them:
//   • SourceMonitor   – per source (mic / Mac sound): buffers seen, seconds, the current run of
//                       pure digital silence, when the last buffer came. A real microphone is never
//                       digitally silent; a mic macOS has blocked (permission reset), a muted input
//                       or a broken voice-processing unit delivers exact zeros.
//   • To16kMono       – any input format (mono/stereo, interleaved or not, any rate) → 16 kHz mono.
//   • Live16kMono     – (0.7.7) To16kMono that follows each buffer's ACTUAL format (rebuilds itself
//                       when the rate or channel count changes), for mic taps installed with format nil.
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
    /// firstChannel: channel 0 only (old mic behavior). average: plain mean of all channels (Mac sound).
    /// voice (0.7.7, microphones): per buffer, the channels carrying sound are averaged and the
    /// near-silent ones are left out. A USB wireless receiver (e.g. a 2-channel "Wireless
    /// Microphone") can put the transmitter's voice on ONE channel only (often channel 2): the old
    /// channel-0 copy recorded silence, and a plain average would halve the voice (-6 dB). "Voice"
    /// keeps a single live channel at full level, and a normal stereo/dual-mono mic (the same voice
    /// on both channels) comes out as the average, i.e. unchanged. A channel counts as live when its
    /// energy is within 20 dB of the loudest channel in that buffer.
    enum Mix { case firstChannel, average, voice }
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
        // .voice: which channels are live in this buffer.
        var live = [Bool](repeating: true, count: ch)
        var liveCount = ch
        if mix == .voice, ch > 1 {
            var energy = [Float](repeating: 0, count: ch)
            for c in 0..<ch {
                var e: Float = 0
                for i in 0..<n { let v = interleaved ? src[0][i * ch + c] : src[c][i]; e += v * v }
                energy[c] = e
            }
            let top = energy.max() ?? 0
            for c in 0..<ch { live[c] = top > 0 && energy[c] >= top * 0.01 }
            liveCount = max(1, live.filter { $0 }.count)
        }
        for i in 0..<n {
            var v: Float
            if mix == .voice && ch > 1 {
                v = 0
                for c in 0..<ch where live[c] { v += interleaved ? src[0][i * ch + c] : src[c][i] }
                v /= Float(liveCount)
            } else if mix == .firstChannel || ch == 1 {
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

/// 0.7.7: 16 kHz mono from whatever format the buffers really arrive in. A mic tap installed with
/// `format: nil` hands over the input node's real format; if that changes (a USB receiver that
/// switches 44.1 ↔ 48 kHz, 1 ↔ 2 channels) the converter is rebuilt instead of feeding the old one a
/// buffer it can't read. Not thread-safe; one audio thread.
final class Live16kMono {
    let mix: To16kMono.Mix
    private(set) var conv: To16kMono?
    /// How many times the format changed after the first buffer (logged by the callers).
    private(set) var formatChanges = 0
    init(mix: To16kMono.Mix) { self.mix = mix }

    static func sameFormat(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        a.sampleRate == b.sampleRate && a.channelCount == b.channelCount && a.isInterleaved == b.isInterleaved
            && a.commonFormat == b.commonFormat
    }

    /// (16 kHz mono buffer or nil while the converter primes, peak of the mono input-rate signal, mono input-rate buffer)
    func process(_ buffer: AVAudioPCMBuffer) -> (out: AVAudioPCMBuffer?, peak: Float, mono: AVAudioPCMBuffer)? {
        let f = buffer.format
        if conv == nil || !Self.sameFormat(conv!.inFormat, f) {
            if conv != nil { formatChanges += 1 }
            conv = To16kMono(inFormat: f, mix: mix)
        }
        guard let conv, let (mono, peak) = conv.mono(buffer) else { return nil }
        return (conv.convert(mono), peak, mono)
    }
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
