// DictationPage.swift
// 0.7.3 "Poster" Dictation page (replaces DictationHistoryView): tiles (words today, average
// speed, top app), the history with per-app filter chips, and three cards: Dictionary (your
// words + "heard → written" replacements; the same list as Settings › Vocabulary), Style
// (Natural / Polished / Exact) and Shortcut (the real hold key and toggle shortcut).

import SwiftUI
import AppKit

struct DictationPage: View {
    @EnvironmentObject var store: Store
    var query: String = ""
    @State private var filter: String? = nil      // nil = All, else an app key
    @State private var showAll = false
    @State private var confirmClear = false

    var body: some View {
        let stats = store.dictationStats
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !store.engineReady { ModelBanner().padding(.bottom, Night.s16) }
                tiles(stats)
                HStack(alignment: .top, spacing: 28) {
                    history(stats).frame(maxWidth: .infinity, alignment: .leading)
                    VStack(spacing: Night.cardGap) {
                        DictionaryCard()
                        StyleCard()
                        ShortcutCard()
                    }
                    .frame(width: 380)
                }
                .padding(.top, 24)
            }
            .padding(.horizontal, Night.gutterLeading)
            .padding(.top, 22)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.never)
        .confirmationDialog("Clear the dictation history?", isPresented: $confirmClear) {
            Button("Clear history", role: .destructive) { store.clearDictations() }
        } message: {
            Text("The text of your past dictations is removed from this Mac. Your word counts and streak stay.")
        }
    }

    // MARK: Tiles

    private func tiles(_ stats: DictationStats) -> some View {
        let wpm = stats.wordsPerMinute
        let top = stats.topApp
        return GeometryReader { geo in
            let gap = Night.cardGap
            let unit = (geo.size.width - 2 * gap) / 3.25
            HStack(spacing: gap) {
                PosterTile(color: Night.posterIndigo, label: "Today", value: stats.wordsToday.formatted(),
                           caption: stats.wordsToday == 1 ? "word dictated" : "words dictated",
                           height: Night.tileHeightCompact, valueSize: 56) {
                    MiniBars(values: stats.last7Words, highlight: 6, height: 40, barWidth: 8)
                }
                .frame(width: unit * 1.25)
                PosterTile(color: Night.posterCoral, label: "Average speed", value: wpm.map { "\($0)" } ?? "–",
                           caption: speedCaption(wpm), height: Night.tileHeightCompact, valueSize: 56) {
                    RingGauge(fraction: Double(wpm ?? 0) / 200, size: 44, line: 5)
                }
                .frame(width: unit)
                PosterTile(color: Night.posterBlack, label: "Top app",
                           value: top.map { "\(Int(($0.fraction * 100).rounded()))%" } ?? "–",
                           caption: top.map { "of your words go to \($0.name)" } ?? "dictate into an app to see",
                           height: Night.tileHeightCompact, valueSize: 56, outlined: true) {
                    DaySquares(filled: topSquares(top), size: 11)
                }
                .frame(width: unit)
            }
        }
        .frame(height: Night.tileHeightCompact)
    }

    /// The top app's share as 7 squares (at least one when there is a top app).
    private func topSquares(_ top: AppShare?) -> [Bool] {
        guard let top else { return Array(repeating: false, count: 7) }
        let n = max(1, min(7, Int((top.fraction * 7).rounded())))
        return (0..<7).map { $0 < n }
    }

    /// "words per minute · about 3× typing" (against an average typist at 40 wpm, an assumption
    /// stated in the tooltip, not a measurement of you).
    private func speedCaption(_ wpm: Int?) -> String {
        guard let wpm else { return "words per minute, after a few dictations" }
        let x = Double(wpm) / 40
        return x >= 1.5 ? "words per minute · about \(Int(x.rounded()))× typing" : "words per minute"
    }

    // MARK: History

    private func items(_ stats: DictationStats) -> [DictationEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return store.dictations.filter { d in
            (q.isEmpty || d.text.localizedCaseInsensitiveContains(q)) && (filter == nil || Store.appKey(d) == filter)
        }
    }

    private func history(_ stats: DictationStats) -> some View {
        let list = items(stats)
        let shown = showAll ? list : Array(list.prefix(40))
        let apps = Array(stats.rankedApps.prefix(5))
        let hasOther = store.dictations.contains { Store.appKey($0) == AppKey.other }
        return VStack(alignment: .leading, spacing: 0) {
            HairlineHeader(title: "History") {
                if !store.dictations.isEmpty {
                    Button("Clear…") { confirmClear = true }
                        .buttonStyle(.plain).font(.nightSecondary).foregroundStyle(Night.text3)
                }
            }
            if !store.dictations.isEmpty {
                WrapLayout(spacing: 6, lineSpacing: 6) {
                    PosterChip(selected: filter == nil, action: { filter = nil }) { Text("All") }
                    ForEach(apps, id: \.self) { k in
                        PosterChip(selected: filter == k, action: { filter = k }) {
                            AppDot(color: stats.color(forApp: k))
                            Text(stats.appName(k))
                        }
                    }
                    if hasOther {
                        PosterChip(selected: filter == AppKey.other, action: { filter = AppKey.other }) {
                            AppDot(color: Night.appOther)
                            Text("Other")
                        }
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 4)
            }
            if shown.isEmpty {
                Text(store.dictations.isEmpty
                     ? "Nothing dictated yet. Hold \(DictationSettings.holdKey.shortName) in any text box, talk, and let go. A copy of each dictation waits here."
                     : "No dictations match.")
                    .font(.nightSecondary).foregroundStyle(Night.text3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { d in
                        HistoryRow(entry: d, color: stats.color(forApp: Store.appKey(d)), appName: stats.appName(Store.appKey(d)))
                    }
                }
                if list.count > shown.count {
                    Button("Show all \(list.count)") { showAll = true }
                        .buttonStyle(.nightGhost)
                        .padding(.top, 8)
                }
            }
        }
    }
}

