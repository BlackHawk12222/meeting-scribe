// Store+Enrollment.swift
// Saves a guided voice enrollment ("Add person") into the voice library.

import Foundation

extension Store {
    /// Create the person (or update the one with this name) with these enrollment clips.
    /// Earlier enrollment clips of that person are replaced; samples learned from meetings stay.
    @discardableResult
    func enrollPerson(named name: String, clips: [(EnrollmentStyle, [Float])]) -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !clips.isEmpty else { return nil }
        let samples = VoiceEnrollment.samples(from: clips)
        if let i = people.firstIndex(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            VoiceMatcher.enroll(person: &people[i], samples: samples)
            save()
            return people[i].id
        }
        var person = Person(name: trimmed, colorIndex: people.count)
        VoiceMatcher.enroll(person: &person, samples: samples)
        people.append(person)
        save()
        return person.id
    }
}
