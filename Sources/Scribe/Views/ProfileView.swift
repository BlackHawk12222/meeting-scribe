// ProfileView.swift
// 0.7.3 Profile page (the round avatar at the bottom of the rail). Poster style:
//  • who you are: a big avatar (photo or initial), display name, "Member since", photo buttons.
//    Name and photo stay on this Mac (Store+Profile.swift), never uploaded.
//  • your numbers: four poster tiles: words dictated (all time), streak, words per minute, meetings.
//  • shortcuts into Settings: Shortcut & style, My voice, Appearance, Updates.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The avatar used in the rail and on the Profile page: the photo, else the name's first letter on
/// the indigo poster color, else a person symbol.
struct ProfileAvatar: View {
    @EnvironmentObject var store: Store
    var size: CGFloat
    var body: some View {
        ZStack {
            if let img = store.profilePhoto {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else if let i = store.profile.initial {
                Circle().fill(Night.posterIndigo)
                Text(i).font(.system(size: size * 0.44, weight: .semibold)).foregroundStyle(Color.white)
            } else {
                Circle().fill(Night.selected)
                Image(systemName: "person.fill").font(.system(size: size * 0.42)).foregroundStyle(Night.text2)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Night.line2, lineWidth: 1))
        .accessibilityHidden(true)
    }
}

struct ProfileView: View {
    @EnvironmentObject var store: Store
    /// Opens a Settings pane in the main window.
    var openSettings: (SettingsPane) -> Void = { _ in }
    @State private var name = ""
    @State private var enrolling = false
    @AppStorage(DictationStyle.key) private var styleRaw = DictationStyle.current.rawValue
    @AppStorage(AppearanceChoice.key) private var appearance = AppearanceChoice.system.rawValue

    var body: some View {
        let stats = store.dictationStats
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                tiles(stats).padding(.top, 28)
                HairlineHeader(title: "Settings").padding(.top, 30).padding(.bottom, 4)
                links
                Text("Your name and photo are stored only on this Mac.")
                    .font(.nightMeta).foregroundStyle(Night.text3)
                    .padding(.top, 18)
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.horizontal, Night.gutterLeading)
            .padding(.top, 24)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .onAppear { name = store.profile.displayName }
        .sheet(isPresented: $enrolling) { VoiceEnrollmentView().environmentObject(store) }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 20) {
            ProfileAvatar(size: 84)
            VStack(alignment: .leading, spacing: 8) {
                Text(store.profile.shownName).font(.pageTitle).tracking(-0.4).foregroundStyle(Night.text).lineLimit(1)
                Text(memberSince).font(.nightSecondary).foregroundStyle(Night.text2)
                HStack(spacing: 8) {
                    NightField(placeholder: "Display name", text: $name, onSubmit: { store.setDisplayName(name) })
                        .frame(width: 220)
                        .onChange(of: name) { _, v in store.setDisplayName(v) }
                        .accessibilityLabel("Display name")
                    Button(store.profilePhoto == nil ? "Add photo…" : "Change photo…", action: pickPhoto)
                        .buttonStyle(NightButtonStyle(kind: .secondary))
                    if store.profilePhoto != nil {
                        Button("Remove") { store.removeProfilePhoto() }
                            .buttonStyle(NightButtonStyle(kind: .ghost))
                    }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
    }

    private var memberSince: String {
        guard let d = store.profile.memberSince else { return "Scribe member" }
        return "Member since " + d.formatted(.dateTime.month(.wide).year())
    }

    private func pickPhoto() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.allowsMultipleSelection = false
        p.canChooseDirectories = false
        p.prompt = "Use photo"
        p.message = "Pick a photo. Scribe keeps a small copy on this Mac only."
        if p.runModal() == .OK, let url = p.url { store.setProfilePhoto(from: url) }
    }

    // MARK: Tiles

    private func tiles(_ stats: DictationStats) -> some View {
        let words = store.totalWordsDictated
        let streak = stats.streak
        let wpm = stats.wordsPerMinute
        let meetings = store.meetings.count
        let h = Night.tileHeightCompact
        return HStack(spacing: Night.cardGap) {
            PosterTile(color: Night.posterIndigo, label: "Words dictated", value: Self.short(words),
                       caption: "all time", height: h, valueSize: 46) { EmptyView() }
            PosterTile(color: Night.posterCoral, label: "Streak", value: "\(streak)",
                       caption: streak == 1 ? "day in a row" : "days in a row", height: h, valueSize: 46) { EmptyView() }
            PosterTile(color: Night.posterGreen, label: "Speed", value: wpm.map { "\($0)" } ?? "–",
                       caption: "words per minute", height: h, valueSize: 46) { EmptyView() }
            PosterTile(color: Night.posterBlack, label: "Meetings", value: "\(meetings)",
                       caption: meetings == 1 ? "meeting recorded" : "meetings recorded", height: h, valueSize: 46,
                       outlined: true) { EmptyView() }
        }
    }

    /// 1,234 / 12.3k / 1.2M.
    static func short(_ n: Int) -> String {
        if n < 10_000 { return n.formatted() }
        if n < 1_000_000 { return String(format: "%.1fk", Double(n) / 1000).replacingOccurrences(of: ".0k", with: "k") }
        return String(format: "%.1fM", Double(n) / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
    }

    // MARK: Links

    private var links: some View {
        let style = DictationStyle(rawValue: styleRaw)?.title ?? DictationStyle.current.title
        let look = (AppearanceChoice(rawValue: appearance) ?? .system).title
        return VStack(spacing: 0) {
            ProfileLinkRow(symbol: "keyboard", title: "Shortcut & style",
                           detail: "Hold \(DictationSettings.holdKey.shortName) · \(style)") { openSettings(.dictation) }
            ProfileLinkRow(symbol: "waveform.and.person.filled", title: "My voice",
                           detail: "Teach Scribe your voice so meetings know it's you") { enrolling = true }
            ProfileLinkRow(symbol: "circle.lefthalf.filled", title: "Appearance", detail: look) { openSettings(.general) }
            ProfileLinkRow(symbol: "arrow.down.circle", title: "Updates",
                           detail: "Scribe \(Updater.currentVersion)", last: true) { openSettings(.updates) }
        }
    }
}

/// A settings shortcut row: icon, title, detail, chevron; hairline under it.
struct ProfileLinkRow: View {
    var symbol: String
    var title: String
    var detail: String
    var last = false
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(Night.text2).frame(width: 22)
                Text(title).font(.system(size: 14.5, weight: .medium)).foregroundStyle(Night.text)
                Spacer(minLength: 12)
                Text(detail).font(.nightSecondary).foregroundStyle(Night.text3).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Night.text3)
            }
            .padding(.horizontal, 10)
            .frame(height: 46)
            .background(RoundedRectangle(cornerRadius: Night.rRow, style: .continuous).fill(hover ? Night.hover : .clear))
            .overlay(alignment: .bottom) { if !last { NightDivider() } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel("\(title), \(detail)")
    }
}
