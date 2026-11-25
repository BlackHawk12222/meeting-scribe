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
    @State private var hoverItem: NavSection?

    var body: some View {
        VStack(spacing: Night.s4) {
            AppIconView(size: 26)
                .padding(.bottom, Night.s12)
            ForEach([NavSection.home, .meetings, .dictations, .people], id: \.self) { s in
                item(s)
            }
            Spacer(minLength: 12)
            item(.settings)
            Text(String(NSFullUserName().prefix(1)).uppercased().isEmpty ? "S" : String(NSFullUserName().prefix(1)).uppercased())
                .font(.nightMeta)
                .foregroundStyle(Night.text2)
                .frame(width: Night.avatar, height: Night.avatar)
                .background(Circle().fill(Night.raised))
                .overlay(Circle().strokeBorder(Night.line2, lineWidth: 1))
                .padding(.top, 8)
                .accessibilityHidden(true)
        }
        .padding(.top, 52)
        .padding(.bottom, Night.s16)
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
                    .font(.nightIcon(Night.iconLarge))
                    .foregroundStyle(on ? Night.accent : (hoverItem == s ? Night.text2 : Night.text3))
                    .frame(width: 32, height: 32)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: Night.rRow, style: .continuous).fill(Night.accentSoft)
                                .matchedGeometryEffect(id: "pill", in: ns)
                        } else if hoverItem == s {
                            RoundedRectangle(cornerRadius: Night.rRow, style: .continuous).fill(Night.hover)
                        }
                    }
                if on {
                    Sparkle().fill(Night.star)
                        .frame(width: 5, height: 5)
                        .padding(4)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                if s == .meetings && live {
                    Circle().fill(Night.live).frame(width: 6, height: 6).padding(4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
            .frame(width: 32, height: 32)
            .overlay(alignment: .leading) {
                if on {
                    Capsule().fill(Night.gradient)
                        .frame(width: 3, height: 16)
                        .offset(x: -10)
                        .matchedGeometryEffect(id: "tick", in: ns)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Night.fast) { hoverItem = h ? s : (hoverItem == s ? nil : hoverItem) } }
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
    @State private var renaming: UUID?
    @State private var renameText = ""
    enum HomeTab: Hashable { case recent, week }

    var body: some View {
        homeBody.renameMeetingAlert(id: $renaming, text: $renameText)
    }

    // 0.7.2 Home dashboard: header · three quiet stat tiles · start + dictate cards · meetings
    // grouped by day · recent dictations. Every size/color comes from the Night tokens.
    private var homeBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: greeting, subtitle: Date().formatted(.dateTime.weekday(.wide).month(.abbreviated).day())) {
                NightSearchField(text: $query, prompt: "Search notes & dictations", width: 240, focusRequest: searchFocus)
                Button { model.toggleMeetingRecording() } label: {
                    Label(recorder.isRecording ? "Stop meeting" : "Record meeting",
                          systemImage: recorder.isRecording ? "stop.fill" : "plus")
                }
                .buttonStyle(.nightPrimary)
            }
            if !store.engineReady { ModelBanner().padding(.bottom, Night.s12) }
            GeometryReader { geo in
                let wide = geo.size.width > 720
                let side = max(240, geo.size.width * 0.36)
                VStack(spacing: Night.cardGap) {
                    HStack(spacing: Night.cardGap) {
                        startCard.frame(maxWidth: .infinity)
                        if wide { dictateCard.frame(width: side) }
                    }
                    .frame(height: 84)
                    HStack(spacing: Night.cardGap) {
                        StatTile(value: "\(weekMeetings.count)", label: "meetings this week", symbol: "waveform")
                        StatTile(value: Night.clock(weekMeetings.reduce(0) { $0 + $1.duration }), label: "recorded this week", symbol: "clock")
                        StatTile(value: "\(wordsToday)", label: "words dictated today", symbol: "text.cursor")
                        if wide { StatTile(value: "\(store.people.count)", label: store.people.count == 1 ? "voice known" : "voices known", symbol: "person.2") }
                    }
                    HStack(alignment: .top, spacing: Night.cardGap) {
                        meetingsCard.frame(maxWidth: .infinity, maxHeight: .infinity)
                        if wide { dictationsCard.frame(width: side).frame(maxHeight: .infinity) }
                    }
                }
            }
            .padding(.top, Night.s4)
            .padding(.bottom, Night.s20)
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

    private var weekMeetings: [Meeting] {
        let start = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date.distantPast
        return store.meetings.filter { $0.date >= start }
    }

    // MARK: Cards

    private var startCard: some View {
        HStack(spacing: Night.s16) {
            RecordButton(recording: recorder.isRecording, size: 40) { model.toggleMeetingRecording() }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Night.s8) {
                    Text(recorder.isRecording ? "Recording a meeting" : "Start a meeting").font(.nightHeadline)
                    if recorder.isRecording { LiveChip(text: Night.clock(recorder.elapsed)) }
                }
                Text("Scribe listens, tells voices apart, and writes the notes when you stop.")
                    .font(.nightSecondary).foregroundStyle(Night.text2)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            CapsuleBars(levels: CapsuleBars.wave(9, seed: 3, floor: 0.2), barWidth: 4, spacing: 3, maxLength: 32,
                        style: recorder.isRecording ? .gradient : .dim)
        }
        .padding(.horizontal, Night.s16)
        .frame(maxHeight: .infinity)
        .background(NightCardBackground())
        .animation(Night.base, value: recorder.isRecording)
    }

    private var dictateCard: some View {
        VStack(alignment: .leading, spacing: Night.s8) {
            SectionLabel(title: "Dictate anywhere")
            HStack(spacing: Night.s4 + 2) {
                Text("Hold").font(.nightSecondary).foregroundStyle(Night.text2)
                Keycap(text: DictationSettings.holdKey.keycap)
                Text("in any text box, speak, let go.").font(.nightSecondary).foregroundStyle(Night.text2)
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
        }
        .padding(.horizontal, Night.s16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
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
        case .week: return weekMeetings
        }
    }

    /// Meetings grouped under quiet day headers: Today, Yesterday, This week, Earlier.
    private struct MeetingGroup: Identifiable { var title: String; var items: [Meeting]; var id: String { title } }

    private var groupedMeetings: [MeetingGroup] {
        let cal = Calendar.current
        let weekStart = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? .distantPast
        var groups: [(String, [Meeting])] = []
        for m in shownMeetings {
            let t = cal.isDateInToday(m.date) ? "Today" : cal.isDateInYesterday(m.date) ? "Yesterday"
                : m.date >= weekStart ? "This week" : "Earlier"
            if let i = groups.firstIndex(where: { $0.0 == t }) { groups[i].1.append(m) } else { groups.append((t, [m])) }
        }
        return groups.map { MeetingGroup(title: $0.0, items: $0.1) }
    }

    private var meetingsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                if query.isEmpty {
                    NightTabs(selection: $tab, options: [(value: HomeTab.recent, title: "Meetings"), (value: HomeTab.week, title: "This week")])
                } else {
                    SectionLabel(title: "Matching “\(query)”")
                }
                Spacer()
                Text("\(shownMeetings.count) meeting\(shownMeetings.count == 1 ? "" : "s")").font(.nightMeta).foregroundStyle(Night.text3)
            }
            .padding(.horizontal, Night.s16)
            .padding(.bottom, Night.s8)
            if shownMeetings.isEmpty {
                CozyEmptyState(symbol: "waveform",
                               title: query.isEmpty ? "No meetings yet" : "Nothing matches",
                               message: query.isEmpty ? "Press Record and Scribe writes the transcript, who said what, and the notes. It all stays on this Mac."
                                                      : "Try another word from the meeting.") {
                    if query.isEmpty {
                        Button { model.toggleMeetingRecording() } label: { Label("Record a meeting", systemImage: "mic") }
                            .buttonStyle(.nightSecondary)
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groupedMeetings) { g in
                            Text(g.title).font(.nightMeta).foregroundStyle(Night.text3)
                                .padding(.horizontal, Night.s12)
                                .padding(.top, Night.s8)
                                .padding(.bottom, Night.s4)
                            ForEach(g.items) { m in
                                Button { open(m.id) } label: { ListRow(meeting: m, selected: false) }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button("Rename…") { renameText = m.title; renaming = m.id }
                                        Button("Delete", role: .destructive) { store.deleteMeeting(m.id) }
                                    }
                            }
                        }
                    }
                    .padding(.horizontal, Night.s4)
                    .animation(Night.base, value: shownMeetings.map(\.id))
                }
                .scrollIndicators(.never)
            }
        }
        .padding(.top, Night.s12)
        .padding(.bottom, Night.s4)
        .background(NightCardBackground())
    }

    private var dictationsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel(title: "Recent dictations")
                Spacer()
                Button("See all", action: seeAllDictations)
                    .buttonStyle(.nightGhost)
            }
            .padding(.leading, Night.s16)
            .padding(.trailing, Night.s8)
            .padding(.bottom, Night.s4)
            if store.dictations.isEmpty {
                CozyEmptyState(symbol: "text.cursor", title: "Nothing dictated yet",
                               message: "Hold \(DictationSettings.holdKey.title) in any app and talk. A copy of each dictation waits here.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(store.dictations.prefix(12).enumerated()), id: \.element.id) { i, d in
                            if i > 0 { NightDivider().padding(.horizontal, Night.s12) }
                            DictationMiniRow(entry: d)
                        }
                    }
                    .padding(.horizontal, Night.s4)
                }
                .scrollIndicators(.never)
            }
        }
        .padding(.top, Night.s12)
        .padding(.bottom, Night.s4)
        .background(NightCardBackground())
    }
}

