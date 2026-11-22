// SettingsView.swift
// Scribe > Settings… (⌘,). Five tabs: Dictation, Model, Permissions, General, About.

import SwiftUI
import AppKit
import ServiceManagement
import AVFoundation

struct SettingsView: View {
    var body: some View {
        TabView {
            DictationSettingsTab().tabItem { Label("Dictation", systemImage: "mic") }
            ModelSettingsTab().tabItem { Label("Model", systemImage: "cpu") }
            PermissionsTab().tabItem { Label("Permissions", systemImage: "lock.shield") }
            GeneralSettingsTab().tabItem { Label("General", systemImage: "gearshape") }
            AboutView().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 440)
    }
}

// MARK: - Dictation

struct DictationSettingsTab: View {
    @EnvironmentObject var dictation: DictationController
    @AppStorage("holdKey") private var holdKey = HoldKey.rightOption.rawValue
    @AppStorage("dictationMode") private var mode = DictationMode.both.rawValue
    @AppStorage("aiCleanup") private var aiCleanup = true
    @AppStorage("removeFillers") private var removeFillers = true
    @AppStorage("restoreClipboard") private var restoreClipboard = true
    @AppStorage("trailingSpace") private var trailingSpace = true
    @AppStorage("dictationSounds") private var sounds = true

