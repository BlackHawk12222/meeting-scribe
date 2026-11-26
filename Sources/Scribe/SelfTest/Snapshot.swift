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
        made += await capture(env(OnboardingView(initialIndex: 0, previewPhase: 0.3, previewPlanned: 487_400_000)),
                              size: obSize, name: "07a_firstrun_usecase_dark", dir: dir, dark: true)
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

        // 0.7 "Night Sky": the mocked screens (design-v07), window server grabs with the custom chrome
        // (traffic lights over the rail), 1200×800 like the mockups. N06 is the light theme.
        let nightSize = NSSize(width: 1200, height: 800)
        // 0.7.3 Profile: an invented sample name (no real person), member since a fixed sample date.
        store.profile = UserProfile(displayName: "Robin Vale", memberSince: Date(timeIntervalSince1970: 1_751_328_000))
        let liveTape = LevelTape(); liveTape.fillPreview(seconds: 30)
        // 0.7.3.1: the live meeting view shows the recording-consent notice (as on a first meeting).
        model.consent.showForPreview()
        let nightShots: [(String, AnyView, Bool)] = [
            ("P01_home_light", AnyView(env(ContentView(section: .home))), false),
            ("P01b_home_dark", AnyView(env(ContentView(section: .home))), true),
            ("P02_dictation_light", AnyView(env(ContentView(initialSelection: .dictation))), false),
            ("P02b_dictation_dark", AnyView(env(ContentView(initialSelection: .dictation))), true),
            ("P03_meeting_light", AnyView(env(ContentView(initialSelection: .meeting(meetingID)))), false),
            ("P03b_meeting_dark", AnyView(env(ContentView(initialSelection: .meeting(meetingID)))), true),
            ("P03c_meeting_live_light", AnyView(env(ContentView(section: .meetings,
                                                               livePreview: LivePreview(elapsed: 768, tape: liveTape)))), false),
            ("P03d_meeting_live_dark", AnyView(env(ContentView(section: .meetings,
                                                               livePreview: LivePreview(elapsed: 768, tape: liveTape)))), true),
            ("P04_people_light", AnyView(env(ContentView(initialSelection: .people))), false),
            ("P04b_people_dark", AnyView(env(ContentView(initialSelection: .people))), true),
            ("P05_settings_general_light", AnyView(env(ContentView(section: .settings, settingsPane: .general))), false),
            ("P05b_settings_general_dark", AnyView(env(ContentView(section: .settings, settingsPane: .general))), true),
            ("P05c_settings_models_light", AnyView(env(ContentView(section: .settings, settingsPane: .models))), false),
            ("P05d_settings_dictation_light", AnyView(env(ContentView(section: .settings, settingsPane: .dictation))), false),
            ("P07_profile_light", AnyView(env(ContentView(section: .profile))), false),
            ("P07b_profile_dark", AnyView(env(ContentView(section: .profile))), true),
            ("P09_settings_vocabulary_light", AnyView(env(ContentView(section: .settings, settingsPane: .vocabulary))), false),
            ("P09b_settings_models_dark", AnyView(env(ContentView(section: .settings, settingsPane: .models))), true),
            // 0.7.3.1 Credits & licenses (Settings › General › Credits & licenses).
            ("P11_settings_credits_light", AnyView(env(ContentView(section: .settings, settingsPane: .credits))), false),
            ("P11b_settings_credits_dark", AnyView(env(ContentView(section: .settings, settingsPane: .credits))), true),
        ]
        for (name, view, dark) in nightShots {
            made += await serverCapture(view, size: nightSize, name: name, dir: dir, dark: dark, chrome: true)
        }
        // 0.7.3 "Learn from my fixes": the edit sheet (sample text).
        for dark in [false, true] {
            made += await serverCapture(env(EditTextSheet(title: "Edit dictation", original: "Ask zorvath to send teh robot notes before practice.") { _ in }),
                                        size: NSSize(width: 560, height: 300), name: dark ? "P10b_edit_text_dark" : "P10_edit_text_light",
                                        dir: dir, dark: dark)
        }
        // 0.7.3 "Name voices" editor on the sample meeting: a selection, the playhead inside it.
        if let sm = store.meetings.first(where: { $0.id == meetingID }) {
            let edSize = NSSize(width: VoiceEditorView.size.width, height: VoiceEditorView.size.height)
            for dark in [false, true] {
                let ed = VoiceEditorModel(meeting: sm, audioURL: nil, preview: true)
                let span = sm.utterances.dropFirst().first.map { $0.start...$0.end } ?? 5...12
                ed.selection = span
                ed.seek(span.lowerBound + (span.upperBound - span.lowerBound) * 0.4)
                made += await serverCapture(env(VoiceEditorView(meeting: sm, audioURL: nil, preview: ed)), size: edSize,
                                            name: dark ? "P08b_name_voices_dark" : "P08_name_voices_light", dir: dir, dark: dark)
            }
        }
        // 0.7.3.1: the whole Credits & licenses page, Parakeet v2's license text open.
        for dark in [false, true] {
            let page = ScrollView {
                CreditsPage(expanded: ["parakeet-tdt-0.6b-v2"]).padding(28).frame(width: 680, alignment: .leading)
            }
            .background(Night.canvas)
            made += await serverCapture(env(page), size: NSSize(width: 680, height: 1000),
                                        name: dark ? "P11d_credits_full_dark" : "P11c_credits_full_light", dir: dir, dark: dark)
        }
        // 0.7.3 Poster capsule: the four states, horizontal and vertical (left/right edge), on a
        // light and a dark backdrop.
        for dark in [false, true] {
            made += await serverCapture(capsuleSheet(dark: dark), size: NSSize(width: 1000, height: 560),
                                        name: dark ? "P06b_capsule_states_dark" : "P06_capsule_states_light",
                                        dir: dir, titled: false, dark: dark)
        }
        // 0.7.3.2 Meetings dashboard (sample meetings above); the detail with its Back button is P03/P03b.
        for dark in [false, true] {
            made += await serverCapture(env(ContentView(section: .meetings)), size: nightSize,
                                        name: dark ? "P13b_meetings_dashboard_dark" : "P13_meetings_dashboard_light",
                                        dir: dir, dark: dark, chrome: true)
            made += await serverCapture(env(ContentView(initialSelection: .meeting(meetingID))), size: nightSize,
                                        name: dark ? "P14b_meeting_detail_back_dark" : "P14_meeting_detail_back_light",
                                        dir: dir, dark: dark, chrome: true)
        }
        // 0.7.6: the Meetings dashboard fills the page edge to edge: a wide window (borderless + offscreen `capture`:
        // the runner's screen is 1024 pt and macOS shrinks a titled window to fit it) and the smallest window.
        made += await capture(env(ContentView(section: .meetings)), size: NSSize(width: 2000, height: 1000),
                                    name: "P13w_meetings_dashboard_wide_light", dir: dir, titled: false, dark: false)
        made += await capture(env(ContentView(section: .meetings)), size: NSSize(width: 2000, height: 1000),
                                    name: "P13wb_meetings_dashboard_wide_dark", dir: dir, titled: false, dark: true)
        made += await serverCapture(env(ContentView(section: .meetings)), size: NSSize(width: 960, height: 600),
                                    name: "P13n_meetings_dashboard_small_light", dir: dir, dark: false, chrome: true)
        made += await capture(env(ContentView(section: .dictations)), size: NSSize(width: 2000, height: 1000),
                                    name: "P13x_dictation_wide_light", dir: dir, titled: false, dark: false)
        // 0.7.3.2 My voice: not set up (Settings › Meetings), then set up with invented voice numbers.
        for dark in [false, true] {
            made += await serverCapture(env(ContentView(section: .settings, settingsPane: .meetings)), size: nightSize,
                                        name: dark ? "P11b_my_voice_not_enrolled_dark" : "P11_my_voice_not_enrolled_light",
                                        dir: dir, dark: dark, chrome: true)
        }
        var srng = SeededRandom(seed: 9)
        let base = (0..<256).map { _ in Float(srng.next() * 2 - 1) }
        store.enrollMe(clips: EnrollmentStyle.allCases.map { s in (s, base.map { $0 + Float(srng.next() * 0.1) }) })
        _ = store.trainMyVoice(embedding: base)
        for dark in [false, true] {
            made += await serverCapture(env(ContentView(section: .settings, settingsPane: .meetings)), size: nightSize,
                                        name: dark ? "P11d_my_voice_enrolled_dark" : "P11c_my_voice_enrolled_light",
                                        dir: dir, dark: dark, chrome: true)
            let v = MyVoice.verdict(score: 0.78)
            made += await serverCapture(env(MyVoiceSheet(preview: .result(ok: v.matched, headline: v.headline, detail: v.detail))),
                                        size: NSSize(width: MyVoiceSheet.size.width, height: MyVoiceSheet.size.height),
                                        name: dark ? "P11f_my_voice_tested_dark" : "P11e_my_voice_tested_light", dir: dir, dark: dark)
        }
        made += await serverCapture(env(MyVoiceSheet(preview: .recording(.test))),
                                    size: NSSize(width: MyVoiceSheet.size.width, height: MyVoiceSheet.size.height),
                                    name: "P11g_my_voice_testing_light", dir: dir)
        // 0.7.3.2 Profile › Account (invented email; preview models never call a server). P07/P07b
        // above show this build's real state ("Accounts coming soon" while no backend is set).
        let realAccount = AccountModel.shared
        let accountShots: [(String, AccountModel.Phase, Date?)] = [
            ("P12_profile_signed_out", .signedOut, nil),
            ("P12c_profile_signed_in", .signedIn(email: "robin@sample.invalid"), Date().addingTimeInterval(-180)),
        ]
        for (name, phase, synced) in accountShots {
            for dark in [false, true] {
                AccountModel.shared = AccountModel.preview(phase, lastSynced: synced)
                made += await serverCapture(env(ContentView(section: .profile)), size: nightSize,
                                            name: name + (dark ? "_dark" : "_light"), dir: dir, dark: dark, chrome: true)
            }
        }
        // The whole Profile page signed in (taller than the runner's screen, so drawn off-screen
        // with cacheDisplay in a borderless window): Account + the My voice row once set up.
        for dark in [false, true] {
            AccountModel.shared = AccountModel.preview(.signedIn(email: "robin@sample.invalid"), lastSynced: Date().addingTimeInterval(-180))
            made += await capture(env(ContentView(section: .profile)), size: NSSize(width: 1200, height: 1180),
                                  name: dark ? "P12d_profile_full_signed_in_dark" : "P12d_profile_full_signed_in_light",
                                  dir: dir, titled: false, dark: dark)
        }
        AccountModel.shared = AccountModel.preview(.codeSent(email: "robin@sample.invalid"))
        made += await serverCapture(env(ContentView(section: .profile)), size: nightSize, name: "P12e_profile_code_light",
                                    dir: dir, chrome: true)
        AccountModel.shared = AccountModel.preview(.showRecoveryKey(email: "robin@sample.invalid",
                                                                    recoveryKey: SyncCrypto.recoveryKey(SyncCrypto.newKey())))
        made += await serverCapture(env(ContentView(section: .profile)), size: nightSize, name: "P12f_profile_recovery_key_light",
                                    dir: dir, chrome: true)
        AccountModel.shared = realAccount
        // 0.7.5: the live meeting view when a source isn't delivering sound (+ the "Mic + Mac sound" input).
        let probTape = LevelTape(); probTape.fillPreview(seconds: 30)
        made += await serverCapture(env(ContentView(section: .meetings,
                                                    livePreview: LivePreview(elapsed: 42, tape: probTape, problem: .systemSilent))),
                                    size: nightSize, name: "P13_meeting_live_system_audio_problem_light", dir: dir, chrome: true)
        made += await serverCapture(env(ContentView(section: .meetings,
                                                    livePreview: LivePreview(elapsed: 42, tape: probTape, problem: .micSilent))),
                                    size: nightSize, name: "P13b_meeting_live_mic_silent_dark", dir: dir, dark: true, chrome: true)
        // 0.7.5: the sign-in step now says "click the link (or type the code)".
        AccountModel.shared = AccountModel.preview(.codeSent(email: "robin@sample.invalid"))
        made += await serverCapture(env(ContentView(section: .profile)), size: nightSize, name: "P13c_profile_link_or_code_dark",
                                    dir: dir, dark: true, chrome: true)
        AccountModel.shared = realAccount
        // 0.7.6 Settings › Learning with INVENTED sample data (no real fixes, no audio): learned fix-ups,
        // suggestions, and 23 minutes of saved corrections (JSON stubs in the sample store's folder).
        made += await learningShots(store: store, dir: dir)
        // 0.7.2 targeted CI: only the Night/Daylight screens (+ the smallest window size).
        if CommandLine.arguments.contains("--quick") {
            made += await serverCapture(env(ContentView(section: .home)), size: NSSize(width: 900, height: 600),
                                        name: "N09_home_light_small", dir: dir, dark: false, chrome: true)
            made += await serverCapture(env(ContentView(section: .home)), size: NSSize(width: 900, height: 600),
                                        name: "N09b_home_dark_small", dir: dir, dark: true, chrome: true)
            print("snapshot quick set done: \(made.count) files")
            return
        }
        made += await capture(env(ContentView(section: .home)), size: nightSize, name: "N01c_home_dark_cache", dir: dir, dark: true, chrome: true)
        made += await serverCapture(env(VoiceEnrollmentView(preview: .init(step: .recording, name: "Priya", index: 3))),
                                    size: NSSize(width: VoiceEnrollmentView.size.width, height: VoiceEnrollmentView.size.height),
                                    name: "N03b_enroll_recording_dark", dir: dir, dark: true)
        made += await serverCapture(env(SettingsView()), size: NSSize(width: SettingsView.size.width, height: SettingsView.size.height),
                                    name: "N04e_settings_window_dark", dir: dir, dark: true, chrome: true)
        made += await serverCapture(env(MenuBarView()), size: nil, name: "N07_menu_bar_panel_dark", dir: dir, titled: false, dark: true)
        made += await serverCapture(env(OnboardingView(initialIndex: 0, previewPhase: 0.3, previewPlanned: 487_400_000)),
                                    size: obSize, name: "N08_firstrun_dark", dir: dir, dark: true)

        made += await capture(env(ContentView(initialSelection: .meeting(meetingID))), size: main, name: "01_meeting_notes", dir: dir)
        made += await capture(env(ContentView(initialSelection: .people)), size: main, name: "02_people", dir: dir)
        made += await capture(env(ContentView(initialSelection: .dictation)), size: main, name: "03_dictation_history", dir: dir)
        // Empty state: a brand-new library, no meetings yet.
        let emptyStore = Store(folder: tmp.appendingPathComponent("empty"))
        emptyStore.engineReady = true
        made += await capture(env(ContentView(), store: emptyStore), size: main, name: "13_main_empty_state", dir: dir)
        made += await capture(env(SettingsView()), size: NSSize(width: SettingsView.size.width, height: SettingsView.size.height),
                              name: "04_settings_dictation", dir: dir)
        // 0.6: the same screens grabbed by the window server (screencapture -l <window>), so Liquid
        // Glass and materials look exactly as on screen (cacheDisplay can't draw them).
        let glassMain = NSSize(width: 1000, height: 680)
        made += await serverCapture(env(ContentView(initialSelection: .meeting(meetingID))), size: glassMain,
                                    name: "G01_main_notes", dir: dir)
        made += await serverCapture(env(ContentView(initialSelection: .meeting(meetingID))), size: glassMain,
                                    name: "G01b_main_notes_dark", dir: dir, dark: true)
        made += await serverCapture(env(ContentView(initialSelection: .dictation)), size: glassMain,
                                    name: "G03_dictation_history", dir: dir)
        made += await serverCapture(env(ContentView(initialSelection: .people)), size: glassMain,
                                    name: "G02_people", dir: dir)
        made += await serverCapture(env(ContentView(), store: emptyStore), size: glassMain, name: "G13_main_empty", dir: dir)
        // 0.6: People with the "Add person" button, then the guided enrollment sheet step by step
        // (made-up name, no microphone: the view opens at a given step with preview state).
        made += await serverCapture(env(ContentView(initialSelection: .people)), size: glassMain,
                                    name: "E01_people_add_person", dir: dir)
        made += await serverCapture(env(ContentView(initialSelection: .people)), size: glassMain,
                                    name: "E01b_people_add_person_dark", dir: dir, dark: true)
        made += await serverCapture(env(ContentView(initialSelection: .people), store: emptyStore), size: glassMain,
                                    name: "E01c_people_empty_add_person", dir: dir)
        let enrollSize = NSSize(width: VoiceEnrollmentView.size.width, height: VoiceEnrollmentView.size.height)
        let enrollSteps: [(String, VoiceEnrollmentView.Preview, Bool)] = [
            ("E02_enroll_intro", .init(step: .intro, name: ""), false),
            ("E03_enroll_prompt", .init(step: .prompt), false),
            ("E03b_enroll_prompt_dark", .init(step: .prompt), true),
            ("E03d_enroll_prompt_longest", .init(step: .prompt, index: 0), false),
            ("E04_enroll_recording", .init(step: .recording, index: 3), false),
            ("E05_enroll_redo", .init(step: .redo, index: 2), false),
            ("E06_enroll_done", .init(step: .done), false),
        ]
        for (name, preview, dark) in enrollSteps {
            made += await serverCapture(env(VoiceEnrollmentView(preview: preview)), size: enrollSize, name: name, dir: dir, dark: dark)
        }
        made += await capture(env(VoiceEnrollmentView(preview: .init(step: .prompt))), size: enrollSize,
                              name: "E03c_enroll_prompt_cache", dir: dir)
        made += await serverCapture(env(SettingsView()), size: NSSize(width: SettingsView.size.width, height: SettingsView.size.height),
                                    name: "G04_settings_dictation", dir: dir)
        made += await serverCapture(env(MenuBarView().background(Warm.canvas)), size: nil, name: "G08_menu_bar_panel", dir: dir,
                                    titled: false)
        // The whole Dictation tab (it scrolls in the real window), to show Overlay > Position.
        UserDefaults.standard.set(OverlayPosition.bottomCenter.rawValue, forKey: OverlayPosition.key)
        made += await capture(env(OverlaySettingsTab().padding(24).frame(width: 640, height: 420).background(Night.canvas)), size: nil,
                              name: "04b_settings_overlay_position", dir: dir)
        // Same tab with the left-edge preset: the preview shows the upright capsule.
        UserDefaults.standard.set(OverlayPosition.middleLeft.rawValue, forKey: OverlayPosition.key)
        made += await capture(env(OverlaySettingsTab().padding(24).frame(width: 640, height: 420).background(Night.canvas)), size: nil,
                              name: "04c_settings_overlay_left_edge", dir: dir)
        UserDefaults.standard.set(OverlayPosition.bottomCenter.rawValue, forKey: OverlayPosition.key)
        model.models.setPreview(["asr-v2": .downloaded, "vad": .downloaded, "diarizer": .updateAvailable(1_200_000),
                                 "asr-v3": .missing, "ctc-110m": .downloaded])
        made += await capture(env(ModelSettingsTab().frame(width: 520, height: 640)), size: nil, name: "05_settings_model", dir: dir)
        made += await capture(env(GeneralSettingsTab().frame(width: 560, height: 460)), size: nil, name: "05b_settings_general", dir: dir)
        // voice-test: Test my voice (made-up numbers, labelled "Sample numbers" on the screen).
        made += await capture(env(VoiceTestView(model: VoiceTestModel.preview(results: false)).frame(width: 620, height: 520)), size: nil,
                              name: "19a_test_my_voice_prompt", dir: dir)
        made += await capture(env(VoiceTestView(model: VoiceTestModel.preview(results: true)).frame(width: 620, height: 520)), size: nil,
                              name: "19b_test_my_voice_results", dir: dir)
        // 0.5: Vocabulary tab, Permissions tab (Accessibility banner + typing test), the banner alone.
        made += await capture(env(VocabularySettingsTab().frame(width: SettingsView.size.width, height: 600)), size: nil,
                              name: "16_settings_vocabulary", dir: dir)
        made += await capture(env(PermissionsTab().frame(width: SettingsView.size.width, height: 640)), size: nil,
                              name: "17_settings_permissions", dir: dir)
        made += await capture(env(AccessibilityBanner(permissions: model.permissions).padding(12).frame(width: 296)
                                    .background(Color(nsColor: .windowBackgroundColor))), size: nil,
                              name: "18_accessibility_banner", dir: dir, titled: false)
        made += await capture(env(SyncSettingsTab().frame(width: 520, height: 520)), size: nil, name: "05c_settings_sync", dir: dir)
        made += await capture(env(AboutView().frame(width: 560, height: 500)), size: nil, name: "06_about_credits", dir: dir)
        made += await capture(env(MenuBarView().background(Color(nsColor: .windowBackgroundColor))), size: nil,
                              name: "08_menu_bar_panel", dir: dir, titled: false)
        made += await capture(env(MenuBarView().background(Color(nsColor: .windowBackgroundColor))), size: nil,
                              name: "08b_menu_bar_panel_dark", dir: dir, titled: false, dark: true)

        // The recording overlay capsule: each state at 1x and 3x on a desktop-like backdrop,
        // then two full-screen mocks showing where it sits (bottom center, top right).
        let listenTape = LevelTape(); listenTape.fillPreview(seconds: 7.4)
        let meetTape = LevelTape(); meetTape.fillPreview(seconds: 12.0)
        let frames: [(String, OverlayMode, LevelTape, TimeInterval?)] = [
            ("09_overlay_listening", .listening, listenTape, nil),
            ("10_overlay_transcribing", .transcribing, listenTape, nil),
            ("11_overlay_meeting", .recording, meetTape, 754),
            ("12_overlay_done", .message("Done", failure: false), listenTape, nil),
            ("19_overlay_needs_accessibility", .needsAccess, listenTape, nil),
            ("20_overlay_no_text_box", .message("Copied — no text box selected", failure: false), listenTape, nil),
        ]
        for (name, mode, tape, elapsed) in frames {
            let capsule = OverlayCapsule(mode: mode, tape: tape, elapsed: elapsed, previewSpin: 40)
            made += await capture(overlayStage(capsule, zoom: 1), size: NSSize(width: 360, height: 120), name: name, dir: dir, titled: false)
            made += await capture(overlayStage(capsule, zoom: 3), size: NSSize(width: 900, height: 240), name: name + "_zoom", dir: dir, titled: false)
        }
        // 0.6: the capsule through the window server (real glass), on a wallpaper and on a white page.
        made += await serverCapture(overlayStage(OverlayCapsule(mode: .listening, tape: listenTape, previewSpin: 40), zoom: 3),
                                    size: NSSize(width: 900, height: 240), name: "G09_capsule_listening_zoom", dir: dir, titled: false)
        made += await serverCapture(overlayStage(OverlayCapsule(mode: .recording, tape: meetTape, elapsed: 754, previewSpin: 40), zoom: 3),
                                    size: NSSize(width: 900, height: 240), name: "G11_capsule_meeting_zoom", dir: dir, titled: false)
        made += await serverCapture(ZStack {
                                        Color.white
                                        OverlayCapsule(mode: .transcribing, tape: listenTape, previewSpin: 40).scaleEffect(3)
                                    }, size: NSSize(width: 900, height: 240), name: "G10_capsule_transcribing_on_white", dir: dir, titled: false)
        // 0.6: the standing capsule (left/right screen edge), zoomed: window server (real glass)
        // and cacheDisplay (material fallback look), plus where it sits on a screen.
        let vStage = NSSize(width: 420, height: 520)
        let vListening = OverlayCapsule(mode: .listening, tape: listenTape, previewSpin: 40).environment(\.overlayVertical, true)
        let vTranscribing = OverlayCapsule(mode: .transcribing, tape: listenTape, previewSpin: 40).environment(\.overlayVertical, true)
        let vMeeting = OverlayCapsule(mode: .recording, tape: meetTape, elapsed: 754, previewSpin: 40).environment(\.overlayVertical, true)
        made += await serverCapture(overlayStage(vListening, zoom: 3), size: vStage, name: "V01_capsule_vertical_listening", dir: dir, titled: false)
        made += await serverCapture(overlayStage(vTranscribing, zoom: 3), size: vStage, name: "V02_capsule_vertical_transcribing", dir: dir, titled: false)
        made += await serverCapture(overlayStage(vMeeting, zoom: 3), size: vStage, name: "V03_capsule_vertical_meeting", dir: dir, titled: false)
        made += await capture(overlayStage(vListening, zoom: 3), size: vStage, name: "V01c_capsule_vertical_listening_cache", dir: dir, titled: false)
        made += await capture(overlayStage(vTranscribing, zoom: 3), size: vStage, name: "V02c_capsule_vertical_transcribing_cache", dir: dir, titled: false)
        made += await capture(screenMock(position: .middleLeft,
                                         capsule: OverlayCapsule(mode: .listening, tape: listenTape, previewSpin: 40)),
                              size: NSSize(width: 1280, height: 800), name: "V04_overlay_screen_left_edge", dir: dir, titled: false)
        made += await capture(screenMock(position: .middleRight,
                                         capsule: OverlayCapsule(mode: .recording, tape: meetTape, elapsed: 754, previewSpin: 40)),
                              size: NSSize(width: 1280, height: 800), name: "V05_overlay_screen_right_edge", dir: dir, titled: false)
        made += await capture(screenMock(position: .bottomCenter,
                                         capsule: OverlayCapsule(mode: .listening, tape: listenTape, previewSpin: 40)),
                              size: NSSize(width: 1280, height: 800), name: "09s_overlay_screen_bottom_center", dir: dir, titled: false)
        made += await capture(screenMock(position: .topRight,
                                         capsule: OverlayCapsule(mode: .recording, tape: meetTape, elapsed: 754, previewSpin: 40)),
                              size: NSSize(width: 1280, height: 800), name: "09t_overlay_screen_top_right", dir: dir, titled: false)

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

        var osInfo = ProcessInfo.processInfo.operatingSystemVersionString
        osInfo += " · 0.7 Night Sky (no glass; Manrope \(ScribeFonts.nsFont(size: 13, weight: 500) != nil ? "loaded" : "MISSING, system font fallback"))"
        let note = ["os": osInfo, "note": "SAMPLE data (made-up meeting/people/dictations), rendered by Scribe --snapshot on the CI Mac runner.",
                    "files": made.joined(separator: ", ")]
        if let d = try? JSONSerialization.data(withJSONObject: note, options: [.prettyPrinted]) {
            try? d.write(to: dir.appendingPathComponent("index.json"))
        }
        print("SNAPSHOT_DONE: \(made.count) files in \(dir.path)")
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Listening / Thinking / Done / Problem, horizontal on top, vertical below, zoomed 2x.
    private static func capsuleSheet(dark: Bool) -> some View {
        let tape = LevelTape(); tape.fillPreview(seconds: 4.2)
        let modes: [OverlayMode] = [.listening, .transcribing, .message("Pasted into Notes", failure: false),
                                    .message("No microphone found", failure: true)]
        return ZStack {
            (dark ? Color(hex: 0x1C1C20) : Color(hex: 0xE9EAEE))
            VStack(spacing: 70) {
                HStack(spacing: 16) {
                    ForEach(Array(modes.enumerated()), id: \.offset) { _, m in
                        OverlayCapsule(mode: m, tape: tape, elapsed: 4, previewSpin: 1)
                    }
                }
                .scaleEffect(1.1)
                HStack(spacing: 90) {
                    ForEach(Array(modes.enumerated()), id: \.offset) { _, m in
                        OverlayCapsule(mode: m, tape: tape, elapsed: 4, previewSpin: 1).environment(\.overlayVertical, true)
                    }
                }
                .scaleEffect(1.6)
            }
        }
    }

    private static func overlayStage<C: View>(_ capsule: C, zoom: CGFloat) -> some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.55, green: 0.62, blue: 0.74), Color(red: 0.36, green: 0.42, blue: 0.56)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            capsule.scaleEffect(zoom)
        }
    }

    /// A 1280x800 "screen" (wallpaper, menu bar, a window, the Dock) with the capsule placed
    /// exactly where OverlayPanel would put it for `position`.
    private static func screenMock(position: OverlayPosition, capsule: OverlayCapsule) -> some View {
        let screen = CGSize(width: 1280, height: 800)
        let menuH: CGFloat = 24, dockH: CGFloat = 76
        // AppKit coordinates (origin bottom-left): visible frame = screen minus menu bar and Dock.
        let visible = CGRect(x: 0, y: dockH, width: screen.width, height: screen.height - menuH - dockH)
        let f = OverlayPanel.frame(for: position, in: visible)
        return ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 0.62, green: 0.70, blue: 0.82), Color(red: 0.40, green: 0.46, blue: 0.62)],
                           startPoint: .top, endPoint: .bottom)
            // A document window.
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { _ in Circle().fill(Color(white: 0.82)).frame(width: 12, height: 12) }
                }
                ForEach(0..<7, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.88)).frame(width: i == 6 ? 260 : 600, height: 10)
                }
            }
            .padding(20)
            .frame(width: 720, height: 440, alignment: .topLeading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
            .compositingGroup()
            .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
            .offset(x: 280, y: 150)
            // Menu bar.
            HStack(spacing: 18) {
                Image(systemName: "applelogo").font(.system(size: 13))
                Text("Notes").font(.system(size: 13, weight: .semibold))
                Text("File")
                Text("Edit")
                Text("View")
                Spacer()
                Image(nsImage: MenuBarGlyph.live).renderingMode(.template)
                Text("Mon 9:41 AM")
            }
            .font(.system(size: 13))
            .foregroundStyle(Color.black.opacity(0.85))
            .padding(.horizontal, 16)
            .frame(width: screen.width, height: menuH)
            .background(Color.white.opacity(0.6))
            // Dock.
            RoundedRectangle(cornerRadius: 18).fill(Color.white.opacity(0.35))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.white.opacity(0.5), lineWidth: 0.5))
                .frame(width: 560, height: 62)
                .offset(x: (screen.width - 560) / 2, y: screen.height - dockH + 7)
            // The overlay panel.
            capsule
                .environment(\.overlayVertical, position.isSide)
                .frame(width: f.width, height: f.height, alignment: position.alignment)
                .offset(x: f.minX, y: screen.height - f.maxY)
        }
        .frame(width: screen.width, height: screen.height, alignment: .topLeading)
        .environment(\.colorScheme, .light)
    }

    /// Finder's icon for this app (proves AppIcon is wired in), a Dock-style mock, and the
    /// menu bar nib glyphs (black on a light bar, white on a dark bar) at 8×.
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

    /// Shows `view` in a real window and lets the window server photograph it (`screencapture -l`),
    /// so glass and materials are composited exactly as on screen.
    private static func serverCapture<V: View>(_ view: V, size: NSSize?, name: String, dir: URL, titled: Bool = true,
                                               dark: Bool = false, chrome: Bool = false) async -> [String] {
        let w = window(for: view, size: size, titled: titled, dark: dark, chrome: chrome)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        if chrome { WindowChrome.placeTrafficLights(w) }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let url = dir.appendingPathComponent("\(name).png")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l\(w.windowNumber)", url.path]
        try? p.run()
        p.waitUntilExit()
        w.close()
        let ok = FileManager.default.fileExists(atPath: url.path)
        print("snapshot \(name) (window server): \(ok)")
        return ok ? [url.lastPathComponent] : []
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

    private static func window<V: View>(for view: V, size: NSSize?, titled: Bool, dark: Bool = false,
                                        chrome: Bool = false) -> NSWindow {
        let host = NSHostingView(rootView: view)
        let s = size ?? host.fittingSize
        var style: NSWindow.StyleMask = titled ? [.titled, .closable, .miniaturizable, .resizable] : [.borderless]
        if titled && chrome { style.insert(.fullSizeContentView) }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: s), styleMask: style, backing: .buffered, defer: false)
        w.title = "Scribe"
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.contentView = host
        if titled && chrome { WindowChrome.configure(w) }
        w.setContentSize(s)
        w.center()
        w.orderFrontRegardless()
        return w
    }

    /// Returns the file names written (the view alone, and for titled windows also the window frame).
    private static func capture<V: View>(_ view: V, size: NSSize?, name: String, dir: URL, titled: Bool = true,
                                         dark: Bool = false, chrome: Bool = false) async -> [String] {
        let w = window(for: view, size: size, titled: titled, dark: dark, chrome: chrome)
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

    // MARK: - Sample data (made up, screenshots only: never shown to users)

    private static func learningShots(store: Store, dir: URL) async -> [String] {
        let keys = [FixUps.key, FixUps.migratedKey, CorrectionStore.key]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (k, v) in zip(keys, saved) {
                if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
            }
        }
        let day: TimeInterval = 86_400
        let base = Date(timeIntervalSince1970: 1_764_000_000)
        func rule(_ f: String, _ t: String, seen: Int, approved: Bool = false, on: Bool = true, name: Bool = false, ago: Double) -> FixUpRule {
            FixUpRule(from: f, to: t, seen: seen, approved: approved, enabled: on, firstSeen: base.addingTimeInterval(-ago * day - 5 * day),
                      lastSeen: base.addingTimeInterval(-ago * day), isName: name)
        }
        UserDefaults.standard.set(true, forKey: FixUps.migratedKey)
        FixUps.rules = [
            rule("superbase", "Supabase", seen: 4, ago: 0.2),
            rule("teh", "the", seen: 3, ago: 1),
            rule("zorvath", "Zorvath", seen: 1, approved: true, name: true, ago: 2),
            rule("on shape", "Onshape", seen: 2, approved: true, on: false, ago: 3),
            rule("their", "there", seen: 2, ago: 0.5),
            rule("fluid audio", "FluidAudio", seen: 1, ago: 0.8),
            rule("tamsin", "Tamsin", seen: 1, name: true, ago: 4),
        ]
        CorrectionStore.enabled = true
        let folder = CorrectionStore.folder(store.folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        for i in 0..<46 {      // 46 × 30 s = 23 min of invented corrections (text only, no audio files)
            let p = CorrectionStore.Pair(id: UUID(), source: "dictation", original: "sample \(i)", corrected: "Sample \(i)",
                                         seconds: 30, savedAt: base)
            try? enc.encode(p).write(to: folder.appendingPathComponent("\(p.id.uuidString).json"))
        }
        var made: [String] = []
        let size = NSSize(width: 1200, height: 800)
        for dark in [false, true] {
            made += await serverCapture(env(ContentView(section: .settings, settingsPane: .learning)), size: size,
                                        name: dark ? "P15b_settings_learning_dark" : "P15_settings_learning_light",
                                        dir: dir, dark: dark, chrome: true)
            // The whole page (taller than the runner's screen): borderless, drawn offscreen.
            made += await capture(env(ContentView(section: .settings, settingsPane: .learning)), size: NSSize(width: 1200, height: 1560),
                                  name: dark ? "P15d_settings_learning_full_dark" : "P15c_settings_learning_full_light",
                                  dir: dir, titled: false, dark: dark)
        }
        made += await serverCapture(env(ContentView(section: .settings, settingsPane: .dictation)), size: size,
                                    name: "P15e_settings_dictation_boost_light", dir: dir, dark: false, chrome: true)
        CorrectionStore.deleteAll(store.folder)
        return made
    }

    private static func fillSampleData(_ store: Store) -> UUID {
        let cal = Calendar.current
        let now = Date()
        let names = ["Alex", "Sam", "Priya", "Jordan"]
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
            ("S1", "Good. Priya, can you have the new hub on the robot by Thursday?"),
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
                c.suggestedPersonID = people[3].id            // shows "maybe Jordan?"
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
            actionItems: [ActionItem(task: "Reprint the roller hub and have it on the robot by Thursday", owner: "Priya"),
                          ActionItem(task: "Test the earlier first turn in autonomous on Saturday", owner: "Sam"),
                          ActionItem(task: "Write up intake changes and test results in the notebook", owner: "Speaker 4", done: true)],
            method: .rules, createdAt: now, seconds: 0.01,
            note: "Sample data for screenshots.")
        var m = Meeting(id: mID, title: "Robotics build meeting", date: cal.date(byAdding: .hour, value: -2, to: now)!,
                        duration: t, audioFileName: "sample.wav")
        m.status = .done
        m.utterances = utterances
        m.clusters = clusters
        m.processingSeconds = t / 9
        m.notes = notes

        var m2 = Meeting(title: "Client call: website refresh", date: cal.date(byAdding: .day, value: -1, to: now)!,
                         duration: 1260, audioFileName: "sample2.wav")
        m2.status = .done
        m2.clusters = [SpeakerCluster(key: "S1", talkSeconds: 700, centroid: [], spanEmbeddings: [], personID: people[0].id),
                       SpeakerCluster(key: "S2", talkSeconds: 560, centroid: [], spanEmbeddings: [])]
        var m3 = Meeting(title: "Study group: chapter 4", date: cal.date(byAdding: .day, value: -3, to: now)!,
                         duration: 2710, audioFileName: "sample3.wav")
        m3.status = .done
        m3.clusters = [SpeakerCluster(key: "S1", talkSeconds: 900, centroid: [], spanEmbeddings: []),
                       SpeakerCluster(key: "S2", talkSeconds: 800, centroid: [], spanEmbeddings: []),
                       SpeakerCluster(key: "S3", talkSeconds: 600, centroid: [], spanEmbeddings: [])]
        var m4 = Meeting(title: "Planning the spring showcase", date: cal.date(byAdding: .day, value: -5, to: now)!,
                         duration: 2032, audioFileName: "sample4.wav")
        m4.status = .done
        m4.clusters = [SpeakerCluster(key: "S1", talkSeconds: 900, centroid: [], spanEmbeddings: [], personID: people[3].id),
                       SpeakerCluster(key: "S2", talkSeconds: 700, centroid: [], spanEmbeddings: [], personID: people[0].id)]
        var m5 = Meeting(title: "Weekly check-in", date: cal.date(byAdding: .day, value: -6, to: now)!,
                         duration: 1117, audioFileName: "sample5.wav")
        m5.status = .done
        m5.clusters = [SpeakerCluster(key: "S1", talkSeconds: 600, centroid: [], spanEmbeddings: [], personID: people[3].id),
                       SpeakerCluster(key: "S2", talkSeconds: 500, centroid: [], spanEmbeddings: [], personID: people[1].id)]
        store.meetings = [m, m2, m3, m4, m5]

        // Sample dictations with the app they went into (made up), plus older ones for the heatmap.
        let apps: [(String, String)] = [("com.apple.Notes", "Notes"), ("com.apple.MobileSMS", "Messages"),
                                        ("com.apple.dt.Xcode", "Xcode"), ("com.apple.Safari", "Safari"), ("com.apple.mail", "Mail")]
        let texts = ["Can you make the sidebar a little skinnier and bring the text size back up so it's easier to read?",
                     "Remember to bring the charger and the spare battery on Thursday.",
                     "Move the record button into the header and make it a pill.",
                     "Hello, this is a quick test to see if the punctuation comes out right.",
                     "Thanks for the update, I'll have the homepage draft ready by Friday."]
        var entries: [DictationEntry] = []
        for i in 0..<5 {
            let app = apps[i]
            entries.append(DictationEntry(date: cal.date(byAdding: .minute, value: -(4 + i * 23), to: now)!,
                                          text: texts[i], raw: texts[i], method: .rules,
                                          audioSeconds: Double(texts[i].split(separator: " ").count) / 2.3, latencySeconds: 0.5,
                                          appBundleID: app.0, appName: app.1, style: "natural"))
        }
        var rng = SeededRandom(seed: 5)
        for day in 1..<150 {
            guard rng.next() < 0.55 else { continue }
            let n = 1 + Int(rng.next() * 3)
            for k in 0..<n {
                let r1 = rng.next(), r2 = rng.next()
                let app = apps[min(4, Int(r1 * r2 * 6))]
                let t = texts[k % texts.count]
                entries.append(DictationEntry(date: cal.date(byAdding: .day, value: -day, to: now)!,
                                              text: t, raw: t, method: .rules,
                                              audioSeconds: Double(t.split(separator: " ").count) / 2.3, latencySeconds: 0.5,
                                              appBundleID: app.0, appName: app.1, style: "natural"))
            }
        }
        store.dictations = entries
        store.rebuildDictationLedger()
        store.dictations = Array(entries.prefix(200))
        return mID
    }
}
