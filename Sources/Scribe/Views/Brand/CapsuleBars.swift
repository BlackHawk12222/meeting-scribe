// CapsuleBars.swift
// The icon's sound wave as one component: rounded capsule bars for the live meter, voice prints,
// list thumbnails, idle "dots" and the download progress row. Bars animate height only; at
// idle (level 0) a bar settles to a dot (length = width).

import SwiftUI

struct CapsuleBars: View {
    enum Style { case gradient, dim, white, solid }

    var levels: [Double]
    var axis: Axis = .horizontal
    var barWidth: CGFloat = 4
    var spacing: CGFloat = 3
    /// Length of a bar at level 1.
    var maxLength: CGFloat = 40
    var style: Style = .gradient
    /// Fades bars toward the ends (the overlay's travelling wave). 0 = off.
    var edgeFade: Double = 0

    init(levels: [Double], axis: Axis = .horizontal, barWidth: CGFloat = 4, spacing: CGFloat = 3,
         maxLength: CGFloat = 40, style: Style = .gradient, edgeFade: Double = 0) {
        self.levels = levels
        self.axis = axis
        self.barWidth = barWidth
        self.spacing = spacing
        self.maxLength = maxLength
        self.style = style
        self.edgeFade = edgeFade
    }

    var body: some View {
        let layout = axis == .horizontal ? AnyLayout(HStackLayout(alignment: .center, spacing: spacing))
                                         : AnyLayout(VStackLayout(alignment: .center, spacing: spacing))
        layout {
            ForEach(Array(levels.enumerated()), id: \.offset) { i, l in
                bar(level: l, index: i)
            }
        }
        .frame(width: axis == .horizontal ? nil : maxLength, height: axis == .horizontal ? maxLength : nil)
        .accessibilityHidden(true)
    }

    private func bar(level: Double, index: Int) -> some View {
        let clamped = min(1, max(0, level))
        let length = max(barWidth, barWidth + (maxLength - barWidth) * CGFloat(clamped))
        let fade: Double
        if edgeFade > 0, levels.count > 1 {
            let x = Double(index) / Double(levels.count - 1) * 2 - 1
            fade = 1 - edgeFade * abs(x) * abs(x)
        } else {
            fade = 1
        }
        return Capsule()
            .fill(fill)
            .frame(width: axis == .horizontal ? barWidth : length, height: axis == .horizontal ? length : barWidth)
            .opacity(fade)
    }

    private var fill: AnyShapeStyle {
        switch style {
        case .gradient:
            return AnyShapeStyle(axis == .horizontal ? Night.gradient : Night.gradientTab)
        case .dim: return AnyShapeStyle(Night.line2)
        case .white:
            return AnyShapeStyle(LinearGradient(colors: [Night.overlayAccentTop, Night.overlayAccentBottom],
                                                startPoint: axis == .horizontal ? .top : .leading,
                                                endPoint: axis == .horizontal ? .bottom : .trailing))
        case .solid: return AnyShapeStyle(Night.accent)
        }
    }

    // MARK: Sample shapes

    /// A pleasant static wave (louder in the middle), seeded so each item keeps its own shape.
    static func wave(_ count: Int, seed: UInt64 = 1, floor: Double = 0.15) -> [Double] {
        var rng = SeededRandom(seed: seed)
        return (0..<count).map { i in
            let x = count > 1 ? Double(i) / Double(count - 1) * 2 - 1 : 0
            let envelope = 0.35 + 0.65 * cos(x * .pi / 2)
            return max(floor, min(1, envelope * (0.45 + 0.55 * rng.next())))
        }
    }

    /// A stable seed from a string (names, ids).
    static func seed(_ s: String) -> UInt64 {
        var h: UInt64 = 1469598103934665603
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return h
    }
}

/// Download progress as a row of 8 pt capsule dots; filled ones in the accent gradient.
/// Replaces ProgressView.
struct CapsuleProgress: View {
    var fraction: Double?
    var count: Int = 36
    var dot: CGFloat = 6
    var spacing: CGFloat = 3

    var body: some View {
        let filled = Int((min(1, max(0, fraction ?? 0)) * Double(count)).rounded())
        HStack(spacing: spacing) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i < filled ? AnyShapeStyle(Night.gradient) : AnyShapeStyle(Night.line2))
                    .frame(width: dot, height: dot)
            }
        }
        .animation(.easeOut(duration: 0.2), value: filled)
        .accessibilityElement()
        .accessibilityLabel(fraction.map { "\(Int($0 * 100)) percent" } ?? "Working")
    }
}

/// A small "working" indicator built from the bars (replaces the system spinner).
struct CapsuleSpinner: View {
    var bars = 5
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            CapsuleBars(levels: (0..<bars).map { i in 0.25 + 0.75 * max(0, sin(t * 5 - Double(i) * 0.7)) },
                        barWidth: 3, spacing: 2, maxLength: 14, style: .gradient)
        }
        .frame(height: 14)
        .accessibilityLabel("Working")
    }
}

/// A 40 pt wave thumbnail tile (list rows).
struct WaveTile: View {
    var seed: UInt64
    var size: CGFloat = 40
    var body: some View {
        CapsuleBars(levels: CapsuleBars.wave(5, seed: seed, floor: 0.3), barWidth: size >= 36 ? 3 : 2.5, spacing: 2, maxLength: size * 0.42)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: Night.rRow, style: .continuous).fill(Night.well))
            .overlay(RoundedRectangle(cornerRadius: Night.rRow, style: .continuous).strokeBorder(Night.line, lineWidth: 1))
    }
}
