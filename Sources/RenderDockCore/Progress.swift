import Foundation

/// Turns what a render prints on its standard output into progress. Pure: feed it lines.
///
/// Understood, in order of precedence:
/// 1. Explicit lines any script can print:  `FRAME 12/720`  or  `PROGRESS 12/720`
/// 2. Blender 5.x:  `… render | Rendering animation (frames 1..250)`, `… | Fra: 12 | … | Sample 8/64`, `… | Saved: '/out/f_0012.png'`
/// 3. Blender 4.x:  `Fra:12 Mem:… | Time:… | … Sample 8/64`, `Saved: '/out/f_0012.png'`, `Append frame 12`
package struct ProgressParser {
    /// Frames finished so far.
    package private(set) var done = 0
    /// Total frames, when the output or the command line says so.
    package private(set) var total: Int?
    /// The frame being rendered right now.
    package private(set) var frame: Int?
    package private(set) var sampleDone: Int?
    package private(set) var sampleTotal: Int?
    /// Where frames are being saved (taken from the first `Saved:` line).
    package private(set) var outDir: String?

    private var explicit = false
    private var saved = Set<Int>()
    private var unnumbered = 0

    /// `totalFromCommandLine`: the frame count the command line asks for, if it says (it knows about `-j`).
    package init(totalFromCommandLine: Int? = nil) {
        total = totalFromCommandLine
    }

    private static let explicitLine = try! NSRegularExpression(pattern: #"^\s*(?:FRAME|PROGRESS)\s+(\d+)\s*/\s*(\d+)\b"#, options: [.caseInsensitive])
    private static let animationRange = try! NSRegularExpression(pattern: #"Rendering animation \(frames (-?\d+)\.\.(-?\d+)\)"#)
    private static let currentFrame = try! NSRegularExpression(pattern: #"(?:^|\| )Fra: ?(\d+)\b|Rendering frame (\d+)\b"#)
    private static let samples = try! NSRegularExpression(pattern: #"Sample (\d+)/(\d+)|Rendering (\d+) / (\d+) samples"#)
    private static let savedFile = try! NSRegularExpression(pattern: #"Saved: '(.+)'"#)
    private static let appended = try! NSRegularExpression(pattern: #"(?:^|\| |Video )[Aa]ppend frame (\d+)\b"#)

    private static func groups(_ re: NSRegularExpression, _ line: String) -> [String?]? {
        let ns = line as NSString
        guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? nil : ns.substring(with: m.range(at: $0)) }
    }

    /// Feed one line of output. Returns true when it changed the progress.
    @discardableResult
    package mutating func feed(_ line: String) -> Bool {
        if let g = Self.groups(Self.explicitLine, line), let d = g[0].flatMap({ Int($0) }), let t = g[1].flatMap({ Int($0) }), t > 0 {
            explicit = true
            done = min(d, t)
            total = t
            sampleDone = nil
            sampleTotal = nil
            return true
        }
        var changed = false
        if total == nil, let g = Self.groups(Self.animationRange, line),
           let a = g[0].flatMap({ Int($0) }), let b = g[1].flatMap({ Int($0) }), b >= a {
            total = b - a + 1
            changed = true
        }
        if let g = Self.groups(Self.currentFrame, line), let f = (g[0] ?? g[1]).flatMap({ Int($0) }), f != frame {
            frame = f
            changed = true
        }
        if let g = Self.groups(Self.samples, line),
           let d = (g[0] ?? g[2]).flatMap({ Int($0) }), let t = (g[1] ?? g[3]).flatMap({ Int($0) }), t > 0 {
            if d != sampleDone || t != sampleTotal { changed = true }
            sampleDone = min(d, t)
            sampleTotal = t
        }
        var finishedOne = false
        if let g = Self.groups(Self.savedFile, line), let path = g[0] {
            let name = (path as NSString).lastPathComponent
            if outDir == nil, path.hasPrefix("/") { outDir = (path as NSString).deletingLastPathComponent }
            // Several passes of one frame (beauty, shadow, …) share a frame number and count once.
            // Temporary files (leading underscore, no number) are not frames.
            if let index = TaskScanner.frameIndex(name) {
                finishedOne = saved.insert(index).inserted
            } else if !name.hasPrefix("_") {
                unnumbered += 1
                finishedOne = true
            }
        } else if let g = Self.groups(Self.appended, line), let n = g[0].flatMap({ Int($0) }) {
            finishedOne = saved.insert(n).inserted
        }
        if finishedOne {
            sampleDone = nil
            sampleTotal = nil
            if !explicit { done = saved.count + unnumbered }
            changed = true
        }
        return changed
    }
}

/// What a wrapped job says about itself. Written by `renderdock run` (and, later, by the Blender hook)
/// to `~/Library/Application Support/RenderDock/reports/<pid>.json`. Never written into a render folder.
package struct JobReport: Codable, Equatable {
    package var v = 1
    package var pid: Int32
    /// Start of the reported process, seconds since 1970. Guards against a recycled pid.
    package var startedAt: Double
    /// "wrapper" or "hook".
    package var source: String
    /// A display name, when one was given.
    package var name: String?
    package var done = 0
    package var total: Int?
    package var frame: Int?
    package var sampleDone: Int?
    package var sampleTotal: Int?
    package var outDir: String?
    /// When the most recent frames finished (seconds since 1970, newest last, at most 30).
    package var recent: [Double] = []
    package var updatedAt: Double
    /// Set when the process has ended: its exit status (128 + signal when it was killed).
    package var exitCode: Int32?
    package var endedAt: Double?

    package init(pid: Int32, startedAt: Double, source: String, name: String? = nil) {
        self.pid = pid
        self.startedAt = startedAt
        self.source = source
        self.name = name
        self.updatedAt = startedAt
    }

    /// Median time between the recent frames.
    package var secPerFrame: Double? {
        guard recent.count >= 3 else { return nil }
        let deltas = zip(recent.dropFirst(), recent).map { $0 - $1 }.sorted()
        let median = deltas[deltas.count / 2]
        return median > 0 ? median : nil
    }

    /// Copies the parser's view into the report; notes a finished frame's time.
    package mutating func absorb(_ p: ProgressParser, now: Double) {
        if p.done > done { recent = Array((recent + Array(repeating: now, count: min(p.done - done, 30))).suffix(30)) }
        done = p.done
        total = p.total
        frame = p.frame
        sampleDone = p.sampleDone
        sampleTotal = p.sampleTotal
        outDir = p.outDir ?? outDir
        updatedAt = now
    }
}

package struct JobOutcome: Equatable {
    package var exitCode: Int32
    package var finished: Bool { exitCode == 0 }

    package init(exitCode: Int32) { self.exitCode = exitCode }
}

package enum ReportStore {
    /// Override with the RENDERDOCK_REPORTS environment variable (used by the checks).
    package static var directory: URL {
        if let custom = ProcessInfo.processInfo.environment["RENDERDOCK_REPORTS"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RenderDock/reports", isDirectory: true)
    }

    package static func url(pid: Int32) -> URL { directory.appendingPathComponent("\(pid).json") }

    package static func write(_ report: JobReport) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(report) else { return }
        try? data.write(to: url(pid: report.pid), options: .atomic)
    }

    package static func read(pid: Int32) -> JobReport? {
        guard let data = try? Data(contentsOf: url(pid: pid)) else { return nil }
        return try? JSONDecoder().decode(JobReport.self, from: data)
    }

    package static func all() -> [JobReport] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap {
            (try? Data(contentsOf: $0)).flatMap { try? JSONDecoder().decode(JobReport.self, from: $0) }
        }
    }

    package static func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    /// Removes reports nobody needs any more: ended more than `keep` ago, or abandoned by a process that died without saying so.
    package static func prune(now: Double = Date().timeIntervalSince1970, keep: Double = 3 * 86_400) {
        for r in all() {
            let last = r.endedAt ?? r.updatedAt
            if now - last > keep, r.endedAt != nil || !isAlive(r.pid) {
                try? FileManager.default.removeItem(at: url(pid: r.pid))
            }
        }
    }
}
