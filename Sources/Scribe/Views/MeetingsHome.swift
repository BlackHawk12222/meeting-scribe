// MeetingsHome.swift
// 0.7.3.2 Meetings tab: one page instead of the old list + detail split.
//  • Dashboard on top (Poster tiles, real data from the store): meetings this week, hours recorded
//    this week, open action items, top speakers this week (who talked most), and a
//    "Speakers need a name" notice when a finished meeting has voices nobody named.
//  • Below it, every meeting as a row: title, date and time, duration, speaker chips. Search (the
//    top bar) filters the rows and shows the matching line.
//  • A row opens the meeting (MeetingDetailView, unchanged apart from a Back button). Back to the
//    dashboard: the Back button, ⌘[ or Esc, or pulling down past the top of the meeting
//    (overscroll) — it returns as soon as the pull passes `MeetingsNav.pullToReturn`.

import SwiftUI
import AppKit

// MARK: - Dashboard numbers

struct MeetingsDashboard: Equatable {
    struct Speaker: Equatable {
        var name: String
        var seconds: Double
        var colorIndex: Int
    }
    var meetingsThisWeek = 0
    var secondsThisWeek = 0.0
    var openActionItems = 0
    var topSpeakers: [Speaker] = []
    /// Unnamed voices in finished meetings (not dismissed with "Not now").
    var unnamedSpeakers = 0
    /// The newest meeting with an unnamed voice ("Name them" opens it).
    var firstUnnamedMeeting: UUID?

    var hoursText: String {
        let h = secondsThisWeek / 3600
        if h == 0 { return "0" }
        if h < 10 { return String(format: "%.1f", h) }
        return "\(Int(h.rounded()))"
    }

    /// Week = the calendar's week containing `now` (same rule as the old list's "This week").
    static func make(meetings: [Meeting], people: [Person], now: Date = Date(), calendar: Calendar = .current,
                     dismissed: Set<String> = [], top: Int = 3) -> MeetingsDashboard {
        var d = MeetingsDashboard()
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? .distantPast
        var talk: [UUID: Double] = [:]
        for m in meetings {
            d.openActionItems += m.notes?.actionItems.filter { !$0.done }.count ?? 0
            if m.status == .done {
                for c in m.clusters where c.personID == nil && !dismissed.contains(m.id.uuidString + "/" + c.key) {
                    d.unnamedSpeakers += 1
                    if d.firstUnnamedMeeting == nil || (meetings.first { $0.id == d.firstUnnamedMeeting }?.date ?? .distantPast) < m.date {
                        d.firstUnnamedMeeting = m.id
                    }
                }
            }
            guard m.date >= weekStart, m.date <= now.addingTimeInterval(60) else { continue }
            d.meetingsThisWeek += 1
            d.secondsThisWeek += m.duration
            for c in m.clusters { if let p = c.personID { talk[p, default: 0] += c.talkSeconds } }
        }
        let speakers: [Speaker] = talk.compactMap { pair -> Speaker? in
            guard let p = people.first(where: { $0.id == pair.key }), pair.value > 0 else { return nil }
            return Speaker(name: p.name, seconds: pair.value, colorIndex: p.colorIndex)
        }
        d.topSpeakers = speakers
            .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.name < $1.name }
            .prefix(top).map { $0 }
        return d
    }
}

extension Store {
    func meetingsDashboard(now: Date = Date()) -> MeetingsDashboard {
        let dismissed = Set(UserDefaults.standard.stringArray(forKey: Store.dismissedVoicesKey) ?? [])
        return MeetingsDashboard.make(meetings: meetings, people: people, now: now, dismissed: dismissed)
    }
}

// MARK: - Navigation rules (shared by the views and the self-test)

enum MeetingsNav {
    /// Pull this far past the top of a meeting to go back to the dashboard.
    static let pullToReturn: CGFloat = 56

    static func shouldReturn(pull: CGFloat) -> Bool { pull >= pullToReturn }

