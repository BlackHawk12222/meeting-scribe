// PeopleView.swift
// The voice library (0.7.3 "Poster"): a banner when a meeting has a voice nobody named yet
// (Listen / Not now / Name this voice), three tiles (people known, voices that need a name,
// meetings with everyone labeled) and a card per person with voice strength, meetings and when
// Scribe last heard them. "Add person" opens the guided enrollment (VoiceEnrollmentView).
//
// Voice strength (how well Scribe can tell this voice apart), from what the library holds:
//   Strong   = heard in 5+ meetings, or a guided enrollment + 2+ meetings, or 30+ min of
//              confirmed talk time
//   Good     = heard in 2+ meetings, or a guided enrollment, or 5+ min of confirmed talk time
//   Learning = anything less (one meeting, a few minutes)
// "Heard in a meeting" = a speaker in that meeting is labeled as this person.

import SwiftUI

enum VoiceStrength: String {
    case strong = "Strong", good = "Good", learning = "Learning"

    static func of(meetings: Int, enrolled: Bool, talkSeconds: Double) -> VoiceStrength {
        if meetings >= 5 || (enrolled && meetings >= 2) || talkSeconds >= 30 * 60 { return .strong }
        if meetings >= 2 || enrolled || talkSeconds >= 5 * 60 { return .good }
        return .learning
    }
    /// Filled segments out of 5.
    var segments: Int {
        switch self { case .strong: return 5; case .good: return 3; case .learning: return 1 }
    }
    var color: Color {
        switch self { case .strong: return Night.posterGreen; case .good: return Night.posterIndigo; case .learning: return Night.posterCoral }
    }
}

/// What People shows about one person, computed from the meetings.
struct PersonSummary {
    var person: Person
    var meetings: Int
    var talkSeconds: Double
    var lastHeard: Date?
    var strength: VoiceStrength
}

/// A voice nobody has named yet, in a finished meeting.
struct UnknownVoice {
    var meeting: Meeting
    var cluster: SpeakerCluster
    var id: String { meeting.id.uuidString + "/" + cluster.key }
}

extension Store {
    func personSummaries() -> [PersonSummary] {
        people.map { p in
            var count = 0, talk = 0.0
            var last: Date?
            for m in meetings where m.status == .done {
                let mine = m.clusters.filter { $0.personID == p.id }
                guard !mine.isEmpty else { continue }
                count += 1
                talk += mine.filter(\.confirmed).reduce(0) { $0 + $1.talkSeconds }
                if last == nil || m.date > last! { last = m.date }
            }
            if last == nil { last = p.samples.map(\.addedAt).max() }
            let enrolled = p.samples.contains { $0.isEnrollment }
            return PersonSummary(person: p, meetings: count, talkSeconds: talk, lastHeard: last,
                                 strength: VoiceStrength.of(meetings: count, enrolled: enrolled, talkSeconds: talk))
        }
        .sorted { $0.meetings != $1.meetings ? $0.meetings > $1.meetings : $0.person.name < $1.person.name }
    }

    static let dismissedVoicesKey = "dismissedVoices"

    /// Unnamed speakers in finished meetings, newest meeting first, longest talker first; ones
    /// dismissed with "Not now" are skipped.
    func unknownVoices() -> [UnknownVoice] {
        let dismissed = Set(UserDefaults.standard.stringArray(forKey: Self.dismissedVoicesKey) ?? [])
        var out: [UnknownVoice] = []
        for m in meetings.sorted(by: { $0.date > $1.date }) where m.status == .done {
            for c in m.clusters.filter({ $0.personID == nil }).sorted(by: { $0.talkSeconds > $1.talkSeconds }) {
                let v = UnknownVoice(meeting: m, cluster: c)
                if !dismissed.contains(v.id) { out.append(v) }
            }
        }
        return out
    }

    func dismissVoice(_ v: UnknownVoice) {
        var list = UserDefaults.standard.stringArray(forKey: Self.dismissedVoicesKey) ?? []
        list.append(v.id)
        UserDefaults.standard.set(Array(list.suffix(500)), forKey: Self.dismissedVoicesKey)
        objectWillChange.send()
    }
}

