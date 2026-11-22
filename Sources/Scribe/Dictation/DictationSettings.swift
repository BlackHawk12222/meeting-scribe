// DictationSettings.swift
// All the dictation settings in one place. They live in UserDefaults, so
// SwiftUI views can bind to them with @AppStorage("key") and other code can
// read them with these helpers.

import AppKit
import Carbon.HIToolbox

/// The key you HOLD to talk. Modifier keys only, because they don't type anything
/// by themselves (holding a letter key would type that letter).
enum HoldKey: String, CaseIterable, Identifiable {
    case rightOption, rightCommand, rightControl, fn, off
    var id: String { rawValue }

    var title: String {
        switch self {
        case .rightOption: return "Right ⌥ Option"
        case .rightCommand: return "Right ⌘ Command"
        case .rightControl: return "Right ⌃ Control"
        case .fn: return "fn / 🌐 Globe"
        case .off: return "Off"
        }
    }

    /// The hardware key code macOS reports in a "flags changed" event.
    var keyCode: UInt16? {
        switch self {
        case .rightOption: return UInt16(kVK_RightOption)    // 61
        case .rightCommand: return UInt16(kVK_RightCommand)  // 54
        case .rightControl: return UInt16(kVK_RightControl)  // 62
        case .fn: return UInt16(kVK_Function)                // 63
        case .off: return nil
        }
    }

    /// Which modifier flag is set while the key is down.
    var flag: NSEvent.ModifierFlags {
        switch self {
        case .rightOption: return .option
        case .rightCommand: return .command
        case .rightControl: return .control
        case .fn: return .function
        case .off: return []
        }
    }
}

/// How the hotkeys behave.
enum DictationMode: String, CaseIterable, Identifiable {
    case both, holdOnly, toggleOnly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .both: return "Hold to talk + toggle shortcut"
        case .holdOnly: return "Hold to talk only"
        case .toggleOnly: return "Toggle shortcut only"
        }
    }
}

/// A keyboard shortcut like ⌃⌥Space, stored as a key code + Carbon modifier bits
/// (Carbon's RegisterEventHotKey is the classic macOS API for global shortcuts and
/// needs no special permission).
struct Shortcut: Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var label: String

    static let defaultToggle = Shortcut(keyCode: UInt32(kVK_Space),
                                        carbonModifiers: UInt32(controlKey | optionKey), label: "⌃⌥Space")

    static func carbon(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    static func symbols(_ flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }

    /// A readable name for the key in a key-down event.
    static func keyName(_ event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Escape: return "Esc"
        case kVK_Delete: return "Delete"
        default:
            return (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
    }
}

enum DictationSettings {
    static var defaults: UserDefaults { .standard }

    static var holdKey: HoldKey { HoldKey(rawValue: defaults.string(forKey: "holdKey") ?? "") ?? .rightOption }
    static var mode: DictationMode { DictationMode(rawValue: defaults.string(forKey: "dictationMode") ?? "") ?? .both }
    static var aiCleanup: Bool { defaults.object(forKey: "aiCleanup") as? Bool ?? true }
    static var removeFillers: Bool { defaults.object(forKey: "removeFillers") as? Bool ?? true }
    static var restoreClipboard: Bool { defaults.object(forKey: "restoreClipboard") as? Bool ?? true }
    static var trailingSpace: Bool { defaults.object(forKey: "trailingSpace") as? Bool ?? true }
    static var sounds: Bool { defaults.object(forKey: "dictationSounds") as? Bool ?? true }

    static var toggleShortcut: Shortcut? {
        get {
            if defaults.bool(forKey: "toggleDisabled") { return nil }
            guard defaults.object(forKey: "toggleKeyCode") != nil else { return .defaultToggle }
            return Shortcut(keyCode: UInt32(defaults.integer(forKey: "toggleKeyCode")),
                            carbonModifiers: UInt32(defaults.integer(forKey: "toggleModifiers")),
                            label: defaults.string(forKey: "toggleLabel") ?? "?")
        }
        set {
            if let s = newValue {
                defaults.set(false, forKey: "toggleDisabled")
                defaults.set(Int(s.keyCode), forKey: "toggleKeyCode")
                defaults.set(Int(s.carbonModifiers), forKey: "toggleModifiers")
                defaults.set(s.label, forKey: "toggleLabel")
            } else {
                defaults.set(true, forKey: "toggleDisabled")
            }
        }
    }
}
