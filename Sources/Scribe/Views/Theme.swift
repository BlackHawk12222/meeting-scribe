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

// MARK: - 0.6 look: Liquid Glass + warm, calm neutrals
//
// Apple structure, Notion calm, a little cozier: warm off-white paper in light mode and a
// warm charcoal in dark mode, soft continuous corners, quiet hairlines, one gentle warm
// accent ("honey") beside the indigo nib. On macOS 26 the floating chrome (buttons, chips,
// the dictation capsule, banners) is Liquid Glass; on macOS 14/15 the same views fall back
// to the system's regular material with a hairline edge.

extension Color {
    /// A color with separate light and dark values (follows the window's appearance).
    static func scribe(light: (CGFloat, CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: c.3)
        })
    }
}

enum Warm {
    /// The page behind content (warm paper / warm charcoal).
    static let canvas = Color.scribe(light: (0.984, 0.976, 0.965, 1), dark: (0.118, 0.110, 0.102, 1))
    /// Cards and grouped blocks sitting on the canvas.
    static let surface = Color.scribe(light: (1.000, 0.996, 0.990, 1), dark: (0.160, 0.149, 0.140, 1))
    /// Subtle filled areas (pills, wells, hover).
    static let well = Color.scribe(light: (0.945, 0.931, 0.912, 1), dark: (0.212, 0.198, 0.186, 1))
    /// Quiet dividers and card edges.
    static let hairline = Color.scribe(light: (0.42, 0.34, 0.26, 0.13), dark: (1, 0.96, 0.90, 0.08))
    /// The gentle warm accent (used sparingly: section marks, empty states, highlights).
    static let honey = Color.scribe(light: (0.78, 0.49, 0.22, 1), dark: (0.90, 0.64, 0.38, 1))
    /// Soft, warm-tinted shadow for cards.
    static let shadow = Color.scribe(light: (0.33, 0.22, 0.12, 0.07), dark: (0, 0, 0, 0.35))
}

extension Brand {
    /// Corner radii: small controls, cards, big panels.
    static let rSmall: CGFloat = 8, rCard: CGFloat = 14, rPanel: CGFloat = 20
    /// Comfortable reading width for notes and transcripts.
    static let readingWidth: CGFloat = 720
}

extension View {
    /// Liquid Glass on macOS 26; regular material + hairline on macOS 14/15.
    @ViewBuilder
    func scribeGlass<S: InsettableShape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(Self.glass(tint: tint, interactive: interactive), in: shape)
        } else {
            self.background {
                shape.fill(.regularMaterial)
                if let tint { shape.fill(tint.opacity(0.18)) }
            }
            .overlay(shape.strokeBorder(Warm.hairline, lineWidth: 0.5))
        }
    }

    @available(macOS 26.0, *)
    private static func glass(tint: Color?, interactive: Bool) -> Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }

    /// A calm card: warm surface, soft corners, hairline edge, a whisper of shadow.
    func scribeCard(radius: CGFloat = Brand.rCard, padding: CGFloat = Brand.s2) -> some View {
        self.padding(padding)
            .background(Warm.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Warm.hairline, lineWidth: 0.5))
            .shadow(color: Warm.shadow, radius: 10, y: 3)
    }

    /// `.glass` / `.glassProminent` buttons on macOS 26, bordered ones before.
    func scribeButton(prominent: Bool = false) -> some View { modifier(ScribeButtonStyle(prominent: prominent)) }

    /// The warm page background (content area of the main window, settings panes).
    func scribeCanvas() -> some View { self.background(Warm.canvas) }
}

struct ScribeButtonStyle: ViewModifier {
    var prominent: Bool
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { content.buttonStyle(.glassProminent) } else { content.buttonStyle(.glass) }
        } else {
            if prominent { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
        }
    }
}

/// Groups nearby glass shapes so they blend like one piece of glass (macOS 26 only).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// A page title block: big title, one calm line under it (Notion-style page header).
struct PageHeader<Trailing: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 28, weight: .bold))
                if let subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            trailing
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A small heading with a quiet symbol, used for blocks inside a page ("Summary", "Action items").
struct BlockHeading: View {
    var title: String
    var symbol: String
    var body: some View {
        Label {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                .textCase(nil)
        } icon: {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(Warm.honey)
        }
        .labelStyle(.titleAndIcon)
    }
}

/// A friendly empty state: a soft symbol tile, a short human line, an optional action.
struct CozyEmptyState<Actions: View>: View {
    var symbol: String
    var title: String
    var message: String
    @ViewBuilder var actions: Actions
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Warm.honey)
                .frame(width: 64, height: 64)
                .background(Warm.honey.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            VStack(spacing: 6) {
                Text(title).font(.title3.weight(.semibold))
                // No fixedSize here: it would make the window's minimum height huge.
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(6)
                    .frame(maxWidth: 380)
            }
            actions.padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

extension CozyEmptyState where Actions == EmptyView {
    init(symbol: String, title: String, message: String) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}
