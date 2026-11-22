// ScrollOverlay.swift
// The floating "scroll" at the bottom of the screen while you dictate or record a meeting
// (replaces v0.2's black pill).
//
// What it looks like: a THIN sideways scroll — a rolled-up paper roller at each end and a
// narrow strip of parchment between them that shows ONE line. While you talk, a quill
// scribbles ink (abstract handwriting, not your real words) and the paper feeds toward the
// left roller, so the line keeps moving. How big the scribbles are follows your voice
// (mic level). A small timer sits at the right end. When you let go, the paper stops and the
// quill finishes with a flourish while Scribe writes the text.
//
// How it's drawn: one SwiftUI Canvas inside a TimelineView at 30 fps, paused when hidden.
// The ink isn't stored as pixels: it's a formula of "paper position" + the mic level that was
// recorded when that bit of paper passed the quill (InkTape), so each frame just redraws a
// ~200 pt line of points. Cheap enough to be a rounding error in Activity Monitor.
//
// The panel is NON-ACTIVATING (the app you're typing in keeps focus, so ⌘V lands there),
// ignores the mouse, floats above other windows, and shows on every Space.

import AppKit
import SwiftUI

// MARK: - Tape (mic level history)

/// Remembers the mic level over time so the ink at each spot on the paper stays put as it
/// scrolls. Read by the Canvas every frame; written ~10×/s by the mic. Main thread only.
final class InkTape {
    private(set) var t0 = Date()
    private var times: [Double] = []
    private var levels: [Float] = []
    private(set) var stoppedAt: Double?
    private var floor: Float = 0.25
    /// Snapshot/preview: freeze the clock at this many seconds.
    var previewNow: Double?
    /// Snapshot/preview: fixed flourish phase (0...1).
    var previewPhase: Double?

    func reset() {
        t0 = Date()
        times.removeAll(keepingCapacity: true)
        levels.removeAll(keepingCapacity: true)
        stoppedAt = nil
        floor = 0.25
        previewNow = nil
        previewPhase = nil
    }

    func add(_ level: Float, at t: Double? = nil) {
        let now = t ?? Date().timeIntervalSince(t0)
        times.append(now)
        levels.append(level)
        if times.count > 1200 { times.removeFirst(400); levels.removeFirst(400) }
        // Background-noise floor: drops fast, rises slowly, so steady room hum makes no ink.
        floor = level < floor ? level : floor + (level - floor) * 0.01
    }

    func stop() { if stoppedAt == nil { stoppedAt = now(Date()) } }
    func now(_ date: Date) -> Double { previewNow ?? date.timeIntervalSince(t0) }
    /// Time used to position the paper (stops moving once writing starts).
    func paperTime(_ date: Date) -> Double { min(now(date), stoppedAt ?? .infinity) }

    /// 0...1 "how much ink" at time `t`.
    func ink(at t: Double) -> Double {
        guard !times.isEmpty, t >= 0 else { return 0 }
        var lo = 0, hi = times.count - 1
        if t >= times[hi] { return strength(levels[hi]) }
        if t <= times[0] { return strength(levels[0]) }
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if times[mid] <= t { lo = mid } else { hi = mid }
        }
        let f = Float((t - times[lo]) / max(1e-6, times[hi] - times[lo]))
        return strength(levels[lo] + (levels[hi] - levels[lo]) * f)
    }

    private func strength(_ level: Float) -> Double {
        let threshold = max(floor + 0.1, 0.3)
        return Double(min(1, max(0, (level - threshold) / 0.32)))
    }

    /// Made-up speech for screenshots: bursts of words with pauses.
    func fillPreview(seconds: Double) {
        reset()
        var t = 0.0
        while t <= seconds {
            let word = sin(t * 2.3) + 0.6 * sin(t * 5.1 + 1)
            let level: Float = word > -0.2 ? Float(0.62 + 0.25 * abs(sin(t * 7))) : 0.18
            add(level, at: t)
            t += 0.1
        }
        previewNow = seconds
    }
}

// MARK: - Panel

