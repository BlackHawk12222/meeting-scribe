// OnboardingView.swift
// First launch, all in ONE window with a soft glowing ring around its edge:
//
//   • The models start downloading by themselves the moment Scribe opens (dictation first,
//     then the speaker models). The ring fills up around the window as they download, and
//     the line at the bottom says what's downloading, how many MB, how fast, how long left.
//   • Meanwhile you flip through cards (← → keys, a two-finger swipe, or the arrow buttons):
//     what Scribe can do, the setup steps (Microphone, Accessibility, your hotkey, a "Try it"
//     box) and a little game, "Quill Dash". Setup never waits for the download and the
//     download never waits for setup.
//   • When everything's ready, the bottom bar says so and you continue when YOU want —
//     it never pulls you out of a game mid-run.

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
    @State private var autoTick = 0
    @FocusState private var focused: Bool
    /// Snapshot: freeze the ring's moving glow at this phase.
    var previewPhase: Double? = nil

    /// Snapshot: pretend this many bytes were planned (so the ring shows a mid-download frame).
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
        ZStack {
            Ink.parchmentLight.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                cardArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 40)
                bottomBar
            }
            .padding(22)
            GlowRing(progress: overallFraction, active: !allReady, previewPhase: previewPhase)
                .allowsHitTesting(false)
        }
        .frame(width: Self.size.width, height: Self.size.height)
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
            // Use-case cards turn by themselves every 7 s (setup cards and the game don't).
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
        ("Hold Right ⌥ and talk — in any app", "Let go and your words are typed where your cursor is. Notes, Messages, Docs, code.", "keyboard"),
        ("Record meetings — Scribe learns who's talking", "Robotics, clubs, calls. Name a voice once and it's recognized next time.", "person.2.wave.2"),
        ("Notes and action items, automatically", "A summary, key points and who-does-what, right after you press Stop.", "checklist"),
        ("Works offline. Free forever.", "Everything runs on this Mac. No account, nothing uploaded.", "lock.shield"),
        ("Search every meeting", "Find the moment someone said “deadline” three weeks ago.", "magnifyingglass"),
        ("Clean words, not ums", "Fillers and stutters are removed; Apple Intelligence can polish the rest.", "wand.and.stars"),
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
        HStack(spacing: 12) {
            arrow("chevron.left") { go(-1) }.opacity(index > 0 ? 1 : 0.25).disabled(index == 0)
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
            arrow("chevron.right") { go(1) }
        }
    }

    private func arrow(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Ink.ink.opacity(0.7))
    }

    @ViewBuilder private func cardView(_ c: Card) -> some View {
        switch c {
        case .useCase(let k):
            let u = Self.useCases[k % Self.useCases.count]
            VStack(spacing: 14) {
                Mascot(pose: k % 2 == 0 ? .welcome : .about, height: 150)
                Label(u.title, systemImage: u.symbol)
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                    .foregroundStyle(Ink.ink)
                    .multilineTextAlignment(.center)
                Text(u.detail).font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
        case .microphone:
            setupCard(step: 1, title: "Let Scribe hear you", pose: .welcome) {
                PermissionRow(title: "Microphone", detail: "To hear you dictate and record meetings. Audio never leaves this Mac.",
                              granted: permissions.microphone == .authorized,
                              button: permissions.microphone == .notDetermined ? "Allow…" : "Open Settings") {
                    Task { await permissions.requestMicrophone() }
                }
            }
        case .accessibility:
            setupCard(step: 2, title: "Let Scribe type for you", pose: .about) {
                PermissionRow(title: "Accessibility", detail: "So the hold key works in other apps and Scribe can paste your words. Click Open Settings and switch Scribe on.",
                              granted: permissions.accessibility, button: "Open Settings") {
                    permissions.requestAccessibility()
                }
            }
        case .hotkey:
            setupCard(step: 3, title: "Pick your talk key", pose: .welcome) { HotkeyPicker() }
        case .tryIt:
            setupCard(step: 4, title: "Try it", pose: .about) { TryItBox(ready: store.engineReady) }
        case .game:
            RunnerGameView(game: game) { go(1) }
                .frame(maxWidth: 560)
        }
    }

    private func setupCard<Content: View>(step: Int, title: String, pose: Mascot.Pose,
                                          @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 24) {
            Mascot(pose: pose, height: 170)
            VStack(alignment: .leading, spacing: 12) {
                Text("Setup · step \(step) of 4").font(.caption.weight(.semibold)).foregroundStyle(Ink.royal)
                Text(title).font(.system(size: 24, weight: .semibold, design: .serif)).foregroundStyle(Ink.ink)
                content()
            }
            .frame(maxWidth: 380, alignment: .leading)
        }
    }

    // MARK: Bars

    private var topBar: some View {
        HStack {
            Text("Welcome to Scribe").font(.system(size: 15, weight: .semibold, design: .serif)).foregroundStyle(Ink.ink)
            Spacer()
            HStack(spacing: 10) {
                checklistDot("Mic", permissions.microphone == .authorized)
                checklistDot("Accessibility", permissions.accessibility)
                checklistDot("Dictation", store.engineReady)
                checklistDot("Meetings", store.meetingModelsReady)
            }
        }
        .padding(.horizontal, 8)
    }

    private func checklistDot(_ label: String, _ ok: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle").foregroundStyle(ok ? .green : .secondary)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(currentTitle).font(.callout.weight(.semibold)).foregroundStyle(Ink.ink).lineLimit(1)
                Text(currentDetail).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            Spacer()
            if store.engineError != nil {
                Button("Retry") { Task { await store.prepareEngine() } }
            }
            if allReady {
                Button("Start using Scribe") { onboarded = true }
                    .buttonStyle(.borderedProminent).tint(Ink.royal).controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Continue in the background") { onboarded = true }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Downloads keep going; the menu bar shows progress.")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
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
        if let e = store.engineError { return "Download paused — \(e.prefix(80))" }
        if let d = downloading { return "Downloading \(d.0.title)" }
        if !store.engineReady { return store.engineStatus }
        if !store.meetingModelsReady { return "Dictation is ready · getting the speaker models" }
        return "Ready — everything works offline now"
    }

    private var currentDetail: String {
        if let d = downloading { return d.1.text }
        if allReady { return "You can close this window any time; Scribe lives in the menu bar." }
        return "Hang tight — this only happens once."
    }
}

