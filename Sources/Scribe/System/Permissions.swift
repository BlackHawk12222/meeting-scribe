// Permissions.swift
// The two macOS permissions Scribe needs, how to check them, and how to open the
// right page of System Settings.
//
//  • Microphone — to hear you. macOS shows its own "Allow?" pop-up the first time.
//  • Accessibility — to (a) notice the hold key while you're in other apps and
//    (b) press ⌘V for you. There's no pop-up you can click "Allow" on: you have to
//    switch Scribe on in System Settings > Privacy & Security > Accessibility.

import AppKit
import AVFoundation
import ApplicationServices
import Combine

@MainActor
final class Permissions: ObservableObject {
    @Published private(set) var microphone: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published private(set) var accessibility = AXIsProcessTrusted()
    private var timer: Timer?

    /// Live status: check every second while a screen that shows permissions is open.
    func startWatching() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        if mic != microphone { microphone = mic }
        let ax = AXIsProcessTrusted()
        if ax != accessibility { accessibility = ax }
        if ax { Self.noteTrusted() }
    }

    static var accessibilityGranted: Bool {
        let ax = AXIsProcessTrusted()
        if ax { noteTrusted() }
        return ax
    }

    // MARK: Accessibility after an update
    //
    // Scribe is ad-hoc signed (no paid Apple developer certificate), so macOS identifies it by
    // the exact build. After an update the Accessibility switch can still LOOK on while macOS
    // answers "not trusted". The only fix: remove Scribe from the list (–) and add it again (+).
    // We remember which build last had the permission, to explain this instead of "turn it on".

    static let trustedBuildKey = "axTrustedBuild"
    static var currentBuild: String {
        let i = Bundle.main.infoDictionary
        return "\(i?["CFBundleShortVersionString"] as? String ?? "?") (\(i?["CFBundleVersion"] as? String ?? "?"))"
    }
    static func noteTrusted() {
        if UserDefaults.standard.string(forKey: trustedBuildKey) != currentBuild {
            UserDefaults.standard.set(currentBuild, forKey: trustedBuildKey)
        }
    }
    /// Not trusted now, but an earlier build (or a previous install that finished the welcome
    /// screen) was set up → almost certainly the "stale switch after update" case.
    static var likelyResetByUpdate: Bool {
        guard !AXIsProcessTrusted() else { return false }
        if let b = UserDefaults.standard.string(forKey: trustedBuildKey) { return b != currentBuild }
        return UserDefaults.standard.bool(forKey: "onboarded")
    }
    static var microphoneGranted: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    /// Shows the macOS pop-up the first time; afterwards opens System Settings.
    func requestMicrophone() async {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .authorized: break
        default: Self.open(.microphone)
        }
        refresh()
    }

    /// Adds Scribe to the Accessibility list (switched off) and opens that settings page.
    func requestAccessibility() {
        // "AXTrustedCheckOptionPrompt" = kAXTrustedCheckOptionPrompt: show the system hint.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        Self.open(.accessibility)
        refresh()
    }

    enum Pane: String {
        case microphone = "Privacy_Microphone"
        case accessibility = "Privacy_Accessibility"
    }

    static func open(_ pane: Pane) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }
}
