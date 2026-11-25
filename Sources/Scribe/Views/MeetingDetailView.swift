// MeetingDetailView.swift
// One meeting (0.7.3 "Poster"): title + meta, three tiles (duration, speakers, action items), a
// "speaker needs a name" notice (Listen / Name speaker), then the summary and action items
// (checkboxes saved to disk, owner chips) beside "Who talked" (share of talk time from the
// speaker diarization). Copy notes puts the summary + action items on the clipboard. The
// transcript is one switch away. Naming a speaker here teaches the voice library.

import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers

/// Plays a bit of a meeting's audio (speaker samples, "play from here"). One at a time, app-wide.
@MainActor
final class SamplePlayer: ObservableObject {
    static let shared = SamplePlayer()
    @Published private(set) var playing = false
    private var player: AVAudioPlayer?
    private var stopWork: DispatchWorkItem?

    func play(url: URL, from t: Double, seconds: Double? = nil) {
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.currentTime = max(0, t - 0.3)
        p.play()
        player = p
        playing = true
        if let seconds {
            let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.stop() } }
            stopWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
        }
    }

    func stop() {
        stopWork?.cancel()
        player?.stop()
        player = nil
        playing = false
    }

    /// The speaker's longest line (up to 8 s).
    func playSpeaker(_ m: Meeting, key: String, store: Store) {
        let lines = m.utterances.filter { $0.speakerKey == key }
        guard let u = lines.max(by: { ($0.end - $0.start) < ($1.end - $1.start) }) else { return }
        play(url: store.audioURL(for: m), from: u.start, seconds: min(8, max(2, u.end - u.start + 0.6)))
    }
}

