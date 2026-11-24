import Foundation

/// Turns what a render prints on its standard output into progress. Pure: feed it lines.
///
/// Understood, in order of precedence:
/// 1. Explicit lines any script can print:  `FRAME 12/720`  or  `PROGRESS 12/720`
/// 2. Blender 5.x:  `… render | Rendering animation (frames 1..250)`, `… | Fra: 12 | … | Sample 8/64`, `… | Saved: '/out/f_0012.png'`
/// 3. Blender 4.x:  `Fra:12 Mem:… | Time:… | … Sample 8/64`, `Saved: '/out/f_0012.png'`, `Append frame 12`
/// 4. ffmpeg:  the `Duration:` of each input, then its status line (`frame= 150 fps= 30 … time=00:00:05.00 bitrate=… speed=1.01x`),
///    or what `-progress` prints (`out_time_us=5000000`, `speed=1.01x`, `progress=end`). An encode has no frames to
///    count on, so its progress is seconds of output written against the length the output will have.
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

    /// For an encode: seconds of output written so far.
    package private(set) var mediaDone: Double?
    /// How long the output will be, when that can be told: from `-t` on the command line, or else from the inputs.
    package private(set) var mediaTotal: Double?
    /// The length is a best guess: something on the command line (a seek, a filter that changes timing, several
    /// inputs of different lengths) means the output need not be as long as its longest input.
    package private(set) var mediaTotalIsRough = false
    /// Seconds of output per second of the clock, as ffmpeg reports it.
    package private(set) var mediaSpeed: Double?

    private var explicit = false
    private var saved = Set<Int>()
    private var unnumbered = 0
    private var inputDurations: [Double] = []
    private var encodePlan = EncodePlan()
    private var encodeStarted = false
    private var mediaTotalGivenUp = false

    /// `totalFromCommandLine`: the frame count the command line asks for, if it says (it knows about `-j`).
    /// `ffmpegArguments`: an ffmpeg command line, when that is what is running; it may say how long the output is.
    package init(totalFromCommandLine: Int? = nil, ffmpegArguments: [String]? = nil) {
        total = totalFromCommandLine
        if let ffmpegArguments { encodePlan = Self.encodePlan(ffmpegArguments) }
    }

    /// What an ffmpeg command line says about the length of its output.
    package struct EncodePlan: Equatable {
        /// `-t`, when given: the output is at most this long.
        package var limit: Double?
        /// Something on the line changes how long the output is, in a way not worked out here.
        package var rough = false
        /// The inputs are joined end to end (`concat` in a filter graph), so their lengths add up.
        package var joined = false

        package init(limit: Double? = nil, rough: Bool = false, joined: Bool = false) {
            self.limit = limit
            self.rough = rough
            self.joined = joined
        }
    }

    /// A time as ffmpeg takes it on the command line: `90`, `90.5`, `1:30`, `0:01:30.5`, `1500ms`.
    package static func mediaTime(_ text: String) -> Double? {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("ms"), let n = Double(t.dropLast(2)) { return n / 1000 }
        if t.hasSuffix("us"), let n = Double(t.dropLast(2)) { return n / 1_000_000 }
        if t.hasSuffix("s") { t.removeLast() }
        let parts = t.split(separator: ":", omittingEmptySubsequences: false).map { Double($0) }
        guard !parts.isEmpty, parts.count <= 3, !parts.contains(nil) else { return nil }
        let seconds = parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
        return seconds >= 0 ? seconds : nil
    }

    package static func encodePlan(_ arguments: [String]) -> EncodePlan {
        var plan = EncodePlan()
        var i = 0
        while i < arguments.count {
            let a = arguments[i]
            let value = i + 1 < arguments.count ? arguments[i + 1] : ""
            switch a {
            case "-t":
                if let seconds = mediaTime(value), seconds > 0 { plan.limit = min(plan.limit ?? seconds, seconds) }
                i += 1
            case "-ss", "-to", "-sseof", "-itsoffset", "-stream_loop", "-fs", "-frames:v", "-vframes", "-frames:a", "-aframes":
                plan.rough = true
                i += 1
            case "-shortest":
                plan.rough = true
            default:
                if a == "-filter_complex" || a == "-lavfi" || a == "-vf" || a == "-af" || a.hasPrefix("-filter") {
                    if value.contains("concat") { plan.joined = true }
                    if ["concat", "setpts", "trim", "atempo", "tpad", "apad", "loop", "xfade", "acrossfade", "select"].contains(where: value.contains) { plan.rough = true }
                    i += 1
                }
            }
            i += 1
        }
        return plan
    }

    private static let explicitLine = try! NSRegularExpression(pattern: #"^\s*(?:FRAME|PROGRESS)\s+(\d+)\s*/\s*(\d+)\b"#, options: [.caseInsensitive])
    private static let animationRange = try! NSRegularExpression(pattern: #"Rendering animation \(frames (-?\d+)\.\.(-?\d+)\)"#)
    private static let currentFrame = try! NSRegularExpression(pattern: #"(?:^|\| )Fra: ?(\d+)\b|Rendering frame (\d+)\b"#)
    private static let samples = try! NSRegularExpression(pattern: #"Sample (\d+)/(\d+)|Rendering (\d+) / (\d+) samples"#)
    private static let savedFile = try! NSRegularExpression(pattern: #"Saved: '(.+)'"#)
    private static let appended = try! NSRegularExpression(pattern: #"(?:^|\| |Video )[Aa]ppend frame (\d+)\b"#)
    private static let inputDuration = try! NSRegularExpression(pattern: #"^\s+Duration: (\d+):(\d\d):(\d\d(?:\.\d+)?),"#)
    private static let encodeTime = try! NSRegularExpression(pattern: #"(?:^|\s)time=(\d+):(\d\d):(\d\d(?:\.\d+)?)\s.*bitrate="#)
    private static let encodeSpeed = try! NSRegularExpression(pattern: #"(?:^|\s)speed=\s*(\d+(?:\.\d+)?)x"#)
    private static let outTimeMicro = try! NSRegularExpression(pattern: #"^out_time_us=(\d+)\s*$"#)
    private static let outTime = try! NSRegularExpression(pattern: #"^out_time=(\d+):(\d\d):(\d\d(?:\.\d+)?)\s*$"#)

    /// One line of an encode's output, if that is what it is. True when it moved the progress.
    private mutating func feedEncode(_ line: String) -> Bool {
        if !encodeStarted, let g = Self.groups(Self.inputDuration, line),
           let h = g[0].flatMap({ Double($0) }), let m = g[1].flatMap({ Double($0) }), let s = g[2].flatMap({ Double($0) }) {
            inputDurations.append(h * 3600 + m * 60 + s)
            return false
        }
        var at: Double?
        if let g = Self.groups(Self.encodeTime, line) ?? Self.groups(Self.outTime, line),
           let h = g[0].flatMap({ Double($0) }), let m = g[1].flatMap({ Double($0) }), let s = g[2].flatMap({ Double($0) }) {
            at = h * 3600 + m * 60 + s
        } else if let g = Self.groups(Self.outTimeMicro, line), let micro = g[0].flatMap({ Double($0) }) {
            at = micro / 1_000_000
        }
        var changed = false
        if let g = Self.groups(Self.encodeSpeed, line), let speed = g[0].flatMap({ Double($0) }), speed > 0, speed != mediaSpeed {
            mediaSpeed = speed
            changed = at != nil
        }
        if line.hasPrefix("progress=end"), let total = mediaTotal, mediaDone != nil {
            mediaDone = total
            return true
        }
        guard let at else { return changed }
        if !encodeStarted {
            // The first sign of output. What is known about the inputs by now is all there will be.
            encodeStarted = true
            let longest = inputDurations.max()
            let together = encodePlan.joined && inputDurations.count > 1 ? inputDurations.reduce(0, +) : longest
            mediaTotal = [encodePlan.limit, together].compactMap { $0 }.min()
            let uneven = inputDurations.count > 1 && (inputDurations.max() ?? 0) - (inputDurations.min() ?? 0) > 0.5
            // With `-t` shorter than every input the length is exactly `-t`, whatever else is on the line.
            let cutShort = encodePlan.limit.map { limit in !inputDurations.isEmpty && inputDurations.allSatisfy { $0 >= limit } && !encodePlan.joined } ?? false
            mediaTotalIsRough = !cutShort && (encodePlan.rough || uneven)
        }
        // Output running past the length it was thought to have: the length was wrong, and is dropped for good.
        if let total = mediaTotal, at > total * 1.02 + 0.5 {
            mediaTotal = nil
            mediaTotalGivenUp = true
        }
        if at != mediaDone {
            mediaDone = at
            changed = true
        }
        return changed
    }

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
        if feedEncode(line) { return true }
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
    /// For an encode: seconds of output written, the output's length when known, whether that length is a
    /// best guess, and the speed (seconds of output per second of the clock).
    package var mediaDone: Double?
    package var mediaTotal: Double?
    package var mediaRough: Bool?
    package var mediaSpeed: Double?
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
        mediaDone = p.mediaDone
        mediaTotal = p.mediaTotal
        mediaRough = p.mediaTotal == nil ? nil : p.mediaTotalIsRough
        mediaSpeed = p.mediaSpeed
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
