// AppLog.swift
// 0.7.5: one plain-text log for things that only go wrong on a real Mac (permissions, the code
// signature macOS sees, meeting audio sources, sign-in links). ~/Library/Logs/Scribe/scribe.log,
// trimmed to the last ~1 MB. Never logs audio, transcripts, tokens or keys.

import Foundation

enum AppLog {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Scribe/scribe.log")
    }
    private static let lock = NSLock()
    private static let maxBytes = 1_000_000

    static func log(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        lock.lock(); defer { lock.unlock() }
        let u = url
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? NSNumber)?.intValue,
           size > maxBytes, let old = try? Data(contentsOf: u) {
            try? old.suffix(maxBytes / 2).write(to: u)
        }
        if let h = try? FileHandle(forWritingTo: u) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: u)
        }
    }
}
