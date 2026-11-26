// FixViews.swift
// 0.7.3 "Learn from my fixes": the edit sheet (dictation text / transcript line) and the
// "Learned: X → Y" toast with Undo (0.7.6: "Suggestion: X → Y" with Approve for a name).
// The lists of learned fix-ups and suggestions, and "Save my corrections", are in Settings › Learning
// (Views/LearningView.swift).

import SwiftUI

/// Edit a piece of text (any length). Save hands back the new text.
struct EditTextSheet: View {
    var title: String
    var original: String
    var onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.nightTitle)
            Text("Fix any words Scribe got wrong. A fix you make twice is learned; approve one sooner in Settings › Learning.")
                .font(.nightSecondary).foregroundStyle(Night.text2)
            TextEditor(text: $text)
                .font(.nightReading)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 140)
                .background(RoundedRectangle(cornerRadius: Night.rControl, style: .continuous).fill(Night.well))
                .overlay(RoundedRectangle(cornerRadius: Night.rControl, style: .continuous).strokeBorder(Night.line2, lineWidth: 1))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.nightGhost).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(text); dismiss() }.buttonStyle(.nightPrimary)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 560)
        .background(Night.canvas)
        .onAppear { text = original }
    }
}

/// Bottom-center toast: "Learned: X → Y" with Undo; goes away after 7 s.
struct LearnedToast: View {
    @EnvironmentObject var store: Store
    @State private var hideWork: DispatchWorkItem?

    var body: some View {
        VStack(spacing: 6) {
            ForEach(store.learnedToast) { item in
                HStack(spacing: 10) {
                    Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold)).foregroundStyle(Night.posterGreen)
                    Text(item.isActive ? "Learned: " : "Suggestion: ").font(.nightSmallStrong).foregroundColor(Night.onPrimary)
                        + Text(item.label).font(.nightBody).foregroundColor(Night.onPrimary)
                    if item.isName && !item.addedWords.isEmpty {
                        Text("· added to your words").font(.nightSecondary).foregroundStyle(Night.onPrimary.opacity(0.7))
                    }
                    if item.isActive {
                        Button("Undo") { store.undoLearned(item) }
                            .buttonStyle(.plain).font(.nightSmallStrong).foregroundStyle(Night.onPrimary)
                            .padding(.leading, 4)
                    } else {
                        Button("Approve") { _ = store.approveFixUp(item) }
                            .buttonStyle(.plain).font(.nightSmallStrong).foregroundStyle(Night.onPrimary)
                            .padding(.leading, 4)
                    }
                }
                .padding(.horizontal, 14).frame(height: 36)
                .background(Capsule().fill(Night.primary))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 18)
        .animation(Night.base, value: store.learnedToast)
        .onChange(of: store.learnedToast) { _, list in
            hideWork?.cancel()
            guard !list.isEmpty else { return }
            let s = store
            let w = DispatchWorkItem { MainActor.assumeIsolated { s.learnedToast = [] } }
            hideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 7, execute: w)
        }
    }
}
