// renderdock — the command-line side of RenderDock.
//
//   renderdock run [--name NAME] [--total N] -- <command…>   run a command unchanged and report its progress
//   renderdock status [--json]                               what is rendering on this Mac right now
//   renderdock history [--json] [--limit N]                  the shots that ended most recently
//   renderdock estimates [--json] [--days N]                 how close the time-left estimates were
//   renderdock agents [--json]                               what coding agents' sessions are doing right now
//   renderdock hook                                          an agent's permission hook: asks the app, prints its answer
//   renderdock hooks status|install|uninstall …              put that hook into a Claude Code settings file, or take it out
//   renderdock notify TEXT [--title T] [--level L]           put a notice on the dock and on a desk device
//   renderdock progress NAME [--percent N] [--done|--failed]  show how far a task of your own has got
//   renderdock ask TEXT --choice A --choice B …              ask the user a question and print the answer they pick
//   renderdock mcp [--from NAME]                             those three and `status` as an MCP server, for an agent's client to start
//   renderdock api [token]                                   where the API is; the token a device on the network has to show
//
// `run` passes the command's input and output straight through and exits with the command's own status.
// It reads the output on the way past, and keeps a small report next to RenderDock's preferences
// (never in your render folder), which is how the app shows an exact percentage and knows whether the
// job finished or failed.
import Foundation
import RenderDockCore

setvbuf(stdout, nil, _IOLBF, 0)

func fail(_ message: String, code: Int32 = 64) -> Never {
    FileHandle.standardError.write(Data("renderdock: \(message)\n".utf8))
    exit(code)
}

let usage = """
usage:
  renderdock run [--name NAME] [--total N] -- <command> [arguments…]
  renderdock status [--json]
  renderdock history [--json] [--limit N]
  renderdock estimates [--json] [--days N]
  renderdock agents [--json]
  renderdock hooks status|install|uninstall (--project DIR | --global) [--yes]
  renderdock notify TEXT [--title TITLE] [--level info|done|error] [--from NAME]
  renderdock progress NAME [--title TITLE] [--percent 0-100] [--eta SECONDS] [--done | --failed] [--from NAME]
  renderdock ask TEXT --choice A --choice B [--choice C] [--choice D] [--timeout SECONDS] [--from NAME] [--json]
  renderdock mcp [--from NAME]
  renderdock api [token]
  renderdock version

notify, progress and ask need "Take Notices, Progress and Questions from Other Programs" switched on in
RenderDock's menu. They exit 0 when it worked (ask: an answer was picked and is printed), 2 when nobody
answered, 3 when RenderDock is not running or the switch is off, 65 when RenderDock refused it.
"""

// MARK: run

/// Splits a byte stream into lines. Carriage returns count as line ends: progress lines are often redrawn with them.
struct LineSplitter {
    private var buffer = Data()

    mutating func feed(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let i = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = buffer[buffer.startIndex..<i]
            if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
            buffer.removeSubrange(buffer.startIndex...i)
        }
        if buffer.count > 65_536 { buffer.removeAll() }   // a "line" this long is not a progress line
        return lines
    }
}

