// SettingsView.swift
// Settings (0.7 "Night Sky"): a rail destination in the main window, and the same view in the
// Scribe › Settings… (⌘,) window. No grouped Form: a section list on the left (a sparkle marks
// the selected one) and flat cards on the right, with Night toggles, segmented controls,
// pickers and fields. Panes: Dictation, Overlay, Vocabulary, Models, Permissions, General,
// Sync, About.

import SwiftUI
import AppKit
import ServiceManagement
import AVFoundation

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, dictation, meetings, vocabulary, models, updates
    /// 0.7.3.1: Settings › General › Credits & licenses (a sub-page; not in the section list).
    case credits

    /// The section list (Credits & licenses opens from General).
    static let sidebar: [SettingsPane] = [.general, .dictation, .meetings, .vocabulary, .models, .updates]
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "General"
        case .dictation: return "Dictation"
        case .meetings: return "Meetings"
        case .vocabulary: return "Vocabulary"
        case .models: return "Models"
        case .updates: return "Updates"
        case .credits: return "Credits & licenses"
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .dictation: return "mic"
        case .meetings: return "waveform"
        case .vocabulary: return "character.book.closed"
        case .models: return "cpu"
        case .updates: return "arrow.down.circle"
        case .credits: return "doc.text"
        }
    }
    var subtitle: String {
        switch self {
        case .general: return "How Scribe looks and starts."
        case .dictation: return "How you talk to type, and where the capsule sits."
        case .meetings: return "Recording, notes, and where they're saved."
        case .vocabulary: return "Words Scribe should spell your way."
        case .models: return "What runs on this Mac."
        case .updates: return "New versions, and who made what."
        case .credits: return "The models, code and fonts Scribe is built on, and their licenses."
        }
    }
}

/// The Settings window (⌘,): the same page as the main window's Settings destination.
struct SettingsView: View {
    var pane: SettingsPane = .general
    var body: some View {
        SettingsPage(initial: pane, inWindow: false)
            .frame(width: SettingsView.size.width, height: SettingsView.size.height)
    }
    static let size = CGSize(width: 900, height: 640)
}

/// 0.7.3 "Poster" Settings: a section list on the sidebar color (icon + name) and the pane on the
/// right with a big title, a one-line description and hairline-labeled groups of rows.
struct SettingsPage: View {
    @State private var pane: SettingsPane
    var inWindow: Bool

    init(initial: SettingsPane = .general, inWindow: Bool = true) {
        _pane = State(initialValue: initial)
        self.inWindow = inWindow
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsPane.sidebar) { p in
                    NightSidebarItem(title: p.title, symbol: p.symbol,
                                     selected: p == pane || (pane == .credits && p == .general)) { pane = p }
                }
                Spacer(minLength: 0)
                Text("Scribe \(Updater.currentVersion)").font(.nightMeta).foregroundStyle(Night.text3)
                    .padding(.horizontal, Night.s12)
            }
            .padding(.horizontal, 12)
            .padding(.top, inWindow ? 16 : 52)
            .padding(.bottom, 14)
            .frame(width: Night.settingsListWidth)
            .frame(maxHeight: .infinity)
            .background(Night.rail)
            NightDivider(vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(pane.title).font(.pageTitle).tracking(-0.4).foregroundStyle(Night.text)
                    Text(pane.subtitle).font(.nightBody).foregroundStyle(Night.text2).padding(.top, 4)
                    paneContent.padding(.top, 26)
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.horizontal, 36)
                .padding(.top, inWindow ? 26 : 44)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Night.canvas.ignoresSafeArea())
        .foregroundStyle(Night.text)
    }

    @ViewBuilder private var paneContent: some View {
        switch pane {
        case .general:
            VStack(alignment: .leading, spacing: 26) {
                GeneralSettingsTab(openCredits: { pane = .credits })
                PermissionsTab()
            }
        case .dictation:
            VStack(alignment: .leading, spacing: 26) {
                DictationSettingsTab()
                OverlaySettingsTab()
            }
        case .meetings:
            VStack(alignment: .leading, spacing: 26) {
                MeetingsSettingsTab()
                SyncSettingsTab()
            }
        case .vocabulary: VocabularySettingsTab()
        case .models: ModelSettingsTab()
        case .updates:
            VStack(alignment: .leading, spacing: 26) {
                SettingsCard(title: "Updates") { UpdateSection() }
                AboutView(embedded: true, openCredits: { pane = .credits })
            }
        case .credits:
            CreditsPage(back: { pane = .general })
        }
    }
}

// MARK: - Building blocks

