// Store.swift
// Saves meetings and the voice library as JSON in
//   ~/Library/Containers/com.blackhawk12222.MeetingScribe/Data/Library/Application Support/MeetingScribe/
// (the app is sandboxed, so macOS gives it its own private folder).
// Nothing is uploaded anywhere.

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

    let folder: URL
    let audioFolder: URL
    private var meetingsURL: URL { folder.appendingPathComponent("meetings.json") }
    private var voicesURL: URL { folder.appendingPathComponent("voices.json") }

    init(folder: URL? = nil) {
        let base = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingScribe", isDirectory: true)
        self.folder = base
        self.audioFolder = base.appendingPathComponent("Audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: audioFolder, withIntermediateDirectories: true)
        load()
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
    }

    func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted]
        try? enc.encode(meetings).write(to: meetingsURL, options: .atomic)
        try? enc.encode(people).write(to: voicesURL, options: .atomic)
    }

    // MARK: - Models

    func prepareEngine() async {
        do {
            try await SpeechEngine.shared.prepare { msg in
                Task { @MainActor in self.engineStatus = msg }
            }
            engineReady = true
            engineError = nil
            // Process anything recorded while models were loading.
            for m in meetings where m.status == .recorded { await process(m.id) }
        } catch {
            engineError = "Model download/load failed: \(error.localizedDescription). Check your internet connection for the one-time download, then press Retry."
        }
    }

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
        guard engineReady, let i = index(of: id) else { return }
        meetings[i].status = .processing
        meetings[i].errorMessage = nil
        progressText[id] = "Transcribing and finding speakers…"
        let url = audioURL(for: meetings[i])
        let setting = DiarizerSetting(speakers: meetings[i].speakerCount)
        do {
            let started = Date()
            let samples = try SpeechEngine.loadSamples(url)
            let out = try await SpeechEngine.shared.process(samples: samples, setting: setting)
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
    }

    /// "There were really 5 people": re-group the voices without re-transcribing.
    func resplitSpeakers(_ id: UUID, count: Int?) async {
        guard engineReady, let i = index(of: id) else { return }
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
