// OnboardingView.swift
// First launch, all in ONE window:
//
//   • The models start downloading by themselves the moment Scribe opens (dictation first,
//     then the speaker models). A thin progress bar at the bottom says what's downloading,
//     how many MB, how fast and how long is left.
//   • Meanwhile you flip through cards (← → keys, a two-finger swipe, or the arrow buttons):
//     what Scribe can do, the setup steps (Microphone, Accessibility, your talk key, a "Try it"
//     box) and a little game, "Quill Dash". Setup never waits for the download and the
//     download never waits for setup.
//   • When everything's ready, the bottom bar says so and you continue when YOU want —
//     it never pulls you out of a game mid-run. "Continue in the background" is always there.

import SwiftUI
import AppKit

struct OnboardingView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var permissions: Permissions
    @EnvironmentObject var models: ModelStore
    @AppStorage("onboarded") private var onboarded = false
    @StateObject private var game = RunnerGame()
    @State private var index: Int
    @State private var planned: Int64 = 0
    @FocusState private var focused: Bool
    /// Snapshot: a frozen frame (no auto-advancing cards).
    var previewPhase: Double? = nil
    /// Snapshot: pretend this many bytes were planned (so the bar shows a mid-download frame).
    var previewPlanned: Int64? = nil
    /// Snapshot: freeze the game in a mid-run frame.
    var previewGame = false

    init(initialIndex: Int = 0, previewPhase: Double? = nil, previewPlanned: Int64? = nil, previewGame: Bool = false) {
        _index = State(initialValue: initialIndex)
        self.previewPhase = previewPhase
        self.previewPlanned = previewPlanned
        self.previewGame = previewGame
    }

    static let size = CGSize(width: 760, height: 560)

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 8)
            cardArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 16)
            pageDots
                .padding(.bottom, 16)
            Divider()
            bottomBar
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Warm.canvas)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.leftArrow) { go(-1); return .handled }
        .onKeyPress(.rightArrow) { go(1); return .handled }
        .onAppear {
            focused = true
            permissions.startWatching()
            planned = previewPlanned ?? max(planned, remainingBytes)
            if previewGame { game.setPreview() }
        }
        .onDisappear { permissions.stopWatching() }
        .onChange(of: remainingBytes) { _, r in if r > planned && previewPlanned == nil { planned = r } }
        .task(id: index) {
            // Feature cards turn by themselves every 7 s (setup cards and the game don't).
            guard previewPhase == nil, case .useCase = card(at: index) else { return }
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            if !Task.isCancelled, case .useCase = card(at: index) { withAnimation(.easeInOut(duration: 0.35)) { index += 1 } }
        }
    }

    // MARK: Cards

    enum Card: Equatable {
        case useCase(Int), microphone, accessibility, hotkey, tryIt, game
    }

    static let useCases: [(title: String, detail: String, symbol: String)] = [
        ("Hold Right ⌥ and talk, in any app", "Let go and your words are typed where your cursor is. Notes, Messages, Docs, code.", "keyboard"),
        ("Record meetings", "Scribe learns who's talking. Name a voice once and it's recognized next time.", "person.2.wave.2"),
        ("Notes and action items", "A summary, key points and who does what, right after you press Stop.", "checklist"),
        ("Private by design", "Everything runs on this Mac. No account, nothing uploaded. Free.", "lock"),
        ("Search every meeting", "Find the moment someone said “deadline” three weeks ago.", "magnifyingglass"),
        ("Clean words, not ums", "Fillers and stutters are removed; Apple Intelligence can polish the rest.", "text.badge.checkmark"),
    ]

    /// The order of cards. Setup steps come early; after the list ends it loops
    /// "use case, use case, game" until you're done.
    static let base: [Card] = [.useCase(0), .useCase(1), .microphone, .accessibility, .hotkey,
                               .useCase(2), .game, .useCase(3), .useCase(4), .tryIt]

    func card(at i: Int) -> Card {
        if i < Self.base.count { return Self.base[max(0, i)] }
        let j = i - Self.base.count
        if j % 3 == 0 { return .game }
        let n = j - (j / 3) - 1
        return .useCase((5 + n) % Self.useCases.count)
    }

    private func go(_ d: Int) {
        withAnimation(.easeInOut(duration: 0.3)) { index = max(0, index + d) }
    }

    @ViewBuilder private var cardArea: some View {
        HStack(spacing: 8) {
            arrow("chevron.left", label: "Previous") { go(-1) }.opacity(index > 0 ? 1 : 0.3).disabled(index == 0)
            ZStack {
                cardView(card(at: index))
                    .id(index)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .move(edge: .leading).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .gesture(DragGesture(minimumDistance: 30).onEnded { v in
                if v.translation.width < -60 { go(1) } else if v.translation.width > 60 { go(-1) }
            })
            arrow("chevron.right", label: "Next") { go(1) }
        }
    }

    private func arrow(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(0.06), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(label)
    }

    private var pageDots: some View {
        let count = Self.base.count
        let current = min(index, count - 1)
        return HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(i == current ? Color.primary.opacity(0.55) : Color.primary.opacity(0.15))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private func cardView(_ c: Card) -> some View {
        switch c {
        case .useCase(let k):
            let u = Self.useCases[k % Self.useCases.count]
            VStack(spacing: 16) {
                SymbolTile(symbol: u.symbol, size: 64)
                Text(u.title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(u.detail).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        case .microphone:
            setupCard(step: 1, title: "Let Scribe hear you", symbol: "mic") {
                PermissionRow(title: "Microphone", detail: "To hear you dictate and record meetings. Audio never leaves this Mac.",
                              granted: permissions.microphone == .authorized,
                              button: permissions.microphone == .notDetermined ? "Allow…" : "Open Settings") {
                    Task { await permissions.requestMicrophone() }
                }
            }
        case .accessibility:
            setupCard(step: 2, title: "Let Scribe type for you", symbol: "accessibility") {
                PermissionRow(title: "Accessibility", detail: "So the talk key works in other apps and Scribe can paste your words. Click Open Settings and switch Scribe on.",
                              granted: permissions.accessibility, button: "Open Settings") {
                    permissions.requestAccessibility()
                }
            }
        case .hotkey:
            setupCard(step: 3, title: "Pick your talk key", symbol: "keyboard") { HotkeyPicker() }
        case .tryIt:
            setupCard(step: 4, title: "Try it", symbol: "text.cursor") { TryItBox(ready: store.engineReady) }
        case .game:
            RunnerGameView(game: game) { go(1) }
                .frame(maxWidth: 560)
        }
    }

    private func setupCard<Content: View>(step: Int, title: String, symbol: String,
                                          @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                SymbolTile(symbol: symbol, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Step \(step) of 4").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Text(title).font(.title2.weight(.semibold))
                }
            }
            content()
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Warm.surface, in: RoundedRectangle(cornerRadius: Brand.rCard, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Brand.rCard, style: .continuous).strokeBorder(Warm.hairline, lineWidth: 0.5))
        }
        .frame(maxWidth: 440)
    }

    // MARK: Bars

    private var topBar: some View {
        HStack(spacing: 10) {
            AppIconView(size: 28)
            Text("Welcome to Scribe").font(.title3.weight(.semibold))
            Spacer()
            HStack(spacing: 12) {
                checklistDot("Mic", permissions.microphone == .authorized)
                checklistDot("Accessibility", permissions.accessibility)
                checklistDot("Dictation", store.engineReady)
                checklistDot("Meetings", store.meetingModelsReady)
            }
        }
    }

    private func checklistDot(_ label: String, _ ok: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? Color.green : Color.secondary.opacity(0.6))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var bottomBar: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if allReady {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    Text(currentTitle).font(.callout.weight(.medium)).lineLimit(1)
                }
                if !allReady {
                    ProgressView(value: overallFraction)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .tint(Brand.accent)
                }
                Text(currentDetail).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            .frame(maxWidth: 420, alignment: .leading)
            Spacer()
            if store.engineError != nil {
                Button("Retry") { Task { await store.prepareEngine() } }
            }
            if allReady {
                Button("Start Using Scribe") { onboarded = true }
                    .scribeButton(prominent: true).controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Continue in Background") { onboarded = true }
                    .scribeButton()
                    .controlSize(.large)
                    .help("Downloads keep going; the menu bar shows progress.")
            }
        }
    }

    // MARK: Progress numbers

    private var allIDs: [String] { models.dictationComponents(SpeechModel.current) + models.meetingComponents }
    private var allReady: Bool { store.engineReady && store.meetingModelsReady }

    /// Bytes still to download across every model (dictation + meetings).
    private var remainingBytes: Int64 {
        var total: Int64 = 0
        var seenRuns: [DownloadProgress] = []
        for id in allIDs {
            guard let c = models.manifest?.component(id) else { continue }
            switch models.states[id] {
            case .downloaded?: break
            case .downloading(let p)?:
                if !seenRuns.contains(p) { seenRuns.append(p); total += max(0, p.totalBytes - p.doneBytes) }
            default:
                total += models.filesToFetch(c).reduce(Int64(0)) { $0 + $1.size }
            }
        }
        return total
    }

    private var overallFraction: Double {
        guard planned > 0 else { return allReady || models.manifest == nil ? 1 : (store.engineReady ? 0.9 : 0.02) }
        return min(1, max(0.02, 1 - Double(remainingBytes) / Double(planned)))
    }

    private var downloading: (ModelComponent, DownloadProgress)? {
        for id in allIDs {
            if case .downloading(let p)? = models.states[id], let c = models.manifest?.component(id) { return (c, p) }
        }
        return nil
    }

    private var currentTitle: String {
        if let e = store.engineError { return "Download paused: \(e.prefix(80))" }
        if let d = downloading { return "Downloading \(d.0.title)" }
        if !store.engineReady { return store.engineStatus }
        if !store.meetingModelsReady { return "Dictation is ready. Getting the speaker models…" }
        return "Ready. Everything works offline now."
    }

    private var currentDetail: String {
        if let d = downloading { return d.1.text }
        if allReady { return "You can close this window any time; Scribe lives in the menu bar." }
        return "This only happens once."
    }
}

