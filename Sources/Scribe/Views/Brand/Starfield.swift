// Starfield.swift
// A faint field of the icon's sparkles and dots behind every screen. Static and cheap: the star
// list is seeded (the same sky every launch), drawn once per size in a Canvas, no animation loop.
// Opacity 0.10–0.35; only the 2–3 biggest stars get the icon's soft glow.

import SwiftUI

struct Starfield: View {
    /// Changes the layout of the sky (each window/sheet can have its own).
    var seed: UInt64 = 7
    /// Overall strength (1 = the mock).
    var intensity: Double = 1
    @Environment(\.colorScheme) private var scheme

    private struct Star { var x: Double; var y: Double; var r: Double; var o: Double; var sparkle: Bool }

    private var stars: [Star] {
        var rng = SeededRandom(seed: seed)
        var out: [Star] = []
        for i in 0..<14 {           // sparkles
            let big = i < 3
            out.append(Star(x: rng.next(), y: rng.next(),
                            r: big ? 5 + rng.next() * 3 : 2 + rng.next() * 2.5,
                            o: big ? 0.28 + rng.next() * 0.07 : 0.12 + rng.next() * 0.16,
                            sparkle: true))
        }
        for _ in 0..<30 {           // dots
            out.append(Star(x: rng.next(), y: rng.next(), r: 0.6 + rng.next() * 0.7,
                            o: 0.10 + rng.next() * 0.2, sparkle: false))
        }
        return out
    }

    var body: some View {
        let color = scheme == .dark ? Color(hex: 0xC9CAFF) : Color(hex: 0x8C86EC)
        let list = stars
        let k = intensity * (scheme == .dark ? 1 : 0.8)
        Canvas(rendersAsynchronously: false) { ctx, size in
            for s in list {
                let cx = s.x * size.width, cy = s.y * size.height
                if s.sparkle {
                    let rect = CGRect(x: cx - s.r * 1.3, y: cy - s.r * 1.3, width: s.r * 2.6, height: s.r * 2.6)
                    if s.r >= 5 {
                        var g = ctx
                        g.addFilter(.blur(radius: s.r * 0.9))
                        g.fill(Sparkle().path(in: rect.insetBy(dx: -s.r * 0.8, dy: -s.r * 0.8)),
                               with: .color(color.opacity(0.18 * k)))
                    }
                    ctx.fill(Sparkle().path(in: rect), with: .color(color.opacity(s.o * k)))
                } else {
                    ctx.fill(Path(ellipseIn: CGRect(x: cx - s.r, y: cy - s.r, width: s.r * 2, height: s.r * 2)),
                             with: .color(color.opacity(s.o * k)))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A tiny deterministic random source (SplitMix64), so the sky and the sample waves look the
/// same every launch.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    /// A number in 0..<1.
    mutating func next() -> Double {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z = z ^ (z >> 31)
        return Double(z >> 11) / Double(1 << 53)
    }
}
