// RecordingOverlay.swift
// The small floating capsule shown while you dictate or record a meeting (0.4; replaces
// 0.3's scroll). About 140 × 32 pt on a dark HUD material:
//   • listening:    mic-level bars + timer
//   • meeting:      red record dot + bars + timer
//   • transcribing: a small spinner + "Transcribing"
//   • done/failed:  a symbol + a short message, then it hides
//
// Where it appears: Settings › Dictation › Overlay position (bottom center by default, or
// top center / any corner), on the screen with the active window (else the mouse). It stays
// inside the screen's visible frame, so it never sits under the menu bar or the Dock.
// Drag it anywhere; Scribe remembers that spot per screen until you pick a position again.
//
// The panel is NON-ACTIVATING (the app you're typing in keeps focus, so ⌘V lands there),
// floats above other windows and shows on every Space.

import AppKit
import SwiftUI

// MARK: - Level history

/// Remembers the mic level over time (written ~10×/s by the mic, read by the capsule's bars).
/// Main thread only.
final class LevelTape {
    private(set) var t0 = Date()
    private var times: [Double] = []
    private var levels: [Float] = []
    private var floor: Float = 0.25
    /// Snapshot/preview: freeze the clock at this many seconds.
    var previewNow: Double?

    func reset() {
        t0 = Date()
        times.removeAll(keepingCapacity: true)
        levels.removeAll(keepingCapacity: true)
        floor = 0.25
        previewNow = nil
    }

    func add(_ level: Float, at t: Double? = nil) {
        times.append(t ?? Date().timeIntervalSince(t0))
        levels.append(level)
        if times.count > 600 { times.removeFirst(300); levels.removeFirst(300) }
        // Background-noise floor: drops fast, rises slowly, so steady room hum stays flat.
        floor = level < floor ? level : floor + (level - floor) * 0.01
    }

    func stop() {}
    func now(_ date: Date) -> Double { previewNow ?? date.timeIntervalSince(t0) }

    /// The last `n` levels as 0...1 bar heights (oldest first), padded with zeros.
    func recent(_ n: Int) -> [Double] {
        let tail = levels.suffix(n).map { strength($0) }
        return Array(repeating: 0, count: max(0, n - tail.count)) + tail
    }

    private func strength(_ level: Float) -> Double {
        let threshold = max(floor + 0.06, 0.2)
        return Double(min(1, max(0, (level - threshold) / 0.55)))
    }

    /// Made-up speech for screenshots: bursts of words with pauses.
    func fillPreview(seconds: Double) {
        reset()
        var t = 0.0
        while t <= seconds {
            let word = sin(t * 2.3) + 0.6 * sin(t * 5.1 + 1)
            // The last second is always mid-word, so a frozen frame shows lively bars.
            let speaking = word > -0.2 || t > seconds - 1.0
            let level: Float = speaking ? Float(0.42 + 0.42 * abs(sin(t * 5.3)) * abs(cos(t * 2.1 + 0.4))) : 0.15
            add(level, at: t)
            t += 0.1
        }
        previewNow = seconds
    }
}

// MARK: - Position

enum OverlayPosition: String, CaseIterable, Identifiable {
    case bottomCenter, topCenter, topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bottomCenter: return "Bottom center"
        case .topCenter: return "Top center"
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        }
    }
    var isTop: Bool { self == .topCenter || self == .topLeft || self == .topRight }
    var alignment: Alignment {
        switch self {
        case .topLeft, .bottomLeft: return .leading
        case .topRight, .bottomRight: return .trailing
        default: return .center
        }
    }

    static let key = "overlayPosition"
    static var current: OverlayPosition {
        get { OverlayPosition(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .bottomCenter }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// Dragged spots, one per screen: "overlayDragged.<display id>" = [x, y] of the panel's
    /// origin relative to that screen's visible frame.
    private static let draggedPrefix = "overlayDragged."
    @MainActor
    static func dragged(for screen: NSScreen) -> CGPoint? {
        guard let a = UserDefaults.standard.array(forKey: draggedPrefix + screen.scribeID) as? [Double], a.count == 2 else { return nil }
        return CGPoint(x: a[0], y: a[1])
    }
    @MainActor
    static func setDragged(_ p: CGPoint?, for screen: NSScreen) {
        if let p { UserDefaults.standard.set([Double(p.x), Double(p.y)], forKey: draggedPrefix + screen.scribeID) }
        else { UserDefaults.standard.removeObject(forKey: draggedPrefix + screen.scribeID) }
    }
    /// Picking a position in Settings forgets every dragged spot.
    @MainActor
    static func clearDragged() {
        for k in UserDefaults.standard.dictionaryRepresentation().keys where k.hasPrefix(draggedPrefix) {
            UserDefaults.standard.removeObject(forKey: k)
        }
    }
    @MainActor
    static var hasDragged: Bool {
        UserDefaults.standard.dictionaryRepresentation().keys.contains { $0.hasPrefix(draggedPrefix) }
    }
}

@MainActor
extension NSScreen {
    /// A stable id for this display (survives relaunches).
    var scribeID: String {
        guard let n = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return localizedName }
        if let u = CGDisplayCreateUUIDFromDisplayID(n.uint32Value)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, u) as String
        }
        return "\(n)"
    }

    /// The screen with the frontmost app's front window, else the one under the mouse.
    static var forOverlay: NSScreen? {
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
           let info = list.first(where: { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }),
           let dict = info[kCGWindowBounds as String] as? NSDictionary,
           let b = CGRect(dictionaryRepresentation: dict as CFDictionary),
           let primary = NSScreen.screens.first {
            // CG window bounds are top-left based on the primary screen; AppKit is bottom-left.
            let center = CGPoint(x: b.midX, y: primary.frame.maxY - b.midY)
            if let s = NSScreen.screens.first(where: { $0.frame.contains(center) }) { return s }
        }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }
}