    /// ⌘[ always; Esc only when no text is being edited (Esc then belongs to the text field).
    static func isBackKey(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags,
                          firstResponder: NSResponder?) -> Bool {
        let mods = modifiers.intersection([.command, .option, .control, .shift])
        if mods == [.command], characters == "[" { return true }
        if keyCode == 53, mods.isEmpty {
            if firstResponder is NSText || firstResponder is NSTextView { return false }
            return true
        }
        return false
    }
}

// MARK: - Page

struct MeetingsPage: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var model: AppModel
    @Binding var selected: UUID?
    @Binding var query: String
    @State private var renaming: UUID?
    @State private var renameText = ""

    var body: some View {
        Group {
            if let id = selected, store.meetings.contains(where: { $0.id == id }) {
                MeetingDetailView(meetingID: id, onBack: back).id(id)
                    .transition(.opacity)
            } else {
                dashboardPage.transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: query) { _, q in if !q.isEmpty { selected = nil } }
        .renameMeetingAlert(id: $renaming, text: $renameText)
    }

    private func open(_ id: UUID) { selected = id }
    private func back() { selected = nil }

    private var hits: [UUID: String] {
        Dictionary(store.search(query).map { ($0.id, $0.snippet) }, uniquingKeysWith: { a, _ in a })
    }

    private var dashboardPage: some View {
        let found = hits
        let shown = store.meetings.filter { query.isEmpty || found[$0.id] != nil }.sorted { $0.date > $1.date }
        let dash = store.meetingsDashboard()
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !store.engineReady { ModelBanner().padding(.bottom, 16) }
                if store.meetings.isEmpty {
                    CozyEmptyState(symbol: "waveform", title: "No meetings yet",
                                   message: "Press Record and Scribe writes the transcript, who said what, and the notes. It all stays on this Mac.") {
                        Button { model.toggleMeetingRecording() } label: { Text("Record a meeting") }
                            .buttonStyle(.nightPrimary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                } else {
                    if query.isEmpty {
                        MeetingsDashboardTiles(dash: dash)
                        if dash.unnamedSpeakers > 0, let m = dash.firstUnnamedMeeting {
                            UnnamedSpeakersNotice(count: dash.unnamedSpeakers) { open(m) }.padding(.top, 12)
                        }
                    }
                    HairlineHeader(title: query.isEmpty ? "All meetings" : "Results for “\(query)”") {
                        Text("\(shown.count)").font(.nightMeta).foregroundStyle(Night.text3).monospacedDigit()
                    }
                    .padding(.top, query.isEmpty ? 30 : 0)
                    .padding(.bottom, 4)
                    if shown.isEmpty {
                        Text("Nothing matches “\(query)”").font(.nightSecondary).foregroundStyle(Night.text3).padding(.top, 14)
                    }
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(shown) { m in
                            Button { open(m.id) } label: { MeetingRowCard(meeting: m, snippet: found[m.id]) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Rename…") { renameText = m.title; renaming = m.id }
                                    Button("Delete", role: .destructive) { store.deleteMeeting(m.id) }
                                }
                                .accessibilityHint("Opens the meeting")
                        }
                    }
                }
            }
            .frame(maxWidth: 1040, alignment: .leading)
            .padding(.horizontal, Night.gutterLeading)
            .padding(.top, 24)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
    }
}

// MARK: - Tiles

struct MeetingsDashboardTiles: View {
    var dash: MeetingsDashboard

    var body: some View {
        let h = Night.tileHeightCompact
        HStack(spacing: Night.cardGap) {
            PosterTile(color: Night.posterIndigo, label: "Meetings", value: "\(dash.meetingsThisWeek)",
                       caption: "this week", height: h, valueSize: 46) { EmptyView() }
            PosterTile(color: Night.posterCoral, label: "Recorded", value: dash.hoursText, unit: "h",
                       caption: "this week", height: h, valueSize: 46) { EmptyView() }
            PosterTile(color: Night.posterGreen, label: "Action items", value: "\(dash.openActionItems)",
                       caption: dash.openActionItems == 1 ? "open item" : "open items", height: h, valueSize: 46) { EmptyView() }
            TopSpeakersTile(speakers: dash.topSpeakers, height: h)
        }
    }
}

