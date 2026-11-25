// HomeView.swift
// 0.7.3 "Poster" Home: three poster tiles (words this week + daily bars, streak + last 7 days,
// words per minute + gauge), the 26-week activity heatmap, "Where you talk" (words per app), and
// the latest dictations with their app's color. Everything comes from Store.dictationStats.

import SwiftUI
import AppKit

struct HomeView: View {
    @EnvironmentObject var store: Store
    var query: String = ""
    var open: (UUID) -> Void = { _ in }
    var seeAllDictations: () -> Void = {}

    var body: some View {
        let stats = store.dictationStats
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !store.engineReady { ModelBanner().padding(.bottom, Night.s16) }
                tiles(stats)
                HStack(alignment: .top, spacing: 40) {
                    VStack(alignment: .leading, spacing: 0) {
                        HairlineHeader(title: "Last 26 weeks").padding(.bottom, 12)
                        ActivityHeatmap(stats: stats)
                        HairlineHeader(title: "Where you talk").padding(.top, 26).padding(.bottom, 12)
                        whereYouTalk(stats)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    latest(stats)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 28)
            }
            .padding(.horizontal, Night.gutterLeading)
            .padding(.top, 22)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.never)
    }

    // MARK: Tiles

    private func tiles(_ stats: DictationStats) -> some View {
        let wpm = stats.wordsPerMinute
        let streak = stats.streak
        return GeometryReader { geo in
            let gap = Night.cardGap
            let unit = (geo.size.width - 2 * gap) / 3.25
            HStack(spacing: gap) {
                PosterTile(color: Night.posterIndigo, label: "This week", value: stats.wordsThisWeek.formatted(),
                           caption: stats.wordsThisWeek == 1 ? "word dictated" : "words dictated") {
                    MiniBars(values: stats.weekBars, highlight: stats.todayIndexInWeek)
                }
                .frame(width: unit * 1.25)
                PosterTile(color: Night.posterCoral, label: "Streak", value: String(format: "%02d", streak),
                           caption: streak == 1 ? "day in a row" : "days in a row") {
                    DaySquares(filled: stats.last7Words.map { $0 > 0 })
                }
                .frame(width: unit)
                PosterTile(color: Night.posterGreen, label: "Speed", value: wpm.map { "\($0)" } ?? "–",
                           caption: wpm == nil ? "words per minute, after a few dictations" : "words per minute") {
                    RingGauge(fraction: Double(wpm ?? 0) / 200)
                }
                .frame(width: unit)
            }
        }
        .frame(height: Night.tileHeight)
    }

    // MARK: Where you talk

    @ViewBuilder private func whereYouTalk(_ stats: DictationStats) -> some View {
        let shares = stats.appShares
        if shares.isEmpty {
            Text("Dictate into any app and Scribe shows where your words go.")
                .font(.nightSecondary).foregroundStyle(Night.text3)
        } else {
            AppShareBar(shares: shares)
        }
    }

    // MARK: Latest

    private func latest(_ stats: DictationStats) -> some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        let items = Array(store.dictations.filter { q.isEmpty || $0.text.localizedCaseInsensitiveContains(q) }.prefix(5))
        return VStack(alignment: .leading, spacing: 0) {
            HairlineHeader(title: q.isEmpty ? "Latest" : "Matching “\(q)”") {
                if !store.dictations.isEmpty {
                    Button("See all", action: seeAllDictations)
                        .buttonStyle(.plain)
                        .font(.nightSecondary).foregroundStyle(Night.text3)
                }
            }
            if items.isEmpty {
                Text(store.dictations.isEmpty
                     ? "Nothing dictated yet. Hold \(DictationSettings.holdKey.shortName) in any text box and talk; a copy of each dictation shows up here."
                     : "No dictations match “\(q)”.")
                    .font(.nightSecondary).foregroundStyle(Night.text3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            } else {
                ForEach(items) { d in
                    LatestRow(entry: d, color: stats.color(forApp: Store.appKey(d)),
                              appName: stats.appName(Store.appKey(d)))
                }
            }
        }
    }
}

/// One latest dictation: "● 8:41 PM — Notes", then the text. Copy on hover.
struct LatestRow: View {
    let entry: DictationEntry
    var color: Color
    var appName: String
    @State private var hover = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                AppDot(color: color)
                Text("\(DictationFormat.time(entry.date)) — \(appName)")
                    .font(.nightSecondary).foregroundStyle(Night.text3).lineLimit(1)
                Spacer(minLength: 4)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Night.text3)
                    .opacity(hover || copied ? 1 : 0)
                    .help("Copy")
                    .accessibilityLabel("Copy dictation")
            }
            Text(entry.text).font(.nightReading).foregroundStyle(Night.text).lineSpacing(3)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { NightDivider() }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

enum DictationFormat {
    /// "8:41 PM" today, "Yesterday" / "Mon" / "Nov 3" before.
    static func time(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(d) { return "Yesterday " + d.formatted(date: .omitted, time: .shortened) }
        return d.formatted(.dateTime.month(.abbreviated).day()) + ", " + d.formatted(date: .omitted, time: .shortened)
    }
}
