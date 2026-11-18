// Models.swift
// The plain data the app saves to disk. Everything here is `Codable`, which means
// Swift can turn it into JSON and back with one line (see Storage/Store.swift).

import Foundation

/// One "fingerprint" of a person's voice: a list of 256 numbers (an embedding)
/// that the speaker model produced from a few seconds of that person talking.
/// Two clips of the same person give embeddings that point in nearly the same
/// direction, so we compare them with cosine similarity (see VoiceMath.swift).
struct VoiceSample: Codable, Hashable {
    var vector: [Float]
    /// Which meeting (and which speaker cluster in it) this sample came from,
    /// so we can undo it if you re-label that speaker later.
    var meetingID: UUID?
    var clusterKey: String?
    var addedAt: Date
}

/// A person in your voice library (a teammate, a coach...).
struct Person: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var samples: [VoiceSample] = []
    var colorIndex: Int = 0

    /// How many different meetings taught us this voice.
    var meetingCount: Int { Set(samples.compactMap(\.meetingID)).count }
}

/// One transcribed word with its time (kept so speakers can be re-split without re-transcribing).
struct Word: Codable, Hashable {
    var start: Double
    var end: Double
    var text: String
}

/// One line of the transcript: who said what, and when.
struct Utterance: Codable, Identifiable, Hashable {
    var id = UUID()
    var start: Double      // seconds from the start of the recording
    var end: Double
    var speakerKey: String // the diarizer's label inside this meeting, e.g. "S2"
    var text: String
}

/// A voice the diarizer found inside ONE meeting ("S1", "S2"...).
/// The diarizer only knows the voices are different; the voice library
/// is what turns "S2" into "Sam".
struct SpeakerCluster: Codable, Identifiable, Hashable {
    var id: String { key }
    var key: String
    var talkSeconds: Double
    /// Average embedding of this voice in this meeting (used for matching).
    var centroid: [Float]
    /// Embeddings of this voice's longest turns (added to the library when you confirm).
    var spanEmbeddings: [[Float]]

    /// Who we think it is.
    var personID: UUID?
    /// How similar the voice was to that person (0...1, higher = more alike).
    var matchScore: Float?
    /// true = you named or confirmed it, so the library learned from it.
    var confirmed: Bool = false
    /// A weaker guess shown as "Maybe Sam?" when we are not sure enough to auto-label.
    var suggestedPersonID: UUID?
}

enum MeetingStatus: String, Codable {
    case recorded, processing, done, failed
}

struct Meeting: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var date: Date
    var duration: Double
    /// File name inside the app's Audio folder.
    var audioFileName: String
    var status: MeetingStatus = .recorded
    var errorMessage: String?
    var utterances: [Utterance] = []
    var clusters: [SpeakerCluster] = []
    /// Timed words from the speech-to-text model (optional so older files still load).
    var words: [Word]?
    /// nil = the model decides how many people talked; a number = you told it.
    var speakerCount: Int?
    /// How long transcription + speaker detection took (for the "x times faster than real time" readout).
    var processingSeconds: Double?
}
