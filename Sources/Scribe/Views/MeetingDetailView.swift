// MeetingDetailView.swift
// One meeting: the speakers found in it (name them here!), the notes, and the transcript.
// 0.6: one content-first page (Notion-like), glass speaker chips, notes as calm blocks.

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
    @State private var chipKey: String?
    @FocusState private var titleFocused: Bool
    @State private var tab = DetailTab.notes
    enum DetailTab: String, CaseIterable { case notes = "Notes", transcript = "Transcript" }

    private var meeting: Meeting? { store.meetings.first { $0.id == meetingID } }

    var body: some View {
        if let m = meeting {
            Group {
                if m.status == .done {
                    // One calm, content-first page: title, people, then notes or transcript.
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            header(m)
                            speakersBar(m)
                            Picker("", selection: $tab) {
                                ForEach(DetailTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 220)
                            Divider().overlay(Warm.hairline)
                            if tab == .notes { notesView(m) } else { transcript(m) }
                        }
                        .padding(.horizontal, 40)
                        .padding(.top, 28)
                        .padding(.bottom, 40)
                        .frame(maxWidth: Brand.readingWidth + 80, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        header(m).padding(.horizontal, 40).padding(.top, 28)
                        statusView(m)
                    }
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
        VStack(alignment: .leading, spacing: 10) {
            if editingTitle {
                TextField("Untitled meeting", text: Binding(
                    get: { m.title },
                    set: { new in if let i = store.index(of: m.id) { store.meetings[i].title = new } }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 30, weight: .bold))
                .focused($titleFocused)
                .onSubmit { store.save(); editingTitle = false }
                .onChange(of: titleFocused) { _, f in if !f { store.save(); editingTitle = false } }
                .onAppear { titleFocused = true }
            } else {
                Text(m.title.isEmpty ? "Untitled meeting" : m.title)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(m.title.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { editingTitle = true }
                    .help("Click to rename")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Rename this meeting")
            }
            HStack(spacing: 14) {
                Label(m.date.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                    .lineLimit(1).fixedSize()
                Label(Exporter.clock(m.duration), systemImage: "clock").monospacedDigit()
                if let p = m.processingSeconds, p > 0 {
                    // Measured on this Mac for this recording.
                    Label(String(format: "processed in %.0f s (%.0f× real time)", p, m.duration / p), systemImage: "bolt")
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if m.status == .done {
                    Picker("People talking", selection: Binding(
                        get: { m.speakerCount ?? 0 },
                        set: { n in Task { await store.resplitSpeakers(m.id, count: n == 0 ? nil : n) } }
                    )) {
                        Text("Auto").tag(0)
                        ForEach(2...10, id: \.self) { n in Text("\(n)").tag(n) }
                    }
                    .fixedSize()
                    .help("If two people got merged into one speaker (or one person got split), tell the app how many people were talking.")
                }
            }
            .labelStyle(.titleAndIcon)
            .font(.callout).foregroundStyle(.secondary)
        }
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
            HStack(spacing: 8) {
                ForEach(m.clusters) { c in speakerChip(m, c) }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
        }
    }

    /// A speaker chip: a glass pill (dot, name, match, talk time). Clicking it opens a small
    /// popover with the naming choices. (A SwiftUI Menu would flatten this label to plain text.)
    private func speakerChip(_ m: Meeting, _ c: SpeakerCluster) -> some View {
        let person = store.person(c.personID)
        let suggestion = store.person(c.suggestedPersonID)
        let color = person.map { Palette.color($0.colorIndex) } ?? .gray
        return Button { chipKey = c.key } label: {
            HStack(spacing: 7) {
                Circle().fill(color).frame(width: 9, height: 9)
                Text(store.displayName(m, key: c.key)).fontWeight(.semibold)
                if let s = suggestion, person == nil { Text("maybe \(s.name)?").foregroundStyle(.secondary) }
                if c.confirmed {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Brand.accent)
                } else if let score = c.matchScore, person != nil {
                    Text(String(format: "%.0f%%", score * 100)).font(.caption).foregroundStyle(.secondary)
                }
                Text(Exporter.clock(c.talkSeconds)).font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .scribeGlass(Capsule(), tint: person == nil ? nil : color.opacity(0.12), interactive: true)
        .help("Click to name this speaker. Naming teaches the voice library.")
        .popover(isPresented: Binding(get: { chipKey == c.key }, set: { if !$0 { chipKey = nil } }), arrowEdge: .bottom) {
            speakerChoices(m, c, person: person, suggestion: suggestion)
        }
    }

    private func choiceRow(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button { chipKey = nil; action() } label: {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(MenuRowStyle())
    }

    private func speakerChoices(_ m: Meeting, _ c: SpeakerCluster, person: Person?, suggestion: Person?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let s = suggestion {
                choiceRow("Yes, this is \(s.name)", "checkmark") { store.assign(meetingID: m.id, clusterKey: c.key, to: s.id) }
            }
            if let p = person, !c.confirmed {
                choiceRow("Confirm \(p.name)", "checkmark.seal") { store.assign(meetingID: m.id, clusterKey: c.key, to: p.id) }
            }
            choiceRow("Play a sample", "play") { playSample(m, c.key) }
            Divider().padding(.vertical, 4)
            ForEach(store.people) { p in
                Button { chipKey = nil; store.assign(meetingID: m.id, clusterKey: c.key, to: p.id) } label: {
                    HStack(spacing: 8) {
                        Circle().fill(Palette.color(p.colorIndex)).frame(width: 8, height: 8)
                        Text(p.name)
                        Spacer()
                        if p.id == person?.id { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(MenuRowStyle())
            }
            choiceRow("New person…", "person.badge.plus") { newName = ""; namingKey = c.key }
            if person != nil {
                Divider().padding(.vertical, 4)
                choiceRow("Not them / unknown", "person.fill.questionmark") { store.clearSpeaker(meetingID: m.id, clusterKey: c.key) }
            }
        }
        .padding(8)
        .frame(width: 240)
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

    // MARK: Notes

    @ViewBuilder
    private func notesView(_ m: Meeting) -> some View {
        if store.notesInProgress.contains(m.id) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Writing notes on this Mac…").foregroundStyle(.secondary)
            }
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        } else if let n = m.notes {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    BlockHeading(title: "Summary", symbol: "text.alignleft")
                    Text(n.summary)
                        .font(.system(size: 15))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !n.keyPoints.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        BlockHeading(title: "Key points", symbol: "list.bullet")
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(n.keyPoints, id: \.self) { p in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Circle().fill(Color.secondary.opacity(0.6)).frame(width: 5, height: 5)
                                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                                    Text(p).font(.system(size: 15)).textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    BlockHeading(title: "Action items", symbol: "checklist")
                    if n.actionItems.isEmpty {
                        Text("Nothing to follow up on.").foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(n.actionItems.enumerated()), id: \.element.id) { i, a in
                                if i > 0 { Divider().overlay(Warm.hairline).padding(.leading, 34) }
                                actionRow(m, a)
                            }
                        }
                        .scribeCard(padding: 6)
                    }
                }
                HStack(alignment: .center) {
                    Text((n.note ?? "") + " " + (n.method == .appleIntelligence ? "Written by Apple Intelligence on this Mac — check it against the transcript." : ""))
                        .font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                    Button { Task { await store.makeNotes(m.id) } } label: {
                        Label("Redo notes", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .scribeButton()
                    .help("Redo after naming speakers, so action items get the right names.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            CozyEmptyState(symbol: "note.text", title: "No notes yet",
                           message: "Scribe can write a summary, key points and action items from the transcript.") {
                Button("Make notes") { Task { await store.makeNotes(m.id) } }.scribeButton(prominent: true)
            }
            .frame(minHeight: 260)
        }
    }

    private func actionRow(_ m: Meeting, _ a: ActionItem) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Button { store.toggleActionItem(meetingID: m.id, itemID: a.id) } label: {
                Image(systemName: a.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(a.done ? AnyShapeStyle(Warm.honey) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(a.done ? "Done" : "Not done")
            Text(a.task)
                .font(.system(size: 14))
                .strikethrough(a.done, color: .secondary)
                .foregroundStyle(a.done ? .secondary : .primary)
                .textSelection(.enabled)
            Spacer(minLength: 12)
            ownerPill(m, a.owner)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
    }

    /// The owner's name on a soft pill, tinted with their speaker color when we know them.
    private func ownerPill(_ m: Meeting, _ owner: String) -> some View {
        let person = store.people.first { $0.name == owner }
        let color = person.map { Palette.color($0.colorIndex) } ?? Color.secondary
        return Text(owner)
            .font(.caption.weight(.medium))
            .foregroundStyle(person == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(color))
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(person == nil ? AnyShapeStyle(Warm.well) : AnyShapeStyle(color.opacity(0.13)), in: Capsule())
    }

    // MARK: Transcript

    private func transcript(_ m: Meeting) -> some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(m.utterances) { u in
                let c = m.clusters.first { $0.key == u.speakerKey }
                let color = store.person(c?.personID).map { Palette.color($0.colorIndex) } ?? .gray
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Button(Exporter.clock(u.start)) { play(m, from: u.start) }
                        .buttonStyle(.link).monospacedDigit().font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(width: 52, alignment: .leading)
                        .help("Play from here")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.displayName(m, key: u.speakerKey))
                            .font(.callout.weight(.semibold)).foregroundStyle(color)
                        Text(u.text).font(.system(size: 14.5)).lineSpacing(3).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
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
