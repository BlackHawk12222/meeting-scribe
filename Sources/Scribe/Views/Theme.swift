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
    // MARK: Color (light, dark): 0.7.3 "Poster" (docs/DESIGN.md)
    // Flat white / near-black, hairline borders, no gradients, no glow. Color lives in the big
    // poster tiles (indigo, coral, green, black) and nowhere else.
    static let canvas = Color.night(0xFFFFFF, 0x111112)
    static let rail = Color.night(0xF7F7F8, 0x0B0B0C)
    static let surface = Color.night(0xFFFFFF, 0x111112)
    static let raised = Color.night(0xFFFFFF, 0x1A1A1C)
    static let well = Color.night(0xF7F7F8, 0x161618)
    static let hover = Color.night(0xF5F5F7, 0x19191B)
    /// Hairline: borders and dividers.
    static let line = Color.night(0xE8E8EB, 0x232326)
    /// Control borders (buttons, fields, chips).
    static let line2 = Color.night(0xDADADF, 0x2E2E32)
    static let highlight = Color.night(0xFFFFFF, 0xFFFFFF, lightAlpha: 0, darkAlpha: 0)
    static let text = Color.night(0x111113, 0xEDEDF0)
    static let text2 = Color.night(0x6B6B73, 0x9A9AA3)
    static let text3 = Color.night(0x8E8E96, 0x76767E)
    static let accentTop = Color.night(0x5B57D9, 0x8E8BF5)
    static let accentBottom = Color.night(0x5B57D9, 0x8E8BF5)
    static let accent = Color.night(0x5B57D9, 0x8E8BF5)
    static let accentSoft = Color.night(0x5B57D9, 0x8E8BF5, lightAlpha: 0.10, darkAlpha: 0.16)
    static let onAccent = Color.night(0xFFFFFF, 0x111113)
    static let star = Color.night(0x9A9AA2, 0x6E6E76)
    /// Selected row / rail item fill (the hairline color, like the mockups).
    static let selected = Color.night(0xEDEDF0, 0x232326)
    /// Primary button (Record pill, Name speaker): black in light mode, near-white in dark.
    static let primary = Color.night(0x111113, 0xEDEDF0)
    static let onPrimary = Color.night(0xFFFFFF, 0x111113)
    /// Recording state only (dot, timer). Never decorative.
    static let live = Color.night(0xE5484D, 0xE5484D)
    static let liveSoft = Color.night(0xE5484D, 0xE5484D, lightAlpha: 0.10, darkAlpha: 0.16)
    /// Warnings (a failed step, a missing permission).
    static let warn = Color.night(0xB4560E, 0xF4BE93)
    static let ok = Color.night(0x1FA463, 0x3CC584)

    // MARK: Poster tiles (same in both themes; the black tile gets a hairline in dark mode)
    static let posterIndigo = Color(hex: 0x5B57D9)
    static let posterCoral = Color(hex: 0xF2685B)
    static let posterGreen = Color(hex: 0x1FA463)
    static let posterBlack = Color(hex: 0x141416)
    static let posterBlackEdge = Color.night(0x141416, 0x2E2E32)

    /// "Where you talk": one color per app, by rank (Notes-yellow, green, blue, cyan, indigo, coral).
    static let appColors: [Color] = [Color(hex: 0xF5B83D), Color(hex: 0x34C77B), Color(hex: 0x3D8BFD),
                                     Color(hex: 0x36B5D9), Color(hex: 0x5B57D9), Color(hex: 0xF2685B)]
    /// Apps past the sixth, and dictations from before 0.7.3 (no app recorded).
    static let appOther = Color.night(0xB4B4BC, 0x5A5A62)
    /// The 26-week heatmap: empty → most (light), dark mode gets brighter as it fills.
    static let heat: [Color] = [Color.night(0xEEEEF3, 0x1E1E22), Color.night(0xD6D4FB, 0x2E2B5C),
                                Color.night(0xABA7F5, 0x433E9A), Color.night(0x7C77EB, 0x625CD6),
                                Color.night(0x5B57D9, 0x8E8BF5)]

    // MARK: Shadow (none in Poster: hairlines do the work)
    static let shadow = Color.night(0x000000, 0x000000, lightAlpha: 0, darkAlpha: 0)
    static let shadowRadius: CGFloat = 0
    static let shadowY: CGFloat = 0

    /// Kept for older call sites: a flat accent (Poster has no gradients).
    static let gradient = LinearGradient(colors: [accent, accent], startPoint: .top, endPoint: .bottom)
    static let gradientH = LinearGradient(colors: [accent, accent], startPoint: .leading, endPoint: .trailing)
    static let gradientTab = LinearGradient(colors: [text, text], startPoint: .leading, endPoint: .trailing)

    /// Speaker avatar fills (white letter on top), assigned in order.
    static let speakers: [Color] = [Color(hex: 0x5B57D9), Color(hex: 0xF2685B), Color(hex: 0x1FA463),
                                    Color(hex: 0xF5B83D), Color(hex: 0x3D8BFD), Color(hex: 0x36B5D9)]
    static let onSpeaker = Color.white
    /// An unnamed speaker ("Speaker 4").
    static let unnamed = Color.night(0x8E8E96, 0x5A5A62)

    /// The dictation capsule: always black (#141416), in both themes.
    static let overlayTop = Color(hex: 0x141416)
    static let overlayBottom = Color(hex: 0x141416)
    static let overlayStar = Color(hex: 0xEDEDF0)
    static let overlayAccentTop = Color(hex: 0x1FA463)
    static let overlayAccentBottom = Color(hex: 0x1FA463)
    static let overlayLive = Color(hex: 0xE5484D)

    // MARK: Space (a 4-pt scale: 4 / 8 / 12 / 16 / 20 / 24 / 32)
    static let s4: CGFloat = 4, s8: CGFloat = 8, s12: CGFloat = 12, s16: CGFloat = 16
    static let s20: CGFloat = 20, s24: CGFloat = 24, s32: CGFloat = 32

    // MARK: Radius
    static let rWindow: CGFloat = 10, rCard: CGFloat = 8, rSheet: CGFloat = 10, rControl: CGFloat = 6
    static let rPill: CGFloat = 8, rRow: CGFloat = 6, rSegment: CGFloat = 5, rSegmentOuter: CGFloat = 7, rKey: CGFloat = 5
    /// Poster tiles.
    static let rTile: CGFloat = 10

    // MARK: Size (compact, Mac-native)
    static let controlHeight: CGFloat = 28        // buttons, search field, segmented control
    static let controlHeightSmall: CGFloat = 24   // keycaps, chips
    static let iconButton: CGFloat = 26
    static let switchSize = CGSize(width: 34, height: 20)
    static let rowHeight: CGFloat = 32            // sidebar items, settings pane rows, menu rows
    static let iconSmall: CGFloat = 10, iconRegular: CGFloat = 12, iconLarge: CGFloat = 14
    static let avatar: CGFloat = 22, avatarSmall: CGFloat = 18

    // MARK: Layout
    static let railWidth: CGFloat = 46, headerHeight: CGFloat = 52
    static let meetingsListWidth: CGFloat = 300, settingsListWidth: CGFloat = 196
    static let gutterLeading: CGFloat = 28, gutterTrailing: CGFloat = 28, cardGap: CGFloat = 12
    static let cardPadding: CGFloat = 16
    /// Poster tile height on Home (the other pages use a shorter one).
    static let tileHeight: CGFloat = 186, tileHeightCompact: CGFloat = 132
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
    /// 0.7.3 "Poster": the system font (SF Pro, Inter-like) at `size` pt and `weight` (200–800).
    /// Manrope stays bundled for older builds' screenshots but is no longer used.
    static func scribe(_ size: CGFloat, _ weight: CGFloat = 500) -> Font {
        .system(size: size, weight: ScribeFonts.systemWeight(weight))
    }
    // The type scale (docs/DESIGN.md › Type). Poster: body 14, reading 15, nothing tiny.
    static var nightDisplay: Font { scribe(15, 600) }     // page title in the top bar
    static var nightTitle: Font { scribe(17, 600) }       // sheet / dialog title
    static var nightHeadline: Font { scribe(14, 560) }    // row and card titles
    static var nightBody: Font { scribe(14, 420) }        // normal text
    static var nightReading: Font { scribe(15, 420) }     // notes, transcript, dictations
    static var nightSecondary: Font { scribe(13, 420) }   // descriptions under a title
    static var nightSmallStrong: Font { scribe(13, 560) } // small emphasis, status lines
    static var nightMeta: Font { scribe(12.5, 420) }      // dates, counts, captions
    static var nightLabel: Font { scribe(12.5, 600) }     // section labels (sentence case)
    static var nightKeycap: Font { scribe(13, 600) }
    static var nightButton: Font { scribe(13, 500) }
    /// Big poster numbers.
    static func posterNumber(_ size: CGFloat = 72) -> Font { .system(size: size, weight: .bold) }
    /// A page heading inside the content (Settings pane title, meeting title).
    static var pageTitle: Font { scribe(24, 650) }
    /// SF Symbol sizes: small 10, regular 12, large 14 (semibold/medium).
    static func nightIcon(_ size: CGFloat = Night.iconRegular, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight)
    }
}

