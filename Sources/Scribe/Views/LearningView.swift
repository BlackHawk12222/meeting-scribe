// LearningView.swift
// 0.7.6 Settings › Learning (Poster design): what Scribe picked up from your fixes.
//  • two poster tiles: fix-ups on, and minutes of saved speech toward a personal model ("coming later")
//  • Learned fix-ups: from → to, times seen, on/off switch, delete (Engine/Learning.swift, FixUps)
//  • Waiting for your OK: suggestions with Approve / Dismiss
//  • Personal model: the minutes, "Save my corrections" (moved here from Settings › Models), Delete all
// The personal model does not exist yet; the page says "coming later" and never claims it.

import SwiftUI

struct LearningSettingsTab: View {
    @EnvironmentObject var store: Store
    @AppStorage(CorrectionStore.key) private var saveCorrections = false
    @State private var rules: [FixUpRule] = FixUps.rules
    @State private var seconds = 0.0
    @State private var count = 0
    @State private var confirm = false

    private var learned: [FixUpRule] { rules.filter(\.learned).sorted { $0.lastSeen > $1.lastSeen } }
    private var waiting: [FixUpRule] {
        rules.filter { !$0.learned }.sorted { $0.seen != $1.seen ? $0.seen > $1.seen : $0.lastSeen > $1.lastSeen }
    }
    private var goal: Double { CorrectionStore.personalModelGoalMinutes }
    private var minutes: Int { Int((seconds / 60).rounded(.down)) }
    private var progressLine: String { "\(minutes) of \(Int(goal)) min toward a personal model — coming later" }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 14) {
                PosterTile(color: Night.posterGreen, label: "Fix-ups on", value: "\(learned.filter(\.enabled).count)",
                           caption: waiting.isEmpty ? "Nothing waiting for you" : "\(waiting.count) waiting for your OK",
                           height: Night.tileHeightCompact, valueSize: 54) {
                    Image(systemName: "sparkles").font(.system(size: 20, weight: .semibold))
                }
                PosterTile(color: Night.posterIndigo, label: "Your saved speech", value: "\(minutes)", unit: "of \(Int(goal)) min",
                           caption: "Personal model: coming later", height: Night.tileHeightCompact, valueSize: 54) {
                    RingGauge(fraction: seconds / 60 / goal, size: 42, line: 5)
                }
            }

            SettingsCard(title: "Learned fix-ups",
                         footer: "Applied right after Scribe hears you, before your Style. A fix turns on after you make the same one twice, or as soon as you approve it. A fix that would change an everyday word always waits for your OK. Deleting one stops Scribe from learning it again.") {
                if learned.isEmpty {
                    CardNote(text: "Nothing learned yet. Fix a dictation in Dictation › History, or a line in a meeting's transcript.")
                } else {
                    ForEach(Array(learned.enumerated()), id: \.element.id) { i, r in
                        if i > 0 { NightDivider() }
                        HStack(spacing: 10) {
                            fromTo(r)
                            Spacer(minLength: 8)
                            Text(seenText(r)).font(.nightMeta).foregroundStyle(Night.text3).monospacedDigit()
                            Button { FixUps.setEnabled(r.id, !r.enabled); reload() } label: { NightSwitch(isOn: r.enabled) }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(r.label) \(r.enabled ? "on" : "off")")
                            Button { store.undoLearned(r); reload() } label: {
                                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Night.text3)
                                    .frame(width: 22, height: 22).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Delete \(r.label)")
                        }
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .opacity(r.enabled ? 1 : 0.6)
                    }
                }
            }

            SettingsCard(title: "Waiting for your OK",
                         footer: "Fixes Scribe has seen once, and fixes that would change an everyday word. Approve turns one on now; Dismiss forgets it.") {
                if waiting.isEmpty {
                    CardNote(text: "No suggestions right now.")
                } else {
                    ForEach(Array(waiting.enumerated()), id: \.element.id) { i, r in
                        if i > 0 { NightDivider() }
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                fromTo(r)
                                Text(reason(r)).font(.nightMeta).foregroundStyle(Night.text3)
                            }
                            Spacer(minLength: 8)
                            Button("Dismiss") { store.undoLearned(r); reload() }.buttonStyle(.nightGhost)
                            Button("Approve") { _ = store.approveFixUp(r); reload() }
                                .buttonStyle(NightButtonStyle(kind: .secondary, height: 28))
                        }
                        .padding(.horizontal, 16).padding(.vertical, 9)
                    }
                }
            }

            SettingsCard(title: "Personal model",
                         footer: "Off by default. When on, the audio of each dictation is kept on this Mac for a while, and when you fix a dictation or a transcript line, its clip and your corrected text are saved together in Application Support › Scribe › Corrections. Nothing is uploaded. A personal speech model trained on these clips is coming later; it doesn't exist yet, and today Scribe learns only the text fix-ups above.") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(progressLine).font(.system(size: 14.5, weight: .medium)).foregroundStyle(Night.text)
                    CapsuleProgress(fraction: seconds / 60 / goal, count: 40)
                }
                .padding(.horizontal, 16).padding(.vertical, 13)
                NightDivider()
                ToggleRow(title: "Save my corrections", detail: "Keeps the audio of the dictations you fix, on this Mac only", isOn: $saveCorrections)
                NightDivider()
                HStack {
                    Text(count == 1 ? "1 correction saved" : "\(count) corrections saved")
                        .font(.nightSecondary).foregroundStyle(Night.text2)
                    Spacer()
                    Button("Delete all…") { confirm = true }
                        .buttonStyle(NightButtonStyle(kind: .danger))
                        .disabled(count == 0 && rules.isEmpty && !saveCorrections)
                }
                .padding(.horizontal, Night.rowPaddingH).padding(.vertical, Night.rowPaddingV)
            }
        }
        .onAppear(perform: reload)
        .onChange(of: store.learnedToast) { _, _ in reload() }
        .onChange(of: saveCorrections) { _, v in
            if !v { try? FileManager.default.removeItem(at: CorrectionStore.pending(store.folder)) }
        }
        .alert("Delete everything Scribe learned?", isPresented: $confirm) {
            Button("Delete", role: .destructive) {
                CorrectionStore.deleteAll(store.folder)
                FixUps.deleteAll()
                AppLog.log("learning: deleted all (fix-ups and saved corrections)")
                Task { await store.prepareVocabularyBoost() }
                reload()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the saved audio clips and texts, every learned fix-up and every suggestion from this Mac. Your dictations, meetings and word list stay.")
        }
    }

    private func fromTo(_ r: FixUpRule) -> some View {
        HStack(spacing: 8) {
            Text(r.from).font(.nightBody).foregroundStyle(Night.text2).lineLimit(1)
            Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(Night.text3)
            Text(r.to).font(.nightBody).foregroundStyle(Night.text).lineLimit(1)
        }
    }

    private func seenText(_ r: FixUpRule) -> String {
        let seen = r.seen == 1 ? "seen once" : "seen \(r.seen)×"
        return r.approved ? seen + " · approved" : seen
    }

    private func reason(_ r: FixUpRule) -> String {
        let seen = r.seen == 1 ? "Seen once" : "Seen \(r.seen)×"
        if r.touchesCommonWord { return seen + " · changes an everyday word" }
        if r.isName { return seen + " · a name" }
        return seen
    }

    private func reload() {
        rules = FixUps.rules
        seconds = CorrectionStore.totalSeconds(store.folder)
        count = CorrectionStore.count(store.folder)
    }
}
