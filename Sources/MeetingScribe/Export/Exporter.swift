// Exporter.swift
// Turns a meeting into .txt, .srt (subtitles) or Markdown notes.

import Foundation

enum ExportFormat: String, CaseIterable, Identifiable {
    case txt, srt, md
    var id: String { rawValue }
    var label: String {
        switch self {
        case .txt: return "Plain text (.txt)"
        case .srt: return "Subtitles (.srt)"
        case .md: return "Markdown notes (.md)"
        }
    }
}

enum Exporter {
    /// 83.5 -> "00:01:23"
    static func clock(_ t: Double) -> String {
        let s = Int(t.rounded(.down))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    /// 83.5 -> "00:01:23,500" (SRT wants a comma before the milliseconds)
    static func srtClock(_ t: Double) -> String {
        let ms = Int((t * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms % 3_600_000) / 60_000,
                      (ms % 60_000) / 1000, ms % 1000)
    }

    static func render(_ m: Meeting, format: ExportFormat, name: (String) -> String) -> String {
        switch format {
        case .txt:
            var out = "\(m.title)\n\(m.date.formatted(date: .long, time: .shortened))\n\n"
            for u in m.utterances {
                out += "[\(clock(u.start))] \(name(u.speakerKey)): \(u.text)\n"
            }
            return out

        case .srt:
            var out = ""
            for (n, u) in m.utterances.enumerated() {
                out += "\(n + 1)\n\(srtClock(u.start)) --> \(srtClock(max(u.end, u.start + 0.5)))\n"
                out += "\(name(u.speakerKey)): \(u.text)\n\n"
            }
            return out

        case .md:
            var out = "# \(m.title)\n\n"
            out += "*\(m.date.formatted(date: .long, time: .shortened)) · \(clock(m.duration)) long*\n\n"
            out += "## Who talked\n\n"
            let total = max(m.clusters.reduce(0) { $0 + $1.talkSeconds }, 1)
            for c in m.clusters {
                let pct = Int((c.talkSeconds / total * 100).rounded())
                out += "- **\(name(c.key))** – \(clock(c.talkSeconds)) (\(pct)%)\n"
            }
            out += "\n## Notes\n\n- \n\n## Action items\n\n- [ ] \n\n## Transcript\n\n"
            for u in m.utterances {
                out += "**\(name(u.speakerKey))** `\(clock(u.start))` \(u.text)\n\n"
            }
            return out
        }
    }
}
