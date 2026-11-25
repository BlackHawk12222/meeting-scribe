// CreditsView.swift
// 0.7.3.1: Settings › General › Credits & licenses. Lists every speech model, Swift package
// (every pin in Package.resolved), font and design credit Scribe uses, with its license, a
// link, and the full license text. The list and the texts are bundled in
// Contents/Resources/Licenses (licenses.json + the .txt/.md files); build.sh also copies the
// build's Package.resolved there so the exact resolved versions show. scripts/check_licenses.py
// fails the build if a resolved package has no entry. Privacy Policy and Terms of Use are
// placeholders ("Coming soon") until their pages exist.

import SwiftUI
import AppKit

struct LicenseEntry: Codable, Identifiable, Hashable {
    var id: String
    var pin: String?
    var kind: String
    var name: String
    var version: String?
    var what: String
    var license: String
    var copyright: String?
    var url: String?
    var extraUrl: String?
    var file: String?
    var notices: [String]?
}

enum LicenseCatalog {
    private struct Manifest: Codable { var schema: Int; var entries: [LicenseEntry] }

    /// Contents/Resources/Licenses in the app bundle.
    static var folder: URL? {
        Bundle.main.url(forResource: "Licenses", withExtension: nil)
            ?? Bundle.main.resourceURL.map { $0.appendingPathComponent("Licenses", isDirectory: true) }
    }

    static func entries(in folder: URL? = LicenseCatalog.folder) -> [LicenseEntry] {
        guard let folder, let data = try? Data(contentsOf: folder.appendingPathComponent("licenses.json")),
              let m = try? JSONDecoder().decode(Manifest.self, from: data) else { return [] }
        return m.entries
    }

    static func text(_ file: String, in folder: URL? = LicenseCatalog.folder) -> String? {
        guard let folder else { return nil }
        return (try? String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// identity → version from the Package.resolved build.sh copies next to the licenses.
    static func resolvedPins(in folder: URL? = LicenseCatalog.folder) -> [String: String] {
        guard let folder, let data = try? Data(contentsOf: folder.appendingPathComponent("Package.resolved")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        let pins = (obj["pins"] as? [[String: Any]]) ?? ((obj["object"] as? [String: Any])?["pins"] as? [[String: Any]]) ?? []
        var out: [String: String] = [:]
        for p in pins {
            let id = (p["identity"] as? String) ?? ((p["package"] as? String)?.lowercased() ?? "")
            let state = p["state"] as? [String: Any]
            let v = (state?["version"] as? String) ?? (state?["revision"] as? String).map { String($0.prefix(10)) } ?? "?"
            if !id.isEmpty { out[id] = v }
        }
        return out
    }

    struct CreditGroup: Hashable { var title: String; var kinds: Set<String> }
    static let groups: [CreditGroup] = [
        CreditGroup(title: "Speech models", kinds: ["model"]),
        CreditGroup(title: "Open-source code", kinds: ["package", "binary"]),
        CreditGroup(title: "Fonts and design", kinds: ["font", "design"]),
        CreditGroup(title: "Other", kinds: ["other"]),
    ]
}

/// Privacy Policy and Terms of Use. No pages yet: both show "Coming soon" until a URL is set here.
enum LegalLinks {
    static let privacyURL: URL? = nil
    static let termsURL: URL? = nil
}

/// The Credits & licenses page (a sub-page of Settings › General).
struct CreditsPage: View {
    var back: (() -> Void)? = nil
    /// Snapshots: open these entries' license text.
    var expanded: Set<String> = []

    private var entries: [LicenseEntry] { LicenseCatalog.entries() }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            if let back {
                Button { back() } label: { Label("General", systemImage: "chevron.left") }
                    .buttonStyle(.nightGhost)
                    .padding(.top, -14)
            }
            SettingsCard(title: "Legal") {
                LegalRow(title: "Privacy Policy", url: LegalLinks.privacyURL)
                NightDivider()
                LegalRow(title: "Terms of Use", url: LegalLinks.termsURL)
            }
            CreditsList(entries: entries, pins: LicenseCatalog.resolvedPins(), expanded: expanded)
            Text("The full license texts also ship inside the app, in Scribe › Contents › Resources › Licenses.")
                .font(.nightMeta).foregroundStyle(Night.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct LegalRow: View {
    var title: String
    var url: URL?
    var body: some View {
        SettingRow(title: title, detail: url == nil ? "Not published yet" : nil) {
            if let url {
                Link("Open", destination: url).font(.nightButton).foregroundStyle(Night.accent)
            } else {
                Text("Coming soon")
                    .font(.nightMeta).foregroundStyle(Night.text2)
                    .padding(.horizontal, 10)
                    .frame(height: Night.controlHeightSmall)
                    .background(Capsule().fill(Night.well))
                    .overlay(Capsule().strokeBorder(Night.line, lineWidth: 1))
            }
        }
    }
}

/// All credits, grouped (models, code, fonts/design, other).
struct CreditsList: View {
    var entries: [LicenseEntry]
    var pins: [String: String] = [:]
    var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            if entries.isEmpty {
                SettingsCard(title: "Credits & licenses") {
                    CardNote(text: "The license list is missing from this copy of Scribe. Reinstall it from the Releases page.")
                }
            }
            ForEach(LicenseCatalog.groups, id: \.title) { g in
                let rows = entries.filter { g.kinds.contains($0.kind) }
                if !rows.isEmpty {
                    SettingsCard(title: g.title) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, e in
                            if i > 0 { NightDivider() }
                            CreditRow(entry: e, version: e.version ?? e.pin.flatMap { pins[$0] },
                                      showText: expanded.contains(e.id))
                        }
                    }
                }
            }
        }
    }
}

struct CreditRow: View {
    var entry: LicenseEntry
    var version: String?
    @State private var showText: Bool
    @State private var openNotice: String?

