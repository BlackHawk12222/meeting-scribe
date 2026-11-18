// MeetingScribeApp.swift
// Entry point. Normally it opens the window. If launched with --selftest
// (used by the GitHub Actions Mac runner) it runs a headless test and quits.

import SwiftUI

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.runAndExit()            // never returns
        } else {
            MeetingScribeApp.main()
        }
    }
}

struct MeetingScribeApp: App {
    @StateObject private var store = Store()
    @StateObject private var recorder = Recorder()

    var body: some Scene {
        WindowGroup("Meeting Scribe") {
            ContentView()
                .environmentObject(store)
                .environmentObject(recorder)
                .frame(minWidth: 860, minHeight: 540)
                .task { await store.prepareEngine() }
        }
        .windowStyle(.titleBar)
    }
}

/// A small palette so each person keeps the same color everywhere.
enum Palette {
    static let colors: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .red, .brown, .indigo, .mint]
    static func color(_ i: Int) -> Color { colors[abs(i) % colors.count] }
}