/// A settings group: a hairline-labeled title above, rows in a hairline card, an optional footnote.
struct SettingsCard<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title { HairlineHeader(title: title).padding(.bottom, 4) }
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(NightCardBackground())
            if let footer {
                Text(footer).font(.nightSecondary).foregroundStyle(Night.text3).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

/// One row: title (+ detail) on the left, a control on the right.
struct SettingRow<Control: View>: View {
    var title: String
    var detail: String? = nil
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14.5, weight: .medium)).foregroundStyle(Night.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(.nightSecondary).foregroundStyle(Night.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 10)
            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

/// A row with a switch.
struct ToggleRow: View {
    var title: String
    var detail: String? = nil
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        SettingRow(title: title, detail: detail) {
            NightSwitch(isOn: isOn)
        }
        .contentShape(Rectangle())
        .onTapGesture { if enabled { isOn.toggle() } }
        .opacity(enabled ? 1 : 0.45)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// A short text block inside a card.
struct CardNote: View {
    var text: String
    var body: some View {
        Text(text).font(.nightSecondary).foregroundStyle(Night.text2).lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
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
    @AppStorage("doubleTapHandsFree") private var doubleTap = true
    @AppStorage(DictationStyle.key) private var style = DictationStyle.natural.rawValue

    private var holdOptions: [(value: String, title: String)] { HoldKey.allCases.map { (value: $0.rawValue, title: $0.title) } }
    private var modeOptions: [(value: String, title: String)] {
        [(value: DictationMode.both.rawValue, title: "Hold + toggle"),
         (value: DictationMode.holdOnly.rawValue, title: "Hold only"),
         (value: DictationMode.toggleOnly.rawValue, title: "Toggle only")]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: "Shortcuts", footer: "Press Esc while talking to cancel. A quick tap of the hold key does nothing, and so does using it in a shortcut like ⌥←.") {
                SettingRow(title: "Dictation shortcut", detail: "Hold to talk, release to paste where your cursor is") {
                    HStack(spacing: 10) {
                        Keycap(text: (HoldKey(rawValue: holdKey) ?? .rightOption).keycap)
                        NightPicker(selection: $holdKey, options: holdOptions)
                    }
                }
                .disabled(mode == DictationMode.toggleOnly.rawValue)
                NightDivider()
                ToggleRow(title: "Double-tap for hands-free",
                          detail: "Tap the hold key twice to keep listening without holding it; tap once more to stop",
                          isOn: $doubleTap)
                    .disabled(mode == DictationMode.toggleOnly.rawValue || holdKey == HoldKey.off.rawValue)
                NightDivider()
                SettingRow(title: "Mode") {
                    NightSegmented(selection: $mode, options: modeOptions)
                }
                NightDivider()
                SettingRow(title: "Toggle shortcut", detail: "Press, talk, press again") {
                    ShortcutRecorder { dictation.hotkeys.reload() }
                }
                .disabled(mode == DictationMode.holdOnly.rawValue)
            }
            SettingsCard(title: "Style", footer: (DictationStyle(rawValue: style) ?? .natural).example) {
                SettingRow(title: "Style", detail: (DictationStyle(rawValue: style) ?? .natural).detail) {
                    NightSegmented(selection: $style, options: DictationStyle.allCases.map { (value: $0.rawValue, title: $0.title) })
                }
            }
            SettingsCard(title: "Clean-up (Natural style)") {
                ToggleRow(title: "Clean up filler words", detail: "Removes “um”, “uh” and false starts", isOn: $removeFillers)
                NightDivider()
                ToggleRow(title: "Polish with Apple Intelligence",
                          detail: AppleIntelligence.statusText + ". On-device. Fixes punctuation and “no wait, I mean…”.",
                          isOn: $aiCleanup)
                NightDivider()
                ToggleRow(title: "I pause while thinking",
                          detail: "A pause must last over a second before it counts as a break, so thinking pauses don't add periods mid-sentence",
                          isOn: $pauseWhileThinking)
            }
            SettingsCard(title: "Typing") {
                ToggleRow(title: "Add a space after the text", isOn: $trailingSpace)
                NightDivider()
                ToggleRow(title: "Type straight into the text field", detail: "When possible, without the clipboard", isOn: $directInsert)
                NightDivider()
                ToggleRow(title: "Put my clipboard back after pasting", isOn: $restoreClipboard)
                NightDivider()
            }
        }
        .onChange(of: holdKey) { _, _ in dictation.hotkeys.reload() }
        .onChange(of: mode) { _, _ in dictation.hotkeys.reload() }
    }
}

// MARK: - Overlay

struct OverlaySettingsTab: View {
    @AppStorage(OverlayPosition.key) private var overlayPosition = OverlayPosition.bottomCenter.rawValue
    @State private var hasDragged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: "Capsule",
                         footer: "The small black capsule appears on the screen you're working on, clear of the menu bar and Dock. Drag it to move it; Scribe remembers the spot for each display. Against the left or right edge it stands upright (34 pt wide).") {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Overlay position").font(.nightHeadline).foregroundStyle(Night.text)
                        Text(OverlayPosition(rawValue: overlayPosition)?.title ?? "Bottom center")
                            .font(.nightSecondary).foregroundStyle(Night.text3)
                        if hasDragged {
                            Button("Reset dragged spot") { OverlayPosition.clearDragged(); hasDragged = false }
                                .buttonStyle(NightButtonStyle(kind: .secondary, height: 30))
                                .padding(.top, 10)
                        }
                    }
                    Spacer(minLength: 10)
                    OverlayPositionPreview(position: OverlayPosition(rawValue: overlayPosition) ?? .bottomCenter) { p in
                        overlayPosition = p.rawValue
                    }
                }
                .padding(Night.cardPadding)
            }
        }
        .onAppear { hasDragged = OverlayPosition.hasDragged }
        .onChange(of: overlayPosition) { _, _ in OverlayPosition.clearDragged(); hasDragged = false }
    }
}

