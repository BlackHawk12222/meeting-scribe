// RecordingOverlay.swift
// The small floating capsule shown while you dictate or record a meeting. 0.7 "Night Sky":
// a 52 pt pill that is always the icon's dark tile (#1E1E22 → #09090B, 1 px white@9% edge),
// whatever the theme, so it reads as a piece of the icon over any app. No material, no glass.
//   • listening:    glowing sparkle → live wave (14 capsule bars) → "Listening" → timer
//   • meeting:      live dot + mini wave → "Meeting · mm:ss"
//   • transcribing: dim flat bars + "Writing…"
//   • done/failed:  an accent check (or a warning) + a short message, then it hides
//
// Where it appears: Settings › Dictation › Overlay position (bottom center by default, or
// top center / any corner / the left or right edge), on the screen with the active window
// (else the mouse). It stays inside the screen's visible frame, so it never sits under the
// menu bar or the Dock. Drag it anywhere; Scribe remembers that spot (and its orientation)
// per screen until you pick a position again.
//
// Against the left or right edge (a side preset, or dropped within ~80 pt of a side and away
// from the corners) the capsule stands up: a tall narrow pill, bars stacked down the long axis,
// status icon on top and timer below. It springs between the two shapes in ~0.3 s.
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
    // Declaration order = order in the Settings picker (raw values are what's stored).
    case topLeft, topCenter, topRight, middleLeft, middleRight, bottomLeft, bottomCenter, bottomRight
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bottomCenter: return "Bottom center"
        case .topCenter: return "Top center"
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        case .middleLeft: return "Left edge"
        case .middleRight: return "Right edge"
        }
    }
    var isTop: Bool { self == .topCenter || self == .topLeft || self == .topRight }
    /// Left/right edge presets: the capsule stands up (vertical layout).
    var isSide: Bool { self == .middleLeft || self == .middleRight }
    var alignment: Alignment {
        switch self {
        case .topLeft, .bottomLeft, .middleLeft: return .leading
        case .topRight, .bottomRight, .middleRight: return .trailing
        default: return .center
        }
    }

    static let key = "overlayPosition"
    static var current: OverlayPosition {
        get { OverlayPosition(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .bottomCenter }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// A dragged spot: the capsule's center relative to the screen's visible frame (without
    /// any stacking lift), plus whether it stood vertical against a side edge.
    struct DraggedSpot: Equatable {
        var center: CGPoint
        var vertical: Bool
    }

    /// Dragged spots, one per screen: "overlayDragged2.<display id>" = [cx, cy, vertical 0/1].
    /// (0.5's "overlayDragged.<id>" stored the panel origin; it is ignored and cleared.)
    private static let draggedPrefix = "overlayDragged2."
    private static let legacyPrefix = "overlayDragged."
    @MainActor
    static func dragged(for screen: NSScreen) -> DraggedSpot? {
        guard let a = UserDefaults.standard.array(forKey: draggedPrefix + screen.scribeID) as? [Double], a.count >= 2 else { return nil }
        return DraggedSpot(center: CGPoint(x: a[0], y: a[1]), vertical: a.count > 2 && a[2] > 0.5)
    }
    @MainActor
    static func setDragged(_ spot: DraggedSpot?, for screen: NSScreen) {
        if let s = spot {
            UserDefaults.standard.set([Double(s.center.x), Double(s.center.y), s.vertical ? 1 : 0], forKey: draggedPrefix + screen.scribeID)
        } else {
            UserDefaults.standard.removeObject(forKey: draggedPrefix + screen.scribeID)
        }
    }
    /// Picking a position in Settings forgets every dragged spot.
    @MainActor
    static func clearDragged() {
        for k in UserDefaults.standard.dictionaryRepresentation().keys where k.hasPrefix(draggedPrefix) || k.hasPrefix(legacyPrefix) {
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

/// The overlay window: NEVER becomes key or main, so the app you're typing in keeps keyboard
/// focus the whole time (⌘V and Accessibility inserts land there, not in Scribe).
final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets the first click on the (inactive) panel start a drag.
private final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Sizes shared by the panel and the capsule (not actor-isolated).
enum OverlayMetrics {
    /// Room for the widest message; the capsule sits inside it at the position's alignment.
    static let panelSize = NSSize(width: 400, height: 72)
    /// Against a side edge the panel is taller, so the standing capsule (and a message that
    /// still needs a horizontal line) both fit, anchored to that edge.
    static let verticalPanelSize = NSSize(width: 400, height: 240)
    /// The capsule's usual width (used to keep it on screen when dragged).
    static let capsuleWidth: CGFloat = 210
    /// The standing capsule: its width, and its usual height (listening/meeting).
    static let verticalThickness: CGFloat = 52
    static let verticalLength: CGFloat = 190
    static let margin: CGFloat = 12
    /// A capsule whose side is this close to the left/right edge stands up (unless it is also
    /// near the top or bottom: corners stay horizontal).
    static let sideSnap: CGFloat = 80
    static let cornerZone: CGFloat = 120
    /// The orientation change: a short spring.
    static let springDuration: Double = 0.3
}

/// Tells the capsule to use its standing (vertical) layout.
private struct OverlayVerticalKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var overlayVertical: Bool {
        get { self[OverlayVerticalKey.self] }
        set { self[OverlayVerticalKey.self] = newValue }
    }
}

/// Where the panel goes and how the capsule sits inside it.
struct OverlayTarget: Equatable {
    var frame: CGRect
    var alignment: Alignment
    var vertical: Bool
}

/// Live layout shared by OverlayPanel (AppKit) and the panel's SwiftUI root.
@MainActor
final class OverlayLayout: ObservableObject {
    @Published var vertical = false
    @Published var alignment: Alignment = .center
    /// Only non-zero while an orientation change animates inside a temporarily larger panel.
    @Published var offset: CGSize = .zero
    /// The capsule's frame in the panel's content (top-left origin), measured by the root.
    var capsuleRect: CGRect = .zero
}

private struct OverlayRoot<Content: View>: View {
    @ObservedObject var layout: OverlayLayout
    var content: Content
    var onDrag: () -> Void
    var onDragEnd: () -> Void

    var body: some View {
        content
            .environment(\.overlayVertical, layout.vertical)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("overlayPanel")) } action: { layout.capsuleRect = $0 }
            .offset(layout.offset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: layout.alignment)
            .coordinateSpace(.named("overlayPanel"))
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { _ in onDrag() }
                .onEnded { _ in onDragEnd() })
    }
}

