// ContentView.swift
// The main window (0.7 "Night Sky"): a slim icon rail on the left (Home, Meetings, Dictations,
// People, with Settings and the profile pinned to the bottom) and the page on the right, all over
// a faint static starfield. No system sidebar, no title bar: the traffic lights float over the
// rail (WindowChrome in ScribeApp.swift) and every page draws its own 72 pt header.

import SwiftUI

/// Kept for older call sites (Snapshot, menu bar): what to open first.
enum SidebarItem: Hashable {
    case meeting(UUID)
    case people
    case dictation
}

enum NavSection: String, Hashable, CaseIterable {
    case home, meetings, dictations, people, settings

    var title: String {
        switch self {
        case .home: return "Home"
        case .meetings: return "Meetings"
        case .dictations: return "Dictations"
        case .people: return "People"
        case .settings: return "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .home: return "house"
        case .meetings: return "waveform"
        case .dictations: return "mic"
        case .people: return "person.2"
        case .settings: return "slider.horizontal.3"
        }
    }
}

/// Snapshot: show the live meeting screen without a microphone.
struct LivePreview {
    var elapsed: TimeInterval
    var tape: LevelTape
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: Store
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var permissions: Permissions
    @EnvironmentObject var dictation: DictationController
    @EnvironmentObject var models: ModelStore
    @AppStorage("onboarded") private var onboarded = false
    @State private var section: NavSection
    @State private var selectedMeeting: UUID?
    @State private var query = ""
    @State private var searchFocus = 0
    private let livePreview: LivePreview?
    private let settingsPane: SettingsPane?

    init(initialSelection: SidebarItem? = nil, section: NavSection? = nil, livePreview: LivePreview? = nil,
         settingsPane: SettingsPane? = nil) {
        var s: NavSection = section ?? .home
        var m: UUID? = nil
        switch initialSelection {
        case .meeting(let id): s = section ?? .meetings; m = id
        case .people: s = .people
        case .dictation: s = .dictations
        case nil: break
        }
        _section = State(initialValue: s)
        _selectedMeeting = State(initialValue: m)
        self.livePreview = livePreview
        self.settingsPane = settingsPane
    }

    private var isLive: Bool { recorder.isRecording || livePreview != nil }

    var body: some View {
        ZStack {
            Night.canvas
            Starfield(seed: 11)
            HStack(spacing: 0) {
                NavRail(section: $section, live: isLive)
                VStack(spacing: 0) {
                    page
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ignoresSafeArea()
        .foregroundStyle(Night.text)
        .background(hiddenShortcuts)
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
            if let id { selectedMeeting = id; section = .meetings }
        }
        .onChange(of: model.openMeetingRequest) { _, id in
            if let id { selectedMeeting = id; section = .meetings; model.openMeetingRequest = nil }
        }
        .onChange(of: recorder.isRecording) { _, on in
            if on { withAnimation(Night.spring) { section = .meetings } }
        }
        .onAppear {
            if let id = model.openMeetingRequest { selectedMeeting = id; section = .meetings; model.openMeetingRequest = nil }
        }
    }

    /// ⌘K focuses search, ⌘R records, ⌘1–5 switch pages.
    private var hiddenShortcuts: some View {
        ZStack {
            Button("") { searchFocus += 1 }.keyboardShortcut("k", modifiers: [.command])
            Button("") { model.toggleMeetingRecording() }.keyboardShortcut("r", modifiers: [.command])
            ForEach(Array(NavSection.allCases.enumerated()), id: \.offset) { i, s in
                Button("") { section = s }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command])
            }
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var page: some View {
        switch section {
        case .home:
            HomeView(query: $query, searchFocus: searchFocus,
                     open: { id in selectedMeeting = id; section = .meetings },
                     seeAllDictations: { section = .dictations })
        case .meetings:
            if isLive {
                LiveMeetingView(preview: livePreview)
            } else {
                MeetingsPage(selected: $selectedMeeting, query: $query, searchFocus: searchFocus)
            }
        case .dictations:
            DictationHistoryView(query: query, queryBinding: $query, searchFocus: searchFocus)
        case .people:
            PeopleView(query: $query, searchFocus: searchFocus)
        case .settings:
            SettingsPage(initial: settingsPane ?? .dictation, inWindow: true)
        }
    }
}

// MARK: - Nav rail

/// 76 pt rail: the app icon on top, 44 pt icon buttons, Settings and the profile at the bottom.
/// Selected: accentSoft pill, accent icon, a small sparkle top-right, a 4 pt gradient tick on the
/// rail's left edge.
struct NavRail: View {
    @Binding var section: NavSection
    var live = false
    @Namespace private var ns

    var body: some View {
        VStack(spacing: 6) {
            AppIconView(size: 32)
                .padding(.bottom, 16)
            ForEach([NavSection.home, .meetings, .dictations, .people], id: \.self) { s in
                item(s)
            }
            Spacer(minLength: 12)
            item(.settings)
            Text(String(NSFullUserName().prefix(1)).uppercased().isEmpty ? "S" : String(NSFullUserName().prefix(1)).uppercased())
                .font(.scribe(12, 700))
                .foregroundStyle(Night.text2)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Night.raised))
                .overlay(Circle().strokeBorder(Night.line2, lineWidth: 1))
                .padding(.top, 8)
                .accessibilityHidden(true)
        }
        .padding(.top, 54)
        .padding(.bottom, 20)
        .frame(width: Night.railWidth)
        .frame(maxHeight: .infinity)
        .background(Night.rail)
        .overlay(alignment: .trailing) { NightDivider(vertical: true) }
    }

