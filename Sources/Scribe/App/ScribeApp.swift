// ScribeApp.swift
// Entry point. Normally it starts the app (window + menu bar icon + hotkeys).
// If launched with --selftest (used by the GitHub Actions Mac runner) it runs a
// headless test and quits.

import SwiftUI
import Combine

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.runAndExit()            // never returns
        } else if CommandLine.arguments.contains("--snapshot") {
            Snapshot.runAndExit()            // renders the UI to PNGs (CI screenshots), never returns
        } else {
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

    /// The meeting scroll at the bottom of the screen while a meeting records.
    private let meetingOverlay = ScrollOverlay()
    let meetingTape = InkTape()
    private var bag: Set<AnyCancellable> = []
    @Published var alertText: String?

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        dictation.attach(store: store, recorder: recorder)
        // Meeting scroll: ink follows the recorder's mic level.
        recorder.$level.sink { [weak self] l in
            guard let self, self.recorder.isRecording else { return }
            self.meetingTape.add(l)
        }.store(in: &bag)
        recorder.$isRecording.removeDuplicates().sink { [weak self] on in
            guard let self else { return }
            if on && UserDefaults.standard.object(forKey: "showMeetingScroll") as? Bool ?? true {
                self.meetingTape.reset()
                self.meetingOverlay.show(MeetingScrollView(recorder: self.recorder, tape: self.meetingTape))
            } else {
                self.meetingOverlay.hide()
            }
        }.store(in: &bag)
        Task { await store.prepareEngine() }
        updater.checkInBackgroundIfDue()
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
                .frame(minWidth: 860, minHeight: 540)
                .onAppear { model.start() }
        }
        .windowStyle(.titleBar)
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
        } label: {
            MenuBarIcon(dictation: model.dictation, recorder: model.recorder)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(model.store)
                .environmentObject(model.dictation)
                .environmentObject(model.permissions)
                .environmentObject(model.models)
                .environmentObject(model.updater)
        }
    }
}

/// The menu bar icon: a small open scroll drawn in code as a template image (Theme.swift).
/// A dot appears on the parchment while listening/recording, three dots while writing.
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

/// A small palette so each person keeps the same color everywhere.
enum Palette {
    static let colors: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .red, .brown, .indigo, .mint]
    static func color(_ i: Int) -> Color { colors[abs(i) % colors.count] }
}
