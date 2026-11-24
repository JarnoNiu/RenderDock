// renderdock — the command-line side of RenderDock.
//
//   renderdock run [--name NAME] [--total N] -- <command…>   run a command unchanged and report its progress
//   renderdock status [--json]                               what is rendering on this Mac right now
//   renderdock history [--json] [--limit N]                  the shots that ended most recently
//   renderdock agents [--json]                               what coding agents' sessions are doing right now
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
  renderdock agents [--json]
  renderdock version
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
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")   // env finds the command on PATH, then becomes it: same pid
    process.arguments = command
    process.standardInput = FileHandle.standardInput
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err

    let state = DispatchQueue(label: "renderdock.run")
    var parser = ProgressParser(totalFromCommandLine: total)
    var report: JobReport?
    var lastWrite = 0.0
    var splitters = [LineSplitter(), LineSplitter()]
    let drained = DispatchGroup()

    func absorb(_ data: Data, stream: Int) {
        state.sync {
            var changed = false
            let before = parser.done
            for line in splitters[stream].feed(data) where parser.feed(line) { changed = true }
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

func status(json: Bool) -> Never {
    let scanner = TaskScanner()
    _ = scanner.scan()
    let sampler = MetricsSampler()
    _ = sampler.sample()
    Thread.sleep(forTimeInterval: 1.2)   // CPU and per-process figures need two samples
    var groups = scanner.scan()
    // Reading history only: the app is the one that records.
    let history = HistoryStore(readOnly: true)
    if let history { for i in groups.indices { groups[i].queueETA = history.queueETA(for: groups[i]) } }
    let snapshot = StateSnapshot.make(groups: groups, metrics: sampler.sample(), agents: AgentScanner().scan(),
                                      recent: history?.recent(limit: 4) ?? [])
    if json {
        print(String(decoding: snapshot.json(pretty: true), as: UTF8.self))
        exit(0)
    }
    let s = snapshot.summary
    print("\(s.rendering) rendering · \(s.paused) paused · \(s.stalled) stalled · \(s.queued) queued")
    if !snapshot.agents.isEmpty {
        let a = s.agents
        print("agents: \(a.error) failed · \(a.waiting) waiting · \(a.working) working · \(a.done) just finished · \(a.idle) idle")
    }
    print("overall: \(s.state)  [\(s.line)]")
    for job in snapshot.jobs {
        let shots = job.shotsTotal > 1 ? "  \(job.shotsDone)/\(job.shotsTotal) shots" : ""
        print("● \(job.title)  [\(job.state)]  \(job.project)\(shots)")
        if let eta = job.queueEtaSec { print("    queue done in ~\(eta / 60)m\(job.queueEtaRough == true ? " (rough)" : "")") }
        for shot in job.shots where shot.state != "done" && shot.state != "pending" {
            var line = "    \(shot.name)  \(shot.state)"
            if let d = shot.framesDone {
                line += "  \(d)" + (shot.framesTotal.map { "/\(shot.exact ? "" : "≈")\($0)" } ?? "") + " frames"
            }
            if let f = shot.fraction { line += "  \(shot.exact ? "" : "≈")\(Int(f * 100))%" }
            if let e = shot.etaSec { line += e >= 90 ? "  ~\(e / 60)m left" : "  ~\(e)s left" }
            print(line)
        }
    }
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
        let frames = r.framesDone.map { "\($0) frames" } ?? "-"
        let ended = r.endedAt.map { clock.string(from: Date(timeIntervalSince1970: $0)) } ?? "-"
        let outcome = (r.outcome ?? "-") + (r.outcome == "failed" ? " (\(r.exitCode.map(String.init) ?? "?"))" : "")
        print("\(ended)  \(outcome.padding(toLength: 12, withPad: " ", startingAt: 0))  \(took.padding(toLength: 8, withPad: " ", startingAt: 0))  \(frames.padding(toLength: 12, withPad: " ", startingAt: 0))  \(r.shot)  ·  \(r.jobTitle)")
    }
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

// MARK: entry

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "run": run(Array(arguments.dropFirst()))
case "status": status(json: arguments.contains("--json"))
case "history":
    let limit = arguments.firstIndex(of: "--limit").flatMap { $0 + 1 < arguments.count ? Int(arguments[$0 + 1]) : nil } ?? 20
    history(json: arguments.contains("--json"), limit: max(1, min(limit, 500)))
case "agents": agents(json: arguments.contains("--json"))
case "version", "--version": print("renderdock \(StateSnapshot.appVersion)")
case "help", "--help", "-h", nil: print(usage)
default: fail("unknown command \(arguments[0])\n\(usage)")
}
