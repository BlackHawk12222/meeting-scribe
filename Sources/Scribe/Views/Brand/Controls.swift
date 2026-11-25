// Controls.swift
// Night Sky controls: toggle, segmented control, text field, search field, keycap, picker,
// tabs with the capsule underline, avatars and speaker chips. All flat, no system chrome.

import SwiftUI
import AppKit

// MARK: - Toggle

/// 38×22 capsule. Off: line2 fill, text2 knob. On: horizontal accent gradient, white knob.
struct NightToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        NightToggleBody(configuration: configuration)
    }
}

private struct NightToggleBody: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            configuration.label
            Spacer(minLength: 8)
            NightSwitch(isOn: configuration.isOn)
                .onTapGesture { withAnimation(Night.spring) { configuration.isOn.toggle() } }
        }
        .opacity(enabled ? 1 : 0.45)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAction { configuration.isOn.toggle() }
    }
}

/// The switch itself (also used where a row draws its own label).
struct NightSwitch: View {
    var isOn: Bool
    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule().fill(isOn ? AnyShapeStyle(Night.gradientH) : AnyShapeStyle(Night.line2))
            Circle().fill(isOn ? Color.white : Night.text2)
                .frame(width: 16, height: 16)
                .padding(3)
                .shadow(color: .black.opacity(isOn ? 0.18 : 0), radius: 1, y: 0.5)
        }
        .frame(width: 38, height: 22)
        .contentShape(Capsule())
        .animation(Night.spring, value: isOn)
    }
}

extension ToggleStyle where Self == NightToggleStyle {
    static var night: NightToggleStyle { NightToggleStyle() }
}

// MARK: - Segmented control

/// Well track with a 3 pt inset; the selected segment is raised with a line2 ring. No accent.
struct NightSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [(value: Value, title: String)]
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                let on = o.value == selection
                Button { withAnimation(Night.spring) { selection = o.value } } label: {
                    Text(o.title)
                        .font(.scribe(12.5, 700))
                        .foregroundStyle(on ? Night.text : Night.text3)
                        .lineLimit(1)
                        .padding(.horizontal, 13)
                        .frame(height: 28)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: Night.rSegment, style: .continuous)
                                    .fill(Night.raised)
                                    .overlay(RoundedRectangle(cornerRadius: Night.rSegment, style: .continuous)
                                        .strokeBorder(Night.line2, lineWidth: 1))
                                    .matchedGeometryEffect(id: "seg", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: Night.rSegmentOuter, style: .continuous).fill(Night.well))
        .overlay(RoundedRectangle(cornerRadius: Night.rSegmentOuter, style: .continuous).strokeBorder(Night.line, lineWidth: 1))
        .fixedSize()
    }
}

// MARK: - Tabs with the capsule underline

struct NightTabs<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [(value: Value, title: String)]
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 22) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                let on = o.value == selection
                Button { withAnimation(Night.spring) { selection = o.value } } label: {
                    VStack(spacing: 7) {
                        Text(o.title)
                            .font(.scribe(13.5, 700))
                            .foregroundStyle(on ? Night.text : Night.text3)
                            .fixedSize()
                        ZStack {
                            Capsule().fill(Color.clear).frame(height: 4)
                            if on {
                                Capsule().fill(Night.gradientTab).frame(height: 4)
                                    .matchedGeometryEffect(id: "underline", in: ns)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

// MARK: - Text fields

/// Well fill + line2 border, 12 radius, 38 tall. Focus: accent border + 3 pt accentSoft halo.
struct NightField: View {
    var placeholder: String
    @Binding var text: String
    var secure = false
    var height: CGFloat = 38
    var font: Font = .scribe(13.5, 600)
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if secure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(font)
        .foregroundStyle(Night.text)
        .tint(Night.accent)
        .focused($focused)
        .onSubmit(onSubmit)
        .padding(.horizontal, 12)
        .frame(height: height)
        .nightFieldChrome(focused: focused)
    }
}

extension View {
    /// The field look around any content (well fill, line2 border, accent focus ring).
    func nightFieldChrome(focused: Bool, radius: CGFloat = Night.rControl) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .background(shape.fill(Night.well))
            .overlay(shape.strokeBorder(focused ? Night.accent : Night.line2, lineWidth: 1))
            .background(shape.inset(by: -3).stroke(focused ? Night.accentSoft : Color.clear, lineWidth: 3))
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

/// The header search field: magnifier, prompt, a ⌘K keycap. `focusRequest` changing focuses it.
struct NightSearchField: View {
    @Binding var text: String
    var prompt: String
    var width: CGFloat = 260
    var focusRequest: Int = 0
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Night.text3)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.scribe(13, 500))
                .foregroundStyle(Night.text)
                .tint(Night.accent)
                .focused($focused)
                .onExitCommand { text = ""; focused = false }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Night.text3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            } else {
                Text("⌘K")
                    .font(.scribe(11, 600))
                    .foregroundStyle(Night.text3)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Night.line2, lineWidth: 1))
            }
        }
        .padding(.horizontal, 12)
        .frame(width: width, height: 36)
        .background(RoundedRectangle(cornerRadius: Night.rControl, style: .continuous).fill(Night.well))
        .overlay(RoundedRectangle(cornerRadius: Night.rControl, style: .continuous)
            .strokeBorder(focused ? Night.accent : Night.line, lineWidth: 1))
        .onChange(of: focusRequest) { _, _ in focused = true }
    }
}