@MainActor
final class ScrollOverlay {
    private var panel: NSPanel?
    static let size = NSSize(width: 330, height: 64)
    /// Raise this overlay above the other one (dictation above a meeting scroll).
    var lift: CGFloat = 0

    func show<V: View>(_ content: @autoclosure () -> V) {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false               // the Canvas draws its own soft shadow
            p.ignoresMouseEvents = true
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.contentView = NSHostingView(rootView: content())
            panel = p
        }
        // Bottom-center of the screen your mouse is on.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            panel?.setFrameOrigin(NSPoint(x: f.midX - Self.size.width / 2, y: f.minY + 22 + lift))
        }
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }
    var isVisible: Bool { panel?.isVisible ?? false }
}

// MARK: - The scroll itself

/// What the scroll shows.
enum ScrollMode: Equatable {
    case listening           // dictation: scribbling, paper feeding
    case recording           // meeting: same, with a red seal
    case writing             // paper stopped, quill flourish, "Writing…"
    case message(String, failure: Bool)
    case hidden
}

struct ScribeScroll: View {
    var mode: ScrollMode
    var tape: InkTape
    /// Seconds to show in the timer (nil = use the tape's clock).
    var elapsed: TimeInterval? = nil

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: mode == .hidden || isMessage)) { tl in
            Canvas(rendersAsynchronously: false) { ctx, size in
                ScrollPainter(mode: mode, tape: tape, date: tl.date, elapsed: elapsed).draw(&ctx, size)
            }
        }
        .overlay { messageOverlay }
        .frame(width: ScrollOverlay.size.width, height: ScrollOverlay.size.height)
        .environment(\.colorScheme, .light)
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
    }

    private var isMessage: Bool { if case .message = mode { return true }; return false }

    @ViewBuilder private var messageOverlay: some View {
        if case .message(let text, let failure) = mode {
            HStack(spacing: 6) {
                Image(systemName: failure ? "exclamationmark.circle.fill" : "checkmark.seal.fill")
                    .foregroundStyle(failure ? Ink.royal : Ink.gold)
                Text(text)
                    .font(.system(size: 12.5, weight: .medium, design: .serif))
                    .italic()
                    .foregroundStyle(failure ? Ink.royal : Ink.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 44)
            .offset(y: 3)
        }
    }

    private var accessibilityText: String {
        switch mode {
        case .listening: return "Scribe is listening"
        case .recording: return "Scribe is recording a meeting"
        case .writing: return "Scribe is writing"
        case .message(let t, _): return t
        case .hidden: return ""
        }
    }
}

/// All the drawing, in one place. Coordinates: SwiftUI (y grows downward).
struct ScrollPainter {
    var mode: ScrollMode
    var tape: InkTape
    var date: Date
    var elapsed: TimeInterval?

    // Layout
    static let rollerW: CGFloat = 13
    static let stripH: CGFloat = 24
    static let speed: Double = 26          // paper feed, points per second
    static let letterW: Double = 6.5       // one "letter" of scribble

    func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        guard mode != .hidden else { return }
        let midY = size.height / 2 + 5
        let leftX: CGFloat = 8, rightX = size.width - 8
        let strip = CGRect(x: leftX + Self.rollerW * 0.5, y: midY - Self.stripH / 2,
                           width: rightX - leftX - Self.rollerW, height: Self.stripH)

        // Soft shadow under the whole scroll (a blurred dark capsule; drawn once per frame, small).
        var shadow = ctx
        shadow.addFilter(.blur(radius: 5))
        shadow.fill(Path(roundedRect: strip.insetBy(dx: -6, dy: -2).offsetBy(dx: 0, dy: 4), cornerRadius: 8),
                    with: .color(.black.opacity(0.22)))