@MainActor
final class OverlayPanel {
    private var panel: NSPanel?
    private var screen: NSScreen?
    let layout = OverlayLayout()
    static let size = OverlayMetrics.panelSize
    static let verticalSize = OverlayMetrics.verticalPanelSize
    static let capsuleWidth = OverlayMetrics.capsuleWidth
    static let margin = OverlayMetrics.margin
    /// Stack this overlay away from the screen edge (dictation over a meeting capsule).
    var lift: CGFloat = 0
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    /// Bumped on every placement, so a stale "settle" after an animation is skipped.
    private var generation = 0

    func show<V: View>(_ content: @autoclosure () -> V) {
        let root = OverlayRoot(layout: layout, content: content(),
                               onDrag: { [weak self] in self?.dragChanged() },
                               onDragEnd: { [weak self] in self?.dragEnded() })
        if panel == nil {
            let p = NonActivatingPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                                       styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            p.becomesKeyOnlyIfNeeded = true
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false               // the capsule draws its own shadow
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel = p
        }
        panel?.contentView = OverlayHostingView(rootView: root)
        if panel?.isVisible != true { place() }
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }
    /// For the self-test: the panel's focus rules.
    var focusRules: (nonActivating: Bool, canBecomeKey: Bool, canBecomeMain: Bool)? {
        guard let p = panel else { return nil }
        return (p.styleMask.contains(.nonactivatingPanel), p.canBecomeKey, p.canBecomeMain)
    }
    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: Geometry (pure, AppKit coordinates)