/// A mini screen with a capsule spot for every position; click one to choose it.
struct OverlayPositionPreview: View {
    var position: OverlayPosition
    var onPick: ((OverlayPosition) -> Void)? = nil

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Night.well)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Night.line2, lineWidth: 1))
            ForEach(OverlayPosition.allCases) { p in
                spot(p)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(p))
                    .padding(.horizontal, p.isSide ? 8 : 12)
                    .padding(.vertical, 12)
            }
        }
        .frame(width: 196, height: 124)
        .animation(Night.spring, value: position)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Overlay position: \(position.title)")
    }

    private func spot(_ p: OverlayPosition) -> some View {
        let on = p == position
        return Button { onPick?(p) } label: {
            Capsule()
                .fill(on ? AnyShapeStyle(Night.gradient) : AnyShapeStyle(Night.line2))
                .frame(width: p.isSide ? 7 : 28, height: p.isSide ? 26 : 7)
                .padding(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onPick == nil)
        .help(p.title)
        .accessibilityLabel(p.title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func alignment(_ p: OverlayPosition) -> Alignment {
        switch p {
        case .bottomCenter: return .bottom
        case .topCenter: return .top
        case .topLeft: return .topLeading
        case .topRight: return .topTrailing
        case .bottomLeft: return .bottomLeading
        case .bottomRight: return .bottomTrailing
        case .middleLeft: return .leading
        case .middleRight: return .trailing
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
        HStack(spacing: 8) {
            if !recording, DictationSettings.toggleShortcut != nil {
                Keycap(text: label)
            }
            Button(recording ? "Press keys…" : (DictationSettings.toggleShortcut == nil ? "Set" : "Change")) {
                if recording { stop() } else { start() }
            }
            .buttonStyle(NightButtonStyle(kind: .secondary, height: 32))
            if !recording, DictationSettings.toggleShortcut != nil {
                Button { DictationSettings.toggleShortcut = nil; label = "None"; onChange() } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(NightIconButtonStyle(size: 28))
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
    @AppStorage(Vocabulary.boostKey) private var acoustic = false
    @State private var pairs: [DictionaryReplacements.Pair] = DictionaryReplacements.pairs
    @State private var heard = ""
    @State private var written = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            SettingsCard(title: "Your words",
                         footer: "Names, apps and terms you use. Scribe spells them your way: “on shape” → Onshape, “swift ui” → SwiftUI, “v five” → V5. Close misspellings of longer words are fixed only when they aren't real English words.") {
                HStack(spacing: 10) {
                    NightField(placeholder: "Add a word or name", text: $newWord, onSubmit: add)
                    Button("Add", action: add)
                        .buttonStyle(.nightPrimary)
                        .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(Night.cardPadding)
                NightDivider()
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(words, id: \.self) { w in
                        HStack(spacing: 6) {
                            Text(w).font(.nightSmallStrong).foregroundStyle(Night.text).lineLimit(1)
                            Spacer(minLength: 0)
                            Button { words.removeAll { $0 == w }; save() } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Night.text3)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(w)")
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(Capsule().fill(Night.raised))
                        .overlay(Capsule().strokeBorder(Night.line, lineWidth: 1))
                    }
                }
                .padding(Night.cardPadding)
                NightDivider()
                HStack {
                    Spacer()
                    Button("Restore defaults") { words = Vocabulary.defaults; save() }.buttonStyle(.nightGhost)
                }
                .padding(.horizontal, Night.rowPaddingH).padding(.vertical, Night.rowPaddingV)
            }
            SettingsCard(title: "Replacements",
                         footer: "When Scribe hears the left side, it writes the right side. Whole words, any capitalization. Applied in every Style, also Exact. The same list is on the Dictation page.") {
                HStack(spacing: 8) {
                    NightField(placeholder: "Heard, e.g. sweet UI", text: $heard, onSubmit: addPair)
                    Image(systemName: "arrow.right").foregroundStyle(Night.text3)
                    NightField(placeholder: "Written, e.g. SwiftUI", text: $written, onSubmit: addPair)
                    Button("Add", action: addPair)
                        .buttonStyle(.nightPrimary)
                        .disabled(heard.trimmingCharacters(in: .whitespaces).isEmpty || written.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(Night.cardPadding)
                if !pairs.isEmpty {
                    NightDivider()
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(pairs) { p in
                            HStack(spacing: 8) {
                                Text(p.from).font(.nightBody).foregroundStyle(Night.text2)
                                Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(Night.text3)
                                Text(p.to).font(.nightBody).foregroundStyle(Night.text)
                                Spacer()
                                Button { DictionaryReplacements.remove(p); pairs = DictionaryReplacements.pairs } label: {
                                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Night.text3)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(p.from)")
                            }
                            .padding(.horizontal, 16).padding(.vertical, 9)
                        }
                    }
                }
            }
            LearnedFixesCard(changed: { words = Vocabulary.words; pairs = DictionaryReplacements.pairs })
            SettingsCard(footer: "Uses a small extra model (about 100 MB, downloaded once) to check your words against how they sounded, so misheard names can be fixed even when the spelling is far off. Off by default: it can sometimes swap an ordinary word for one of yours.") {
                ToggleRow(title: "Also match against the audio",
                          detail: acoustic && !store.vocabularyBoostStatus.isEmpty ? store.vocabularyBoostStatus : nil,
                          isOn: $acoustic)
            }
        }
        .onChange(of: acoustic) { _, _ in Task { await store.prepareVocabularyBoost() } }
    }

    private func addPair() {
        let a = heard.trimmingCharacters(in: .whitespacesAndNewlines), b = written.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !b.isEmpty else { return }
        DictionaryReplacements.add(.init(from: a, to: b))
        pairs = DictionaryReplacements.pairs
        heard = ""; written = ""
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

// MARK: - Models

struct ModelSettingsTab: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var models: ModelStore
    @AppStorage(DictationEngine.key) private var engineRaw = DictationEngine.current.rawValue
    @AppStorage("aiNotes") private var aiNotes = true
    @State private var showVoiceTest = false
    @StateObject private var voiceTest = VoiceTestModel()
    /// The Tachys speed engine (built on its own branch). Read by the engine; default on.
    @AppStorage("tachysEnabled") private var tachysEnabled = true
    @State private var changing = false

    private var statusText: String {
        if store.engineReady { return "Ready" }
        if store.engineError != nil { return "Problem" }
        return "Loading…"
    }
    private var statusColor: Color {
        store.engineReady ? Night.ok : (store.engineError != nil ? Night.live : Night.text3)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            SettingsCard(title: "Models") {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text("Speech model").font(.system(size: 14.5, weight: .medium)).foregroundStyle(Night.text)
                            Text((DictationEngine(rawValue: engineRaw) ?? .parakeetV2).shortTitle)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Night.onPrimary)
                                .padding(.horizontal, 7)
                                .frame(height: 20)
                                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Night.primary))
                        }
                        Text("Runs on this Mac · nothing leaves your computer").font(.nightSecondary).foregroundStyle(Night.text2)
                    }
                    Spacer(minLength: 10)
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 7, height: 7)
                        Text(statusText).font(.nightSecondary).foregroundStyle(Night.text2)
                    }
                    Button(changing ? "Done" : "Change") { changing.toggle() }.buttonStyle(.nightSecondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                NightDivider()
                ToggleRow(title: "Tachys speed engine", detail: "Faster transcription on Apple silicon", isOn: $tachysEnabled)
            }
            if changing {
            SettingsCard(title: "Choose a dictation model",
                         footer: "Runs on this Mac's Neural Engine with Core ML. Downloads once, then works with no internet.") {
                ForEach(Array(DictationEngine.allCases.enumerated()), id: \.element.id) { i, m in
                    if i > 0 { NightDivider() }

                    Button { engineRaw = m.rawValue } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle().strokeBorder(engineRaw == m.rawValue ? Color.clear : Night.line2, lineWidth: 1.5)
                                if engineRaw == m.rawValue {
                                    Circle().fill(Night.gradient)
                                    Circle().fill(Color.white).frame(width: 6, height: 6)
                                }
                            }
                            .frame(width: 18, height: 18)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(m.title).font(.nightHeadline).foregroundStyle(Night.text)
                                Text(m.detail + (m.componentIDs.allSatisfy { models.isInstalled($0) } ? "" : " Downloads \(ModelStore.mb(m.downloadBytes)) when picked."))
                                    .font(.nightSecondary).foregroundStyle(Night.text3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Night.rowPaddingH).padding(.vertical, Night.rowPaddingV + 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                NightDivider()
                SettingRow(title: "Test my voice", detail: "Read 20 sentences; see which model gets your voice right.") {
                    Button("Test my voice…") { showVoiceTest = true }
                        .buttonStyle(NightButtonStyle(kind: .secondary, height: 32))
                }
                if !store.whisperStatus.isEmpty {
                    NightDivider()
                    CardNote(text: store.whisperStatus)
                }
                NightDivider()
                HStack(spacing: 12) {
                    if store.engineReady {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Night.ok)
                        Text("Loaded and working offline").font(.nightSmallStrong).foregroundStyle(Night.text2)
                    } else if let e = store.engineError {
                        Text(e).font(.nightSmallStrong).foregroundStyle(Night.warn)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(store.engineStatus).font(.nightSmallStrong).foregroundStyle(Night.text2).monospacedDigit()
                            CapsuleProgress(fraction: store.modelProgress, count: 40)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Night.rowPaddingH).padding(.vertical, Night.rowPaddingV + 2)
            }
            }
            CorrectionsCard()
            SettingsCard(title: "Downloaded models",
                         footer: "Models live outside the app (in Application Support), so updating or reinstalling Scribe never downloads them again. Only missing or changed files are fetched. Verify re-checks every byte.") {
                ModelComponentsList()
            }
        }
        .onChange(of: engineRaw) { _, new in
            if let e = DictationEngine(rawValue: new) { DictationEngine.select(e) }
            Task { await store.prepareEngine() }
        }
        .sheet(isPresented: $showVoiceTest) {
            VoiceTestView(model: voiceTest).environmentObject(store).environmentObject(models)
        }
    }
}

