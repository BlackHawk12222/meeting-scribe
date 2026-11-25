// RunnerGame.swift
// "Star Dash" (0.6: "Quill Dash"): a tiny endless runner for the first-run download screen.
// Flat monochrome shapes (think Chrome's offline dino): the sparkle runs along a line and jumps
// (Space, ↑ or click) over ink drops, posts and blocks. It speeds up slowly. Best score is saved.
//
// How it works (no game engine): a SwiftUI Canvas inside a TimelineView redraws ~60×/s
// ONLY while a run is going (paused otherwise). Each frame, `step(to:)` moves time forward:
// gravity pulls the scribe down, obstacles slide left, and simple box overlap = game over.

import SwiftUI
import AppKit

@MainActor
final class RunnerGame: ObservableObject {
    enum Phase { case ready, running, over }

    struct Obstacle {
        enum Kind: CaseIterable { case inkPot, candle, books }
        var kind: Kind
        var x: Double
        var w: Double { switch kind { case .inkPot: 20; case .candle: 11; case .books: 30 } }
        var h: Double { switch kind { case .inkPot: 22; case .candle: 36; case .books: 22 } }
    }

    @Published private(set) var phase: Phase = .ready
    @Published private(set) var best: Int = UserDefaults.standard.integer(forKey: "runnerBest")

    // Physics state (not @Published: read by the Canvas every frame).
    private(set) var y: Double = 0               // height above the ground
    private var vy: Double = 0
    private(set) var obstacles: [Obstacle] = []
    private(set) var distance: Double = 0
    private var lastTime: Date?
    private var nextGap: Double = 260
    private var rng = SystemRandomNumberGenerator()

    var score: Int { Int(distance / 12) }
    var speed: Double { min(430, 250 + distance / 40) }      // points per second
    static let playerX: Double = 70
    static let playerW: Double = 34, playerH: Double = 40
    static let gravity: Double = 1900, jumpSpeed: Double = 620

    /// Space / ↑ / click.
    func jump() {
        switch phase {
        case .ready, .over: start()
        case .running: if y <= 0.5 { vy = Self.jumpSpeed }
        }
    }

    func start() {
        y = 0; vy = 0; distance = 0; obstacles = []; nextGap = 320; lastTime = nil
        phase = .running
    }

    /// Advance the world to `date`. Called by the Canvas each frame.
    func step(to date: Date, width: Double) {
        guard phase == .running else { return }
        let dt = min(1.0 / 20, lastTime.map { date.timeIntervalSince($0) } ?? 0)
        lastTime = date
        guard dt > 0 else { return }
        let v = speed
        distance += v * dt
        vy -= Self.gravity * dt
        y = max(0, y + vy * dt)
        if y == 0 { vy = 0 }
        for i in obstacles.indices { obstacles[i].x -= v * dt }
        obstacles.removeAll { $0.x + $0.w < -10 }
        // Spawn: keep a gap that's always jumpable, a bit random.
        let lastX = obstacles.last?.x ?? 0
        if obstacles.isEmpty || width - lastX > nextGap {
            let kind = Obstacle.Kind.allCases.randomElement(using: &rng) ?? .inkPot
            obstacles.append(Obstacle(kind: kind, x: width + 10))
            nextGap = Double.random(in: 230...420, using: &rng) + v * 0.35
        }
        // Collision (slightly forgiving boxes).
        let px0 = Self.playerX + 6, px1 = Self.playerX + Self.playerW - 6
        for o in obstacles where o.x < px1 && o.x + o.w > px0 && y < o.h - 4 {
            gameOver()
            break
        }
    }

    private func gameOver() {
        // Publishing during a Canvas draw is not allowed, so do it right after.
        DispatchQueue.main.async {
            self.phase = .over
            if self.score > self.best {
                self.best = self.score
                UserDefaults.standard.set(self.best, forKey: "runnerBest")
            }
        }
        lastTime = nil
    }

    /// Snapshot: a fixed mid-run frame.
    func setPreview() {
        phase = .running
        distance = 1450
        y = 34
        obstacles = [Obstacle(kind: .inkPot, x: 170), Obstacle(kind: .candle, x: 390), Obstacle(kind: .books, x: 590)]
        previewFrozen = true
    }
    private(set) var previewFrozen = false
}

