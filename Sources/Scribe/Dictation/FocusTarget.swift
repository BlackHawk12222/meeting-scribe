// FocusTarget.swift
// Remembers WHERE your words should go, at the moment you start talking.
//
// 0.4 asked macOS "which app is in front?" only when the text was ready. If anything had
// changed focus in between (you clicked the menu bar's "Start dictation", which brings Scribe
// forward; a notification; the Scribe window) the paste went to the wrong place or nowhere.
// 0.5 captures the app AND its focused text element when you press the key, and TextInserter
// puts focus back there before typing.

import AppKit
import ApplicationServices
import os

/// Is the focused thing a place you can type?
enum Editability: String, Sendable {
    case yes, no, unknown

    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    /// Focused things that are clearly NOT text boxes (lists, buttons, the desktop…).
    static let nonTextRoles: Set<String> = [
        "AXButton", "AXList", "AXOutline", "AXTable", "AXRow", "AXCell", "AXImage", "AXWindow",
        "AXStaticText", "AXCheckBox", "AXRadioButton", "AXMenuItem", "AXMenuBar", "AXMenuBarItem",
        "AXToolbar", "AXSplitGroup", "AXBrowser", "AXColumn", "AXSlider", "AXPopUpButton", "AXTabGroup",
        "AXDisclosureTriangle", "AXProgressIndicator", "AXApplication",
    ]

    /// Pure decision (unit-tested in the self-test). Unknown = we can't tell (Electron/web apps
    /// often hide their text boxes from Accessibility), so Scribe pastes anyway.
    static func classify(role: String?, selectedTextSettable: Bool, valueSettable: Bool,
                         hasEditableAncestor: Bool) -> Editability {
        guard let role else { return .unknown }
        if textRoles.contains(role) || selectedTextSettable || hasEditableAncestor { return .yes }
        if valueSettable, !nonTextRoles.contains(role) { return .yes }
        if nonTextRoles.contains(role) { return .no }
        return .unknown
    }
}

struct FocusTarget {
    let pid: pid_t
    let bundleID: String?
    let appName: String
    /// The focused UI element when you started (nil without Accessibility, or if the app hides it).
    let element: AXUIElement?
    let role: String?
    let editable: Editability

    var app: NSRunningApplication? { NSRunningApplication(processIdentifier: pid) }
    var summary: String { "\(appName) [\(bundleID ?? "?")] role=\(role ?? "none") editable=\(editable.rawValue)" }
}

@MainActor
enum FocusTracker {
    static let log = Logger(subsystem: "com.blackhawk12222.Scribe", category: "paste")
    /// The last app other than Scribe that was in front (for when Scribe itself is in front).
    private(set) static var lastExternal: NSRunningApplication?
    private static var observer: NSObjectProtocol?

    static func start() {
        guard observer == nil else { return }
        if let f = NSWorkspace.shared.frontmostApplication, !isSelf(f) { lastExternal = f }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app, !isSelf(app) { lastExternal = app }
            }
        }
    }

    static func isSelf(_ app: NSRunningApplication) -> Bool {
        app.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    /// Where the text should go: the frontmost app, or (if that's Scribe) the app you were in before.
    static func targetApp() -> NSRunningApplication? {
        if let f = NSWorkspace.shared.frontmostApplication, !isSelf(f) { return f }
        if let l = lastExternal, !l.isTerminated { return l }
        return nil
    }

    static func capture() -> FocusTarget? {
        guard let app = targetApp() else { return nil }
        let pid = app.processIdentifier
        var element: AXUIElement?
        var role: String?
        var editable = Editability.unknown
        if AXIsProcessTrusted() {
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, 0.25)          // never hang on a busy app
            var focused: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
               let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID() {
                let el = f as! AXUIElement
                AXUIElementSetMessagingTimeout(el, 0.25)
                element = el
                role = stringAttr(el, kAXRoleAttribute)
                editable = Editability.classify(role: role,
                                                selectedTextSettable: settable(el, kAXSelectedTextAttribute),
                                                valueSettable: settable(el, kAXValueAttribute),
                                                hasEditableAncestor: hasAttr(el, "AXEditableAncestor"))
            }
        }
        let t = FocusTarget(pid: pid, bundleID: app.bundleIdentifier, appName: app.localizedName ?? "app",
                            element: element, role: role, editable: editable)
        log.info("target captured: \(t.summary, privacy: .public)")
        return t
    }

    // MARK: AX helpers (nonisolated: safe to call off the main thread)

    nonisolated static func stringAttr(_ el: AXUIElement, _ name: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? String
    }

    nonisolated static func settable(_ el: AXUIElement, _ name: String) -> Bool {
        var s = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(el, name as CFString, &s) == .success && s.boolValue
    }

    nonisolated static func hasAttr(_ el: AXUIElement, _ name: String) -> Bool {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success && v != nil
    }
}
