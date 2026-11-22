// PillOverlay.swift
// The little black "pill" at the bottom of the screen while you dictate.
//
// It's an NSPanel (a floating window) that:
//  • never becomes the active window ("non-activating"), so the app you're typing
//    in keeps its cursor — otherwise ⌘V would paste into Scribe instead;
//  • ignores the mouse, floats above other windows, and shows on every Space.

import AppKit
import SwiftUI

@MainActor
final class PillOverlay {
    private var panel: NSPanel?
    private let size = NSSize(width: 240, height: 46)

    func show(_ controller: DictationController) {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.ignoresMouseEvents = true
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.contentView = NSHostingView(rootView: PillView().environmentObject(controller))
            panel = p
        }
        // Bottom-center of the screen your mouse is on.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            panel?.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.minY + 28))
        }
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }
}

/// What the pill draws. Matte black glass, white type.
struct PillView: View {
    @EnvironmentObject var dictation: DictationController

    var body: some View {
        HStack(spacing: 10) {
            switch dictation.state {
            case .listening:
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Bars(levels: dictation.levels)
                Text(Exporter.clock(dictation.elapsed).dropFirst(3))   // "00:12"
                    .font(.system(size: 12, weight: .medium, design: .rounded)).monospacedDigit()
            case .transcribing:
                ProgressView().controlSize(.small).tint(.white)
                Text("Writing…").font(.system(size: 13, weight: .medium, design: .rounded))
            case .done(let message), .failed(let message):
                Image(systemName: dictation.state.isFailure ? "exclamationmark.circle" : "checkmark")
                Text(message).font(.system(size: 13, weight: .medium, design: .rounded)).lineLimit(1)
            case .idle:
                EmptyView()
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                Capsule().fill(.ultraThinMaterial)
                Capsule().fill(Color.black.opacity(0.78))      // matte black over frosted glass
                Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

/// A tiny live level meter: one bar per recent loudness reading.
struct Bars: View {
    var levels: [Float]
    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, l in
                Capsule().fill(Color.white.opacity(0.9))
                    .frame(width: 3, height: max(3, CGFloat(l) * 22))
            }
        }
        .frame(height: 24)
        .animation(.easeOut(duration: 0.08), value: levels)
    }
}