// MARK: - Glowing ring

/// A soft glowing border around the whole window that fills as progress grows, with a brighter
/// "comet" that slowly travels along the filled part. One TimelineView at 30 fps, paused when done.
struct GlowRing: View {
    var progress: Double
    var active: Bool
    var previewPhase: Double? = nil

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active || previewPhase != nil)) { tl in
            let phase = previewPhase ?? (tl.date.timeIntervalSinceReferenceDate / 6).truncatingRemainder(dividingBy: 1)
            let p = max(0.001, progress)
            let gradient = AngularGradient(
                gradient: Gradient(colors: [Ink.gold, Ink.royal.opacity(0.85), Ink.gold, Color(red: 1, green: 0.85, blue: 0.5), Ink.gold]),
                center: .center, angle: .degrees(phase * 360))
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            ZStack {
                // Faint full track so you can see where the ring will go.
                shape.inset(by: 3).stroke(Ink.parchmentDeep.opacity(0.8), lineWidth: 2.5)
                // The filled part: a wide blurred glow + a crisp line.
                shape.inset(by: 3).trim(from: 0, to: p).stroke(gradient, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .blur(radius: 9).opacity(0.85)
                shape.inset(by: 3).trim(from: 0, to: p).stroke(gradient, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                // The comet travelling along the filled part.
                if active {
                    let head = (phase * 1.0).truncatingRemainder(dividingBy: 1) * p
                    shape.inset(by: 3).trim(from: max(0, head - 0.05), to: head)
                        .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .blur(radius: 2)
                }
            }
            .animation(.easeOut(duration: 0.6), value: progress)
        }
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
