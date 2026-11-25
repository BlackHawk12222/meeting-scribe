// Theme.swift
// Scribe 0.7 "Night Sky": the window looks like the app icon. Matte near-black surfaces
// (warm paper in light mode), one lavender accent, Manrope type, flat cards with a 1 px
// border and a 1 px inner top highlight. No blur and no Liquid Glass anywhere.
// Two shapes from the icon carry the system: the capsule bar (Brand/CapsuleBars.swift) and
// the four-point sparkle (Brand/Sparkle.swift). Tokens follow design-v07/DESIGN.md.
//
// Older names (Brand.*, Warm.*, scribeCard, scribeButton, scribeCanvas) are kept as thin
// aliases onto the Night tokens so every screen picks up the new look from this one file.

import SwiftUI
import AppKit
import CoreText

// MARK: - Colors

extension NSColor {
    /// 0xRRGGBB in sRGB.
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Color {
    /// A color with separate light and dark values (follows the window's appearance).
    static func scribe(light: (CGFloat, CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: c.3)
        })
    }

    /// Hex light/dark pair (0xRRGGBB), each with its own alpha.
    static func night(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor.night(light, dark, lightAlpha: lightAlpha, darkAlpha: darkAlpha))
    }

    /// A fixed sRGB color from hex (same in both themes).
    init(hex: UInt32, opacity: Double = 1) {
        self.init(nsColor: NSColor(hex: hex, alpha: CGFloat(opacity)))
    }
}

extension NSColor {
    static func night(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(hex: dark, alpha: darkAlpha) : NSColor(hex: light, alpha: lightAlpha)
        }
    }
}

/// The Night Sky tokens (DESIGN.md › Color tokens). Light values come from the light icon.
enum Night {
    static let canvas = Color.night(0xF8F5EF, 0x0E0E11)
    static let rail = Color.night(0xEFEAE1, 0x09090B)
    static let surface = Color.night(0xFFFDF9, 0x16161A)
    static let raised = Color.night(0xFFFFFF, 0x1D1D23)
    static let well = Color.night(0xF2EEE7, 0x111114)
    static let line = Color.night(0x463728, 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.07)
    static let line2 = Color.night(0x463728, 0xFFFFFF, lightAlpha: 0.16, darkAlpha: 0.11)
    static let highlight = Color.night(0xFFFFFF, 0xFFFFFF, lightAlpha: 0.70, darkAlpha: 0.04)
    static let text = Color.night(0x1D1C2A, 0xECEBF5)
    static let text2 = Color.night(0x5D5B70, 0xA9A8BC)
    static let text3 = Color.night(0x706D7E, 0x85849A)
    static let accentTop = Color.night(0x7074EA, 0xBABCFF)
    static let accentBottom = Color.night(0x3C3AA4, 0x8680F6)
    static let accent = Color.night(0x5653D2, 0xA3A0FB)
    static let accentSoft = Color.night(0x5653D2, 0xA3A0FB, lightAlpha: 0.10, darkAlpha: 0.14)
    static let onAccent = Color.night(0xFFFFFF, 0x0D0C1A)
    static let star = Color.night(0x8C86EC, 0xC9CAFF)
    /// Recording state only (dot, timer). Never decorative.
    static let live = Color.night(0xD9545E, 0xF2878E)
    static let liveSoft = Color.night(0xD9545E, 0xF2878E, lightAlpha: 0.12, darkAlpha: 0.14)
    /// Warnings (a failed step, a missing permission). Kept soft, like the rest.
    static let warn = Color.night(0xB86A1E, 0xF4BE93)
    static let ok = Color.night(0x2E8B6E, 0x8FD9C2)

    /// The accent gradient, top → bottom (wave, primary button, record button).
    static let gradient = LinearGradient(colors: [accentTop, accentBottom], startPoint: .top, endPoint: .bottom)
    /// The accent gradient, left → right (toggles, progress, tab underline).
    static let gradientH = LinearGradient(colors: [accentBottom, accentTop], startPoint: .leading, endPoint: .trailing)
    static let gradientTab = LinearGradient(colors: [accentTop, accentBottom], startPoint: .leading, endPoint: .trailing)

    /// Speaker avatar fills (dark text on top), assigned in order.
    static let speakers: [Color] = [Color(hex: 0xBABCFF), Color(hex: 0x8FD9C2), Color(hex: 0xF4BE93),
                                    Color(hex: 0x9CCBFF), Color(hex: 0xE9A9D0), Color(hex: 0xD7D98E)]
    static let onSpeaker = Color(hex: 0x0D0C1A)

