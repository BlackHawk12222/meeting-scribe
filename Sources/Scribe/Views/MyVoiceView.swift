// MyVoiceView.swift
// 0.7.3.2 "My voice" (Settings › Meetings, and Profile › My voice).
//  • Not set up: the setup prompt ("Teach Scribe your voice so meetings know it's you") → the
//    guided enrollment (VoiceEnrollmentView(forMe: true)).
//  • Set up: voice strength (Strong / Good / Learning, the People rules), how many clips taught it,
//    "Train it more" (one more clip into the voiceprint), "Test it" (~5 s, then "Matched you —
//    strong match" and the score vs. the naming threshold in plain words), "Re-record from
//    scratch" and "Delete my voice".
// Audio is only held in memory while a clip is checked; nothing is saved or uploaded.

import SwiftUI

/// Records one short clip for Train it more / Test it, with a live level meter.
@MainActor
final class VoiceClipRecorder: ObservableObject {
    enum Kind { case train, test }
    enum Phase: Equatable {
        case idle
        case recording(Kind)
        case working(Kind)
        case result(ok: Bool, headline: String, detail: String)
    }
    static let testSeconds = 5.0
    static let trainMaxSeconds = 12.0
    static let bars = 28

    @Published var phase: Phase = .idle
    @Published var levels: [Float] = Array(repeating: 0, count: VoiceClipRecorder.bars)
    @Published var seconds = 0.0
    /// Which enrollment line Train it more asks for next.
    @Published var promptIndex = 0
    private var mic = MicCapture()
    private var timer: Timer?

    var prompt: EnrollmentPrompt { VoiceEnrollment.prompts[promptIndex % VoiceEnrollment.prompts.count] }

    init(preview: Phase? = nil) {
        if let preview { phase = preview }
        if case .recording? = preview {
            seconds = 2.5
            levels = (0..<Self.bars).map { i in
                let x = Float(i)
                return max(0.08, min(0.95, 0.45 + 0.30 * sin(x * 0.9) + 0.15 * sin(x * 2.3)))
            }
        }
    }

    func start(_ kind: Kind, store: Store) {
        levels = Array(repeating: 0, count: Self.bars)
        mic.onLevel = { [weak self] l in
            guard let self else { return }
            self.levels.removeFirst()
            self.levels.append(l)
        }
        do {
            try mic.start()
        } catch {
            phase = .result(ok: false, headline: "Couldn't start the microphone", detail: error.localizedDescription)
            return
        }
        phase = .recording(kind)
        seconds = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, case .recording(let k) = self.phase else { return }
                self.seconds += 0.25
                let limit = k == .test ? Self.testSeconds : Self.trainMaxSeconds
                if self.seconds >= limit { self.stop(store: store) }
            }
        }
    }

    func stop(store: Store) {
        guard case .recording(let kind) = phase else { return }
        timer?.invalidate(); timer = nil
        let audio = mic.stop()
        phase = .working(kind)
        let style = prompt.style
        Task { @MainActor in
            do {
                switch kind {
                case .train:
                    let r = try await VoiceEnrollment.process(samples: audio, style: style)
                    if let e = r.embedding, store.trainMyVoice(embedding: e) {
                        promptIndex += 1
                        phase = .result(ok: true, headline: "Added to your voiceprint",
                                        detail: "\(store.myVoiceClipCount) clips now teach Scribe your voice.")
                    } else {
                        phase = .result(ok: false, headline: "That clip wasn't used",
                                        detail: r.check.problem ?? "Try once more.")
                    }
                case .test:
                    guard let e = try await Self.embedTestClip(audio) else {
                        phase = .result(ok: false, headline: "Not enough speech",
                                        detail: "Talk for the whole 5 seconds, then it compares.")
                        return
                    }
                    if let v = store.testMyVoice(embedding: e) {
                        phase = .result(ok: v.matched, headline: v.headline, detail: v.detail)
                    } else {
                        phase = .idle
                    }
                }
            } catch {
                phase = .result(ok: false, headline: "Couldn't check that clip",
                                detail: "The voice models may still be loading; try again in a moment.")
            }
        }
    }

    func cancel() {
        timer?.invalidate(); timer = nil
        if case .recording = phase { _ = mic.stop() }
        phase = .idle
    }

    /// The speech parts of a test clip (at least 1.5 s of it) → one voice embedding.
    static func embedTestClip(_ samples: [Float]) async throws -> [Float]? {
        let speech = try await SpeechEngine.shared.speechRanges(samples)
        let speechSeconds = Double(speech.reduce(0) { $0 + $1.count }) / 16_000
        guard speechSeconds >= 1.5 else { return nil }
        let audio = speech.flatMap { samples[$0.clamped(to: 0..<samples.count)] }
        let emb = try await SpeechEngine.shared.embedSpans(samples: audio, spans: [0..<(Double(audio.count) / 16_000)])
        return emb.first
    }
}

/// The My voice rows, for a SettingsCard (Settings) or the Profile sheet.
struct MyVoiceCard: View {
    @EnvironmentObject var store: Store
    @StateObject private var rec: VoiceClipRecorder
    @State private var enrolling = false
    @State private var reRecording = false
    @State private var confirmDelete = false

