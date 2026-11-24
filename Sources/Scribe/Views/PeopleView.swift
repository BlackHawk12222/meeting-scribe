// PeopleView.swift
// The voice library: everyone the app has learned, and how much it knows about each voice.

import SwiftUI

struct PeopleView: View {
    @EnvironmentObject var store: Store
    @State private var renaming: Person?
    @State private var newName = ""
    @State private var adding = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(title: "People",
                           subtitle: "Add someone by voice, or name a speaker in a meeting. Each meeting you confirm helps Scribe recognize their voice a little better.") {
                    headerActions
                }
                if store.people.isEmpty {
                    CozyEmptyState(symbol: "person.2",
                                   title: "No one here yet",
                                   message: "Choose Add person to teach Scribe a voice in about a minute, or click a speaker's name after a meeting and choose “New person…”.")
                        .frame(minHeight: 300)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(store.people.enumerated()), id: \.element.id) { i, p in
                            if i > 0 { Divider().overlay(Warm.hairline).padding(.leading, 56) }
                            row(p)
                        }
                    }
                    .scribeCard(padding: 4)
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 28)
            .padding(.bottom, 40)
            .frame(maxWidth: Brand.readingWidth + 80, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $adding) {
            VoiceEnrollmentView().environmentObject(store)
        }
        .sheet(item: $renaming) { p in
            VStack(alignment: .leading, spacing: 12) {
                Text("Rename \(p.name)").font(.headline)
                TextField("Name", text: $newName)
                HStack {
                    Spacer()
                    Button("Cancel") { renaming = nil }
                    Button("Save") { store.rename(personID: p.id, to: newName); renaming = nil }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding().frame(width: 300)
        }
    }

    /// Buttons at the top right of the page: guided voice enrollment ("Add person").
    @ViewBuilder private var headerActions: some View {
        Button { adding = true } label: {
            Label("Add person", systemImage: "person.crop.circle.badge.plus")
        }
        .scribeButton(prominent: true)
        .controlSize(.large)
        .help("Teach Scribe someone's voice: they read six short lines out loud")
    }

    private func row(_ p: Person) -> some View {
        let color = Palette.color(p.colorIndex)
        return HStack(spacing: 14) {
            Text(String(p.name.prefix(1)).uppercased())
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(color.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).font(.system(size: 14, weight: .semibold))
                Text("\(p.samples.count) voice samples · \(p.meetingCount) meeting\(p.meetingCount == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            // A rough "how well do we know this voice" meter: more meetings = steadier matching.
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { k in
                    Capsule().fill(k < min(p.meetingCount, 5) ? AnyShapeStyle(color.opacity(0.75)) : AnyShapeStyle(Warm.well))
                        .frame(width: 10, height: 5)
                }
            }
            .help("Voice library strength (fills up after about 5 meetings)")
            .accessibilityLabel("Voice strength \(min(p.meetingCount, 5)) of 5")
            Menu {
                Button("Rename…") { newName = p.name; renaming = p }
                Button("Delete", role: .destructive) { store.deletePerson(p.id) }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
