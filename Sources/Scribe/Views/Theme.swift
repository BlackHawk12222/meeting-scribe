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

/// THE design system (0.7.2). Every color, size, space, radius, shadow and animation the app
/// uses comes from here; docs/DESIGN.md lists the same values in plain words.
///  • Dark = "Night Sky": matte near-black, lavender accent, a 1 px top highlight on cards.
///  • Light = "Daylight" (new in 0.7.2, its own design, not dark with the backgrounds swapped):
///    cool paper-white surfaces, soft shadows instead of glow, softer lavender, no dots in the sky.
enum Night {
    // MARK: Color (light, dark)
    static let canvas = Color.night(0xF6F5FA, 0x0E0E11)
    static let rail = Color.night(0xEFEEF5, 0x09090B)
    static let surface = Color.night(0xFFFFFF, 0x16161A)
    static let raised = Color.night(0xFFFFFF, 0x1D1D23)
    static let well = Color.night(0xF1F0F6, 0x111114)
    static let hover = Color.night(0x1E1A3C, 0xFFFFFF, lightAlpha: 0.045, darkAlpha: 0.04)
    static let line = Color.night(0x1E1A3C, 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.065)
    static let line2 = Color.night(0x1E1A3C, 0xFFFFFF, lightAlpha: 0.13, darkAlpha: 0.10)
    static let highlight = Color.night(0xFFFFFF, 0xFFFFFF, lightAlpha: 0.0, darkAlpha: 0.04)
    static let text = Color.night(0x1C1B29, 0xECEBF5)
    static let text2 = Color.night(0x535166, 0xA9A8BC)
    static let text3 = Color.night(0x6B6980, 0x85849A)
    static let accentTop = Color.night(0x7C78E2, 0xBABCFF)
    static let accentBottom = Color.night(0x6863D6, 0x8680F6)
    static let accent = Color.night(0x5F5AD0, 0xA3A0FB)
    static let accentSoft = Color.night(0x6560D4, 0xA3A0FB, lightAlpha: 0.09, darkAlpha: 0.14)
    static let onAccent = Color.night(0xFFFFFF, 0x0D0C1A)
    static let star = Color.night(0xA8A3EC, 0xC9CAFF)
    /// Recording state only (dot, timer). Never decorative. Coral in both themes.
    static let live = Color.night(0xD3424F, 0xF2878E)
    static let liveSoft = Color.night(0xD3424F, 0xF2878E, lightAlpha: 0.10, darkAlpha: 0.14)
    /// Warnings (a failed step, a missing permission). Kept soft, like the rest.
    static let warn = Color.night(0xA15C12, 0xF4BE93)
    static let ok = Color.night(0x267A60, 0x8FD9C2)

    // MARK: Shadow (light only: dark mode uses the 1 px top highlight instead)
    static let shadow = Color.night(0x1E1A3C, 0x000000, lightAlpha: 0.07, darkAlpha: 0)
    static let shadowRadius: CGFloat = 6
    static let shadowY: CGFloat = 1

    /// The accent gradient, top → bottom (wave, primary button, record button). In light mode the
    /// two ends are close, so it reads as one soft lavender.
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

    // MARK: Space (a 4-pt scale: 4 / 8 / 12 / 16 / 20 / 24 / 32)
    static let s4: CGFloat = 4, s8: CGFloat = 8, s12: CGFloat = 12, s16: CGFloat = 16
    static let s20: CGFloat = 20, s24: CGFloat = 24, s32: CGFloat = 32

    // MARK: Radius
    static let rWindow: CGFloat = 12, rCard: CGFloat = 12, rSheet: CGFloat = 14, rControl: CGFloat = 7
    static let rPill: CGFloat = 9, rRow: CGFloat = 8, rSegment: CGFloat = 6, rSegmentOuter: CGFloat = 8, rKey: CGFloat = 6

    // MARK: Size (compact, Mac-native)
    static let controlHeight: CGFloat = 28        // buttons, search field, segmented control
    static let controlHeightSmall: CGFloat = 24   // keycaps, chips
    static let iconButton: CGFloat = 26
    static let switchSize = CGSize(width: 30, height: 18)
    static let rowHeight: CGFloat = 30            // sidebar items, settings pane rows, menu rows
    static let iconSmall: CGFloat = 10, iconRegular: CGFloat = 12, iconLarge: CGFloat = 14
    static let avatar: CGFloat = 22, avatarSmall: CGFloat = 18

    // MARK: Layout
    static let railWidth: CGFloat = 52, headerHeight: CGFloat = 52
    static let meetingsListWidth: CGFloat = 230, settingsListWidth: CGFloat = 124
    static let gutterLeading: CGFloat = 20, gutterTrailing: CGFloat = 18, cardGap: CGFloat = 12
    static let cardPadding: CGFloat = 14
    static let rowPaddingH: CGFloat = 12, rowPaddingV: CGFloat = 8

    // MARK: Motion (nothing bounces)
    static let fast = Animation.easeOut(duration: 0.12)      // hover, pressed
    static let base = Animation.easeInOut(duration: 0.2)     // show/hide, selection
    static let spring = Animation.spring(response: 0.3, dampingFraction: 0.9)

