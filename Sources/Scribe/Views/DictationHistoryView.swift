// DictationHistoryView.swift
// Your recent dictations (kept on this Mac, last 200), so nothing is lost if a paste
// went to the wrong place. 0.7: a list of flat cards (text, then time · length · method).

import SwiftUI
import AppKit

struct DictationHistoryView: View {
    @EnvironmentObject var store: Store
    var query: String = ""
    var queryBinding: Binding<String>? = nil
    var searchFocus: Int = 0
    @State private var copiedID: UUID?

    private var items: [DictationEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return store.dictations }
        return store.dictations.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Dictations", subtitle: "\(store.dictations.count) kept on this Mac") {
                if let queryBinding {
                    NightSearchField(text: queryBinding, prompt: "Search dictations", focusRequest: searchFocus)
                }
                if !store.dictations.isEmpty {
                    Button("Clear") { store.clearDictations() }.buttonStyle(.nightSecondary)
                }
            }
            .padding(.leading, Night.gutterLeading)
            .padding(.trailing, Night.gutterTrailing)
            if items.isEmpty {
                CozyEmptyState(symbol: query.isEmpty ? "mic" : "magnifyingglass",
                               title: query.isEmpty ? "Nothing yet" : "No matches",
                               message: query.isEmpty ? "Hold \(DictationSettings.holdKey.title) in any text box and talk. What you say lands there, and a copy waits here."
                                                      : "No dictations match “\(query)”.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(items) { d in card(d) }
                    }
                    .padding(.leading, Night.gutterLeading)
                    .padding(.trailing, Night.gutterTrailing)
                    .padding(.bottom, 32)
                    .frame(maxWidth: Brand.readingWidth + 120, alignment: .leading)
                }
                .scrollIndicators(.never)
            }
        }
    }

    private func card(_ d: DictationEntry) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(d.text).font(.scribe(14, 500)).foregroundStyle(Night.text).lineSpacing(4).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(meta(d)).font(.nightMeta).foregroundStyle(Night.text3)
            }
            Spacer(minLength: 8)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(d.text, forType: .string)
                copiedID = d.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if copiedID == d.id { copiedID = nil } }
            } label: { Image(systemName: copiedID == d.id ? "checkmark" : "doc.on.doc") }
            .buttonStyle(NightIconButtonStyle())
            .help("Copy")
            .accessibilityLabel("Copy")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .nightCard(padding: 18)
    }

    private func meta(_ d: DictationEntry) -> String {
        let when = Calendar.current.isDateInToday(d.date) ? d.date.formatted(date: .omitted, time: .shortened)
                                                         : d.date.formatted(date: .abbreviated, time: .shortened)
        return "\(when)  ·  \(String(format: "%.1f", d.audioSeconds)) s spoken  ·  ready \(String(format: "%.2f", d.latencySeconds)) s after release  ·  \(d.method.label)"
    }
}
