// SelfTest077.swift
// 0.7.7 targeted checks for "a USB wireless mic receiver records nothing" (run inside
// `--suite targeted`, see SelfTest072.run). The CI runner has no USB mic, so these exercise the
// conversion path with synthetic buffers:
//   ch1_only    – 48 kHz stereo where the voice is ONLY on channel 2 (channel 1 silent or faint hiss),
//                 planar and interleaved → the 16 kHz mono output carries the voice at full level
//                 (the old channel-0 copy gave silence; a plain average would halve it).
//   both        – the same voice on both channels comes out unchanged (not doubled, not halved).
//   mismatch    – the converter first sees 44.1 kHz mono (the stale format the old code read after
//                 setDeviceID), then the buffers really arrive as 48 kHz stereo → it rebuilds for
//                 the real format, the output length matches 48 kHz input, and the voice is there.
//   devices     – the device description used in scribe.log works for every input on this Mac.

import Foundation
import AVFoundation
import CoreAudio

enum SelfTest077 {
    static func run() -> ([String: Any], [String]) {
        var r: [String: Any] = [:]
        var fail: [String] = []

        // A 440 Hz tone at amplitude 0.3 (RMS ≈ 0.212).
        func tone(_ i: Int, rate: Double) -> Float { 0.3 * Float(sin(2 * Double.pi * 440 * Double(i) / rate)) }

        /// Feeds `count` buffers of 0.1 s; channel values from `value(channel, frame index)`.
        func feed(_ conv: Live16kMono, rate: Double, channels: AVAudioChannelCount, interleaved: Bool, count: Int,
                  start: Int = 0, value: (Int, Int) -> Float) -> [Float] {
            var out: [Float] = []
            guard let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: interleaved) else { return [] }
            let n = Int(rate / 10)
            for k in 0..<count {
                guard let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(n)) else { return [] }
                b.frameLength = AVAudioFrameCount(n)
                let p = b.floatChannelData!
                let ch = Int(channels)
                for i in 0..<n {
                    let idx = start + k * n + i
                    for c in 0..<ch {
                        let v = value(c, idx)
                        if interleaved && ch > 1 { p[0][i * ch + c] = v } else { p[c][i] = v }
                    }
                }
                if let res = conv.process(b), let o = res.out, let d = o.floatChannelData?[0] {
                    out += Array(UnsafeBufferPointer(start: d, count: Int(o.frameLength)))
                }
            }
            return out
        }
        func rms(_ x: ArraySlice<Float>) -> Float {
            x.isEmpty ? 0 : sqrt(x.reduce(0) { $0 + $1 * $1 } / Float(x.count))
        }
        func tail(_ x: [Float]) -> ArraySlice<Float> { x.suffix(max(0, x.count / 2)) }   // skip the converter's priming
        func round4(_ v: Float) -> Double { (Double(v) * 10_000).rounded() / 10_000 }

        // ch1_only: voice on channel index 1, channel 0 silent / faint hiss; planar and interleaved.
        var ch1: [String: Any] = [:]
        for interleaved in [false, true] {
            for hiss in [Float(0), 0.0005] {
                let conv = Live16kMono(mix: .voice)
                let out = feed(conv, rate: 48_000, channels: 2, interleaved: interleaved, count: 10) { c, i in
                    c == 1 ? tone(i, rate: 48_000) : (i % 2 == 0 ? hiss : -hiss)
                }
                let level = rms(tail(out))
                let key = "\(interleaved ? "interleaved" : "planar")_hiss\(hiss > 0 ? "on" : "off")"
                ch1[key] = ["frames_16k": out.count, "rms": round4(level)] as [String: Any]
                if out.count < 14_000 || out.count > 16_100 { fail.append("usbmic: 1 s at 48 kHz → \(out.count) frames at 16 kHz (\(key))") }
                if level < 0.18 { fail.append("usbmic: voice on channel 2 only came out at RMS \(level), want ≈0.21 (\(key))") }
            }
        }
        // What 0.7.6 did (channel 0 only) on the same input: silence. Recorded to document the bug.
        let old = Live16kMono(mix: .firstChannel)
        let oldOut = feed(old, rate: 48_000, channels: 2, interleaved: false, count: 10) { c, i in c == 1 ? tone(i, rate: 48_000) : 0 }
        ch1["v076_first_channel_rms"] = round4(rms(tail(oldOut)))
        if rms(tail(oldOut)) > 0.001 { fail.append("usbmic: test input wrong (channel 0 should be silent)") }
        r["ch1_only"] = ch1

        // both: identical voice on both channels → unchanged level.
        let both = Live16kMono(mix: .voice)
        let bothOut = feed(both, rate: 48_000, channels: 2, interleaved: false, count: 10) { _, i in tone(i, rate: 48_000) }
        let bothRMS = rms(tail(bothOut))
        r["both_channels_rms"] = round4(bothRMS)
        if abs(bothRMS - 0.212) > 0.02 { fail.append("usbmic: same voice on both channels → RMS \(bothRMS), want ≈0.21") }

        // mismatch: 44.1 kHz mono first (the stale format), then 48 kHz stereo with the voice on channel 2.
        let mm = Live16kMono(mix: .voice)
        let a = feed(mm, rate: 44_100, channels: 1, interleaved: false, count: 2) { _, i in tone(i, rate: 44_100) * 0.1 }
        let b = feed(mm, rate: 48_000, channels: 2, interleaved: false, count: 10) { c, i in c == 1 ? tone(i, rate: 48_000) : 0 }
        let mmRMS = rms(tail(b))
        r["mismatch"] = ["first_frames_16k": a.count, "then_frames_16k": b.count, "format_changes": mm.formatChanges,
                         "rms": round4(mmRMS), "now_converting_from": mm.conv.map { "\(Int($0.inFormat.sampleRate)) Hz × \($0.inFormat.channelCount) ch" } ?? "none"] as [String: Any]
        if mm.formatChanges != 1 { fail.append("usbmic: converter didn't rebuild once for the real format (changes=\(mm.formatChanges))") }
        if mm.conv?.inFormat.sampleRate != 48_000 || mm.conv?.inFormat.channelCount != 2 { fail.append("usbmic: converter not following the 48 kHz stereo buffers") }
        if b.count < 14_000 || b.count > 16_100 { fail.append("usbmic: after the format change, 1 s at 48 kHz → \(b.count) frames (want ≈16,000)") }
        if mmRMS < 0.18 { fail.append("usbmic: after the format change the voice came out at RMS \(mmRMS)") }

        // devices: the log description for each input on this Mac (count only in the report).
        let inputs = MicDevices.inputs()
        var described = 0
        for d in inputs where !MicDevices.describe(d).isEmpty { described += 1 }
        r["devices"] = ["inputs": inputs.count, "described": described,
                        "transports": inputs.map { MicDevices.transportName($0.transport) }] as [String: Any]
        if MicDevices.transportName(kAudioDeviceTransportTypeUSB) != "USB" || MicDevices.transportName(kAudioDeviceTransportTypeBluetooth) != "Bluetooth" {
            fail.append("usbmic: transport names wrong")
        }
        // The Automatic rule is unchanged: a USB mic that is the default input is used.
        let builtIn = MicDevice(id: 10, uid: "builtin", name: "Built-in Microphone", transport: kAudioDeviceTransportTypeBuiltIn)
        let usb = MicDevice(id: 11, uid: "usb-rx", name: "Wireless Microphone", transport: kAudioDeviceTransportTypeUSB)
        let pods = MicDevice(id: 12, uid: "pods", name: "Headset", transport: kAudioDeviceTransportTypeBluetooth)
        if MicDevices.choose([builtIn, usb, pods], defaultID: 11, setting: "auto")?.id != 11 { fail.append("usbmic: Automatic should use a USB mic that is the default input") }
        if MicDevices.choose([builtIn, usb, pods], defaultID: 12, setting: "auto")?.id != 10 { fail.append("usbmic: Automatic with a Bluetooth default should still use the built-in mic") }
        return (r, fail)
    }
}
