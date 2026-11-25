// SelfTest0732.swift
// Targeted checks for 0.7.3.2 (run inside `--suite targeted`, see SelfTest072.run):
//   crypto     – AES-GCM round trip; a changed byte, another kind (associated data), another
//                account or another key fail to open; recovery key round trip (any case, O/0, I/1,
//                spaces); the key check accepts the right key only
//   payload    – the opt-in kinds (People, voice profiles) are OFF by default and not uploaded;
//                the rows that would be uploaded contain no plaintext (marker words, names,
//                voiceprint numbers) even with both switches on; opening them on a "new Mac"
//                restores Dictionary, Vocabulary, learned fixes, Style, settings and people
//   signedout  – no backend configured = "unavailable": no Keychain, no network, Sync does
//                nothing; placeholders are not a configuration; the app's data saves and loads
//                exactly as before
//   myvoice    – not set up → set up (strength, clip count), Train it more adds a clip, Test it
//                says "Matched you — strong match" for you and "Sounded more like …" for someone
//                else, thresholds in plain words, Re-record from scratch, Delete my voice
//   meetings   – dashboard numbers from a sample store (this week's meetings and hours, open
//                action items, top speakers, unnamed voices minus dismissed ones); opening a
//                meeting shows the detail; a pull past the top (overscroll) returns to the
//                dashboard (a small pull doesn't); Esc and ⌘[ go back, Esc in a text field doesn't
// All names and data are invented.

import Foundation
import AppKit
import SwiftUI
import CryptoKit

enum SelfTest0732 {
    static func log(_ s: String) { SelfTest.log(s) }

    @MainActor static func run() async -> ([String: Any], [String]) {
        var r: [String: Any] = [:]
        var fail: [String] = []
        let c = cryptoCheck(); r["crypto"] = c.0; fail += c.1
        let p = payloadCheck(); r["payload"] = p.0; fail += p.1
        let s = await signedOutCheck(); r["signed_out"] = s.0; fail += s.1
        let v = myVoiceCheck(); r["my_voice"] = v.0; fail += v.1
        let m = await meetingsCheck(); r["meetings"] = m.0; fail += m.1
        return (r, fail)
    }

    // MARK: Crypto

