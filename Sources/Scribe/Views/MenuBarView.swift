// MenuBarView.swift
// The panel that drops down from the scroll icon in the menu bar: the essentials only.
//   • Start/stop dictation (with the hotkey hint)   • Record/stop a meeting
//   • Last dictation + Copy                          • Recent meetings (open in the main window)
//   • Settings, Quit
// A light parchment header; everything else is plain, readable system UI.

import SwiftUI
import AppKit

struct MenuBarView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: Store
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var dictation: DictationController
    @EnvironmentObject var models: ModelStore
    @Environment(\.openWindow) private var openWindow
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 10) {
                if !store.engineReady { loading }
                dictationButton
                meetingButton
                if let last = store.dictations.first { lastDictation(last) }
                if !store.meetings.isEmpty { recentMeetings }
            }
            .padding(12)
            Divider()
            footer
        }
        .frame(width: 300)
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage()).resizable().frame(width: 22, height: 22)
            Text("Scribe").font(.system(.headline, design: .serif))
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(statusText).font(.caption).foregroundStyle(Ink.ink.opacity(0.75))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(ParchmentBand())
        .environment(\.colorScheme, .light)
    }

    private var loading: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: store.modelProgress ?? models.progress?.fraction ?? 0)
            Text(store.engineError ?? store.engineStatus).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    private var dictationButton: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { dictation.toggle() } label: {
                Label(dictation.state == .listening ? "Stop dictation" : "Start dictation",
                      systemImage: dictation.state == .listening ? "stop.fill" : "mic.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(dictation.state == .listening ? Ink.royal : Ink.ink)
            .disabled(!store.engineReady || dictation.state == .transcribing)
            Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var meetingButton: some View {
        Button { model.toggleMeetingRecording() } label: {
            Label(recorder.isRecording ? "Stop meeting · \(Exporter.clock(recorder.elapsed))" : "Record a meeting",
                  systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.bordered)
        .tint(recorder.isRecording ? Ink.royal : nil)
        .disabled(!store.engineReady && !recorder.isRecording)
    }

    private func lastDictation(_ last: DictationEntry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Last dictation").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(last.text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            Text(last.text).font(.callout).lineLimit(3).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Ink.parchmentLight.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Ink.parchmentDeep.opacity(0.7), lineWidth: 0.5))
        }
    }

    private var recentMeetings: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Recent meetings").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(store.meetings.prefix(3)) { m in
                Button {
                    model.openMeeting(m.id)
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    HStack {
                        Image(systemName: m.status == .processing ? "hourglass" : "doc.text")
                            .foregroundStyle(.secondary).frame(width: 16)
                        Text(m.title).lineLimit(1)
                        Spacer()
                        Text(m.date.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3)
            }
        }
    }

    private var footer: some View {
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
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: Text

    private var statusText: String {
        if !store.engineReady { return store.engineError == nil ? "Getting ready…" : "Needs attention" }
        switch dictation.state {
        case .listening: return "Listening"
        case .transcribing: return "Writing…"
        default: return recorder.isRecording ? "Recording meeting" : "Ready"
        }
    }

    private var statusColor: Color {
        if !store.engineReady { return store.engineError == nil ? Ink.gold : .orange }
        if dictation.state == .listening || recorder.isRecording { return Ink.royal }
        return .green
    }

    private var hint: String {
        var parts: [String] = []
        let key = DictationSettings.holdKey
        if key != .off, DictationSettings.mode != .toggleOnly { parts.append("Hold \(key.title) and talk") }
        if let t = DictationSettings.toggleShortcut, DictationSettings.mode != .holdOnly { parts.append("or press \(t.label)") }
        return parts.isEmpty ? "Hotkeys are off (Settings)." : parts.joined(separator: ", ") + " in any app."
    }
}
