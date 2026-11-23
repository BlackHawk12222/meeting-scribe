// TextInserter.swift
// Types the dictated text into the text box you were in when you started talking.
//
// 0.5 order of attempts (each step logged under Console → "paste"):
//  0. No Accessibility permission → copy to the clipboard and say so ("needs Accessibility").
//     (macOS ties that permission to the exact app build. Scribe's builds are ad-hoc signed, so
//     every update looks like a NEW app: the switch in System Settings can still look ON while
//     macOS quietly says "not trusted". That made 0.4 copy instead of paste with only a 1-second
//     "Copied – press ⌘V" hint.)
//  1. The focused thing is clearly not a text box (a list, a button, the desktop) → copy and
//     say "Copied — no text box selected".
//  2. Bring the app you started in back to the front and re-focus its text box (clicking the
//     menu bar's Start button, or Scribe's own window, could have taken focus away).
//  3. Put the text straight into the text box through Accessibility (kAXSelectedText) and check
//     the box's value really changed. No clipboard involved.
//  4. Otherwise: clipboard + a real ⌘V (Command down, V down, V up, Command up). Sent to the
//     system event stream when the target app is in front, or straight to the target app's
//     process (CGEvent.postToPid) if macOS wouldn't bring it forward. Your old clipboard comes
//     back 600 ms later, only if nothing else touched it.

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import os

/// What happened on the last paste (Settings › Permissions shows it).
struct PasteReport: Sendable, Equatable {
    var outcome: TextInserter.Outcome
    var method: String
    var app: String
    var milliseconds: Int
    var verified: Bool?
    var date = Date()

    var line: String {
        let v = verified.map { $0 ? " · checked ✓" : " · not confirmed" } ?? ""
        return "\(method) → \(app) in \(milliseconds) ms\(v)"
    }
}

@MainActor
final class PasteLog: ObservableObject {
    static let shared = PasteLog()
    @Published var last: PasteReport?
}

@MainActor
enum TextInserter {
    enum Outcome: String, Sendable { case typedDirectly, pasted, copiedOnly, noTextBox, needsAccessibility }

    static let log = Logger(subsystem: "com.blackhawk12222.Scribe", category: "paste")

    /// Whether to try typing straight into the text field (no clipboard) first. Settings key "directInsert".
    static var directInsert: Bool { UserDefaults.standard.object(forKey: "directInsert") as? Bool ?? true }

    /// Insert `text` where `target` says (nil = whatever is in front now).
    /// `verify`: wait ~0.2 s after ⌘V and check the text box changed (Settings test, self-test).
    @discardableResult
    static func insert(_ text: String, target: FocusTarget? = nil, restoreClipboard: Bool,
                       verify: Bool = false) async -> PasteReport {
        let t0 = Date()
        let target = target ?? FocusTracker.capture()
        let appName = target?.appName ?? "front app"
        func report(_ o: Outcome, _ method: String, verified: Bool? = nil) -> PasteReport {
            let r = PasteReport(outcome: o, method: method, app: appName,
                                milliseconds: Int(Date().timeIntervalSince(t0) * 1000), verified: verified)
            log.info("paste method: \(method, privacy: .public) outcome=\(o.rawValue, privacy: .public) app=\(appName, privacy: .public) target=\(target?.summary ?? "none", privacy: .public) \(r.milliseconds)ms")
            PasteLog.shared.last = r
            return r
        }

        // 0) Accessibility off (or silently reset by an update): clipboard only.
        guard Permissions.accessibilityGranted else {
            _ = write(text, to: .general, transient: false)
            return report(.needsAccessibility, "copied (Accessibility is off)")
        }
        // 1) Clearly not a text box.
        if let target, target.editable == .no {
            _ = write(text, to: .general, transient: false)
            return report(.noTextBox, "copied (focused \(target.role ?? "item") is not a text box)")
        }
        // 2) Back to where you were.
        let inFront = await refocus(target)

        // 3) Straight into the text box.
        if directInsert, let target, let el = target.element, target.editable == .yes,
           !pasteOnlyApps.contains(target.bundleID ?? ""), insertViaAccessibility(text, into: el) {
            return report(.typedDirectly, "typed directly (Accessibility)", verified: true)
        }

        // 4) Clipboard + ⌘V.
        let before = target?.element.flatMap { valueOf($0) }
        let outcome = await paste(text, restoreClipboard: restoreClipboard,
                                  pid: inFront ? nil : target?.pid)
        guard outcome == .pasted else { return report(outcome, "copied (clipboard write failed)") }
        var verified: Bool?
        if verify, let el = target?.element {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if let after = valueOf(el) { verified = after != before && after.contains(text.trimmingCharacters(in: .whitespaces)) }
        }
        return report(.pasted, inFront ? "pasted (⌘V to the front app)" : "pasted (⌘V sent to the app's process)",
                      verified: verified)
    }