    /// A duration as m:ss, or h:mm:ss from an hour (list rows, chips, timers).
    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
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
    // The type scale (docs/DESIGN.md › Type). Compact in 0.7.2: body 13, titles 13 semibold.
    static var nightDisplay: Font { scribe(17, 650) }     // page title
    static var nightTitle: Font { scribe(14, 650) }       // sheet / dialog title
    static var nightHeadline: Font { scribe(13, 600) }    // row and card titles
    static var nightBody: Font { scribe(13, 460) }        // normal text
    static var nightReading: Font { scribe(13.5, 460) }   // notes and transcript (long reading)
    static var nightSecondary: Font { scribe(12, 460) }   // descriptions under a title
    static var nightSmallStrong: Font { scribe(12, 600) } // small emphasis, status lines
    static var nightMeta: Font { scribe(11, 550) }        // dates, counts, captions
    static var nightLabel: Font { scribe(10.5, 700) }     // UPPERCASE section labels
    static var nightKeycap: Font { scribe(11.5, 700) }
    static var nightButton: Font { scribe(12.5, 600) }
    /// SF Symbol sizes: small 10, regular 12, large 14 (semibold/medium).
    static func nightIcon(_ size: CGFloat = Night.iconRegular, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight)
    }
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
        // Light mode: a soft shadow gives the lift (dark mode's shadow color is clear).
        .shadow(color: Night.shadow, radius: Night.shadowRadius, y: Night.shadowY)
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
    var height: CGFloat = Night.controlHeight
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
            .padding(.horizontal, kind == .ghost ? Night.s8 : Night.s12)
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
                    shape.fill(hover ? Night.hover : Color.clear)
                }
            }
            .brightness(configuration.isPressed ? -0.06 : (hover && kind != .ghost ? 0.03 : 0))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(shape)
            .onHover { hover = $0 }
            .animation(Night.fast, value: hover)
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
    var size: CGFloat = Night.iconButton
    func makeBody(configuration: Configuration) -> some View {
        NightIconButtonBody(configuration: configuration, size: size)
    }
}

private struct NightIconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let size: CGFloat
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Night.rControl, style: .continuous)
        configuration.label
            .font(.nightIcon(Night.iconRegular, .semibold))
            .foregroundStyle(hover ? Night.text : Night.text2)
            .frame(width: size, height: size)
            .background(shape.fill(Night.raised))
            .overlay(shape.fill(hover ? Night.hover : .clear))
            .overlay(shape.strokeBorder(Night.line2, lineWidth: 1))
            .brightness(configuration.isPressed ? -0.06 : 0)
            .opacity(enabled ? 1 : 0.45)
            .contentShape(shape)
            .onHover { hover = $0 }
            .animation(Night.fast, value: hover)
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
    var size: CGFloat = 36
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
        HStack(alignment: .center, spacing: Night.s12) {
            HStack(alignment: .firstTextBaseline, spacing: Night.s8) {
                Text(title).font(.nightDisplay).tracking(-0.2).foregroundStyle(Night.text).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.nightSecondary).foregroundStyle(Night.text3).lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: Night.s12)
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
        HStack(spacing: Night.s4 + 2) {
            Sparkle().fill(Night.star).frame(width: 7, height: 7)
            Text(title.uppercased()).font(.nightLabel).tracking(0.7).foregroundStyle(color).lineLimit(1)
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
        VStack(spacing: Night.s12) {
            VStack(spacing: Night.s12) {
                SparkleView(size: 32, glow: true)
                CapsuleBars(levels: Array(repeating: 0, count: 7), barWidth: 4, spacing: 4, maxLength: 4, style: .dim)
            }
            .padding(.bottom, Night.s4)
            VStack(spacing: Night.s4) {
                Text(title).font(.nightHeadline).foregroundStyle(Night.text)
                // No fixedSize here: it would make the window's minimum height huge.
                Text(message).font(.nightSecondary).foregroundStyle(Night.text2)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .lineLimit(6)
                    .frame(maxWidth: 340)
            }
            actions.padding(.top, Night.s4)
        }
        .padding(Night.s24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .transition(.opacity)
    }
}

extension CozyEmptyState where Actions == EmptyView {
    init(symbol: String, title: String, message: String) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

/// A sidebar / list item (Settings panes, any vertical list of places): 30 tall, sparkle on the
/// selected one, hover tint, accentSoft when selected.
struct NightSidebarItem: View {
    var title: String
    var symbol: String? = nil
    var selected: Bool
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: Night.s8 - 2) {
                if let symbol {
                    Image(systemName: symbol).font(.nightIcon(Night.iconRegular))
                        .foregroundStyle(selected ? Night.accent : Night.text3).frame(width: 16)
                } else {
                    Sparkle().fill(Night.star).frame(width: 6, height: 6).opacity(selected ? 1 : 0)
                }
                Text(title).font(selected ? Font.nightHeadline : Font.nightBody)
                    .foregroundStyle(selected ? Night.text : Night.text2).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Night.s8)
            .frame(height: Night.rowHeight)
            .background(RoundedRectangle(cornerRadius: Night.rRow, style: .continuous)
                .fill(selected ? Night.accentSoft : (hover ? Night.hover : Color.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(Night.fast, value: hover)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A list row container (meeting rows, dictation rows): row padding, 8 radius, hover + selected fill.
struct NightRowBackground: View {
    var selected: Bool
    var hover: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: Night.rRow, style: .continuous)
            .fill(selected ? Night.accentSoft : (hover ? Night.hover : Color.clear))
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
