// DictationHistoryView.swift
// Your recent dictations (kept on this Mac, last 200), so nothing is lost if a paste
// went to the wrong place.

import SwiftUI
import AppKit

struct DictationHistoryView: View {
    @EnvironmentObject var store: Store
    var query: String = ""

    private var items: [DictationEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return store.dictations }
        return store.dictations.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dictation").font(.title2.bold())
                    Text("Hold \(DictationSettings.holdKey.title) in any app and talk. Your last dictations are here.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if !store.dictations.isEmpty {
                    Button("Clear") { store.clearDictations() }
                }
            }
            .padding()
            Divider()
            if items.isEmpty {
                Text(query.isEmpty ? "Nothing yet." : "No dictations match “\(query)”.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(items) { d in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(d.text).textSelection(.enabled)
                            Text("\(d.date.formatted(date: .abbreviated, time: .shortened)) · \(String(format: "%.1f", d.audioSeconds)) s spoken · ready \(String(format: "%.2f", d.latencySeconds)) s after release · \(d.method.label)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(d.text, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help("Copy")
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset)
            }
        }
    }
}