struct PeopleView: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var audio = SamplePlayer.shared
    @Binding var query: String
    var openMeeting: (UUID) -> Void = { _ in }
    @State private var renaming: Person?
    @State private var newName = ""
    @State private var adding = false
    @State private var naming: SpeakerRef?

    init(query: Binding<String> = .constant(""), openMeeting: @escaping (UUID) -> Void = { _ in }) {
        _query = query
        self.openMeeting = openMeeting
    }

    var body: some View {
        let summaries = store.personSummaries()
        let unknown = store.unknownVoices()
        let q = query.trimmingCharacters(in: .whitespaces)
        let shown = q.isEmpty ? summaries : summaries.filter { $0.person.name.localizedCaseInsensitiveContains(q) }
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let v = unknown.first { banner(v).padding(.bottom, 12) }
                tiles(summaries, unknown: unknown)
                HairlineHeader(title: "Everyone") {
                    Text("Sorted by meetings").font(.nightSecondary).foregroundStyle(Night.text3)
                    Button { adding = true } label: { Label("Add person", systemImage: "plus") }
                        .buttonStyle(.nightSecondary)
                        .help("Teach Scribe someone's voice: they read six short lines out loud")
                }
                .padding(.top, 28)
                if store.people.isEmpty {
                    CozyEmptyState(symbol: "person.2", title: "No one here yet",
                                   message: "Name a speaker after a meeting, or teach Scribe a voice in about a minute.") {
                        Button { adding = true } label: { Text("Add person") }.buttonStyle(.nightPrimary)
                    }
                    .frame(minHeight: 260)
                } else if shown.isEmpty {
                    Text("No one matches “\(q)”.").font(.nightSecondary).foregroundStyle(Night.text3).padding(.top, 14)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 520), spacing: Night.cardGap)],
                              alignment: .leading, spacing: Night.cardGap) {
                        ForEach(shown, id: \.person.id) { s in card(s) }
                    }
                    .padding(.top, 14)
                }
            }
            .padding(.horizontal, Night.gutterLeading)
            .padding(.top, 22)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.never)
        .sheet(isPresented: $adding) {
            VoiceEnrollmentView().environmentObject(store)
        }
        .sheet(item: $naming) { ref in
            NameSpeakerSheet(meetingID: ref.meetingID, clusterKey: ref.key) { naming = nil }
                .environmentObject(store)
        }
        .sheet(item: $renaming) { p in
            VStack(alignment: .leading, spacing: 12) {
                Text("Rename \(p.name)").font(.nightTitle)
                NightField(placeholder: "Name", text: $newName) { store.rename(personID: p.id, to: newName); renaming = nil }
                HStack {
                    Spacer()
                    Button("Cancel") { renaming = nil }.buttonStyle(.nightGhost)
                    Button("Save") { store.rename(personID: p.id, to: newName); renaming = nil }
                        .buttonStyle(.nightPrimary)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(22).frame(width: 320)
            .background(Night.raised)
        }
    }

    // MARK: Banner

    private func banner(_ v: UnknownVoice) -> some View {
        let name = store.displayName(v.meeting, key: v.cluster.key)
        let title = v.meeting.title.isEmpty ? "a meeting" : v.meeting.title
        return HStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Night.posterCoral))
            VStack(alignment: .leading, spacing: 2) {
                Text("New voice in \(title)").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.white)
                    .lineLimit(1)
                Text("\(name) talked for about \(MeetingFormat.minutes(v.cluster.talkSeconds)). Name them once and Scribe will know them next time.")
                    .font(.nightSecondary).foregroundStyle(Color.white.opacity(0.7))
                    .lineLimit(2)
            }
            Spacer(minLength: 10)
            Button { audio.playSpeaker(v.meeting, key: v.cluster.key, store: store) } label: { Label("Listen", systemImage: "play") }
                .buttonStyle(BannerButtonStyle(filled: false))
            Button("Not now") { store.dismissVoice(v) }
                .buttonStyle(BannerButtonStyle(filled: false))
            Button("Name this voice") { naming = SpeakerRef(meetingID: v.meeting.id, key: v.cluster.key) }
                .buttonStyle(BannerButtonStyle(filled: true))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: Night.rTile, style: .continuous).fill(Night.posterBlack))
        .overlay(RoundedRectangle(cornerRadius: Night.rTile, style: .continuous).strokeBorder(Night.posterBlackEdge, lineWidth: 1))
    }

    // MARK: Tiles

    private func tiles(_ summaries: [PersonSummary], unknown: [UnknownVoice]) -> some View {
        let done = store.meetings.filter { $0.status == .done }
        let labeled = done.filter { !$0.clusters.isEmpty && $0.clusters.allSatisfy { $0.personID != nil } }
        // "Needs a name": the unnamed voices in the newest meeting that has one.
        let newest = unknown.first?.meeting
        let needs = newest.map { m in unknown.filter { $0.meeting.id == m.id }.count } ?? 0
        let needsCaption: String = {
            guard let m = newest else { return "every voice has a name" }
            if Calendar.current.isDateInToday(m.date) { return "from today's meeting" }
            if Calendar.current.isDateInYesterday(m.date) { return "from yesterday's meeting" }
            return "from \(m.title.isEmpty ? "a recent meeting" : m.title)"
        }()
        // Bars: labeled meetings per week, last 6 weeks.
        let cal = Calendar.current
        let weekStart = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        let bars: [Int] = (0..<6).reversed().map { w in
            let s = cal.date(byAdding: .weekOfYear, value: -w, to: weekStart) ?? weekStart
            let e = cal.date(byAdding: .weekOfYear, value: 1, to: s) ?? s
            return labeled.filter { $0.date >= s && $0.date < e }.count
        }
        return GeometryReader { geo in
            let gap = Night.cardGap
            let unit = (geo.size.width - 2 * gap) / 3.25
            HStack(spacing: gap) {
                PosterTile(color: Night.posterIndigo, label: "People known", value: "\(summaries.count)",
                           caption: summaries.count == 1 ? "voice Scribe can tell apart" : "voices Scribe can tell apart",
                           height: 120, valueSize: 52) {
                    DaySquares(filled: (0..<min(7, max(1, summaries.count))).map { $0 < summaries.count }, size: 11)
                }
                .frame(width: unit * 1.25)
                PosterTile(color: Night.posterCoral, label: "Needs a name", value: "\(needs)", caption: needsCaption,
                           height: 120, valueSize: 52) {
                    DaySquares(filled: Array(repeating: true, count: min(7, needs)), size: 11)
                }
                .frame(width: unit)
                PosterTile(color: Night.posterBlack, label: "Meetings", value: "\(labeled.count)",
                           caption: "with everyone labeled", height: 120, valueSize: 52, outlined: true) {
                    MiniBars(values: bars, highlight: 5, height: 34, barWidth: 7)
                }
                .frame(width: unit)
            }
        }
        .frame(height: 120)
    }

    // MARK: Card

    private func card(_ s: PersonSummary) -> some View {
        let p = s.person
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Avatar(name: p.name, color: Palette.color(p.colorIndex), size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Night.text).lineLimit(1)
                    Text(lastHeard(s.lastHeard)).font(.nightSecondary).foregroundStyle(Night.text2).lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(s.strength.rawValue)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(s.strength.color)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(s.strength.color.opacity(0.12)))
                    .help(strengthHelp(s))
            }
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(i < s.strength.segments ? s.strength.color : Night.line)
                        .frame(height: 5)
                }
            }
            HStack {
                Text("Voice strength").font(.nightSecondary).foregroundStyle(Night.text2)
                Spacer()
                Text("\(s.meetings) meeting\(s.meetings == 1 ? "" : "s")").font(.nightSecondary).foregroundStyle(Night.text2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(NightCardBackground())
        .contentShape(Rectangle())
        .contextMenu {
            Button("Rename…") { newName = p.name; renaming = p }
            Button("Delete", role: .destructive) { store.deletePerson(p.id) }
        }
        .accessibilityElement(children: .combine)
    }

    private func lastHeard(_ d: Date?) -> String {
        guard let d else { return "Not heard in a meeting yet" }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Last heard Today" }
        if cal.isDateInYesterday(d) { return "Last heard Yesterday" }
        if let days = cal.dateComponents([.day], from: d, to: Date()).day, days < 7 {
            return "Last heard \(d.formatted(.dateTime.weekday(.abbreviated)))"
        }
        return "Last heard \(d.formatted(.dateTime.month(.abbreviated).day()))"
    }

    private func strengthHelp(_ s: PersonSummary) -> String {
        "\(s.meetings) meeting\(s.meetings == 1 ? "" : "s"), \(MeetingFormat.minutes(s.talkSeconds)) of confirmed talk"
            + (s.person.samples.contains { $0.isEnrollment } ? ", guided enrollment" : "")
            + ". Strong: 5+ meetings, enrollment + 2 meetings, or 30+ min. Good: 2+ meetings, enrollment, or 5+ min."
    }
}

/// Buttons on the black banner: outlined (Listen, Not now) or white (Name this voice).
struct BannerButtonStyle: ButtonStyle {
    var filled: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(filled ? Color(hex: 0x111113) : Color.white)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: Night.rControl, style: .continuous).fill(filled ? Color.white : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: Night.rControl, style: .continuous)
                .strokeBorder(filled ? Color.clear : Color.white.opacity(0.28), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .lineLimit(1)
            .fixedSize()
    }
}
