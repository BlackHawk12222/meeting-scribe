// NotesMaker.swift
// After a meeting: summary, key points, and action items with owners.
//
// Plan A — Apple Intelligence (on-device, macOS 26+):
//   The model only "sees" about 4,000 tokens (~3,000 words) at once, so a long
//   meeting is cut into chunks. Each chunk gets its own notes ("map"), then the
//   chunk summaries are merged into one ("reduce"). This is called map-reduce.
//   We use *guided generation*: instead of hoping the model writes valid JSON, we
//   give it a Swift struct (@Generable) and it fills in the fields.
//
// Plan B — no AI (always works, instant):
//   "Extractive" notes: we don't write new sentences, we pick existing ones.
//   • Action items = sentences with promise/request words ("I'll", "we need to",
//     "can you", "by Friday"). Owner = whoever said it (or who they asked).
//   • Key points = sentences with the most "topic words" (words that come up a lot
//     in this meeting but aren't common words like "the").

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// One line of the transcript, with the speaker's current display name.
struct NotesLine: Sendable {
    var speaker: String
    var text: String
}

enum NotesMaker {
    /// Make notes for a meeting. Tries Apple Intelligence first when `useAI` is on.
    static func make(lines: [NotesLine], useAI: Bool) async -> MeetingNotes {
        if useAI, AppleIntelligence.isAvailable, let notes = await smart(lines: lines) {
            return notes
        }
        var notes = extractive(lines: lines)
        if useAI && !AppleIntelligence.isAvailable {
            notes.note = "Quick notes picked from the transcript (Apple Intelligence: \(AppleIntelligence.statusText))."
        }
        return notes
    }

    // MARK: - Plan A: Apple Intelligence

    /// Cut the transcript into pieces that fit the model's context window.
    /// ~6,000 characters ≈ 1,500 tokens, leaving room for instructions and the answer.
    static func chunks(_ lines: [NotesLine], maxChars: Int = 6_000) -> [String] {
        var out: [String] = []
        var current = ""
        for l in lines {
            let row = "\(l.speaker): \(l.text)\n"
            if current.count + row.count > maxChars, !current.isEmpty {
                out.append(current)
                current = ""
            }
            current += row.count > maxChars ? String(row.prefix(maxChars)) + "\n" : row
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    static func smart(lines: [NotesLine]) async -> MeetingNotes? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let parts = chunks(lines)
            guard !parts.isEmpty else { return nil }
            let started = Date()
            var drafts: [NotesDraft] = []
            let instructions = """
            You write meeting notes from a transcript. Each line starts with the speaker's name. \
            Only use facts that are in the transcript. Owners of action items must be speaker names \
            from the transcript, or "Unassigned". Keep everything short and plain.
            """
            do {
                // MAP: notes for each chunk (a fresh session each time, so the context starts empty).
                for (i, part) in parts.enumerated() {
                    let session = LanguageModelSession(instructions: instructions)
                    let prompt = "Transcript part \(i + 1) of \(parts.count):\n\n\(part)"
                    let r = try await session.respond(to: prompt, generating: NotesDraft.self,
                                                      options: GenerationOptions(sampling: .greedy))
                    drafts.append(r.content)
                }
                // REDUCE: merge the chunk summaries into one (only needed for long meetings).
                var summary = drafts.first?.summary ?? ""
                var keyPoints = drafts.flatMap(\.keyPoints)
                if drafts.count > 1 {
                    let session = LanguageModelSession(instructions: "You merge partial meeting notes into one short set of notes. Only use what is given.")
                    let joined = drafts.enumerated().map { i, d in
                        "Part \(i + 1) summary: \(d.summary)\nPart \(i + 1) points: " + d.keyPoints.joined(separator: "; ")
                    }.joined(separator: "\n\n")
                    let merged = try await session.respond(to: String(joined.prefix(9_000)), generating: MergedDraft.self,
                                                           options: GenerationOptions(sampling: .greedy))
                    summary = merged.content.summary
                    keyPoints = merged.content.keyPoints
                }
                // Action items from every chunk, without duplicates.
                var seen = Set<String>()
                var items: [ActionItem] = []
                for d in drafts {
                    for a in d.actionItems where seen.insert(a.task.lowercased()).inserted {
                        items.append(ActionItem(task: a.task, owner: a.owner))
                    }
                }
                return MeetingNotes(summary: summary, keyPoints: Array(keyPoints.prefix(8)), actionItems: items,
                                    method: .appleIntelligence, createdAt: Date(),
                                    seconds: Date().timeIntervalSince(started),
                                    note: parts.count > 1 ? "Made on-device from \(parts.count) parts of the transcript." : nil)
            } catch {
                print("Apple Intelligence notes failed, using quick notes: \(error)")
                return nil
            }
        }
        #endif
        return nil
    }

    // MARK: - Plan B: extractive (no AI)

