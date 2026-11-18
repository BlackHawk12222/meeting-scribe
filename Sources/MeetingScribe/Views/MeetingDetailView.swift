// MeetingDetailView.swift
// One meeting: the speakers found in it (name them here!) and the transcript.

import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers

struct MeetingDetailView: View {
    @EnvironmentObject var store: Store
    let meetingID: UUID
    @State private var player: AVAudioPlayer?
    @State private var namingKey: String?
    @State private var newName = ""
    @State private var editingTitle = false

    private var meeting: Meeting? { store.meetings.first { $0.id == meetingID } }

    var body: some View {
        if let m = meeting {
            VStack(alignment: .leading, spacing: 0) {
                header(m)
                Divider()
                if m.status == .done {
                    speakersBar(m)
                    Divider()
                    transcript(m)
                } else {
                    statusView(m)
                }
            }
            .toolbar { toolbar(m) }
            .sheet(isPresented: Binding(get: { namingKey != nil }, set: { if !$0 { namingKey = nil } })) {
                nameSheet(m)
            }
        }
    }

    // MARK: Header

    private func header(_ m: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Title", text: Binding(
                get: { m.title },
                set: { new in if let i = store.index(of: m.id) { store.meetings[i].title = new } }
            ), onCommit: { store.save() })
            .textFieldStyle(.plain)
            .font(.title2.bold())
            HStack(spacing: 12) {
                Text(m.date.formatted(date: .abbreviated, time: .shortened))
                Text(Exporter.clock(m.duration)).monospacedDigit()
                if let p = m.processingSeconds, p > 0 {
                    // Measured on this Mac for this recording.
                    Text(String(format: "processed in %.0f s (%.0f× real time)", p, m.duration / p))
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }

    @ViewBuilder
    private func statusView(_ m: Meeting) -> some View {
        VStack(spacing: 12) {
            switch m.status {
            case .processing:
                ProgressView()
                Text(store.progressText[m.id] ?? "Working…")
            case .failed:
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                Text(m.errorMessage ?? "Something went wrong.")
                Button("Try again") { Task { await store.process(m.id) } }
            default:
                Text(store.engineReady ? "Waiting to process…" : "Will process once the models are ready.")
                if store.engineReady { Button("Process now") { Task { await store.process(m.id) } } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Speakers

    private func speakersBar(_ m: Meeting) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(m.clusters) { c in speakerChip(m, c) }
            }
            .padding(.horizontal).padding(.vertical, 10)
        }
    }

    private func speakerChip(_ m: Meeting, _ c: SpeakerCluster) -> some View {
        let person = store.person(c.personID)
        let suggestion = store.person(c.suggestedPersonID)
        let color = person.map { Palette.color($0.colorIndex) } ?? .gray
        return Menu {
            if let s = suggestion {
                Button("Yes, this is \(s.name)") { store.assign(meetingID: m.id, clusterKey: c.key, to: s.id) }
            }
            if person != nil && !c.confirmed {
                Button("Confirm \(person!.name) (teach the library)") {
                    store.assign(meetingID: m.id, clusterKey: c.key, to: person!.id)
                }
            }
            Button("Play a sample") { playSample(m, c.key) }
            Divider()
            ForEach(store.people) { p in
                Button(p.name) { store.assign(meetingID: m.id, clusterKey: c.key, to: p.id) }
            }
            Button("New person…") { newName = ""; namingKey = c.key }
            if person != nil {
                Divider()
                Button("Not them / unknown") { store.clearSpeaker(meetingID: m.id, clusterKey: c.key) }
            }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 10, height: 10)
                Text(store.displayName(m, key: c.key)).bold()
                if let s = suggestion, person == nil { Text("maybe \(s.name)?").foregroundStyle(.secondary) }
                if c.confirmed {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                } else if let score = c.matchScore, person != nil {
                    Text(String(format: "%.0f%% match", score * 100)).font(.caption).foregroundStyle(.secondary)
                }
                Text(Exporter.clock(c.talkSeconds)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderedButton)
        .fixedSize()
        .help("Click to name this speaker. Naming teaches the voice library.")
    }

    private func nameSheet(_ m: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Who is \(store.displayName(m, key: namingKey ?? ""))?").font(.headline)
            Text("Tip: use “Play a sample” on the speaker first.").font(.caption).foregroundStyle(.secondary)
            TextField("Name", text: $newName).onSubmit(saveName)
            HStack {
                Spacer()
                Button("Cancel") { namingKey = nil }
                Button("Save", action: saveName).keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 320)
    }

    private func saveName() {
        if let key = namingKey { store.createPerson(named: newName, meetingID: meetingID, clusterKey: key) }
        namingKey = nil
    }

    // MARK: Transcript

    private func transcript(_ m: Meeting) -> some View {
        List(m.utterances) { u in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Button(Exporter.clock(u.start)) { play(m, from: u.start) }
                    .buttonStyle(.link).monospacedDigit().font(.caption)
                    .help("Play from here")
                let c = m.clusters.first { $0.key == u.speakerKey }
                let color = store.person(c?.personID).map { Palette.color($0.colorIndex) } ?? .gray
                Text(store.displayName(m, key: u.speakerKey))
                    .bold().foregroundStyle(color)
                    .frame(width: 110, alignment: .leading)
                Text(u.text).textSelection(.enabled)
            }
            .padding(.vertical, 2)
        }
        .listStyle(.inset)
    }

    // MARK: Toolbar / export

    @ToolbarContentBuilder
    private func toolbar(_ m: Meeting) -> some ToolbarContent {
        ToolbarItemGroup {
            Button { player?.stop() } label: { Label("Stop audio", systemImage: "stop.fill") }
                .disabled(player == nil)
            Button { Task { await store.process(m.id) } } label: {
                Label("Re-process", systemImage: "arrow.clockwise")
            }
            .disabled(!store.engineReady || m.status == .processing)
            Menu {
                ForEach(ExportFormat.allCases) { f in
                    Button(f.label) { export(m, f) }
                }
            } label: { Label("Export", systemImage: "square.and.arrow.up") }
            .disabled(m.status != .done)
        }
    }

    private func export(_ m: Meeting, _ f: ExportFormat) {
        let text = Exporter.render(m, format: f) { store.displayName(m, key: $0) }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = m.title.replacingOccurrences(of: "/", with: "-") + "." + f.rawValue
        if panel.runModal() == .OK, let url = panel.url {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: Audio playback

    private func play(_ m: Meeting, from t: Double) {
        player?.stop()
        guard let p = try? AVAudioPlayer(contentsOf: store.audioURL(for: m)) else { return }
        p.currentTime = max(0, t - 0.3)
        p.play()
        player = p
    }

    private func playSample(_ m: Meeting, _ key: String) {
        // The speaker's longest line.
        let lines = m.utterances.filter { $0.speakerKey == key }
        if let u = lines.max(by: { ($0.end - $0.start) < ($1.end - $1.start) }) { play(m, from: u.start) }
    }
}
