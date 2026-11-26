// SystemAudioTap.swift
// 0.7.5: records the sound the Mac PLAYS (the other people on a Zoom/Meet/Teams call) during a
// meeting, with a Core Audio process tap (macOS 14.4+): a global stereo tap on every app except
// Scribe, wrapped in a private aggregate device whose IOProc hands us the audio.
//
// Why: before 0.7.5 a meeting recorded only the microphone, with Apple voice processing on. Voice
// processing's echo cancellation removes what the Mac's speakers play from the mic signal, and
// with headphones the mic never hears the call at all, so the other people on a call were missing
// or nearly silent in the recording.
//
// Permission: "System Audio Recording Only" (System Settings › Privacy & Security › Screen &
// System Audio Recording). macOS asks the first time the tap starts (Info.plist
// NSAudioCaptureUsageDescription). If it's refused the tap delivers silence; the recorder's
// silence check then says so.

import AVFoundation
import CoreAudio
import AudioToolbox

@available(macOS 14.4, *)
final class SystemAudioTap {
    enum TapError: LocalizedError {
        case step(String, OSStatus)
        var errorDescription: String? {
            if case .step(let what, let st) = self { return "\(what) failed (\(st))" }
            return nil
        }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "scribe.systemaudio", qos: .userInitiated)
    private(set) var format: AVAudioFormat?

    /// Starts the tap. `handler` runs on a private queue with each buffer (the tap's own format,
    /// usually 48 kHz float stereo).
    func start(handler: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcessObjects())
        desc.uuid = UUID()
        desc.name = "Scribe meeting"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        var st = AudioHardwareCreateProcessTap(desc, &tap)
        guard st == noErr else { throw TapError.step("Creating the system audio tap", st) }
        tapID = tap

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        st = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard st == noErr, let fmt = AVAudioFormat(streamDescription: &asbd) else {
            stop(); throw TapError.step("Reading the tap's format", st)
        }
        format = fmt

        let outputUID = try Self.defaultOutputUID()
        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Scribe System Audio",
            kAudioAggregateDeviceUIDKey: "com.blackhawk12222.Scribe.tap." + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        var aggID = AudioObjectID(kAudioObjectUnknown)
        st = AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID)
        guard st == noErr else { stop(); throw TapError.step("Creating the aggregate device", st) }
        aggregateID = aggID

        var proc: AudioDeviceIOProcID?
        st = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, queue) { _, inInput, _, _, _ in
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: inInput, deallocator: nil),
                  buf.frameLength > 0 else { return }
            handler(buf)
        }
        guard st == noErr, let proc else { stop(); throw TapError.step("Creating the audio callback", st) }
        procID = proc
        st = AudioDeviceStart(aggregateID, proc)
        guard st == noErr else { stop(); throw TapError.step("Starting system audio", st) }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }

    // MARK: Helpers

    /// Scribe's own Core Audio process object(s), so the tap doesn't record Scribe itself.
    static func ownProcessObjects() -> [AudioObjectID] {
        var pid = getpid()
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
        return st == noErr && obj != kAudioObjectUnknown ? [obj] : []
    }

    static func defaultOutputUID() throws -> String {
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        guard st == noErr, dev != kAudioObjectUnknown else { throw TapError.step("Finding the output device", st) }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioDevicePropertyDeviceUID
        st = AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &uid)
        guard st == noErr, let u = uid?.takeRetainedValue() else { throw TapError.step("Reading the output device id", st) }
        return u as String
    }
}