// MARK: - Setup pieces

struct HotkeyPicker: View {
    @EnvironmentObject var dictation: DictationController
    @AppStorage("holdKey") private var holdKey = HoldKey.rightOption.rawValue
    @AppStorage("dictationMode") private var mode = DictationMode.both.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Hold to talk", selection: $holdKey) {
                ForEach(HoldKey.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Picker("Mode", selection: $mode) {
                ForEach(DictationMode.allCases) { Text($0.title).tag($0.rawValue) }
            }
            LabeledContent("Or press") { ShortcutRecorder { dictation.hotkeys.reload() } }
            Text("Hold the key, talk, let go. Esc cancels.").font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: holdKey) { _, _ in dictation.hotkeys.reload() }
        .onChange(of: mode) { _, _ in dictation.hotkeys.reload() }
    }
}

struct TryItBox: View {
    var ready: Bool
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if ready {
                Text("Click in the box, hold \(DictationSettings.holdKey.title) (or press \(DictationSettings.toggleShortcut?.label ?? "your shortcut")), say something, let go.")
                    .font(.callout)
            } else {
                Label("The speech model is still downloading — you can try this as soon as it's in. Dictation comes first, so it's not long.",
                      systemImage: "hourglass").font(.callout).foregroundStyle(.secondary)
            }
            TextField("Your words appear here…", text: $text, axis: .vertical)
                .lineLimit(3...5)
                .textFieldStyle(.roundedBorder)
                .disabled(!ready)
        }
    }
}
