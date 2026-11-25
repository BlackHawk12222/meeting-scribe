// DictationStats.swift
// 0.7.3 "Poster": the numbers on Home and Dictation, from real dictations only.
//
// The history (dictations.json) keeps the last 200 entries with their text. The LEDGER below keeps
// only counts (words, seconds spoken, dictations, words per app) for every day, forever, so the
// 26-week heatmap, the streak and "Where you talk" stay right after the history rolls over.
// No text is stored in the ledger. File: ~/Library/Application Support/Scribe/dictation-stats.json
//
// First launch of 0.7.3: the ledger is rebuilt from the history that exists. Entries from before
// 0.7.3 have no app recorded and count as "Other".

import Foundation
import SwiftUI

/// One day's counts.
struct DayStat: Codable, Hashable {
    var words: Int = 0
    /// Seconds of speech (key held), for words per minute.
    var seconds: Double = 0
    var count: Int = 0
    /// Words per app key (the app's bundle id, or "other").
    var apps: [String: Int] = [:]
}

struct DictationLedger: Codable, Hashable {
    /// "yyyy-MM-dd" in the Mac's calendar and time zone → counts.
    var days: [String: DayStat] = [:]
    /// Bundle id → the app's display name (last seen).
    var appNames: [String: String] = [:]
}

enum LedgerDay {
    static func key(_ d: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// One app's slice of "Where you talk".
struct AppShare: Identifiable, Hashable {
    var key: String
    var name: String
    var words: Int
    var fraction: Double
    var colorIndex: Int?      // nil = the grey "Other"
    var id: String { key }
    var color: Color { colorIndex.map { Night.appColors[$0 % Night.appColors.count] } ?? Night.appOther }
}

/// The app key for dictations with no app recorded (before 0.7.3).
enum AppKey {
    static let other = "other"
}

extension Store {
    private var ledgerURL: URL { folder.appendingPathComponent("dictation-stats.json") }

    func loadDictationLedger() {
        if let d = try? Data(contentsOf: ledgerURL), let l = try? JSONDecoder().decode(DictationLedger.self, from: d) {
            dictationLedger = l
        } else {
            rebuildDictationLedger()
        }
    }

    /// Recount everything from the history we have (first launch of 0.7.3; screenshots).
    func rebuildDictationLedger() {
        var l = DictationLedger()
        for e in dictations { Self.add(e, to: &l) }
        dictationLedger = l
        saveDictationLedger()
    }

    func recordInLedger(_ e: DictationEntry) {
        Self.add(e, to: &dictationLedger)
        saveDictationLedger()
    }

    private func saveDictationLedger() {
        try? JSONEncoder().encode(dictationLedger).write(to: ledgerURL, options: .atomic)
    }

    nonisolated static func appKey(_ e: DictationEntry) -> String {
        if let b = e.appBundleID, !b.isEmpty { return b }
        return AppKey.other
    }

    private static func add(_ e: DictationEntry, to l: inout DictationLedger) {
        let k = LedgerDay.key(e.date)
        var day = l.days[k] ?? DayStat()
        let w = e.wordCount
        day.words += w
        day.seconds += max(0, e.audioSeconds)
        day.count += 1
        day.apps[appKey(e), default: 0] += w
        l.days[k] = day
        if let b = e.appBundleID, let n = e.appName, !b.isEmpty, !n.isEmpty { l.appNames[b] = n }
    }

    /// Stats for the screens (computed, cheap: at most a few hundred days).
    var dictationStats: DictationStats { DictationStats(ledger: dictationLedger) }
}

/// Everything Home and Dictation show, computed from the ledger. `now` is injectable for tests.
struct DictationStats {
    let ledger: DictationLedger
    var now = Date()
    var calendar = Calendar.current

    func day(_ d: Date) -> DayStat { ledger.days[LedgerDay.key(d, calendar: calendar)] ?? DayStat() }

    private var today: Date { calendar.startOfDay(for: now) }

    /// The 7 days of THIS calendar week (the Mac's first weekday), oldest first.
    var weekDays: [Date] {
        let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    /// Words dictated this calendar week (the real sum of its days, today included).
    var wordsThisWeek: Int { weekDays.reduce(0) { $0 + day($1).words } }
    /// Words per day of this week (future days are 0), for the mini bars.
    var weekBars: [Int] { weekDays.map { $0 > now ? 0 : day($0).words } }
    /// Index of today in `weekDays`.
    var todayIndexInWeek: Int { weekDays.firstIndex { calendar.isDate($0, inSameDayAs: now) } ?? 6 }

    var wordsToday: Int { day(now).words }

    /// The last 7 days, oldest first (today last).
    var last7Days: [Date] { (0..<7).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) } }
    var last7Words: [Int] { last7Days.map { day($0).words } }

    /// Days in a row with at least one dictation, ending today (or yesterday, if today has none
    /// yet: the streak isn't broken until the day is over).
    var streak: Int {
        var d = day(now).words > 0 ? today : (calendar.date(byAdding: .day, value: -1, to: today) ?? today)
        var n = 0
        while day(d).words > 0 {
            n += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: d) else { break }
            d = prev
        }
        return n
    }

