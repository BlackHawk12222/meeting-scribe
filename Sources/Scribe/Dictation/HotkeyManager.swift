// HotkeyManager.swift
// Listens for the dictation keys while you're in ANY app.
//
// Two different macOS APIs, because there are two kinds of keys:
//
//  • HOLD key (Right ⌥ by default) — a modifier key alone. Carbon hotkeys can't
//    see a modifier pressed by itself, so we watch "flags changed" events with
//    NSEvent.addGlobalMonitorForEvents. macOS only delivers other apps' key events
//    to us after you grant Accessibility (System Settings > Privacy & Security).
//
//  • TOGGLE shortcut (⌃⌥Space by default) — a normal key combo. We register it with
//    Carbon's RegisterEventHotKey, the classic API for global shortcuts. It works
//    even without Accessibility, and it "eats" the keystroke so the app in front
//    doesn't also receive it.
//
// This class only reports what happened; DictationController decides what to do.

import AppKit
import Carbon.HIToolbox

@MainActor
final class HotkeyManager {
    var onHoldStart: () -> Void = {}
    var onHoldEnd: (_ heldFor: TimeInterval) -> Void = { _ in }
    /// Another key was pressed while holding (you were using ⌥ for a shortcut, not to talk).
    var onHoldInterrupted: () -> Void = {}
    var onToggle: () -> Void = {}
    var onEscape: () -> Void = {}

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var holdStartedAt: Date?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var installedWithAccessibility = false
    private var axTimer: Timer?

    // Device-specific bits inside NSEvent.modifierFlags that tell LEFT from RIGHT keys
    // (from IOKit's NX_DEVICER*KEYMASK). `.option` alone would also fire for the left ⌥.
    private static let rightBits: [HoldKey: UInt] = [.rightOption: 0x40, .rightCommand: 0x10, .rightControl: 0x2000]

    func start() {
        installMonitors()
        registerToggle()
        // Key monitors only start receiving other apps' keys once Accessibility is granted.
        // Re-install them the moment that happens, so no relaunch is needed.
        axTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let trusted = Permissions.accessibilityGranted
                if trusted != self.installedWithAccessibility { self.installMonitors() }
            }
        }
    }

    /// Call after the user changes the hotkey settings.
    func reload() {
        installMonitors()
        registerToggle()
    }

    // MARK: - Hold key (NSEvent monitors)

    private func installMonitors() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        localMonitor = nil
        installedWithAccessibility = Permissions.accessibilityGranted

        // Global = events going to OTHER apps (we can watch, not block).
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            let info = KeyInfo(event)
            MainActor.assumeIsolated { self?.handle(info) }
        }
        // Local = events going to Scribe itself (when its window is in front).
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            let info = KeyInfo(event)
            MainActor.assumeIsolated { self?.handle(info) }
            return event
        }
    }

    /// The bits of an NSEvent we need, copied out so we don't hold on to the event.
    private struct KeyInfo {
        var isFlagsChanged: Bool
        var keyCode: UInt16
        var flags: NSEvent.ModifierFlags
        init(_ e: NSEvent) {
            isFlagsChanged = e.type == .flagsChanged
            keyCode = e.keyCode
            flags = e.modifierFlags
        }
    }

    private func handle(_ e: KeyInfo) {
        let key = DictationSettings.holdKey
        let mode = DictationSettings.mode

        if !e.isFlagsChanged {
            // A normal key was pressed.
            if e.keyCode == UInt16(kVK_Escape) { onEscape(); return }
            if holdStartedAt != nil {
                holdStartedAt = nil
                onHoldInterrupted()
            }
            return
        }

        guard key != .off, mode != .toggleOnly, let code = key.keyCode, e.keyCode == code else {
            // Some OTHER modifier changed while holding (e.g. ⌥ + ⇧): treat as a shortcut, not talking.
            if holdStartedAt != nil, e.keyCode != key.keyCode {
                holdStartedAt = nil
                onHoldInterrupted()
            }
            return
        }

        let isDown: Bool
        if let bit = Self.rightBits[key] {
            isDown = e.flags.rawValue & bit != 0
        } else {
            isDown = e.flags.contains(key.flag)
        }

        if isDown, holdStartedAt == nil {
            holdStartedAt = Date()
            onHoldStart()
        } else if !isDown, let started = holdStartedAt {
            holdStartedAt = nil
            onHoldEnd(Date().timeIntervalSince(started))
        }
    }

    // MARK: - Toggle shortcut (Carbon)

    private func registerToggle() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        guard DictationSettings.mode != .holdOnly, let shortcut = DictationSettings.toggleShortcut else { return }

        if handlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            // A C callback can't capture Swift variables, so we pass `self` through as a raw pointer.
            let me = Unmanaged.passUnretained(self).toOpaque()
            InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated { manager.onToggle() }
                return noErr
            }, 1, &spec, me, &handlerRef)
        }

        let id = EventHotKeyID(signature: OSType(0x5343_5242), id: 1) // 'SCRB'
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr { print("Couldn't register \(shortcut.label) (another app may use it): \(status)") }
    }
}
