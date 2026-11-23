// Store.swift
// Saves meetings, the voice library and recent dictations as JSON in
//   ~/Library/Application Support/Scribe/
// Nothing is uploaded anywhere.
// (Older versions were called Meeting Scribe and were sandboxed; their data is copied over once.)

import Foundation
import SwiftUI

@MainActor
final class Store: ObservableObject {
    @Published var meetings: [Meeting] = []
    @Published var people: [Person] = []
    @Published var engineStatus: String = "Starting…"
    @Published var engineReady = false
    @Published var engineError: String?
    @Published var progressText: [UUID: String] = [:]
    /// 0...1 while models download (nil = not downloading). Shown in onboarding + the banner.
    @Published var modelProgress: Double?
    @Published var dictations: [DictationEntry] = []

    let folder: URL
    let audioFolder: URL
    private var meetingsURL: URL { folder.appendingPathComponent("meetings.json") }
    private var voicesURL: URL { folder.appendingPathComponent("voices.json") }
    private var dictationsURL: URL { folder.appendingPathComponent("dictations.json") }

    init(folder: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let base = folder ?? support.appendingPathComponent("Scribe", isDirectory: true)
        self.folder = base
        self.audioFolder = base.appendingPathComponent("Audio", isDirectory: true)
        if folder == nil { Self.migrateFromMeetingScribe(to: base, support: support) }
        try? FileManager.default.createDirectory(at: audioFolder, withIntermediateDirectories: true)
        load()
    }