    /// Words per minute of speech over the last 30 days (nil until there are 20 s of speech).
    var wordsPerMinute: Int? {
        var words = 0, secs = 0.0
        for i in 0..<30 {
            guard let d = calendar.date(byAdding: .day, value: -i, to: today) else { continue }
            let s = day(d)
            words += s.words
            secs += s.seconds
        }
        guard secs >= 20, words > 0 else { return nil }
        return Int((Double(words) / (secs / 60)).rounded())
    }

    /// Dictations counted in the last 30 days.
    var count30: Int {
        (0..<30).reduce(0) { acc, i in
            guard let d = calendar.date(byAdding: .day, value: -i, to: today) else { return acc }
            return acc + day(d).count
        }
    }

    // MARK: Heatmap

    /// `weeks` columns (oldest first, the current week last) × 7 rows (the calendar's weekday
    /// order). nil = a day still to come.
    func heat(weeks: Int = 26) -> [[Int?]] {
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        return (0..<weeks).map { c in
            let start = calendar.date(byAdding: .weekOfYear, value: c - (weeks - 1), to: thisWeek) ?? thisWeek
            return (0..<7).map { r in
                guard let d = calendar.date(byAdding: .day, value: r, to: start) else { return nil }
                return d > now ? nil : day(d).words
            }
        }
    }

    /// 0 = nothing, 1...4 = a quarter of the busiest day each.
    static func heatLevel(_ words: Int, max: Int) -> Int {
        guard words > 0, max > 0 else { return 0 }
        return 1 + min(3, Int(Double(words) / Double(max) * 4 - 0.0001))
    }

    /// Month labels under the heatmap: the month of evenly spaced columns.
    func heatMonths(weeks: Int = 26, labels: Int = 6) -> [String] {
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        let f = DateFormatter()
        f.calendar = calendar
        f.setLocalizedDateFormatFromTemplate("MMM")
        return (0..<labels).map { i in
            let c = labels > 1 ? Int((Double(i) / Double(labels - 1) * Double(weeks - 1)).rounded()) : 0
            let d = calendar.date(byAdding: .weekOfYear, value: c - (weeks - 1), to: thisWeek) ?? thisWeek
            return f.string(from: d)
        }
    }

    // MARK: Apps

    func appName(_ key: String) -> String {
        if key == AppKey.other { return "Other" }
        return ledger.appNames[key] ?? key.split(separator: ".").last.map(String.init) ?? key
    }

    /// Words per app over all days.
    var appTotals: [String: Int] {
        var t: [String: Int] = [:]
        for d in ledger.days.values { for (k, w) in d.apps { t[k, default: 0] += w } }
        return t
    }

    /// Named apps by words, most first (the color order).
    var rankedApps: [String] {
        appTotals.filter { $0.key != AppKey.other && $0.value > 0 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { $0.key }
    }

    /// The dot color for an app (same rank → same color everywhere; past 6 → grey).
    func colorIndex(forApp key: String) -> Int? {
        guard key != AppKey.other, let i = rankedApps.firstIndex(of: key), i < Night.appColors.count else { return nil }
        return i
    }

    func color(forApp key: String) -> Color {
        colorIndex(forApp: key).map { Night.appColors[$0] } ?? Night.appOther
    }

    /// "Where you talk": up to 6 named apps; when there are more (or unknown ones), the top 5 +
    /// "Other". Fractions add up to 1.
    var appShares: [AppShare] {
        let totals = appTotals
        let all = totals.values.reduce(0, +)
        guard all > 0 else { return [] }
        let ranked = rankedApps
        let other = totals[AppKey.other] ?? 0
        let keep = (other == 0 && ranked.count <= 6) ? ranked : Array(ranked.prefix(5))
        var out = keep.enumerated().map { i, k in
            AppShare(key: k, name: appName(k), words: totals[k] ?? 0,
                     fraction: Double(totals[k] ?? 0) / Double(all), colorIndex: i)
        }
        let rest = all - out.reduce(0) { $0 + $1.words }
        if rest > 0 {
            out.append(AppShare(key: AppKey.other, name: "Other", words: rest, fraction: Double(rest) / Double(all), colorIndex: nil))
        }
        return out
    }

    /// The named app with the most words, and its share of ALL words.
    var topApp: AppShare? {
        guard let first = rankedApps.first else { return nil }
        let all = appTotals.values.reduce(0, +)
        guard all > 0 else { return nil }
        let w = appTotals[first] ?? 0
        return AppShare(key: first, name: appName(first), words: w, fraction: Double(w) / Double(all), colorIndex: 0)
    }
}