        // Parchment strip with darker top/bottom edges.
        ctx.fill(Path(strip), with: .color(Ink.parchment))
        var edge = Path()
        edge.move(to: CGPoint(x: strip.minX, y: strip.minY + 0.5)); edge.addLine(to: CGPoint(x: strip.maxX, y: strip.minY + 0.5))
        edge.move(to: CGPoint(x: strip.minX, y: strip.maxY - 0.5)); edge.addLine(to: CGPoint(x: strip.maxX, y: strip.maxY - 0.5))
        ctx.stroke(edge, with: .color(Ink.ink.opacity(0.55)), lineWidth: 1)
        // Faint ruled baseline.
        let baseline = midY + 4.5
        var rule = Path()
        rule.move(to: CGPoint(x: strip.minX + 6, y: baseline + 0.5)); rule.addLine(to: CGPoint(x: strip.maxX - 6, y: baseline + 0.5))
        ctx.stroke(rule, with: .color(Ink.parchmentDeep), lineWidth: 0.6)

        let paper = tape.paperTime(date)
        let isWriting = mode == .writing
        let isMessage: Bool = { if case .message = mode { return true }; return false }()

        // Timer slot at the right end.
        let timerW: CGFloat = isWriting ? 50 : 38
        let nibX = strip.maxX - timerW - 8

        if !isMessage {
            drawInk(&ctx, strip: strip, nibX: nibX, baseline: baseline, paper: paper)
            if isWriting { drawFlourish(&ctx, nibX: nibX, baseline: baseline) }
            // Paper curling into the left roller: fade the ink out near it.
            let fade = CGRect(x: strip.minX, y: strip.minY + 1, width: 30, height: strip.height - 2)
            ctx.fill(Path(fade), with: .linearGradient(Gradient(colors: [Ink.parchment, Ink.parchment.opacity(0)]),
                                                     startPoint: CGPoint(x: fade.minX, y: 0), endPoint: CGPoint(x: fade.maxX, y: 0)))
            drawTimer(&ctx, x: strip.maxX - timerW - 2, width: timerW, midY: midY, paper: paper)
        }

        // Rollers on top of the strip ends. They turn with the paper.
        let turn = paper * Self.speed / 5.0
        drawRoller(&ctx, centerX: leftX + Self.rollerW / 2, midY: midY, height: size.height - 14, turn: turn)
        drawRoller(&ctx, centerX: rightX - Self.rollerW / 2, midY: midY, height: size.height - 14, turn: -turn)