/// One row per model component: status (Downloaded / Update available / Missing…) + Verify.
struct ModelComponentsList: View {
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if models.components.isEmpty {
                CardNote(text: "No model manifest in this build — FluidAudio downloads models itself.")
            }
            ForEach(models.components.filter { models.isRelevant($0) }) { c in
                let state = models.states[c.id] ?? .missing
                HStack(spacing: 12) {
                    Image(systemName: icon(state)).foregroundStyle(color(state)).frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(c.title).font(.nightHeadline).foregroundStyle(Night.text)
                        Text("\(state.label) · \(ModelStore.mb(c.totalBytes)) · version \(c.version)")
                            .font(.nightSecondary).foregroundStyle(Night.text3).lineLimit(1)
                        if case .downloading(let p) = state {
                            CapsuleProgress(fraction: p.fraction, count: 30, dot: 5, spacing: 2.5).padding(.top, 4)
                        }
                    }
                    Spacer()
                    switch state {
                    case .downloading, .verifying:
                        CapsuleSpinner()
                    case .downloaded:
                        Button("Verify") { Task { await models.verify(c.id) } }
                            .buttonStyle(NightButtonStyle(kind: .secondary, height: 30))
                    default:
                        Button("Download") { Task { try? await models.ensure([c.id]) } }
                            .buttonStyle(NightButtonStyle(kind: .secondary, height: 30))
                    }
                }
                .padding(.horizontal, Night.rowPaddingH).padding(.vertical, Night.rowPaddingV)
                NightDivider()
            }
            HStack {
                Spacer()
                Button("Re-check") { models.refresh() }.buttonStyle(.nightGhost)
            }
            .padding(.horizontal, Night.rowPaddingH).padding(.vertical, Night.rowPaddingV)
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
        case .downloaded: return Night.ok
        case .updateAvailable, .downloading, .verifying: return Night.accent
        case .damaged, .failed: return Night.warn
        case .missing, .partial: return Night.text3
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
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: "Permissions") {
                AccessibilityBanner(permissions: permissions).padding(.horizontal, 14).padding(.top, 14)
                PermissionRows()
            }
            SettingsCard(title: "Typing", footer: "The test opens an empty TextEdit document and types one line the same way a dictation does.") {
                SettingRow(title: "Test typing into TextEdit", detail: testResult?.message) {
                    HStack(spacing: 8) {
                        if let r = testResult {
                            Image(systemName: r.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(r.ok ? Night.ok : Night.warn)
                        }
                        Button(testing ? "Testing…" : "Run test") {
                            testing = true
                            Task {
                                testResult = await TypingTest.run()
                                testing = false
                                NSApp.activate(ignoringOtherApps: true)
                            }
                        }
                        .buttonStyle(NightButtonStyle(kind: .secondary, height: 32))
                        .disabled(testing)
                    }
                }
                if let last = pasteLog.last {
                    NightDivider()
                    SettingRow(title: "Last dictation", detail: last.line) { EmptyView() }
                }
            }
            SettingsCard(title: "Reset Accessibility (after every update)") {
                VStack(alignment: .leading, spacing: 5) {
                    Text("1. Open System Settings › Privacy & Security › Accessibility.")
                    Text("2. Select Scribe and click –. It's fine if its switch looked on.")
                    Text("3. Click +, choose Scribe in Applications, and turn it on.")
                    Text("Scribe builds aren't signed with a paid Apple certificate, so macOS sees each update as a new app and quietly stops trusting the old entry.")
                        .foregroundStyle(Night.text3)
                        .padding(.top, 4)
                }
                .font(.nightSecondary)
                .foregroundStyle(Night.text2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Night.cardPadding)
                NightDivider()
                HStack(spacing: 10) {
                    Button("Open Accessibility Settings") { AccessibilityHelp.fix() }.buttonStyle(NightButtonStyle(kind: .secondary, height: 32))
                    Button("Show Scribe in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                        .buttonStyle(NightButtonStyle(kind: .secondary, height: 32))
                }
                .padding(14)
            }
        }
        .onAppear { permissions.startWatching() }
        .onDisappear { permissions.stopWatching() }
    }
}

