// PeopleView.swift
// The voice library: everyone the app has learned, and how much it knows about each voice.

import SwiftUI

struct PeopleView: View {
    @EnvironmentObject var store: Store
    @State private var renaming: Person?
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("People").font(.title2.bold())
                Text("Name a speaker inside a meeting to add them here. Every meeting where you confirm someone adds more voice samples, so the app gets better at recognizing them.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding()
            Divider()
            if store.people.isEmpty {
                Text("No one yet. Record a meeting, then click a speaker chip and choose “New person…”.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.people) { p in
                    HStack(spacing: 12) {
                        Circle().fill(Palette.color(p.colorIndex)).frame(width: 14, height: 14)
                        VStack(alignment: .leading) {
                            Text(p.name).font(.headline)
                            Text("\(p.samples.count) voice samples from \(p.meetingCount) meeting\(p.meetingCount == 1 ? "" : "s")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        // A rough "how well do we know this voice" bar: more meetings = steadier matching.
                        ProgressView(value: min(Double(p.meetingCount), 5), total: 5)
                            .frame(width: 80)
                            .help("Voice library strength (fills up after about 5 meetings)")
                        Menu {
                            Button("Rename…") { newName = p.name; renaming = p }
                            Button("Delete", role: .destructive) { store.deletePerson(p.id) }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                    .padding(.vertical, 4)
                }
            }
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
}