func run(_ arguments: [String]) -> Never {
    var name: String?
    var total: Int?
    var rest = arguments[...]
    while let first = rest.first, first.hasPrefix("--"), first != "--" {
        rest = rest.dropFirst()
        switch first {
        case "--name":
            guard let v = rest.first else { fail("--name needs a value\n\(usage)") }
            name = v
            rest = rest.dropFirst()
        case "--total":
            guard let v = rest.first, let n = Int(v), n > 0 else { fail("--total needs a positive number\n\(usage)") }
            total = n
            rest = rest.dropFirst()
        default:
            fail("unknown option \(first)\n\(usage)")
        }
    }
    if rest.first == "--" { rest = rest.dropFirst() }
    let command = Array(rest)
    guard let executable = command.first else { fail("nothing to run\n\(usage)") }

    // A Blender command line may already say how many frames it will render (and it knows about -j).
    if total == nil, (executable as NSString).lastPathComponent.lowercased() == "blender" {
        let own = Array(command[..<(command.firstIndex(of: "--") ?? command.count)])
        total = TaskScanner.blenderFrames(own)?.count
        // No range on the command line: it is the one stored in the .blend, unless a script may change it first
        // (then Blender's own output says what it is rendering, and that is read as it goes by).
        if total == nil, let fromFile = TaskScanner.blenderFramesFromFile(own, read: { BlendFile.frameRange(at: $0, scene: $1) }), !fromFile.rough {
            total = fromFile.frames.count
        }
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")   // env finds the command on PATH, then becomes it: same pid
    process.arguments = command
    process.standardInput = FileHandle.standardInput
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err

    // An ffmpeg command line may say how long its output will be (`-t`), or that its length cannot be told from the inputs.
    let isFFmpeg = (executable as NSString).lastPathComponent.lowercased() == "ffmpeg"
    let state = DispatchQueue(label: "renderdock.run")
    var parser = ProgressParser(totalFromCommandLine: total, ffmpegArguments: isFFmpeg ? command : nil)
    var report: JobReport?
    var lastWrite = 0.0
    var splitters = [LineSplitter(), LineSplitter()]
    let drained = DispatchGroup()

    func absorb(_ data: Data, stream: Int) {
        state.sync {
            var changed = false
            let before = parser.done
            for line in splitters[stream].feed(data) where parser.feed(line) { changed = true }
            // (An encode's position moves with every status line; it is written at most twice a second, below.)
            guard changed, var r = report else { return }
            let now = Date().timeIntervalSince1970
            r.absorb(parser, now: now)
            report = r
            // A finished frame is written at once; sample ticks at most twice a second.
            if parser.done != before || now - lastWrite >= 0.5 {
                ReportStore.write(r)
                lastWrite = now
            }
        }
    }

    for (index, pair) in [(out, FileHandle.standardOutput), (err, FileHandle.standardError)].enumerated() {
        drained.enter()
        let (pipe, passthrough) = pair
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                drained.leave()
            } else {
                passthrough.write(data)   // the bytes go on untouched, before anything else happens
                absorb(data, stream: index)
            }
        }
    }

    // Signals meant for the job are handed on to it; the wrapper stays to record how it ended.
    var sources: [DispatchSourceSignal] = []
    for sig in [SIGINT, SIGTERM, SIGHUP] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler { if process.isRunning { kill(process.processIdentifier, sig) } }
        source.resume()
        sources.append(source)
    }

    do {
        try process.run()
    } catch {
        fail("could not start \(executable): \(error.localizedDescription)", code: 127)
    }
    let started = Date().timeIntervalSince1970
    state.sync {
        var r = JobReport(pid: process.processIdentifier, startedAt: started, source: "wrapper", name: name)
        r.total = total
        report = r
        ReportStore.write(r)
    }

    process.waitUntilExit()
    // Wait briefly for the last output. Not forever: a background grandchild may still hold the pipe open.
    _ = drained.wait(timeout: .now() + 1.0)

    let code: Int32 = process.terminationReason == .exit ? process.terminationStatus : 128 + process.terminationStatus
    state.sync {
        guard var r = report else { return }
        let now = Date().timeIntervalSince1970
        r.absorb(parser, now: now)
        r.exitCode = code
        r.endedAt = now
        ReportStore.write(r)
    }
    ReportStore.prune()
    _ = sources
    exit(code)
}

// MARK: status

/// What is going on right now, looked at afresh (this takes a little over a second).
func statusSnapshot() -> StateSnapshot {
    let scanner = TaskScanner()
    _ = scanner.scan()
    let sampler = MetricsSampler()
    _ = sampler.sample()
    Thread.sleep(forTimeInterval: 1.2)   // CPU and per-process figures need two samples
    var groups = scanner.scan()
    // Reading history only: the app is the one that records.
    let history = HistoryStore(readOnly: true)
    if let history { for i in groups.indices { groups[i].queueETA = history.queueETA(for: groups[i]) } }
    return StateSnapshot.make(groups: groups, metrics: sampler.sample(), agents: AgentScanner().scan(),
                              recent: history?.recent(limit: 4) ?? [])
}