/// The black tile: who talked most this week, with a bar per person.
struct TopSpeakersTile: View {
    var speakers: [MeetingsDashboard.Speaker]
    var height: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Night.rTile, style: .continuous)
        let most = speakers.first?.seconds ?? 1
        VStack(alignment: .leading, spacing: 0) {
            Text("Top speakers").font(.system(size: 14, weight: .regular)).opacity(0.88)
            Spacer(minLength: 6)
            if speakers.isEmpty {
                Text("No named voices this week").font(.system(size: 13)).opacity(0.7)
                Spacer(minLength: 0)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(speakers.enumerated()), id: \.offset) { _, s in
                        HStack(spacing: 8) {
                            Text(s.name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                                .frame(width: 78, alignment: .leading)
                            GeometryReader { g in
                                Capsule().fill(Palette.color(s.colorIndex))
                                    .frame(width: max(6, g.size.width * CGFloat(s.seconds / most)), height: 6)
                                    .frame(maxHeight: .infinity, alignment: .center)
                            }
                            .frame(height: 10)
                            Text(MeetingFormat.minutes(s.seconds)).font(.system(size: 12.5)).monospacedDigit().opacity(0.8)
                                .lineLimit(1).fixedSize()
                        }
                    }
                }
            }
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height)
        .background(shape.fill(Night.posterBlack))
        .overlay { shape.strokeBorder(Night.posterBlackEdge, lineWidth: 1) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Top speakers this week: " + (speakers.isEmpty ? "none" :
            speakers.map { "\($0.name), \(MeetingFormat.minutes($0.seconds))" }.joined(separator: "; ")))
    }
}

/// "2 speakers need a name" + Name them.
struct UnnamedSpeakersNotice: View {
    var count: Int
    var action: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.questionmark").font(.system(size: 16)).foregroundStyle(Night.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(count == 1 ? "1 speaker needs a name" : "\(count) speakers need a name")
                    .font(.nightHeadline).foregroundStyle(Night.text)
                Text("Name a voice once and Scribe knows it in every meeting after.")
                    .font(.nightSecondary).foregroundStyle(Night.text2)
            }
            Spacer(minLength: 10)
            Button("Name them", action: action).buttonStyle(NightButtonStyle(kind: .secondary, height: 30))
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(NightCardBackground())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Row

/// A meeting row: title, "Today, 4:10 PM", duration, speaker chips (and the search hit's line).
struct MeetingRowCard: View {
    @EnvironmentObject var store: Store
    let meeting: Meeting
    var snippet: String? = nil
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(meeting.title.isEmpty ? "Untitled meeting" : meeting.title)
                        .font(.nightHeadline).foregroundStyle(Night.text).lineLimit(1)
                    HStack(spacing: 8) {
                        Text(MeetingFormat.day(meeting.date))
                        Text("·").foregroundStyle(Night.text3)
                        Text(status).foregroundStyle(meeting.status == .failed ? Night.warn : Night.text2)
                    }
                    .font(.nightSecondary).foregroundStyle(Night.text2).lineLimit(1)
                    if let snippet {
                        Text(snippet).font(.nightSecondary).foregroundStyle(Night.text2).lineLimit(2).padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                chips
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Night.text3)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: Night.rRow, style: .continuous).fill(hover ? Night.hover : .clear))
            NightDivider()
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .accessibilityElement(children: .combine)
    }

    private var status: String {
        switch meeting.status {
        case .processing: return "writing…"
        case .failed: return "needs a retry"
        case .recorded: return "waiting"
        case .done: return MeetingFormat.minutes(meeting.duration)
        }
    }

    /// Up to 4 speakers, most talk first; "+2" for the rest.
    private var chips: some View {
        let list = meeting.clusters.sorted { $0.talkSeconds > $1.talkSeconds }
        let shown = Array(list.prefix(4))
        return HStack(spacing: 6) {
            ForEach(shown, id: \.key) { c in
                let p = store.person(c.personID)
                HStack(spacing: 5) {
                    Circle().fill(p.map { Palette.color($0.colorIndex) } ?? Night.unnamed).frame(width: 7, height: 7)
                    Text(store.displayName(meeting, key: c.key)).lineLimit(1)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(p == nil ? Night.text3 : Night.text2)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: Night.rControl, style: .continuous).strokeBorder(Night.line2, lineWidth: 1))
            }
            if list.count > shown.count {
                Text("+\(list.count - shown.count)").font(.system(size: 12, weight: .medium)).foregroundStyle(Night.text3)
            }
        }
        .fixedSize()
    }
}

