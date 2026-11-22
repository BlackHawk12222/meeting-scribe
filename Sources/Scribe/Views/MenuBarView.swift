// MenuBarView.swift
// The panel that drops down from the nib icon in the menu bar: the essentials only.
//   • Start/stop dictation (with the hotkey hint)   • Record/stop a meeting
//   • Last dictation + Copy                          • Recent meetings (open in the main window)
//   • Settings, Quit
// Plain, compact system UI (light and dark).

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
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if !store.engineReady { loading }
                dictationButton
                meetingButton
            }
            .padding(12)
            if let last = store.dictations.first {
                Divider()
                lastDictation(last).padding(12)
            }
            if !store.meetings.isEmpty {
                Divider()
                recentMeetings.padding(.horizontal, 6).padding(.vertical, 8)
            }
            Divider()
            footer
        }
        .frame(width: 296)
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 8) {
            AppIconView(size: 20)
            Text("Scribe").font(.headline)
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 6, height: 6)
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var loading: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: store.modelProgress ?? models.progress?.fraction ?? 0)
            Text(store.engineError ?? store.engineStatus).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                .monospacedDigit()
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
            .tint(dictation.state == .listening ? Brand.record : Brand.accent)
            .disabled(!store.engineReady || dictation.state == .transcribing)
            Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var meetingButton: some View {
        Button { model.toggleMeetingRecording() } label: {
            Label {
                Text(recorder.isRecording ? "Stop meeting · \(Exporter.clock(recorder.elapsed))" : "Record a meeting")
                    .monospacedDigit()
            } icon: {
                Image(systemName: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                    .foregroundStyle(Brand.record)
            }
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.bordered)
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
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private var recentMeetings: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent meetings").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.bottom, 4)
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
                .buttonStyle(MenuRowStyle())
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
        case .transcribing: return "Transcribing…"
        default: return recorder.isRecording ? "Recording meeting" : "Ready"
        }
    }

    private var statusColor: Color {
        if !store.engineReady { return store.engineError == nil ? .yellow : .orange }
        if dictation.state == .listening || recorder.isRecording { return Brand.record }
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

/// A menu-like row: highlights on hover, like native menu items.
struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuRow(configuration: configuration)
    }
    private struct MenuRow: View {
        let configuration: ButtonStyleConfiguration
        @State private var hover = false
        var body: some View {
            configuration.label
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : (hover ? 0.07 : 0))))
                .onHover { hover = $0 }
        }
    }
}
