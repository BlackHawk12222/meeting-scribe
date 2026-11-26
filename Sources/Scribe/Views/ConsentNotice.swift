// ConsentNotice.swift
// 0.7.3.1: a small, non-blocking reminder at the top of the live meeting view when a meeting
// recording starts: "Let everyone know you're recording. Some places require everyone's OK."
// It never stops or delays the recording. × hides it for this meeting; "Don't show again" hides
// it for good (UserDefaults `consentReminderHidden`). Poster style, light + dark.

import SwiftUI

@MainActor
final class ConsentReminder: ObservableObject {
    static let hiddenKey = "consentReminderHidden"
    static let message = "Let everyone know you're recording. Some places require everyone's OK."

    private let defaults: UserDefaults
    /// True while the notice is on screen (from recording start until closed or stopped).
    @Published private(set) var isShowing = false

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// "Don't show again" was pressed at some point.
    var neverShow: Bool { defaults.bool(forKey: Self.hiddenKey) }

    /// AppModel calls this from the recorder's isRecording publisher.
    func recordingChanged(_ on: Bool) { if on { meetingStarted() } else { meetingStopped() } }
    /// Called when a meeting recording starts.
    func meetingStarted() { isShowing = !neverShow }
    /// Called when the recording stops.
    func meetingStopped() { isShowing = false }
    /// × : hide it for this meeting only.
    func close() { isShowing = false }
    /// "Don't show again": hide it now and on every later meeting.
    func dontShowAgain() {
        defaults.set(true, forKey: Self.hiddenKey)
        isShowing = false
    }
    /// Snapshots: show it without a recording.
    func showForPreview() { isShowing = true }
}

/// The notice itself: a hairline card with an indigo tile, the message, "Don't show again" and ×.
struct ConsentNoticeView: View {
    @ObservedObject var reminder: ConsentReminder

    var body: some View {
        Group {
            if reminder.isShowing {
                HStack(spacing: 12) {
                    Image(systemName: "person.2")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.white)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: Night.rControl, style: .continuous).fill(Night.posterIndigo))
                        .accessibilityHidden(true)
                    Text(ConsentReminder.message)
                        .font(.nightBody).foregroundStyle(Night.text)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Don't show again") { withAnimation(Night.base) { reminder.dontShowAgain() } }
                        .buttonStyle(.nightSecondary)
                    Button { withAnimation(Night.base) { reminder.close() } } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.nightGhost)
                    .help("Hide for this meeting")
                    .accessibilityLabel("Hide for this meeting")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(NightCardBackground())
                .transition(.opacity.combined(with: .move(edge: .top)))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("consent-notice")
            }
        }
    }
}
