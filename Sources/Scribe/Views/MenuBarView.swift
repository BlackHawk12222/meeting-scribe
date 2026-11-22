// MenuBarView.swift
// The panel that drops down from the menu bar icon.

import SwiftUI
import AppKit

struct MenuBarView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: Store
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var dictation: DictationController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Scribe").font(.headline)
                Spacer()
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }

            if let p = store.modelProgress, !store.engineReady {
                ProgressView(value: p)
                Text(store.engineStatus).font(.caption).foregroundStyle(.secondary)
            }

            Button { dictation.toggle() } label: {
                Label(dictation.state == .listening ? "Stop dictation" : "Start dictation",
                      systemImage: dictation.state == .listening ? "stop.fill" : "mic.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(dictation.state == .listening ? .red : .primary)
            .disabled(!store.engineReady || dictation.state == .transcribing)

            Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Button { model.toggleMeetingRecording() } label: {
                Label(recorder.isRecording ? "Stop meeting (\(Exporter.clock(recorder.elapsed)))" : "Record a meeting",
                      systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!store.engineReady && !recorder.isRecording)

            if let last = store.dictations.first {
                Divider()
                Text("Last dictation").font(.caption).foregroundStyle(.secondary)
                Text(last.text).font(.callout).lineLimit(3)
                Button("Copy again") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(last.text, forType: .string)
                }
                .buttonStyle(.link)
            }

            Divider()
            HStack {
                Button("Open Scribe") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                SettingsLink { Text("Settings…") }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 280)
    }

    private var statusText: String {
        if !store.engineReady { return store.engineError == nil ? "Loading…" : "Error" }
        switch dictation.state {
        case .listening: return "Listening"
        case .transcribing: return "Writing…"
        default: return recorder.isRecording ? "Recording meeting" : "Ready"
        }
    }

    private var hint: String {
        var parts: [String] = []
        let key = DictationSettings.holdKey
        if key != .off, DictationSettings.mode != .toggleOnly { parts.append("Hold \(key.title) and talk") }
        if let t = DictationSettings.toggleShortcut, DictationSettings.mode != .holdOnly { parts.append("or press \(t.label)") }
        return parts.isEmpty ? "Hotkeys are off (Settings)." : parts.joined(separator: ", ") + "."
    }
}
