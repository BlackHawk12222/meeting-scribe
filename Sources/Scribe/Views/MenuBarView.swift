// MenuBarView.swift
// The panel that drops down from the nib icon in the menu bar: the essentials only.
//   • Start/stop dictation (with the hotkey hint)   • Record/stop a meeting
//   • Last dictation + Copy                          • Recent meetings (open in the main window)
//   • Settings, Quit
// 0.7 "Night Sky": the same cards, type and buttons as the main window (light and dark).

import SwiftUI
import AppKit

struct MenuBarView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: Store
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var dictation: DictationController
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var permissions: Permissions
    @EnvironmentObject var updater: Updater
    @Environment(\.openWindow) private var openWindow
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            NightDivider()
            VStack(alignment: .leading, spacing: 12) {
                AccessibilityBanner(permissions: permissions)
                if !store.engineReady { loading }
                dictationButton
                meetingButton
            }
            .padding(12)
            if let last = store.dictations.first {
                NightDivider()
                lastDictation(last).padding(12)
            }
            if !store.meetings.isEmpty {
                NightDivider()
                recentMeetings.padding(.horizontal, 6).padding(.vertical, 8)
            }
            if case .ready(let r) = updater.phase {
                NightDivider()
                updateReady(r).padding(.horizontal, 12).padding(.vertical, 8)
            } else if case .needsMove(let r) = updater.phase {
                NightDivider()
                needsMove(r).padding(.horizontal, 12).padding(.vertical, 8)
            }
            if let n = updater.notice {
                NightDivider()
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle").foregroundStyle(Night.accent)
                    Text(n).font(.scribe(12, 600)).foregroundStyle(Night.text2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if n.contains("see ") {
                        Button("Log") { NSWorkspace.shared.open(Updater.logURL) }
                            .buttonStyle(.plain).font(.scribe(12, 700)).foregroundStyle(Night.accent)
                    }
                    Button { updater.dismissNotice() } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(Night.text3)
                        .accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            NightDivider()
            footer
        }
        .frame(width: 300)
        .foregroundStyle(Night.text)
        .background(Night.canvas)
        .onAppear { permissions.startWatching() }
        .onDisappear { permissions.stopWatching() }
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 8) {
            AppIconView(size: 20)
            Text("Scribe").font(.nightHeadline)
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 6, height: 6)
                Text(statusText).font(.nightMeta).foregroundStyle(Night.text3)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// "Update ready — Restart": small, never pops up by itself.
    private func updateReady(_ r: Updater.Release) -> some View {
        let busy = recorder.isRecording || dictation.state.isBusy
        return HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Night.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Update ready — \(r.version)").font(.scribe(13, 700))
                Text(busy ? "Restarts after you finish recording" : "Installs when you restart or quit")
                    .font(.nightMeta).foregroundStyle(Night.text3)
            }
            Spacer()
            Button("Restart") { updater.restartNow() }
                .buttonStyle(NightButtonStyle(kind: .secondary, height: 28))
                .opacity(busy ? 0.6 : 1)
        }
    }

    /// Downloaded, but this copy can't replace itself (translocated / read-only folder).
    private func needsMove(_ r: Updater.Release) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").foregroundStyle(Night.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Move Scribe to Applications to update").font(.scribe(13, 700))
                Text("Scribe \(r.version) is ready, but this copy can't replace itself where it runs from.")
                    .font(.nightMeta).foregroundStyle(Night.text3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                .buttonStyle(NightButtonStyle(kind: .secondary, height: 28))
        }
    }

    private var loading: some View {
        VStack(alignment: .leading, spacing: 4) {
            CapsuleProgress(fraction: store.modelProgress ?? models.progress?.fraction ?? 0, count: 34, dot: 5, spacing: 2.5)
            Text(store.engineError ?? store.engineStatus).font(.nightMeta).foregroundStyle(Night.text3).lineLimit(2)
                .monospacedDigit()
        }
    }

    private var dictationButton: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { dictation.toggle() } label: {
                Label(dictation.state == .listening ? "Stop dictation" : "Start dictation",
                      systemImage: dictation.state == .listening ? "stop.fill" : "mic.fill")
            }
            .buttonStyle(NightButtonStyle(kind: dictation.state == .listening ? .danger : .primary, fullWidth: true))
            .disabled(!store.engineReady || dictation.state == .transcribing)
            Text(hint).font(.nightMeta).foregroundStyle(Night.text3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var meetingButton: some View {
        Button { model.toggleMeetingRecording() } label: {
            Label {
                Text(recorder.isRecording ? "Stop meeting · \(Exporter.clock(recorder.elapsed))" : "Record a meeting")
                    .monospacedDigit()
            } icon: {
                Image(systemName: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                    .foregroundStyle(Night.live)
            }
        }
        .buttonStyle(NightButtonStyle(kind: .secondary, fullWidth: true))
        .disabled(!store.engineReady && !recorder.isRecording)
    }

    private func lastDictation(_ last: DictationEntry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                SectionLabel(title: "Last dictation")
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(last.text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.scribe(12, 700))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Night.accent)
            }
            Text(last.text).font(.nightBody).foregroundStyle(Night.text).lineLimit(3).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .nightCard(radius: 14, padding: 12)
        }
    }

    private var recentMeetings: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(title: "Recent meetings")
                .padding(.horizontal, 8).padding(.bottom, 6)
            ForEach(store.meetings.prefix(3)) { m in
                Button {
                    model.openMeeting(m.id)
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    HStack {
                        Image(systemName: m.status == .processing ? "hourglass" : "waveform")
                            .foregroundStyle(Night.accent).frame(width: 16)
                        Text(m.title).lineLimit(1)
                        Spacer()
                        Text(m.date.formatted(.relative(presentation: .named))).font(.nightMeta).foregroundStyle(Night.text3)
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
        .buttonStyle(.plain)
        .font(.scribe(12.5, 700))
        .foregroundStyle(Night.text2)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
        if !store.engineReady { return store.engineError == nil ? Night.accent : Night.warn }
        if dictation.state == .listening || recorder.isRecording { return Night.live }
        return Night.ok
    }

    private var hint: String {
        var parts: [String] = []
        let key = DictationSettings.holdKey
        if key != .off, DictationSettings.mode != .toggleOnly { parts.append("Hold \(key.title) and talk") }
        if let t = DictationSettings.toggleShortcut, DictationSettings.mode != .holdOnly { parts.append("or press \(t.label)") }
        return parts.isEmpty ? "Hotkeys are off (Settings)." : parts.joined(separator: ", ") + " in any app."
    }
}
