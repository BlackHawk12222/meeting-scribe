// VoiceEnrollmentView.swift
// "Add person": guided voice enrollment, shown as a sheet from the People page:
//     .sheet(isPresented: $adding) { VoiceEnrollmentView().environmentObject(store) }
//
// Flow: type a name → read 6 short lines, one at a time (≈ 30–45 s in total) → each clip is checked
// (level, clipping, background noise, at least 4 s of speech) and must be redone if it fails →
// Save puts one voice sample per clip into the voice library.
// Look (0.7 "Night Sky"): built from Theme.swift tokens (Night.*, nightCard, NightButtonStyle,
// NightField, CapsuleBars, SectionLabel) on the raised sheet surface with a faint starfield.
// Calm on purpose: one line on screen,
// big readable text, a quiet hint for HOW to say it, a live level meter, and dots for progress.

import SwiftUI

extension EnrollmentStyle {
    /// A short, friendly "how to say it" hint shown above the line.
    var hint: String {
        switch self {
        case .reading: return "Read this in your normal voice"
        case .question: return "Ask it like a real question"
        case .loud: return "Say this a little louder, like across a table"
        case .quiet: return "Now softer and relaxed, like to someone next to you"
        case .numbers: return "Count at an easy, steady pace"
        case .free: return "Talk freely for a few seconds. Anything works"
        }
    }

    var symbol: String {
        switch self {
        case .reading: return "text.alignleft"
        case .question: return "questionmark.bubble"
        case .loud: return "speaker.wave.3"
        case .quiet: return "speaker.wave.1"
        case .numbers: return "number"
        case .free: return "bubble.left"
        }
    }
}

struct VoiceEnrollmentView: View {
    static let size = CGSize(width: 580, height: 480)

    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var started = false
    @State private var index = 0
    @State private var recording = false
    @State private var working = false
    @State private var levels: [Float] = Array(repeating: 0, count: VoiceEnrollmentView.meterBars)
    @State private var seconds = 0.0
    @State private var message: String?
    @State private var good: [EnrollmentStyle: [Float]] = [:]
    @State private var lastCheck: VoiceEnrollment.ClipCheck?
    @State private var mic = MicCapture()
    @State private var timer: Timer?

    private let prompts = VoiceEnrollment.prompts
    /// At least this many good clips before Save is allowed (the free-talk one can be skipped).
    private let minimumClips = 5
    static let meterBars = 32

    /// For `Scribe --snapshot`: open the sheet at a given step with made-up state (no microphone).
    struct Preview {
        enum Step { case intro, prompt, recording, redo, done }
        var step: Step
        var name = "Jordan"
        var index = 2
        var problem = "Too noisy. Try a quieter spot."
    }

    init(preview: Preview? = nil) {
        guard let p = preview else { return }
        _name = State(initialValue: p.name)
        _started = State(initialValue: p.step != .intro)
        let done = p.step == .done ? prompts.count : p.index
        _index = State(initialValue: done)
        var g: [EnrollmentStyle: [Float]] = [:]
        for k in 0..<min(done, prompts.count) { g[prompts[k].style] = [1] }
        _good = State(initialValue: g)
        if p.step == .recording {
            _recording = State(initialValue: true)
            _seconds = State(initialValue: 4.5)
            _levels = State(initialValue: (0..<Self.meterBars).map { i in
                let x = Float(i)
                return max(0.08, min(0.95, 0.45 + 0.30 * sin(x * 0.9) + 0.15 * sin(x * 2.3)))
            })
        }
        if p.step == .redo {
            _message = State(initialValue: p.problem)
            _lastCheck = State(initialValue: VoiceEnrollment.ClipCheck(speechSeconds: 6.2, speechLevelDB: -30, noiseLevelDB: -38,
                                                                        snrDB: 8, clippedFraction: 0, problem: p.problem))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !started { intro } else if index < prompts.count { promptStep } else { finish }
        }
        .padding(28)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .foregroundStyle(Night.text)
        .background { ZStack { Night.raised; Starfield(seed: 31, intensity: 0.7) } }
        .onDisappear { stopTimer(); if recording { _ = mic.stop() } }
    }

    // MARK: Intro

