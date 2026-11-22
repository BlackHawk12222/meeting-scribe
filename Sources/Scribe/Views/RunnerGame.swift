// RunnerGame.swift
// "Quill Dash": a tiny endless runner for the first-run download screen.
// The scribe runs along a strip of parchment and jumps (Space, ↑ or click) over ink pots,
// candles and stacks of books. It speeds up slowly. Best score is saved.
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
                Text("Quill Dash").font(.system(.headline, design: .serif)).foregroundStyle(Ink.ink)
                Spacer()
                Text("Score \(game.score)   Best \(game.best)")
                    .font(.system(.callout, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Ink.ink.opacity(0.7))
            }
            ZStack {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: game.phase != .running || game.previewFrozen)) { tl in
                    Canvas { ctx, size in
                        game.step(to: tl.date, width: size.width)
                        RunnerPainter.draw(&ctx, size: size, game: game, date: tl.date)
                    }
                }
                .background(Ink.parchmentLight, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.parchmentDeep, lineWidth: 1))
                .contentShape(Rectangle())
                .onTapGesture { game.jump() }

                if game.phase != .running {
                    VStack(spacing: 8) {
                        Text(game.phase == .over ? "Ink spilled!" : "Help the scribe dodge the ink")
                            .font(.system(.title3, design: .serif).weight(.semibold))
                        Text(game.phase == .over ? "Score \(game.score)" : "Space, ↑ or click to jump")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Button(game.phase == .over ? "Play again" : "Start") { game.start() }
                                .keyboardShortcut(.space, modifiers: [])
                                .buttonStyle(.borderedProminent).tint(Ink.royal)
                            if game.phase == .over { Button("Next") { onNext() } }
                        }
                    }
                    .padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .frame(height: 170)
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
        let ground = size.height - 26
        // Ground line with dashes sliding left.
        var line = Path()
        line.move(to: CGPoint(x: 0, y: ground)); line.addLine(to: CGPoint(x: size.width, y: ground))
        ctx.stroke(line, with: .color(Ink.ink.opacity(0.6)), lineWidth: 1.2)
        let off = game.distance.truncatingRemainder(dividingBy: 40)
        var dashes = Path()
        var x = -off
        while x < size.width {
            let y = ground + 7 + CGFloat(Int(x + game.distance) % 3)
            dashes.move(to: CGPoint(x: x, y: y)); dashes.addLine(to: CGPoint(x: x + 9, y: y))
            x += 40
        }
        ctx.stroke(dashes, with: .color(Ink.ink.opacity(0.25)), lineWidth: 1)

        // Obstacles.
        for o in game.obstacles {
            let r = CGRect(x: o.x, y: ground - o.h, width: o.w, height: o.h)
            switch o.kind {
            case .inkPot:
                ctx.fill(Path(roundedRect: r.insetBy(dx: 0, dy: 5).offsetBy(dx: 0, dy: 5), cornerRadius: 5), with: .color(Ink.ink))
                ctx.fill(Path(roundedRect: CGRect(x: r.minX + 5, y: r.minY + 2, width: r.width - 10, height: 6), cornerRadius: 2), with: .color(Ink.ink))
                ctx.fill(Path(ellipseIn: CGRect(x: r.minX + 4, y: r.midY + 2, width: 4, height: 4)), with: .color(.white.opacity(0.5)))
            case .candle:
                ctx.fill(Path(roundedRect: r.insetBy(dx: 0, dy: 8).offsetBy(dx: 0, dy: 8), cornerRadius: 2), with: .color(Ink.parchment))
                ctx.stroke(Path(roundedRect: r.insetBy(dx: 0, dy: 8).offsetBy(dx: 0, dy: 8), cornerRadius: 2), with: .color(Ink.ink), lineWidth: 1.2)
                let flicker = sin(date.timeIntervalSinceReferenceDate * 14) * 1.2
                ctx.fill(Path(ellipseIn: CGRect(x: r.midX - 3.5 + flicker * 0.3, y: r.minY, width: 7, height: 13)), with: .color(Ink.gold))
                ctx.fill(Path(ellipseIn: CGRect(x: r.midX - 1.6, y: r.minY + 5, width: 3.2, height: 6)), with: .color(Ink.royal))
            case .books:
                let colors = [Ink.royal, Ink.gold, Ink.ink]
                for k in 0..<3 {
                    let b = CGRect(x: r.minX + CGFloat(k % 2) * 3, y: r.maxY - CGFloat(k + 1) * 7.3, width: r.width - 3, height: 7)
                    ctx.fill(Path(roundedRect: b, cornerRadius: 1.5), with: .color(colors[k]))
                    ctx.stroke(Path(roundedRect: b, cornerRadius: 1.5), with: .color(Ink.ink), lineWidth: 0.8)
                }
            }
        }

        // The scribe (mascot picture), bobbing while running, tilted while in the air.
        let bob = game.y > 0 ? 0 : abs(sin(game.distance / 18)) * 2.5
        let rect = CGRect(x: RunnerGame.playerX, y: ground - RunnerGame.playerH - game.y - bob,
                          width: RunnerGame.playerW, height: RunnerGame.playerH)
        if let img = NSImage(named: "MascotWelcome") {
            var c = ctx
            c.translateBy(x: rect.midX, y: rect.midY)
            c.rotate(by: .degrees(game.y > 0 ? -8 : 0))
            c.draw(Image(nsImage: img), in: CGRect(x: -rect.width / 2 - 4, y: -rect.height / 2 - 4,
                                                  width: rect.width + 8, height: rect.height + 8))
        } else {
            ctx.fill(Path(roundedRect: rect, cornerRadius: 10), with: .color(Ink.royal))
        }
        // Shadow on the ground.
        let sw = max(10, 26 - game.y / 4)
        ctx.fill(Path(ellipseIn: CGRect(x: rect.midX - sw / 2, y: ground - 2, width: sw, height: 4)),
                 with: .color(Ink.ink.opacity(0.18)))
    }
}
