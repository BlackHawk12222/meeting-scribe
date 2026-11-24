// VoiceEnrollmentView.swift
// "Add person": guided voice enrollment. Plain system controls on purpose (the app's look is being
// redesigned separately); show it as a sheet, e.g.
//     .sheet(isPresented: $showEnroll) { VoiceEnrollmentView().environmentObject(store) }
//
// Flow: type a name → read 6 short prompts (≈ 30–45 s in total) → each clip is checked
// (level, clipping, background noise, at least 4 s of speech) and must be redone if it fails →
// Save puts one voice sample per clip into the voice library.

import SwiftUI

struct VoiceEnrollmentView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var started = false
    @State private var index = 0
    @State private var recording = false
    @State private var working = false
    @State private var level: Float = 0
    @State private var seconds = 0.0
    @State private var message: String?
    @State private var good: [EnrollmentStyle: [Float]] = [:]
    @State private var lastCheck: VoiceEnrollment.ClipCheck?
    @State private var mic = MicCapture()
    @State private var timer: Timer?

    private let prompts = VoiceEnrollment.prompts
    /// At least this many good clips before Save is allowed (the free-talk one can be skipped).
    private let minimumClips = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !started { intro } else if index < prompts.count { promptStep } else { finish }
        }
        .padding(24)
        .frame(width: 520)
        .onDisappear { stopTimer(); if recording { _ = mic.stop() } }
    }

    // MARK: Steps

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a person").font(.title2).bold()
            Text("They read six short lines out loud in a quiet room (about 30–45 seconds). Each line asks for a different way of talking, so Scribe can recognize them in meetings, even in a noisy room.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Start") { started = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var promptStep: some View {
        let p = prompts[index]
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Line \(index + 1) of \(prompts.count)").foregroundStyle(.secondary)
                Spacer()
                Text(name).foregroundStyle(.secondary)
            }
            ProgressView(value: Double(index), total: Double(prompts.count))
            Text(p.style.title).font(.headline)
            GroupBox {
                Text(p.text)
                    .font(.title3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(6)
            }
            if recording {
                HStack {
                    Image(systemName: "mic.fill").foregroundStyle(.red)
                    ProgressView(value: Double(level))
                    Text(String(format: "%.0f s", seconds)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if working { ProgressView("Checking…").controlSize(.small) }
            if let message {
                Label(message, systemImage: lastCheck?.ok == true ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(lastCheck?.ok == true ? Color.green : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancel") { if recording { _ = mic.stop() }; dismiss() }
                Spacer()
                if p.style == .free && !recording && good[p.style] == nil && good.count >= minimumClips {
                    Button("Skip") { next() }
                }
                if recording {
                    Button("Stop") { stop(style: p.style) }.keyboardShortcut(.defaultAction)
                } else if good[p.style] != nil {
                    Button("Redo") { good[p.style] = nil; message = nil; lastCheck = nil }
                    Button("Next") { next() }.keyboardShortcut(.defaultAction)
                } else {
                    Button(lastCheck == nil ? "Record" : "Try again") { start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(working)
                }
            }
        }
    }

    private var finish: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ready to save").font(.title2).bold()
            Text("\(good.count) of \(prompts.count) lines recorded for \(name).")
            ForEach(prompts) { p in
                Label(p.style.title, systemImage: good[p.style] != nil ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(good[p.style] != nil ? Color.primary : Color.secondary)
            }
            HStack {
                Button("Back") { index = max(0, prompts.count - 1) }
                Spacer()
                Button("Save") {
                    let clips = prompts.compactMap { p in good[p.style].map { (p.style, $0) } }
                    store.enrollPerson(named: name, clips: clips)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(good.count < minimumClips)
            }
        }
    }

    // MARK: Recording

    private func start() {
        message = nil
        lastCheck = nil
        mic.onLevel = { level = $0 }
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
                        message = String(format: "Good — %.1f s of speech, %.0f dB above the room.", r.check.speechSeconds, r.check.snrDB)
                    } else {
                        message = r.check.problem ?? "Please try again."
                    }
                }
            } catch {
                await MainActor.run {
                    working = false
                    message = "Couldn't check that clip: \(error.localizedDescription). The speaker models may still be loading."
                }
            }
        }
    }

    private func next() {
        index += 1
        message = nil
        lastCheck = nil
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }
}
