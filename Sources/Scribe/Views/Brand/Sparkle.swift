// Sparkle.swift
// The icon's rounded four-point star: the superellipse |x|^0.42 + |y|^0.42 <= 1, the same math as
// scripts/make_icon.py (star_mask). Used sparingly: the selected-nav marker, section labels, the
// Record button, note bullets, empty states, the overlay head and the starfield.

import SwiftUI

struct Sparkle: Shape {
    /// The superellipse exponent (< 1 gives the pinched four-point star).
    var exponent: Double = 0.42

    func path(in rect: CGRect) -> Path {
        let cx = rect.midX, cy = rect.midY
        let rx = rect.width / 2, ry = rect.height / 2
        let e = 2.0 / exponent
        let n = 96
        var p = Path()
        for i in 0...n {
            let t = Double(i) / Double(n) * 2 * Double.pi
            let c = cos(t), s = sin(t)
            let x = (c < 0 ? -1.0 : 1.0) * pow(abs(c), e)
            let y = (s < 0 ? -1.0 : 1.0) * pow(abs(s), e)
            let pt = CGPoint(x: cx + CGFloat(x) * rx, y: cy + CGFloat(y) * ry)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

/// A sparkle, optionally with the icon's soft glow (~18% opacity).
struct SparkleView: View {
    var size: CGFloat
    var glow = false
    var color: Color = Night.star

    var body: some View {
        ZStack {
            if glow {
                Sparkle().fill(color.opacity(0.18))
                    .frame(width: size * 1.7, height: size * 1.7)
                    .blur(radius: size * 0.28)
            }
            Sparkle().fill(color).frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
