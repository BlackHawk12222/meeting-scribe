// ContentView.swift
// The main window (0.7.3 "Poster"): a thin 46 pt icon rail on the left (Home, Meetings, Dictation,
// People; Settings pinned to the bottom), a 52 pt top bar (page title, search, the black Record
// pill), then the page. Flat white / near-black, hairlines, no starfield. The traffic lights float
// over the rail (WindowChrome in ScribeApp.swift).

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
        case .dictations: return "Dictation"
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
        case .settings: return "gearshape"
        }
    }
    var hasSearch: Bool { self != .settings }
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
        HStack(spacing: 0) {
            NavRail(section: $section, live: isLive)
            VStack(spacing: 0) {
                TopBar(title: section.title,
                       query: section.hasSearch ? $query : nil,
                       searchFocus: searchFocus,
                       recording: isLive,
                       elapsed: livePreview?.elapsed ?? recorder.elapsed) { model.toggleMeetingRecording() }
                NightDivider()
                page
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Night.canvas)
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
            if on { withAnimation(Night.base) { section = .meetings } }
        }
        .onChange(of: section) { _, _ in query = "" }
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
            HomeView(query: query,
                     open: { id in selectedMeeting = id; section = .meetings },
                     seeAllDictations: { section = .dictations })
        case .meetings:
            if isLive {
                LiveMeetingView(preview: livePreview)
            } else {
                MeetingsPage(selected: $selectedMeeting, query: $query)
            }
        case .dictations:
            DictationPage(query: query)
        case .people:
            PeopleView(query: $query, openMeeting: { id in selectedMeeting = id; section = .meetings })
        case .settings:
            SettingsPage(initial: settingsPane ?? .general, inWindow: true)
        }
    }
}

// MARK: - Top bar

/// 52 pt: page title (15 semibold), search (210 wide, ⌘K), the Record pill.
struct TopBar: View {
    var title: String
    var query: Binding<String>?
    var searchFocus: Int
    var recording: Bool
    var elapsed: TimeInterval
    var record: () -> Void

    var body: some View {
        HStack(spacing: Night.s8) {
            Text(title).font(.nightDisplay).foregroundStyle(Night.text).lineLimit(1)
            Spacer(minLength: Night.s12)
            if let query {
                NightSearchField(text: query, prompt: "Search", width: 210, focusRequest: searchFocus)
            }
            RecordPill(recording: recording, elapsed: elapsed, action: record)
        }
        .padding(.leading, 34)
        .padding(.trailing, 16)
        .frame(height: Night.headerHeight)
    }
}

/// The black pill with a red dot (white pill in dark mode). While a meeting records it reads
/// "Stop · 12:34".
struct RecordPill: View {
    var recording: Bool
    var elapsed: TimeInterval
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Circle().fill(Night.live).frame(width: 7, height: 7)
                Text(recording ? "Stop · \(Night.clock(elapsed))" : "Record")
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Night.onPrimary)
            }
            .padding(.horizontal, 12)
            .frame(height: Night.controlHeight)
            .background(RoundedRectangle(cornerRadius: Night.rControl, style: .continuous).fill(Night.primary))
            .opacity(hover ? 0.88 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressDimStyle())
        .onHover { hover = $0 }
        .help(recording ? "Stop the meeting and write the notes (⌘R)" : "Record a meeting (⌘R)")
        .accessibilityLabel(recording ? "Stop recording" : "Record a meeting")
    }
}

// MARK: - Nav rail

/// 46 pt rail on the sidebar color: 30 pt icon buttons (radius 6), the selected one on the
/// hairline color. Settings at the bottom. A red dot on Meetings while recording.
struct NavRail: View {
    @Binding var section: NavSection
    var live = false
    @State private var hoverItem: NavSection?

    var body: some View {
        VStack(spacing: 2) {
            ForEach([NavSection.home, .meetings, .dictations, .people], id: \.self) { s in
                item(s)
            }
            Spacer(minLength: 12)
            item(.settings)
        }
        .padding(.top, 52)
        .padding(.bottom, 12)
        .frame(width: Night.railWidth)
        .frame(maxHeight: .infinity)
        .background(Night.rail)
        .overlay(alignment: .trailing) { NightDivider(vertical: true) }
    }

    private func item(_ s: NavSection) -> some View {
        let on = section == s
        return Button { section = s } label: {
            Image(systemName: s.symbol)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(on ? Night.text : (hoverItem == s ? Night.text2 : Night.text3))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: Night.rControl, style: .continuous)
                    .fill(on ? Night.selected : (hoverItem == s ? Night.hover : Color.clear)))
                .overlay(alignment: .topTrailing) {
                    if s == .meetings && live {
                        Circle().fill(Night.live).frame(width: 6, height: 6).padding(4)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in hoverItem = h ? s : (hoverItem == s ? nil : hoverItem) }
        .help(s.title)
        .accessibilityLabel(s.title)
        .accessibilityAddTraits(on ? .isSelected : [])
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
    /// Short name for sentences ("Hold right ⌥ to talk").
    var shortName: String {
        switch self {
        case .rightOption: return "right ⌥"
        case .rightCommand: return "right ⌘"
        case .rightControl: return "right ⌃"
        case .fn: return "fn"
        case .off: return "the shortcut"
        }
    }
}

// MARK: - Meetings page (list + detail)

struct MeetingsPage: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var model: AppModel
    @Binding var selected: UUID?
    @Binding var query: String
    @State private var renaming: UUID?
    @State private var renameText = ""

