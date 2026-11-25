// VoiceTestView.swift
// Settings › Model › "Test my voice…": read 20 short sentences out loud, then every speech model
// on this Mac transcribes your recordings and you see which one gets YOUR voice right.
//
// Privacy: the recordings stay in memory only (never written to disk, never uploaded) and are
// thrown away as soon as the scores are ready.

import SwiftUI
import FluidAudio

@MainActor
final class VoiceTestModel: ObservableObject {
    struct Row: Identifiable {
        var engine: DictationEngine
        var score: VoiceScore
        var meanSeconds: Double
        var worst: (said: String, heard: String)?
        var id: String { engine.rawValue }
    }
    enum Phase: Equatable { case intro, recording, scoring(String), results }

    let prompts: [String]
    @Published var phase: Phase = .intro
    @Published var index = 0
    @Published var isRecording = false
    @Published var level: Float = 0
    @Published var rows: [Row] = []
    @Published var message = ""
    @Published var isPreview = false

    /// In memory only. Emptied after scoring (and when the sheet closes).
    private var clips: [Int: [Float]] = [:]
    private let mic = MicCapture()

    init(prompts: [String] = VoicePrompts.forTest) { self.prompts = prompts }

    var recordedCount: Int { clips.count }
    var current: String { prompts[min(index, prompts.count - 1)] }

    func begin() {
        phase = .recording
        index = 0
        clips = [:]
        rows = []
    }

    func toggleRecording() {
        if isRecording { stop() } else { Task { await start() } }
    }

    private func start() async {
        guard await Recorder.requestPermission() else {
            message = "Scribe needs the microphone for this test (System Settings › Privacy & Security › Microphone)."
            return
        }
        mic.onLevel = { [weak self] l in self?.level = l }
        do {
            try mic.start()
            isRecording = true
            message = ""
        } catch {
            message = "Mic error: \(error.localizedDescription)"
        }
    }

    private func stop() {
        let samples = mic.stop()
        isRecording = false
        level = 0
        if samples.count > 16_000 / 2 {
            clips[index] = samples
            if index < prompts.count - 1 { index += 1 }
        } else {
            message = "That was too short — press Record and read the sentence."
        }
    }

    func previous() { if index > 0 { index -= 1 } }
    func skip() { if index < prompts.count - 1 { index += 1 } }

    /// Engines whose model files are on this Mac.
    static func installed() -> [DictationEngine] {
        DictationEngine.allCases.filter { e in e.componentIDs.allSatisfy { ModelStore.shared.isInstalled($0) } }
    }

    func score(engineReady: Bool) async {
        guard !clips.isEmpty else { return }
        guard engineReady else { message = "The speech models are still loading. Try again in a moment."; return }
        let recorded = clips.sorted { $0.key < $1.key }.map { (ref: prompts[$0.key], audio: $0.value) }
        clips = [:]                                   // the only copy now lives in `recorded`, freed when this ends
        var out: [Row] = []
        let currentModel = SpeechModel.current
        for engine in Self.installed() {
            phase = .scoring("Transcribing with \(engine.shortTitle)…")
            var manager: AsrManager? = nil
            do {
                if let m = engine.speechModel, m != currentModel {
                    manager = try await SpeechEngine.loadManager(m)
                } else if engine.isWhisper {
                    try await WhisperEngine.shared.load(engine)
                }
                var total = VoiceScore(), seconds = 0.0
                var worst: (Double, String, String)? = nil
                for clip in recorded {
                    let t0 = Date()
                    let r = try await Dictation.run(samples: clip.audio, useAI: false, removeFillers: true,
                                                    asrOverride: manager, engine: engine)
                    seconds += Date().timeIntervalSince(t0)
                    let s = VoiceScoring.score(reference: clip.ref, hypothesis: r.text)
                    total = total + s
                    let bad = s.formattedErrorRate
                    if bad > 0, bad > (worst?.0 ?? 0) { worst = (bad, clip.ref, r.text) }
                }
                out.append(Row(engine: engine, score: total, meanSeconds: seconds / Double(recorded.count),
                               worst: worst.map { ($0.1, $0.2) }))
            } catch {
                message = "\(engine.shortTitle) failed: \(error.localizedDescription)"
            }
            if engine.isWhisper, engine != DictationEngine.current { await WhisperEngine.shared.unload(engine) }
        }
        rows = out.sorted { ($0.score.wer, $0.score.formattedErrorRate) < ($1.score.wer, $1.score.formattedErrorRate) }
        phase = .results
    }

