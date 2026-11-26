// MicDevices.swift
// 0.7.5: which microphone Scribe opens (Settings › Dictation › Microphone).
//
// Why: opening a Bluetooth headset's mic (AirPods & co.) switches the headset from its music mode
// (A2DP/AAC) to its call mode (HFP): mono, narrowband, so music and videos sound distorted for as
// long as the mic is open. Before 0.7.5 Scribe also PREPARED its dictation mic engine at launch on
// the system's default input, so with AirPods as the default input that could happen while Scribe
// merely ran. Now:
//   • "Automatic" (default): the Mac's built-in mic when the default input is a Bluetooth headset
//     (and a built-in mic exists), otherwise the system default.
//   • "System default", or one specific device (saved by its UID).
//   • The dictation engine is only warmed up ahead of time on a non-Bluetooth mic; a Bluetooth mic
//     is opened only while you actually dictate or record.

import CoreAudio
import AudioToolbox
import Foundation

struct MicDevice: Equatable, Identifiable {
    var id: AudioDeviceID
    var uid: String
    var name: String
    var transport: UInt32

    var isBluetooth: Bool { transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE }
    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
}

enum MicDevices {
    static let settingKey = "micDevice"          // "auto" (default), "system", or a device UID
    static var setting: String { UserDefaults.standard.string(forKey: settingKey) ?? "auto" }

    /// Every device with an input stream.
    static func inputs() -> [MicDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard hasInput(id), let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            // Skip Scribe's own private aggregate (the meeting's system-audio tap).
            guard !uid.hasPrefix("com.blackhawk12222.Scribe.tap") else { return nil }
            return MicDevice(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? "Microphone",
                             transport: uint32(id, kAudioDevicePropertyTransportType) ?? 0)
        }
    }

    static func defaultInputID() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    /// The rule, as a pure function (the self-test checks it): which device to open.
    static func choose(_ devices: [MicDevice], defaultID: AudioDeviceID?, setting: String) -> MicDevice? {
        let def = devices.first { $0.id == defaultID }
        switch setting {
        case "system": return def
        case "auto", "":
            if let d = def, d.isBluetooth, let builtIn = devices.first(where: \.isBuiltIn) { return builtIn }
            return def ?? devices.first(where: \.isBuiltIn) ?? devices.first
        default:
            // A device that's gone (unplugged) falls back to Automatic.
            return devices.first { $0.uid == setting } ?? choose(devices, defaultID: defaultID, setting: "auto")
        }
    }

    /// The device to open right now.
    static func current() -> MicDevice? { choose(inputs(), defaultID: defaultInputID(), setting: setting) }

    // MARK: Core Audio helpers

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioObjectPropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value?.takeRetainedValue() else { return nil }
        return v as String
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr else { return nil }
        return v
    }
}
