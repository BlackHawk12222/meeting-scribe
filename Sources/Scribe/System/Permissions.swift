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
import Security
import Darwin

@MainActor
final class Permissions: ObservableObject {
    @Published private(set) var microphone: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published private(set) var accessibility = AXIsProcessTrusted()
    /// 0.7.5: "System Audio Recording Only" (meetings also record the Mac's sound, e.g. a call).
    @Published private(set) var systemAudio: SystemAudioStatus = Permissions.systemAudioStatus()
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
        let sa = Self.systemAudioStatus()
        if sa != systemAudio { systemAudio = sa }
    }

    // MARK: System audio (Core Audio process tap, macOS 14.4+)

    enum SystemAudioStatus: String { case authorized, denied, notAsked, unknown, unsupported }

    /// macOS has no public "is system audio allowed?" call. TCC's own preflight (the one Apple's
    /// sample code uses) is looked up at run time; if it isn't there we say "unknown" and rely on
    /// the silence check while recording.
    nonisolated static func systemAudioStatus() -> SystemAudioStatus {
        guard #available(macOS 14.4, *) else { return .unsupported }
        typealias Fn = @convention(c) (CFString, CFDictionary?) -> Int
        guard let h = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_LAZY),
              let sym = dlsym(h, "TCCAccessPreflight") else { return .unknown }
        let r = unsafeBitCast(sym, to: Fn.self)("kTCCServiceAudioCapture" as CFString, nil)
        switch r {
        case 0: return .authorized
        case 1: return .denied
        case 2: return .notAsked
        default: return .unknown
        }
    }

    // MARK: Code identity (what macOS keys every permission to)
    //
    // 0.7.5: releases are signed with ONE self-signed certificate, so the designated requirement is
    // `identifier "com.blackhawk12222.Scribe" and certificate leaf = H"…"` in every build and macOS
    // keeps Microphone / Accessibility across updates. An ad-hoc build's requirement is its cdhash,
    // which changes every build → every permission resets. We log it at launch and remember it, so a
    // reset can be explained ("this build has a different signature") instead of guessed.

    struct CodeIdentity: Equatable {
        var designatedRequirement: String?
        var adHoc: Bool { designatedRequirement?.contains("cdhash") ?? true }
        var certificateLeaf: Bool { designatedRequirement?.contains("certificate leaf") ?? false }
    }

    nonisolated static func codeIdentity(of url: URL? = nil) -> CodeIdentity {
        var staticCode: SecStaticCode?
        if let url {
            SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        } else {
            var code: SecCode?
            if SecCodeCopySelf([], &code) == errSecSuccess, let code { SecCodeCopyStaticCode(code, [], &staticCode) }
        }
        guard let sc = staticCode else { return CodeIdentity(designatedRequirement: nil) }
        var req: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(sc, [], &req) == errSecSuccess, let req else { return CodeIdentity(designatedRequirement: nil) }
        var str: CFString?
        SecRequirementCopyString(req, [], &str)
        return CodeIdentity(designatedRequirement: str as String?)
    }

    static let lastRequirementKey = "lastDesignatedRequirement"
    /// True for this launch when the signature identity differs from the last launch's.
    private(set) static var identityChangedThisLaunch = false

    /// Once at launch: write what macOS will judge permissions by, and what they are right now.
    static func launchAudit() {
        let id = codeIdentity()
        let dr = id.designatedRequirement ?? "none"
        let last = UserDefaults.standard.string(forKey: lastRequirementKey)
        identityChangedThisLaunch = last != nil && last != dr
        UserDefaults.standard.set(dr, forKey: lastRequirementKey)
        let path = Bundle.main.bundleURL.path
        let quarantined = getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
        AppLog.log("launch \(currentBuild) path=\(path)\(Updater.isTranslocated(path) ? " TRANSLOCATED" : "")\(quarantined ? " quarantined" : "")")
        AppLog.log("signature: \(id.adHoc ? "AD-HOC (permissions reset every build)" : id.certificateLeaf ? "stable certificate" : "other") designated => \(dr)")
        if identityChangedThisLaunch { AppLog.log("signature CHANGED since last launch (was: \(last ?? "?")) → macOS asks for permissions again") }
        AppLog.log("permissions: microphone=\(micName(AVCaptureDevice.authorizationStatus(for: .audio))) accessibility=\(AXIsProcessTrusted()) systemAudio=\(systemAudioStatus().rawValue) inputMonitoring=\(CGPreflightListenEventAccess())")
    }

    nonisolated static func micName(_ s: AVAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    static var accessibilityGranted: Bool {
        let ax = AXIsProcessTrusted()
        if ax { noteTrusted() }
        return ax
    }

    // MARK: Accessibility after an update
    //
    // Ad-hoc builds (and the first update from one to a certificate-signed build) change Scribe's
    // identity, so the Accessibility switch can still LOOK on while macOS answers "not trusted".
    // The fix then: remove Scribe from the list (–) and add it again (+). 0.7.5: only blamed on an
    // update when the signature really changed (identityChangedThisLaunch).

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
        if identityChangedThisLaunch { return true }
        if codeIdentity().adHoc, let b = UserDefaults.standard.string(forKey: trustedBuildKey) { return b != currentBuild }
        return false
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
        /// "Screen & System Audio Recording" (its "System Audio Recording Only" list).
        case systemAudio = "Privacy_ScreenCapture"
    }

    static func open(_ pane: Pane) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }
}