    func discard() {
        if isRecording { _ = mic.stop(); isRecording = false }
        clips = [:]
    }

    /// For `Scribe --snapshot` only: made-up numbers, clearly labelled.
    static func preview(results: Bool) -> VoiceTestModel {
        let m = VoiceTestModel()
        m.isPreview = true
        if results {
            func s(_ w: Int, _ f: Int, _ c: Int) -> VoiceScore {
                var x = VoiceScore(); x.refWords = 200; x.wordEdits = w; x.formatEdits = f; x.matchedWords = 200 - w; x.capErrors = c
                return x
            }
            m.rows = [Row(engine: .parakeetV2, score: s(6, 14, 3), meanSeconds: 0.4, worst: ("Note to self: charge the batteries.", "Note to self, charge the batteries.")),
                      Row(engine: .whisperTurbo, score: s(7, 12, 2), meanSeconds: 1.1, worst: nil),
                      Row(engine: .parakeetV3, score: s(9, 18, 4), meanSeconds: 0.4, worst: nil)]
            m.phase = .results
        } else {
            m.phase = .recording
            m.index = 5
            m.clips = [0: [], 1: [], 2: [], 3: [], 4: []]
        }
        return m
    }
}

struct VoiceTestView: View {
    @EnvironmentObject var store: Store
    @ObservedObject var model: VoiceTestModel
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: DictationEngine? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Test my voice").font(.nightDisplay)
                Spacer()
                if model.isPreview { Text("Sample numbers (screenshot)").font(.nightMeta).foregroundStyle(Night.warn) }
            }
            switch model.phase {
            case .intro: intro
            case .recording: recording
            case .scoring(let s): HStack { CapsuleSpinner(); Text(s) }.frame(maxWidth: .infinity, minHeight: 200)
            case .results: results
            }
            if !model.message.isEmpty { Text(model.message).font(.nightMeta).foregroundStyle(Night.warn) }
            Spacer(minLength: 0)
            HStack {
                Label("Recordings stay in memory and are deleted after scoring. Nothing is saved or uploaded.", systemImage: "lock")
                    .font(.nightMeta).foregroundStyle(Night.text3)
                Spacer()
                Button("Close") { model.discard(); dismiss() }.buttonStyle(.nightSecondary).keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(minWidth: 600, minHeight: 520)
        .foregroundStyle(Night.text)
        .background(Night.raised)
        .onDisappear { model.discard() }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Read \(model.prompts.count) short sentences out loud, the way you normally dictate. Every speech model on this Mac then writes them down, and you see which one makes the fewest mistakes with your voice — both wrong words and wrong capitals or punctuation.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Models on this Mac").font(.nightHeadline)
            ForEach(DictationEngine.allCases) { e in EngineAvailabilityRow(engine: e) }
            Button("Start") { model.begin() }.buttonStyle(.nightPrimary)
        }
    }

    private var recording: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sentence \(model.index + 1) of \(model.prompts.count) · \(model.recordedCount) recorded")
                .font(.nightMeta).foregroundStyle(Night.text3)
            Text(model.current)
                .font(.nightTitle)
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
                .background(NightCardBackground(radius: 14))
            HStack(spacing: 12) {
                Button { model.toggleRecording() } label: {
                    Label(model.isRecording ? "Stop" : "Record", systemImage: model.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .frame(minWidth: 110)
                }
                .buttonStyle(.nightPrimary)
                .tint(model.isRecording ? .red : .accentColor)
                .controlSize(.large)
                .keyboardShortcut(.space, modifiers: [])
                CapsuleProgress(fraction: Double(model.level), count: 16, dot: 6, spacing: 2).opacity(model.isRecording ? 1 : 0.3)
                Spacer()
                Button("Back") { model.previous() }.disabled(model.isRecording || model.index == 0)
                Button("Skip") { model.skip() }.disabled(model.isRecording || model.index >= model.prompts.count - 1)
            }
            Text("Press Record (or Space), read the sentence, press Stop. The next one appears automatically.")
                .font(.nightMeta).foregroundStyle(Night.text3)
            HStack {
                Spacer()
                Button("Score \(model.recordedCount) recording\(model.recordedCount == 1 ? "" : "s")") {
                    Task { await model.score(engineReady: store.engineReady) }
                }
                .disabled(model.isRecording || model.recordedCount < 3)
            }
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Model").bold()
                    Text("Wrong words").bold()
                    Text("Formatting errors").bold()
                    Text("Time / sentence").bold()
                    Text("")
                }
                Divider().gridCellColumns(5)
                ForEach(model.rows) { r in
                    GridRow {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.engine.shortTitle)
                            if r.engine == DictationEngine.current { Text("in use").font(.scribe(11, 600)).foregroundStyle(Night.ok) }
                        }
                        Text(pct(r.score.wer)).monospacedDigit()
                        Text(pct(r.score.formattedErrorRate)).monospacedDigit()
                        Text(String(format: "%.1f s", r.meanSeconds)).monospacedDigit()
                        Button(chosen == r.engine ? "In use" : "Use this model") {
                            DictationEngine.select(r.engine)
                            chosen = r.engine
                            Task { await store.prepareEngine() }
                        }
                        .disabled(r.engine == DictationEngine.current && chosen == nil || chosen == r.engine)
                        .fixedSize()
                    }
                }
            }
            Text("Wrong words = words heard wrong, missing or extra, out of every word you read. Formatting errors also count a word as wrong when its capital letter or the punctuation after it is wrong. Lower is better. Times are on this Mac.")
                .font(.nightMeta).foregroundStyle(Night.text3).fixedSize(horizontal: false, vertical: true)
            if let best = model.rows.first, let w = best.worst {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hardest sentence for \(best.engine.shortTitle):").font(.scribe(12, 700))
                    Text("You read: \(w.said)").font(.nightMeta)
                    Text("It wrote: \(w.heard)").font(.nightMeta).foregroundStyle(Night.text3)
                }
            }
            HStack {
                Button("Test again") { model.begin() }
                Spacer()
            }
        }
    }

    private func pct(_ x: Double) -> String { String(format: "%.1f %%", x * 100) }
}

/// One engine: on this Mac, or a Download button (through ModelStore, like every model).
struct EngineAvailabilityRow: View {
    let engine: DictationEngine
    @EnvironmentObject var models: ModelStore
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        HStack {
            let have = engine.componentIDs.allSatisfy { models.isInstalled($0) }
            Image(systemName: have ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(have ? Night.ok : Night.text3)
            VStack(alignment: .leading, spacing: 1) {
                Text(engine.title)
                Text(engine.detail).font(.nightMeta).foregroundStyle(Night.text3)
            }
            Spacer()
            if busy {
                CapsuleSpinner()
            } else if !have {
                Button("Download \(ModelStore.mb(engine.downloadBytes))") {
                    busy = true
                    Task {
                        do { try await models.ensure(engine.componentIDs + ["vad"]) } catch { self.error = error.localizedDescription }
                        busy = false
                    }
                }
            }
            if let error { Text(error).font(.nightMeta).foregroundStyle(Night.warn) }
        }
    }
}