/// The same as a few lines of text: what `renderdock status` prints, and what the `status` tool answers.
func statusLines(_ snapshot: StateSnapshot) -> [String] {
    var lines: [String] = []
    let s = snapshot.summary
    lines.append("\(s.rendering) rendering · \(s.paused) paused · \(s.stalled) stalled · \(s.queued) queued")
    if !snapshot.agents.isEmpty {
        let a = s.agents
        lines.append("agents: \(a.error) failed · \(a.waiting) waiting · \(a.working) working · \(a.done) just finished · \(a.idle) idle")
    }
    lines.append("overall: \(s.state)  [\(s.line)]")
    for job in snapshot.jobs {
        let shots = job.shotsTotal > 1 ? "  \(job.shotsDone)/\(job.shotsTotal) shots" : ""
        lines.append("● \(job.title)  [\(job.state)]  \(job.project)\(shots)")
        if let eta = job.queueEtaSec { lines.append("    queue done in ~\(eta / 60)m\(job.queueEtaRough == true ? " (rough)" : "")") }
        for shot in job.shots where shot.state != "done" && shot.state != "pending" {
            var line = "    \(shot.name)  \(shot.state)"
            if let d = shot.framesDone {
                line += "  \(d)" + (shot.framesTotal.map { "/\(shot.exact ? "" : "≈")\($0)" } ?? "") + " frames"
            }
            if let f = shot.fraction { line += "  \(shot.exact ? "" : "≈")\(Int(f * 100))%" }
            if let e = shot.etaSec { line += e >= 90 ? "  ~\(e / 60)m left" : "  ~\(e)s left" }
            lines.append(line)
        }
    }
    return lines
}

func status(json: Bool) -> Never {
    let snapshot = statusSnapshot()
    if json {
        print(String(decoding: snapshot.json(pretty: true), as: UTF8.self))
        exit(0)
    }
    statusLines(snapshot).forEach { print($0) }
    exit(0)
}

// MARK: history

func history(json: Bool, limit: Int) -> Never {
    let runs = HistoryStore(readOnly: true)?.recent(limit: limit) ?? []
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: (try? encoder.encode(["runs": runs])) ?? Data("{}".utf8), as: UTF8.self))
        exit(0)
    }
    if runs.isEmpty { print("nothing recorded yet") }
    let clock = DateFormatter()
    clock.dateFormat = "MM-dd HH:mm"
    for r in runs {
        let took = r.duration.map { $0 >= 3600 ? "\(Int($0) / 3600)h \(Int($0) % 3600 / 60)m" : ($0 >= 60 ? "\(Int($0) / 60)m" : "\(Int($0))s") } ?? "-"
        var frames = r.framesDone.map { "\($0) frames" } ?? "-"
        // What the Mac drew meanwhile, where that was recorded (see docs/HISTORY.md for what it does and does not mean).
        if let energy = r.energyWh, energy > 0 { frames += " · " + Fmt.energy(energy) }
        let ended = r.endedAt.map { clock.string(from: Date(timeIntervalSince1970: $0)) } ?? "-"
        let outcome = (r.outcome ?? "-") + (r.outcome == "failed" ? " (\(r.exitCode.map(String.init) ?? "?"))" : "")
        print("\(ended)  \(outcome.padding(toLength: 12, withPad: " ", startingAt: 0))  \(took.padding(toLength: 8, withPad: " ", startingAt: 0))  \(frames.padding(toLength: 12, withPad: " ", startingAt: 0))  \(r.shot)  ·  \(r.jobTitle)")
    }
    exit(0)
}

// MARK: estimates

/// The time-left estimates RenderDock showed, held against what happened. Read-only.
func estimates(json: Bool, days: Double) -> Never {
    let report = HistoryStore(readOnly: true)?.estimateReport(days: days) ?? EstimateReport.nothing
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: (try? encoder.encode(report)) ?? Data("{}".utf8), as: UTF8.self))
        exit(0)
    }
    func span(_ seconds: Double) -> String {
        let s = Int(abs(seconds).rounded())
        return s >= 3600 ? "\(s / 3600)h \(s % 3600 / 60)m" : (s >= 60 ? "\(s / 60)m \(s % 60)s" : "\(s)s")
    }
    let waiting = report.leftOut.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
    guard let from = report.from, let to = report.to, !report.lines.isEmpty else {
        print("no estimate has met its end yet" + (waiting.isEmpty ? "" : " (left out: \(waiting))"))
        print("Estimates are written down from RenderDock 0.3.1 on, once a minute while something renders.")
        exit(0)
    }
    let clock = DateFormatter()
    clock.dateFormat = "MM-dd HH:mm"
    print("time-left estimates held against what happened, \(clock.string(from: Date(timeIntervalSince1970: from))) to \(clock.string(from: Date(timeIntervalSince1970: to)))")
    for kind in ["shot", "queue"] {
        let lines = report.lines.filter { $0.kind == kind }
        guard !lines.isEmpty else { continue }
        print("")
        for line in lines {
            let name = line.horizon == "all" ? "\(kind)s" : "  \(line.horizon) left"
            var lean = "no lean"
            if line.medianBias >= 1 { lean = "said \(span(line.medianBias)) too long" }
            if line.medianBias <= -1 { lean = "said \(span(line.medianBias)) too short" }
            let count = "\(line.estimates) estimate\(line.estimates == 1 ? "" : "s"), \(line.targets) \(kind)\(line.targets == 1 ? "" : "s")"
            let off = "off by \(span(line.medianOff)) (\(Int(line.medianOffPercent.rounded()))%)"
            let close = "\(Int((line.withinFifth * 100).rounded()))% within a fifth"
            let columns: [(String, Int)] = [(name, 22), (count, 28), (off, 26), (lean, 26), (close, 0)]
            print(columns.map { $0.1 > 0 ? $0.0.padding(toLength: $0.1, withPad: " ", startingAt: 0) : $0.0 }.joined())
        }
    }
    print("")
    print("\"off by\" and the lean are the middle value of all estimates in the line.")
    if !waiting.isEmpty { print("left out: \(waiting)") }
    exit(0)
}