    /// One time: copy data from the old sandboxed "Meeting Scribe" app, if there is any.
    /// (macOS may ask "Scribe would like to access data from other apps" — that's this copy.)
    private static func migrateFromMeetingScribe(to base: URL, support: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: base.appendingPathComponent("meetings.json").path),
              !UserDefaults.standard.bool(forKey: "migratedFromMeetingScribe") else { return }
        UserDefaults.standard.set(true, forKey: "migratedFromMeetingScribe")
        let home = fm.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Library/Containers/com.blackhawk12222.MeetingScribe/Data/Library/Application Support/MeetingScribe"),
            support.appendingPathComponent("MeetingScribe"),
        ]
        for old in candidates where fm.fileExists(atPath: old.appendingPathComponent("meetings.json").path) {
            try? fm.createDirectory(at: base.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fm.copyItem(at: old, to: base)) != nil { return }
        }
    }

    // MARK: - Saving / loading

    private func load() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: meetingsURL), let m = try? dec.decode([Meeting].self, from: d) {
            // A meeting that was mid-processing when the app quit gets retried.
            meetings = m.map { var x = $0; if x.status == .processing { x.status = .recorded }; return x }
        }
        if let d = try? Data(contentsOf: voicesURL), let p = try? dec.decode([Person].self, from: d) {
            people = p
        }
        if let d = try? Data(contentsOf: dictationsURL), let x = try? dec.decode([DictationEntry].self, from: d) {
            dictations = x
        }
    }

    func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted]
        try? enc.encode(meetings).write(to: meetingsURL, options: .atomic)
        try? enc.encode(people).write(to: voicesURL, options: .atomic)
        try? enc.encode(dictations).write(to: dictationsURL, options: .atomic)
    }

    // MARK: - Models

    /// Startup: get DICTATION working as fast as possible, then the meeting models.
    ///  1. ModelStore checks what's on disk and downloads only missing/changed files
    ///     (in parallel, resumable) — usually nothing at all after the first launch.
    ///  2. FluidAudio loads Parakeet + the voice detector → dictation works.
    ///  3. In the background: the speaker models (22 MB) for meetings.
    func prepareEngine() async {
        engineReady = false
        engineError = nil
        let models = ModelStore.shared
        let speech = SpeechModel.current
        do {
            let needed = models.dictationComponents(speech)
            let watcher = Task { @MainActor in
                // Mirror download progress into the status line + progress bar.
                while !Task.isCancelled {
                    if let p = models.progress {
                        self.engineStatus = "Downloading speech model (one time) · \(p.text)"
                        self.modelProgress = p.fraction
                    }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
            defer { watcher.cancel() }
            engineStatus = "Checking models…"
            try await models.ensure(needed)
            watcher.cancel()
            modelProgress = nil
            // Dictation models are in; start the meeting models right away (in parallel with
            // loading the speech model), so everything is ready without waiting for a meeting.
            Task(priority: .utility) { _ = await self.prepareMeetingModels() }
            try await SpeechEngine.shared.prepareDictation(model: speech) { msg, fraction in
                Task { @MainActor in
                    self.engineStatus = msg
                    self.modelProgress = fraction
                }
            }
            engineReady = true
            engineError = nil
            modelProgress = nil
            engineStatus = "Ready"
            Task(priority: .utility) { await self.prepareVocabularyBoost() }
            Task.detached(priority: .utility) { Vocabulary.preload() }
        } catch {
            modelProgress = nil
            engineError = "Model download/load failed: \(error.localizedDescription). Check your internet connection for the one-time download, then press Retry."
            return
        }
    }

    /// Settings › Vocabulary: "" = off/not loaded, else a short status line.
    @Published var vocabularyBoostStatus = ""

    /// The vocabulary helper: download (100 MB, once) + load, or unload when switched off.
    /// Never blocks dictation; the text pass works without it.
    func prepareVocabularyBoost() async {
        guard Vocabulary.acousticBoost else {
            await SpeechEngine.shared.unloadVocabularyBoost()
            vocabularyBoostStatus = ""
            return
        }
        do {
            vocabularyBoostStatus = "Getting the helper model ready…"
            try await ModelStore.shared.ensure(ModelStore.shared.vocabularyComponents)
            try await SpeechEngine.shared.loadVocabularyBoost(terms: Vocabulary.terms)
            vocabularyBoostStatus = "Ready"
        } catch {
            vocabularyBoostStatus = "Helper model unavailable: \(error.localizedDescription)"
        }
    }

    /// True once the speaker models are loaded (meetings can be processed).
    @Published var meetingModelsReady = false
    private var meetingPrep: Task<Bool, Never>?

    /// Make sure the meeting (speaker) models are downloaded and loaded. Safe to call many times.
    @discardableResult
    func prepareMeetingModels() async -> Bool {
        if meetingModelsReady { return true }
        if let t = meetingPrep { return await t.value }
        let t = Task { @MainActor () -> Bool in
            do {
                try await ModelStore.shared.ensure(ModelStore.shared.meetingComponents)
                try await SpeechEngine.shared.prepareMeetings { _, _ in }
                self.meetingModelsReady = true
                // Process anything recorded while models were loading.
                for m in self.meetings where m.status == .recorded { await self.process(m.id) }
                return true
            } catch {
                self.meetingPrepError = error.localizedDescription
                return false
            }
        }
        meetingPrep = t
        let ok = await t.value
        meetingPrep = nil
        return ok
    }
    @Published var meetingPrepError: String?

    // MARK: - Meetings

    func newRecordingURL() -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return audioFolder.appendingPathComponent("meeting_\(f.string(from: Date())).wav")
    }

    @discardableResult
    func addMeeting(audioURL: URL, duration: Double, title: String? = nil) -> Meeting {
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d, h:mm a"
        let m = Meeting(title: title ?? "Meeting – \(f.string(from: Date()))", date: Date(),
                        duration: duration, audioFileName: audioURL.lastPathComponent)
        meetings.insert(m, at: 0)
        save()
        return m
    }

    func audioURL(for m: Meeting) -> URL { audioFolder.appendingPathComponent(m.audioFileName) }

    func index(of id: UUID) -> Int? { meetings.firstIndex { $0.id == id } }

    /// Transcribe + find speakers + match them to the voice library.
    func process(_ id: UUID) async {
        guard engineReady, index(of: id) != nil else { return }
        if !meetingModelsReady {
            if let i = index(of: id) { progressText[id] = "Getting the speaker models (one time)…"; meetings[i].status = .processing }
            guard await prepareMeetingModels() else {
                if let i = index(of: id) {
                    meetings[i].status = .failed
                    meetings[i].errorMessage = "Couldn't get the speaker models: \(meetingPrepError ?? "unknown error"). Check the internet and press Process again."
                    progressText[id] = nil
                    save()
                }
                return
            }
        }
        guard let i = index(of: id) else { return }
        meetings[i].status = .processing
        meetings[i].errorMessage = nil
        progressText[id] = "Transcribing and finding speakers…"
        let url = audioURL(for: meetings[i])
        let setting = DiarizerSetting(speakers: meetings[i].speakerCount)
        do {
            let started = Date()
            let samples = try SpeechEngine.loadSamples(url)
            let out = try await SpeechEngine.shared.process(samples: samples, setting: setting) { line in
                Task { @MainActor in self.progressText[id] = line }
            }
            guard let j = index(of: id) else { return }
            unlearnMeeting(id)
            meetings[j].words = out.words
            meetings[j].utterances = out.utterances
            meetings[j].clusters = out.clusters
            meetings[j].duration = Double(samples.count) / 16_000
            meetings[j].processingSeconds = Date().timeIntervalSince(started)
            meetings[j].status = .done
            applyLibrary(to: id)
        } catch {
            if let j = index(of: id) {
                meetings[j].status = .failed
                meetings[j].errorMessage = error.localizedDescription
            }
        }
        progressText[id] = nil
        save()
        if meetings.first(where: { $0.id == id })?.status == .done { await makeNotes(id) }
    }

    // MARK: - Notes

    @Published var notesInProgress: Set<UUID> = []

    /// Summary + key points + action items (Apple Intelligence if available, otherwise quick notes).
    func makeNotes(_ id: UUID) async {
        guard let m = meetings.first(where: { $0.id == id }), !m.utterances.isEmpty,
              !notesInProgress.contains(id) else { return }
        notesInProgress.insert(id)
        let lines = m.utterances.map { NotesLine(speaker: displayName(m, key: $0.speakerKey), text: $0.text) }
        let useAI = UserDefaults.standard.object(forKey: "aiNotes") as? Bool ?? true
        let notes = await NotesMaker.make(lines: lines, useAI: useAI)
        if let j = index(of: id) { meetings[j].notes = notes }
        notesInProgress.remove(id)
        save()
        syncMeeting(id)
    }

    /// Queue this meeting's Markdown for the user's GitHub notes repo (if Sync is set up).
    /// Returns immediately; GitHubSync sends it in the background.
    func syncMeeting(_ id: UUID) {
        guard folderIsDefault, let m = meetings.first(where: { $0.id == id }), m.status == .done else { return }
        let md = Exporter.render(m, format: .md, name: { self.displayName(m, key: $0) })
        GitHubSync.shared.add(meeting: m, markdown: md)
    }

    /// Only the real library syncs (not the snapshot/self-test sample stores).
    private var folderIsDefault: Bool {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return folder.standardizedFileURL == support.appendingPathComponent("Scribe", isDirectory: true).standardizedFileURL
    }

    func toggleActionItem(meetingID: UUID, itemID: UUID) {
        guard let i = index(of: meetingID), var notes = meetings[i].notes,
              let k = notes.actionItems.firstIndex(where: { $0.id == itemID }) else { return }
        notes.actionItems[k].done.toggle()
        meetings[i].notes = notes
        save()
    }

    // MARK: - Search

    /// Meetings whose title, transcript, notes or speaker names contain `query`,
    /// each with a short snippet around the first hit.
    func search(_ query: String) -> [(id: UUID, snippet: String)] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        func hit(_ text: String) -> String? {
            guard let r = text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
            let start = text.index(r.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(r.upperBound, offsetBy: 60, limitedBy: text.endIndex) ?? text.endIndex
            let prefix = start > text.startIndex ? "…" : ""
            let suffix = end < text.endIndex ? "…" : ""
            return prefix + String(text[start..<end]) + suffix
        }
        var out: [(UUID, String)] = []
        for m in meetings {
            if let s = hit(m.title) { out.append((m.id, s)); continue }
            if let n = m.notes {
                let notesText = ([n.summary] + n.keyPoints + n.actionItems.map { "\($0.task) (\($0.owner))" })
                    .joined(separator: " · ")
                if let s = hit(notesText) { out.append((m.id, "Notes: " + s)); continue }
            }
            if let u = m.utterances.first(where: { hit($0.text) != nil }), let s = hit(u.text) {
                out.append((m.id, "\(displayName(m, key: u.speakerKey)): " + s)); continue
            }
            let names = m.clusters.compactMap { person($0.personID)?.name }.joined(separator: ", ")
            if let s = hit(names) { out.append((m.id, "People: " + s)) }
        }
        return out.map { (id: $0.0, snippet: $0.1) }
    }

    // MARK: - Dictation history

    func addDictation(_ entry: DictationEntry) {
        dictations.insert(entry, at: 0)
        if dictations.count > 200 { dictations.removeLast(dictations.count - 200) }
        save()
        if folderIsDefault { GitHubSync.shared.add(dictation: entry) }
    }

    func clearDictations() {
        dictations.removeAll()
        save()
    }

    /// "There were really 5 people": re-group the voices without re-transcribing.
    func resplitSpeakers(_ id: UUID, count: Int?) async {
        guard engineReady, await prepareMeetingModels(), let i = index(of: id) else { return }
        meetings[i].speakerCount = count
        guard let words = meetings[i].words else { await process(id); return }
        meetings[i].status = .processing
        progressText[id] = "Re-grouping speakers…"
        do {
            let samples = try SpeechEngine.loadSamples(audioURL(for: meetings[i]))
            let d = try await SpeechEngine.shared.diarize(samples: samples, setting: DiarizerSetting(speakers: count))
            guard let j = index(of: id) else { return }
            unlearnMeeting(id)   // old clusters are gone, so forget what they taught
            meetings[j].clusters = d.clusters
            meetings[j].utterances = SpeechEngine.utterances(words: words, segments: d.segments)
            meetings[j].status = .done
            applyLibrary(to: id)
        } catch {
            if let j = index(of: id) {
                meetings[j].status = .failed
                meetings[j].errorMessage = error.localizedDescription
            }
        }
        progressText[id] = nil
        save()
    }

    /// Remove every voice sample that came from this meeting.
    private func unlearnMeeting(_ id: UUID) {
        for p in people.indices { people[p].samples.removeAll { $0.meetingID == id } }
    }

    /// Put names on speakers that aren't confirmed yet, using the voice library.
    func applyLibrary(to id: UUID) {
        guard let i = index(of: id) else { return }
        let open = meetings[i].clusters.filter { !$0.confirmed }
        // People already confirmed in this meeting can't be matched again.
        let taken = Set(meetings[i].clusters.filter(\.confirmed).compactMap(\.personID))
        let matches = VoiceMatcher.match(clusters: open, people: people.filter { !taken.contains($0.id) })
        for c in open {
            guard let k = meetings[i].clusters.firstIndex(where: { $0.key == c.key }) else { continue }
            let m = matches[c.key]
            meetings[i].clusters[k].personID = (m?.isConfident == true) ? m?.personID : nil
            meetings[i].clusters[k].suggestedPersonID = (m?.isConfident == false) ? m?.personID : nil
            meetings[i].clusters[k].matchScore = m?.score
        }
    }

    // MARK: - Naming speakers (this is where the library learns)

    /// "S2 is Sam" -> label it AND add S2's voice samples to Sam.
    func assign(meetingID: UUID, clusterKey: String, to personID: UUID) {
        guard let i = index(of: meetingID),
              let k = meetings[i].clusters.firstIndex(where: { $0.key == clusterKey }),
              let p = people.firstIndex(where: { $0.id == personID }) else { return }

        // If this cluster was taught to someone else before, undo that.
        if let old = meetings[i].clusters[k].personID, meetings[i].clusters[k].confirmed,
           let o = people.firstIndex(where: { $0.id == old }) {
            VoiceMatcher.unlearn(person: &people[o], meetingID: meetingID, clusterKey: clusterKey)
        }
        // Note: one person CAN own two clusters (the diarizer sometimes splits a voice in two).
        meetings[i].clusters[k].personID = personID
        meetings[i].clusters[k].suggestedPersonID = nil
        meetings[i].clusters[k].confirmed = true
        VoiceMatcher.learn(person: &people[p], from: meetings[i].clusters[k], meetingID: meetingID)

        applyLibrary(to: meetingID)   // the new samples may help name the others
        save()
        syncMeeting(meetingID)        // names changed: update the notes file
    }

    func createPerson(named name: String, meetingID: UUID, clusterKey: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let existing = people.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            assign(meetingID: meetingID, clusterKey: clusterKey, to: existing.id)
            return
        }
        let person = Person(name: trimmed, colorIndex: people.count)
        people.append(person)
        assign(meetingID: meetingID, clusterKey: clusterKey, to: person.id)
    }

    /// Mark a speaker as "not this person / unknown".
    func clearSpeaker(meetingID: UUID, clusterKey: String) {
        guard let i = index(of: meetingID),
              let k = meetings[i].clusters.firstIndex(where: { $0.key == clusterKey }) else { return }
        if let old = meetings[i].clusters[k].personID, let o = people.firstIndex(where: { $0.id == old }) {
            VoiceMatcher.unlearn(person: &people[o], meetingID: meetingID, clusterKey: clusterKey)
        }
        meetings[i].clusters[k].personID = nil
        meetings[i].clusters[k].suggestedPersonID = nil
        meetings[i].clusters[k].confirmed = false
        save()
    }

    func deleteMeeting(_ id: UUID) {
        guard let i = index(of: id) else { return }
        // Voices learned from this meeting stay in the library on purpose.
        try? FileManager.default.removeItem(at: audioURL(for: meetings[i]))
        meetings.remove(at: i)
        save()
    }

    // MARK: - People

    func person(_ id: UUID?) -> Person? { people.first { $0.id == id } }

    func rename(personID: UUID, to name: String) {
        guard let p = people.firstIndex(where: { $0.id == personID }) else { return }
        people[p].name = name
        save()
    }

    func deletePerson(_ id: UUID) {
        people.removeAll { $0.id == id }
        for i in meetings.indices {
            for k in meetings[i].clusters.indices where meetings[i].clusters[k].personID == id
                || meetings[i].clusters[k].suggestedPersonID == id {
                meetings[i].clusters[k].personID = nil
                meetings[i].clusters[k].suggestedPersonID = nil
                meetings[i].clusters[k].confirmed = false
            }
        }
        save()
    }

    /// Display name for a speaker in a meeting.
    func displayName(_ meeting: Meeting, key: String) -> String {
        if let c = meeting.clusters.first(where: { $0.key == key }), let p = person(c.personID) {
            return p.name
        }
        let n = key.replacingOccurrences(of: "S", with: "")
        return "Speaker \(n)"
    }
}
