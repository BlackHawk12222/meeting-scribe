// ScribeApp.swift
// Entry point. Normally it starts the app (window + menu bar icon + hotkeys).
// If launched with --selftest (used by the GitHub Actions Mac runner) it runs a
// headless test and quits.

import SwiftUI

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.runAndExit()            // never returns
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
    /// Set when a meeting recording stops, so the window can jump to it.
    @Published var justRecordedMeeting: UUID?
    @Published var alertText: String?

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        dictation.attach(store: store, recorder: recorder)
        Task { await store.prepareEngine() }
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
                .frame(minWidth: 860, minHeight: 540)
                .onAppear { model.start() }
        }
        .windowStyle(.titleBar)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
                .environmentObject(model.store)
                .environmentObject(model.recorder)
                .environmentObject(model.dictation)
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
        }
    }
}

/// The menu bar icon: a waveform, filled red-dot style while listening or recording.
struct MenuBarIcon: View {
    @ObservedObject var dictation: DictationController
    @ObservedObject var recorder: Recorder
    var body: some View {
        if dictation.state == .listening || recorder.isRecording {
            Image(systemName: "record.circle.fill")
        } else if dictation.state == .transcribing {
            Image(systemName: "ellipsis.circle")
        } else {
            Image(systemName: "waveform")
        }
    }
}

/// A small palette so each person keeps the same color everywhere.
enum Palette {
    static let colors: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .red, .brown, .indigo, .mint]
    static func color(_ i: Int) -> Color { colors[abs(i) % colors.count] }
}