/// Microphone + Accessibility rows with live status (shared by Settings and onboarding).
struct PermissionRows: View {
    @EnvironmentObject var permissions: Permissions
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PermissionRow(title: "Microphone", detail: "To hear you dictate and record meetings.",
                          granted: permissions.microphone == .authorized,
                          button: permissions.microphone == .notDetermined ? "Allow…" : "Open Settings") {
                Task { await permissions.requestMicrophone() }
            }
            NightDivider()
            PermissionRow(title: "Accessibility", detail: "To notice the hold key in other apps and paste your words for you. Turn Scribe on in the list.",
                          granted: permissions.accessibility, button: "Open Settings") {
                permissions.requestAccessibility()
            }
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
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 18))
                .foregroundStyle(granted ? Night.ok : Night.text3)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.nightHeadline).foregroundStyle(Night.text)
                Text(detail).font(.nightSecondary).foregroundStyle(Night.text3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !granted { Button(button, action: action).buttonStyle(NightButtonStyle(kind: .secondary, height: 32)) }
        }
        .padding(.horizontal, Night.rowPaddingH).padding(.vertical, Night.rowPaddingV)
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @AppStorage("onboarded") private var onboarded = true
    @AppStorage(AppearanceChoice.key) private var appearance = AppearanceChoice.system.rawValue
    @AppStorage(DockPolicy.key) private var showInDock = true
    @AppStorage("dictationSounds") private var sounds = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    /// 0.7.3.1: opens Settings › General › Credits & licenses.
    var openCredits: () -> Void

    init(openCredits: @escaping () -> Void = {}) { self.openCredits = openCredits }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            SettingsCard(title: "App") {
                SettingRow(title: "Appearance", detail: "Match your Mac, or pick one") {
                    NightSegmented(selection: $appearance,
                                   options: AppearanceChoice.allCases.map { (value: $0.rawValue, title: $0.title) })
                }
                NightDivider()
                ToggleRow(title: "Open at login", detail: loginError ?? "Start Scribe when you sign in", isOn: $launchAtLogin)
                NightDivider()
                ToggleRow(title: "Show in Dock", detail: "Off keeps Scribe in the menu bar only", isOn: $showInDock)
                NightDivider()
                ToggleRow(title: "Sounds", detail: "Play a soft tick when dictation starts and stops", isOn: $sounds)
                NightDivider()
                SettingRow(title: "Welcome screen", detail: "The first-run guide: models, microphone, typing") {
                    Button("Show again") { onboarded = false }.buttonStyle(.nightSecondary)
                }
            }
            SettingsCard(title: "About") {
                SettingRow(title: "Credits & licenses", detail: "Speech models, open-source code and fonts, with their licenses") {
                    Button("Open") { openCredits() }.buttonStyle(.nightSecondary)
                }
                NightDivider()
                LegalRow(title: "Privacy Policy", url: LegalLinks.privacyURL)
                NightDivider()
                LegalRow(title: "Terms of Use", url: LegalLinks.termsURL)
            }
        }
        .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
        .onChange(of: appearance) { _, v in AppearanceChoice.apply(AppearanceChoice(rawValue: v) ?? .system) }
        .onChange(of: showInDock) { _, on in DockPolicy.apply(on) }
    }

    /// SMAppService is Apple's modern "login item" API (macOS 13+).
    private func setLaunchAtLogin(_ on: Bool) {
        guard on != (SMAppService.mainApp.status == .enabled) else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "macOS said no: \(error.localizedDescription). You can add Scribe in System Settings → General → Login Items."
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// Settings › General › Show in Dock: a regular app (Dock + app menu) or menu bar only.
enum DockPolicy {
    static let key = "showInDock"
    static var showInDock: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    @MainActor
    static func apply(_ show: Bool = DockPolicy.showInDock) {
        let policy: NSApplication.ActivationPolicy = show ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // Menu-bar-only drops the app out of the front; bring the Settings window back.
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
    }
}

// MARK: - Meetings

struct MeetingsSettingsTab: View {
    @AppStorage("noiseCleanup") private var noiseCleanup = true
    @AppStorage("meetingSystemAudio") private var systemAudio = true
    @AppStorage("showMeetingScroll") private var showMeetingScroll = true
    @AppStorage("aiNotes") private var aiNotes = true

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            // 0.7.3.2: your own voiceprint (setup, strength, Train it more, Test it).
            SettingsCard(title: "My voice",
                         footer: "Your voiceprint stays on this Mac. Scribe never keeps the audio you record here.") {
                MyVoiceCard()
            }
            SettingsCard(title: "Recording") {
                ToggleRow(title: "Noise cleanup", detail: "Apple voice processing: reduces background noise while recording", isOn: $noiseCleanup)
                NightDivider()
                ToggleRow(title: "Also record the Mac's sound",
                          detail: "The other people on a call (Zoom, Meet, Teams…), even with headphones. macOS asks once to allow System Audio Recording. Needs macOS 14.4+.",
                          isOn: $systemAudio)
                NightDivider()
                ToggleRow(title: "Show the capsule while a meeting records", detail: "A red dot and a timer at the edge of the screen", isOn: $showMeetingScroll)
            }
            SettingsCard(title: "Notes") {
                ToggleRow(title: "Write notes with Apple Intelligence",
                          detail: AppleIntelligence.statusText + ". On-device. Otherwise Scribe picks key sentences and action items from the transcript itself.",
                          isOn: $aiNotes)
            }
        }
    }
}

