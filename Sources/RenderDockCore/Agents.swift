import Foundation
import SQLite3

// Coding agents' sessions, read without touching the agents' own configuration.
//
// Three sources, all read-only:
//   Claude Code  its own command, `claude agents --json` (run with the network blocked), with its session
//                registry files as the fallback
//   Codex        the session records it writes under ~/.codex/sessions (only event types and times are used)
//   Hermes       its gateway state file and its kanban database
//
// Nothing here reads or keeps what was said in a session. See docs/AGENT-TASKS.md.

// MARK: Model

/// What a session is doing, in the vocabulary every display shares.
/// The cases are in order of how much they need the user: a single light shows the first one present.
package enum AgentState: String, Codable, CaseIterable {
    case error, waiting, working, done, idle, stale

    /// Lower is more urgent.
    package var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    package var label: String {
        switch self {
        case .error: return L("出错", "Error")
        case .waiting: return L("等你", "Needs you")
        case .working: return L("在干活", "Working")
        case .done: return L("刚做完", "Just finished")
        case .idle: return L("空闲", "Idle")
        case .stale: return L("没有新消息", "Gone quiet")
        }
    }
}

package enum AgentTool {
    package static let claudeCode = "claude-code"
    package static let codex = "codex"
    package static let hermes = "hermes"
    package static let all = [claudeCode, codex, hermes]

    package static func displayName(_ tool: String) -> String {
        switch tool {
        case claudeCode: return "Claude Code"
        case codex: return "Codex"
        case hermes: return "Hermes"
        default: return tool
        }
    }
}

/// One session of a coding agent.
package struct AgentSession: Identifiable, Equatable {
    /// "<tool>:<short id>". Stable for as long as the session lives; carries no path.
    package var id: String
    package var tool: String
    /// The project it works in: the repository's directory name, never a path.
    package var project: String
    /// The session's own name. Shown on this Mac only; never sent over the API.
    package var title: String?
    package var state: AgentState
    /// What it is waiting for, in the tool's own words (only while `waiting`).
    package var waitingFor: String?
    /// When it entered this state, as far as that is known.
    package var since: Date?
    package var startedAt: Date?
    package var pid: Int32?
    /// "official": the tool's own command reported it. "files": read from the tool's local files, best effort.
    package var source: String

    package init(id: String, tool: String, project: String, title: String? = nil, state: AgentState, waitingFor: String? = nil,
                 since: Date? = nil, startedAt: Date? = nil, pid: Int32? = nil, source: String) {
        self.id = id
        self.tool = tool
        self.project = project
        self.title = title
        self.state = state
        self.waitingFor = waitingFor
        self.since = since
        self.startedAt = startedAt
        self.pid = pid
        self.source = source
    }
}

extension Array where Element == AgentSession {
    package func count(_ state: AgentState) -> Int { filter { $0.state == state }.count }

    /// Most urgent first; within one state, the most recent change first.
    package var byUrgency: [AgentSession] {
        sorted {
            if $0.state.rank != $1.state.rank { return $0.state.rank < $1.state.rank }
            return ($0.since ?? .distantPast) > ($1.since ?? .distantPast)
        }
    }

    /// The session that most needs attention, if any is doing more than sitting idle.
    package var top: AgentSession? { byUrgency.first { $0.state != .idle && $0.state != .stale } }
}

enum AgentSupport {
    static func alive(_ pid: Int32) -> Bool { pid > 0 && (kill(pid, 0) == 0 || errno == EPERM) }

