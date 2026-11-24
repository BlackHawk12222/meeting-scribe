// SettingsView.swift
// Scribe > Settings… (⌘,). Tabs: Dictation, Vocabulary, Model, Permissions, General, Sync, About.

import SwiftUI
import AppKit
import ServiceManagement
import AVFoundation

struct SettingsView: View {
    var body: some View {
        TabView {
            DictationSettingsTab().tabItem { Label("Dictation", systemImage: "mic") }
            VocabularySettingsTab().tabItem { Label("Vocabulary", systemImage: "character.book.closed") }
            ModelSettingsTab().tabItem { Label("Model", systemImage: "cpu") }
            PermissionsTab().tabItem { Label("Permissions", systemImage: "lock.shield") }
            GeneralSettingsTab().tabItem { Label("General", systemImage: "gearshape") }
            SyncSettingsTab().tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
            AboutView().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: SettingsView.size.width, height: SettingsView.size.height)
    }
    static let size = CGSize(width: 560, height: 500)
}

extension View {
    /// Settings panes: grouped form on the warm canvas.
    func scribeForm() -> some View {
        self.formStyle(.grouped).scrollContentBackground(.hidden).background(Warm.canvas)
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
    @AppStorage("directInsert") private var directInsert = true
    @AppStorage("dictationSounds") private var sounds = true
    @AppStorage("pauseWhileThinking") private var pauseWhileThinking = true
    @AppStorage(OverlayPosition.key) private var overlayPosition = OverlayPosition.bottomCenter.rawValue
    @State private var hasDragged = false

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
            Section {
                Picker("Position", selection: $overlayPosition) {
                    ForEach(OverlayPosition.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .onChange(of: overlayPosition) { _, _ in OverlayPosition.clearDragged(); hasDragged = false }
                OverlayPositionPreview(position: OverlayPosition(rawValue: overlayPosition) ?? .bottomCenter)
                if hasDragged {
                    LabeledContent("Dragged to a custom spot") {
                        Button("Reset") { OverlayPosition.clearDragged(); hasDragged = false }
                    }
                }
            } header: {
                Text("Overlay")
            } footer: {
                Text("The small recording indicator appears on the screen you're working on, clear of the menu bar and Dock. Drag it to move it; Scribe remembers the spot for each display.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("I pause while thinking", isOn: $pauseWhileThinking)
            } header: {
                Text("Pauses")
            } footer: {
                Text("On: a pause has to last over a second before Scribe treats it as a break, and everything you say in one go is written in a single pass, so thinking pauses don't add periods or capitals mid-sentence.")
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
                Toggle("Type straight into the text field when possible (no clipboard)", isOn: $directInsert)
                Toggle("Put my clipboard back after pasting", isOn: $restoreClipboard)
                Toggle("Play start/stop sounds", isOn: $sounds)
            }
        }
        .scribeForm()
        .onAppear { hasDragged = OverlayPosition.hasDragged }
        .onChange(of: holdKey) { _, _ in dictation.hotkeys.reload() }
        .onChange(of: mode) { _, _ in dictation.hotkeys.reload() }
    }
}

/// A tiny screen diagram showing where the overlay will appear.
struct OverlayPositionPreview: View {
    var position: OverlayPosition
    var body: some View {
        HStack {
            Spacer()
            ZStack(alignment: alignment) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Warm.well)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Warm.hairline, lineWidth: 1))
                // Menu bar and Dock, so the safe areas read at a glance.
                VStack(spacing: 0) {
                    UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.08)).frame(height: 7)
                    Spacer()
                    RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.10)).frame(width: 60, height: 6).padding(.bottom, 3)
                }
                Capsule().fill(Color(white: 0.16).opacity(0.85))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5))
                    .frame(width: 30, height: 8)
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                    .padding(.horizontal, 8)
                    .padding(.top, 12)
                    .padding(.bottom, 13)
            }
            .frame(width: 160, height: 96)
            .animation(.easeInOut(duration: 0.2), value: position)
            .accessibilityLabel("Overlay preview: \(position.title)")
            Spacer()
        }
    }
    private var alignment: Alignment {
        switch position {
        case .bottomCenter: return .bottom
        case .topCenter: return .top
        case .topLeft: return .topLeading
        case .topRight: return .topTrailing
        case .bottomLeft: return .bottomLeading
        case .bottomRight: return .bottomTrailing
        }
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

// MARK: - Vocabulary

/// Settings › Vocabulary: words Scribe should spell your way.
struct VocabularySettingsTab: View {
    @EnvironmentObject var store: Store
    @State private var words: [String] = Vocabulary.words
    @State private var newWord = ""
    @State private var selection: String?
    @AppStorage(Vocabulary.boostKey) private var acoustic = false

    var body: some View {
        Form {
            Section {
                List(selection: $selection) {
                    ForEach(words, id: \.self) { w in Text(w).tag(w) }
                        .onDelete { words.remove(atOffsets: $0); save() }
                }
                .frame(minHeight: 170)
                HStack {
                    TextField("Add a word or name", text: $newWord)
                        .onSubmit(add)
                    Button("Add", action: add).disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Remove") {
                        if let s = selection { words.removeAll { $0 == s }; selection = nil; save() }
                    }
                    .disabled(selection == nil)
                }
            } header: {
                Text("Your words")
            } footer: {
                Text("Names, apps and terms you use. Scribe spells them your way: “on shape” → Onshape, “swift ui” → SwiftUI, “v five” → V5. Close misspellings of longer words are fixed only when they aren't real English words.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Also match against the audio", isOn: $acoustic)
                if acoustic, !store.vocabularyBoostStatus.isEmpty {
                    Text(store.vocabularyBoostStatus).font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Uses a small extra model (about 100 MB, downloaded once) to check your words against how they sounded, so misheard names can be fixed even when the spelling is far off. Off by default: it can sometimes swap an ordinary word for one of yours.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Restore Defaults") { words = Vocabulary.defaults; save() }
            }
        }
        .scribeForm()
        .onChange(of: acoustic) { _, _ in Task { await store.prepareVocabularyBoost() } }
    }

    private func add() {
        let w = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !words.contains(where: { $0.caseInsensitiveCompare(w) == .orderedSame }) else { newWord = ""; return }
        words.append(w)
        newWord = ""
        save()
    }

    private func save() {
        Vocabulary.words = words
        Task { await store.prepareVocabularyBoost() }
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
                    ForEach(SpeechModel.choices) { m in
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
        .scribeForm()
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
        ForEach(models.components.filter { models.isRelevant($0) }) { c in
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
    @ObservedObject private var pasteLog = PasteLog.shared
    @State private var testing = false
    @State private var testResult: TypingTest.Result?

    var body: some View {
        Form {
            Section {
                AccessibilityBanner(permissions: permissions)
                PermissionRows()
            }
            Section {
                HStack {
                    Button(testing ? "Testing…" : "Test typing into TextEdit") {
                        testing = true
                        Task {
                            testResult = await TypingTest.run()
                            testing = false
                            NSApp.activate(ignoringOtherApps: true)
                        }
                    }
                    .disabled(testing)
                    if let r = testResult {
                        Image(systemName: r.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(r.ok ? .green : .orange)
                    }
                }
                if let r = testResult { Text(r.message).font(.caption).foregroundStyle(.secondary) }
                if let last = pasteLog.last {
                    LabeledContent("Last dictation") {
                        Text(last.line).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            } header: {
                Text("Typing")
            } footer: {
                Text("The test opens an empty TextEdit document and types one line the same way a dictation does.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Reset Accessibility (after every update)") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("1. Open System Settings › Privacy & Security › Accessibility.")
                    Text("2. Select Scribe and click –. It's fine if its switch looked on.")
                    Text("3. Click +, choose Scribe in Applications, and turn it on.")
                    Text("Scribe builds aren't signed with a paid Apple certificate, so macOS sees each update as a new app and quietly stops trusting the old entry.")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                HStack {
                    Button("Open Accessibility Settings") { AccessibilityHelp.fix() }
                    Button("Show Scribe in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                }
            }
        }
        .scribeForm()
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
            Toggle("Show the recording indicator while a meeting records", isOn: $showMeetingScroll)
            Button("Show the welcome screen again") { onboarded = false }
            Section("Updates") {
                UpdateSection()
            }
        }
        .scribeForm()
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
        Toggle("Update automatically", isOn: $updater.autoCheck)
        Text("Checks when Scribe opens and every 6 hours, downloads in the background, and installs when you restart or quit. Never during a recording. Models only download again if they changed.")
            .font(.caption).foregroundStyle(.secondary)
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
                Button("Download and Restart") { updater.install(r) }.scribeButton(prominent: true)
            }
        case .downloading: HStack { ProgressView().controlSize(.small); Text("Downloading the app…") }
        case .ready(let r):
            HStack {
                Label("Scribe \(r.version) is ready.", systemImage: "arrow.down.circle.fill")
                Spacer()
                Button("Restart Now") { updater.restartNow() }.scribeButton(prominent: true)
            }
        case .installing: HStack { ProgressView().controlSize(.small); Text("Installing…") }
        case .failed(let e): Text(e).font(.caption).foregroundStyle(.orange)
        }
    }
}

// MARK: - Sync (GitHub)

struct SyncSettingsTab: View {
    @ObservedObject private var sync = GitHubSync.shared
    @State private var tokenField = ""
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Notes repo") {
                    TextField("owner/name", text: $sync.repo).frame(width: 240)
                }
                if sync.hasToken {
                    LabeledContent("Token") {
                        HStack {
                            Text("Saved in Keychain").foregroundStyle(.secondary)
                            Button("Remove") { sync.setToken(nil) }
                        }
                    }
                } else {
                    LabeledContent("Token") {
                        HStack {
                            SecureField("github_pat_…", text: $tokenField).frame(width: 200)
                            Button("Save") { sync.setToken(tokenField); tokenField = "" }
                                .disabled(tokenField.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                HStack {
                    Button(testing ? "Testing…" : "Test connection") {
                        testing = true
                        Task { testResult = await sync.testConnection(); testing = false }
                    }
                    .disabled(!sync.hasToken || testing)
                    if let r = testResult { Text(r).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                }
            } header: {
                Text("Save to GitHub")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Every dictation (dictations/YYYY-MM-DD.md) and every meeting's notes (meetings/…md) are saved as Markdown in this PRIVATE repo — not the app's code repo. Nothing waits for GitHub: items queue up and send in the background, also after being offline.")
                    Link("1. Create the private repo “scribe-notes”", destination: URL(string: "https://github.com/new?name=scribe-notes&visibility=private")!)
                    Link("2. Create a fine-grained token (only that repo, Contents: Read and write)", destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("What to save") {
                Toggle("Dictations", isOn: $sync.syncDictations)
                Toggle("Meeting notes", isOn: $sync.syncMeetings)
            }
            Section("Status") {
                HStack {
                    Text(statusText)
                    Spacer()
                    Text("\(sync.pending) waiting").foregroundStyle(.secondary)
                    Button("Send now") { sync.kick() }.disabled(!sync.hasToken || sync.pending == 0)
                }
            }
        }
        .scribeForm()
    }

    private var statusText: String {
        switch sync.status {
        case .off: return "Off — add a token to start"
        case .idle(let d): return d.map { "Last saved \($0.formatted(date: .omitted, time: .shortened))" } ?? "Ready"
        case .syncing: return "Saving…"
        case .waiting(let m): return m
        case .problem(let m): return "⚠︎ " + m
        }
    }
}
