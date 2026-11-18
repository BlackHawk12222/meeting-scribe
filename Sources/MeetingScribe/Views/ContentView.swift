// ContentView.swift
// Sidebar (record button, meetings, people) + detail pane.

import SwiftUI

enum SidebarItem: Hashable {
    case meeting(UUID)
    case people
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var recorder: Recorder
    @AppStorage("noiseCleanup") private var noiseCleanup = true
    @State private var selection: SidebarItem?
    @State private var alertText: String?

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                recordPanel
                Divider()
                List(selection: $selection) {
                    Section("Voice library") {
                        Label("People (\(store.people.count))", systemImage: "person.2.wave.2")
                            .tag(SidebarItem.people)
                    }
                    Section("Meetings") {
                        ForEach(store.meetings) { m in
                            MeetingRow(meeting: m).tag(SidebarItem.meeting(m.id))
                                .contextMenu {
                                    Button("Delete", role: .destructive) { store.deleteMeeting(m.id) }
                                }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 280)
        } detail: {
            VStack(spacing: 0) {
                if !store.engineReady { ModelBanner() }
                switch selection {
                case .people:
                    PeopleView()
                case .meeting(let id):
                    if store.meetings.contains(where: { $0.id == id }) {
                        MeetingDetailView(meetingID: id)
                    } else {
                        placeholder
                    }
                case nil:
                    placeholder
                }
            }
        }
        .alert("Heads up", isPresented: Binding(get: { alertText != nil }, set: { if !$0 { alertText = nil } })) {
            Button("OK") { alertText = nil }
        } message: { Text(alertText ?? "") }
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.badge.mic").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("Press Record to capture a meeting.").font(.title3)
            Text("Everything stays on this Mac.").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // The big record button at the top of the sidebar.
    private var recordPanel: some View {
        VStack(spacing: 10) {
            Button(action: toggleRecording) {
                HStack {
                    Image(systemName: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                        .font(.system(size: 22))
                    Text(recorder.isRecording ? "Stop" : "Record")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(recorder.isRecording ? .red : .accentColor)
            .keyboardShortcut("r", modifiers: [.command])

            if recorder.isRecording {
                HStack {
                    Text(Exporter.clock(recorder.elapsed)).monospacedDigit()
                    ProgressView(value: Double(recorder.level)).tint(.green)
                }
                if recorder.noiseCleanupActive {
                    Label("Noise cleanup on", systemImage: "waveform.badge.minus").font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Toggle("Noise cleanup (Apple voice processing)", isOn: $noiseCleanup)
                    .font(.caption)
                    .toggleStyle(.checkbox)
            }
        }
        .padding(12)
    }

    private func toggleRecording() {
        if recorder.isRecording {
            if let (url, duration) = recorder.stop() {
                let m = store.addMeeting(audioURL: url, duration: duration)
                selection = .meeting(m.id)
                Task { await store.process(m.id) }
            }
        } else {
            Task {
                guard await Recorder.requestPermission() else {
                    alertText = "Meeting Scribe needs the microphone. Turn it on in System Settings → Privacy & Security → Microphone."
                    return
                }
                do {
                    try recorder.start(to: store.newRecordingURL(), noiseCleanup: noiseCleanup)
                } catch {
                    alertText = "Couldn't start recording: \(error.localizedDescription)"
                }
            }
        }
    }
}

struct MeetingRow: View {
    @EnvironmentObject var store: Store
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(meeting.title).lineLimit(1)
            HStack(spacing: 6) {
                Text(Exporter.clock(meeting.duration)).monospacedDigit()
                switch meeting.status {
                case .processing: ProgressView().controlSize(.mini)
                case .failed: Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                case .recorded: Image(systemName: "clock")
                case .done:
                    let names = meeting.clusters.compactMap { store.person($0.personID)?.name }
                    Text(names.isEmpty ? "\(meeting.clusters.count) speakers" : names.joined(separator: ", "))
                        .lineLimit(1)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Shown until the speech models are downloaded and loaded.
struct ModelBanner: View {
    @EnvironmentObject var store: Store
    var body: some View {
        HStack(spacing: 10) {
            if store.engineError == nil { ProgressView().controlSize(.small) }
            Text(store.engineError ?? store.engineStatus).font(.callout)
            Spacer()
            if store.engineError != nil {
                Button("Retry") { Task { await store.prepareEngine() } }
            }
        }
        .padding(10)
        .background(.yellow.opacity(0.15))
    }
}