    /// The panel's frame for `position` on a screen with this visible frame (no drag).
    static func frame(for position: OverlayPosition, in visible: CGRect, lift: CGFloat = 0) -> CGRect {
        target(for: position, in: visible, lift: lift).frame
    }

    /// Frame, alignment and orientation for a preset.
    static func target(for position: OverlayPosition, in visible: CGRect, lift: CGFloat = 0) -> OverlayTarget {
        if position.isSide {
            let half = OverlayMetrics.verticalThickness / 2
            let cx = position == .middleLeft ? visible.minX + margin + half : visible.maxX - margin - half
            return target(center: CGPoint(x: cx, y: visible.midY), vertical: true, in: visible, lift: lift)
        }
        let w = size.width, h = size.height
        let x: CGFloat
        switch position.alignment {
        case .leading: x = visible.minX + margin
        case .trailing: x = visible.maxX - margin - w
        default: x = visible.midX - w / 2
        }
        let y = position.isTop ? visible.maxY - margin - h - lift : visible.minY + margin + lift
        return OverlayTarget(frame: CGRect(x: x, y: y, width: w, height: h), alignment: position.alignment, vertical: false)
    }

    /// Frame, alignment and orientation for a dragged spot (capsule center `c`, no lift).
    /// Vertical: snapped to the nearer side edge, kept clear of the top and bottom. Horizontal:
    /// kept inside the visible frame; near a side it anchors to that side so wider messages grow
    /// inward instead of off screen.
    static func target(center c: CGPoint, vertical: Bool, in visible: CGRect, lift: CGFloat = 0) -> OverlayTarget {
        let w = size.width
        if vertical {
            let left = c.x < visible.midX
            let h = verticalSize.height
            let half = OverlayMetrics.verticalLength / 2
            let cy = min(max(c.y, visible.minY + 4 + half), visible.maxY - 4 - half)
            let x = left ? visible.minX + margin + lift : visible.maxX - margin - lift - w
            return OverlayTarget(frame: CGRect(x: x, y: cy - h / 2, width: w, height: h),
                                 alignment: left ? .leading : .trailing, vertical: true)
        }
        let h = size.height, cw = capsuleWidth
        let top = c.y > visible.midY
        let cy = min(max(c.y + (top ? -lift : lift), visible.minY + 4 + h / 2), visible.maxY - 4 - h / 2)
        let cx = min(max(c.x, visible.minX + 4 + cw / 2), visible.maxX - 4 - cw / 2)
        let alignment: Alignment
        let x: CGFloat
        if cx - cw / 2 - visible.minX < OverlayMetrics.sideSnap {
            alignment = .leading; x = cx - cw / 2
        } else if visible.maxX - (cx + cw / 2) < OverlayMetrics.sideSnap {
            alignment = .trailing; x = cx + cw / 2 - w
        } else {
            alignment = .center; x = cx - w / 2
        }
        return OverlayTarget(frame: CGRect(x: x, y: cy - h / 2, width: w, height: h), alignment: alignment, vertical: false)
    }

    /// Should a capsule dropped at `r` stand up? Its side is within ~80 pt of the left or right
    /// edge, and it is not in a top/bottom corner zone.
    static func wantsVertical(capsule r: CGRect, in visible: CGRect) -> Bool {
        let side = r.minX - visible.minX < OverlayMetrics.sideSnap || visible.maxX - r.maxX < OverlayMetrics.sideSnap
        let corner = r.midY - visible.minY < OverlayMetrics.cornerZone || visible.maxY - r.midY < OverlayMetrics.cornerZone
        return side && !corner
    }