    /// Bring the target app forward and focus its text box. Returns whether it's in front.
    static func refocus(_ target: FocusTarget?) async -> Bool {
        guard let target, let app = target.app, !app.isTerminated else { return true }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.pid {
            log.info("refocus: bringing \(target.appName, privacy: .public) back to the front")
            app.activate()
            for _ in 0..<20 where NSWorkspace.shared.frontmostApplication?.processIdentifier != target.pid {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        if let el = target.element {
            // Ask the app to focus that element again (harmless if it already is).
            AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid
    }

    // MARK: Clipboard + ⌘V

    /// v0.2 bug ("it pasted my PREVIOUS dictation"): the old clipboard was put back 350 ms after
    /// ⌘V. Some apps read the clipboard later than that. So: write and CHECK the pasteboard
    /// holds the text before pressing ⌘V; restore only after 600 ms and only if untouched.
    /// `pid`: send ⌘V straight to that process instead of the system event stream.
    static func paste(_ text: String, restoreClipboard: Bool, pid: pid_t? = nil) async -> Outcome {
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        guard write(text, to: pb) else { return .copiedOnly }
        let ourChange = pb.changeCount

        guard Permissions.accessibilityGranted else { return .copiedOnly }

        // Wait until you've let go of ⌘/⌥/⌃/⇧, or our ⌘V would turn into e.g. ⌘⌥V.
        for _ in 0..<20 where !NSEvent.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        try? await Task.sleep(nanoseconds: 40_000_000)   // let the pasteboard server publish it
        // Still ours? (A clipboard manager or another app may have written in between.)
        if pb.changeCount != ourChange || pb.string(forType: .string) != text {
            guard write(text, to: pb) else { return .copiedOnly }
        }
        let pastedChange = pb.changeCount
        await pressCommandV(pid: pid)

        if restoreClipboard {
            let restore = saved
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                if pb.changeCount == pastedChange {
                    pb.clearContents()
                    if !restore.isEmpty { pb.writeObjects(restore) }
                }
            }
        }
        return .pasted
    }

    /// Copy every item, every format (text, images, files…) so it can be put back.
    static func snapshot(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    /// Put `text` on the pasteboard and confirm it's really there. With `transient`, two marker
    /// types ask clipboard-history apps (Raycast, Paste, Maccy…) not to save this temporary copy.
    @discardableResult
    static func write(_ text: String, to pb: NSPasteboard, transient: Bool = true) -> Bool {
        let before = pb.changeCount
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if transient {
            item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
            item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        }
        pb.writeObjects([item])
        return pb.changeCount != before && pb.string(forType: .string) == text
    }

    // MARK: Accessibility (direct)

    /// Apps whose text fields say "OK" to an Accessibility insert but ignore it, or handle it
    /// badly (browsers, Electron apps, terminals). They always get the ⌘V path.
    static let pasteOnlyApps: Set<String> = [
        "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "org.mozilla.firefox",
        "com.apple.Safari", "company.thebrowser.Browser", "com.tinyspeck.slackmacgap", "com.hnc.Discord",
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "notion.id", "com.figma.Desktop",
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.microsoft.teams2",
        "com.openai.chat", "md.obsidian", "com.spotify.client",
    ]

    nonisolated static func valueOf(_ el: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success else { return nil }
        return v as? String
    }

    /// Replace the selection (or insert at the cursor) in `element`. True only if the element's
    /// value afterwards actually changed and contains the new text (some apps answer "OK"
    /// without doing anything).
    nonisolated static func insertViaAccessibility(_ text: String, into element: AXUIElement) -> Bool {
        guard FocusTracker.settable(element, kAXSelectedTextAttribute) else { return false }
        guard let before = valueOf(element), before.count < 200_000 else { return false }   // huge docs: just paste
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success,
              let after = valueOf(element) else { return false }
        return after != before && after.contains(text)
    }

    /// The four key events of a real ⌘V. Pure (no posting), so the self-test can check them.
    nonisolated static func commandVEvents() -> [CGEvent] {
        let source = CGEventSource(stateID: .hidSystemState)
        let cmd = CGKeyCode(kVK_Command), v = CGKeyCode(kVK_ANSI_V)
        let specs: [(CGKeyCode, Bool, CGEventFlags)] = [
            (cmd, true, .maskCommand), (v, true, .maskCommand), (v, false, .maskCommand), (cmd, false, []),
        ]
        return specs.compactMap { key, down, flags in
            let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            e?.flags = flags
            return e
        }
    }

    /// Press ⌘V: to the system event stream (front app), or to one process.
    static func pressCommandV(pid: pid_t? = nil) async {
        for e in commandVEvents() {
            if let pid { e.postToPid(pid) } else { e.post(tap: .cghidEventTap) }
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
    }
}