    /// The repository's directory name for a working directory. Looks through linked git worktrees.
    static func project(_ cwd: String) -> String {
        guard !cwd.isEmpty else { return "" }
        var dir = cwd
        while dir.count > 1 {
            let dotGit = "\(dir)/.git"
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDir) {
                if !isDir.boolValue, let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
                   let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }),
                   let r = line.range(of: "/.git/worktrees/") {
                    let main = line[line.index(line.startIndex, offsetBy: 7)..<r.lowerBound].trimmingCharacters(in: .whitespaces)
                    if !main.isEmpty { return (main as NSString).lastPathComponent }
                }
                return (dir as NSString).lastPathComponent
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return (cwd as NSString).lastPathComponent
    }

    static func shortID(_ id: String) -> String { String(id.replacingOccurrences(of: "-", with: "").prefix(8)) }

    static func date(_ value: Any?) -> Date? {
        if let n = value as? Double { return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n) }   // milliseconds or seconds
        if let s = value as? String { return isoFractional.date(from: s) ?? isoPlain.date(from: s) }
        return nil
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

// MARK: Claude Code

/// Claude Code's sessions, from `claude agents --json`: the command its documentation names for reading
/// session state from another program. It is run inside a sandbox that denies network access, so asking
/// never makes a connection. If the command cannot be run, the session registry files are read instead.
package final class ClaudeCodeSource {
    /// How long a session that has just stopped working is shown as "just finished" before it is plain idle.
    package static let doneWindow: TimeInterval = 300

    private let home: URL
    private let binaryOverride: String?
    private let run: ((String) -> Data?)?
    private var lastSignature: String?
    private var lastFetch = Date.distantPast
    private var cached: [AgentSession] = []
    private var cachedOfficial = true
    /// For tests: what the last scan had to fall back on.
    package private(set) var lastSource = ""

    /// - Parameters:
    ///   - home: Claude Code's directory; `~/.claude`, or `RENDERDOCK_CLAUDE_HOME`.
    ///   - binary: where `claude` is; searched for when nil. `RENDERDOCK_CLAUDE` overrides it.
    ///   - runner: for tests, stands in for running the command.
    package init(home: URL? = nil, binary: String? = nil, runner: ((String) -> Data?)? = nil) {
        let env = ProcessInfo.processInfo.environment
        self.home = home ?? env["RENDERDOCK_CLAUDE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        self.binaryOverride = binary ?? env["RENDERDOCK_CLAUDE"]
        self.run = runner
    }

    private var sessionsDir: URL { home.appendingPathComponent("sessions") }

    package func scan(now: Date = Date()) -> [AgentSession] {
        let files = registryFiles()
        // Nothing registered and no Claude Code directory: the tool is not in use, so do not even look for it.
        guard !files.isEmpty || FileManager.default.fileExists(atPath: sessionsDir.path) else {
            cached = []
            return []
        }
        // The registry is only watched for *change*: its names and modification times. The data comes from the command.
        let signature = files.map { "\($0.lastPathComponent)@\(AgentSupport.modified($0)?.timeIntervalSince1970 ?? 0)" }.joined(separator: "|")
        let busy = cached.contains { $0.state == .working || $0.state == .waiting }
        if signature == lastSignature, now.timeIntervalSince(lastFetch) < (busy ? 20 : 60) {
            return refreshed(cached, now: now)
        }
        lastSignature = signature
        lastFetch = now

        var raws: [Raw]
        if let binary = binary(), let data = (run ?? Self.runSandboxed)(binary), let listed = Self.parse(listing: data) {
            raws = listed
            cachedOfficial = true
        } else {
            raws = files.compactMap { url in (try? Data(contentsOf: url)).flatMap(Self.parse(registry:)) }
                .filter { AgentSupport.alive($0.pid ?? 0) }
            cachedOfficial = false
        }
        lastSource = cachedOfficial ? "official" : "files"

        let mtimes = Dictionary(files.compactMap { url -> (Int32, Date)? in
            guard let pid = Int32(url.deletingPathExtension().lastPathComponent), let m = AgentSupport.modified(url) else { return nil }
            return (pid, m)
        }, uniquingKeysWith: { a, _ in a })

        cached = raws.map { raw in
            // The command does not say when the status last changed. The registry file is rewritten on every
            // change, so its modification time is that moment, near enough.
            let since = raw.statusAt ?? raw.pid.flatMap { mtimes[$0] } ?? raw.startedAt
            return AgentSession(
                id: "\(AgentTool.claudeCode):\(AgentSupport.shortID(raw.sessionId ?? raw.id ?? String(raw.pid ?? 0)))",
                tool: AgentTool.claudeCode, project: AgentSupport.project(raw.cwd ?? ""), title: raw.name,
                state: raw.state, waitingFor: raw.state == .waiting ? raw.waitingFor : nil,
                since: since, startedAt: raw.startedAt, pid: raw.pid, source: cachedOfficial ? "official" : "files")
        }
        return refreshed(cached, now: now)
    }

    /// A session that stopped working a moment ago is "just finished" for a while, then idle.
    private func refreshed(_ sessions: [AgentSession], now: Date) -> [AgentSession] {
        sessions.map { s in
            var s = s
            s.state = Self.settled(s.state, since: s.since, startedAt: s.startedAt, now: now)
            return s
        }
    }

    package static func settled(_ state: AgentState, since: Date?, startedAt: Date?, now: Date) -> AgentState {
        guard state == .idle, let since else { return state }
        // A session that went idle right after starting has not finished anything.
        if let startedAt, since.timeIntervalSince(startedAt) < 10 { return .idle }
        return now.timeIntervalSince(since) < doneWindow ? .done : .idle
    }

    // MARK: parsing

    struct Raw: Equatable {
        var pid: Int32?
        var id: String?
        var sessionId: String?
        var cwd: String?
        var name: String?
        var kind: String?
        var state: AgentState
        var waitingFor: String?
        var startedAt: Date?
        var statusAt: Date?
    }

    /// The output of `claude agents --json`: an array of sessions.
    static func parse(listing data: Data) -> [Raw]? {
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        return array.compactMap(raw)
    }

    /// One registry file, `sessions/<pid>.json`. Same fields, plus the time of the last status change.
    static func parse(registry data: Data) -> Raw? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return raw(object)
    }

    private static func raw(_ o: [String: Any]) -> Raw? {
        let pid = (o["pid"] as? Int).map(Int32.init)
        let sessionId = o["sessionId"] as? String
        guard pid != nil || sessionId != nil || o["id"] != nil else { return nil }
        return Raw(pid: pid, id: o["id"] as? String, sessionId: sessionId, cwd: o["cwd"] as? String, name: o["name"] as? String,
                   kind: o["kind"] as? String,
                   state: state(status: o["status"] as? String, background: o["state"] as? String),
                   waitingFor: o["waitingFor"] as? String,
                   startedAt: AgentSupport.date(o["startedAt"]), statusAt: AgentSupport.date(o["statusUpdatedAt"]))
    }

    /// Interactive sessions carry `status` (busy / idle / waiting). Background sessions also carry `state`
    /// (working / blocked / done / failed / stopped / idle), which says more, so it wins when present.
    package static func state(status: String?, background: String? = nil) -> AgentState {
        switch background {
        case "blocked", "needs_input": return .waiting
        case "failed", "error": return .error
        case "done", "completed": return .done
        case "stopped": return .idle
        default: break
        }
        switch status {
        case "waiting": return .waiting
        case "busy": return .working
        case "idle": return .idle
        default: break
        }
        switch background {
        case "working", "running": return .working
        default: return .idle
        }
    }

    // MARK: running the command

    private func registryFiles() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func binary() -> String? {
        if run != nil { return binaryOverride ?? "claude" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [binaryOverride, "\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                          "\(home)/.claude/local/claude", "\(home)/.npm-global/bin/claude"].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs `claude agents --json` with network access denied and a time limit. Returns its output, or nil.
    static func runSandboxed(_ binary: String) -> Data? {
        let sandbox = "/usr/bin/sandbox-exec"
        guard FileManager.default.isExecutableFile(atPath: sandbox) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sandbox)
        process.arguments = ["-p", "(version 1)(allow default)(deny network*)", binary, "agents", "--json"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let out = Pipe()
        process.standardOutput = out
        do { try process.run() } catch { return nil }

        var data = Data()
        let read = DispatchGroup()
        read.enter()
        DispatchQueue.global(qos: .utility).async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            read.leave()
        }
        if read.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}

// MARK: Codex

/// Codex's sessions, from the records it writes under `~/.codex/sessions`. Best effort: the format is Codex's
/// own and may change. Only two things are taken from a record: where the session runs (its first line), and
/// the type and time of its last task event. A session waiting for approval cannot be told apart from one that
/// is working, so Codex sessions never show as `waiting` here.
package final class CodexSource {
    /// A finished turn is shown for this long.
    package static let doneWindow: TimeInterval = 600
    /// A turn with nothing written for this long is shown as gone quiet rather than working.
    package static let quietAfter: TimeInterval = 900

    private struct Parsed {
        var modified: Date
        var size: Int
        var meta: Meta?
        var last: TaskEvent?
    }

    struct Meta: Equatable {
        var id: String
        var cwd: String
        var subagent: Bool
    }

    struct TaskEvent: Equatable {
        var type: String
        var at: Date?
    }

    private let home: URL
    private let alive: () -> Bool
    private var cache: [String: Parsed] = [:]
    private var known: [URL] = []
    private var lastListing = Date.distantPast
    private var titles: [String: String] = [:]
    private var titlesModified: Date?

    /// - Parameters:
    ///   - home: Codex's directory; `~/.codex`, or `RENDERDOCK_CODEX_HOME`.
    ///   - alive: for tests, stands in for "is a Codex process running".
    package init(home: URL? = nil, alive: (() -> Bool)? = nil) {
        self.home = home ?? ProcessInfo.processInfo.environment["RENDERDOCK_CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        self.alive = alive ?? Self.codexRunning
    }

    package func scan(now: Date = Date()) -> [AgentSession] {
        let root = home.appendingPathComponent("sessions")
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        // Walking the whole tree is the slow part, so it is done at most every 20 s; known files are re-checked every time.
        if now.timeIntervalSince(lastListing) >= 20 {
            lastListing = now
            known = Self.recordFiles(under: root)
        }
        var sessions: [AgentSession] = []
        var running: Bool?
        var seen = Set<String>()
        for url in known {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modified = values.contentModificationDate, now.timeIntervalSince(modified) < 86_400 else { continue }
            let size = values.fileSize ?? 0
            seen.insert(url.path)
            var parsed = cache[url.path]
            if parsed == nil || parsed?.modified != modified || parsed?.size != size {
                let meta = parsed?.meta ?? Self.meta(head: Self.read(url, fromStart: true, bytes: 262_144))
                parsed = Parsed(modified: modified, size: size, meta: meta,
                                last: Self.lastTaskEvent(tail: Self.read(url, fromStart: false, bytes: 524_288)))
                cache[url.path] = parsed
            }
            guard let p = parsed, let meta = p.meta, !meta.subagent, let last = p.last else { continue }

            let state: AgentState
            switch last.type {
            case "task_started":
                if running == nil { running = alive() }
                guard running == true else { continue }   // Codex is not running: the turn is not either
                state = now.timeIntervalSince(modified) < Self.quietAfter ? .working : .stale
            case "task_complete":
                guard now.timeIntervalSince(last.at ?? modified) < Self.doneWindow else { continue }
                state = .done
            default:
                continue   // interrupted, or nothing recognisable
            }
            sessions.append(AgentSession(
                id: "\(AgentTool.codex):\(AgentSupport.shortID(meta.id))", tool: AgentTool.codex,
                project: AgentSupport.project(meta.cwd), title: title(for: meta.id), state: state,
                since: last.at ?? modified, source: "files"))
        }
        cache = cache.filter { seen.contains($0.key) }
        return sessions
    }

    // MARK: parsing

    /// The first line of a record is `session_meta`: the thread id, the working directory, and whether it is a subagent.
    static func meta(head: Data) -> Meta? {
        guard let end = head.firstIndex(of: 0x0A) ?? (head.isEmpty ? nil : head.endIndex),
              let object = (try? JSONSerialization.jsonObject(with: head[head.startIndex..<end])) as? [String: Any],
              object["type"] as? String == "session_meta", let payload = object["payload"] as? [String: Any],
              let id = payload["id"] as? String else { return nil }
        // A user's own thread has a plain string source; a subagent's is an object describing its parent.
        let subagent = !(payload["source"] is String) || (payload["thread_source"] as? String).map { $0 != "user" } == true
        return Meta(id: id, cwd: payload["cwd"] as? String ?? "", subagent: subagent)
    }

    /// The last task event in the end of a record: `task_started`, `task_complete` or `turn_aborted`.
    static func lastTaskEvent(tail: Data) -> TaskEvent? {
        let markers = ["task_started", "task_complete", "turn_aborted"]
        var end = tail.endIndex
        while end > tail.startIndex {
            let start = tail[tail.startIndex..<end].lastIndex(of: 0x0A).map { tail.index(after: $0) } ?? tail.startIndex
            let line = tail[start..<end]
            end = start > tail.startIndex ? tail.index(before: start) : tail.startIndex
            guard !line.isEmpty else { continue }
            // Cheap test first: most lines are tool output and model text, and are never decoded.
            guard markers.contains(where: { line.range(of: Data($0.utf8)) != nil }) else { continue }
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  object["type"] as? String == "event_msg", let payload = object["payload"] as? [String: Any],
                  let type = payload["type"] as? String, markers.contains(type) else { continue }
            return TaskEvent(type: type, at: AgentSupport.date(object["timestamp"]))
        }
        return nil
    }

    private static func read(_ url: URL, fromStart: Bool, bytes: Int) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        if !fromStart, let size = try? handle.seekToEnd(), size > UInt64(bytes) {
            try? handle.seek(toOffset: size - UInt64(bytes))
        } else {
            try? handle.seek(toOffset: 0)
        }
        return (try? handle.read(upToCount: bytes)) ?? Data()
    }

    private static func recordFiles(under root: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                                                          options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") {
            out.append(url)
        }
        return out
    }

    /// Thread names, from `session_index.jsonl`. Shown on this Mac only.
    private func title(for id: String) -> String? {
        let url = home.appendingPathComponent("session_index.jsonl")
        let modified = AgentSupport.modified(url)
        if modified != titlesModified {
            titlesModified = modified
            titles = [:]
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                          let id = o["id"] as? String, let name = o["thread_name"] as? String, !name.isEmpty else { continue }
                    titles[id] = name
                }
            }
        }
        return titles[id]
    }

    static func codexRunning() -> Bool {
        ProcTable.allPids().contains { pid in
            guard let name = ProcTable.proc(pid)?.name.lowercased() else { return false }
            return name == "codex" || name.hasPrefix("codex ") || name.hasPrefix("codex-")
        }
    }
}