    static func cryptoCheck() -> ([String: Any], [String]) {
        var r: [String: Any] = [:]
        var fail: [String] = []
        let key = SyncCrypto.newKey()
        let user = "11111111-2222-3333-4444-555555555555"
        let plain = Data("Zorvath Quill → zorvath quill; vocabulary: Tamsin".utf8)
        do {
            let sealed = try SyncCrypto.seal(plain, key: key, user: user, kind: "vocabulary")
            r["sealed_prefix"] = String(sealed.prefix(3))
            r["sealed_length"] = sealed.count
            if try SyncCrypto.open(sealed, key: key, user: user, kind: "vocabulary") != plain { fail.append("crypto: round trip changed the data") }
            let again = try SyncCrypto.seal(plain, key: key, user: user, kind: "vocabulary")
            if again == sealed { fail.append("crypto: same text sealed twice gave the same output (nonce reuse)") }
            if (try? SyncCrypto.open(sealed, key: key, user: user, kind: "dictionary")) != nil { fail.append("crypto: opened under another kind (associated data not bound)") }
            if (try? SyncCrypto.open(sealed, key: key, user: "99999999-2222-3333-4444-555555555555", kind: "vocabulary")) != nil { fail.append("crypto: opened under another account") }
            if (try? SyncCrypto.open(sealed, key: SyncCrypto.newKey(), user: user, kind: "vocabulary")) != nil { fail.append("crypto: opened with another key") }
            var bytes = Data(base64Encoded: String(sealed.dropFirst(3)))!
            bytes[bytes.count / 2] ^= 0x01
            if (try? SyncCrypto.open("v1." + bytes.base64EncodedString(), key: key, user: user, kind: "vocabulary")) != nil {
                fail.append("crypto: a changed byte still opened (no authentication)")
            }
        } catch { fail.append("crypto: seal/open threw \(error)") }
        // Recovery key.
        let rk = SyncCrypto.recoveryKey(key)
        r["recovery_key_groups"] = rk.split(separator: "-").count
        let compact = rk.replacingOccurrences(of: "-", with: "")
        if compact.count != 52 || rk.split(separator: "-").count != 13 { fail.append("crypto: recovery key should be 52 characters in 13 groups (\(rk.count))") }
        let typed = rk.lowercased().replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "0", with: "o")
        if let back = SyncCrypto.parseRecoveryKey(typed) {
            if SyncCrypto.keyData(back) != SyncCrypto.keyData(key) { fail.append("crypto: recovery key read back a different key") }
        } else { fail.append("crypto: recovery key typed in lowercase/with spaces/O for 0 wasn't accepted") }
        if SyncCrypto.parseRecoveryKey(String(compact.dropLast())) != nil { fail.append("crypto: a short recovery key was accepted") }
        if SyncCrypto.parseRecoveryKey("hello world") != nil { fail.append("crypto: nonsense accepted as a recovery key") }
        if let check = try? SyncCrypto.keyCheck(key: key, user: user) {
            if !SyncCrypto.verify(key: key, keyCheck: check, user: user) { fail.append("crypto: key check rejects the right key") }
            if SyncCrypto.verify(key: SyncCrypto.newKey(), keyCheck: check, user: user) { fail.append("crypto: key check accepts a wrong key") }
        } else { fail.append("crypto: couldn't make a key check") }
        return (r, fail)
    }

    // MARK: Payload

    static func suite(_ name: String) -> UserDefaults {
        let n = "scribe-st0732-\(name)-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: n)!
        d.removePersistentDomain(forName: n)
        return d
    }

    @MainActor static func payloadCheck() -> ([String: Any], [String]) {
        var r: [String: Any] = [:]
        var fail: [String] = []
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("st0732-pay-\(UUID().uuidString)")
        let tmp2 = FileManager.default.temporaryDirectory.appendingPathComponent("st0732-pay2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp); try? FileManager.default.removeItem(at: tmp2) }
        let d = suite("mac1")
        let markers = ["Quorbleweed", "Snazzlefrump", "Zorvath", "Tamsin Rowe", "Plinkerton"]
        d.set([["quor bull weed", "Quorbleweed"]], forKey: DictionaryReplacements.key)
        d.set(["Snazzlefrump", "Scribe"], forKey: Vocabulary.key)
        let fix = LearnedFix(from: "zorvath", to: "Zorvath", addedReplacement: true, addedWords: ["Zorvath"], isName: true)
        d.set(try? JSONEncoder().encode([fix]), forKey: FixLearner.itemsKey)
        d.set(["zorvath→Zorvath": 2], forKey: FixLearner.countsKey)
        d.set(DictationStyle.polished.rawValue, forKey: DictationStyle.key)
        d.set("Plinkerton", forKey: "toggleLabel")
        d.set(false, forKey: "aiCleanup")

        let store = Store(folder: tmp)
        var person = Person(name: "Tamsin Rowe", colorIndex: 1)
        let vp = SelfTest072.vec(77)
        person.samples = [VoiceSample(vector: vp, meetingID: nil, clusterKey: VoiceEnrollment.tag + "reading", addedAt: Date())]
        store.people = [person]

        // Default: opt-in kinds off.
        let opts = SyncOptions.load(d)
        r["default_options"] = ["people": opts.people, "voiceprints": opts.voiceprints]
        if opts.people || opts.voiceprints { fail.append("payload: People / voice profiles sync must be OFF by default") }
        let model = AccountModel(config: nil, secrets: MemorySecretStore(), defaults: d)
        if model.syncPeople || model.syncVoiceprints { fail.append("payload: account switches for People / voice profiles must start off") }
        let items = SyncPayload.collect(store: store, options: opts, defaults: d)
        r["default_kinds"] = items.keys.map(\.rawValue).sorted()
        if items[.voiceprints] != nil || items[.people] != nil { fail.append("payload: voiceprints/people collected while off") }
        for k in [SyncKind.dictionary, .vocabulary, .learned_fixes, .styles, .settings] where items[k] == nil {
            fail.append("payload: \(k.rawValue) not collected")
        }

        let key = SyncCrypto.newKey()
        let user = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        func leaks(_ rows: [UploadRow]) -> [String] {
            var found: [String] = []
            let json = String(decoding: (try? JSONEncoder().encode(rows)) ?? Data(), as: UTF8.self)
            var blobs = json
            for row in rows { if let b = Data(base64Encoded: String(row.ciphertext.dropFirst(3))) { blobs += String(decoding: b, as: UTF8.self) } }
            for m in markers + ["quor bull weed", "polished", "Polished"] where blobs.localizedCaseInsensitiveContains(m) { found.append(m) }
            // Voiceprint numbers as JSON would print them.
            if blobs.contains(String(format: "%.6g", Double(vp[0]))) && abs(vp[0]) > 0.0001 { found.append("voiceprint number") }
            return found
        }
        do {
            let rows = try SyncPayload.rows(items, key: SymmetricKeyBox(key: key), user: user, deviceID: "device-1")
            r["default_rows"] = rows.map(\.kind)
            if rows.contains(where: { $0.kind == SyncKind.voiceprints.rawValue }) { fail.append("payload: a voiceprints row would be uploaded while off") }
            let l = leaks(rows)
            if !l.isEmpty { fail.append("payload: plaintext in upload: \(l)") }
            if rows.contains(where: { !$0.ciphertext.hasPrefix("v1.") }) { fail.append("payload: a row isn't sealed") }

            // Both switches on: still no plaintext.
            let on = SyncOptions(people: true, voiceprints: true)
            let all = SyncPayload.collect(store: store, options: on, defaults: d)
            let rowsOn = try SyncPayload.rows(all, key: SymmetricKeyBox(key: key), user: user, deviceID: "device-1")
            r["opt_in_rows"] = rowsOn.map(\.kind)
            if !rowsOn.contains(where: { $0.kind == "voiceprints" }) { fail.append("payload: voiceprints row missing with the switch on") }
            let l2 = leaks(rowsOn)
            if !l2.isEmpty { fail.append("payload: plaintext in upload with People/voice on: \(l2)") }

            // "New Mac": open every row and apply.
            let d2 = suite("mac2")
            let store2 = Store(folder: tmp2)
            for row in rowsOn {
                guard let kind = SyncKind(rawValue: row.kind) else { continue }
                let plain = try SyncCrypto.open(row.ciphertext, key: key, user: user, kind: row.kind)
                SyncPayload.apply(kind, data: plain, remoteWins: true, store: store2, defaults: d2)
            }
            let restored: [String: Any] = [
                "dictionary": (d2.array(forKey: DictionaryReplacements.key) as? [[String]])?.first ?? [],
                "vocabulary": d2.stringArray(forKey: Vocabulary.key) ?? [],
                "style": d2.string(forKey: DictationStyle.key) ?? "",
                "toggleLabel": d2.string(forKey: "toggleLabel") ?? "",
                "people": store2.people.map(\.name),
                "samples": store2.people.first?.samples.count ?? 0,
            ]
            r["restored"] = restored
            if (d2.array(forKey: DictionaryReplacements.key) as? [[String]]) != [["quor bull weed", "Quorbleweed"]] { fail.append("payload: Dictionary not restored") }
            if !(d2.stringArray(forKey: Vocabulary.key) ?? []).contains("Snazzlefrump") { fail.append("payload: Vocabulary not restored") }
            let fixes = d2.data(forKey: FixLearner.itemsKey).flatMap { try? JSONDecoder().decode([LearnedFix].self, from: $0) } ?? []
            if fixes.map(\.id) != [fix.id] { fail.append("payload: learned fixes not restored") }
            if d2.string(forKey: DictationStyle.key) != DictationStyle.polished.rawValue { fail.append("payload: Style not restored") }
            if d2.string(forKey: "toggleLabel") != "Plinkerton" || d2.object(forKey: "aiCleanup") as? Bool != false { fail.append("payload: settings not restored") }
            if store2.people.map(\.name) != ["Tamsin Rowe"] || store2.people.first?.samples.count != 1 { fail.append("payload: people/voiceprint not restored") }
            // Merge keeps local words (union) and doesn't duplicate.
            d2.set(["LocalOnlyWord"], forKey: Vocabulary.key)
            for row in rowsOn where row.kind == "vocabulary" {
                SyncPayload.apply(.vocabulary, data: try SyncCrypto.open(row.ciphertext, key: key, user: user, kind: row.kind),
                                  remoteWins: false, store: store2, defaults: d2)
            }
            let merged = d2.stringArray(forKey: Vocabulary.key) ?? []
            r["vocabulary_merged"] = merged
            if !merged.contains("LocalOnlyWord") || !merged.contains("Snazzlefrump") || merged.count != Set(merged.map { $0.lowercased() }).count {
                fail.append("payload: vocabulary merge lost or duplicated words (\(merged))")
            }
        } catch { fail.append("payload: sealing/opening threw \(error)") }
        return (r, fail)
    }

    // MARK: Signed out

    @MainActor static func signedOutCheck() async -> ([String: Any], [String]) {
        var r: [String: Any] = [:]
        var fail: [String] = []
        let d = suite("signedout")
        let secrets = MemorySecretStore()
        let m = AccountModel(config: nil, secrets: secrets, defaults: d)
        r["phase"] = "\(m.phase)"
        if m.phase != .unavailable || m.isAvailable { fail.append("signed out: no backend should mean 'Accounts coming soon' (got \(m.phase))") }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("st0732-so-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = Store(folder: tmp)
        await m.syncNow(store: store)
        await m.sendCode(email: "someone@sample.invalid")
        if m.phase != .unavailable || m.error != nil && m.error != "That doesn't look like an email address." {
            fail.append("signed out: account calls changed something while unavailable (\(m.phase), \(m.error ?? ""))")
        }
        if !secrets.names.isEmpty { fail.append("signed out: touched the secret store (\(secrets.names))") }
        if d.object(forKey: AccountModel.lastSyncedKey) != nil { fail.append("signed out: wrote a sync time") }
        // Placeholders / junk are not a configuration; a real-looking one is.
        let parsed: [(String?, String?, Bool)] = [
            ("YOUR_SUPABASE_URL", "YOUR_SUPABASE_ANON_KEY", false), ("", "", false), (nil, nil, false),
            ("http://abc.supabase.co", "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.x", false),
            ("https://abcdefgh.supabase.co", "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.x", true),
        ]
        for (u, k, want) in parsed where (AccountConfig.parse(url: u, key: k) != nil) != want {
            fail.append("signed out: config parse \(u ?? "nil") → \(!want), want \(want)")
        }
        // The bundled Supabase.plist: placeholders unless the build filled it.
        let bundled = AccountConfig.load(bundle: .main, environment: [:])
        r["bundled_config"] = bundled == nil ? "not configured (placeholders)" : "configured"
        // Configured but signed out: signedOut, still no secrets written, no network until asked.
        let cfg = AccountConfig.parse(url: "https://abcdefgh.supabase.co", key: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.x")!
        let m2 = AccountModel(config: cfg, secrets: MemorySecretStore(), defaults: suite("cfg"))
        r["configured_phase"] = "\(m2.phase)"
        if m2.phase != .signedOut { fail.append("signed out: configured backend without a session should be signedOut (\(m2.phase))") }
        // The app's own data works the same without an account.
        var mt = Meeting(title: "Sample standup", date: Date(), duration: 60, audioFileName: "x.wav")
        mt.status = .done
        store.meetings = [mt]
        store.people = [Person(name: "Wren Ashby")]
        store.save()
        let again = Store(folder: tmp)
        r["store_roundtrip"] = ["meetings": again.meetings.count, "people": again.people.count]
        if again.meetings.count != 1 || again.people.map(\.name) != ["Wren Ashby"] { fail.append("signed out: local data didn't save/load") }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        if files.contains(where: { $0.localizedCaseInsensitiveContains("account") || $0.localizedCaseInsensitiveContains("sync") }) {
            fail.append("signed out: account files written into the app folder (\(files))")
        }
        return (r, fail)
    }

    // MARK: My voice

    @MainActor static func myVoiceCheck() -> ([String: Any], [String]) {
        var r: [String: Any] = [:]
        var fail: [String] = []
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("st0732-mv-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = Store(folder: tmp)
        store.profile.displayName = "Robin Vale"
        let other = SelfTest072.vec(41)
        var someone = Person(name: "Ellis Marrow", colorIndex: 0)
        someone.samples = (0..<5).map { VoiceSample(vector: SelfTest072.jitter(other, $0, 0.05), meetingID: nil,
                                                     clusterKey: VoiceEnrollment.tag + "reading", addedAt: Date()) }
        store.people = [someone]

        var states: [String: Any] = ["not_enrolled": ["enrolled": store.myVoiceEnrolled, "strength": store.myVoiceStrength?.rawValue ?? "none"]]
        if store.myVoiceEnrolled || store.myVoiceStrength != nil { fail.append("my voice: should start not set up") }

        let me = SelfTest072.vec(42)
        let clips = EnrollmentStyle.allCases.enumerated().map { (i, s) in (s, SelfTest072.jitter(me, 100 + i, 0.05)) }
        let id = store.enrollMe(clips: clips)
        states["enrolled"] = ["enrolled": store.myVoiceEnrolled, "strength": store.myVoiceStrength?.rawValue ?? "none",
                              "clips": store.myVoiceClipCount, "name": store.myPerson?.name ?? ""]
        if id == nil || store.profile.myPersonID != id || !store.myVoiceEnrolled { fail.append("my voice: enrollment didn't set up your voice") }
        if store.myVoiceStrength != .good { fail.append("my voice: a fresh enrollment should be Good (got \(store.myVoiceStrength?.rawValue ?? "nil"))") }
        if store.myVoiceClipCount != 6 { fail.append("my voice: expected 6 clips, got \(store.myVoiceClipCount)") }
        if store.myPerson?.name != "Robin Vale" { fail.append("my voice: your library entry should use your Profile name") }

        // Train it more.
        _ = store.trainMyVoice(embedding: SelfTest072.jitter(me, 200, 0.05))
        if store.myVoiceClipCount != 7 { fail.append("my voice: Train it more didn't add a clip (\(store.myVoiceClipCount))") }
        for k in 0..<(MyVoice.maxExtraClips + 3) { _ = store.trainMyVoice(embedding: SelfTest072.jitter(me, 300 + k, 0.05)) }
        if store.myVoiceClipCount != 6 + MyVoice.maxExtraClips { fail.append("my voice: extra clips not capped at \(MyVoice.maxExtraClips)") }

        // Test it.
        let mine = store.testMyVoice(embedding: SelfTest072.jitter(me, 999, 0.05))
        let theirs = store.testMyVoice(embedding: SelfTest072.jitter(other, 998, 0.05))
        r["test_me"] = [mine?.headline ?? "nil", mine?.detail ?? ""]
        r["test_other"] = [theirs?.headline ?? "nil", theirs?.detail ?? ""]
        if mine?.matched != true || mine?.headline != "Matched you — strong match" { fail.append("my voice: your own voice should be a strong match (\(mine?.headline ?? "nil"))") }
        if theirs?.matched != false || theirs?.headline.hasPrefix("Sounded more like Ellis Marrow") != true {
            fail.append("my voice: someone else's voice should not match you (\(theirs?.headline ?? "nil"))")
        }
        // Thresholds in plain words.
        let words = [(Float(0.80), "Matched you — strong match", true), (0.60, "Matched you — good match", true),
                     (MyVoice.threshold + 0.01, "Matched you — weak match", true), (MyVoice.threshold - 0.05, "Didn't match you", false)]
        for (score, want, ok) in words {
            let v = MyVoice.verdict(score: score)
            if v.headline != want || v.matched != ok { fail.append("my voice: score \(score) → \(v.headline)") }
            if !v.detail.contains(String(format: "%.2f", score)) || !v.detail.contains(String(format: "%.2f", MyVoice.threshold)) {
                fail.append("my voice: the detail must show the score and the threshold (\(v.detail))")
            }
        }

        // Re-record from scratch: meeting samples and extra clips go; 6 new clips.
        if let i = store.people.firstIndex(where: { $0.id == id }) {
            store.people[i].samples.append(VoiceSample(vector: me, meetingID: UUID(), clusterKey: "S1", addedAt: Date()))
        }
        _ = store.enrollMe(clips: clips, fromScratch: true)
        states["re_recorded"] = ["clips": store.myVoiceClipCount, "samples": store.myPerson?.samples.count ?? 0]
        if store.myPerson?.samples.count != 6 || store.profile.myPersonID != id { fail.append("my voice: Re-record from scratch should leave exactly the 6 new clips on the same person") }

        // Delete my voice → back to the setup prompt; the person (name in meetings) stays.
        store.deleteMyVoice()
        states["deleted"] = ["enrolled": store.myVoiceEnrolled, "person_kept": store.myPerson != nil]
        if store.myVoiceEnrolled || store.myPerson?.samples.isEmpty != true { fail.append("my voice: Delete my voice left samples") }
        // Survives a reload (profile.json + voices.json).
        _ = store.enrollMe(clips: clips)
        let again = Store(folder: tmp)
        if !again.myVoiceEnrolled || again.profile.myPersonID != id { fail.append("my voice: setup not saved to disk") }

        // Both states render (Settings card), with the right words.
        func renders(_ s: Store) -> CGSize {
            let host = NSHostingView(rootView: MyVoiceCard().environmentObject(s).frame(width: 600))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize
        }
        let empty = Store(folder: tmp.appendingPathComponent("empty"))
        let szNot = renders(empty), szOn = renders(again)
        states["render_heights"] = ["not_enrolled": szNot.height, "enrolled": szOn.height]
        if szNot.height < 20 || szOn.height <= szNot.height { fail.append("my voice: card heights look wrong (not \(szNot.height), enrolled \(szOn.height))") }
        r["states"] = states
        return (r, fail)
    }

    // MARK: Meetings dashboard + navigation

    @MainActor final class NavBox: ObservableObject {
        @Published var selected: UUID?
        @Published var query = ""
    }

    struct Harness: View {
        @ObservedObject var box: NavBox
        var body: some View { MeetingsPage(selected: $box.selected, query: $box.query) }
    }

    @MainActor static func sampleMeetings(now: Date, cal: Calendar) -> (meetings: [Meeting], people: [Person]) {
        let a = Person(name: "Ada Fenwick", colorIndex: 0), b = Person(name: "Bram Oakes", colorIndex: 1)
        let week = cal.dateInterval(of: .weekOfYear, for: now)!.start
        func meeting(_ title: String, _ date: Date, _ dur: Double, _ clusters: [SpeakerCluster], items: [Bool] = []) -> Meeting {
            var m = Meeting(title: title, date: date, duration: dur, audioFileName: "none.wav")
            m.status = .done
            m.clusters = clusters
            m.utterances = [Utterance(start: 0, end: 5, speakerKey: clusters.first?.key ?? "S1", text: "Sample line for \(title).")]
            if !items.isEmpty {
                m.notes = MeetingNotes(summary: "Sample.", keyPoints: [],
                                       actionItems: items.enumerated().map { ActionItem(task: "Task \($0.offset)", owner: "Ada", done: $0.element) },
                                       method: .rules, createdAt: now, seconds: 0)
            }
            return m
        }
        let m1 = meeting("Design sync", week.addingTimeInterval(3600), 1800,
                         [SpeakerCluster(key: "S1", talkSeconds: 900, centroid: [], spanEmbeddings: [], personID: a.id),
                          SpeakerCluster(key: "S2", talkSeconds: 600, centroid: [], spanEmbeddings: [], personID: b.id),
                          SpeakerCluster(key: "S3", talkSeconds: 200, centroid: [], spanEmbeddings: [])],
                         items: [false, false, true])
        let m2 = meeting("Budget check", week.addingTimeInterval(7200), 1800,
                         [SpeakerCluster(key: "S1", talkSeconds: 1000, centroid: [], spanEmbeddings: [], personID: b.id),
                          SpeakerCluster(key: "S2", talkSeconds: 300, centroid: [], spanEmbeddings: [])],
                         items: [false])
        let old = meeting("Old kickoff", week.addingTimeInterval(-3 * 86400), 5400,
                          [SpeakerCluster(key: "S1", talkSeconds: 5000, centroid: [], spanEmbeddings: [], personID: a.id)],
                          items: [false])
        return ([m1, m2, old], [a, b])
    }

    @MainActor static func meetingsCheck() async -> ([String: Any], [String]) {
        var r: [String: Any] = [:]
        var fail: [String] = []
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.firstWeekday = 1
        let now = cal.date(from: DateComponents(year: 2026, month: 3, day: 12, hour: 15))!   // a Thursday
        let (meetings, people) = sampleMeetings(now: now, cal: cal)
        let dash = MeetingsDashboard.make(meetings: meetings, people: people, now: now, calendar: cal)
        r["dashboard"] = ["meetings_this_week": dash.meetingsThisWeek, "hours": dash.hoursText, "open_items": dash.openActionItems,
                          "top": dash.topSpeakers.map { "\($0.name) \(Int($0.seconds))s" }, "unnamed": dash.unnamedSpeakers]
        if dash.meetingsThisWeek != 2 { fail.append("meetings: this week should be 2 (got \(dash.meetingsThisWeek))") }
        if abs(dash.secondsThisWeek - 3600) > 0.1 || dash.hoursText != "1.0" { fail.append("meetings: hours this week should be 1.0 (got \(dash.hoursText))") }
        if dash.openActionItems != 4 { fail.append("meetings: open action items should be 4 (got \(dash.openActionItems))") }
        if dash.topSpeakers.map(\.name) != ["Bram Oakes", "Ada Fenwick"] || dash.topSpeakers.first?.seconds != 1600 {
            fail.append("meetings: top speakers this week wrong (\(dash.topSpeakers))")
        }
        if dash.unnamedSpeakers != 2 || dash.firstUnnamedMeeting != meetings[1].id { fail.append("meetings: unnamed voices should be 2, newest first") }
        let dismissed = MeetingsDashboard.make(meetings: meetings, people: people, now: now, calendar: cal,
                                               dismissed: [meetings[1].id.uuidString + "/S2"])
        if dismissed.unnamedSpeakers != 1 { fail.append("meetings: a dismissed voice still counted") }
        let empty = MeetingsDashboard.make(meetings: [], people: [], now: now, calendar: cal)
        if empty != MeetingsDashboard() || empty.hoursText != "0" { fail.append("meetings: empty store should show zeros") }

        // Keys (pure rule).
        let keys: [(String, Bool, Bool)] = [
            ("esc", MeetingsNav.isBackKey(keyCode: 53, characters: "\u{1b}", modifiers: [], firstResponder: nil), true),
            ("esc in text", MeetingsNav.isBackKey(keyCode: 53, characters: "\u{1b}", modifiers: [], firstResponder: NSTextView()), false),
            ("cmd [", MeetingsNav.isBackKey(keyCode: 33, characters: "[", modifiers: [.command], firstResponder: nil), true),
            ("cmd shift [", MeetingsNav.isBackKey(keyCode: 33, characters: "[", modifiers: [.command, .shift], firstResponder: nil), false),
            ("plain [", MeetingsNav.isBackKey(keyCode: 33, characters: "[", modifiers: [], firstResponder: nil), false),
        ]
        var kr: [String: Bool] = [:]
        for (n, got, want) in keys { kr[n] = got; if got != want { fail.append("meetings: key \(n) → \(got), want \(want)") } }
        r["keys"] = kr

        // Live view: dashboard → open → pull → dashboard, then Esc / ⌘[.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("st0732-mt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = Store(folder: tmp)
        store.engineReady = true
        store.people = people
        store.meetings = meetings
        let box = NavBox()
        let view = Harness(box: box).environmentObject(store).environmentObject(AppModel.shared)
            .frame(width: 1000, height: 700)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: view)
        w.orderFrontRegardless()
        defer { w.close() }
        func settle(_ s: Double = 0.6) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        await settle()
        var nav: [String: Any] = ["dashboard_probes": MeetingBackProbeView.attached.count]
        if !MeetingBackProbeView.attached.isEmpty { fail.append("meetings: a meeting is open before tapping one") }

        // Tap a row = what its button does: select the meeting.
        box.selected = meetings[0].id
        await settle(1.0)
        guard let probe = MeetingBackProbeView.attached.first(where: { $0.window === w }) else {
            fail.append("meetings: opening a meeting didn't show its detail")
            r["nav"] = nav
            return (r, fail)
        }
        nav["detail_open"] = true
        nav["scroll_view_found"] = probe.scrollView != nil
        guard let sv = probe.scrollView else {
            fail.append("meetings: the detail's scroll view wasn't found (overscroll can't be watched)")
            r["nav"] = nav
            return (r, fail)
        }
        let clip = sv.contentView
        nav["clip_flipped"] = clip.isFlipped
        nav["rest_pull"] = probe.pull
        if probe.pull != 0 { fail.append("meetings: the detail reads as pulled while at rest (\(probe.pull))") }
        // Synthetic bounds changes aren't scroll-wheel events; let them count here.
        MeetingBackProbeView.requireScrollEvent = false
        defer { MeetingBackProbeView.requireScrollEvent = true }
        func setPull(_ p: CGFloat) {
            if clip.isFlipped {
                clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: -sv.contentInsets.top - p))
            } else if let doc = sv.documentView {
                clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: doc.frame.maxY + sv.contentInsets.top + p - clip.bounds.height))
            }
        }
        setPull(20)
        nav["small_pull"] = probe.pull
        if box.selected == nil { fail.append("meetings: a small pull (20 pt) went back") }
        setPull(MeetingsNav.pullToReturn + 24)
        nav["big_pull"] = probe.pull
        if box.selected != nil { fail.append("meetings: pulling \(Int(MeetingsNav.pullToReturn + 24)) pt past the top didn't return to the dashboard") }
        await settle()
        nav["after_pull_probes"] = MeetingBackProbeView.attached.filter { $0.window === w }.count
        if MeetingBackProbeView.attached.contains(where: { $0.window === w }) { fail.append("meetings: detail still showing after the pull") }

        // Esc and ⌘[.
        for (name, chars, mods, code) in [("esc", "\u{1b}", NSEvent.ModifierFlags(), UInt16(53)), ("cmd [", "[", NSEvent.ModifierFlags.command, UInt16(33))] {
            box.selected = meetings[1].id
            await settle(1.0)
            guard let p = MeetingBackProbeView.attached.first(where: { $0.window === w }) else {
                fail.append("meetings: detail didn't reopen for the \(name) check"); continue
            }
            w.makeFirstResponder(nil)
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
                                     windowNumber: w.windowNumber, context: nil, characters: chars,
                                     charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)
            let used = e.map { p.handleKey($0) } ?? false
            nav[name] = used && box.selected == nil
            if !used || box.selected != nil { fail.append("meetings: \(name) didn't go back to the dashboard") }
            await settle(0.4)
        }
        r["nav"] = nav
        return (r, fail)
    }
}