    private var intro: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Add a person").font(.nightDisplay).tracking(-0.3)
                Text("They read six short lines out loud, about 30 to 45 seconds in all. Each line asks for a different way of talking, so Scribe can tell their voice apart in meetings, even in a busy room.")
                    .font(.nightSecondary).foregroundStyle(Night.text2).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Name").font(.nightMeta).foregroundStyle(Night.text3)
                NightField(placeholder: "Their name", text: $name, height: 40, font: .scribe(15, 600)) {
                    if canStart { started = true }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                tip("waveform", "Find a quiet spot and sit where you normally would.")
                tip("mic", "Speak toward the Mac, at an arm's length or so.")
                tip("arrow.counterclockwise", "If a line doesn't come out right, you can redo it.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .scribeCard()
            Spacer(minLength: 0)
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(.nightGhost)
                Spacer()
                Button { started = true } label: { Text("Start").frame(minWidth: 80) }
                    .scribeButton(prominent: true)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
            }
        }
    }

    private var canStart: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    private func tip(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(Night.accent).frame(width: 18)
            Text(text).font(.nightSecondary).foregroundStyle(Night.text2).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Prompt

    private var promptStep: some View {
        let p = prompts[index]
        let failed = lastCheck.map { !$0.ok } ?? false
        let passed = good[p.style] != nil
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center) {
                stepDots
                Text("\(index + 1) of \(prompts.count)")
                    .font(.nightMeta).monospacedDigit().foregroundStyle(Night.text3)
                Spacer()
                Text(name).font(.scribe(13, 700)).foregroundStyle(Night.text2).lineLimit(1)
            }
            Label(p.style.hint, systemImage: p.style.symbol)
                .font(.scribe(13.5, 700))
                .foregroundStyle(Night.accent)
            Text(p.text)
                .font(.scribe(22, 600))
                .foregroundStyle(Night.text)
                .lineSpacing(5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .scribeCard(padding: 22)
            levelMeter
            status(failed: failed, passed: passed)
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                Button("Cancel") { if recording { _ = mic.stop() }; stopTimer(); dismiss() }
                    .buttonStyle(.nightGhost)
                Spacer()
                HStack(spacing: 10) {
                        if p.style == .free && !recording && !passed && good.count >= minimumClips {
                            Button("Skip") { next() }.scribeButton()
                        }
                        if recording {
                            Button { stop(style: p.style) } label: {
                                Label("Stop", systemImage: "stop.fill").frame(minWidth: 80)
                            }
                            .scribeButton(prominent: true)
                            .keyboardShortcut(.defaultAction)
                        } else if passed {
                            Button { redo(p.style) } label: { Label("Redo", systemImage: "arrow.counterclockwise") }
                                .scribeButton()
                            Button { next() } label: { Text(index + 1 < prompts.count ? "Next" : "Finish").frame(minWidth: 80) }
                                .scribeButton(prominent: true)
                                .keyboardShortcut(.defaultAction)
                        } else {
                            Button { start() } label: {
                                Label(failed ? "Redo" : "Record", systemImage: failed ? "arrow.counterclockwise" : "mic.fill")
                                    .frame(minWidth: 80)
                            }
                            .scribeButton(prominent: true)
                            .keyboardShortcut(.defaultAction)
                            .disabled(working)
                        }
                }
                .controlSize(.large)
            }
        }
    }

    /// One dot per line: filled = recorded, wide = this line, hollow = still to come.
    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(Array(prompts.enumerated()), id: \.offset) { k, p in
                let current = k == index
                let done = good[p.style] != nil
                Capsule()
                    .fill(current ? AnyShapeStyle(Night.gradientH) : done ? AnyShapeStyle(Night.accent.opacity(0.5)) : AnyShapeStyle(Night.line2))
                    .frame(width: current ? 20 : 8, height: 8)
            }
        }
        .animation(.spring(duration: 0.3), value: index)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Line \(index + 1) of \(prompts.count)")
    }

    /// Live loudness as a row of bars (newest on the right), with the time recorded so far.
    private var levelMeter: some View {
        HStack(spacing: 12) {
            Circle().fill(recording ? Night.live : Night.line2).frame(width: 8, height: 8)
                .frame(width: 18)
            CapsuleBars(levels: levels.map { recording ? Double($0) : 0 }, barWidth: 4, spacing: 3, maxLength: 28,
                        style: recording ? .gradient : .dim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeOut(duration: 0.1), value: levels)
            Text(recording ? String(format: "0:%02.0f", seconds) : "")
                .font(.scribe(13, 700)).monospacedDigit().foregroundStyle(Night.live)
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: Night.rControl, style: .continuous).fill(Night.well))
        .overlay(RoundedRectangle(cornerRadius: Night.rControl, style: .continuous).strokeBorder(Night.line, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(recording ? "Recording, \(Int(seconds)) seconds" : "Not recording")
    }

    @ViewBuilder
    private func status(failed: Bool, passed: Bool) -> some View {
        Group {
            if working {
                HStack(spacing: 8) { CapsuleSpinner(); Text("Checking…").foregroundStyle(Night.text2) }
            } else if recording {
                Text("Read the line, then press Stop.").foregroundStyle(Night.text2)
            } else if failed, let message {
                Label(message, systemImage: "exclamationmark.circle")
                    .foregroundStyle(Night.warn)
            } else if passed {
                Label(message ?? "Got it.", systemImage: "checkmark.circle")
                    .foregroundStyle(Night.ok)
            } else if let message {
                Text(message).foregroundStyle(Night.text2)
            } else {
                Text("Press Record when you're ready.").foregroundStyle(Night.text2)
            }
        }
        .font(.nightSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(minHeight: 20, alignment: .leading)
    }

    // MARK: Done

    private var finish: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                SparkleView(size: 40, glow: true)
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(name) is ready").font(.nightDisplay).tracking(-0.3)
                    Text("\(good.count) of \(prompts.count) lines recorded. Scribe will put their name on their voice in meetings.")
                        .font(.nightSecondary).foregroundStyle(Night.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(prompts.enumerated()), id: \.offset) { k, p in
                    if k > 0 { NightDivider() }
                    HStack(spacing: 10) {
                        Image(systemName: good[p.style] != nil ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(good[p.style] != nil ? Night.accent : Night.text3)
                        Text(p.style.hint).foregroundStyle(good[p.style] != nil ? Night.text : Night.text3)
                        Spacer()
                    }
                    .font(.nightSecondary)
                    .padding(.vertical, 7)
                }
            }
            .scribeCard(padding: 12)
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                Button("Back") { index = max(0, prompts.count - 1); message = nil; lastCheck = nil }
                    .buttonStyle(.nightGhost)
                Spacer()
                Button {
                    let clips = prompts.compactMap { p in good[p.style].map { (p.style, $0) } }
                    store.enrollPerson(named: name, clips: clips)
                    dismiss()
                } label: { Text("Save").frame(minWidth: 80) }
                .scribeButton(prominent: true)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(good.count < minimumClips)
            }
        }
    }

    // MARK: Recording

    private func start() {
        message = nil
        lastCheck = nil
        levels = Array(repeating: 0, count: Self.meterBars)
        mic.onLevel = { l in
            levels.removeFirst()
            levels.append(l)
        }
        do {
            try mic.start()
            recording = true
            seconds = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
                Task { @MainActor in
                    seconds += 0.25
                    if seconds >= 20, recording, index < prompts.count { stop(style: prompts[index].style) }   // safety stop
                }
            }
        } catch {
            message = "Couldn't start the microphone: \(error.localizedDescription)"
        }
    }

    private func stop(style: EnrollmentStyle) {
        stopTimer()
        let audio = mic.stop()
        recording = false
        working = true
        Task {
            do {
                let r = try await VoiceEnrollment.process(samples: audio, style: style)
                await MainActor.run {
                    working = false
                    lastCheck = r.check
                    if let e = r.embedding {
                        good[style] = e
                        message = "Got it. Sounds clear."
                    } else {
                        message = r.check.problem ?? "That didn't come through. Try once more."
                    }
                }
            } catch {
                await MainActor.run {
                    working = false
                    message = "Couldn't check that clip. The voice models may still be loading; try again in a moment."
                }
            }
        }
    }

    private func redo(_ style: EnrollmentStyle) {
        good[style] = nil
        message = nil
        lastCheck = nil
    }

    private func next() {
        index += 1
        message = nil
        lastCheck = nil
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }
}
