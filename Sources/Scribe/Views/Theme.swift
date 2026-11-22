// Theme.swift
// Scribe's look: a 14th-century royal scribe, used lightly. The app stays clean and
// Apple-like; parchment, ink and a royal red/gold show up only as accents (headers,
// the dictation scroll, the mascot), never as busy textures.

import SwiftUI
import AppKit

enum Ink {
    /// Parchment cream (the scroll paper, header bands).
    static let parchment = Color(red: 0.953, green: 0.902, blue: 0.784)        // #F3E6C8
    /// A shade darker: rolled paper ends, borders.
    static let parchmentDeep = Color(red: 0.886, green: 0.812, blue: 0.647)    // #E2CFA5
    /// The lightest paper tone, for big backgrounds (headers) so text stays crisp.
    static let parchmentLight = Color(red: 0.984, green: 0.957, blue: 0.894)   // #FBF4E4
    /// Iron-gall ink: dark brown-black.
    static let ink = Color(red: 0.169, green: 0.114, blue: 0.078)               // #2B1D14
    /// Royal red (the mascot's robe, wax seals, record buttons).
    static let royal = Color(red: 0.620, green: 0.165, blue: 0.169)             // #9E2A2B
    /// Gold leaf trim.
    static let gold = Color(red: 0.831, green: 0.635, blue: 0.227)              // #D4A23A
}

/// The mascot pictures live in Assets.xcassets. If one is missing (shouldn't happen),
/// a quill symbol keeps the layout intact.
struct Mascot: View {
    enum Pose: String { case welcome = "MascotWelcome", empty = "MascotEmpty", about = "MascotAbout" }
    var pose: Pose
    var height: CGFloat

    var body: some View {
        if let img = NSImage(named: pose.rawValue) {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(height: height)
                .accessibilityLabel("Scribe mascot")
        } else {
            Image(systemName: "pencil.and.scribble")
                .font(.system(size: height * 0.5))
                .foregroundStyle(Ink.royal)
                .frame(height: height)
        }
    }
}

/// A soft parchment band with a thin gold hairline at the bottom: used as a header
/// background in onboarding and the main window. Plain color, no texture.
struct ParchmentBand: View {
    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [Ink.parchmentLight, Ink.parchment.opacity(0.85)],
                           startPoint: .top, endPoint: .bottom)
            Rectangle().fill(Ink.gold.opacity(0.55)).frame(height: 1)
        }
    }
}

/// The menu bar icon: a small open scroll (two paper rollers with a strip of parchment
/// between them, the same motif as the dictation overlay), drawn in code as a TEMPLATE
/// image so macOS tints it black or white to match the menu bar. Crisp at any scale.
///  .idle  = an ink squiggle on the strip
///  .live  = a solid dot (listening / recording a meeting)
///  .busy  = three dots (writing / transcribing)
enum MenuBarGlyph {
    enum Mode { case idle, live, busy }

    static func image(_ mode: Mode) -> NSImage {
        let size = NSSize(width: 20, height: 16)
        let img = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            // Rollers (rolled-up paper) at each end.
            for x in [CGFloat(1.2), 15.8] {
                NSBezierPath(roundedRect: NSRect(x: x, y: 1.2, width: 3.0, height: 13.6), xRadius: 1.5, yRadius: 1.5).fill()
            }
            // Top and bottom edges of the parchment strip.
            let edges = NSBezierPath()
            edges.move(to: NSPoint(x: 4.2, y: 12.2)); edges.line(to: NSPoint(x: 15.8, y: 12.2))
            edges.move(to: NSPoint(x: 4.2, y: 3.8));  edges.line(to: NSPoint(x: 15.8, y: 3.8))
            edges.lineWidth = 1.3
            edges.stroke()
            switch mode {
            case .idle:
                let ink = NSBezierPath()
                ink.move(to: NSPoint(x: 6.4, y: 8))
                var x: CGFloat = 6.4
                while x <= 13.6 {
                    ink.line(to: NSPoint(x: x, y: 8 + 1.25 * sin((x - 6.4) * 1.3)))
                    x += 0.2
                }
                ink.lineWidth = 1.15
                ink.lineCapStyle = .round
                ink.lineJoinStyle = .round
                ink.stroke()
            case .live:
                NSBezierPath(ovalIn: NSRect(x: 10 - 2.3, y: 8 - 2.3, width: 4.6, height: 4.6)).fill()
            case .busy:
                for x in [CGFloat(7.3), 10, 12.7] {
                    NSBezierPath(ovalIn: NSRect(x: x - 0.95, y: 8 - 0.95, width: 1.9, height: 1.9)).fill()
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