// MARK: agents

/// Coding agents' sessions, read-only. `--json` prints what the API's `agents` block carries: no titles, no paths.
func agents(json: Bool) -> Never {
    let sessions = AgentScanner().scan()
    if json {
        let snapshot = StateSnapshot.make(groups: [], metrics: Metrics(), agents: sessions)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: (try? encoder.encode(["agents": snapshot.agents])) ?? Data("{}".utf8), as: UTF8.self))
        exit(0)
    }
    if sessions.isEmpty { print("no agent sessions found") }
    let now = Date()
    func pad(_ s: String, _ n: Int) -> String { s.padding(toLength: n, withPad: " ", startingAt: 0) }
    for s in sessions {
        let since = s.since.map { t -> String in
            let d = Int(max(0, now.timeIntervalSince(t)))
            return d >= 3600 ? "\(d / 3600)h \(d % 3600 / 60)m" : (d >= 60 ? "\(d / 60)m" : "\(d)s")
        } ?? "-"
        let waiting = s.waitingFor.map { "  (\($0))" } ?? ""
        print("\(pad(s.state.rawValue, 8))  \(pad(AgentTool.displayName(s.tool), 12))  \(pad(since, 8))  \(s.project)\(waiting)")
    }
    exit(0)
}

// MARK: hook

/// Run by an agent as its PermissionRequest hook. It asks the app and prints the app's answer. If the app is
/// not running, the feature is off, or nobody answers in time, it prints nothing and the agent asks in its own
/// window as usual. It always exits 0: this hook never gets in an agent's way.
func hook() -> Never {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let request = HookInput.parse(input), request.event == "PermissionRequest" else { exit(0) }
    let paths = ControlPaths.standard
    let wait = TimeInterval(ControlPolicy.load(from: paths.policy).timeoutSec + 5)
    if let output = HookOutput.permissionRequest(ControlClient.ask(hookJSON: input, paths: paths, timeout: wait)) { print(output) }
    exit(0)
}

// MARK: hooks