    /// The point of `rect` that `alignment` pins (AppKit coordinates, y up).
    private static func anchor(_ alignment: Alignment, of r: CGRect) -> CGPoint {
        let x: CGFloat = alignment.horizontal == .leading ? r.minX : alignment.horizontal == .trailing ? r.maxX : r.midX
        let y: CGFloat = alignment.vertical == .top ? r.maxY : alignment.vertical == .bottom ? r.minY : r.midY
        return CGPoint(x: x, y: y)
    }

    // MARK: Placement

    /// Where the capsule is on screen right now (from the root's measurement).
    private var capsuleScreenRect: CGRect? {
        guard let p = panel, layout.capsuleRect.width > 1, layout.capsuleRect.height > 1 else { return nil }
        let r = layout.capsuleRect
        return CGRect(x: p.frame.minX + r.minX, y: p.frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    private func place() {
        guard let s = NSScreen.forOverlay else { return }
        screen = s
        let visible = s.visibleFrame
        let t: OverlayTarget
        if let d = OverlayPosition.dragged(for: s) {
            t = Self.target(center: CGPoint(x: visible.minX + d.center.x, y: visible.minY + d.center.y),
                            vertical: d.vertical, in: visible, lift: lift)
        } else {
            t = Self.target(for: OverlayPosition.current, in: visible, lift: lift)
        }
        apply(t, animated: false)
    }

    private func withoutAnimation(_ body: () -> Void) {
        var tr = Transaction()
        tr.disablesAnimations = true
        withTransaction(tr, body)
    }

    /// Moves the panel to `t`. Animated: the panel briefly grows to cover the old and new spots,
    /// the capsule springs from where it was to its new place and shape (~0.3 s), then the panel
    /// shrinks back to the new frame.
    private func apply(_ t: OverlayTarget, animated: Bool) {
        guard let p = panel else { return }
        generation += 1
        guard animated, p.isVisible, let old = capsuleScreenRect else {
            withoutAnimation {
                layout.vertical = t.vertical
                layout.alignment = t.alignment
                layout.offset = .zero
            }
            p.setFrame(t.frame, display: true)
            return
        }
        let union = p.frame.union(t.frame)
        let a = t.alignment
        let start = Self.anchor(a, of: old), end = Self.anchor(a, of: t.frame), base = Self.anchor(a, of: union)
        withoutAnimation {
            layout.alignment = a
            layout.offset = CGSize(width: start.x - base.x, height: -(start.y - base.y))
        }
        p.setFrame(union, display: true)
        p.contentView?.layoutSubtreeIfNeeded()
        withAnimation(.spring(duration: OverlayMetrics.springDuration, bounce: 0.12)) {
            layout.vertical = t.vertical
            layout.offset = CGSize(width: end.x - base.x, height: -(end.y - base.y))
        }
        let gen = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((OverlayMetrics.springDuration + 0.08) * 1_000_000_000))
            guard let self, self.generation == gen, let p = self.panel else { return }
            self.withoutAnimation { self.layout.offset = .zero }
            p.setFrame(t.frame, display: true)
        }
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
        guard panel != nil, let cap = capsuleScreenRect else { return }
        let center = CGPoint(x: cap.midX, y: cap.midY)
        guard let s = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? screen else { return }
        let visible = s.visibleFrame
        let vertical = Self.wantsVertical(capsule: cap, in: visible)
        // Remember the spot without this overlay's stacking lift.
        var base = center
        if !vertical { base.y += center.y > visible.midY ? lift : -lift }
        screen = s
        OverlayPosition.setDragged(.init(center: CGPoint(x: base.x - visible.minX, y: base.y - visible.minY), vertical: vertical), for: s)
        apply(Self.target(center: base, vertical: vertical, in: visible, lift: lift), animated: true)
    }
}

// MARK: - The capsule

