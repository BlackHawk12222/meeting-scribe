// Theme.swift
// Scribe's look (0.4): plain macOS. System fonts, system colors (light + dark), standard
// materials and SF Symbols. One quiet accent: the asset catalog's AccentColor (deep indigo,
// used when the Mac's accent is set to "Multicolor"; otherwise the user's own accent wins).
// The only brand mark is the fountain-pen nib, drawn in code here (menu bar) and in
// scripts/make_icon.py (the app icon), from the same numbers.

import SwiftUI
import AppKit

enum Brand {
    /// The app's accent (AccentColor asset / the user's system accent).
    static let accent = Color.accentColor
    /// Record / live indicators.
    static let record = Color.red
    /// 8-pt spacing grid.
    static let s1: CGFloat = 8, s2: CGFloat = 16, s3: CGFloat = 24, s4: CGFloat = 32
}

/// The fountain-pen nib, in a 100×100 box with the tip at the bottom (y grows downward).
/// Same geometry as scripts/make_icon.py.
enum NibShape {
    enum Detail { case icon, glyph }

    /// The nib rotated `degrees` (45 = tip pointing down-left), fitted into `rect`.
    /// Fill it with the even-odd rule: the slit and breather hole are cut-outs.
    static func path(in rect: CGRect, degrees: CGFloat = 45, detail: Detail = .glyph) -> CGPath {
        let side = min(rect.width, rect.height)
        let s = side / 92
        let t = CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .rotated(by: degrees * .pi / 180)
            .scaledBy(x: s, y: s)
            .translatedBy(x: -50, y: -55)
        let p = CGMutablePath()
        // Outline: tip → left shoulder → top → right shoulder → tip.
        p.move(to: CGPoint(x: 50, y: 96), transform: t)
        p.addCurve(to: CGPoint(x: 27, y: 47), control1: CGPoint(x: 45, y: 82), control2: CGPoint(x: 27, y: 64), transform: t)
        p.addLine(to: CGPoint(x: 28.5, y: 24), transform: t)
        p.addQuadCurve(to: CGPoint(x: 38, y: 15), control: CGPoint(x: 29, y: 15), transform: t)
        p.addLine(to: CGPoint(x: 62, y: 15), transform: t)
        p.addQuadCurve(to: CGPoint(x: 71.5, y: 24), control: CGPoint(x: 71, y: 15), transform: t)
        p.addLine(to: CGPoint(x: 73, y: 47), transform: t)
        p.addCurve(to: CGPoint(x: 50, y: 96), control1: CGPoint(x: 73, y: 64), control2: CGPoint(x: 55, y: 82), transform: t)
        p.closeSubpath()
        // Cut-outs. A menu bar glyph is ~16 px, so its slit and hole are drawn thicker.
        let hole: CGFloat = detail == .icon ? 5.2 : 7.5
        let slitW: CGFloat = detail == .icon ? 1.1 : 3.2
        p.addEllipse(in: CGRect(x: 50 - hole, y: 52 - hole, width: hole * 2, height: hole * 2), transform: t)
        p.addRect(CGRect(x: 50 - slitW, y: 52 + hole - 0.5, width: slitW * 2, height: 90 - 52 - hole), transform: t)
        if detail == .icon {
            p.addRect(CGRect(x: 28.6, y: 27, width: 42.8, height: 2.6), transform: t)
        }
        return p
    }
}

/// The nib as a SwiftUI shape (fill with `style: FillStyle(eoFill: true)`).
struct Nib: Shape {
    var degrees: CGFloat = 45
    var detail: NibShape.Detail = .glyph
    func path(in rect: CGRect) -> Path { Path(NibShape.path(in: rect, degrees: degrees, detail: detail)) }
}

/// The app icon from the bundle (Assets.car), at any size.
struct AppIconView: View {
    var size: CGFloat
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage ?? NSImage())
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// An SF Symbol on a soft tinted rounded square: used for feature and setup cards.
struct SymbolTile: View {
    var symbol: String
    var size: CGFloat = 48
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(Brand.accent)
            .frame(width: size, height: size)
            .background(Brand.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The menu bar icon: the nib as a TEMPLATE image (macOS tints it for light/dark menu bars).
///  .idle = the nib   .live = nib + a dot (listening / recording)   .busy = nib + three dots (transcribing)
enum MenuBarGlyph {
    enum Mode { case idle, live, busy }

    static func image(_ mode: Mode) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: true) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            cg.setFillColor(NSColor.black.cgColor)
            let nibRect = mode == .idle ? CGRect(x: 0.5, y: 0.5, width: 17, height: 17)
                                        : CGRect(x: 0, y: 0, width: 15, height: 15)
            cg.addPath(NibShape.path(in: nibRect, detail: .glyph))
            cg.fillPath(using: .evenOdd)
            switch mode {
            case .idle: break
            case .live:
                cg.fillEllipse(in: CGRect(x: 12.4, y: 12.4, width: 5.4, height: 5.4))
            case .busy:
                for x in [CGFloat(10.2), 13.2, 16.2] {
                    cg.fillEllipse(in: CGRect(x: x - 1.1, y: 15.6 - 1.1, width: 2.2, height: 2.2))
                }
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Scribe"
        return img
    }

    // Built once; the menu bar asks for them every time state changes.
    static let idle = image(.idle)
    static let live = image(.live)
    static let busy = image(.busy)
}
