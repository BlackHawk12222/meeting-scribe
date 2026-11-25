// MeetingDetailView.swift
// One meeting: the speakers found in it (name them here!), the notes, and the transcript.
// 0.7 "Night Sky": a 72 pt header (title, meta, actions), speaker cards with talk-share capsules,
// tabs with the capsule underline, notes and transcript on flat cards. No toolbar, no glass.

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
    @State private var exportOpen = false
    @FocusState private var titleFocused: Bool
    @State private var tab = DetailTab.notes
    enum DetailTab: String, CaseIterable { case notes = "Notes", transcript = "Transcript" }

    private var meeting: Meeting? { store.meetings.first { $0.id == meetingID } }

    var body: some View {
        if let m = meeting {
            VStack(alignment: .leading, spacing: 0) {
                header(m)
                    .padding(.leading, 28)
                    .padding(.trailing, Night.gutterTrailing)
                if m.status == .done {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            speakersRow(m)
                            HStack(alignment: .bottom) {
                                NightTabs(selection: $tab, options: DetailTab.allCases.map { (value: $0, title: $0.rawValue) })
                                Spacer()
                                speakerCountPicker(m)
                            }
                            Group {
                                if tab == .notes { notesView(m) } else { transcript(m) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.leading, 28)
                        .padding(.trailing, Night.gutterTrailing)
                        .padding(.bottom, 32)
                        .frame(maxWidth: Brand.readingWidth + 120, alignment: .leading)
                    }
                    .scrollIndicators(.never)
                } else {
                    statusView(m)
                }
            }
            .sheet(isPresented: Binding(get: { namingKey != nil }, set: { if !$0 { namingKey = nil } })) {
                nameSheet(m)
            }
        }
    }

    // MARK: Header

    private func header(_ m: Meeting) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if editingTitle {
                    TextField("Untitled meeting", text: Binding(
                        get: { m.title },
                        set: { new in if let i = store.index(of: m.id) { store.meetings[i].title = new } }
                    ))
                    .textFieldStyle(.plain)
                    .font(.nightDisplay)
                    .tint(Night.accent)
                    .focused($titleFocused)
                    .onSubmit { store.save(); editingTitle = false }
                    .onChange(of: titleFocused) { _, f in if !f { store.save(); editingTitle = false } }
                    .onAppear { titleFocused = true }
                } else {
                    Text(m.title.isEmpty ? "Untitled meeting" : m.title)
                        .font(.nightDisplay).tracking(-0.3)
                        .foregroundStyle(m.title.isEmpty ? Night.text3 : Night.text)
                        .lineLimit(1)
                        .contentShape(Rectangle())
                        .onTapGesture { editingTitle = true }
                        .help("Click to rename")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint("Rename this meeting")
                }
                Text(meta(m)).font(.nightMeta).foregroundStyle(Night.text3).lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            if player != nil {
                Button { player?.stop(); player = nil } label: { Label("Stop audio", systemImage: "stop.fill") }
                    .buttonStyle(.nightGhost)
            }
            Button { Task { await store.process(m.id) } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(NightIconButtonStyle(size: 36))
                .disabled(!store.engineReady || m.status == .processing)
                .help("Re-process this recording")
                .accessibilityLabel("Re-process")
            Button { exportOpen.toggle() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .buttonStyle(.nightSecondary)
                .disabled(m.status != .done)
                .popover(isPresented: $exportOpen, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(ExportFormat.allCases) { f in
                            Button { exportOpen = false; export(m, f) } label: {
                                Text(f.label).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                            .buttonStyle(MenuRowStyle())
                        }
                    }
                    .padding(6)
                    .frame(width: 220)
                    .background(Night.raised)
                }
        }
        .frame(height: Night.headerHeight)
    }

    private func meta(_ m: Meeting) -> String {
        var parts = [m.date.formatted(date: .abbreviated, time: .shortened), Exporter.clock(m.duration)]
        if let p = m.processingSeconds, p > 0 {
            parts.append(String(format: "processed in %.0f s (%.0f× real time)", p, m.duration / p))
        }
        return parts.joined(separator: "  ·  ")
    }

    private func speakerCountPicker(_ m: Meeting) -> some View {
        var counts: [(value: Int, title: String)] = [(value: 0, title: "Auto")]
        for n in 2...10 { counts.append((value: n, title: "\(n)")) }
        return HStack(spacing: 8) {
            Text("People talking").font(.nightMeta).foregroundStyle(Night.text3)
            NightPicker(selection: Binding(
                get: { m.speakerCount ?? 0 },
                set: { n in Task { await store.resplitSpeakers(m.id, count: n == 0 ? nil : n) } }
            ), options: counts)
        }
        .padding(.bottom, 8)
        .help("If two people got merged into one speaker (or one person got split), tell Scribe how many people were talking.")
    }

    @ViewBuilder
    private func statusView(_ m: Meeting) -> some View {
        VStack(spacing: 14) {
            switch m.status {
            case .processing:
                SparkleView(size: 40, glow: true)
                CapsuleSpinner(bars: 7)
                Text(store.progressText[m.id] ?? "Working…").font(.nightSecondary).foregroundStyle(Night.text2)
            case .failed:
                Image(systemName: "exclamationmark.triangle").font(.system(size: 28)).foregroundStyle(Night.warn)
                Text(m.errorMessage ?? "Something went wrong.").font(.nightSecondary).foregroundStyle(Night.text2)
                    .multilineTextAlignment(.center).frame(maxWidth: 420)
                Button("Try again") { Task { await store.process(m.id) } }.buttonStyle(.nightPrimary)
            default:
                SparkleView(size: 40, glow: true)
                Text(store.engineReady ? "Waiting to process…" : "Will process once the models are ready.")
                    .font(.nightSecondary).foregroundStyle(Night.text2)
                if store.engineReady { Button("Process now") { Task { await store.process(m.id) } }.buttonStyle(.nightPrimary) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Speakers

    private func speakersRow(_ m: Meeting) -> some View {
        let total = max(1, m.clusters.reduce(0) { $0 + $1.talkSeconds })
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Array(m.clusters.enumerated()), id: \.element.id) { i, c in
                    speakerCard(m, c, index: i, share: c.talkSeconds / total)
                }
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 1)
        }
    }

    /// A speaker card: avatar, name, match, talk share as 16 capsule segments. Clicking it opens a
    /// small popover with the naming choices.
    private func speakerCard(_ m: Meeting, _ c: SpeakerCluster, index: Int, share: Double) -> some View {
        let person = store.person(c.personID)
        let suggestion = store.person(c.suggestedPersonID)
        let color = person.map { Palette.color($0.colorIndex) } ?? Palette.color(index)
        let name = store.displayName(m, key: c.key)
        return Button { chipKey = c.key } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Avatar(name: name, color: person == nil ? Night.text3.opacity(0.55) : color, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(name).font(.scribe(13.5, 700)).foregroundStyle(Night.text).lineLimit(1)
                            if c.confirmed {
                                Image(systemName: "checkmark.seal.fill").font(.system(size: 10)).foregroundStyle(Night.accent)
                            }
                        }
                        Group {
                            if let s = suggestion, person == nil {
                                Text("maybe \(s.name)?").foregroundStyle(Night.accent)
                            } else if let score = c.matchScore, person != nil, !c.confirmed {
                                Text(String(format: "%.0f%% match", score * 100))
                            } else {
                                Text(Exporter.clock(c.talkSeconds)).monospacedDigit()
                            }
                        }
                        .font(.scribe(11.5, 600)).foregroundStyle(Night.text3).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Night.text3)
                }
                HStack(spacing: 8) {
                    TalkShare(share: share)
                    Text("\(Int((share * 100).rounded()))%").font(.scribe(11.5, 700)).monospacedDigit().foregroundStyle(Night.text3)
                }
            }
            .frame(width: 196, alignment: .leading)
            .padding(14)
            .background(NightCardBackground(radius: 16))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            NightDivider().padding(.vertical, 4)
            ForEach(store.people) { p in
                Button { chipKey = nil; store.assign(meetingID: m.id, clusterKey: c.key, to: p.id) } label: {
                    HStack(spacing: 8) {
                        Avatar(name: p.name, color: Palette.color(p.colorIndex), size: 18)
                        Text(p.name)
                        Spacer()
                        if p.id == person?.id { Image(systemName: "checkmark").foregroundStyle(Night.accent) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(MenuRowStyle())
            }
            choiceRow("New person…", "person.badge.plus") { newName = ""; namingKey = c.key }
            if person != nil {
                NightDivider().padding(.vertical, 4)
                choiceRow("Not them / unknown", "person.fill.questionmark") { store.clearSpeaker(meetingID: m.id, clusterKey: c.key) }
            }
        }
        .padding(8)
        .frame(width: 250)
        .background(Night.raised)
    }

    private func nameSheet(_ m: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Who is \(store.displayName(m, key: namingKey ?? ""))?").font(.nightTitle)
            Text("Tip: use “Play a sample” on the speaker first.").font(.nightMeta).foregroundStyle(Night.text3)
            NightField(placeholder: "Name", text: $newName, onSubmit: saveName)
            HStack {
                Spacer()
                Button("Cancel") { namingKey = nil }.buttonStyle(.nightGhost)
                Button("Save", action: saveName).buttonStyle(.nightPrimary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 340)
        .background(Night.raised)
    }

    private func saveName() {
        if let key = namingKey { store.createPerson(named: newName, meetingID: meetingID, clusterKey: key) }
        namingKey = nil
    }

    // MARK: Notes

    @ViewBuilder
    private func notesView(_ m: Meeting) -> some View {
        if store.notesInProgress.contains(m.id) {
            HStack(spacing: 12) {
                CapsuleSpinner()
                Text("Writing notes on this Mac…").font(.nightSecondary).foregroundStyle(Night.text2)
            }
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
            .nightCard()
        } else if let n = m.notes {
            VStack(alignment: .leading, spacing: Night.cardGap) {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(title: "Summary")
                    Text(n.summary)
                        .font(.scribe(14, 500))
                        .foregroundStyle(Night.text)
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .nightCard(padding: 22)
                if !n.keyPoints.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(title: "Key points")
                        VStack(alignment: .leading, spacing: 9) {
                            ForEach(n.keyPoints, id: \.self) { p in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Sparkle().fill(Night.star).frame(width: 8, height: 8)
                                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                                    Text(p).font(.scribe(14, 500)).foregroundStyle(Night.text).lineSpacing(3)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .nightCard(padding: 22)
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(title: "Action items").padding(.horizontal, 22).padding(.top, 20)
                    if n.actionItems.isEmpty {
                        Text("Nothing to follow up on.").font(.nightSecondary).foregroundStyle(Night.text2)
                            .padding(.horizontal, 22).padding(.bottom, 20)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(n.actionItems.enumerated()), id: \.element.id) { i, a in
                                if i > 0 { NightDivider().padding(.leading, 50) }
                                actionRow(m, a)
                            }
                        }
                        .padding(.bottom, 6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(NightCardBackground())
                HStack(alignment: .center) {
                    Text((n.note ?? "") + " " + (n.method == .appleIntelligence ? "Written by Apple Intelligence on this Mac — check it against the transcript." : ""))
                        .font(.nightMeta).foregroundStyle(Night.text3)
                    Spacer()
                    Button { Task { await store.makeNotes(m.id) } } label: {
                        Label("Redo notes", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.nightSecondary)
                    .help("Redo after naming speakers, so action items get the right names.")
                }
            }
        } else {
            CozyEmptyState(symbol: "note.text", title: "No notes yet",
                           message: "Scribe can write a summary, key points and action items from the transcript.") {
                Button("Make notes") { Task { await store.makeNotes(m.id) } }.buttonStyle(.nightPrimary)
            }
            .frame(minHeight: 260)
            .background(NightCardBackground())
        }
    }

    private func actionRow(_ m: Meeting, _ a: ActionItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Button { store.toggleActionItem(meetingID: m.id, itemID: a.id) } label: {
                ZStack {
                    Circle().strokeBorder(a.done ? Color.clear : Night.line2, lineWidth: 1.5)
                    if a.done {
                        Circle().fill(Night.gradient)
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(Night.onAccent)
                    }
                }
                .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(a.done ? "Done" : "Not done")
            Text(a.task)
                .font(.scribe(14, 500))
                .strikethrough(a.done, color: Night.text3)
                .foregroundStyle(a.done ? Night.text3 : Night.text)
                .textSelection(.enabled)
            Spacer(minLength: 12)
            ownerPill(m, a.owner)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
    }

    /// The owner's name with their avatar when we know them.
    private func ownerPill(_ m: Meeting, _ owner: String) -> some View {
        let person = store.people.first { $0.name == owner }
        return HStack(spacing: 6) {
            if let p = person { Avatar(name: p.name, color: Palette.color(p.colorIndex), size: 18) }
            Text(owner).font(.scribe(12, 700)).foregroundStyle(person == nil ? Night.text3 : Night.text)
        }
        .padding(.leading, person == nil ? 10 : 3).padding(.trailing, 10)
        .frame(height: 26)
        .background(Capsule().fill(Night.raised))
        .overlay(Capsule().strokeBorder(Night.line, lineWidth: 1))
    }

    // MARK: Transcript

    private func transcript(_ m: Meeting) -> some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(m.utterances) { u in
                let idx = m.clusters.firstIndex { $0.key == u.speakerKey } ?? 0
                let c = m.clusters.first { $0.key == u.speakerKey }
                let color = store.person(c?.personID).map { Palette.color($0.colorIndex) } ?? Palette.color(idx)
                let name = store.displayName(m, key: u.speakerKey)
                HStack(alignment: .top, spacing: 12) {
                    Avatar(name: name, color: color, size: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(name).font(.scribe(13, 700)).foregroundStyle(Night.text)
                            Button(Exporter.clock(u.start)) { play(m, from: u.start) }
                                .buttonStyle(.plain)
                                .font(.scribe(11.5, 600)).monospacedDigit()
                                .foregroundStyle(Night.text3)
                                .help("Play from here")
                        }
                        Text(u.text).font(.scribe(14, 500)).foregroundStyle(Night.text).lineSpacing(4).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .nightCard(padding: 22)
    }

    // MARK: Export

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

/// Talk share as a row of 16 small capsule segments (filled ones in the gradient).
struct TalkShare: View {
    var share: Double
    var segments = 16
    var body: some View {
        let filled = Int((min(1, max(0, share)) * Double(segments)).rounded())
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { i in
                Capsule().fill(i < filled ? AnyShapeStyle(Night.gradient) : AnyShapeStyle(Night.line2))
                    .frame(width: 4, height: 9)
            }
        }
        .accessibilityLabel("\(Int(share * 100)) percent of the talking")
    }
}