    /// The dictation capsule: always dark (the icon tile), in both themes.
    static let overlayTop = Color(hex: 0x1E1E22)
    static let overlayBottom = Color(hex: 0x09090B)
    static let overlayStar = Color(hex: 0xC9CAFF)
    static let overlayAccentTop = Color(hex: 0xBABCFF)
    static let overlayAccentBottom = Color(hex: 0x8680F6)
    static let overlayLive = Color(hex: 0xF2878E)

    // Radii
    static let rWindow: CGFloat = 16, rCard: CGFloat = 18, rSheet: CGFloat = 18, rControl: CGFloat = 12
    static let rPill: CGFloat = 14, rSegment: CGFloat = 9, rSegmentOuter: CGFloat = 12, rKey: CGFloat = 8
    // Layout
    static let railWidth: CGFloat = 76, headerHeight: CGFloat = 72
    static let gutterLeading: CGFloat = 32, gutterTrailing: CGFloat = 28, cardGap: CGFloat = 16
    static let cardPadding: CGFloat = 20

    /// A duration as m:ss, or h:mm:ss from an hour (list rows, chips, timers).
    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Default motion: nothing bounces.
    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.85)
}

// MARK: - Type (Manrope, bundled; SIL OFL 1.1)

enum ScribeFonts {
    private static var cache: [String: NSFont] = [:]
    private static var available: Bool?

    /// Registers the bundled Manrope (Resources/Fonts) for this process. Info.plist also lists the
    /// folder in ATSApplicationFontsPath; this covers builds where that key didn't apply.
    static func register() {
        if NSFont(name: "Manrope-Regular", size: 12) != nil || NSFontManager.shared.availableMembers(ofFontFamily: "Manrope") != nil {
            return
        }
        let candidates = [Bundle.main.url(forResource: "Manrope", withExtension: "ttf", subdirectory: "Fonts"),
                          Bundle.main.url(forResource: "Manrope", withExtension: "ttf")]
        for case let url? in candidates {
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { return }
        }
    }

    private static let wghtTag = 0x77676874   // 'wght'

    /// Manrope at a weight (200–800) through the variable font's wght axis; nil if it isn't there.
    static func nsFont(size: CGFloat, weight: CGFloat) -> NSFont? {
        let key = "\(size)-\(weight)"
        if let f = cache[key] { return f }
        if available == false { return nil }
        let attrs: [NSFontDescriptor.AttributeName: Any] = [
            .family: "Manrope",
            .variation: [NSNumber(value: wghtTag): NSNumber(value: Double(weight))],
        ]
        let desc = NSFontDescriptor(fontAttributes: attrs)
        guard let f = NSFont(descriptor: desc, size: size), f.familyName == "Manrope" else {
            available = false
            return nil
        }
        available = true
        cache[key] = f
        return f
    }

    static func systemWeight(_ w: CGFloat) -> Font.Weight {
        switch w {
        case ..<350: return .light
        case ..<450: return .regular
        case ..<550: return .medium
        case ..<650: return .semibold
        case ..<750: return .bold
        default: return .heavy
        }
    }
}

extension Font {
    /// Manrope at `size` pt and `weight` (200–800). Falls back to the system font.
    static func scribe(_ size: CGFloat, _ weight: CGFloat = 500) -> Font {
        if let f = ScribeFonts.nsFont(size: size, weight: weight) { return Font(f as CTFont) }
        return .system(size: size, weight: ScribeFonts.systemWeight(weight))
    }
    // The type scale (DESIGN.md › Typography).
    static var nightDisplay: Font { scribe(22, 700) }
    static var nightTitle: Font { scribe(17, 700) }
    static var nightHeadline: Font { scribe(15, 700) }
    static var nightBody: Font { scribe(13.5, 500) }
    static var nightSecondary: Font { scribe(13, 500) }
    static var nightMeta: Font { scribe(12, 600) }
    static var nightLabel: Font { scribe(11.5, 700) }
    static var nightKeycap: Font { scribe(12.5, 800) }
    static var nightButton: Font { scribe(13.5, 700) }
}

// MARK: - Appearance (Settings › General)

enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system, dark, light
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "System"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }
    static let key = "appearance"
    static var current: AppearanceChoice {
        AppearanceChoice(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
    }
    /// Applies the choice to the whole app (nil = follow the Mac).
    @MainActor
    static func apply(_ choice: AppearanceChoice = current) {
        switch choice {
        case .system: NSApp.appearance = nil
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        }
    }
}

// MARK: - Legacy names (aliases onto Night)

enum Brand {
    static let accent = Night.accent
    /// Record / live indicators.
    static let record = Night.live
    /// 8-pt spacing grid.
    static let s1: CGFloat = 8, s2: CGFloat = 16, s3: CGFloat = 24, s4: CGFloat = 32
    static let rSmall: CGFloat = 12, rCard: CGFloat = 18, rPanel: CGFloat = 18
    /// Comfortable reading width for notes and transcripts.
    static let readingWidth: CGFloat = 760
}

enum Warm {
    static let canvas = Night.canvas
    static let surface = Night.surface
    static let well = Night.well
    static let hairline = Night.line
    /// 0.6's warm accent; in Night Sky every accent is the lavender one.
    static let honey = Night.accent
    static let shadow = Color.black.opacity(0.0)
}

// MARK: - Cards, canvas, buttons

/// A flat Night card background: surface fill, 1 px border, 1 px inner top highlight.
struct NightCardBackground: View {
    var radius: CGFloat = Night.rCard
    var fill: Color = Night.surface
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape.fill(fill)
            // Inner top edge: a 1 px highlight that fades out below the corner.
            shape.inset(by: 0.5)
                .stroke(LinearGradient(colors: [Night.highlight, .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.08)),
                        lineWidth: 1)
            shape.strokeBorder(Night.line, lineWidth: 1)
        }
    }
}

extension View {
    /// A Night card: surface, 18 radius, 1 px border + inner highlight, padding.
    func nightCard(radius: CGFloat = Night.rCard, padding: CGFloat = Night.cardPadding, fill: Color = Night.surface) -> some View {
        self.padding(padding)
            .background(NightCardBackground(radius: radius, fill: fill))
    }

    /// Old name for a card; same Night look.
    func scribeCard(radius: CGFloat = Night.rCard, padding: CGFloat = Night.cardPadding) -> some View {
        nightCard(radius: radius, padding: padding)
    }

    /// 0.6 glass, now a flat raised fill + line border (no blur).
    func scribeGlass<S: InsettableShape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        self.background {
            shape.fill(Night.raised)
            if let tint { shape.fill(tint) }
        }
        .overlay(shape.strokeBorder(Night.line2, lineWidth: 1))
    }

    /// Primary (accent gradient) or secondary (raised) button.
    func scribeButton(prominent: Bool = false) -> some View {
        self.buttonStyle(NightButtonStyle(kind: prominent ? .primary : .secondary))
    }

    /// The canvas behind content.
    func scribeCanvas() -> some View { self.background(Night.canvas) }

    /// Primary text color in the Night palette.
    func nightText(_ level: Int = 1) -> some View {
        self.foregroundStyle(level == 1 ? Night.text : level == 2 ? Night.text2 : Night.text3)
    }
}

/// Buttons: Primary (accent gradient, onAccent text, white top edge), Secondary (raised + line2),
/// Ghost (text2 only), Danger (secondary with the live color). 36 tall, 12 radius.
struct NightButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, danger }
    var kind: Kind = .secondary
    var height: CGFloat = 36
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        NightButtonBody(configuration: configuration, kind: kind, height: height, fullWidth: fullWidth)
    }
}

private struct NightButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: NightButtonStyle.Kind
    let height: CGFloat
    let fullWidth: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Night.rControl, style: .continuous)
        configuration.label
            .font(.nightButton)
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, kind == .ghost ? 10 : 15)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: height)
            .background {
                switch kind {
                case .primary:
                    shape.fill(Night.gradient)
                        .overlay(shape.inset(by: 0.5).stroke(LinearGradient(colors: [Color.white.opacity(0.35), .clear],
                                                                             startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.12)),
                                                             lineWidth: 1))
                case .secondary, .danger:
                    shape.fill(Night.raised).overlay(shape.strokeBorder(Night.line2, lineWidth: 1))
                case .ghost:
                    shape.fill(hover ? Night.accentSoft.opacity(0.6) : Color.clear)
                }
            }
            .brightness(configuration.isPressed ? -0.06 : (hover && kind != .ghost ? 0.03 : 0))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(shape)
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.12), value: hover)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return Night.onAccent
        case .secondary: return Night.text
        case .ghost: return Night.text2
        case .danger: return Night.live
        }
    }
}