// MARK: - Panel

/// Lets the first click on the (inactive) panel start a drag.
private final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Sizes shared by the panel and the capsule (not actor-isolated).
enum OverlayMetrics {
    /// Room for the widest message; the capsule sits inside it at the position's alignment.
    static let panelSize = NSSize(width: 320, height: 44)
    /// The capsule's usual width (used to keep it on screen when dragged).
    static let capsuleWidth: CGFloat = 140
    static let margin: CGFloat = 12
}

@MainActor
final class OverlayPanel {
    private var panel: NSPanel?
    private var screen: NSScreen?
    static let size = OverlayMetrics.panelSize
    static let capsuleWidth = OverlayMetrics.capsuleWidth
    static let margin = OverlayMetrics.margin
    /// Stack this overlay away from the screen edge (dictation over a meeting capsule).
    var lift: CGFloat = 0
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    func show<V: View>(_ content: @autoclosure () -> V) {
        let position = OverlayPosition.current
        let root = content()
            .frame(width: Self.size.width, height: Self.size.height, alignment: position.alignment)
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { [weak self] _ in self?.dragChanged() }
                .onEnded { [weak self] _ in self?.dragEnded() })
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false               // the capsule draws its own shadow
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel = p
        }
        panel?.contentView = OverlayHostingView(rootView: root)
        if panel?.isVisible != true { place(position) }
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }
    var isVisible: Bool { panel?.isVisible ?? false }

    /// The panel's frame for `position` on `screen` (no drag).
    static func frame(for position: OverlayPosition, in visible: CGRect, lift: CGFloat = 0) -> CGRect {
        let w = size.width, h = size.height
        let x: CGFloat
        switch position.alignment {
        case .leading: x = visible.minX + margin
        case .trailing: x = visible.maxX - margin - w
        default: x = visible.midX - w / 2
        }
        let y = position.isTop ? visible.maxY - margin - h - lift : visible.minY + margin + lift
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func place(_ position: OverlayPosition) {
        guard let s = NSScreen.forOverlay else { return }
        screen = s
        let visible = s.visibleFrame
        var origin = Self.frame(for: position, in: visible, lift: lift).origin
        if let d = OverlayPosition.dragged(for: s) {
            origin = clamp(NSPoint(x: visible.minX + d.x, y: visible.minY + d.y + (position.isTop ? -lift : lift)),
                           position: position, visible: visible)
        }
        panel?.setFrameOrigin(origin)
    }

    /// Keep the capsule (not the whole transparent panel) inside the visible frame.
    private func clamp(_ o: NSPoint, position: OverlayPosition, visible: CGRect) -> NSPoint {
        let w = Self.size.width, cw = Self.capsuleWidth
        let capLeft: CGFloat
        switch position.alignment {
        case .leading: capLeft = 0
        case .trailing: capLeft = w - cw
        default: capLeft = (w - cw) / 2
        }
        let x = min(max(o.x, visible.minX + 4 - capLeft), visible.maxX - 4 - capLeft - cw)
        let y = min(max(o.y, visible.minY + 4), visible.maxY - 4 - Self.size.height)
        return NSPoint(x: x, y: y)
    }

    private func dragChanged() {
        guard let p = panel else { return }
        let mouse = NSEvent.mouseLocation
        if dragStart == nil { dragStart = (mouse, p.frame.origin) }
        guard let start = dragStart else { return }
        p.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y))
    }

    private func dragEnded() {
        defer { dragStart = nil }
        guard let p = panel else { return }
        let center = NSPoint(x: p.frame.midX, y: p.frame.midY)
        guard let s = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? screen else { return }
        let visible = s.visibleFrame
        let position = OverlayPosition.current
        let o = clamp(p.frame.origin, position: position, visible: visible)
        p.setFrameOrigin(o)
        screen = s
        OverlayPosition.setDragged(CGPoint(x: o.x - visible.minX, y: o.y - visible.minY + (position.isTop ? lift : -lift)), for: s)
    }
}