// MARK: - Keycap

/// Raised, line2 border, a 2 pt bottom ledge.
struct Keycap: View {
    var text: String
    var height: CGFloat = 28
    var body: some View {
        Text(text)
            .font(.nightKeycap)
            .foregroundStyle(Night.text)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .frame(minWidth: 30, minHeight: height, maxHeight: height)
            .background {
                RoundedRectangle(cornerRadius: Night.rKey, style: .continuous).fill(Night.line2).offset(y: 2)
                RoundedRectangle(cornerRadius: Night.rKey, style: .continuous).fill(Night.raised)
            }
            .overlay(RoundedRectangle(cornerRadius: Night.rKey, style: .continuous).strokeBorder(Night.line2, lineWidth: 1))
            .padding(.bottom, 2)
            .fixedSize()
    }
}

// MARK: - Picker (a raised button that opens a list)

/// A menu-style picker drawn in the Night style: a raised button with the current value and a
/// chevron, opening a popover list. (A SwiftUI Menu would draw system chrome.)
struct NightPicker<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [(value: Value, title: String)]
    var minWidth: CGFloat = 0
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 8) {
                Text(title(selection)).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Night.text3)
            }
            .frame(minWidth: minWidth)
        }
        .buttonStyle(NightButtonStyle(kind: .secondary, height: 32))
        .fixedSize()
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                    Button { selection = o.value; open = false } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Night.accent)
                                .opacity(o.value == selection ? 1 : 0)
                            Text(o.title).font(.scribe(13, 600)).foregroundStyle(Night.text)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(MenuRowStyle())
                }
            }
            .padding(6)
            .frame(minWidth: max(minWidth, 200))
            .background(Night.raised)
        }
        .accessibilityLabel(title(selection))
    }

    private func title(_ v: Value) -> String { options.first { $0.value == v }?.title ?? "" }
}

// MARK: - Avatars

struct Avatar: View {
    var name: String
    var color: Color
    var size: CGFloat = 22
    var ring: Color? = nil
    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.scribe(size * 0.48, 800))
            .foregroundStyle(Night.onSpeaker)
            .frame(width: size, height: size)
            .background(Circle().fill(color))
            .overlay(Circle().strokeBorder(ring ?? .clear, lineWidth: 2).padding(-2))
            .accessibilityLabel(name)
    }
}

/// Overlapping avatars with a surface-colored ring between them.
struct AvatarStack: View {
    var people: [(name: String, color: Color)]
    var size: CGFloat = 22
    var limit = 4
    var body: some View {
        HStack(spacing: -6) {
            ForEach(Array(people.prefix(limit).enumerated()), id: \.offset) { _, p in
                Avatar(name: p.name, color: p.color, size: size)
                    .padding(2)
                    .background(Circle().fill(Night.surface))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(people.map(\.name).joined(separator: ", "))
    }
}

// MARK: - Record button

/// 64 pt accent circle with a mic glyph and a 6 pt accentSoft halo. Recording: a rounded-square
/// stop glyph.
struct RecordButton: View {
    var recording: Bool
    var size: CGFloat = 64
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Night.accentSoft).frame(width: size + 12, height: size + 12)
                Circle().fill(Night.gradient)
                    .overlay(Circle().inset(by: 0.5).stroke(LinearGradient(colors: [Color.white.opacity(0.35), .clear],
                                                                           startPoint: .top, endPoint: .center), lineWidth: 1))
                    .frame(width: size, height: size)
                if recording {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Night.onAccent)
                        .frame(width: size * 0.3, height: size * 0.3)
                } else {
                    Image(systemName: "mic").font(.system(size: size * 0.36, weight: .semibold)).foregroundStyle(Night.onAccent)
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(recording ? "Stop recording" : "Record a meeting")
    }
}

/// "● Recording · 12:48" in the live color.
struct LiveChip: View {
    var text: String
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(Night.live).frame(width: 7, height: 7)
            Text(text).font(.scribe(12.5, 700)).monospacedDigit().foregroundStyle(Night.live)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Capsule().fill(Night.liveSoft))
    }
}

// MARK: - Menu-like row

/// A menu-like row: highlights on hover, like native menu items.
struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuRow(configuration: configuration)
    }
    private struct MenuRow: View {
        let configuration: ButtonStyleConfiguration
        @State private var hover = false
        var body: some View {
            configuration.label
                .font(.scribe(13, 600))
                .foregroundStyle(Night.text)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(configuration.isPressed ? Night.accentSoft : (hover ? Night.accentSoft.opacity(0.7) : Color.clear)))
                .onHover { hover = $0 }
        }
    }
}
