// ModelDownloader.swift
// Fast, resumable downloads for the speech models.
//
// Why not FluidAudio's own downloader? It fetches files ONE AT A TIME, and one file
// (the speech encoder's weight.bin, ~445 MB) is 95% of the bytes. So here:
//  • big files are cut into 8 MB pieces and up to 8 pieces download at once
//    (HTTP "Range" requests — like several people carrying one couch);
//  • small files download in parallel too;
//  • every finished piece is written down in a little ".scribepart.json" note, so if the
//    Wi-Fi drops or you quit, the next launch continues where it stopped (resume);
//  • each piece is retried up to 5 times with a growing pause (1, 2, 4, 8 s).
// Files land in exactly the folder FluidAudio loads from, so FluidAudio finds them and
// never downloads anything itself.

import Foundation

/// One file to fetch.
struct DownloadJob: Sendable {
    var url: URL
    var destination: URL
    var size: Int64
}

/// Live numbers for the progress bar.
struct DownloadProgress: Sendable, Equatable {
    var doneBytes: Int64
    var totalBytes: Int64
    var bytesPerSecond: Double
    var fraction: Double { totalBytes > 0 ? min(1, Double(doneBytes) / Double(totalBytes)) : 0 }
    var secondsLeft: Double? {
        guard bytesPerSecond > 1 else { return nil }
        return Double(max(0, totalBytes - doneBytes)) / bytesPerSecond
    }

    /// "120 of 465 MB · 18.3 MB/s · about 20 s left"
    var text: String {
        let mb = { (b: Int64) in String(format: "%.0f", Double(b) / 1_000_000) }
        var s = "\(mb(doneBytes)) of \(mb(totalBytes)) MB"
        if bytesPerSecond > 1 { s += String(format: " · %.1f MB/s", bytesPerSecond / 1_000_000) }
        if let left = secondsLeft, doneBytes > 0 {
            s += left < 60 ? " · about \(max(1, Int(left.rounded()))) s left"
                           : " · about \(Int((left / 60).rounded(.up))) min left"
        }
        return s
    }
}

enum DownloadFailure: LocalizedError {
    case http(Int, String)
    case shortRead(String)
    var errorDescription: String? {
        switch self {
        case .http(let code, let file): return "Server answered \(code) for \(file)"
        case .shortRead(let file): return "Download of \(file) was cut short"
        }
    }
}

final class ModelDownloader: @unchecked Sendable {
    static let chunkSize: Int64 = 8 * 1024 * 1024
    let maxConcurrent: Int
    private let session: URLSession