/// Settings → General → Updates.
struct UpdateSection: View {
    @EnvironmentObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ToggleRow(title: "Update automatically",
                      detail: "Checks when Scribe opens and every 6 hours, downloads in the background, and installs when you restart or quit. Never during a recording.",
                      isOn: $updater.autoCheck)
            NightDivider()
            SettingRow(title: "This is Scribe \(Updater.currentVersion)") {
                Button("Check for Updates…") { updater.check(userInitiated: true) }
                    .buttonStyle(NightButtonStyle(kind: .secondary, height: 32))
                    .disabled(updater.phase == .checking || updater.phase == .installing)
            }
            phaseView
            if let n = updater.notice {
                HStack(alignment: .top, spacing: 10) {
                    Text(n).font(.nightSmallStrong).foregroundStyle(Night.text2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if n.contains("see ") {
                        Button("Show log") { NSWorkspace.shared.open(Updater.logURL) }
                            .buttonStyle(NightButtonStyle(kind: .secondary, height: 28))
                    }
                    Button { updater.dismissNotice() } label: { Image(systemName: "xmark") }
                        .buttonStyle(NightIconButtonStyle(size: 28))
                        .accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, Night.rowPaddingH).padding(.bottom, Night.s12)
            }
        }
    }

    @ViewBuilder private var phaseView: some View {
        switch updater.phase {
        case .idle: EmptyView()
        case .checking:
            HStack(spacing: 10) { CapsuleSpinner(); Text("Checking…").font(.nightMeta).foregroundStyle(Night.text3) }
                .padding(.horizontal, Night.rowPaddingH).padding(.bottom, Night.s12)
        case .upToDate(let v):
            Label("You're up to date (\(v)).", systemImage: "checkmark.circle").font(.nightSmallStrong).foregroundStyle(Night.ok)
                .padding(.horizontal, Night.rowPaddingH).padding(.bottom, Night.s12)
        case .available(let r):
            VStack(alignment: .leading, spacing: 6) {
                Text("Scribe \(r.version) is available — app download \(ModelStore.mb(r.zipBytes)).").font(.nightHeadline)
                Text(r.modelChanges.isEmpty ? "Models: no change (nothing else to download)."
                                            : "Models that changed: " + r.modelChanges.joined(separator: ", "))
                    .font(.nightMeta).foregroundStyle(Night.text3)
                Button("Download and Restart") { updater.install(r) }.buttonStyle(.nightPrimary)
            }
            .padding(.horizontal, Night.rowPaddingH).padding(.bottom, Night.s12)
        case .downloading:
            HStack(spacing: 10) { CapsuleSpinner(); Text("Downloading the app…").font(.nightMeta).foregroundStyle(Night.text3) }
                .padding(.horizontal, Night.rowPaddingH).padding(.bottom, Night.s12)
        case .ready(let r):
            HStack {
                Label("Scribe \(r.version) is ready.", systemImage: "arrow.down.circle.fill").font(.nightSmallStrong)
                Spacer()
                Button("Restart Now") { updater.restartNow() }.buttonStyle(.nightPrimary)
            }
            .padding(.horizontal, Night.rowPaddingH).padding(.bottom, Night.s12)
        case .needsMove(let r):
            HStack {
                Label("Scribe \(r.version) is downloaded. Move Scribe to Applications to update.", systemImage: "folder")
                    .font(.nightSmallStrong).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Show Scribe") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                    .buttonStyle(NightButtonStyle(kind: .secondary, height: 32))
            }
            .padding(.horizontal, Night.rowPaddingH).padding(.bottom, Night.s12)
        case .installing:
            HStack(spacing: 10) { CapsuleSpinner(); Text("Installing…").font(.nightMeta).foregroundStyle(Night.text3) }
                .padding(.horizontal, Night.rowPaddingH).padding(.bottom, Night.s12)
        case .failed(let e):
            Text(e).font(.nightMeta).foregroundStyle(Night.warn).padding(.horizontal, Night.rowPaddingH).padding(.bottom, Night.s12)
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
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: "Save to GitHub") {
                SettingRow(title: "Notes repo", detail: "A PRIVATE repo for your notes, not the app's code repo") {
                    NightField(placeholder: "owner/name", text: $sync.repo).frame(width: 220)
                }
                NightDivider()
                if sync.hasToken {
                    SettingRow(title: "Token", detail: "Saved in Keychain") {
                        Button("Remove") { sync.setToken(nil) }.buttonStyle(NightButtonStyle(kind: .secondary, height: 32))
                    }
                } else {
                    SettingRow(title: "Token") {
                        HStack(spacing: 8) {
                            NightField(placeholder: "github_pat_…", text: $tokenField, secure: true).frame(width: 190)
                            Button("Save") { sync.setToken(tokenField); tokenField = "" }
                                .buttonStyle(NightButtonStyle(kind: .secondary, height: 32))
                                .disabled(tokenField.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                NightDivider()
                SettingRow(title: "Connection", detail: testResult) {
                    Button(testing ? "Testing…" : "Test connection") {
                        testing = true
                        Task { testResult = await sync.testConnection(); testing = false }
                    }
                    .buttonStyle(NightButtonStyle(kind: .secondary, height: 32))
                    .disabled(!sync.hasToken || testing)
                }
                NightDivider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Every dictation (dictations/YYYY-MM-DD.md) and every meeting's notes (meetings/…md) are saved as Markdown in this private repo. Nothing waits for GitHub: items queue up and send in the background, also after being offline.")
                        .foregroundStyle(Night.text3)
                        .fixedSize(horizontal: false, vertical: true)
                    Link("1. Create the private repo “scribe-notes”", destination: URL(string: "https://github.com/new?name=scribe-notes&visibility=private")!)
                    Link("2. Create a fine-grained token (only that repo, Contents: Read and write)", destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!)
                }
                .font(.nightSecondary)
                .tint(Night.accent)
                .padding(Night.cardPadding)
            }
            SettingsCard(title: "What to save") {
                ToggleRow(title: "Dictations", isOn: $sync.syncDictations)
                NightDivider()
                ToggleRow(title: "Meeting notes", isOn: $sync.syncMeetings)
            }
            SettingsCard(title: "Status") {
                SettingRow(title: statusText, detail: "\(sync.pending) waiting") {
                    Button("Send now") { sync.kick() }
                        .buttonStyle(NightButtonStyle(kind: .secondary, height: 32))
                        .disabled(!sync.hasToken || sync.pending == 0)
                }
            }
        }
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
