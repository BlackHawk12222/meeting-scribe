// SelfTestUpdater.swift
// 0.7: checks for the hardened updater (no network, no real install):
//  • version comparison (isNewer), including 0.5.38 vs 0.5.21 and 0.5.10 vs 0.5.9
//  • App Translocation path detection and where the update would be installed
//  • the swap script: shell syntax, then a dry run on throwaway folders (success: new app in
//    place + log written; failure: old app kept, failure marker written)

import Foundation

extension SelfTest {
    static func updaterLogicTest() -> [String: Any] {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            checks.append(["name": name, "pass": ok, "detail": detail])
            log("updater \(ok ? "PASS" : "FAIL"): \(name) \(detail)")
        }
        // Versions.
        check("0.5.38 is newer than 0.5.21", Updater.isNewer("0.5.38", than: "0.5.21"))
        check("0.5.21 is not newer than 0.5.38", !Updater.isNewer("0.5.21", than: "0.5.38"))
        check("0.5.10 is newer than 0.5.9 (numbers, not text)", Updater.isNewer("0.5.10", than: "0.5.9"))
        check("same version is not newer", !Updater.isNewer("0.7.3", than: "0.7.3"))
        check("0.7 equals 0.7.0", !Updater.isNewer("0.7", than: "0.7.0") && !Updater.isNewer("0.7.0", than: "0.7"))
        check("1.0 is newer than 0.9.99", Updater.isNewer("1.0", than: "0.9.99"))

        // Translocation.
        let fake = "/private/var/folders/xy/abc123/T/AppTranslocation/0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0/d/Scribe.app"
        check("translocated path detected", Updater.isTranslocated(fake))
        check("/Applications path is not translocated", !Updater.isTranslocated("/Applications/Scribe.app"))
        check("unresolvable translocated path → no install target (\"Move to Applications\")",
              Updater.installTarget(for: URL(fileURLWithPath: fake)) == nil)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("updater-test-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let cur = tmp.appendingPathComponent("Scribe.app", isDirectory: true)
        check("writable folder → installs in place", Updater.installTarget(for: cur)?.path == cur.path)
        check("read-only folder → no install target", Updater.installTarget(for: URL(fileURLWithPath: "/System/Applications/Scribe.app")) == nil)
        let running = Bundle.main.bundleURL.path
        let symbol = dlsym(dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY), "SecTranslocateCreateOriginalPathForURL") != nil

        // Swap script: syntax, then two dry runs against a process id that isn't running.
        func sh(_ args: [String]) -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = args
            do { try p.run() } catch { return -1 }
            p.waitUntilExit()
            return p.terminationStatus
        }
        let logFile = tmp.appendingPathComponent("update.log")
        let marker = tmp.appendingPathComponent("INSTALL_FAILED")
        let new = tmp.appendingPathComponent("Update/Scribe.app", isDirectory: true)
        let deadPID: Int32 = 999_999
        let script = Updater.swapScript(pid: deadPID, current: cur.path, new: new.path, log: logFile.path,
                                        marker: marker.path, relaunch: false)
        check("swap script parses (sh -n)", sh(["-n", "-c", script]) == 0)
        let fm = FileManager.default
        try? fm.createDirectory(at: cur.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try? "old".write(to: cur.appendingPathComponent("Contents/v.txt"), atomically: true, encoding: .utf8)
        try? fm.createDirectory(at: new.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try? "new".write(to: new.appendingPathComponent("Contents/v.txt"), atomically: true, encoding: .utf8)
        let ok = sh(["-c", script])
        let installed = (try? String(contentsOf: cur.appendingPathComponent("Contents/v.txt"), encoding: .utf8)) ?? ""
        let logText = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
        check("dry run: new app swapped in, old copy removed, steps logged",
              ok == 0 && installed == "new" && !fm.fileExists(atPath: cur.path + ".old") && logText.contains("done"),
              "exit \(ok), installed \(installed)")
        // Failure: the new app is missing → the current app stays, marker written.
        let bad = sh(["-c", script])          // `new` was moved away by the first run
        let still = (try? String(contentsOf: cur.appendingPathComponent("Contents/v.txt"), encoding: .utf8)) ?? ""
        check("dry run failure: current app kept, failure marker written, exit 1",
              bad == 1 && still == "new" && fm.fileExists(atPath: marker.path), "exit \(bad)")
        try? fm.removeItem(at: tmp)

        let failed = checks.filter { ($0["pass"] as? Bool) != true }.count
        return ["checks": checks, "failed": failed, "running_from": running,
                "running_translocated": Updater.isTranslocated(running), "sectranslocate_symbol": symbol]
    }
}