    init(maxConcurrent: Int = 8) {
        self.maxConcurrent = maxConcurrent
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = maxConcurrent
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    /// A piece of work: one whole small file, or one 8 MB slice of a big file.
    private struct Piece: Sendable {
        var job: Int
        var index: Int          // slice number (0 for whole files)
        var start: Int64
        var end: Int64          // inclusive
        var whole: Bool
    }

    /// Download everything in `jobs`. `progress` is called (from any thread) a few times a second.
    func run(_ jobs: [DownloadJob], progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {
        let total = jobs.reduce(Int64(0)) { $0 + $1.size }
        let meter = Meter(total: total, report: progress)
        var ledgers: [Ledger] = []
        var pieces: [Piece] = []

        for (j, job) in jobs.enumerated() {
            let fm = FileManager.default
            try fm.createDirectory(at: job.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let ledger = Ledger(job: job)
            ledgers.append(ledger)
            if job.size <= Self.chunkSize * 2 {
                pieces.append(Piece(job: j, index: 0, start: 0, end: max(0, job.size - 1), whole: true))
                continue
            }
            let count = Int((job.size + Self.chunkSize - 1) / Self.chunkSize)
            let done = await ledger.prepareChunked(count: count)
            for i in 0..<count {
                let start = Int64(i) * Self.chunkSize
                let end = min(job.size, start + Self.chunkSize) - 1
                if done.contains(i) {
                    await meter.add(end - start + 1, resumed: true)
                } else {
                    pieces.append(Piece(job: j, index: i, start: start, end: end, whole: false))
                }
            }
        }
        // Biggest first, so the long file starts right away and small files fill the gaps.
        pieces.sort { jobs[$0.job].size > jobs[$1.job].size }

        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                await meter.tick()
            }
        }
        defer { ticker.cancel() }

        let work = pieces
        let limit = maxConcurrent
        try await withThrowingTaskGroup(of: Void.self) { group in
            // Keep at most `limit` pieces in flight; start the next one as each finishes.
            var next = 0
            while next < work.count && next < limit {
                let p = work[next]
                let job = jobs[p.job], ledger = ledgers[p.job]
                group.addTask { try await self.fetch(p, job: job, ledger: ledger, meter: meter) }
                next += 1
            }
            while try await group.next() != nil {
                if next < work.count {
                    let p = work[next]
                    let job = jobs[p.job], ledger = ledgers[p.job]
                    group.addTask { try await self.fetch(p, job: job, ledger: ledger, meter: meter) }
                    next += 1
                }
            }
        }

        for ledger in ledgers { try await ledger.finish() }
        await meter.tick(final: true)
    }

    private func fetch(_ p: Piece, job: DownloadJob, ledger: Ledger, meter: Meter) async throws {
        var attempt = 0
        while true {
            do {
                try Task.checkCancellation()
                var request = URLRequest(url: await ledger.bestURL())
                request.setValue("Scribe (macOS)", forHTTPHeaderField: "User-Agent")
                if !p.whole { request.setValue("bytes=\(p.start)-\(p.end)", forHTTPHeaderField: "Range") }
                let (data, response) = try await session.data(for: request)
                let http = response as? HTTPURLResponse
                let code = http?.statusCode ?? 0
                let name = job.destination.lastPathComponent
                guard (200..<300).contains(code) else {
                    if code == 403 || code == 410 { await ledger.forgetResolvedURL() }   // signed CDN link expired
                    throw DownloadFailure.http(code, name)
                }
                let expected = p.whole ? job.size : p.end - p.start + 1
                if p.whole {
                    guard Int64(data.count) == job.size else { throw DownloadFailure.shortRead(name) }
                } else {
                    // A server that ignores Range sends the whole file (200): don't accept that.
                    guard code == 206, Int64(data.count) == expected else { throw DownloadFailure.shortRead(name) }
                }
                if let final = http?.url, final != job.url { await ledger.remember(resolved: final) }
                try await ledger.write(data, at: p.start, piece: p.index, whole: p.whole)
                await meter.add(expected, resumed: false)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                attempt += 1
                if attempt >= 5 { throw error }
                let pause = UInt64(pow(2.0, Double(attempt - 1))) * 1_000_000_000
                try await Task.sleep(nanoseconds: pause)
            }
        }
    }
}

/// Keeps track of one file: where pieces go, which are done (saved to disk for resume),
/// and the final CDN address Hugging Face redirected us to (saves a round trip per piece).
private actor Ledger {
    let job: DownloadJob
    private var resolved: URL?
    private var done = Set<Int>()
    private var chunked = false
    private var part: URL { job.destination.appendingPathExtension("scribepart") }
    private var note: URL { job.destination.appendingPathExtension("scribepart.json") }

    init(job: DownloadJob) { self.job = job }

    func bestURL() -> URL { resolved ?? job.url }
    func remember(resolved url: URL) { if resolved == nil { resolved = url } }
    func forgetResolvedURL() { resolved = nil }

    /// Set up (or pick up) a sliced download. Returns the slices already on disk.
    func prepareChunked(count: Int) -> Set<Int> {
        chunked = true
        let fm = FileManager.default
        struct Note: Codable { var size: Int64; var chunk: Int64; var done: [Int] }
        if let data = try? Data(contentsOf: note),
           let n = try? JSONDecoder().decode(Note.self, from: data),
           n.size == job.size, n.chunk == ModelDownloader.chunkSize,
           let attrs = try? fm.attributesOfItem(atPath: part.path),
           (attrs[.size] as? NSNumber)?.int64Value == job.size {
            done = Set(n.done.filter { $0 < count })
            return done
        }
        try? fm.removeItem(at: part)
        try? fm.removeItem(at: note)
        fm.createFile(atPath: part.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: part) {
            try? h.truncate(atOffset: UInt64(job.size))      // reserve the full size up front
            try? h.close()
        }
        done = []
        return done
    }

    func write(_ data: Data, at offset: Int64, piece: Int, whole: Bool) throws {
        if whole {
            let fm = FileManager.default
            try data.write(to: part, options: .atomic)
            try? fm.removeItem(at: job.destination)
            try fm.moveItem(at: part, to: job.destination)
            return
        }
        let h = try FileHandle(forWritingTo: part)
        try h.seek(toOffset: UInt64(offset))
        try h.write(contentsOf: data)
        try h.close()
        done.insert(piece)
        struct Note: Codable { var size: Int64; var chunk: Int64; var done: [Int] }
        let n = Note(size: job.size, chunk: ModelDownloader.chunkSize, done: done.sorted())
        try? JSONEncoder().encode(n).write(to: note, options: .atomic)
    }

    /// All slices done: put the file in its real place.
    func finish() throws {
        guard chunked else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: job.destination)
        try fm.moveItem(at: part, to: job.destination)
        try? fm.removeItem(at: note)
    }
}

/// Adds up bytes and works out speed (smoothed) for "MB/s" and "time left".
private actor Meter {
    let total: Int64
    let report: @Sendable (DownloadProgress) -> Void
    private var done: Int64 = 0
    private var fresh: Int64 = 0                 // bytes downloaded this session (not resumed)
    private var lastFresh: Int64 = 0
    private var lastTime = Date()
    private var speed: Double = 0

    init(total: Int64, report: @escaping @Sendable (DownloadProgress) -> Void) {
        self.total = total
        self.report = report
    }

    func add(_ bytes: Int64, resumed: Bool) {
        done += bytes
        if !resumed { fresh += bytes }
    }

    func tick(final: Bool = false) {
        let now = Date()
        let dt = now.timeIntervalSince(lastTime)
        if dt > 0.2 {
            let instant = Double(fresh - lastFresh) / dt
            // Smooth it so the number doesn't jump around (pieces finish in bursts).
            speed = speed == 0 ? instant : speed * 0.75 + instant * 0.25
            lastFresh = fresh
            lastTime = now
        }
        report(DownloadProgress(doneBytes: final ? total : done, totalBytes: total, bytesPerSecond: speed))
    }
}