// MARK: Hermes

/// Hermes Agent, from its gateway state file and its kanban database. Read-only, best effort.
package final class HermesSource {
    private let home: URL

    package init(home: URL? = nil) {
        self.home = home ?? ProcessInfo.processInfo.environment["RENDERDOCK_HERMES_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes")
    }

    package func scan(now: Date = Date()) -> [AgentSession] {
        var sessions: [AgentSession] = []
        let stateFile = home.appendingPathComponent("gateway_state.json")
        if let data = try? Data(contentsOf: stateFile), let gateway = Self.gateway(data), AgentSupport.alive(gateway.pid) {
            sessions.append(AgentSession(
                id: "\(AgentTool.hermes):gateway", tool: AgentTool.hermes, project: "gateway",
                state: gateway.activeAgents > 0 ? .working : .idle, since: gateway.updatedAt,
                startedAt: gateway.startedAt, pid: gateway.pid, source: "files"))
        }
        for task in Self.runningTasks(database: home.appendingPathComponent("kanban.db")) where AgentSupport.alive(task.pid) {
            sessions.append(AgentSession(
                id: "\(AgentTool.hermes):task-\(task.id)", tool: AgentTool.hermes,
                project: task.workspace.isEmpty ? "kanban" : AgentSupport.project(task.workspace), title: task.title,
                state: .working, since: task.startedAt, startedAt: task.startedAt, pid: task.pid, source: "files"))
        }
        return sessions
    }

    struct Gateway: Equatable {
        var pid: Int32
        var running: Bool
        var activeAgents: Int
        var updatedAt: Date?
        var startedAt: Date?
    }

    /// `gateway_state.json`. Nil unless the gateway says it is running.
    static func gateway(_ data: Data) -> Gateway? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pid = o["pid"] as? Int, o["gateway_state"] as? String == "running" else { return nil }
        return Gateway(pid: Int32(pid), running: true, activeAgents: o["active_agents"] as? Int ?? 0,
                       updatedAt: AgentSupport.date(o["updated_at"]),
                       startedAt: AgentSupport.date(o["start_time"]))
    }

    struct RunningTask: Equatable {
        var id: String
        var title: String?
        var workspace: String
        var pid: Int32
        var startedAt: Date?
    }

    /// Kanban tasks that have a worker process and no completion time. Whether the worker is alive is checked by the caller.
    static func runningTasks(database: URL) -> [RunningTask] {
        guard FileManager.default.fileExists(atPath: database.path) else { return [] }
        var db: OpaquePointer?
        // Read-only. If the write-ahead log cannot be attached read-only, fall back to reading the main file as it is.
        let plain = sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK
        let sql = "SELECT CAST(id AS TEXT), title, workspace_path, worker_pid, started_at FROM tasks WHERE worker_pid IS NOT NULL AND completed_at IS NULL"
        var statement: OpaquePointer?
        if !plain || sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
            sqlite3_close(db)
            db = nil
            let uri = "file:\(database.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? database.path)?immutable=1"
            guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
                  sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                sqlite3_close(db)
                return []
            }
        }
        defer {
            sqlite3_finalize(statement)
            sqlite3_close(db)
        }
        var out: [RunningTask] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ i: Int32) -> String? { sqlite3_column_text(statement, i).map { String(cString: $0) } }
            let started: Date? = sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil
                : (sqlite3_column_type(statement, 4) == SQLITE_TEXT ? AgentSupport.date(text(4)) : AgentSupport.date(sqlite3_column_double(statement, 4)))
            out.append(RunningTask(id: text(0) ?? "", title: text(1), workspace: text(2) ?? "",
                                   pid: Int32(truncatingIfNeeded: sqlite3_column_int64(statement, 3)), startedAt: started))
        }
        return out
    }
}

// MARK: All of them

/// Collects the sessions of every agent that is switched on.
package final class AgentScanner {
    private let claude: ClaudeCodeSource
    private let codex: CodexSource
    private let hermes: HermesSource

    package init(claude: ClaudeCodeSource = ClaudeCodeSource(), codex: CodexSource = CodexSource(), hermes: HermesSource = HermesSource()) {
        self.claude = claude
        self.codex = codex
        self.hermes = hermes
    }

    /// - Parameter tools: which agents to look at. A tool that is not installed costs one directory check.
    package func scan(tools: Set<String> = Set(AgentTool.all), now: Date = Date()) -> [AgentSession] {
        var all: [AgentSession] = []
        if tools.contains(AgentTool.claudeCode) { all += claude.scan(now: now) }
        if tools.contains(AgentTool.codex) { all += codex.scan(now: now) }
        if tools.contains(AgentTool.hermes) { all += hermes.scan(now: now) }
        return all.byUrgency
    }
}