        if !isMessage { drawQuill(&ctx, nibX: nibX, baseline: baseline, paper: paper) }
    }

    // MARK: Ink

    /// Pen position for paper coordinate `s` (points of paper since the start).
    /// Cursive-ish loops: x runs backward a little each letter (that's what makes loops).
    static func pen(_ s: Double, amp: Double) -> (dx: Double, dy: Double, lift: Bool) {
        let i = Int(floor(s / letterW))
        let h = hash(i)
        // Every ~6th letter is a space between words.
        if h % 6 == 0 { return (0, 0, true) }
        let w = 2 * Double.pi / letterW
        let tall: Double = h % 4 == 1 ? 1.0 : (h % 5 == 2 ? -0.55 : 0.6)   // ascender / descender / x-height
        let dx = -2.6 * sin(w * s)
        let dy = -amp * tall * (1 - cos(w * s)) / 2 + 0.6 * sin(s * 0.09)
        return (dx, dy, false)
    }

    static func hash(_ i: Int) -> Int {
        var x = UInt64(bitPattern: Int64(i)) &* 0x9E3779B97F4A7C15
        x ^= x >> 29; x &*= 0xBF58476D1CE4E5B9; x ^= x >> 32
        return Int(x % 1000)
    }

    private func drawInk(_ ctx: inout GraphicsContext, strip: CGRect, nibX: CGFloat, baseline: CGFloat, paper: Double) {
        let sNib = paper * Self.speed                 // paper coordinate under the quill now
        let visible = Double(nibX - strip.minX) + 6
        var path = Path()
        var penDown = false
        var s = max(0, sNib - visible)
        let step = 0.7
        while s <= sNib {
            let t = s / Self.speed                     // when this bit of paper passed the quill
            let e = tape.ink(at: t)
            let p = Self.pen(s, amp: 3.5 + 7.5 * e)
            let x = nibX - CGFloat(sNib - s) + CGFloat(p.dx)
            let y = baseline + CGFloat(p.dy)
            if e > 0.04 && !p.lift && x > strip.minX + 2 {
                if penDown { path.addLine(to: CGPoint(x: x, y: y)) } else { path.move(to: CGPoint(x: x, y: y)); penDown = true }
            } else {
                penDown = false
            }
            s += step
        }
        ctx.stroke(path, with: .color(Ink.ink.opacity(0.9)),
                   style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
    }

    /// While writing: a looping swash under the line, drawn progressively.
    private func drawFlourish(_ ctx: inout GraphicsContext, nibX: CGFloat, baseline: CGFloat) {
        let phase = tape.previewPhase ?? (tape.now(date).truncatingRemainder(dividingBy: 1.8) / 1.8)
        let n = 90
        let upto = Int(Double(n) * min(1, phase * 1.15))
        guard upto > 1 else { return }
        var path = Path()
        for k in 0...upto {
            let u = Double(k) / Double(n)
            // A loop-de-loop that ends in a tail under the last word.
            let x = nibX - 46 + CGFloat(u * 44) + CGFloat(5 * sin(u * .pi * 3))
            let y = baseline + 3 + CGFloat(-5 * cos(u * .pi * 3) + 5) * CGFloat(1 - u * 0.6) - 4
            if k == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        ctx.stroke(path, with: .color(Ink.ink.opacity(0.85)), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
    }

    // MARK: Pieces

    private func drawRoller(_ ctx: inout GraphicsContext, centerX: CGFloat, midY: CGFloat, height: CGFloat, turn: Double) {
        let w = Self.rollerW
        let body = CGRect(x: centerX - w / 2, y: midY - height / 2, width: w, height: height)
        let shape = Path(roundedRect: body, cornerRadius: w / 2.2)
        ctx.fill(shape, with: .linearGradient(
            Gradient(colors: [Ink.parchmentDeep, Ink.parchmentLight, Ink.parchmentDeep]),
            startPoint: CGPoint(x: body.minX, y: 0), endPoint: CGPoint(x: body.maxX, y: 0)))
        // Grain lines that slide around as the roll turns.
        for k in 0..<3 {
            let a = turn + Double(k) * 2.0944
            let c = cos(a)
            guard sin(a) > 0 else { continue }            // only the front side
            let x = centerX + CGFloat(c) * (w / 2 - 1.5)
            var line = Path()
            line.move(to: CGPoint(x: x, y: body.minY + 5)); line.addLine(to: CGPoint(x: x, y: body.maxY - 5))
            ctx.stroke(line, with: .color(Ink.ink.opacity(0.18)), lineWidth: 0.8)
        }
        ctx.stroke(shape, with: .color(Ink.ink.opacity(0.75)), lineWidth: 1.1)
        // Curl at the top: a little spiral end.
        let curl = CGRect(x: centerX - w / 2 + 1, y: body.minY - 1, width: w - 2, height: w * 0.55)
        ctx.fill(Path(ellipseIn: curl), with: .color(Ink.parchment))
        ctx.stroke(Path(ellipseIn: curl), with: .color(Ink.ink.opacity(0.75)), lineWidth: 1)
        ctx.stroke(Path(ellipseIn: curl.insetBy(dx: 3, dy: 1.6)), with: .color(Ink.ink.opacity(0.5)), lineWidth: 0.8)
    }

    private func drawTimer(_ ctx: inout GraphicsContext, x: CGFloat, width: CGFloat, midY: CGFloat, paper: Double) {
        let center = CGPoint(x: x + width / 2 + 3, y: midY)
        if mode == .writing {
            ctx.draw(Text("Writing…").font(.system(size: 9.5, weight: .medium, design: .serif)).italic()
                .foregroundStyle(Ink.ink.opacity(0.8)), at: center)
            return
        }
        let secs = Int(elapsed ?? tape.now(date))
        let label = secs >= 3600 ? String(format: "%d:%02d:%02d", secs / 3600, secs / 60 % 60, secs % 60)
                                 : String(format: "%d:%02d", secs / 60, secs % 60)
        // A tiny red wax-seal dot (pulses gently) = the mic is on.
        let pulse = 0.75 + 0.25 * sin(tape.now(date) * 4)
        let dotR: CGFloat = mode == .recording ? 3.4 : 2.6
        let dotX = x + 4
        ctx.fill(Path(ellipseIn: CGRect(x: dotX - dotR, y: midY - dotR, width: dotR * 2, height: dotR * 2)),
                 with: .color(Ink.royal.opacity(pulse)))
        ctx.draw(Text(label).font(.system(size: 9.5, weight: .semibold, design: .rounded)).monospacedDigit()
            .foregroundStyle(Ink.ink.opacity(0.75)), at: CGPoint(x: center.x + 4, y: midY))
    }

    /// A cream feather quill whose nib follows the pen.
    private func drawQuill(_ ctx: inout GraphicsContext, nibX: CGFloat, baseline: CGFloat, paper: Double) {
        var tip = CGPoint(x: nibX, y: baseline - 2)
        if mode == .writing {
            let phase = tape.previewPhase ?? (tape.now(date).truncatingRemainder(dividingBy: 1.8) / 1.8)
            let u = min(1, phase * 1.15)
            tip = CGPoint(x: nibX - 46 + CGFloat(u * 44) + CGFloat(5 * sin(u * .pi * 3)),
                          y: baseline + 3 + CGFloat(-5 * cos(u * .pi * 3) + 5) * CGFloat(1 - u * 0.6) - 4)
        } else {
            let s = paper * Self.speed
            let e = tape.ink(at: paper)
            let p = Self.pen(s, amp: 3.5 + 7.5 * e)
            tip.y = e > 0.04 && !p.lift ? baseline + CGFloat(p.dy) : baseline - 3   // lifted in silence
        }
        // Feather: a leaf shape angled up and to the right.
        let back = CGPoint(x: tip.x + 30, y: tip.y - 30)
        var feather = Path()
        feather.move(to: CGPoint(x: tip.x + 5, y: tip.y - 5))
        feather.addQuadCurve(to: back, control: CGPoint(x: tip.x + 4, y: tip.y - 26))
        feather.addQuadCurve(to: CGPoint(x: tip.x + 5, y: tip.y - 5), control: CGPoint(x: tip.x + 27, y: tip.y - 6))
        ctx.fill(feather, with: .color(Color(red: 0.99, green: 0.97, blue: 0.92)))
        ctx.stroke(feather, with: .color(Ink.ink.opacity(0.85)), lineWidth: 1)
        var shaft = Path()
        shaft.move(to: tip); shaft.addLine(to: CGPoint(x: back.x - 2, y: back.y + 2))
        ctx.stroke(shaft, with: .color(Ink.ink.opacity(0.85)), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
        // Gold nib.
        var nib = Path()
        nib.move(to: tip)
        nib.addLine(to: CGPoint(x: tip.x + 5.5, y: tip.y - 2.5))
        nib.addLine(to: CGPoint(x: tip.x + 2.5, y: tip.y - 5.5))
        nib.closeSubpath()
        ctx.fill(nib, with: .color(Ink.gold))
        ctx.stroke(nib, with: .color(Ink.ink.opacity(0.85)), lineWidth: 0.8)
    }
}

// MARK: - The two live overlays

/// Dictation scroll: follows DictationController.
struct DictationScrollView: View {
    @EnvironmentObject var dictation: DictationController
    var body: some View {
        ScribeScroll(mode: mode, tape: dictation.tape)
    }
    private var mode: ScrollMode {
        switch dictation.state {
        case .listening: return .listening
        case .transcribing: return .writing
        case .done(let m): return .message(m, failure: false)
        case .failed(let m): return .message(m, failure: true)
        case .idle: return .hidden
        }
    }
}

/// Meeting scroll: follows the Recorder.
struct MeetingScrollView: View {
    @ObservedObject var recorder: Recorder
    var tape: InkTape
    var body: some View {
        ScribeScroll(mode: recorder.isRecording ? .recording : .hidden, tape: tape, elapsed: recorder.elapsed)
    }
}