    static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "so", "to", "of", "in", "on", "at", "for", "with",
        "is", "are", "was", "were", "be", "been", "it", "its", "it's", "this", "that", "these", "those", "i",
        "you", "we", "they", "he", "she", "me", "my", "your", "our", "their", "them", "us", "do", "did",
        "does", "have", "has", "had", "not", "no", "yes", "yeah", "okay", "ok", "um", "uh", "like", "just",
        "if", "then", "there", "here", "what", "which", "who", "how", "why", "when", "can", "could", "would", "should",
        "will", "i'll", "we'll", "don't", "i'm", "we're", "you're", "that's", "there's", "gonna", "really", "very", "also", "about",
        "think", "know", "mean", "right", "well", "go", "get", "got", "one", "all", "some", "more", "as", "from",
        "by", "up", "out", "because", "maybe", "kind", "sort", "thing", "things", "lot", "mm", "hmm", "oh", "actually", "going", "yup", "yep", "now", "first",
        "need",
    ]

    /// Promise / request / deadline phrases that usually mark an action item.
    static let actionPattern = try! NSRegularExpression(pattern: """
    (?i)\\b(i'll|i will|i'm going to|i am going to|let me|we'll|we will|we need to|we have to|we should|\
    let's|you need to|can you|could you|would you|please|make sure|remember to|don't forget|action item|\
    by (monday|tuesday|wednesday|thursday|friday|saturday|sunday|tomorrow|tonight|next week|the end of))\\b
    """)

    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, _, _, _ in
            if let s { out.append(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        return out.filter { !$0.isEmpty }
    }

    static func extractive(lines: [NotesLine]) -> MeetingNotes {
        let started = Date()
        // Every sentence, remembering who said it and in what order.
        var all: [(speaker: String, text: String, order: Int)] = []
        for l in lines { for s in sentences(l.text) { all.append((l.speaker, s, all.count)) } }

        // Word counts across the whole meeting (topic words).
        var freq: [String: Int] = [:]
        for s in all { for w in TextCleanup.words(s.text) where !stopwords.contains(w) && w.count > 2 { freq[w, default: 0] += 1 } }

        // Action items.
        var items: [ActionItem] = []
        var seen = Set<String>()
        for s in all {
            let n = TextCleanup.words(s.text).count
            guard n >= 4, n <= 40,
                  actionPattern.firstMatch(in: s.text, range: NSRange(s.text.startIndex..., in: s.text)) != nil,
                  seen.insert(s.text.lowercased()).inserted else { continue }
            let lower = s.text.lowercased()
            let owner: String
            if lower.hasPrefix("we") || lower.hasPrefix("let's") { owner = "Team (\(s.speaker) said)" }
            else if lower.contains("can you") || lower.contains("could you") || lower.contains("you need to")
                        || lower.contains("would you") { owner = "Asked by \(s.speaker)" }
            else { owner = s.speaker }
            items.append(ActionItem(task: s.text, owner: owner))
        }

        // Key points: sentences with the most topic words (normalized so long rambles don't always win).
        let scored = all.compactMap { s -> (Double, Int, String)? in
            let ws = TextCleanup.words(s.text)
            guard ws.count >= 6, ws.count <= 40 else { return nil }
            let score = ws.reduce(0.0) { $0 + Double(freq[$1] ?? 0) } / sqrt(Double(ws.count))
            return (score, s.order, "\(s.speaker): \(s.text)")
        }
        let key = scored.sorted { $0.0 > $1.0 }.prefix(5).sorted { $0.1 < $1.1 }.map(\.2)

        // Summary: who talked most + the top topic words.
        var talk: [String: Int] = [:]
        for l in lines { talk[l.speaker, default: 0] += TextCleanup.words(l.text).count }
        let total = max(talk.values.reduce(0, +), 1)
        let speakers = talk.sorted { $0.value > $1.value }.prefix(4)
            .map { "\($0.key) (\(Int((Double($0.value) / Double(total) * 100).rounded()))%)" }
        let topics = freq.sorted { $0.value > $1.value }.prefix(6).map(\.key)
        var summary = "\(talk.count) \(talk.count == 1 ? "person" : "people") talked"
        if !speakers.isEmpty { summary += ", mostly " + speakers.joined(separator: ", ") }
        summary += "."
        if !topics.isEmpty { summary += " Words that came up most: " + topics.joined(separator: ", ") + "." }

        return MeetingNotes(summary: summary, keyPoints: key, actionItems: Array(items.prefix(12)),
                            method: .rules, createdAt: Date(), seconds: Date().timeIntervalSince(started),
                            note: "Quick notes picked from the transcript (no AI).")
    }
}

#if canImport(FoundationModels)
// The shapes we ask Apple's model to fill in ("guided generation").
@available(macOS 26.0, *)
@Generable
struct NotesDraft {
    @Guide(description: "A 2 to 4 sentence summary of what was discussed and decided")
    var summary: String
    @Guide(description: "The most important points, each one short sentence, at most 6")
    var keyPoints: [String]
    @Guide(description: "Tasks someone agreed to do or was asked to do. Empty if there are none")
    var actionItems: [ActionDraft]
}

@available(macOS 26.0, *)
@Generable
struct ActionDraft {
    @Guide(description: "What needs to be done, as a short command, e.g. 'Print the new gear mount'")
    var task: String
    @Guide(description: "The speaker name of the person who will do it, exactly as written in the transcript, or Unassigned")
    var owner: String
}

@available(macOS 26.0, *)
@Generable
struct MergedDraft {
    @Guide(description: "A 3 to 5 sentence summary of the whole meeting")
    var summary: String
    @Guide(description: "The most important points of the whole meeting, each one short sentence, at most 8")
    var keyPoints: [String]
}
#endif