extension ButtonStyle where Self == NightButtonStyle {
    static var nightPrimary: NightButtonStyle { NightButtonStyle(kind: .primary) }
    static var nightSecondary: NightButtonStyle { NightButtonStyle(kind: .secondary) }
    static var nightGhost: NightButtonStyle { NightButtonStyle(kind: .ghost) }
}

/// An icon-only button on a raised square (copy, more, close).
struct NightIconButtonStyle: ButtonStyle {
    var size: CGFloat = 30
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Night.text2)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Night.raised))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Night.line2, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}

// MARK: - App icon, symbol tile, menu bar glyph

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

/// An SF Symbol on a soft accent square: used for feature and setup cards.
struct SymbolTile: View {
    var symbol: String
    var size: CGFloat = 48
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(Night.accent)
            .frame(width: size, height: size)
            .background(Night.accentSoft, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).strokeBorder(Night.line, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// The menu bar icon: a small capsule sound wave as a TEMPLATE image (macOS tints it for
/// light/dark menu bars).  .idle = the wave   .live = wave + a dot   .busy = wave + three dots
enum MenuBarGlyph {
    enum Mode { case idle, live, busy }

    static func image(_ mode: Mode) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: true) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            cg.setFillColor(NSColor.black.cgColor)
            // Five capsule bars (the icon's wave), a little narrower when a badge sits beside it.
            let idle = mode == .idle
            let heights: [CGFloat] = idle ? [5, 10, 14, 9, 6] : [4, 8, 11, 7, 5]
            let w: CGFloat = idle ? 2.2 : 1.9
            let gap: CGFloat = idle ? 1.4 : 0.9
            let total = CGFloat(heights.count) * w + CGFloat(heights.count - 1) * gap
            let x0: CGFloat = idle ? (18 - total) / 2 : 0.5
            let cy: CGFloat = idle ? 9 : 6.5
            for (i, h) in heights.enumerated() {
                let r = CGRect(x: x0 + CGFloat(i) * (w + gap), y: cy - h / 2, width: w, height: h)
                cg.addPath(CGPath(roundedRect: r, cornerWidth: w / 2, cornerHeight: w / 2, transform: nil))
            }
            cg.fillPath()
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

// MARK: - Page header, block heading, empty state

/// A page header: Display title + meta on one line, trailing controls right-aligned. 72 tall.
struct PageHeader<Trailing: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title).font(.nightDisplay).tracking(-0.3).foregroundStyle(Night.text).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.nightSecondary).foregroundStyle(Night.text3).lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            trailing
        }
        .frame(height: Night.headerHeight)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A section label: a small sparkle + UPPERCASE text (11.5/700, +0.9 tracking).
struct SectionLabel: View {
    var title: String
    var color: Color = Night.text3
    var body: some View {
        HStack(spacing: 7) {
            Sparkle().fill(Night.star).frame(width: 9, height: 9)
            Text(title.uppercased()).font(.nightLabel).tracking(0.9).foregroundStyle(color).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A block heading inside a page ("Summary", "Action items"): the sparkle label. The symbol
/// argument is kept for older call sites.
struct BlockHeading: View {
    var title: String
    var symbol: String = ""
    var body: some View { SectionLabel(title: title) }
}

/// The empty state: one large sparkle (soft glow) over a row of dot-height idle bars, one
/// Headline line, one Secondary line, then an optional primary action. Nothing else.
struct CozyEmptyState<Actions: View>: View {
    var symbol: String
    var title: String
    var message: String
    @ViewBuilder var actions: Actions
    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 14) {
                SparkleView(size: 48, glow: true)
                CapsuleBars(levels: Array(repeating: 0, count: 9), barWidth: 5, spacing: 5, maxLength: 5, style: .dim)
            }
            .padding(.bottom, 4)
            VStack(spacing: 6) {
                Text(title).font(.nightHeadline).foregroundStyle(Night.text)
                // No fixedSize here: it would make the window's minimum height huge.
                Text(message).font(.nightSecondary).foregroundStyle(Night.text2)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .lineLimit(6)
                    .frame(maxWidth: 400)
            }
            actions.padding(.top, 6)
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

/// A 1 px divider in the line color.
struct NightDivider: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(Night.line)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}