// MARK: - The capsule

/// What the capsule shows.
enum OverlayMode: Equatable {
    case listening           // dictation
    case recording           // meeting (red dot)
    case transcribing
    case message(String, failure: Bool)
    case hidden
}

struct OverlayCapsule: View {
    var mode: OverlayMode
    var tape: LevelTape
    /// Seconds to show in the timer (nil = the tape's clock).
    var elapsed: TimeInterval? = nil
    /// Snapshot: fixed spinner angle (degrees).
    var previewSpin: Double? = nil

    static let height: CGFloat = 32
    static let bars = 9

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: mode == .hidden || isMessage || previewSpin != nil)) { tl in
            content(tl.date)
                .padding(.horizontal, 14)
                .frame(minWidth: isMessage ? nil : OverlayMetrics.capsuleWidth, maxWidth: 300)
                .fixedSize(horizontal: true, vertical: false)
                .frame(height: Self.height)
                .background {
                    Capsule().fill(.ultraThinMaterial)
                    Capsule().fill(Color(white: 0.09).opacity(0.78))
                }
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        }
        .opacity(mode == .hidden ? 0 : 1)
        .environment(\.colorScheme, .dark)
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
    }

    private var isMessage: Bool { if case .message = mode { return true }; return false }

    @ViewBuilder private func content(_ date: Date) -> some View {
        switch mode {
        case .listening, .recording:
            HStack(spacing: 10) {
                if mode == .recording {
                    Circle().fill(Brand.record).frame(width: 8, height: 8)
                        .opacity(0.88 + 0.12 * sin(tape.now(date) * 3))
                }
                LevelBars(levels: tape.recent(Self.bars))
                Text(clock(elapsed ?? tape.now(date)))
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize()
            }
        case .transcribing:
            HStack(spacing: 8) {
                Spinner(angle: previewSpin ?? (date.timeIntervalSinceReferenceDate * 360).truncatingRemainder(dividingBy: 360))
                Text("Transcribing")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize()
            }
        case .message(let text, let failure):
            HStack(spacing: 6) {
                Image(systemName: failure ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(failure ? Color.orange : Color.green)
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        case .hidden:
            EmptyView()
        }
    }

    private func clock(_ t: TimeInterval) -> String {
        let secs = max(0, Int(t))
        return secs >= 3600 ? String(format: "%d:%02d:%02d", secs / 3600, secs / 60 % 60, secs % 60)
                            : String(format: "%d:%02d", secs / 60, secs % 60)
    }

    private var accessibilityText: String {
        switch mode {
        case .listening: return "Scribe is listening"
        case .recording: return "Scribe is recording a meeting"
        case .transcribing: return "Scribe is transcribing"
        case .message(let t, _): return t
        case .hidden: return ""
        }
    }
}

/// Small vertical bars driven by the mic level (newest on the right), shaped by a soft
/// envelope (taller in the middle) so it reads as a voice, not a barcode.
struct LevelBars: View {
    var levels: [Double]
    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { i, l in
                let x = levels.count > 1 ? Double(i) / Double(levels.count - 1) * 2 - 1 : 0
                let envelope = 0.45 + 0.55 * cos(x * .pi / 2)
                Capsule()
                    .fill(Color.white.opacity(0.6 + 0.35 * l))
                    .frame(width: 2.5, height: 3 + 15 * l * envelope)
            }
        }
        .frame(height: 18)
        .animation(.easeOut(duration: 0.12), value: levels)
    }
}

/// A thin rotating arc.
struct Spinner: View {
    var angle: Double
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.18), lineWidth: 1.8)
            Circle().trim(from: 0, to: 0.28)
                .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .rotationEffect(.degrees(angle))
        }
        .frame(width: 12, height: 12)
    }
}

// MARK: - The two live overlays

/// Dictation capsule: follows DictationController.
struct DictationOverlayView: View {
    @EnvironmentObject var dictation: DictationController
    var body: some View {
        OverlayCapsule(mode: mode, tape: dictation.tape)
    }
    private var mode: OverlayMode {
        switch dictation.state {
        case .listening: return .listening
        case .transcribing: return .transcribing
        case .done(let m): return .message(m, failure: false)
        case .failed(let m): return .message(m, failure: true)
        case .idle: return .hidden
        }
    }
}

/// Meeting capsule: follows the Recorder.
struct MeetingOverlayView: View {
    @ObservedObject var recorder: Recorder
    var tape: LevelTape
    var body: some View {
        OverlayCapsule(mode: recorder.isRecording ? .recording : .hidden, tape: tape, elapsed: recorder.elapsed)
    }
}
