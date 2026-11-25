// PeopleView.swift
// The voice library: everyone the app has learned, and how much it knows about each voice.
// 0.7 "Night Sky": a two-column grid of cards with a voice print (capsule bars), plus a dashed
// "Add someone" tile. Add person opens the guided enrollment sheet (VoiceEnrollmentView).

import SwiftUI

struct PeopleView: View {
    @EnvironmentObject var store: Store
    @Binding var query: String
    var searchFocus: Int = 0
    @State private var renaming: Person?
    @State private var newName = ""
    @State private var adding = false
    @State private var menuFor: UUID?

    init(query: Binding<String> = .constant(""), searchFocus: Int = 0) {
        _query = query
        self.searchFocus = searchFocus
    }

    private var shown: [Person] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return store.people }
        return store.people.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "People",
                       subtitle: "\(store.people.count) voice\(store.people.count == 1 ? "" : "s") Scribe knows") {
                NightSearchField(text: $query, prompt: "Find a person", width: 200, focusRequest: searchFocus)
                Button { adding = true } label: { Label("Add person", systemImage: "plus") }
                    .buttonStyle(.nightPrimary)
                    .help("Teach Scribe someone's voice: they read six short lines out loud")
            }
            .padding(.leading, Night.gutterLeading)
            .padding(.trailing, Night.gutterTrailing)
            if store.people.isEmpty {
                CozyEmptyState(symbol: "person.2",
                               title: "No one here yet",
                               message: "Teach Scribe a voice in about a minute, or name a speaker after a meeting.") {
                    Button { adding = true } label: { Label("Add person", systemImage: "plus") }
                        .buttonStyle(.nightPrimary)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 420), spacing: Night.cardGap)],
                              alignment: .leading, spacing: Night.cardGap) {
                        ForEach(shown) { p in card(p) }
                        if query.isEmpty { addTile }
                    }
                    .padding(.leading, Night.gutterLeading)
                    .padding(.trailing, Night.gutterTrailing)
                    .padding(.bottom, 32)
                }
                .scrollIndicators(.never)
            }
        }
        .sheet(isPresented: $adding) {
            VoiceEnrollmentView().environmentObject(store)
        }
        .sheet(item: $renaming) { p in
            VStack(alignment: .leading, spacing: 12) {
                Text("Rename \(p.name)").font(.nightTitle)
                NightField(placeholder: "Name", text: $newName) { store.rename(personID: p.id, to: newName); renaming = nil }
                HStack {
                    Spacer()
                    Button("Cancel") { renaming = nil }.buttonStyle(.nightGhost)
                    Button("Save") { store.rename(personID: p.id, to: newName); renaming = nil }
                        .buttonStyle(.nightPrimary)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(22).frame(width: 320)
            .background(Night.raised)
        }
    }

    private func card(_ p: Person) -> some View {
        let color = Palette.color(p.colorIndex)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Avatar(name: p.name, color: color, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name).font(.nightHeadline).foregroundStyle(Night.text).lineLimit(1)
                    Text("\(p.meetingCount) meeting\(p.meetingCount == 1 ? "" : "s") · \(p.samples.count) sample\(p.samples.count == 1 ? "" : "s")")
                        .font(.nightMeta).foregroundStyle(Night.text3)
                }
                Spacer(minLength: 0)
                Button { menuFor = p.id } label: { Image(systemName: "ellipsis") }
                    .buttonStyle(NightIconButtonStyle(size: 28))
                    .accessibilityLabel("More for \(p.name)")
                    .popover(isPresented: Binding(get: { menuFor == p.id }, set: { if !$0 { menuFor = nil } }), arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 2) {
                            Button { menuFor = nil; newName = p.name; renaming = p } label: {
                                Label("Rename…", systemImage: "pencil").frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(MenuRowStyle())
                            Button { menuFor = nil; store.deletePerson(p.id) } label: {
                                Label("Delete", systemImage: "trash").foregroundStyle(Night.live)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(MenuRowStyle())
                        }
                        .padding(6).frame(width: 180).background(Night.raised)
                    }
            }
            HStack(spacing: 10) {
                CapsuleBars(levels: CapsuleBars.wave(9, seed: CapsuleBars.seed(p.name), floor: 0.25),
                            barWidth: 4, spacing: 3, maxLength: 22, style: .gradient)
                Spacer(minLength: 0)
                strength(p)
                Text("Voice print").font(.nightMeta).foregroundStyle(Night.text3)
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Night.well))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Night.line, lineWidth: 1))
        }
        .nightCard(padding: 18)
    }

    /// A rough "how well do we know this voice" meter: more meetings = steadier matching.
    private func strength(_ p: Person) -> some View {
        let n = min(max(p.meetingCount, p.samples.isEmpty ? 0 : 1), 5)
        return HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { k in
                Capsule().fill(k < n ? AnyShapeStyle(Night.accent) : AnyShapeStyle(Night.line2)).frame(width: 4, height: 4)
            }
        }
        .help("Voice library strength (fills up after about 5 meetings)")
        .accessibilityLabel("Voice strength \(n) of 5")
    }

    private var addTile: some View {
        Button { adding = true } label: {
            VStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Night.accent)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Night.accentSoft))
                Text("Add someone you meet with").font(.nightMeta).foregroundStyle(Night.text3)
            }
            .frame(maxWidth: .infinity, minHeight: 128)
            .background(RoundedRectangle(cornerRadius: Night.rCard, style: .continuous)
                .strokeBorder(Night.line2, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
