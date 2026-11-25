// FixViews.swift
// 0.7.3 "Learn from my fixes": the edit sheet (dictation text / transcript line), the
// "Learned: X → Y" toast with Undo, the Settings › Vocabulary list of learned items, and the
// Settings › Models "Save my corrections" card.

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
            Text("Fix any words Scribe got wrong. Scribe learns fixes you repeat, and names right away.")
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
                    Text("Learned: ").font(.nightSmallStrong).foregroundColor(Night.onPrimary)
                        + Text(item.label).font(.nightBody).foregroundColor(Night.onPrimary)
                    if item.isName && !item.addedWords.isEmpty {
                        Text("· added to your words").font(.nightSecondary).foregroundStyle(Night.onPrimary.opacity(0.7))
                    }
                    Button("Undo") { store.undoLearned(item) }
                        .buttonStyle(.plain).font(.nightSmallStrong).foregroundStyle(Night.onPrimary)
                        .padding(.leading, 4)
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

/// Settings › Vocabulary: what Scribe learned from your fixes; × removes it (and its word/replacement).
struct LearnedFixesCard: View {
    @EnvironmentObject var store: Store
    @State private var items: [LearnedFix] = FixLearner.learned
    var changed: () -> Void = {}

    var body: some View {
        SettingsCard(title: "Learned from your fixes",
                     footer: "When you fix the same word twice in a dictation or a transcript (or fix a name once), Scribe adds it here as a replacement, and names to your words. Removing one takes it back and stops Scribe from learning it again. The speech model itself isn't retrained.") {
            if items.isEmpty {
                Text("Nothing yet. Edit a dictation in Dictation › History, or a line in a meeting's transcript.")
                    .font(.nightSecondary).foregroundStyle(Night.text3)
                    .padding(Night.cardPadding)
            } else {
                ForEach(items.reversed()) { it in
                    HStack(spacing: 8) {
                        Text(it.from).font(.nightBody).foregroundStyle(Night.text2)
                        Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(Night.text3)
                        Text(it.to).font(.nightBody).foregroundStyle(Night.text)
                        if it.isName { Text("name").font(.nightMeta).foregroundStyle(Night.text3) }
                        Spacer()
                        Text(it.date.formatted(date: .abbreviated, time: .omitted)).font(.nightMeta).foregroundStyle(Night.text3)
                        Button { store.undoLearned(it); items = FixLearner.learned; changed() } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Night.text3)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(it.label)")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 9)
                }
            }
        }
        .onAppear { items = FixLearner.learned }
        .onChange(of: store.learnedToast) { _, _ in items = FixLearner.learned }
    }
}

/// Settings › Models: opt-in, local-only correction pairs for a future fine-tune.
struct CorrectionsCard: View {
    @EnvironmentObject var store: Store
    @AppStorage(CorrectionStore.key) private var on = false
    @State private var count = 0
    @State private var confirm = false

    var body: some View {
        SettingsCard(title: "Corrections",
                     footer: "Off by default. When on, each dictation's audio is kept on this Mac for a while, and when you fix a dictation or a transcript line, its audio clip and your corrected text are saved together in Application Support › Scribe › Corrections. Nothing is uploaded. This prepares for training a future model on your voice; today the speech model doesn't retrain.") {
            ToggleRow(title: "Save my corrections for future training", isOn: $on)
            NightDivider()
            HStack {
                Text(count == 1 ? "1 correction saved" : "\(count) corrections saved")
                    .font(.nightSecondary).foregroundStyle(Night.text2)
                Spacer()
                Button("Delete all…") { confirm = true }
                    .buttonStyle(NightButtonStyle(kind: .danger))
                    .disabled(count == 0 && !on)
            }
            .padding(.horizontal, Night.rowPaddingH).padding(.vertical, Night.rowPaddingV)
        }
        .onAppear { count = CorrectionStore.count(store.folder) }
        .onChange(of: on) { _, v in if !v { try? FileManager.default.removeItem(at: CorrectionStore.pending(store.folder)) } }
        .alert("Delete all saved corrections?", isPresented: $confirm) {
            Button("Delete", role: .destructive) { CorrectionStore.deleteAll(store.folder); count = 0 }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The audio clips and texts are removed from this Mac. Your dictations and meetings stay.") }
    }
}