// MARK: - Appearance (Settings › General)

enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system, light, dark
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
        // Poster: flat fill + one hairline. No shadow, no inner highlight.
        ZStack {
            shape.fill(fill)
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
                    shape.fill(Night.primary)
                case .secondary, .danger:
                    shape.fill(Night.raised).overlay(shape.strokeBorder(Night.line2, lineWidth: 1))
                case .ghost:
                    shape.fill(hover ? Night.hover : Color.clear)
                }
            }
            .opacity(configuration.isPressed ? 0.8 : (hover && kind == .primary ? 0.9 : 1))
            .background { if hover && kind == .secondary { shape.fill(Night.hover) } }
            .opacity(enabled ? 1 : 0.45)
            .contentShape(shape)
            .onHover { hover = $0 }
            .animation(Night.fast, value: hover)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return Night.onPrimary
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
        // Poster: sentence case, 12.5 semibold, secondary text. No sparkle.
        Text(title).font(.nightLabel).foregroundStyle(color == Night.text3 ? Night.text2 : color).lineLimit(1)
            .accessibilityAddTraits(.isHeader)
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
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Night.text3)
                .frame(width: 44, height: 44)
                .overlay(RoundedRectangle(cornerRadius: Night.rCard, style: .continuous).strokeBorder(Night.line, lineWidth: 1))
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
                        .foregroundStyle(selected ? Night.text : Night.text2).frame(width: 18)
                }
                Text(title).font(.nightBody)
                    .foregroundStyle(selected ? Night.text : Night.text2).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Night.s12)
            .frame(height: Night.rowHeight + 2)
            .background(RoundedRectangle(cornerRadius: Night.rRow, style: .continuous)
                .fill(selected ? Night.selected : (hover ? Night.hover : Color.clear)))
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
            .fill(selected ? Night.selected : (hover ? Night.hover : Color.clear))
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