struct RunnerGameView: View {
    @ObservedObject var game: RunnerGame
    var onNext: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Star Dash").font(.nightHeadline)
                Spacer()
                Text("\(game.score)   HI \(game.best)")
                    .font(.system(.callout, design: .monospaced).weight(.medium))
                    .foregroundStyle(.secondary)
            }
            ZStack {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: game.phase != .running || game.previewFrozen)) { tl in
                    Canvas { ctx, size in
                        game.step(to: tl.date, width: size.width)
                        RunnerPainter.draw(&ctx, size: size, game: game, date: tl.date)
                    }
                }
                .background(Night.well, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Night.line2, lineWidth: 1))
                .contentShape(Rectangle())
                .onTapGesture { game.jump() }

                if game.phase != .running {
                    VStack(spacing: 8) {
                        Text(game.phase == .over ? "Game over" : "Jump the ink blots")
                            .font(.headline)
                        Text(game.phase == .over ? "Score \(game.score)" : "Space, ↑ or click to jump")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Button(game.phase == .over ? "Play Again" : "Start") { game.start() }
                                .keyboardShortcut(.space, modifiers: [])
                                .buttonStyle(.nightPrimary)
                            if game.phase == .over { Button("Next") { onNext() }.buttonStyle(.nightSecondary) }
                        }
                    }
                    .padding(16)
                    .background(Night.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            .frame(height: 176)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.space) { game.jump(); return .handled }
        .onKeyPress(.upArrow) { game.jump(); return .handled }
    }
}

@MainActor
enum RunnerPainter {
    static func draw(_ ctx: inout GraphicsContext, size: CGSize, game: RunnerGame, date: Date) {
        let ink = Night.text
        let ground = size.height - 28
        // Ground line with small pebbles sliding left.
        var line = Path()
        line.move(to: CGPoint(x: 0, y: ground)); line.addLine(to: CGPoint(x: size.width, y: ground))
        ctx.stroke(line, with: .color(ink.opacity(0.55)), lineWidth: 1)
        let off = game.distance.truncatingRemainder(dividingBy: 48)
        var pebbles = Path()
        var x = -off
        while x < size.width {
            let y = ground + 6 + CGFloat(Int(x + game.distance) % 3) * 2
            pebbles.move(to: CGPoint(x: x, y: y)); pebbles.addLine(to: CGPoint(x: x + 4, y: y))
            x += 48
        }
        ctx.stroke(pebbles, with: .color(ink.opacity(0.25)), lineWidth: 1)

        // Obstacles: flat shapes, one color.
        for o in game.obstacles {
            let r = CGRect(x: o.x, y: ground - o.h, width: o.w, height: o.h)
            switch o.kind {
            case .inkPot:       // an ink drop
                var drop = Path()
                drop.move(to: CGPoint(x: r.midX, y: r.minY))
                drop.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY - r.width / 2), control: CGPoint(x: r.maxX, y: r.minY + r.height * 0.45))
                drop.addArc(center: CGPoint(x: r.midX, y: r.maxY - r.width / 2), radius: r.width / 2,
                            startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
                drop.addQuadCurve(to: CGPoint(x: r.midX, y: r.minY), control: CGPoint(x: r.minX, y: r.minY + r.height * 0.45))
                ctx.fill(drop, with: .color(ink.opacity(0.8)))
            case .candle:       // a post
                ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(ink.opacity(0.8)))
            case .books:        // two stacked blocks
                let lower = CGRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2)
                let upper = CGRect(x: r.minX + 5, y: r.minY, width: r.width - 10, height: r.height / 2 - 2)
                ctx.fill(Path(roundedRect: lower, cornerRadius: 2), with: .color(ink.opacity(0.8)))
                ctx.fill(Path(roundedRect: upper, cornerRadius: 2), with: .color(ink.opacity(0.8)))
            }
        }

        // The player: the icon's sparkle, bobbing while running, turning a little in the air.
        let bob = game.y > 0 ? 0 : abs(sin(game.distance / 18)) * 2
        let rect = CGRect(x: RunnerGame.playerX, y: ground - RunnerGame.playerH - game.y - bob,
                          width: RunnerGame.playerW, height: RunnerGame.playerH)
        let side = max(rect.width, rect.height) + 4
        let box = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        let turn = CGAffineTransform(translationX: box.midX, y: box.midY)
            .rotated(by: game.y > 0 ? .pi / 12 : 0)
            .translatedBy(x: -box.midX, y: -box.midY)
        ctx.fill(Sparkle().path(in: box).applying(turn), with: .color(Night.accent))
        // Shadow on the ground.
        let sw = max(8, 22 - game.y / 4)
        ctx.fill(Path(ellipseIn: CGRect(x: rect.midX - sw / 2, y: ground - 1.5, width: sw, height: 3)),
                 with: .color(ink.opacity(0.15)))
    }
}
