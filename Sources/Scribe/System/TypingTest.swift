// TypingTest.swift
// Settings › Permissions › "Test typing into TextEdit": opens an empty text file in TextEdit,
// types a test line exactly like a dictation would (same TextInserter path), and reads the
// text box back through Accessibility to confirm it landed. Also used by the self-test.

import AppKit

@MainActor
enum TypingTest {
    static let sample = "Scribe typing test ✓"

    struct Result {
        var ok: Bool
        var report: PasteReport?
        var message: String
    }

    static func run() async -> Result {
        guard Permissions.accessibilityGranted else {
            return Result(ok: false, report: nil, message: "Accessibility is off, so Scribe can only copy. Use Fix above, then test again.")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Scribe typing test.txt")
        try? Data().write(to: file)
        guard let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else {
            return Result(ok: false, report: nil, message: "TextEdit isn't installed.")
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        do {
            _ = try await NSWorkspace.shared.open([file], withApplicationAt: textEdit, configuration: config)
        } catch {
            return Result(ok: false, report: nil, message: "Couldn't open TextEdit: \(error.localizedDescription)")
        }
        // Wait for TextEdit to be in front with its window focused.
        for _ in 0..<40 where NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.TextEdit" {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard let target = FocusTracker.capture(), target.bundleID == "com.apple.TextEdit" else {
            return Result(ok: false, report: nil, message: "TextEdit didn't come to the front.")
        }
        let r = await TextInserter.insert(sample, target: target, restoreClipboard: true, verify: true)
        let landed: Bool
        switch r.outcome {
        case .typedDirectly: landed = true
        case .pasted: landed = r.verified ?? false
        default: landed = false
        }
        let msg = landed
            ? "It works: \(r.line). You can close the TextEdit window without saving."
            : "Didn't land in TextEdit (\(r.line)). Try Fix above (remove Scribe from the list, add it again)."
        return Result(ok: landed, report: r, message: msg)
    }
}
