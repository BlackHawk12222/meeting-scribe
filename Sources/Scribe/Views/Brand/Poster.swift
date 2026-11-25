// Poster.swift
// 0.7.3 "Poster" building blocks: the big colored stat tiles and the little charts on them
// (mini bars, day squares, ring gauge), the 26-week heatmap, the per-app share bar, app dots and
// the hairline section header. Values always come from real data; empty data draws empty shapes.

import SwiftUI

/// A poster tile: label top-left, a small chart top-right, a huge number at the bottom, a caption.
struct PosterTile<Accessory: View>: View {
    var color: Color
    var label: String
    var value: String
    var unit: String? = nil
    var caption: String
    var height: CGFloat = Night.tileHeight
    var valueSize: CGFloat = 72
    /// The black tile gets a hairline in dark mode.
    var outlined = false
    @ViewBuilder var accessory: Accessory

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Night.rTile, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.system(size: 14, weight: .regular)).opacity(0.88).lineLimit(1)
            Spacer(minLength: 4)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.posterNumber(valueSize))
                    .tracking(-valueSize * 0.045)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .contentTransition(.numericText())
                if let unit {
                    Text(unit).font(.system(size: valueSize * 0.4, weight: .semibold)).opacity(0.9)
                }
            }
            Text(caption).font(.system(size: 14, weight: .regular)).opacity(0.88).lineLimit(1)
                .padding(.top, 2)
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height)
        .background(shape.fill(color))
        .overlay(alignment: .topTrailing) { accessory.padding(18).foregroundStyle(Color.white) }
        .overlay { if outlined { shape.strokeBorder(Night.posterBlackEdge, lineWidth: 1) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)\(unit.map { " " + $0 } ?? "") \(caption)")
    }
}

/// White bars on a tile; the highlighted one solid, the rest 35%.
struct MiniBars: View {
    var values: [Int]
    var highlight: Int?
    var height: CGFloat = 60
    var barWidth: CGFloat = 9
    var body: some View {
        let mx = max(1, values.max() ?? 1)
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.white.opacity(i == highlight ? 1 : 0.35))
                    .frame(width: barWidth, height: max(4, height * CGFloat(v) / CGFloat(mx)))
            }
        }
        .frame(height: height, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

/// Seven small squares (white = yes).
struct DaySquares: View {
    var filled: [Bool]
    var size: CGFloat = 12
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(filled.enumerated()), id: \.offset) { _, on in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.white.opacity(on ? 1 : 0.28))
                    .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A ring gauge (white on 25% white), 0...1.
struct RingGauge: View {
    var fraction: Double
    var size: CGFloat = 58
    var line: CGFloat = 6
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.25), lineWidth: line)
            Circle().trim(from: 0, to: min(1, max(0, fraction)))
                .stroke(Color.white, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A 7 pt rounded square in an app's color.
struct AppDot: View {
    var color: Color
    var size: CGFloat = 7
    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous).fill(color).frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// "Last 26 weeks"-style header: 12.5 semibold secondary text, optional trailing text/action,
/// a hairline under it.
struct HairlineHeader<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        VStack(spacing: 7) {
            HStack {
                Text(title).font(.nightLabel).foregroundStyle(Night.text2)
                Spacer(minLength: 8)
                trailing
            }
            NightDivider()
        }
        .accessibilityElement(children: .contain)
    }
}

extension HairlineHeader where Trailing == EmptyView {
    init(title: String) { self.init(title: title) { EmptyView() } }
}

/// The 26-week heatmap: columns are weeks (oldest left), rows the days of the week.
struct ActivityHeatmap: View {
    var stats: DictationStats
    var weeks = 26
    var body: some View {
        let grid = stats.heat(weeks: weeks)
        let mx = grid.flatMap { $0.compactMap { $0 } }.max() ?? 0
        let months = stats.heatMonths(weeks: weeks)
        GeometryReader { geo in
            let gap: CGFloat = 3
            let cell = max(4, min((geo.size.width - gap * CGFloat(weeks - 1)) / CGFloat(weeks), 17))
            let gridWidth = cell * CGFloat(weeks) + gap * CGFloat(weeks - 1)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: gap) {
                    ForEach(Array(grid.enumerated()), id: \.offset) { _, col in
                        VStack(spacing: gap) {
                            ForEach(Array(col.enumerated()), id: \.offset) { _, words in
                                RoundedRectangle(cornerRadius: min(3, cell * 0.2), style: .continuous)
                                    .fill(words == nil ? Color.clear : Night.heat[DictationStats.heatLevel(words ?? 0, max: mx)])
                                    .frame(width: cell, height: cell)
                            }
                        }
                    }
                }
                HStack(spacing: 0) {
                    ForEach(Array(months.enumerated()), id: \.offset) { i, m in
                        if i > 0 { Spacer(minLength: 0) }
                        Text(m)
                    }
                }
                .font(.nightMeta).foregroundStyle(Night.text3)
                .frame(width: gridWidth)
            }
        }
        .frame(height: 7 * 17 + 6 * 3 + 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Dictation activity over the last \(weeks) weeks")
    }
}

/// "Where you talk": one bar split by app, then a legend with percentages.
struct AppShareBar: View {
    var shares: [AppShare]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                let gaps = CGFloat(max(0, shares.count - 1)) * 2
                HStack(spacing: 2) {
                    ForEach(shares) { s in
                        Rectangle().fill(s.color)
                            .frame(width: max(2, (geo.size.width - gaps) * CGFloat(s.fraction)))
                    }
                }
            }
            .frame(height: 10)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            FlowLegend(items: shares.map { (color: $0.color, text: "\($0.name) \(Int(($0.fraction * 100).rounded()))%") })
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shares.map { "\($0.name) \(Int(($0.fraction * 100).rounded())) percent" }.joined(separator: ", "))
    }
}

/// Legend items that wrap onto more lines.
struct FlowLegend: View {
    var items: [(color: Color, text: String)]
    var body: some View {
        WrapLayout(spacing: 16, lineSpacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                HStack(spacing: 6) {
                    AppDot(color: it.color, size: 8)
                    Text(it.text).font(.nightSecondary).foregroundStyle(Night.text2).fixedSize()
                }
            }
        }
    }
}

/// A simple left-to-right wrapping layout (chips, legends).
struct WrapLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > maxW { y += lineH + lineSpacing; x = 0; lineH = 0 }
            x += s.width + spacing
            lineH = max(lineH, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { y += lineH + lineSpacing; x = bounds.minX; lineH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            lineH = max(lineH, s.height)
        }
    }
}

/// A Poster chip (filters, dictionary words): 28 tall, radius 6, hairline. Selected = filled black.
struct PosterChip<Label: View>: View {
    var selected = false
    var action: () -> Void
    @ViewBuilder var label: Label
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) { label }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? Night.onPrimary : Night.text2)
                .padding(.horizontal, 11)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: Night.rControl, style: .continuous)
                    .fill(selected ? Night.primary : (hover ? Night.hover : Color.clear)))
                .overlay(RoundedRectangle(cornerRadius: Night.rControl, style: .continuous)
                    .strokeBorder(selected ? Color.clear : Night.line2, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