    init(entry: LicenseEntry, version: String?, showText: Bool = false) {
        self.entry = entry
        self.version = version
        _showText = State(initialValue: showText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.name).font(.nightHeadline).foregroundStyle(Night.text)
                if let version {
                    Text(version).font(.nightMeta).foregroundStyle(Night.text3).monospacedDigit()
                }
                Spacer(minLength: 8)
                Text(entry.license).font(.nightMeta).foregroundStyle(Night.text2)
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(Capsule().fill(Night.well))
            }
            Text(entry.what).font(.nightSecondary).foregroundStyle(Night.text2)
                .fixedSize(horizontal: false, vertical: true)
            if let c = entry.copyright {
                Text(c).font(.nightMeta).foregroundStyle(Night.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 14) {
                if let s = entry.url, let u = URL(string: s) {
                    Link(destination: u) { Text(entry.kind == "model" ? "Model page" : "Project page").lineLimit(1) }
                        .font(.nightMeta).foregroundStyle(Night.accent).help(s)
                }
                if let s = entry.extraUrl, let u = URL(string: s) {
                    Link(destination: u) { Text("Core ML version").lineLimit(1) }
                        .font(.nightMeta).foregroundStyle(Night.accent).help(s)
                }
                Spacer(minLength: 0)
                if entry.file != nil {
                    Button(showText ? "Hide license" : "View license") { withAnimation(Night.base) { showText.toggle() } }
                        .buttonStyle(.nightGhost)
                }
            }
            if showText, let f = entry.file {
                LicenseTextBox(text: LicenseCatalog.text(f) ?? "License text not found in this copy of Scribe (\(f)).")
            }
            if let notices = entry.notices, !notices.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Third-party notices included in \(entry.name)")
                        .font(.nightMeta).foregroundStyle(Night.text3).padding(.top, 4)
                    ForEach(notices, id: \.self) { n in
                        Button {
                            withAnimation(Night.base) { openNotice = openNotice == n ? nil : n }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: openNotice == n ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                Text(noticeName(n)).font(.nightMeta)
                            }
                            .foregroundStyle(Night.text2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if openNotice == n {
                            LicenseTextBox(text: LicenseCatalog.text(n) ?? "Notice not found (\(n)).")
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private func noticeName(_ path: String) -> String {
        (path as NSString).lastPathComponent
            .replacingOccurrences(of: "-LICENSE.md", with: "")
            .replacingOccurrences(of: "-LICENSE", with: "")
            .replacingOccurrences(of: "-NOTICE", with: " notice")
            .replacingOccurrences(of: "-", with: " ")
    }
}

/// A full license text in a scrolling, selectable well.
struct LicenseTextBox: View {
    var text: String
    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Night.text2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .frame(height: 220)
        .background(RoundedRectangle(cornerRadius: Night.rControl, style: .continuous).fill(Night.well))
        .overlay(RoundedRectangle(cornerRadius: Night.rControl, style: .continuous).strokeBorder(Night.line, lineWidth: 1))
    }
}
