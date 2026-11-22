// ContentView.swift
// The main window: sidebar (search, record button, dictation, people, meetings) + detail pane.

import SwiftUI

enum SidebarItem: Hashable {
    case meeting(UUID)
    case people
    case dictation
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: Store
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var permissions: Permissions
    @EnvironmentObject var dictation: DictationController
    @EnvironmentObject var models: ModelStore
    @AppStorage("noiseCleanup") private var noiseCleanup = true
    @AppStorage("onboarded") private var onboarded = false
    @State private var selection: SidebarItem?
    @State private var query = ""

    init(initialSelection: SidebarItem? = nil) {
        _selection = State(initialValue: initialSelection)
    }

    /// Search results: meeting id -> snippet showing where the words were found.
    private var hits: [UUID: String] {
        Dictionary(store.search(query).map { ($0.id, $0.snippet) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                recordPanel
                Divider()
                List(selection: $selection) {
                    Section("Library") {
                        Label("Dictation (\(store.dictations.count))", systemImage: "mic")
                            .tag(SidebarItem.dictation)
                        Label("People (\(store.people.count))", systemImage: "person.2.wave.2")
                            .tag(SidebarItem.people)
                    }
                    Section(query.isEmpty ? "Meetings" : "Meetings matching “\(query)”") {
                        let found = hits
                        ForEach(store.meetings.filter { query.isEmpty || found[$0.id] != nil }) { m in
                            MeetingRow(meeting: m, snippet: found[m.id]).tag(SidebarItem.meeting(m.id))
                                .contextMenu {
                                    Button("Delete", role: .destructive) { store.deleteMeeting(m.id) }
                                }
                        }
                    }
                }
                .searchable(text: $query, placement: .sidebar, prompt: "Search meetings & notes")
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 280)
        } detail: {
            VStack(spacing: 0) {
                if !store.engineReady { ModelBanner() }
                switch selection {
                case .people:
                    PeopleView()
                case .dictation:
                    DictationHistoryView(query: query)
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
        .alert("Heads up", isPresented: Binding(get: { model.alertText != nil }, set: { if !$0 { model.alertText = nil } })) {
            Button("OK") { model.alertText = nil }
        } message: { Text(model.alertText ?? "") }
        .sheet(isPresented: Binding(get: { !onboarded }, set: { if !$0 { onboarded = true } })) {
            OnboardingView()
                .environmentObject(store)
                .environmentObject(permissions)
                .environmentObject(models)
                .environmentObject(dictation)
                .interactiveDismissDisabled()
        }
        .onChange(of: model.justRecordedMeeting) { _, id in
            if let id { selection = .meeting(id) }
        }
        .onChange(of: model.openMeetingRequest) { _, id in
            if let id { selection = .meeting(id); model.openMeetingRequest = nil }
        }
        .onAppear {
            if let id = model.openMeetingRequest { selection = .meeting(id); model.openMeetingRequest = nil }
        }
    }

    /// Empty state (native ContentUnavailableView).
    @ViewBuilder private var placeholder: some View {
        if store.meetings.isEmpty {
            ContentUnavailableView {
                Label("No Meetings Yet", systemImage: "waveform")
            } description: {
                Text("Press Record (⌘R) and Scribe writes the transcript, who said what, and the notes. Or hold \(DictationSettings.holdKey.title) in any app to dictate. Everything stays on this Mac.")
            } actions: {
                Button("Record a Meeting") { model.toggleMeetingRecording() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        } else {
            ContentUnavailableView("Select a Meeting", systemImage: "doc.text",
                                   description: Text("Pick a meeting in the sidebar, or press ⌘R to record a new one."))
        }
    }

    // The record button at the top of the sidebar.
    private var recordPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { model.toggleMeetingRecording() }) {
                Label {
                    Text(recorder.isRecording ? "Stop · \(Exporter.clock(recorder.elapsed))" : "Record Meeting")
                        .monospacedDigit()
                } icon: {
                    Image(systemName: recorder.isRecording ? "stop.fill" : "record.circle")
                        .foregroundStyle(Brand.record)
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
            .tint(recorder.isRecording ? Brand.record : nil)
            .keyboardShortcut("r", modifiers: [.command])

            if recorder.isRecording {
                ProgressView(value: Double(recorder.level)).tint(Brand.record)
                if recorder.noiseCleanupActive {
                    Label("Noise cleanup on", systemImage: "waveform.badge.minus").font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Toggle("Noise cleanup", isOn: $noiseCleanup)
                    .font(.caption)
                    .toggleStyle(.checkbox)
                    .help("Apple voice processing: reduces background noise while recording.")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }
}

struct MeetingRow: View {
    @EnvironmentObject var store: Store
    let meeting: Meeting
    var snippet: String? = nil

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
            if let snippet {
                Text(snippet).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

/// Shown until the speech models are downloaded and loaded.
struct ModelBanner: View {
    @EnvironmentObject var store: Store
    var body: some View {
        HStack(spacing: 10) {
            if store.engineError == nil {
                if let p = store.modelProgress {
                    ProgressView(value: p).frame(width: 120).controlSize(.small)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            Text(store.engineError ?? store.engineStatus).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            if store.engineError != nil {
                Button("Retry") { Task { await store.prepareEngine() } }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}