/// Adds the hook to a Claude Code settings file, or takes it out again. Nothing is written without `--yes`.
/// By default it is one project's local settings; `--global` is the file every session on this Mac reads.
func hooks(_ arguments: [String]) -> Never {
    let verb = arguments.first ?? ""
    let yes = arguments.contains("--yes")
    let file: URL
    if let i = arguments.firstIndex(of: "--project"), i + 1 < arguments.count {
        file = URL(fileURLWithPath: (arguments[i + 1] as NSString).expandingTildeInPath).appendingPathComponent(".claude/settings.local.json")
    } else if arguments.contains("--global") {
        file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    } else {
        fail("say where: --project DIR (one project's local settings) or --global (every session on this Mac)\n\(usage)")
    }
    let fm = FileManager.default
    // The copy of the file as it was, and the mark that RenderDock created it, are kept in RenderDock's own
    // directory: nothing extra is left inside a project.
    let kept = HookSettings.keepsakes(for: file)
    let backup = kept.backup, created = kept.created
    let original = try? Data(contentsOf: file)
    let me = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
    let command = "'\(me)' hook"

    switch verb {
    case "status":
        print(HookSettings.isInstalled(in: original) ? "installed in \(file.path)" : "not installed in \(file.path)")
    case "install":
        guard let updated = HookSettings.adding(command: command, to: original) else { fail("\(file.path) is not a JSON object; nothing was changed") }
        print("file:    \(file.path)\(original == nil ? "  (does not exist yet)" : "")")
        print("adds:    hooks.PermissionRequest → \(command)  (timeout 120 s)")
        if arguments.contains("--global") { print("note:    this file applies to EVERY Claude Code session on this Mac, including ones already open") }
        print("effect:  nothing changes until \"Answer Agents' Requests Here\" is switched on in RenderDock's menu; with it off the hook prints nothing")
        guard yes else {
            print("nothing written. Run it again with --yes to write the file.")
            exit(0)
        }
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.createDirectory(at: kept.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var keptNow = false
        if let original {
            // Kept afresh each time the hook goes into a file that does not have it yet. (Putting it in again
            // over itself keeps the copy from before the first time.)
            if !HookSettings.isInstalled(in: original) || !fm.fileExists(atPath: backup.path) {
                try? fm.removeItem(at: backup)
                keptNow = fm.createFile(atPath: backup.path, contents: original, attributes: [.posixPermissions: 0o600])
                try? fm.removeItem(at: created)
            }
        } else {
            fm.createFile(atPath: created.path, contents: nil, attributes: [.posixPermissions: 0o600])
            try? fm.removeItem(at: backup)
        }
        do { try updated.write(to: file, options: .atomic) } catch { fail("could not write \(file.path): \(error.localizedDescription)", code: 1) }
        print("written." + (keptNow ? " The file as it was is kept at \(backup.path)" : ""))
    case "uninstall":
        guard let original else {
            print("nothing to do: \(file.path) does not exist")
            exit(0)
        }
        guard HookSettings.isInstalled(in: original) else {
            print("nothing to do: the hook is not in \(file.path)")
            exit(0)
        }
        // If the file is still exactly what `install` wrote, put back what was there before, byte for byte.
        let untouched = HookSettings.adding(command: command, to: try? Data(contentsOf: backup)) == original
        if fm.fileExists(atPath: created.path), HookSettings.adding(command: command, to: nil) == original {
            print("removes: \(file.path)  (RenderDock created it, and it holds nothing else)")
            guard yes else { print("nothing written. Run it again with --yes."); exit(0) }
            try? fm.removeItem(at: file)
            try? fm.removeItem(at: created)
        } else if fm.fileExists(atPath: backup.path), untouched, let before = try? Data(contentsOf: backup) {
            print("restores: \(file.path) to exactly what it was before the hook was added")
            guard yes else { print("nothing written. Run it again with --yes."); exit(0) }
            do { try before.write(to: file, options: .atomic) } catch { fail("could not write \(file.path): \(error.localizedDescription)", code: 1) }
            try? fm.removeItem(at: backup)
        } else {
            guard let updated = HookSettings.removing(from: original) else { fail("\(file.path) is not a JSON object; nothing was changed") }
            print("removes: the RenderDock hook from \(file.path). The file was edited since, so it is rewritten (same content, formatting may differ)")
            guard yes else { print("nothing written. Run it again with --yes."); exit(0) }
            do { try updated.write(to: file, options: .atomic) } catch { fail("could not write \(file.path): \(error.localizedDescription)", code: 1) }
            try? fm.removeItem(at: created)
            try? fm.removeItem(at: backup)   // it no longer matches the file, and must not be put back later
        }
        print("done.")
    default:
        fail("hooks needs status, install or uninstall\n\(usage)")
    }
    exit(0)
}

// MARK: notify, progress, ask (the entry for other programs; see docs/AGENT-ENTRY.md)

/// Splits arguments into plain words and `--name value` options. `--` ends the options, so text may start with dashes.
func options(_ arguments: [String], valued: Set<String>, flags: Set<String>) -> (words: [String], values: [(name: String, value: String)], flags: Set<String>) {
    var words: [String] = [], values: [(name: String, value: String)] = [], seen = Set<String>()
    var rest = arguments[...]
    while let first = rest.first {
        rest = rest.dropFirst()
        if first == "--" {
            words += rest
            break
        }
        if valued.contains(first) {
            guard let value = rest.first else { fail("\(first) needs a value\n\(usage)") }
            values.append((first, value))
            rest = rest.dropFirst()
        } else if flags.contains(first) {
            seen.insert(first)
        } else if first.hasPrefix("--") {
            fail("unknown option \(first)\n\(usage)")
        } else {
            words.append(first)
        }
    }
    return (words, values, seen)
}

/// Who is speaking: `--from`, or the RENDERDOCK_FROM environment variable. It is shown as given; nothing checks it.
func sender(_ values: [(name: String, value: String)]) -> String {
    values.last { $0.name == "--from" }?.value ?? ProcessInfo.processInfo.environment["RENDERDOCK_FROM"] ?? ""
}

let notTaking = "RenderDock is not taking this: it is not running, or \"Take Notices, Progress and Questions from Other Programs\" is off in its menu"

func finish(_ sent: InboxClient.Sent) -> Never {
    switch sent {
    case .ok: exit(0)
    case .refused(let reason): fail("refused: \(reason)", code: 65)
    case .unavailable: fail(notTaking, code: 3)
    }
}

func notify(_ arguments: [String]) -> Never {
    let parsed = options(arguments, valued: ["--title", "--level", "--from"], flags: [])
    let body = parsed.words.joined(separator: " ")
    let title = parsed.values.last { $0.name == "--title" }?.value ?? ""
    guard !body.isEmpty || !title.isEmpty else { fail("nothing to say\n\(usage)") }
    var level = InboxLevel.info
    if let text = parsed.values.last(where: { $0.name == "--level" })?.value {
        guard let known = InboxLevel(rawValue: text) else { fail("--level is info, done or error\n\(usage)") }
        level = known
    }
    finish(InboxClient.notify(title: title, body: body, level: level, from: sender(parsed.values)))
}

func progress(_ arguments: [String]) -> Never {
    let parsed = options(arguments, valued: ["--title", "--percent", "--eta", "--from"], flags: ["--done", "--failed"])
    guard parsed.words.count == 1, let name = parsed.words.first else { fail("progress needs one name for the task\n\(usage)") }
    guard !(parsed.flags.contains("--done") && parsed.flags.contains("--failed")) else { fail("--done or --failed, not both\n\(usage)") }
    var percent: Double?
    if let text = parsed.values.last(where: { $0.name == "--percent" })?.value {
        guard let n = Double(text), (0...100).contains(n) else { fail("--percent is a number from 0 to 100\n\(usage)") }
        percent = n
    }
    var eta: Int?
    if let text = parsed.values.last(where: { $0.name == "--eta" })?.value {
        guard let n = Int(text), n >= 0 else { fail("--eta is a number of seconds\n\(usage)") }
        eta = n
    }
    let state = parsed.flags.contains("--done") ? "done" : parsed.flags.contains("--failed") ? "failed" : "working"
    finish(InboxClient.progress(name: name, title: parsed.values.last { $0.name == "--title" }?.value, percent: percent, etaSec: eta,
                                state: state, from: sender(parsed.values)))
}

/// Prints the answer the user picked, and nothing else, so a script can use it as it is.
func ask(_ arguments: [String]) -> Never {
    let parsed = options(arguments, valued: ["--choice", "--timeout", "--from"], flags: ["--json"])
    let text = InboxLimits.oneLine(parsed.words.joined(separator: " "))
    let choices = parsed.values.filter { $0.name == "--choice" }.map { InboxLimits.oneLine($0.value) }
    if let problem = InboxLimits.problem(question: text, choices: choices) { fail("\(problem)\n\(usage)") }
    var timeout = InboxLimits.askTimeoutDefault
    if let value = parsed.values.last(where: { $0.name == "--timeout" })?.value {
        guard let n = Int(value), InboxLimits.askTimeout.contains(n) else {
            fail("--timeout is a number of seconds from \(InboxLimits.askTimeout.lowerBound) to \(InboxLimits.askTimeout.upperBound)\n\(usage)")
        }
        timeout = n
    }
    switch InboxClient.ask(text: text, choices: choices, timeoutSec: timeout, from: sender(parsed.values)) {
    case .chosen(let index, let label):
        if parsed.flags.contains("--json") {
            let data = (try? JSONSerialization.data(withJSONObject: ["index": index, "choice": label], options: [.sortedKeys])) ?? Data("{}".utf8)
            print(String(decoding: data, as: UTF8.self))
        } else {
            print(label)
        }
        exit(0)
    case .none(let reason): fail("no answer (\(reason))", code: 2)
    case .refused(let reason): fail("refused: \(reason)", code: 65)
    case .unavailable: fail(notTaking, code: 3)
    }
}

// MARK: mcp

/// `renderdock mcp [--from NAME]`: the same entry as `notify`, `progress` and `ask`, with `status`, as a Model
/// Context Protocol server on standard input and output. An agent's client starts this and keeps it running;
/// it reads one message a line and answers one a line, and writes nothing else to standard output.
/// Messages are answered one after another: while a question waits for the user, the next message waits too.
func mcp(_ arguments: [String]) -> Never {
    let parsed = options(arguments, valued: ["--from"], flags: [])
    guard parsed.words.isEmpty else { fail("mcp takes no arguments but --from\n\(usage)") }
    var server = MCPServer(backend: MCPServer.Backend(
        notify: { title, body, level, from in InboxClient.notify(title: title, body: body, level: level, from: from) },
        progress: { name, title, percent, eta, state, from in InboxClient.progress(name: name, title: title, percent: percent, etaSec: eta, state: state, from: from) },
        ask: { text, choices, timeout, from in InboxClient.ask(text: text, choices: choices, timeoutSec: timeout, from: from) },
        status: { statusLines(statusSnapshot()).joined(separator: "\n") }), from: sender(parsed.values))
    while let line = readLine(strippingNewline: true) {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
        // Nothing this server is asked comes near a megabyte: a longer line is not read as a message.
        guard line.utf8.count <= 1_048_576 else {
            FileHandle.standardOutput.write(Data("{\"error\":{\"code\":-32600,\"message\":\"invalid request: the line is too long\"},\"id\":null,\"jsonrpc\":\"2.0\"}\n".utf8))
            continue
        }
        if var reply = server.handle(Data(line.utf8)) {
            reply.append(0x0A)
            FileHandle.standardOutput.write(reply)
        }
    }
    exit(0)
}

// MARK: api

/// `renderdock api`: where the API is and whether devices on the network may reach it.
/// `renderdock api token`: the token such a device has to show, and nothing else, for a script to pass on.
func api(_ arguments: [String]) -> Never {
    if arguments.first == "token" {
        // Read, never made here: a token only means something once the app has switched access on with it.
        guard let text = try? String(contentsOf: LocalAPIServer.tokenFile, encoding: .utf8) else {
            fail("no token yet: switch on \"Allow Devices on the Local Network\" in RenderDock's menu first", code: 3)
        }
        print(text.trimmingCharacters(in: .whitespacesAndNewlines))
        exit(0)
    }
    guard arguments.isEmpty else { fail("api takes nothing, or the word token\n\(usage)") }
    guard let data = try? Data(contentsOf: LocalAPIServer.discoveryFile), let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let url = info["url"] as? String, let port = info["port"] as? Int else {
        fail("the API is not running: it is off in RenderDock's menu, or RenderDock is not running", code: 3)
    }
    print("on this Mac: \(url)")
    if info["lan"] as? Bool == true {
        let addresses = LocalAPIServer.networkAddresses()
        if addresses.isEmpty { print("from the network: switched on, but this Mac is not on a network right now") }
        for address in addresses { print("from the network: http://\(address):\(port)  (needs the token: renderdock api token)") }
    } else {
        print("from the network: off")
    }
    exit(0)
}

// MARK: entry

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "run": run(Array(arguments.dropFirst()))
case "status": status(json: arguments.contains("--json"))
case "history":
    let limit = arguments.firstIndex(of: "--limit").flatMap { $0 + 1 < arguments.count ? Int(arguments[$0 + 1]) : nil } ?? 20
    history(json: arguments.contains("--json"), limit: max(1, min(limit, 500)))
case "estimates":
    let days = arguments.firstIndex(of: "--days").flatMap { $0 + 1 < arguments.count ? Double(arguments[$0 + 1]) : nil } ?? 30
    estimates(json: arguments.contains("--json"), days: max(1, min(days, 365)))
case "agents": agents(json: arguments.contains("--json"))
case "hook": hook()
case "hooks": hooks(Array(arguments.dropFirst()))
case "notify": notify(Array(arguments.dropFirst()))
case "progress": progress(Array(arguments.dropFirst()))
case "ask": ask(Array(arguments.dropFirst()))
case "mcp": mcp(Array(arguments.dropFirst()))
case "api": api(Array(arguments.dropFirst()))
case "version", "--version": print("renderdock \(StateSnapshot.appVersion)")
case "help", "--help", "-h", nil: print(usage)
default: fail("unknown command \(arguments[0])\n\(usage)")
}
