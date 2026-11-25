// LiveMeetingView.swift
// The Meetings page while a meeting records (0.7 "Night Sky"): the live meter card (the icon's
// capsule wave following the mic), the input, the voices Scribe already knows, and what happens
// when you stop. Scribe transcribes and splits speakers AFTER the recording (using the whole
// recording is what makes the speaker split reliable), so this screen shows no live transcript.

import SwiftUI

struct LiveMeetingView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: Store
    @EnvironmentObject var recorder: Recorder
    /// Snapshot: a frozen frame without a microphone.
    var preview: LivePreview?

    private var tape: LevelTape { preview?.tape ?? model.meetingTape }
    private var elapsed: TimeInterval { preview?.elapsed ?? recorder.elapsed }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Text("New meeting").font(.nightDisplay).tracking(-0.3).foregroundStyle(Night.text)
                LiveChip(text: "Recording · \(Exporter.clock(elapsed))")
                Spacer(minLength: 12)
                Button { model.toggleMeetingRecording() } label: {
                    Label("Stop & write notes", systemImage: "stop.fill")
                }
                .buttonStyle(.nightPrimary)
                .disabled(preview == nil && !recorder.isRecording)
            }
            .frame(height: Night.headerHeight)
            VStack(spacing: Night.cardGap) {
                meterCard
                HStack(alignment: .top, spacing: Night.cardGap) {
                    voicesCard.frame(maxWidth: .infinity)
                    whatsNextCard.frame(width: 300)
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
                Text("Mac microphone").font(.scribe(13.5, 700)).foregroundStyle(Night.text)
                Text(recorder.noiseCleanupActive ? "Noise cleanup on · no upload" : "On-device · no upload")
                    .font(.nightMeta).foregroundStyle(Night.text3)
            }
            .frame(width: 170, alignment: .leading)
        }
        .padding(.horizontal, 24)
        .frame(height: 110)
        .background(NightCardBackground())
    }

    // MARK: Voices

    private var voicesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(title: "Voices Scribe knows")
            if store.people.isEmpty {
                Text("No one yet. After this meeting, click a speaker and give them a name, and Scribe will recognize that voice next time.")
                    .font(.nightSecondary).foregroundStyle(Night.text2).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], alignment: .leading, spacing: 10) {
                    ForEach(store.people) { p in
                        HStack(spacing: 10) {
                            Avatar(name: p.name, color: Palette.color(p.colorIndex), size: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.name).font(.scribe(13.5, 700)).foregroundStyle(Night.text).lineLimit(1)
                                Text("\(p.meetingCount) meeting\(p.meetingCount == 1 ? "" : "s")")
                                    .font(.scribe(11.5, 600)).foregroundStyle(Night.text3)
                            }
                            Spacer(minLength: 0)
                            CapsuleBars(levels: CapsuleBars.wave(6, seed: CapsuleBars.seed(p.name), floor: 0.25),
                                        barWidth: 3, spacing: 2, maxLength: 16, style: .dim)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Night.well))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Night.line, lineWidth: 1))
                    }
                }
                Text("When you stop, Scribe tells the voices apart and puts these names on the ones it recognizes.")
                    .font(.nightMeta).foregroundStyle(Night.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .nightCard(padding: 22)
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
            Text("Notes write themselves when you stop. Nothing leaves this Mac.")
                .font(.nightMeta).foregroundStyle(Night.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .nightCard(padding: 22)
    }
}