/// A Home stat: a small icon, a number, a quiet caption. Flat card, compact.
struct StatTile: View {
    var value: String
    var label: String
    var symbol: String
    var body: some View {
        HStack(spacing: Night.s12) {
            Image(systemName: symbol).font(.nightIcon(Night.iconRegular, .semibold))
                .foregroundStyle(Night.accent)
                .frame(width: 26, height: 26)
                .background(Night.accentSoft, in: RoundedRectangle(cornerRadius: Night.rControl, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.nightHeadline).monospacedDigit().foregroundStyle(Night.text)
                    .contentTransition(.numericText())
                Text(label).font(.nightMeta).foregroundStyle(Night.text3).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Night.s12)
        .padding(.vertical, Night.s8 + 2)
        .frame(maxWidth: .infinity)
        .background(NightCardBackground(radius: Night.rCard))
        .accessibilityElement(children: .combine)
    }
}

/// One recent dictation on Home: the text (3 lines), words · time, and a copy button on hover.
struct DictationMiniRow: View {
    let entry: DictationEntry
    @State private var hover = false
    @State private var copied = false
    var body: some View {
        HStack(alignment: .top, spacing: Night.s8) {
            VStack(alignment: .leading, spacing: Night.s4) {
                Text(entry.text).font(.nightBody).foregroundStyle(Night.text).lineSpacing(2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(entry.text.split(separator: " ").count) words  ·  \(entry.date.formatted(date: .omitted, time: .shortened))")
                    .font(.nightMeta).foregroundStyle(Night.text3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.text, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                .buttonStyle(NightIconButtonStyle(size: 24))
                .opacity(hover || copied ? 1 : 0)
                .help("Copy")
                .accessibilityLabel("Copy dictation")
        }
        .padding(.horizontal, Night.s12)
        .padding(.vertical, Night.s8 + 2)
        .background(NightRowBackground(selected: false, hover: hover))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(Night.fast, value: hover)
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
    @State private var renaming: UUID?
    @State private var renameText = ""

    private var hits: [UUID: String] {
        Dictionary(store.search(query).map { ($0.id, $0.snippet) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        HStack(spacing: 0) {
            listColumn
                .frame(width: Night.meetingsListWidth)
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
        .renameMeetingAlert(id: $renaming, text: $renameText)
    }

    private var listColumn: some View {
        let found = hits
        let shown = store.meetings.filter { query.isEmpty || found[$0.id] != nil }
        return VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Meetings", subtitle: "\(store.meetings.count)")
                .padding(.leading, Night.gutterLeading)
                .padding(.trailing, Night.s12)
            NightSearchField(text: $query, prompt: "Search meetings", width: Night.meetingsListWidth - 2 * Night.s12, focusRequest: searchFocus)
                .padding(.horizontal, Night.s12)
                .padding(.bottom, Night.s8)
            if !store.engineReady { ModelBanner().padding(.horizontal, Night.s12).padding(.bottom, Night.s8) }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(shown) { m in
                        Button { selected = m.id } label: {
                            ListRow(meeting: m, selected: selected == m.id, snippet: found[m.id], compact: true)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Rename…") { renameText = m.title; renaming = m.id }
                            Button("Delete", role: .destructive) {
                                if selected == m.id { selected = nil }
                                store.deleteMeeting(m.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, Night.s4)
                .padding(.bottom, Night.s12)
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

// MARK: - Rename (meetings list right-click › Rename…)

private struct RenameMeetingAlert: ViewModifier {
    @EnvironmentObject var store: Store
    @Binding var id: UUID?
    @Binding var text: String
    func body(content: Content) -> some View {
        content.alert("Rename meeting", isPresented: Binding(get: { id != nil }, set: { if !$0 { id = nil } })) {
            TextField("Meeting name", text: $text)
            Button("Rename") { if let id { store.renameMeeting(id, to: text) }; id = nil }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { id = nil }
        }
    }
}

extension View {
    /// Shows the Rename meeting box while `id` is set; saves on Rename.
    func renameMeetingAlert(id: Binding<UUID?>, text: Binding<String>) -> some View {
        modifier(RenameMeetingAlert(id: id, text: text))
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
        HStack(spacing: Night.s12) {
            WaveTile(seed: CapsuleBars.seed(meeting.id.uuidString), size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title.isEmpty ? "Untitled meeting" : meeting.title)
                    .font(.nightHeadline).foregroundStyle(Night.text).lineLimit(1)
                HStack(spacing: 5) {
                    Text(meta)
                    statusMark
                }
                .font(.nightMeta).foregroundStyle(Night.text3).lineLimit(1)
                if let snippet {
                    Text(snippet).font(.nightSecondary).foregroundStyle(Night.text2).lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            if !compact {
                AvatarStack(people: speakers, size: Night.avatarSmall, limit: 4)
            }
            Image(systemName: "chevron.right").font(.nightIcon(Night.iconSmall, .semibold)).foregroundStyle(Night.text3)
                .opacity(hover || selected ? 1 : 0.5)
        }
        .padding(.horizontal, Night.s8 + 2)
        .padding(.vertical, Night.rowPaddingV)
        .background(NightRowBackground(selected: selected, hover: hover))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(Night.fast, value: hover)
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
        var seen = Set<UUID>()
        return meeting.clusters.enumerated().filter { _, c in c.personID.map { seen.insert($0).inserted } ?? true }.map { i, c in
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
                Text(store.engineError ?? store.engineStatus).font(.nightHeadline).foregroundStyle(Night.text2)
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
