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
    private static func env<V: View>(_ v: V, store s: Store? = nil) -> some View {
        let model = AppModel.shared
        return v.environmentObject(model)
            .environmentObject(s ?? store!)
            .environmentObject(model.recorder)
            .environmentObject(model.dictation)
            .environmentObject(model.permissions)
            .environmentObject(model.models)
            .environmentObject(model.updater)
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

        var made: [String] = []
        let main = NSSize(width: 1100, height: 700)

        // First-run window mid-download: Parakeet 210 of 465 MB, VAD done, speaker models waiting.
        store.engineReady = false
        store.engineStatus = "Downloading speech model (one time)"
        let mid = DownloadProgress(doneBytes: 210_000_000, totalBytes: 465_500_000, bytesPerSecond: 23_400_000)
        model.models.setPreview(["asr-v2": .downloading(mid), "vad": .downloaded, "diarizer": .missing, "asr-v3": .missing])
        let obSize = NSSize(width: OnboardingView.size.width, height: OnboardingView.size.height)
        made += await capture(env(OnboardingView(initialIndex: 0, previewPhase: 0.3, previewPlanned: 487_400_000)),
                              size: obSize, name: "07a_firstrun_usecase", dir: dir)
        made += await capture(env(OnboardingView(initialIndex: 2, previewPhase: 0.55, previewPlanned: 487_400_000)),
                              size: obSize, name: "07b_firstrun_setup_mic", dir: dir)
        made += await capture(env(OnboardingView(initialIndex: 6, previewPhase: 0.8, previewPlanned: 487_400_000, previewGame: true)),
                              size: obSize, name: "07c_firstrun_game", dir: dir)
        store.engineReady = true
        store.engineStatus = "Ready"
        store.meetingModelsReady = true
        model.models.setPreview(["asr-v2": .downloaded, "vad": .downloaded, "diarizer": .downloaded,
                                 "asr-v3": .missing])
        made += await capture(env(OnboardingView(initialIndex: 9, previewPhase: 0.1, previewPlanned: 487_400_000)),
                              size: obSize, name: "07d_firstrun_ready", dir: dir)

        made += await capture(env(ContentView(initialSelection: .meeting(meetingID))), size: main, name: "01_meeting_notes", dir: dir)
        made += await capture(env(ContentView(initialSelection: .people)), size: main, name: "02_people", dir: dir)
        made += await capture(env(ContentView(initialSelection: .dictation)), size: main, name: "03_dictation_history", dir: dir)
        // Empty state: a brand-new library, no meetings yet.
        let emptyStore = Store(folder: tmp.appendingPathComponent("empty"))
        emptyStore.engineReady = true
        made += await capture(env(ContentView(), store: emptyStore), size: main, name: "13_main_empty_state", dir: dir)
        made += await capture(env(SettingsView()), size: NSSize(width: 520, height: 440), name: "04_settings_dictation", dir: dir)
        model.models.setPreview(["asr-v2": .downloaded, "vad": .downloaded, "diarizer": .updateAvailable(1_200_000),
                                 "asr-v3": .missing])
        made += await capture(env(ModelSettingsTab().frame(width: 520, height: 640)), size: nil, name: "05_settings_model", dir: dir)
        made += await capture(env(GeneralSettingsTab().frame(width: 520, height: 440)), size: nil, name: "05b_settings_general", dir: dir)
        made += await capture(env(AboutView().frame(width: 520, height: 440)), size: nil, name: "06_about_credits", dir: dir)
        made += await capture(env(MenuBarView().background(Color(nsColor: .windowBackgroundColor))), size: nil,
                              name: "08_menu_bar_panel", dir: dir, titled: false)

        // The scroll overlay, on a desktop-like backdrop (it floats over other apps), normal and 2.5× zoom.
        let listenTape = InkTape(); listenTape.fillPreview(seconds: 7.4)
        let writeTape = InkTape(); writeTape.fillPreview(seconds: 9.0); writeTape.stop(); writeTape.previewPhase = 0.62
        let meetTape = InkTape(); meetTape.fillPreview(seconds: 12.0)
        let frames: [(String, ScrollMode, InkTape, TimeInterval?)] = [
            ("09_scroll_listening", .listening, listenTape, nil),
            ("10_scroll_writing", .writing, writeTape, nil),
            ("11_scroll_meeting", .recording, meetTape, 754),
            ("12_scroll_done", .message("Done", failure: false), listenTape, nil),
        ]
        for (name, mode, tape, elapsed) in frames {
            made += await capture(scrollStage(ScribeScroll(mode: mode, tape: tape, elapsed: elapsed), zoom: 1),
                                  size: NSSize(width: 420, height: 140), name: name, dir: dir, titled: false)
            made += await capture(scrollStage(ScribeScroll(mode: mode, tape: tape, elapsed: elapsed), zoom: 2.5),
                                  size: NSSize(width: 960, height: 260), name: name + "_zoom", dir: dir, titled: false)
        }

        // Icons: what Finder/Dock show for this build, plus the menu bar glyphs.
        made += iconRenders(dir: dir)

        // Fallback: the real screen with the main window in front.
        let w = window(for: env(ContentView(initialSelection: .meeting(meetingID))), size: main, titled: true)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let full = dir.appendingPathComponent("15_screen_screencapture.png")
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

    private static func scrollStage(_ scroll: ScribeScroll, zoom: CGFloat) -> some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.20, green: 0.26, blue: 0.38), Color(red: 0.42, green: 0.36, blue: 0.48)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            scroll.scaleEffect(zoom)
        }
    }

    /// Finder's icon for this app (proves AppIcon is wired in), a Dock-style mock, and the
    /// menu bar scroll glyphs (black on a light bar, white on a dark bar) at 8×.
    private static func iconRenders(dir: URL) -> [String] {
        var out: [String] = []
        let finderIcon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        if savePNG(size: NSSize(width: 512, height: 512), to: dir.appendingPathComponent("14_icon_finder.png"), draw: { r in
            finderIcon.draw(in: r)
        }) { out.append("14_icon_finder.png") }
        let appIcon = NSApp.applicationIconImage ?? finderIcon
        if savePNG(size: NSSize(width: 640, height: 220), to: dir.appendingPathComponent("14_icon_dock_mock.png"), draw: { r in
            NSGradient(colors: [NSColor(calibratedRed: 0.35, green: 0.45, blue: 0.62, alpha: 1),
                                NSColor(calibratedRed: 0.62, green: 0.48, blue: 0.58, alpha: 1)])?.draw(in: r, angle: -20)
            let bar = NSRect(x: 40, y: 22, width: r.width - 80, height: 150)
            NSColor(white: 1, alpha: 0.28).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 28, yRadius: 28).fill()
            for (k, size) in [CGFloat(128), 64, 32, 16].enumerated() {
                let x = bar.minX + 30 + CGFloat(k) * 150
                appIcon.draw(in: NSRect(x: x, y: bar.midY - size / 2, width: size, height: size))
            }
        }) { out.append("14_icon_dock_mock.png") }
        let glyphs = [MenuBarGlyph.idle, MenuBarGlyph.live, MenuBarGlyph.busy]
        if savePNG(size: NSSize(width: 560, height: 300), to: dir.appendingPathComponent("14_menubar_glyphs.png"), draw: { r in
            for (row, dark) in [false, true].enumerated() {
                let band = NSRect(x: 0, y: CGFloat(row) * 150, width: r.width, height: 150)
                (dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                band.fill()
                for (k, g) in glyphs.enumerated() {
                    let rect = NSRect(x: 30 + CGFloat(k) * 180, y: band.minY + 11, width: 160, height: 128)
                    let tinted = NSImage(size: g.size, flipped: false) { gr in
                        g.draw(in: gr)
                        (dark ? NSColor.white : NSColor.black).set()
                        gr.fill(using: .sourceAtop)
                        return true
                    }
                    tinted.draw(in: rect)
                }
            }
        }) { out.append("14_menubar_glyphs.png") }
        return out
    }

    private static func savePNG(size: NSSize, to url: URL, draw: (NSRect) -> Void) -> Bool {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
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
