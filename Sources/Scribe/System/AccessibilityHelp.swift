// AccessibilityHelp.swift
// "Scribe needs Accessibility to type — Fix": the banner (menu bar, capsule, Settings) and the
// small help window that the Fix button opens next to System Settings.

import AppKit
import SwiftUI
import AVFoundation

@MainActor
enum AccessibilityHelp {
    private static var window: NSWindow?

    static var headline: String { "Scribe needs Accessibility to type" }
    static var explanation: String {
        Permissions.likelyResetByUpdate
            ? "This copy of Scribe has a different signature than the last one, so macOS turned off its permission to type — even if the switch still looks on."
            : "Without it, Scribe can only copy your words; you'd press ⌘V yourself."
    }

    /// Opens Privacy & Security › Accessibility and the step-by-step help window.
    static func fix() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)          // adds Scribe to the list if it's missing
        Permissions.open(.accessibility)
        show()
    }

    static func show() {
        if window == nil {
            let host = NSHostingView(rootView: AccessibilityHelpView())
            let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 330),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
            w.title = "Turn on typing for Scribe"
            w.isReleasedWhenClosed = false
            w.level = .floating
            w.hidesOnDeactivate = false
            w.contentView = host
            w.center()
            window = w
        }
        window?.orderFrontRegardless()
    }

    static func close() { window?.orderOut(nil) }

    /// Once per build at launch: if typing (or the microphone) is ACTUALLY off — checked live, not a
    /// stored flag — open the help by itself. Nothing shows when both are on.
    static func showAtLaunchIfNeeded() {
        let micOff = AVCaptureDevice.authorizationStatus(for: .audio) == .denied
        guard UserDefaults.standard.bool(forKey: "onboarded"), !AXIsProcessTrusted() || micOff else { return }
        let key = "axHelpShownFor"
        guard UserDefaults.standard.string(forKey: key) != Permissions.currentBuild else { return }
        UserDefaults.standard.set(Permissions.currentBuild, forKey: key)
        show()
    }
}

/// Steps + live status. Closes itself a moment after the permission works.
struct AccessibilityHelpView: View {
    @StateObject private var permissions = Permissions()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: permissions.accessibility ? "checkmark.circle.fill" : "keyboard.badge.ellipsis")
                    .font(.title).foregroundStyle(permissions.accessibility ? Color.green : Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(permissions.accessibility ? "Typing is on" : AccessibilityHelp.headline).font(.headline)
                    Text(permissions.accessibility ? "Scribe can paste into the text box you're in."
                                                   : AccessibilityHelp.explanation)
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if permissions.microphone == .denied || permissions.microphone == .restricted {
                HStack(spacing: 8) {
                    Image(systemName: "mic.slash.fill").foregroundStyle(.orange)
                    Text("The microphone is off for Scribe, so dictation and meetings record silence.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Open Microphone Settings") { Permissions.open(.microphone) }.controlSize(.small)
                }
            }
            if !permissions.accessibility {
                VStack(alignment: .leading, spacing: 6) {
                    step(1, "In System Settings › Privacy & Security › Accessibility, select Scribe and click –.")
                    step(2, "Click +, choose Scribe in Applications, and make sure its switch is on.")
                    step(3, "Come back — this window turns green by itself.")
                }
                Text("Scribe 0.7.5 and later keep the same signature in every update, so macOS should remember this from now on.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open Accessibility Settings") { Permissions.open(.accessibility) }
                        .buttonStyle(.borderedProminent)
                    Button("Show Scribe in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                    }
                }
            } else {
                Button("Done") { AccessibilityHelp.close() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 400)
        .onAppear { permissions.startWatching() }
        .onDisappear { permissions.stopWatching() }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.caption.weight(.bold)).frame(width: 18, height: 18)
                .background(Circle().fill(Color.primary.opacity(0.08)))
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The compact banner used in the menu bar panel and Settings.
struct AccessibilityBanner: View {
    @ObservedObject var permissions: Permissions
    var body: some View {
        if !permissions.accessibility {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AccessibilityHelp.headline).font(.callout.weight(.semibold))
                    Text(Permissions.likelyResetByUpdate ? "After an update: remove Scribe from the list, then add it again."
                                                         : "Your words are copied instead of typed.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Button("Fix") { AccessibilityHelp.fix() }.controlSize(.small)
            }
            .padding(10)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}