    private func item(_ s: NavSection) -> some View {
        let on = section == s
        return Button { withAnimation(Night.spring) { section = s } } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: s.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(on ? Night.accent : Night.text3)
                    .frame(width: 38, height: 38)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: Night.rPill, style: .continuous).fill(Night.accentSoft)
                                .matchedGeometryEffect(id: "pill", in: ns)
                        }
                    }
                if on {
                    Sparkle().fill(Night.star)
                        .frame(width: 7, height: 7)
                        .padding(5)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                if s == .meetings && live {
                    Circle().fill(Night.live).frame(width: 7, height: 7).padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
            .frame(width: 38, height: 38)
            .overlay(alignment: .leading) {
                if on {
                    Capsule().fill(Night.gradient)
                        .frame(width: 4, height: 20)
                        .offset(x: -11)
                        .matchedGeometryEffect(id: "tick", in: ns)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(s.title)
        .accessibilityLabel(s.title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: Store
    @EnvironmentObject var recorder: Recorder
    @Binding var query: String
    var searchFocus: Int
    var open: (UUID) -> Void
    var seeAllDictations: () -> Void
    @State private var tab = HomeTab.recent
    enum HomeTab: Hashable { case recent, week }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: greeting, subtitle: Date().formatted(.dateTime.weekday(.wide).month(.abbreviated).day())) {
                NightSearchField(text: $query, prompt: "Search notes & dictations", focusRequest: searchFocus)
                Button { model.toggleMeetingRecording() } label: {
                    Label(recorder.isRecording ? "Stop meeting" : "Record meeting",
                          systemImage: recorder.isRecording ? "stop.fill" : "plus")
                }
                .buttonStyle(.nightPrimary)
            }
            if !store.engineReady { ModelBanner().padding(.bottom, 12) }
            GeometryReader { geo in
                let wide = geo.size.width > 760
                VStack(spacing: Night.cardGap) {
                    HStack(spacing: Night.cardGap) {
                        startCard.frame(maxWidth: .infinity)
                        if wide { dictateCard.frame(width: max(260, geo.size.width * 0.39)) }
                    }
                    .frame(height: 132)
                    HStack(alignment: .top, spacing: Night.cardGap) {
                        meetingsCard.frame(maxWidth: .infinity, maxHeight: .infinity)
                        if wide { dictationsCard.frame(width: max(260, geo.size.width * 0.39)).frame(maxHeight: .infinity) }
                    }
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 28)
        }
        .padding(.leading, Night.gutterLeading)
        .padding(.trailing, Night.gutterTrailing)
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        if h < 5 || h >= 18 { return "Good evening" }
        if h < 12 { return "Good morning" }
        return "Good afternoon"
    }

    // MARK: Cards

    private var startCard: some View {
        HStack(spacing: 22) {
            RecordButton(recording: recorder.isRecording) { model.toggleMeetingRecording() }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text(recorder.isRecording ? "Recording a meeting" : "Start a meeting").font(.nightTitle)
                    if recorder.isRecording { LiveChip(text: Night.clock(recorder.elapsed)) }
                }
                Text("Scribe listens, tells voices apart, and writes the notes when you stop.")
                    .font(.nightSecondary).foregroundStyle(Night.text2).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            CapsuleBars(levels: CapsuleBars.wave(9, seed: 3, floor: 0.2), barWidth: 5, spacing: 4, maxLength: 44, style: .dim)
        }
        .padding(.horizontal, 24)
        .frame(maxHeight: .infinity)
        .background(NightCardBackground())
    }

    private var dictateCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(title: "Dictate anywhere")
            HStack(spacing: 6) {
                Text("Hold").font(.nightSecondary).foregroundStyle(Night.text2)
                Keycap(text: DictationSettings.holdKey.keycap, height: 24)
                Text("in any text box, speak, let go.").font(.nightSecondary).foregroundStyle(Night.text2)
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
            .padding(.top, 12)
            Text("\(wordsToday) words dictated today").font(.nightMeta).foregroundStyle(Night.text3).padding(.top, 12)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(NightCardBackground())
    }

    private var wordsToday: Int {
        store.dictations.filter { Calendar.current.isDateInToday($0.date) }
            .reduce(0) { $0 + $1.text.split(separator: " ").count }
    }

    private var shownMeetings: [Meeting] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            let ids = Set(store.search(q).map(\.id))
            return store.meetings.filter { ids.contains($0.id) }
        }
        switch tab {
        case .recent: return store.meetings
        case .week:
            let start = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date.distantPast
            return store.meetings.filter { $0.date >= start }
        }
    }

    private var meetingsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                if query.isEmpty {
                    NightTabs(selection: $tab, options: [(value: HomeTab.recent, title: "Meetings"), (value: HomeTab.week, title: "This week")])
                } else {
                    SectionLabel(title: "Matching “\(query)”").padding(.top, 2)
                }
                Spacer()
                Text("\(shownMeetings.count) meeting\(shownMeetings.count == 1 ? "" : "s")").font(.nightMeta).foregroundStyle(Night.text3)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 6)
            if shownMeetings.isEmpty {
                CozyEmptyState(symbol: "waveform",
                               title: query.isEmpty ? "No meetings yet" : "Nothing matches",
                               message: query.isEmpty ? "Press Record and Scribe writes the transcript, who said what, and the notes. It all stays on this Mac."
                                                      : "Try another word from the meeting.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(shownMeetings) { m in
                            Button { open(m.id) } label: { ListRow(meeting: m, selected: false) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Delete", role: .destructive) { store.deleteMeeting(m.id) }
                                }
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .scrollIndicators(.never)
            }
        }
        .padding(.top, 16)
        .padding(.bottom, 8)
        .background(NightCardBackground())
    }

    private var dictationsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel(title: "Recent dictations")
                Spacer()
                Button("See all", action: seeAllDictations)
                    .buttonStyle(.plain)
                    .font(.scribe(12, 700))
                    .foregroundStyle(Night.accent)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 4)
            if store.dictations.isEmpty {
                Text("Hold \(DictationSettings.holdKey.title) in any app and talk. A copy of each dictation waits here.")
                    .font(.nightSecondary).foregroundStyle(Night.text2)
                    .padding(18)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(store.dictations.prefix(12).enumerated()), id: \.element.id) { i, d in
                            if i > 0 { NightDivider() }
                            VStack(alignment: .leading, spacing: 6) {
                                Text(d.text).font(.nightBody).foregroundStyle(Night.text).lineSpacing(3)
                                    .lineLimit(3)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("\(d.text.split(separator: " ").count) words  ·  \(d.date.formatted(date: .omitted, time: .shortened))")
                                    .font(.nightMeta).foregroundStyle(Night.text3)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 14)
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .padding(.top, 16)
        .padding(.bottom, 4)
        .background(NightCardBackground())
    }
}

