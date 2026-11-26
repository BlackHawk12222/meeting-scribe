// LiveMeetingView.swift
// The Meetings page while a meeting records (0.7 "Night Sky"): the live meter card (the icon's
// capsule wave following the mic), the input, the voices Scribe already knows, and what happens
// when you stop (0.7.3.1: plus the recording-consent reminder on top). Scribe transcribes and splits speakers AFTER the recording (using the whole
// recording is what makes the speaker split reliable), so this screen shows no live transcript.

import SwiftUI

struct LiveMeetingView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: Store
    @EnvironmentObject var recorder: Recorder
    /// Snapshot: a frozen frame without a microphone.
    var preview: LivePreview?

    private var tape: LevelTape { preview?.tape ?? model.meetingTape }
    private var audioProblem: Recorder.AudioProblem? { preview?.problem ?? (preview == nil ? recorder.problem : nil) }
    private var systemAudioOn: Bool { preview?.systemAudio ?? recorder.systemAudioActive }
    private var elapsed: TimeInterval { preview?.elapsed ?? recorder.elapsed }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Text("New meeting").font(.nightDisplay).tracking(-0.3).foregroundStyle(Night.text)
                LiveChip(text: "Recording · \(Night.clock(elapsed))")
                Spacer(minLength: 12)
                Button { model.toggleMeetingRecording() } label: {
                    Label("Stop & write notes", systemImage: "stop.fill")
                }
                .buttonStyle(.nightPrimary)
                .disabled(preview == nil && !recorder.isRecording)
            }
            .frame(height: Night.headerHeight)
            VStack(spacing: Night.cardGap) {
                // 0.7.3.1: recording-consent reminder (non-blocking; see ConsentNotice.swift).
                ConsentNoticeView(reminder: model.consent)
                // 0.7.5: a source that isn't delivering sound, with the Settings page that fixes it.
                if let p = audioProblem { AudioProblemBanner(problem: p) }
                meterCard
                HStack(alignment: .top, spacing: Night.cardGap) {
                    listeningCard.frame(maxWidth: .infinity, maxHeight: .infinity)
                    VStack(spacing: Night.cardGap) {
                        voicesCard
                        // 0.7.5: the problem banner takes this card's room, so the page still fits the window.
                        if audioProblem == nil { whatsNextCard }
                        Spacer(minLength: 0)
                    }
                    .frame(width: 320)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .padding(.bottom, 28)
        }
        .padding(.leading, Night.gutterLeading)
        .padding(.trailing, Night.gutterTrailing)
    }

    // MARK: Meter

    private var meterCard: some View {
        HStack(spacing: 24) {
            TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: preview != nil)) { _ in
                CapsuleBars(levels: tape.recent(44).map { max(0.04, $0) }, barWidth: 5, spacing: 4, maxLength: 64,
                            style: .gradient, edgeFade: 0.55)
                    .animation(.easeOut(duration: 0.12), value: tape.recent(44))
            }
            .frame(maxWidth: .infinity)
            NightDivider(vertical: true).frame(height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text("Input").font(.nightMeta).foregroundStyle(Night.text3)
                Text(systemAudioOn ? "Mic + Mac sound" : "Mac microphone").font(.nightHeadline).foregroundStyle(Night.text)
                Text(recorder.noiseCleanupActive ? "Noise cleanup on · no upload" : "On-device · no upload")
                    .font(.nightMeta).foregroundStyle(Night.text3)
            }
            .frame(width: 170, alignment: .leading)
        }
        .padding(.horizontal, 24)
        .frame(height: 110)
        .background(NightCardBackground())
    }

    // MARK: Listening (where the transcript lands)

    private var listeningCard: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            SparkleView(size: 44, glow: true)
            CapsuleBars(levels: Array(repeating: 0, count: 9), barWidth: 5, spacing: 5, maxLength: 5, style: .dim)
            Text("Scribe is listening").font(.nightHeadline).foregroundStyle(Night.text)
            Text("The transcript, who said what and the notes are written on this Mac when you stop, using the whole recording.")
                .font(.nightSecondary).foregroundStyle(Night.text2)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .lineLimit(3)
                .frame(maxWidth: 380)
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NightCardBackground())
    }

    // MARK: Voices

    private var voicesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(title: "Voices Scribe knows")
            if store.people.isEmpty {
                Text("No one yet. Name a speaker after this meeting and Scribe recognizes them next time.")
                    .font(.nightSecondary).foregroundStyle(Night.text2).lineSpacing(3)
                    .lineLimit(4)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(store.people.prefix(5)) { p in
                        HStack(spacing: 10) {
                            Avatar(name: p.name, color: Palette.color(p.colorIndex), size: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.name).font(.nightHeadline).foregroundStyle(Night.text).lineLimit(1)
                                Text("\(p.meetingCount) meeting\(p.meetingCount == 1 ? "" : "s")")
                                    .font(.nightMeta).foregroundStyle(Night.text3)
                            }
                            Spacer(minLength: 0)
                            CapsuleBars(levels: CapsuleBars.wave(6, seed: CapsuleBars.seed(p.name), floor: 0.25),
                                        barWidth: 3, spacing: 2, maxLength: 16, style: .dim)
                        }
                    }
                    if store.people.count > 5 {
                        Text("and \(store.people.count - 5) more").font(.nightMeta).foregroundStyle(Night.text3)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .nightCard(padding: 20)
    }

    // MARK: After you stop

    private var whatsNextCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(title: "When you stop")
            ForEach(["The full transcript, on this Mac", "Who said what, by voice", "Summary, key points and action items"], id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Sparkle().fill(Night.star).frame(width: 8, height: 8)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    Text(line).font(.nightSecondary).foregroundStyle(Night.text)
                }
            }
            NightDivider().padding(.vertical, 4)
            Text("Nothing leaves this Mac.")
                .font(.nightMeta).foregroundStyle(Night.text3)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .nightCard(padding: 20)
    }
}

/// 0.7.5: "Scribe can't hear …" with the button that opens the right Settings page.
struct AudioProblemBanner: View {
    let problem: Recorder.AudioProblem
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: problem.pane == .systemAudio ? "speaker.slash.fill" : "mic.slash.fill")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(Night.warn)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(problem.title).font(.nightHeadline).foregroundStyle(Night.text).lineLimit(1)
                // No fixedSize: the live view must keep fitting the window (the listening card shrinks).
                Text(problem.detail).font(.nightSecondary).foregroundStyle(Night.text2)
                    .lineLimit(2).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if let pane = problem.pane {
                Button("Open Settings") { Permissions.open(pane) }
                    .buttonStyle(NightButtonStyle(kind: .secondary, height: 30))
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(NightCardBackground())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(problem.title)
    }
}
