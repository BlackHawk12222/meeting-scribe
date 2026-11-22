// Snapshot.swift
// `Scribe --snapshot --out <folder>` renders the main screens to PNG files with
// made-up SAMPLE data (a fake robotics meeting), so we can get screenshots from the
// GitHub Actions Mac runner. It never touches your real meetings: the sample store
// lives in a temporary folder.
//
// How: each SwiftUI view goes into a real (on-screen) NSWindow through NSHostingView,
// the run loop gets a moment to lay it out, then the view draws itself into a bitmap
// (bitmapImageRepForCachingDisplay + cacheDisplay). At the end it also runs
// `screencapture -x` with the main window in front, as a whole-screen fallback.

import AppKit
import SwiftUI

@MainActor
enum Snapshot {
    nonisolated static func runAndExit() -> Never {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            app.appearance = NSAppearance(named: .aqua)
            Task { @MainActor in
                await run()
                exit(0)
            }
            app.run()
        }
        exit(0)
    }

    private static var store: Store!

    /// Gives a view the same shared objects the real app gives it.
    private static func env<V: View>(_ v: V) -> some View {
        let model = AppModel.shared
        return v.environmentObject(model)
            .environmentObject(store!)
            .environmentObject(model.recorder)
            .environmentObject(model.dictation)
            .environmentObject(model.permissions)
    }

    static var outDir: URL {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--out"), i + 1 < args.count {
            return URL(fileURLWithPath: args[i + 1], isDirectory: true)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("snapshots")
    }

    static func run() async {
        let dir = outDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        UserDefaults.standard.set(true, forKey: "onboarded")      // keep the welcome sheet off the main window

        let model = AppModel.shared                                 // not started: no models, no hotkeys
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ScribeSnapshot-\(UUID().uuidString)")
        let store = Store(folder: tmp)
        Snapshot.store = store
        let meetingID = fillSampleData(store)
        store.engineReady = true
        store.engineStatus = "Ready"
        let dictation = model.dictation

        var made: [String] = []
        let main = NSSize(width: 1100, height: 700)
        made += await capture(env(ContentView(initialSelection: .meeting(meetingID))), size: main, name: "01_meeting_notes", dir: dir)
        made += await capture(env(ContentView(initialSelection: .people)), size: main, name: "02_people", dir: dir)
        made += await capture(env(ContentView(initialSelection: .dictation)), size: main, name: "03_dictation_history", dir: dir)
        made += await capture(env(SettingsView()), size: NSSize(width: 520, height: 440), name: "04_settings_dictation", dir: dir)
        made += await capture(env(ModelSettingsTab().frame(width: 520, height: 440)), size: nil, name: "05_settings_model", dir: dir)
        made += await capture(env(AboutView().frame(width: 520, height: 440)), size: nil, name: "06_about_credits", dir: dir)
        made += await capture(env(OnboardingView()), size: nil, name: "07_onboarding", dir: dir)
        made += await capture(env(MenuBarView().background(Color(nsColor: .windowBackgroundColor))), size: nil,
                              name: "08_menu_bar_panel", dir: dir, titled: false)

        // The recording pill, on a dark desktop-like backdrop (it floats over other apps).
        let levels: [Float] = [0.15, 0.3, 0.55, 0.8, 0.6, 0.35, 0.7, 0.9, 0.5, 0.3, 0.6, 0.75, 0.4, 0.25, 0.45, 0.2]
        dictation.setPreview(state: .listening, levels: levels, elapsed: 7)
        made += await capture(pillStage(dictation), size: NSSize(width: 420, height: 140), name: "09_pill_listening", dir: dir, titled: false)
        dictation.setPreview(state: .transcribing, levels: levels, elapsed: 7)
        made += await capture(pillStage(dictation), size: NSSize(width: 420, height: 140), name: "10_pill_writing", dir: dir, titled: false)
        dictation.setPreview(state: .idle, levels: Array(repeating: 0, count: 16), elapsed: 0)

        // Fallback: the real screen with the main window in front.
        let w = window(for: env(ContentView(initialSelection: .meeting(meetingID))), size: main, titled: true)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let full = dir.appendingPathComponent("11_screen_screencapture.png")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", full.path]
        try? p.run()
        p.waitUntilExit()
        if FileManager.default.fileExists(atPath: full.path) { made.append(full.lastPathComponent) }
        w.close()

        let note = ["note": "SAMPLE data (made-up meeting/people/dictations), rendered by Scribe --snapshot on the CI Mac runner.",
                    "files": made.joined(separator: ", ")]
        if let d = try? JSONSerialization.data(withJSONObject: note, options: [.prettyPrinted]) {
            try? d.write(to: dir.appendingPathComponent("index.json"))
        }
        print("SNAPSHOT_DONE: \(made.count) files in \(dir.path)")
        try? FileManager.default.removeItem(at: tmp)
    }

    private static func pillStage(_ dictation: DictationController) -> some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.20, green: 0.26, blue: 0.38), Color(red: 0.42, green: 0.36, blue: 0.48)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            PillView().environmentObject(dictation).frame(width: 240, height: 46)
        }
    }

    private static func window<V: View>(for view: V, size: NSSize?, titled: Bool) -> NSWindow {
        let host = NSHostingView(rootView: view)
        let s = size ?? host.fittingSize
        let style: NSWindow.StyleMask = titled ? [.titled, .closable, .miniaturizable, .resizable] : [.borderless]
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: s), styleMask: style, backing: .buffered, defer: false)
        w.title = "Scribe"
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .aqua)
        w.contentView = host
        w.setContentSize(s)
        w.center()
        w.orderFrontRegardless()
        return w
    }

    /// Returns the file names written (the view alone, and for titled windows also the window frame).
    private static func capture<V: View>(_ view: V, size: NSSize?, name: String, dir: URL, titled: Bool = true) async -> [String] {
        let w = window(for: view, size: size, titled: titled)
        try? await Task.sleep(nanoseconds: 1_500_000_000)          // let SwiftUI lay out + load
        var out: [String] = []
        if let host = w.contentView {
            host.layoutSubtreeIfNeeded()
            if write(host, to: dir.appendingPathComponent("\(name).png")) { out.append("\(name).png") }
            if titled, let frame = host.superview,
               write(frame, to: dir.appendingPathComponent("\(name)_window.png")) { out.append("\(name)_window.png") }
        }
        w.close()
        print("snapshot \(name): \(out)")
        return out
    }

    private static func write(_ view: NSView, to url: URL) -> Bool {
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return false }
        view.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }

    // MARK: - Sample data (made up)

    private static func fillSampleData(_ store: Store) -> UUID {
        let cal = Calendar.current
        let now = Date()
        let names = ["Alex", "Sam", "Jordan", "Taylor"]
        let mID = UUID()
        var people: [Person] = []
        for (i, n) in names.enumerated() {
            var p = Person(name: n, colorIndex: i)
            let meetings = [5, 3, 2, 1][i]
            for k in 0..<meetings {
                p.samples.append(VoiceSample(vector: [], meetingID: k == 0 ? mID : UUID(), clusterKey: "S\(i + 1)", addedAt: now))
            }
            people.append(p)
        }
        store.people = people

        let lines: [(String, String)] = [
            ("S1", "Okay, let's start. The deadline is in three weeks, so today is about the intake and the autonomous route."),
            ("S2", "The intake jammed twice at practice. I think the rubber bands on the roller are too loose."),
            ("S3", "I can reprint the roller hub tonight with tighter slots. That should fix the slipping."),
            ("S1", "Good. Jordan, can you have the new hub on the robot by Thursday?"),
            ("S3", "Yeah, I'll have it on by Thursday."),
            ("S4", "The autonomous route is scoring two rings right now. We need to get it to four."),
            ("S2", "If we move the first turn earlier we save almost a second. I'll test that on Saturday."),
            ("S1", "We also need to update the engineering notebook before the judges see it."),
            ("S4", "I'll write up the intake changes and the test results in the notebook."),
            ("S1", "Great. Let's meet again Monday and run full matches."),
        ]
        var t = 0.0
        var utterances: [Utterance] = []
        var talk: [String: Double] = [:]
        for (k, text) in lines {
            let d = Double(text.split(separator: " ").count) * 0.42 + 0.6
            utterances.append(Utterance(start: t, end: t + d, speakerKey: k, text: text))
            talk[k, default: 0] += d
            t += d + 0.5
        }
        var clusters: [SpeakerCluster] = []
        for (i, key) in ["S1", "S2", "S3", "S4"].enumerated() {
            var c = SpeakerCluster(key: key, talkSeconds: talk[key] ?? 0, centroid: [], spanEmbeddings: [])
            if i < 3 {
                c.personID = people[i].id
                c.matchScore = [0.82, 0.74, 0.66][i]
                c.confirmed = i == 0
            } else {
                c.suggestedPersonID = people[3].id            // shows "maybe Taylor?"
                c.matchScore = 0.48
            }
            clusters.append(c)
        }
        let notes = MeetingNotes(
            summary: "The team planned for a deadline in three weeks: fixing the intake jam, speeding up the autonomous route, and updating the engineering notebook.",
            keyPoints: ["Intake jammed twice; roller bands are too loose",
                        "Autonomous scores 2 rings, goal is 4",
                        "Moving the first turn earlier saves about a second",
                        "Notebook must be updated before judging"],
            actionItems: [ActionItem(task: "Reprint the roller hub and have it on the robot by Thursday", owner: "Jordan"),
                          ActionItem(task: "Test the earlier first turn in autonomous on Saturday", owner: "Sam"),
                          ActionItem(task: "Write up intake changes and test results in the notebook", owner: "Speaker 4", done: true)],
            method: .rules, createdAt: now, seconds: 0.01,
            note: "Sample data for screenshots.")
        var m = Meeting(id: mID, title: "Team – project planning", date: cal.date(byAdding: .hour, value: -2, to: now)!,
                        duration: t, audioFileName: "sample.wav")
        m.status = .done
        m.utterances = utterances
        m.clusters = clusters
        m.processingSeconds = t / 9
        m.notes = notes

        var m2 = Meeting(title: "Client call – website", date: cal.date(byAdding: .day, value: -2, to: now)!,
                         duration: 1260, audioFileName: "sample2.wav")
        m2.status = .done
        m2.clusters = [SpeakerCluster(key: "S1", talkSeconds: 700, centroid: [], spanEmbeddings: [], personID: people[0].id),
                       SpeakerCluster(key: "S2", talkSeconds: 560, centroid: [], spanEmbeddings: [])]
        var m3 = Meeting(title: "Study group", date: cal.date(byAdding: .day, value: -5, to: now)!,
                         duration: 2710, audioFileName: "sample3.wav")
        m3.status = .done
        m3.clusters = [SpeakerCluster(key: "S1", talkSeconds: 900, centroid: [], spanEmbeddings: []),
                       SpeakerCluster(key: "S2", talkSeconds: 800, centroid: [], spanEmbeddings: []),
                       SpeakerCluster(key: "S3", talkSeconds: 600, centroid: [], spanEmbeddings: [])]
        store.meetings = [m, m2, m3]

        store.dictations = [
            DictationEntry(date: cal.date(byAdding: .minute, value: -4, to: now)!,
                           text: "Hey, can you send me the updated CAD file for the intake before practice tomorrow?",
                           raw: "Hey, um, can you send me the updated CAD file for the intake before practice tomorrow?",
                           method: .rules, audioSeconds: 5.8, latencySeconds: 0.6),
            DictationEntry(date: cal.date(byAdding: .minute, value: -38, to: now)!,
                           text: "The homepage hero should use the frosted glass card and one short headline.",
                           raw: "The homepage hero should use the the frosted glass card and uh one short headline.",
                           method: .rules, audioSeconds: 6.4, latencySeconds: 0.7),
            DictationEntry(date: cal.date(byAdding: .hour, value: -3, to: now)!,
                           text: "Remind me to finish the physics worksheet tonight.",
                           raw: "Remind me to finish the physics worksheet tonight.",
                           method: .none, audioSeconds: 2.9, latencySeconds: 0.4),
        ]
        return mID
    }
}