/// What the capsule shows.
enum OverlayMode: Equatable {
    case listening           // dictation
    case recording           // meeting (red dot)
    case transcribing
    case message(String, failure: Bool)
    /// "Needs Accessibility to type · Fix"
    case needsAccess
    case hidden
}

struct OverlayCapsule: View {
    var mode: OverlayMode
    var tape: LevelTape
    /// Seconds to show in the timer (nil = the tape's clock).
    var elapsed: TimeInterval? = nil
    /// Snapshot: freeze the frame (the old spinner angle; any value freezes it).
    var previewSpin: Double? = nil
    /// Set by the panel when the capsule sits against a left/right screen edge.
    @Environment(\.overlayVertical) private var verticalEdge

    static let height: CGFloat = 52
    static let bars = 14

    var body: some View {
        let v = vertical
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: mode == .hidden || isMessage || previewSpin != nil)) { tl in
            content(tl.date, vertical: v)
                .padding(.horizontal, v ? 0 : 18)
                .padding(.vertical, v ? 16 : 0)
                .frame(minWidth: v || isMessage ? nil : OverlayMetrics.capsuleWidth, maxWidth: v ? nil : 340)
                .fixedSize(horizontal: !v, vertical: v)
                .frame(width: v ? OverlayMetrics.verticalThickness : nil, height: v ? nil : Self.height)
                .modifier(NightCapsuleSurface())
        }
        .animation(.spring(duration: OverlayMetrics.springDuration, bounce: 0.12), value: v)
        .opacity(mode == .hidden ? 0 : 1)
        .scaleEffect(mode == .hidden ? 0.9 : 1)
        .animation(.easeOut(duration: 0.2), value: mode == .hidden)
        .environment(\.colorScheme, .dark)
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
    }

    private var isMessage: Bool {
        switch mode { case .message, .needsAccess: return true; default: return false }
    }

    /// Standing layout: against a side edge, except for text that needs a line of its own
    /// (long messages, the Accessibility prompt), which reads horizontally from that edge.
    private var vertical: Bool {
        guard verticalEdge else { return false }
        switch mode {
        case .needsAccess: return false
        case .message(let text, _): return text.count <= 6
        default: return true
        }
    }

    private func stack(_ vertical: Bool, h: CGFloat, v: CGFloat) -> AnyLayout {
        vertical ? AnyLayout(VStackLayout(spacing: v)) : AnyLayout(HStackLayout(spacing: h))
    }

    private var textColor: Color { Color.white.opacity(0.92) }

    /// The live wave: the last N mic levels shaped by a soft envelope, so it travels left to
    /// right and settles to dots at idle.
    private func wave(_ n: Int, _ date: Date) -> [Double] {
        let raw = tape.recent(n)
        return raw.enumerated().map { i, l in
            let x = n > 1 ? Double(i) / Double(n - 1) * 2 - 1 : 0
            let envelope = 0.45 + 0.55 * cos(x * .pi / 2)
            return l * envelope
        }
    }

    @ViewBuilder private func content(_ date: Date, vertical: Bool) -> some View {
        switch mode {
        case .listening:
            let layout = stack(vertical, h: 12, v: 12)
            layout {
                SparkleView(size: 13, glow: true, color: Night.overlayStar)
                CapsuleBars(levels: wave(vertical ? 12 : Self.bars, date), axis: vertical ? .vertical : .horizontal,
                            barWidth: 3.5, spacing: vertical ? 3 : 2.5, maxLength: vertical ? 24 : 26, style: .white, edgeFade: 0.35)
                    .animation(.easeOut(duration: 0.12), value: tape.recent(4))
                if !vertical {
                    Text("Listening").font(.scribe(13, 700)).foregroundStyle(textColor).fixedSize()
                }
                timer(date, vertical: vertical)
            }
        case .recording:
            let layout = stack(vertical, h: 10, v: 12)
            layout {
                Circle().fill(Night.overlayLive).frame(width: 8, height: 8)
                    .opacity(0.88 + 0.12 * sin(tape.now(date) * 3))
                CapsuleBars(levels: wave(vertical ? 10 : 8, date), axis: vertical ? .vertical : .horizontal,
                            barWidth: 3, spacing: 2, maxLength: vertical ? 22 : 20, style: .white)
                if vertical {
                    timer(date, vertical: true)
                } else {
                    HStack(spacing: 5) {
                        Text("Meeting").font(.scribe(13, 700)).foregroundStyle(textColor)
                        Text("·").font(.scribe(13, 700)).foregroundStyle(Color.white.opacity(0.5))
                        timer(date, vertical: false)
                    }
                    .fixedSize()
                }
            }
        case .transcribing:
            let layout = stack(vertical, h: 10, v: 12)
            layout {
                if vertical { SparkleView(size: 13, glow: true, color: Night.overlayStar) }
                CapsuleBars(levels: Array(repeating: 0.12, count: vertical ? 6 : 6), axis: vertical ? .vertical : .horizontal,
                            barWidth: 4, spacing: 3, maxLength: 12, style: .white)
                    .opacity(0.45)
                if !vertical {
                    Text("Writing…").font(.scribe(13, 700)).foregroundStyle(textColor).fixedSize()
                }
            }
        case .message(let text, let failure):
            let layout = stack(vertical, h: 8, v: 6)
            layout {
                ZStack {
                    Circle().fill(failure ? AnyShapeStyle(Color(hex: 0xF4BE93)) :
                                    AnyShapeStyle(LinearGradient(colors: [Night.overlayAccentTop, Night.overlayAccentBottom],
                                                                 startPoint: .top, endPoint: .bottom)))
                    Image(systemName: failure ? "exclamationmark" : "checkmark")
                        .font(.system(size: 8.5, weight: .heavy)).foregroundStyle(Color(hex: 0x0D0C1A))
                }
                .frame(width: 16, height: 16)
                Text(text)
                    .font(.scribe(vertical ? 10.5 : 13, 700))
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                    .minimumScaleFactor(vertical ? 0.8 : 1)
                    .truncationMode(.tail)
            }
        case .needsAccess:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(hex: 0xF4BE93))
                Text("Copied · needs Accessibility to type")
                    .font(.scribe(13, 700)).foregroundStyle(textColor)
                    .lineLimit(1).fixedSize()
                Button("Fix") { AccessibilityHelp.fix() }
                    .buttonStyle(.plain)
                    .font(.scribe(12.5, 800))
                    .foregroundStyle(Color(hex: 0x0D0C1A))
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(Capsule().fill(LinearGradient(colors: [Night.overlayAccentTop, Night.overlayAccentBottom],
                                                              startPoint: .top, endPoint: .bottom)))
            }
        case .hidden:
            EmptyView()
        }
    }

    private func timer(_ date: Date, vertical: Bool) -> some View {
        Text(clock(elapsed ?? tape.now(date)))
            .font(.scribe(vertical ? 11 : 12.5, 600)).monospacedDigit()
            .foregroundStyle(Color.white.opacity(0.62))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .fixedSize(horizontal: !vertical, vertical: false)
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
        case .transcribing: return "Scribe is writing"
        case .message(let t, _): return t
        case .needsAccess: return "Text copied. Scribe needs Accessibility permission to type. Fix"
        case .hidden: return ""
        }
    }
}

/// The capsule's surface: the icon tile gradient (#1E1E22 → #09090B), a 1 px white@9% inner
/// border and one soft shadow. The same in light and dark mode, on every macOS version.
private struct NightCapsuleSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Capsule().fill(LinearGradient(colors: [Night.overlayTop, Night.overlayBottom],
                                                      startPoint: .top, endPoint: .bottom)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 9, y: 5)
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
        case .needsAccess: return .needsAccess
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

