// ScribeApp.swift
// Entry point. Normally it starts the app (window + menu bar icon + hotkeys).
// If launched with --selftest (used by the GitHub Actions Mac runner) it runs a
// headless test and quits.

import SwiftUI
import Combine

@main
enum Main {
    static func main() {
        ScribeFonts.register()               // the bundled Manrope (Resources/Fonts, SIL OFL 1.1)
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.runAndExit()            // never returns
        } else if CommandLine.arguments.contains("--snapshot") {
            Snapshot.runAndExit()            // renders the UI to PNGs (CI screenshots), never returns
        } else {
            LegacyMigration.runOnce()        // settings + sync token from an older bundle id, once
            ScribeApp.main()
        }
    }
}

/// Everything the app shares between the window, the menu bar and the hotkeys.
/// It's created once, when the app launches (not when a window opens), so
/// dictation works even if you close the window.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let store = Store()
    let recorder = Recorder()
    let dictation = DictationController()
    let permissions = Permissions()
    let models = ModelStore.shared
    let updater = Updater()
    /// Set when a meeting recording stops, so the window can jump to it.
    @Published var justRecordedMeeting: UUID?
    /// Set by the menu bar ("open this meeting"); the main window selects it.
    @Published var openMeetingRequest: UUID?

    /// The meeting capsule (red dot + level bars + timer) while a meeting records.
    private let meetingOverlay = OverlayPanel()
    let meetingTape = LevelTape()
    private var bag: Set<AnyCancellable> = []
    @Published var alertText: String?

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        AppearanceChoice.apply()
        dictation.attach(store: store, recorder: recorder)
        // Meeting capsule: the bars follow the recorder's mic level.
        recorder.$level.sink { [weak self] l in
            guard let self, self.recorder.isRecording else { return }
            self.meetingTape.add(l)
        }.store(in: &bag)
        recorder.$isRecording.removeDuplicates().sink { [weak self] on in
            guard let self else { return }
            if on && UserDefaults.standard.object(forKey: "showMeetingScroll") as? Bool ?? true {
                self.meetingTape.reset()
                self.meetingOverlay.show(MeetingOverlayView(recorder: self.recorder, tape: self.meetingTape))
            } else {
                self.meetingOverlay.hide()
            }
        }.store(in: &bag)
        Task { await store.prepareEngine() }
        // Updates never restart Scribe while a meeting records or you're dictating.
        updater.isBusy = { [weak self] in
            guard let self else { return false }
            return self.recorder.isRecording || self.dictation.state.isBusy
        }
        updater.startAutomatic()
        // Typing permission lost (e.g. after an update)? Explain how to fix it, once per build.
        permissions.refresh()
        AccessibilityHelp.showAtLaunchIfNeeded()
        GitHubSync.shared.kick()          // send anything left in the queue from last time
    }

    /// Menu bar → "open this meeting in the main window".
    func openMeeting(_ id: UUID) {
        openMeetingRequest = id
    }

    /// Record / Stop a meeting (window button, ⌘R, or the menu bar).
    func toggleMeetingRecording() {
        if recorder.isRecording {
            if let (url, duration) = recorder.stop() {
                let m = store.addMeeting(audioURL: url, duration: duration)
                justRecordedMeeting = m.id
                Task { await store.process(m.id) }
            }
        } else {
            Task {
                guard await Recorder.requestPermission() else {
                    alertText = "Scribe needs the microphone. Turn it on in System Settings → Privacy & Security → Microphone."
                    return
                }
                do {
                    let cleanup = UserDefaults.standard.object(forKey: "noiseCleanup") as? Bool ?? true
                    try recorder.start(to: store.newRecordingURL(), noiseCleanup: cleanup)
                } catch {
                    alertText = "Couldn't start recording: \(error.localizedDescription)"
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.start() }
    }
    /// A downloaded update is swapped in when Scribe quits.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.updater.installOnQuitIfReady() }
    }
    /// Closing the window keeps Scribe running in the menu bar (dictation keeps working).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct ScribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("Scribe", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.store)
                .environmentObject(model.recorder)
                .environmentObject(model.dictation)
                .environmentObject(model.permissions)
                .environmentObject(model.models)
                .environmentObject(model.updater)
                .frame(minWidth: 960, minHeight: 600)
                .background(WindowChrome())
                .onAppear { model.start() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { model.updater.check(userInitiated: true) }
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
                .environmentObject(model.store)
                .environmentObject(model.recorder)
                .environmentObject(model.dictation)
                .environmentObject(model.models)
                .environmentObject(model.permissions)
                .environmentObject(model.updater)
        } label: {
            MenuBarIcon(dictation: model.dictation, recorder: model.recorder)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .background(WindowChrome())
                .environmentObject(model)
                .environmentObject(model.store)
                .environmentObject(model.dictation)
                .environmentObject(model.permissions)
                .environmentObject(model.models)
                .environmentObject(model.updater)
        }
    }
}

/// The menu bar icon: the capsule wave, drawn in code as a template image (Theme.swift).
/// A dot appears while listening/recording, three dots while transcribing.
struct MenuBarIcon: View {
    @ObservedObject var dictation: DictationController
    @ObservedObject var recorder: Recorder
    var body: some View {
        if dictation.state == .listening || recorder.isRecording {
            Image(nsImage: MenuBarGlyph.live)
        } else if dictation.state == .transcribing {
            Image(nsImage: MenuBarGlyph.busy)
        } else {
            Image(nsImage: MenuBarGlyph.idle)
        }
    }
}

/// The speaker palette (lavender, mint, peach, sky, rose, olive), so each person keeps the same
/// color everywhere. Avatars put dark text on top (Night.onSpeaker).
enum Palette {
    static let colors: [Color] = Night.speakers
    static func color(_ i: Int) -> Color { colors[abs(i) % colors.count] }
}

/// Custom window chrome: no title bar, content under the transparent titlebar, the traffic lights
/// floating over the rail's top-left, and the window movable by its background.
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ChromeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ChromeView: NSView {
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            guard let w = window else { return }
            WindowChrome.configure(w)
            let names: [Notification.Name] = [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                                              NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification]
            for n in names {
                observers.append(NotificationCenter.default.addObserver(forName: n, object: w, queue: .main) { note in
                    guard let win = note.object as? NSWindow else { return }
                    MainActor.assumeIsolated { WindowChrome.placeTrafficLights(win) }
                })
            }
        }

        deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
    }

    @MainActor
    static func configure(_ w: NSWindow) {
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.styleMask.insert(.fullSizeContentView)
        w.isMovableByWindowBackground = true
        w.titlebarSeparatorStyle = .none
        w.backgroundColor = NSColor.night(0xF8F5EF, 0x0E0E11)
        placeTrafficLights(w)
    }

    /// Nudges the close/minimize/zoom buttons toward 18/18 from the window's top-left corner
    /// (as far down as the titlebar view allows, so they stay clickable).
    @MainActor
    static func placeTrafficLights(_ w: NSWindow) {
        guard !w.styleMask.contains(.fullScreen) else { return }
        let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (i, kind) in kinds.enumerated() {
            guard let b = w.standardWindowButton(kind), let sv = b.superview else { continue }
            let h = b.frame.height
            let y = max(0, sv.bounds.height - 18 - h + 2)
            b.setFrameOrigin(NSPoint(x: 18 + CGFloat(i) * 20, y: y))
        }
    }
}
