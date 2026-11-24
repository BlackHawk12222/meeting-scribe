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
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(title: "Dictation",
                           subtitle: "Hold \(DictationSettings.holdKey.title) in any app and talk. Your recent dictations wait here, just in case.") {
                    if !store.dictations.isEmpty {
                        Button("Clear") { store.clearDictations() }.scribeButton()
                    }
                }
                if items.isEmpty {
                    CozyEmptyState(symbol: query.isEmpty ? "mic" : "magnifyingglass",
                                   title: query.isEmpty ? "Nothing yet" : "No matches",
                                   message: query.isEmpty ? "Try it in any text box. What you say will land there, and a copy stays here."
                                                          : "No dictations match “\(query)”.")
                        .frame(minHeight: 300)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(items) { d in card(d) }
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 28)
            .padding(.bottom, 40)
            .frame(maxWidth: Brand.readingWidth + 80, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func card(_ d: DictationEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(d.text).font(.system(size: 14.5)).lineSpacing(3).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(d.date.formatted(.relative(presentation: .named))) · \(String(format: "%.1f", d.audioSeconds)) s spoken · ready \(String(format: "%.2f", d.latencySeconds)) s after release · \(d.method.label)")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(d.text, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
            .scribeButton()
            .controlSize(.small)
            .help("Copy")
            .accessibilityLabel("Copy")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .scribeCard()
    }
}