/// One history row: time · app · text · words. Copy on hover.
struct HistoryRow: View {
    @EnvironmentObject var store: Store
    let entry: DictationEntry
    var color: Color
    var appName: String
    @State private var hover = false
    @State private var copied = false
    /// 0.7.3: fix the text (Scribe learns from repeated fixes and names).
    @State private var editing = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(DictationFormat.time(entry.date))
                .font(.nightSecondary).foregroundStyle(Night.text3)
                .frame(width: 72, alignment: .leading).lineLimit(1).minimumScaleFactor(0.8)
            HStack(spacing: 6) {
                AppDot(color: color)
                Text(appName).font(.nightSecondary).foregroundStyle(Night.text2).lineLimit(1)
            }
            .frame(width: 96, alignment: .leading)
            Text(entry.text).font(.nightReading).foregroundStyle(Night.text).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            ZStack(alignment: .trailing) {
                Text("\(entry.wordCount) word\(entry.wordCount == 1 ? "" : "s")")
                    .font(.nightSecondary).foregroundStyle(Night.text3)
                    .opacity(hover || copied ? 0 : 1)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    .buttonStyle(NightButtonStyle(kind: .secondary, height: 24))
                    .opacity(hover || copied ? 1 : 0)
            }
            .frame(width: 80, alignment: .trailing)
            Button { editing = true } label: { Image(systemName: "pencil") }
                .buttonStyle(NightIconButtonStyle(size: 24))
                .opacity(hover ? 1 : 0)
                .help("Fix the text")
                .accessibilityLabel("Edit dictation")
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { NightDivider() }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .help(helpText)
        .contextMenu { Button("Edit text…") { editing = true } }
        .sheet(isPresented: $editing) {
            EditTextSheet(title: "Edit dictation", original: entry.text) { _ = store.editDictation(entry.id, text: $0) }
        }
    }

    private var helpText: String {
        var parts = [String(format: "%.1f s spoken", entry.audioSeconds),
                     String(format: "ready %.2f s after release", entry.latencySeconds)]
        if let s = entry.style { parts.append(s.capitalized) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Cards

/// A Poster card: hairline border, radius 8, a header with an icon and title.
struct PosterCard<Trailing: View, Content: View>: View {
    var symbol: String
    var title: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(Night.text2).frame(width: 18)
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Night.text)
                Spacer(minLength: 8)
                trailing
            }
            content
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NightCardBackground())
    }
}

/// Dictionary: Vocabulary.words + DictionaryReplacements, one list, editable here and in
/// Settings › Vocabulary.
struct DictionaryCard: View {
    @EnvironmentObject var store: Store
    @State private var words: [String] = Vocabulary.words
    @State private var pairs: [DictionaryReplacements.Pair] = DictionaryReplacements.pairs
    @State private var adding = false
    @State private var newText = ""

    var body: some View {
        PosterCard(symbol: "character.book.closed", title: "Dictionary") {
            Text("\(words.count + pairs.count) word\(words.count + pairs.count == 1 ? "" : "s")")
                .font(.nightSecondary).foregroundStyle(Night.text3)
        } content: {
            WrapLayout(spacing: 6, lineSpacing: 6) {
                ForEach(pairs) { p in
                    DictionaryChip(remove: { DictionaryReplacements.remove(p); reload() }) {
                        Text(p.from).foregroundStyle(Night.text3)
                        Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(Night.text3)
                        Text(p.to).foregroundStyle(Night.text)
                    }
                }
                ForEach(words, id: \.self) { w in
                    DictionaryChip(remove: { words.removeAll { $0 == w }; save() }) {
                        Text(w).foregroundStyle(Night.text)
                    }
                }
                Button { newText = ""; adding = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .medium))
                        Text("Add word")
                    }
                    .font(.system(size: 13.5, weight: .regular))
                    .foregroundStyle(Night.text2)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .overlay(RoundedRectangle(cornerRadius: Night.rControl, style: .continuous)
                        .strokeBorder(Night.line2, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $adding, arrowEdge: .bottom) { addPopover }
            }
        }
        .onAppear(perform: reload)
    }

    private var addPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add to your Dictionary").font(.nightHeadline)
            NightField(placeholder: "A name or term, or  heard → written", text: $newText, onSubmit: add)
                .frame(width: 280)
            Text("A word: Scribe spells it your way. “sweet UI → SwiftUI”: Scribe replaces what it heard.")
                .font(.nightSecondary).foregroundStyle(Night.text3)
                .frame(width: 280, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { adding = false }.buttonStyle(.nightGhost)
                Button("Add", action: add).buttonStyle(.nightPrimary)
                    .disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .background(Night.raised)
    }

    private func add() {
        let t = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if let p = DictionaryReplacements.parse(t) {
            DictionaryReplacements.add(p)
        } else if !words.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) {
            words.append(t)
            save()
        }
        newText = ""
        adding = false
        reload()
    }

    private func reload() {
        words = Vocabulary.words
        pairs = DictionaryReplacements.pairs
    }

    private func save() {
        Vocabulary.words = words
        Task { await store.prepareVocabularyBoost() }
    }
}

