// Store+Profile.swift
// 0.7.3: the Profile page's data. A display name and "member since" in profile.json, an optional
// photo in profile-photo.png (downscaled to 256 px), both in the app's own folder
// (~/Library/Application Support/Scribe). Nothing here is uploaded or shared.

import Foundation
import AppKit

struct UserProfile: Codable, Hashable {
    /// What the avatar and Profile page call you. Empty = "You".
    var displayName: String = ""
    /// First time this profile was saved or read (filled in on first launch of 0.7.3).
    var memberSince: Date?
    /// 0.7.3.2 "My voice": the voice-library person that is you (nil = not set up yet).
    var myPersonID: UUID? = nil

    var shownName: String {
        let t = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "You" : t
    }
    /// One letter for the avatar (nil = show the person symbol).
    var initial: String? {
        let t = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.first.map { String($0).uppercased() }
    }
}

extension Store {
    private var profileURL: URL { folder.appendingPathComponent("profile.json") }
    private var profilePhotoURL: URL { folder.appendingPathComponent("profile-photo.png") }

    func loadProfile() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: profileURL), let p = try? dec.decode(UserProfile.self, from: d) {
            profile = p
        }
        if profile.memberSince == nil {
            profile.memberSince = earliestActivity ?? Date()
            saveProfile()
        }
        profilePhoto = NSImage(contentsOf: profilePhotoURL)
    }

    /// The oldest meeting, dictation or ledger day (so upgraders keep their real start date).
    private var earliestActivity: Date? {
        var dates = meetings.map(\.date) + dictations.map(\.date)
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        dates += dictationLedger.days.keys.compactMap { f.date(from: $0) }
        return dates.min()
    }

    func saveProfile() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(profile) { try? d.write(to: profileURL, options: .atomic) }
    }

    func setDisplayName(_ name: String) {
        profile.displayName = String(name.prefix(60))
        saveProfile()
    }

    /// Copies the picked image in, center-cropped to a square and scaled to 256 px.
    func setProfilePhoto(from url: URL) {
        guard let src = NSImage(contentsOf: url), let png = Self.squarePNG(src, side: 256) else { return }
        try? png.write(to: profilePhotoURL, options: .atomic)
        profilePhoto = NSImage(data: png)
    }

    func removeProfilePhoto() {
        try? FileManager.default.removeItem(at: profilePhotoURL)
        profilePhoto = nil
    }

    /// Snapshot/self-test only: a photo drawn in memory (no file).
    func setPreviewProfilePhoto(_ image: NSImage?) { profilePhoto = image }

    nonisolated static func squarePNG(_ image: NSImage, side: Int) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = cg.width, h = cg.height, s = min(w, h)
        guard s > 0, let crop = cg.cropping(to: CGRect(x: (w - s) / 2, y: (h - s) / 2, width: s, height: s)),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
    }

    /// Profile stats: every word in the per-day ledger (it keeps all days).
    var totalWordsDictated: Int { dictationLedger.days.values.reduce(0) { $0 + $1.words } }
}