    var body: some View {
        Form {
            Section("Shortcuts") {
                Picker("Mode", selection: $mode) {
                    ForEach(DictationMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("Hold to talk", selection: $holdKey) {
                    ForEach(HoldKey.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .disabled(mode == DictationMode.toggleOnly.rawValue)
                LabeledContent("Toggle (press, talk, press again)") {
                    ShortcutRecorder { dictation.hotkeys.reload() }
                }
                .disabled(mode == DictationMode.holdOnly.rawValue)
                Text("Press Esc while talking to cancel. A quick tap of the hold key does nothing, and so does using it in a shortcut like ⌥← .")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Clean-up") {
                Toggle("Remove “um” and “uh”", isOn: $removeFillers)
                Toggle("Polish with Apple Intelligence (on-device)", isOn: $aiCleanup)
                Text(AppleIntelligence.statusText + ". Fixes punctuation, false starts and “no wait, I mean…”. If it's off or unavailable, the simple rules above are used.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Typing") {
                Toggle("Add a space after the text", isOn: $trailingSpace)
                Toggle("Put my clipboard back after pasting", isOn: $restoreClipboard)
                Toggle("Play start/stop sounds", isOn: $sounds)
            }
        }
        .formStyle(.grouped)
        .onChange(of: holdKey) { _, _ in dictation.hotkeys.reload() }
        .onChange(of: mode) { _, _ in dictation.hotkeys.reload() }
    }
}

/// Click, then press the shortcut you want (it must include ⌃, ⌥ or ⌘).
struct ShortcutRecorder: View {
    var onChange: () -> Void
    @State private var recording = false
    @State private var label = DictationSettings.toggleShortcut?.label ?? "None"
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Button(recording ? "Press keys…" : label) { if recording { stop() } else { start() } }
                .frame(minWidth: 110)
            if !recording, DictationSettings.toggleShortcut != nil {
                Button { DictationSettings.toggleShortcut = nil; label = "None"; onChange() } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Turn the toggle shortcut off")
            }
        }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == 53 { stop(); return nil }                         // Esc = cancel
            guard !mods.intersection([.command, .option, .control]).isEmpty else { return nil }
            let s = Shortcut(keyCode: UInt32(event.keyCode), carbonModifiers: Shortcut.carbon(from: mods),
                             label: Shortcut.symbols(mods) + Shortcut.keyName(event))
            DictationSettings.toggleShortcut = s
            label = s.label
            stop()
            onChange()
            return nil   // swallow the key so it doesn't type anything
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }
}

// MARK: - Model

struct ModelSettingsTab: View {
    @EnvironmentObject var store: Store
    @AppStorage("speechModel") private var speechModel = SpeechModel.english.rawValue
    @AppStorage("aiNotes") private var aiNotes = true

    var body: some View {
        Form {
            Section("Speech to text") {
                Picker("Model", selection: $speechModel) {
                    ForEach(SpeechModel.allCases) { m in
                        VStack(alignment: .leading) {
                            Text(m.title)
                            Text(m.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(m.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
                HStack {
                    if store.engineReady {
                        Label("Loaded and working offline", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if let e = store.engineError {
                        Text(e).foregroundStyle(.orange)
                    } else {
                        ProgressView(value: store.modelProgress ?? 0).frame(width: 120)
                        Text(store.engineStatus)
                    }
                }
                .font(.caption)
                Text("Runs on this Mac's Neural Engine with Core ML. Downloads once (~500 MB), then works with no internet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ModelComponentsList()
            } header: {
                Text("Downloaded models")
            } footer: {
                Text("Models live outside the app (in Application Support), so updating or reinstalling Scribe never downloads them again. Only missing or changed files are fetched. Verify re-checks every byte.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Meeting notes") {
                Toggle("Write notes with Apple Intelligence (on-device)", isOn: $aiNotes)
                Text(AppleIntelligence.statusText + ". Otherwise Scribe picks key sentences and action items from the transcript itself.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: speechModel) { _, _ in Task { await store.prepareEngine() } }
    }
}

/// One row per model component: status (Downloaded / Update available / Missing…) + Verify.
struct ModelComponentsList: View {
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var store: Store

    var body: some View {
        if models.components.isEmpty {
            Text("No model manifest in this build — FluidAudio downloads models itself.").font(.caption)
        }
        ForEach(models.components) { c in
            let state = models.states[c.id] ?? .missing
            HStack(spacing: 10) {
                Image(systemName: icon(state)).foregroundStyle(color(state)).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.title)
                    Text("\(state.label) · \(ModelStore.mb(c.totalBytes)) · version \(c.version)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                switch state {
                case .downloading, .verifying:
                    ProgressView().controlSize(.small)
                case .downloaded:
                    Button("Verify") { Task { await models.verify(c.id) } }
                default:
                    Button("Download") { Task { try? await models.ensure([c.id]) } }
                }
            }
        }
        HStack {
            Spacer()
            Button("Re-check") { models.refresh() }
        }
    }

    private func icon(_ s: ModelState) -> String {
        switch s {
        case .downloaded: return "checkmark.circle.fill"
        case .updateAvailable: return "arrow.down.circle"
        case .downloading: return "arrow.down.circle.dotted"
        case .verifying: return "magnifyingglass.circle"
        case .damaged, .failed: return "exclamationmark.triangle.fill"
        case .missing, .partial: return "circle.dashed"
        }
    }

    private func color(_ s: ModelState) -> Color {
        switch s {
        case .downloaded: return .green
        case .updateAvailable, .downloading, .verifying: return .accentColor
        case .damaged, .failed: return .orange
        case .missing, .partial: return .secondary
        }
    }
}

// MARK: - Permissions

struct PermissionsTab: View {
    @EnvironmentObject var permissions: Permissions
    var body: some View {
        Form {
            PermissionRows()
            Text("Rebuilt or updated the app and dictation stopped pasting? macOS ties Accessibility to the exact app build. Remove Scribe from the Accessibility list with “–”, then add it again.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onAppear { permissions.startWatching() }
        .onDisappear { permissions.stopWatching() }
    }
}

/// Microphone + Accessibility rows with live status (shared by Settings and onboarding).
struct PermissionRows: View {
    @EnvironmentObject var permissions: Permissions
    var body: some View {
        PermissionRow(title: "Microphone", detail: "To hear you dictate and record meetings.",
                      granted: permissions.microphone == .authorized,
                      button: permissions.microphone == .notDetermined ? "Allow…" : "Open Settings") {
            Task { await permissions.requestMicrophone() }
        }
        PermissionRow(title: "Accessibility", detail: "To notice the hold key in other apps and paste your words for you. Turn Scribe on in the list.",
                      granted: permissions.accessibility, button: "Open Settings") {
            permissions.requestAccessibility()
        }
    }
}

struct PermissionRow: View {
    var title: String
    var detail: String
    var granted: Bool
    var button: String
    var action: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.title2)
                .foregroundStyle(granted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button(button, action: action) }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @AppStorage("noiseCleanup") private var noiseCleanup = true
    @AppStorage("onboarded") private var onboarded = true
    @AppStorage("showMeetingScroll") private var showMeetingScroll = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Toggle("Open Scribe when I log in", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
            if let e = loginError { Text(e).font(.caption).foregroundStyle(.orange) }
            Toggle("Noise cleanup for meetings (Apple voice processing)", isOn: $noiseCleanup)
            Toggle("Show the scroll at the bottom of the screen while a meeting records", isOn: $showMeetingScroll)
            Button("Show the welcome screen again") { onboarded = false }
            Section("Updates") {
                UpdateSection()
            }
        }
        .formStyle(.grouped)
    }

    /// SMAppService is Apple's modern "login item" API (macOS 13+).
    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "macOS said no: \(error.localizedDescription). You can add Scribe in System Settings → General → Login Items."
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// Settings → General → Updates.
struct UpdateSection: View {
    @EnvironmentObject var updater: Updater

    var body: some View {
        Toggle("Check for updates once a day", isOn: $updater.autoCheck)
        HStack {
            Text("This is Scribe \(Updater.currentVersion)").foregroundStyle(.secondary)
            Spacer()
            Button("Check for Updates…") { updater.check(userInitiated: true) }
                .disabled(updater.phase == .checking || updater.phase == .installing)
        }
        switch updater.phase {
        case .idle: EmptyView()
        case .checking: ProgressView().controlSize(.small)
        case .upToDate(let v): Label("You're up to date (\(v)).", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .available(let r):
            VStack(alignment: .leading, spacing: 6) {
                Text("Scribe \(r.version) is available — app download \(ModelStore.mb(r.zipBytes)).").font(.headline)
                Text(r.modelChanges.isEmpty ? "Models: no change (nothing else to download)."
                                            : "Models that changed: " + r.modelChanges.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
                Button("Download and Restart") { updater.install(r) }.buttonStyle(.borderedProminent)
            }
        case .downloading: HStack { ProgressView().controlSize(.small); Text("Downloading the app…") }
        case .installing: HStack { ProgressView().controlSize(.small); Text("Installing…") }
        case .failed(let e): Text(e).font(.caption).foregroundStyle(.orange)
        }
    }
}