// MARK: - Back from a meeting (overscroll + keys)

/// Put in the meeting's scrolling content: watches the enclosing NSScrollView for a pull past the
/// top, and ⌘[ / Esc in its window, and calls `onBack`.
struct MeetingBackProbe: NSViewRepresentable {
    var onBack: () -> Void
    func makeNSView(context: Context) -> MeetingBackProbeView {
        let v = MeetingBackProbeView()
        v.onBack = onBack
        return v
    }
    func updateNSView(_ v: MeetingBackProbeView, context: Context) { v.onBack = onBack }
    static func dismantleNSView(_ v: MeetingBackProbeView, coordinator: Coordinator) { v.detach() }
}

final class MeetingBackProbeView: NSView {
    var onBack: (() -> Void)?
    private(set) weak var scrollView: NSScrollView?
    private var boundsObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    private var fired = false
    /// The raw pull at rest (measured when the meeting opens, at its top), so an inset quirk can
    /// never count as a pull.
    private var rest: CGFloat = 0
    /// Only a real scroll gesture counts as a pull (not a layout change). The self-test turns it off.
    static var requireScrollEvent = true
    /// Self-test: probes currently in a window (a meeting is open).
    @MainActor static var attached: [MeetingBackProbeView] { live.allObjects }
    private static let live = NSHashTable<MeetingBackProbeView>.weakObjects()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { detach(); return }
        Self.live.add(self)
        attachScrollObserver()
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self else { return e }
                return self.handleKey(e) ? nil : e
            }
        }
    }

    /// The SwiftUI ScrollView's NSScrollView (it can appear a moment after we're in the window).
    func attachScrollObserver() {
        guard boundsObserver == nil, let sv = enclosingScrollView else {
            if boundsObserver == nil, window != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.attachScrollObserver() }
            }
            return
        }
        scrollView = sv
        rest = max(0, rawPull)
        sv.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                                object: sv.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrolled() }
        }
    }

    /// How far the content is pulled down past its top (0 when not overscrolled).
    var pull: CGFloat { max(0, rawPull - rest) }

    private var rawPull: CGFloat {
        guard let sv = scrollView, let doc = sv.documentView else { return 0 }
        let clip = sv.contentView
        if clip.isFlipped { return -(clip.bounds.minY + sv.contentInsets.top) }
        return clip.bounds.maxY - doc.frame.maxY - sv.contentInsets.top
    }

    func scrolled() {
        if Self.requireScrollEvent {
            // Only while the user scrolls; a momentum bounce after a fast flick isn't a pull.
            guard let e = NSApp.currentEvent, e.type == .scrollWheel, e.momentumPhase == [] else { return }
        }
        if MeetingsNav.shouldReturn(pull: pull) { goBack() }
    }

    /// true = the key was used (⌘[ / Esc → back).
    func handleKey(_ e: NSEvent) -> Bool {
        guard let w = window, e.window === w, w.attachedSheet == nil else { return false }
        guard MeetingsNav.isBackKey(keyCode: e.keyCode, characters: e.charactersIgnoringModifiers,
                                    modifiers: e.modifierFlags, firstResponder: w.firstResponder) else { return false }
        goBack()
        return true
    }

    func goBack() {
        guard !fired else { return }
        fired = true
        onBack?()
    }

    func detach() {
        if let o = boundsObserver { NotificationCenter.default.removeObserver(o); boundsObserver = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        Self.live.remove(self)
    }
}