extension HoldKey {
    /// What the keycap shows.
    var keycap: String {
        switch self {
        case .rightOption: return "⌥"
        case .rightCommand: return "⌘"
        case .rightControl: return "⌃"
        case .fn: return "fn"
        case .off: return "–"
        }
    }
}

// MARK: - Meetings page (list + detail)

struct MeetingsPage: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var model: AppModel
    @Binding var selected: UUID?
    @Binding var query: String
    var searchFocus: Int

    private var hits: [UUID: String] {
        Dictionary(store.search(query).map { ($0.id, $0.snippet) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        HStack(spacing: 0) {
            listColumn
                .frame(width: 260)
            NightDivider(vertical: true)
            Group {
                if let id = selected, store.meetings.contains(where: { $0.id == id }) {
                    MeetingDetailView(meetingID: id).id(id)
                } else {
                    placeholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if selected == nil { selected = store.meetings.first?.id } }
    }

    private var listColumn: some View {
        let found = hits
        let shown = store.meetings.filter { query.isEmpty || found[$0.id] != nil }
        return VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Meetings", subtitle: "\(store.meetings.count)")
                .padding(.leading, Night.gutterLeading - 8)
                .padding(.trailing, 16)
            NightSearchField(text: $query, prompt: "Search meetings", width: 288, focusRequest: searchFocus)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            if !store.engineReady { ModelBanner().padding(.horizontal, 16).padding(.bottom, 10) }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(shown) { m in
                        Button { selected = m.id } label: {
                            ListRow(meeting: m, selected: selected == m.id, snippet: found[m.id], compact: true)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                if selected == m.id { selected = nil }
                                store.deleteMeeting(m.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.never)
        }
    }

    @ViewBuilder private var placeholder: some View {
        if store.meetings.isEmpty {
            CozyEmptyState(symbol: "waveform",
                           title: "Nothing here yet",
                           message: "Press Record and Scribe writes the transcript, who said what, and the notes. Hold \(DictationSettings.holdKey.title) in any app to dictate. It all stays on this Mac.") {
                Button { model.toggleMeetingRecording() } label: {
                    Label("Record a meeting", systemImage: "mic")
                }
                .buttonStyle(.nightPrimary)
            }
        } else {
            CozyEmptyState(symbol: "doc.text",
                           title: "Pick a meeting",
                           message: "Choose one from the list, or press ⌘R to start a new one.")
        }
    }
}

// MARK: - List row

/// 40 pt wave tile, title + meta, overlapping speaker avatars, chevron. Selected: accentSoft
/// fill, 14 radius, inset 6 pt (the caller insets).
struct ListRow: View {
    @EnvironmentObject var store: Store
    let meeting: Meeting
    var selected: Bool
    var snippet: String? = nil
    var compact = false
    @State private var hover = false

    var body: some View {
        HStack(spacing: 14) {
            WaveTile(seed: CapsuleBars.seed(meeting.id.uuidString))
            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title.isEmpty ? "Untitled meeting" : meeting.title)
                    .font(.nightHeadline).foregroundStyle(Night.text).lineLimit(1)
                HStack(spacing: 5) {
                    Text(meta)
                    statusMark
                }
                .font(.nightMeta).foregroundStyle(Night.text3).lineLimit(1)
                if let snippet {
                    Text(snippet).font(.scribe(12, 500)).foregroundStyle(Night.text2).lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            if !compact {
                AvatarStack(people: speakers, size: 20, limit: 4)
            }
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Night.text3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: Night.rPill, style: .continuous)
            .fill(selected ? Night.accentSoft : (hover ? Night.accentSoft.opacity(0.45) : Color.clear)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }

    private var meta: String {
        let day: String
        if Calendar.current.isDateInToday(meeting.date) { day = "Today" }
        else if Calendar.current.isDateInYesterday(meeting.date) { day = "Yesterday" }
        else { day = meeting.date.formatted(.dateTime.weekday(.abbreviated)) }
        return "\(day) · \(meeting.date.formatted(date: .omitted, time: .shortened)) · \(Night.clock(meeting.duration))"
    }

    @ViewBuilder private var statusMark: some View {
        switch meeting.status {
        case .processing: Text("· writing…").foregroundStyle(Night.accent)
        case .failed: Text("· needs a retry").foregroundStyle(Night.warn)
        case .recorded: Text("· waiting")
        case .done: EmptyView()
        }
    }

    private var speakers: [(name: String, color: Color)] {
        meeting.clusters.enumerated().map { i, c in
            let p = store.person(c.personID)
            return (p?.name ?? store.displayName(meeting, key: c.key), p.map { Palette.color($0.colorIndex) } ?? Palette.color(i))
        }
    }
}

// MARK: - Model banner

/// Shown until the speech models are downloaded and loaded: a flat card with capsule progress.
struct ModelBanner: View {
    @EnvironmentObject var store: Store
    var body: some View {
        HStack(spacing: 14) {
            if store.engineError == nil {
                SparkleView(size: 12, glow: true)
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Night.warn)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(store.engineError ?? store.engineStatus).font(.scribe(13, 600)).foregroundStyle(Night.text2)
                    .monospacedDigit().lineLimit(1)
                if store.engineError == nil {
                    CapsuleProgress(fraction: store.modelProgress, count: 30, dot: 6, spacing: 3)
                }
            }
            Spacer(minLength: 0)
            if store.engineError != nil {
                Button("Retry") { Task { await store.prepareEngine() } }
                    .buttonStyle(NightButtonStyle(kind: .secondary, height: 30))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(NightCardBackground(radius: Night.rPill))
    }
}