    init(preview: VoiceClipRecorder.Phase? = nil) {
        _rec = StateObject(wrappedValue: VoiceClipRecorder(preview: preview))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.myVoiceEnrolled { enrolled } else { setup }
        }
        .sheet(isPresented: $enrolling) { VoiceEnrollmentView(forMe: true).environmentObject(store) }
        .sheet(isPresented: $reRecording) { VoiceEnrollmentView(forMe: true, fromScratch: true).environmentObject(store) }
        .alert("Delete your voice?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { rec.cancel(); store.deleteMyVoice() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Scribe forgets your voiceprint on this Mac. Your name stays on your lines in past meetings. You can set it up again any time.")
        }
        .onDisappear { rec.cancel() }
    }

    // MARK: Not set up

    private var setup: some View {
        SettingRow(title: "My voice", detail: "Teach Scribe your voice so meetings know it's you") {
            Button("Set up…") { enrolling = true }
                .buttonStyle(NightButtonStyle(kind: .primary, height: 32))
                .accessibilityHint("Read six short lines out loud")
        }
    }

    // MARK: Set up

    private var enrolled: some View {
        let strength = store.myVoiceStrength ?? .learning
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("My voice").font(.system(size: 14.5, weight: .medium)).foregroundStyle(Night.text)
                    HStack(spacing: 8) {
                        StrengthBadge(strength: strength)
                        Text("\(store.myVoiceClipCount) clips · \(strengthHint(strength))")
                            .font(.nightSecondary).foregroundStyle(Night.text2).lineLimit(1)
                    }
                }
                Spacer(minLength: 10)
                Button { rec.start(.train, store: store) } label: { Label("Train it more", systemImage: "plus.circle") }
                    .buttonStyle(NightButtonStyle(kind: .secondary, height: 32))
                    .disabled(busy)
                Button { rec.start(.test, store: store) } label: { Label("Test it", systemImage: "waveform") }
                    .buttonStyle(NightButtonStyle(kind: .primary, height: 32))
                    .disabled(busy)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            if rec.phase != .idle {
                NightDivider()
                activity.padding(.horizontal, 16).padding(.vertical, 12)
            }
            NightDivider()
            HStack(spacing: 8) {
                Button("Re-record from scratch") { rec.cancel(); reRecording = true }
                    .buttonStyle(NightButtonStyle(kind: .ghost, height: 28))
                Spacer()
                Button("Delete my voice") { confirmDelete = true }
                    .buttonStyle(NightButtonStyle(kind: .danger, height: 28))
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
    }

    private var busy: Bool {
        switch rec.phase { case .recording, .working: return true; default: return false }
    }

    private func strengthHint(_ s: VoiceStrength) -> String {
        switch s {
        case .strong: return "meetings know it's you"
        case .good: return "works well; a few meetings make it strong"
        case .learning: return "train it more to make it surer"
        }
    }

    @ViewBuilder private var activity: some View {
        switch rec.phase {
        case .idle:
            EmptyView()
        case .recording(let kind):
            VStack(alignment: .leading, spacing: 10) {
                Text(kind == .test ? "Say anything for 5 seconds…" : rec.prompt.text)
                    .font(kind == .test ? Font.nightHeadline : Font.nightReading)
                    .foregroundStyle(Night.text)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Circle().fill(Night.live).frame(width: 8, height: 8)
                    CapsuleBars(levels: rec.levels.map { Double($0) }, barWidth: 4, spacing: 3, maxLength: 22, style: .gradient)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(kind == .test ? String(format: "%.0f s", max(0, VoiceClipRecorder.testSeconds - rec.seconds))
                                       : String(format: "0:%02.0f", rec.seconds))
                        .font(.nightSmallStrong).monospacedDigit().foregroundStyle(Night.live)
                    if kind == .train {
                        Button("Stop") { rec.stop(store: store) }.buttonStyle(NightButtonStyle(kind: .primary, height: 28))
                    } else {
                        Button("Cancel") { rec.cancel() }.buttonStyle(NightButtonStyle(kind: .ghost, height: 28))
                    }
                }
            }
        case .working:
            HStack(spacing: 8) { CapsuleSpinner(); Text("Checking…").font(.nightSecondary).foregroundStyle(Night.text2) }
        case .result(let ok, let headline, let detail):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 16)).foregroundStyle(ok ? Night.ok : Night.warn)
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline).font(.nightHeadline).foregroundStyle(Night.text)
                    Text(detail).font(.nightSecondary).foregroundStyle(Night.text2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button { rec.phase = .idle } label: { Image(systemName: "xmark") }
                    .buttonStyle(NightIconButtonStyle(size: 24))
                    .accessibilityLabel("Dismiss")
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// Strong / Good / Learning, colored like People.
struct StrengthBadge: View {
    var strength: VoiceStrength
    var body: some View {
        HStack(spacing: 6) {
            Text(strength.rawValue)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(strength.color)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(strength.color.opacity(0.12)))
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5).fill(i < strength.segments ? strength.color : Night.line)
                        .frame(width: 10, height: 4)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Voice strength: \(strength.rawValue)")
    }
}

/// Profile › My voice when it's set up: the same card in a small sheet.
struct MyVoiceSheet: View {
    static let size = CGSize(width: 620, height: 380)
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    var preview: VoiceClipRecorder.Phase? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("My voice").font(.nightTitle)
                Text("Scribe uses it to put your name on your lines in meetings. It stays on this Mac.")
                    .font(.nightSecondary).foregroundStyle(Night.text2)
            }
            MyVoiceCard(preview: preview)
                .background(NightCardBackground())
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.nightPrimary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(Night.raised)
        .foregroundStyle(Night.text)
    }
}