/// A dictionary chip: hairline, the remove "×" shows on hover.
struct DictionaryChip<Content: View>: View {
    var remove: () -> Void
    @ViewBuilder var content: Content
    @State private var hover = false
    var body: some View {
        HStack(spacing: 6) {
            content
            if hover {
                Button(action: remove) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Night.text3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove")
            }
        }
        .font(.system(size: 13.5, weight: .regular))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: Night.rControl, style: .continuous).fill(Night.well))
        .overlay(RoundedRectangle(cornerRadius: Night.rControl, style: .continuous).strokeBorder(Night.line, lineWidth: 1))
        .onHover { hover = $0 }
        .contextMenu { Button("Remove", role: .destructive, action: remove) }
    }
}

/// Style: Natural / Polished / Exact, with a before → after line.
struct StyleCard: View {
    @AppStorage(DictationStyle.key) private var styleRaw = DictationStyle.natural.rawValue

    var body: some View {
        let current = DictationStyle(rawValue: styleRaw) ?? .natural
        PosterCard(symbol: "text.alignleft", title: "Style") { EmptyView() } content: {
            HStack(alignment: .top, spacing: 8) {
                ForEach(DictationStyle.allCases) { s in
                    let on = s == current
                    Button { styleRaw = s.rawValue } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                ZStack {
                                    Circle().strokeBorder(on ? Night.text : Night.line2, lineWidth: on ? 4.5 : 1.2)
                                }
                                .frame(width: 14, height: 14)
                                Text(s.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Night.text)
                            }
                            Text(s.detail).font(.system(size: 12.5)).foregroundStyle(Night.text2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: Night.rCard, style: .continuous).fill(Night.surface))
                        .overlay(RoundedRectangle(cornerRadius: Night.rCard, style: .continuous)
                            .strokeBorder(on ? Night.text : Night.line, lineWidth: on ? 2 : 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            HStack(spacing: 10) {
                Rectangle().fill(Night.line2).frame(width: 2)
                Text(current.example).font(.nightSecondary).foregroundStyle(Night.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)
            if current == .polished && !AppleIntelligence.isAvailable {
                Text("This Mac has no Apple Intelligence, so Polished uses Scribe's built-in rules.")
                    .font(.nightMeta).foregroundStyle(Night.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Shortcut: the real hold key, double-tap hands-free, and the toggle shortcut.
struct ShortcutCard: View {
    @AppStorage("holdKey") private var holdKey = HoldKey.rightOption.rawValue
    @AppStorage("dictationMode") private var mode = DictationMode.both.rawValue
    @AppStorage("doubleTapHandsFree") private var doubleTap = true

    var body: some View {
        let key = HoldKey(rawValue: holdKey) ?? .rightOption
        let holdOn = key != .off && mode != DictationMode.toggleOnly.rawValue
        let toggle = mode != DictationMode.holdOnly.rawValue ? DictationSettings.toggleShortcut : nil
        PosterCard(symbol: "hand.raised", title: "Shortcut") { EmptyView() } content: {
            VStack(alignment: .leading, spacing: 12) {
                if holdOn {
                    row(keys: [key.keycap], title: "Hold to talk", hint: "Release to paste", big: true)
                    if doubleTap {
                        row(keys: [key.keycap, key.keycap], title: "Double-tap for hands-free", hint: "Tap again to stop")
                    }
                }
                if let toggle {
                    row(keys: [toggle.label], title: "Toggle", hint: "Press again to stop")
                }
                if !holdOn && toggle == nil {
                    Text("No dictation shortcut is set. Pick one in Settings › Dictation.")
                        .font(.nightSecondary).foregroundStyle(Night.text3)
                }
                Text("Esc cancels while you talk. \(key == .off ? "" : "The hold key is \(key.title).")")
                    .font(.nightMeta).foregroundStyle(Night.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(keys: [String], title: String, hint: String, big: Bool = false) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, k in
                    Keycap(text: k, height: big ? 34 : 26)
                }
            }
            Text(title).font(.nightBody).foregroundStyle(Night.text).lineLimit(1).minimumScaleFactor(0.85)
            Spacer(minLength: 6)
            Text(hint).font(.nightSecondary).foregroundStyle(Night.text3).lineLimit(1).minimumScaleFactor(0.85)
        }
    }
}