    private var hits: [UUID: String] {
        Dictionary(store.search(query).map { ($0.id, $0.snippet) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        HStack(spacing: 0) {
            listColumn
                .frame(width: Night.meetingsListWidth)
                .frame(maxHeight: .infinity)
                .background(Night.rail)
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

    private struct Group2: Identifiable { var title: String; var items: [Meeting]; var id: String { title } }

    private func groups(_ list: [Meeting]) -> [Group2] {
        let cal = Calendar.current
        let weekStart = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? .distantPast
        var out: [Group2] = []
        for m in list {
            let t = m.date >= weekStart ? "This week" : "Earlier"
            if let i = out.firstIndex(where: { $0.title == t }) { out[i].items.append(m) } else { out.append(Group2(title: t, items: [m])) }
        }
        return out
    }

    private var listColumn: some View {
        let found = hits
        let shown = store.meetings.filter { query.isEmpty || found[$0.id] != nil }
        return VStack(alignment: .leading, spacing: 0) {
            if !store.engineReady { ModelBanner().padding(.horizontal, Night.s12).padding(.top, Night.s12) }
            if shown.isEmpty {
                Text(query.isEmpty ? "No meetings yet" : "Nothing matches “\(query)”")
                    .font(.nightSecondary).foregroundStyle(Night.text3)
                    .padding(.horizontal, 20).padding(.top, 20)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(groups(shown)) { g in
                            Text(g.title).font(.nightLabel).foregroundStyle(Night.text3)
                                .padding(.horizontal, 20)
                                .padding(.top, 16)
                                .padding(.bottom, 6)
                            ForEach(g.items) { m in
                                Button { selected = m.id } label: {
                                    MeetingListRow(meeting: m, selected: selected == m.id, snippet: found[m.id])
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
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, Night.s12)
                }
                .scrollIndicators(.never)
            }
        }
    }

    @ViewBuilder private var placeholder: some View {
        if store.meetings.isEmpty {
            CozyEmptyState(symbol: "waveform",
                           title: "No meetings yet",
                           message: "Press Record and Scribe writes the transcript, who said what, and the notes. It all stays on this Mac.") {
                Button { model.toggleMeetingRecording() } label: { Text("Record a meeting") }
                    .buttonStyle(.nightPrimary)
            }
        } else {
            CozyEmptyState(symbol: "doc.text",
                           title: "Pick a meeting",
                           message: "Choose one from the list, or press ⌘R to start a new one.")
        }
    }
}

/// A meeting in the list: title, then "Today, 4:10 PM" and "42 min · 4 people".
struct MeetingListRow: View {
    @EnvironmentObject var store: Store
    let meeting: Meeting
    var selected: Bool
    var snippet: String? = nil
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(meeting.title.isEmpty ? "Untitled meeting" : meeting.title)
                .font(.nightHeadline).foregroundStyle(Night.text).lineLimit(1)
            HStack(spacing: 8) {
                Text(MeetingFormat.day(meeting.date)).foregroundStyle(Night.text2)
                Spacer(minLength: 6)
                Text(trailing).foregroundStyle(meeting.status == .failed ? Night.warn : Night.text3)
            }
            .font(.nightSecondary).lineLimit(1)
            if let snippet {
                Text(snippet).font(.nightSecondary).foregroundStyle(Night.text2).lineLimit(2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(NightRowBackground(selected: selected, hover: hover))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }

    private var trailing: String {
        switch meeting.status {
        case .processing: return "writing…"
        case .failed: return "needs a retry"
        case .recorded: return "waiting"
        case .done:
            let n = MeetingFormat.peopleCount(meeting)
            return "\(MeetingFormat.minutes(meeting.duration)) · \(n) \(n == 1 ? "person" : "people")"
        }
    }
}

/// Shared wording for meetings.
enum MeetingFormat {
    /// "Today, 4:10 PM" / "Yesterday, 7:00 PM" / "Mon, 3:30 PM" (this week) / "Nov 3, 3:30 PM".
    static func day(_ d: Date) -> String {
        let cal = Calendar.current
        let time = d.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(d) { return "Today, \(time)" }
        if cal.isDateInYesterday(d) { return "Yesterday, \(time)" }
        let weekStart = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? .distantPast
        if d >= weekStart { return "\(d.formatted(.dateTime.weekday(.abbreviated))), \(time)" }
        return "\(d.formatted(.dateTime.month(.abbreviated).day())), \(time)"
    }

    /// "42 min", "45 s", "1 h 05 min".
    static func minutes(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        if s < 60 { return "\(s) s" }
        let m = (s + 30) / 60
        if m < 60 { return "\(m) min" }
        return String(format: "%d h %02d min", m / 60, m % 60)
    }

    /// Distinct people: one per named person, one per unnamed speaker.
    static func peopleCount(_ m: Meeting) -> Int {
        var seen = Set<UUID>()
        var n = 0
        for c in m.clusters {
            if let p = c.personID { if seen.insert(p).inserted { n += 1 } } else { n += 1 }
        }
        return n
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

// MARK: - Model banner

/// Shown until the speech models are downloaded and loaded: a hairline card with progress.
struct ModelBanner: View {
    @EnvironmentObject var store: Store
    var body: some View {
        HStack(spacing: 12) {
            if store.engineError == nil {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Night.warn)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(store.engineError ?? store.engineStatus).font(.nightSmallStrong).foregroundStyle(Night.text2)
                    .monospacedDigit().lineLimit(2)
                if store.engineError == nil, let p = store.modelProgress {
                    ProgressView(value: min(1, max(0, p))).progressViewStyle(.linear).tint(Night.accent)
                }
            }
            Spacer(minLength: 0)
            if store.engineError != nil {
                Button("Retry") { Task { await store.prepareEngine() } }
                    .buttonStyle(NightButtonStyle(kind: .secondary))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(NightCardBackground(radius: Night.rCard))
    }
}
