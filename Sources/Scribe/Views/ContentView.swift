// ContentView.swift
// The main window: sidebar (search, record button, dictation, people, meetings) + detail pane.
// 0.6: warm canvas behind content, glass record button and banner, friendly empty states.

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
                List(selection: $selection) {
                    Section("Library") {
                        Label("Dictation", systemImage: "mic")
                            .badge(store.dictations.count)
                            .tag(SidebarItem.dictation)
                        Label("People", systemImage: "person.2")
                            .badge(store.people.count)
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
                if !store.engineReady { ModelBanner().padding(.top, 10).padding(.horizontal, 16) }
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scribeCanvas()
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

    /// Empty states: short, friendly, one clear next step.
    @ViewBuilder private var placeholder: some View {
        if store.meetings.isEmpty {
            CozyEmptyState(symbol: "waveform",
                           title: "Nothing here yet",
                           message: "When you're ready, press Record and Scribe will write the transcript, who said what, and the notes. You can also hold \(DictationSettings.holdKey.title) in any app to dictate. It all stays on this Mac.") {
                Button { model.toggleMeetingRecording() } label: {
                    Label("Record a Meeting", systemImage: "record.circle").padding(.horizontal, 6)
                }
                .scribeButton(prominent: true)
                .controlSize(.large)
            }
        } else {
            CozyEmptyState(symbol: "doc.text",
                           title: "Pick a meeting",
                           message: "Choose one from the list, or press ⌘R to start a new one.")
        }
    }

    // The record button at the top of the sidebar: one glass capsule, red while recording.
    private var recordPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: { model.toggleMeetingRecording() }) {
                Label {
                    Text(recorder.isRecording ? "Stop · \(Exporter.clock(recorder.elapsed))" : "Record Meeting")
                        .fontWeight(.medium)
                        .monospacedDigit()
                } icon: {
                    Image(systemName: recorder.isRecording ? "stop.fill" : "record.circle")
                        .foregroundStyle(recorder.isRecording ? Color.white : Brand.record)
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .scribeButton(prominent: recorder.isRecording)
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
                    .foregroundStyle(.secondary)
                    .help("Apple voice processing: reduces background noise while recording.")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }
}

struct MeetingRow: View {
    @EnvironmentObject var store: Store
    let meeting: Meeting
    var snippet: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(meeting.title).fontWeight(.medium).lineLimit(1)
            HStack(spacing: 6) {
                Text(meeting.date.formatted(.relative(presentation: .named)))
                Text("·")
                Text(Exporter.clock(meeting.duration)).monospacedDigit()
                switch meeting.status {
                case .processing: ProgressView().controlSize(.mini)
                case .failed: Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                case .recorded: Image(systemName: "clock")
                case .done:
                    // A few soft dots: one per named speaker, in their color.
                    HStack(spacing: -3) {
                        ForEach(meeting.clusters.prefix(4)) { c in
                            Circle()
                                .fill(store.person(c.personID).map { Palette.color($0.colorIndex) } ?? Color.secondary.opacity(0.5))
                                .frame(width: 7, height: 7)
                                .overlay(Circle().strokeBorder(Warm.surface, lineWidth: 1))
                        }
                    }
                    .accessibilityLabel("\(meeting.clusters.count) speakers")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            if let snippet {
                Text(snippet).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }
}

/// Shown until the speech models are downloaded and loaded: a small floating glass pill.
struct ModelBanner: View {
    @EnvironmentObject var store: Store
    var body: some View {
        HStack(spacing: 10) {
            if store.engineError == nil {
                if let p = store.modelProgress {
                    ProgressView(value: p).frame(width: 110).controlSize(.small)
                } else {
                    ProgressView().controlSize(.small)
                }
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Text(store.engineError ?? store.engineStatus).font(.callout).foregroundStyle(.secondary)
                .monospacedDigit().lineLimit(1)
            if store.engineError != nil {
                Button("Retry") { Task { await store.prepareEngine() } }
                    .scribeButton()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .scribeGlass(Capsule())
        .shadow(color: Warm.shadow, radius: 8, y: 2)
    }
}