struct MeetingDetailView: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var audio = SamplePlayer.shared
    let meetingID: UUID
    @State private var naming: SpeakerRef?
    @State private var editingTitle = false
    @State private var titleDraft = ""
    @State private var titleHover = false
    @State private var chipKey: String?
    @State private var moreOpen = false
    @State private var copied = false
    @FocusState private var titleFocused: Bool
    @State private var tab = DetailTab.notes
    enum DetailTab: String, CaseIterable { case notes = "Notes", transcript = "Transcript" }

    private var meeting: Meeting? { store.meetings.first { $0.id == meetingID } }

    var body: some View {
        if let m = meeting {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header(m)
                    if m.status == .done {
                        tiles(m).padding(.top, 20)
                        if let c = unnamed(m).first { notice(m, c, count: unnamed(m).count).padding(.top, 12) }
                        if tab == .notes {
                            HStack(alignment: .top, spacing: 36) {
                                notesColumn(m).frame(maxWidth: .infinity, alignment: .leading)
                                whoTalked(m).frame(width: 290)
                            }
                            .padding(.top, 26)
                        } else {
                            transcript(m).padding(.top, 26)
                        }
                    } else {
                        statusView(m).padding(.top, 60)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 22)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.never)
            .sheet(item: $naming) { ref in
                NameSpeakerSheet(meetingID: ref.meetingID, clusterKey: ref.key) { naming = nil }
                    .environmentObject(store)
            }
            .onDisappear { audio.stop() }
        }
    }

    private func unnamed(_ m: Meeting) -> [SpeakerCluster] {
        m.clusters.filter { $0.personID == nil }.sorted { $0.talkSeconds > $1.talkSeconds }
    }

    // MARK: Header

    private func header(_ m: Meeting) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if editingTitle {
                    TextField("Untitled meeting", text: $titleDraft)
                        .textFieldStyle(.plain)
                        .font(.pageTitle)
                        .foregroundStyle(Night.text)
                        .focused($titleFocused)
                        .padding(.horizontal, 6)
                        .background(RoundedRectangle(cornerRadius: Night.rControl, style: .continuous).fill(Night.well))
                        .overlay(RoundedRectangle(cornerRadius: Night.rControl, style: .continuous).strokeBorder(Night.line2, lineWidth: 1))
                        .padding(.leading, -6)
                        .onSubmit { commitTitle(m) }
                        .onExitCommand { editingTitle = false }
                        .onChange(of: titleFocused) { _, f in if !f, editingTitle { commitTitle(m) } }
                        .onAppear { titleDraft = m.title; DispatchQueue.main.async { titleFocused = true } }
                        .accessibilityLabel("Meeting title")
                } else {
                    HStack(spacing: 8) {
                        Text(m.title.isEmpty ? "Untitled meeting" : m.title)
                            .font(.pageTitle).tracking(-0.4)
                            .foregroundStyle(m.title.isEmpty ? Night.text3 : Night.text)
                            .lineLimit(2)
                        Image(systemName: "pencil")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Night.text3)
                            .opacity(titleHover ? 1 : 0)
                    }
                    .contentShape(Rectangle())
                    .onHover { titleHover = $0 }
                    .onTapGesture { titleDraft = m.title; editingTitle = true }
                    .help("Click to rename")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Rename this meeting")
                }
                Text(meta(m)).font(.nightBody).foregroundStyle(Night.text2).lineLimit(1)
            }
            Spacer(minLength: 12)
            if audio.playing {
                Button { audio.stop() } label: { Label("Stop audio", systemImage: "stop.fill") }
                    .buttonStyle(.nightSecondary)
            }
            if m.status == .done {
                NightSegmented(selection: $tab, options: DetailTab.allCases.map { (value: $0, title: $0.rawValue) })
                Button { copyNotes(m) } label: {
                    Label(copied ? "Copied" : "Copy notes", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.nightSecondary)
                .fixedSize()
            }
            Button { moreOpen.toggle() } label: { Image(systemName: "ellipsis") }
                .buttonStyle(NightIconButtonStyle(size: Night.controlHeight))
                .accessibilityLabel("More")
                .popover(isPresented: $moreOpen, arrowEdge: .bottom) { moreMenu(m) }
        }
    }

    private func moreMenu(_ m: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(ExportFormat.allCases) { f in
                Button { moreOpen = false; export(m, f) } label: {
                    Label("Export \(f.label)", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(MenuRowStyle())
                .disabled(m.status != .done)
            }
            NightDivider().padding(.vertical, 4)
            Button { moreOpen = false; Task { await store.makeNotes(m.id) } } label: {
                Label("Redo notes", systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(MenuRowStyle())
            .disabled(m.status != .done || m.utterances.isEmpty)
            Button { moreOpen = false; Task { await store.process(m.id) } } label: {
                Label("Re-process the recording", systemImage: "arrow.clockwise").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(MenuRowStyle())
            .disabled(!store.engineReady || m.status == .processing)
            if m.status == .done {
                NightDivider().padding(.vertical, 4)
                HStack {
                    Text("People talking").font(.nightSecondary).foregroundStyle(Night.text2)
                    Spacer()
                    speakerCountPicker(m)
                }
                .padding(.horizontal, 8)
            }
        }
        .padding(6)
        .frame(width: 290)
        .background(Night.raised)
    }

    private func commitTitle(_ m: Meeting) {
        store.renameMeeting(m.id, to: titleDraft)
        editingTitle = false
    }

    private func meta(_ m: Meeting) -> String {
        let cal = Calendar.current
        let day = cal.isDateInToday(m.date) ? "Today" : cal.isDateInYesterday(m.date) ? "Yesterday"
            : m.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        var parts = [day]
        if m.status == .done {
            let n = MeetingFormat.peopleCount(m)
            parts.append("\(n) \(n == 1 ? "person" : "people")")
        }
        parts.append("Recorded on this Mac")
        return parts.joined(separator: " · ")
    }

    private func speakerCountPicker(_ m: Meeting) -> some View {
        var counts: [(value: Int, title: String)] = [(value: 0, title: "Auto")]
        for n in 2...10 { counts.append((value: n, title: "\(n)")) }
        return NightPicker(selection: Binding(
            get: { m.speakerCount ?? 0 },
            set: { n in Task { await store.resplitSpeakers(m.id, count: n == 0 ? nil : n) } }
        ), options: counts)
        .help("If two people got merged into one speaker (or one person got split), tell Scribe how many people were talking.")
    }

    @ViewBuilder
    private func statusView(_ m: Meeting) -> some View {
        VStack(spacing: 14) {
            switch m.status {
            case .processing:
                ProgressView()
                Text(store.progressText[m.id] ?? "Working…").font(.nightBody).foregroundStyle(Night.text2)
            case .failed:
                Image(systemName: "exclamationmark.triangle").font(.system(size: 26)).foregroundStyle(Night.warn)
                Text(m.errorMessage ?? "Something went wrong.").font(.nightBody).foregroundStyle(Night.text2)
                    .multilineTextAlignment(.center).frame(maxWidth: 440)
                Button("Try again") { Task { await store.process(m.id) } }.buttonStyle(.nightPrimary)
            default:
                Image(systemName: "waveform").font(.system(size: 26)).foregroundStyle(Night.text3)
                Text(store.engineReady ? "Waiting to process…" : "Will process once the models are ready.")
                    .font(.nightBody).foregroundStyle(Night.text2)
                if store.engineReady { Button("Process now") { Task { await store.process(m.id) } }.buttonStyle(.nightPrimary) }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Tiles

    private func tiles(_ m: Meeting) -> some View {
        let speakers = m.clusters.sorted { $0.talkSeconds > $1.talkSeconds }
        let open = unnamed(m).count
        let items = m.notes?.actionItems ?? []
        let done = items.filter(\.done).count
        let secs = m.duration
        let end = m.date.addingTimeInterval(secs)
        let range = "\(m.date.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
        return HStack(spacing: Night.cardGap) {
            PosterTile(color: Night.posterIndigo, label: "Duration",
                       value: secs < 60 ? "\(Int(secs.rounded()))" : "\(Int((secs / 60).rounded()))",
                       unit: secs < 60 ? "s" : "min", caption: range,
                       height: 128, valueSize: 48) {
                RingGauge(fraction: secs / 3600, size: 40, line: 5)
            }
            PosterTile(color: Night.posterCoral, label: "Speakers", value: "\(MeetingFormat.peopleCount(m))",
                       caption: open == 0 ? "everyone has a name" : "\(open) still unnamed",
                       height: 128, valueSize: 48) {
                DaySquares(filled: Array(speakers.prefix(7)).map { $0.personID != nil }, size: 11)
            }
            PosterTile(color: Night.posterGreen, label: "Action items", value: "\(items.count)",
                       caption: items.isEmpty ? "nothing to follow up" : (done == 0 ? "none done yet" : "\(done) already done"),
                       height: 128, valueSize: 48) {
                DaySquares(filled: Array(items.prefix(7)).map(\.done), size: 11)
            }
        }
    }

    // MARK: Unnamed speaker notice

    private func notice(_ m: Meeting, _ c: SpeakerCluster, count: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "person")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.white)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: Night.rControl, style: .continuous).fill(Night.posterCoral))
            (Text(count == 1 ? "1 speaker needs a name. " : "\(count) speakers need a name. ").font(.nightHeadline).foregroundColor(Night.text)
             + Text("\(store.displayName(m, key: c.key)) talked for about \(MeetingFormat.minutes(c.talkSeconds)).")
                .font(.nightBody).foregroundColor(Night.text2))
                .lineLimit(2)
            Spacer(minLength: 8)
            Button { audio.playSpeaker(m, key: c.key, store: store) } label: { Label("Listen", systemImage: "play") }
                .buttonStyle(.nightSecondary)
            Button("Name speaker") { naming = SpeakerRef(meetingID: m.id, key: c.key) }
                .buttonStyle(.nightPrimary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(NightCardBackground())
    }

    // MARK: Notes column

    @ViewBuilder
    private func notesColumn(_ m: Meeting) -> some View {
        if store.notesInProgress.contains(m.id) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Writing notes on this Mac…").font(.nightBody).foregroundStyle(Night.text2)
            }
            .padding(.vertical, 20)
        } else if let n = m.notes {
            VStack(alignment: .leading, spacing: 0) {
                HairlineHeader(title: "Summary")
                Text(n.summary)
                    .font(.system(size: 15.5)).foregroundStyle(Night.text)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
                if !n.keyPoints.isEmpty {
                    HairlineHeader(title: "Key points").padding(.top, 24)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(n.keyPoints, id: \.self) { p in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("•").foregroundStyle(Night.text3)
                                Text(p).font(.nightReading).foregroundStyle(Night.text).lineSpacing(3)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.top, 12)
                }
                HairlineHeader(title: "Action items") {
                    Text("\(n.actionItems.count)").font(.nightSecondary).foregroundStyle(Night.text3)
                }
                .padding(.top, 24)
                if n.actionItems.isEmpty {
                    Text("Nothing to follow up on.").font(.nightBody).foregroundStyle(Night.text2).padding(.top, 12)
                } else {
                    ForEach(n.actionItems) { a in actionRow(m, a) }
                }
                Text(footnote(n)).font(.nightMeta).foregroundStyle(Night.text3).padding(.top, 14)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HairlineHeader(title: "Summary")
                Text("No notes yet. Scribe can write a summary, key points and action items from the transcript.")
                    .font(.nightBody).foregroundStyle(Night.text2)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Make notes") { Task { await store.makeNotes(m.id) } }.buttonStyle(.nightPrimary)
            }
        }
    }

    private func footnote(_ n: MeetingNotes) -> String {
        var s = n.method == .appleIntelligence ? "Written by Apple Intelligence on this Mac. Check it against the transcript."
                                               : "Quick notes picked from the transcript (no AI)."
        if let note = n.note, !note.isEmpty { s = note + " " + s }
        return s
    }

    private func actionRow(_ m: Meeting, _ a: ActionItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Button { store.toggleActionItem(meetingID: m.id, itemID: a.id) } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(a.done ? Night.primary : Night.surface)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(a.done ? Color.clear : Night.line2, lineWidth: 1.2)
                    if a.done {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Night.onPrimary)
                    }
                }
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(a.done ? "Done: \(a.task)" : "Not done: \(a.task)")
            Text(a.task)
                .font(.nightReading)
                .strikethrough(a.done, color: Night.text3)
                .foregroundStyle(a.done ? Night.text3 : Night.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            ownerChip(m, a.owner)
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { NightDivider() }
    }

    /// The owner's name with a colored initial when we know them.
    private func ownerChip(_ m: Meeting, _ owner: String) -> some View {
        let person = store.people.first { $0.name == owner }
        return HStack(spacing: 6) {
            if let p = person { Avatar(name: p.name, color: Palette.color(p.colorIndex), size: 20) }
            Text(owner).font(.system(size: 13.5, weight: .medium)).foregroundStyle(person == nil ? Night.text2 : Night.text)
                .lineLimit(1)
        }
        .padding(.leading, person == nil ? 10 : 4).padding(.trailing, 10)
        .frame(height: 28)
        .background(Capsule().fill(Night.well))
        .overlay(Capsule().strokeBorder(Night.line, lineWidth: 1))
    }

    // MARK: Who talked

    private func whoTalked(_ m: Meeting) -> some View {
        let total = max(1, m.clusters.reduce(0) { $0 + $1.talkSeconds })
        let rows = m.clusters.sorted { $0.talkSeconds > $1.talkSeconds }
        return VStack(alignment: .leading, spacing: 0) {
            HairlineHeader(title: "Who talked")
            VStack(alignment: .leading, spacing: 14) {
                ForEach(rows) { c in
                    speakerRow(m, c, share: c.talkSeconds / total)
                }
            }
            .padding(.top, 14)
            Text("Share of talk time. Click a name to change who it is.")
                .font(.nightMeta).foregroundStyle(Night.text3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
        }
    }

    private func speakerRow(_ m: Meeting, _ c: SpeakerCluster, share: Double) -> some View {
        let person = store.person(c.personID)
        let suggestion = store.person(c.suggestedPersonID)
        let color = person.map { Palette.color($0.colorIndex) } ?? Night.unnamed
        let name = store.displayName(m, key: c.key)
        return HStack(spacing: 12) {
            Button { chipKey = c.key } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.nightBody).foregroundStyle(Night.text).lineLimit(1)
                    if let s = suggestion, person == nil {
                        Text("maybe \(s.name)?").font(.nightMeta).foregroundStyle(Night.accent).lineLimit(1)
                    }
                }
                .frame(width: 92, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Name this speaker. Naming teaches Scribe the voice.")
            .popover(isPresented: Binding(get: { chipKey == c.key }, set: { if !$0 { chipKey = nil } }), arrowEdge: .bottom) {
                speakerChoices(m, c, person: person, suggestion: suggestion)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Night.line)
                    Capsule().fill(color).frame(width: max(6, geo.size.width * CGFloat(min(1, share))))
                }
            }
            .frame(height: 8)
            Text("\(Int((share * 100).rounded()))%").font(.nightSecondary).monospacedDigit().foregroundStyle(Night.text2)
                .frame(width: 40, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(Int((share * 100).rounded())) percent of the talking")
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
            choiceRow("Listen", "play") { audio.playSpeaker(m, key: c.key, store: store) }
            NightDivider().padding(.vertical, 4)
            ForEach(store.people) { p in
                Button { chipKey = nil; store.assign(meetingID: m.id, clusterKey: c.key, to: p.id) } label: {
                    HStack(spacing: 8) {
                        Avatar(name: p.name, color: Palette.color(p.colorIndex), size: 18)
                        Text(p.name)
                        Spacer()
                        if p.id == person?.id { Image(systemName: "checkmark").foregroundStyle(Night.text) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(MenuRowStyle())
            }
            choiceRow("New person…", "person.badge.plus") { naming = SpeakerRef(meetingID: m.id, key: c.key) }
            if person != nil {
                NightDivider().padding(.vertical, 4)
                choiceRow("Not them / unknown", "person.fill.questionmark") { store.clearSpeaker(meetingID: m.id, clusterKey: c.key) }
            }
        }
        .padding(8)
        .frame(width: 250)
        .background(Night.raised)
    }

    // MARK: Transcript

    private func transcript(_ m: Meeting) -> some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            ForEach(m.utterances) { u in
                let c = m.clusters.first { $0.key == u.speakerKey }
                let color = store.person(c?.personID).map { Palette.color($0.colorIndex) } ?? Night.unnamed
                let name = store.displayName(m, key: u.speakerKey)
                HStack(alignment: .top, spacing: 12) {
                    Avatar(name: name, color: color, size: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(name).font(.nightHeadline).foregroundStyle(Night.text)
                            Button(Exporter.clock(u.start)) { audio.play(url: store.audioURL(for: m), from: u.start) }
                                .buttonStyle(.plain)
                                .font(.nightMeta).monospacedDigit()
                                .foregroundStyle(Night.text3)
                                .help("Play from here")
                        }
                        Text(u.text).font(.nightReading).foregroundStyle(Night.text).lineSpacing(4).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: Brand.readingWidth, alignment: .leading)
    }

    // MARK: Copy / export

    private func copyNotes(_ m: Meeting) {
        var out = "\(m.title)\n\(m.date.formatted(date: .long, time: .shortened)) · \(MeetingFormat.minutes(m.duration))\n"
        if let n = m.notes {
            out += "\nSummary\n\(n.summary)\n"
            if !n.keyPoints.isEmpty { out += "\nKey points\n" + n.keyPoints.map { "- \($0)" }.joined(separator: "\n") + "\n" }
            if !n.actionItems.isEmpty {
                out += "\nAction items\n" + n.actionItems.map { "- [\($0.done ? "x" : " ")] \($0.task) (\($0.owner))" }.joined(separator: "\n") + "\n"
            }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(out, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    private func export(_ m: Meeting, _ f: ExportFormat) {
        let text = Exporter.render(m, format: f) { store.displayName(m, key: $0) }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = m.title.replacingOccurrences(of: "/", with: "-") + "." + f.rawValue
        if panel.runModal() == .OK, let url = panel.url {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// Which speaker the name sheet is for.
struct SpeakerRef: Identifiable, Hashable {
    var meetingID: UUID
    var key: String
    var id: String { meetingID.uuidString + "/" + key }
}

/// "Who is Speaker 4?": Listen, pick someone Scribe knows, or type a new name.
struct NameSpeakerSheet: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var audio = SamplePlayer.shared
    var meetingID: UUID
    var clusterKey: String
    var done: () -> Void
    @State private var name = ""

    private var meeting: Meeting? { store.meetings.first { $0.id == meetingID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let m = meeting {
                let c = m.clusters.first { $0.key == clusterKey }
                Text("Who is \(store.displayName(m, key: clusterKey))?").font(.nightTitle)
                Text("They talked for about \(MeetingFormat.minutes(c?.talkSeconds ?? 0)) in \(m.title.isEmpty ? "this meeting" : m.title). Name them once and Scribe knows them next time.")
                    .font(.nightSecondary).foregroundStyle(Night.text2)
                    .fixedSize(horizontal: false, vertical: true)
                Button { audio.playing ? audio.stop() : audio.playSpeaker(m, key: clusterKey, store: store) } label: {
                    Label(audio.playing ? "Stop" : "Listen", systemImage: audio.playing ? "stop.fill" : "play")
                }
                .buttonStyle(.nightSecondary)
                if !store.people.isEmpty {
                    WrapLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(store.people) { p in
                            PosterChip(action: { store.assign(meetingID: meetingID, clusterKey: clusterKey, to: p.id); finish() }) {
                                Avatar(name: p.name, color: Palette.color(p.colorIndex), size: 16)
                                Text(p.name)
                            }
                        }
                    }
                }
                NightField(placeholder: "New name", text: $name, onSubmit: save)
                HStack {
                    Spacer()
                    Button("Cancel") { finish() }.buttonStyle(.nightGhost)
                    Button("Save", action: save).buttonStyle(.nightPrimary).keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(22)
        .frame(width: 380)
        .background(Night.raised)
    }

    private func save() {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        store.createPerson(named: t, meetingID: meetingID, clusterKey: clusterKey)
        finish()
    }

    private func finish() {
        audio.stop()
        done()
    }
}

/// Talk share as a row of small segments (kept for older call sites).
struct TalkShare: View {
    var share: Double
    var segments = 16
    var body: some View {
        let filled = Int((min(1, max(0, share)) * Double(segments)).rounded())
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { i in
                Capsule().fill(i < filled ? Night.accent : Night.line2)
                    .frame(width: 4, height: 9)
            }
        }
        .accessibilityLabel("\(Int(share * 100)) percent of the talking")
    }
}
