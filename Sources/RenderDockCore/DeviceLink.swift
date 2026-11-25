import Foundation

// A small Bluetooth device on the desk, spoken to from the computer's side.
//
// The wire format is the Hardware Buddy protocol that the Claude desktop apps speak and Anthropic documents
// (github.com/anthropics/claude-desktop-buddy, REFERENCE.md): the Nordic UART Service, one JSON object per
// line. RenderDock takes the desktop app's place, so a device built for that protocol shows RenderDock's
// renders and agents instead. This file is the protocol only, with no Bluetooth in it, so it can be checked
// without a device. See docs/DEVICES.md.

package enum BuddyProtocol {
    package static let service = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
    /// Computer → device (write).
    package static let rx = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
    /// Device → computer (notify).
    package static let tx = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
    /// A device advertises a name that starts with this.
    package static let namePrefix = "Claude"
    /// A snapshot goes out when something changes, and at least this often. A device treats 30 s of silence as a dead link.
    package static let keepalive: TimeInterval = 10

    // MARK: A connection that is refused

    /// CoreBluetooth's "the peer removed pairing information" (`CBErrorDomain` 14): this Mac still holds a pairing
    /// with the device, and the device no longer has its half. That is what a device looks like after its whole
    /// flash was written again or its memory was cleared. macOS does not pair a second time on its own; the user
    /// has to forget the device in System Settings → Bluetooth first.
    package static func pairingGone(domain: String?, code: Int?) -> Bool {
        domain == "CBErrorDomain" && code == 14
    }

    /// How long to wait between tries while the pairing is gone on the device's side. Each try is refused within
    /// a second, so trying often gains nothing; and once the user does forget the device, macOS takes about half
    /// a minute to let go of the pairing, which goes better when it is not being asked to connect all the while.
    package static let retryWhilePairingGone: TimeInterval = 15

    /// What the reference firmware has room for. Longer text is cut by the device, or worse.
    package enum Limit {
        package static let id = 39
        package static let tool = 19
        package static let hint = 43
        package static let msg = 23
        package static let entry = 91
        package static let entries = 8
        /// For a device that takes RenderDock's own fields: it has room for more, and checks the fit itself.
        package static let hintExtended = 120
        package static let name = 39
        package static let rows = 6
        /// A notice is on a device for this long after it arrived; after that it is only on the Mac.
        package static let noteLife: TimeInterval = 60
        /// A task some program reported as finished or failed counts towards the overall state for this long.
        package static let taskEnded: TimeInterval = 60
    }

    // MARK: Computer → device

    package struct Prompt: Equatable {
        package var id: String
        package var tool: String
        package var hint: String

        package init(id: String, tool: String, hint: String) {
            self.id = id
            self.tool = tool
            self.hint = hint
        }
    }

    /// A question some program put through RenderDock's entry (Inbox.swift), offered on the device. Not a
    /// permission request: nothing is allowed by answering it, and the answer is one of `choices`.
    package struct Ask: Equatable {
        package var id: String
        package var from: String
        package var text: String
        package var choices: [String]
        /// Seconds left to answer.
        package var leftSec: Int

        package init(id: String, from: String, text: String, choices: [String], leftSec: Int) {
            self.id = id
            self.from = from
            self.text = text
            self.choices = choices
            self.leftSec = leftSec
        }
    }

    /// A notice some program sent, while it is still new.
    package struct Note: Equatable {
        package var id: String
        package var from: String
        package var title: String
        package var body: String
        /// info | done | error
        package var level: String

        package init(id: String, from: String, title: String, body: String, level: String) {
            self.id = id
            self.from = from
            self.title = title
            self.body = body
            self.level = level
        }
    }

    /// One line of the device's list: a session, a shot being rendered, or a task some program reports on.
    package struct Row: Equatable {
        package var name: String
        /// The agent's name, or whoever reports on the task; empty for a render.
        package var tool: String
        /// error | waiting | working | done
        package var state: String
        package var ageSec: Int?
        package var percent: Int?
    }

    /// One side of what is going on, for a device that keeps the renders and the agents on pages of their own
    /// (`Options.pages`): what is most urgent on that side, and that side's list.
    package struct Side: Equatable {
        /// error | waiting | working | done | idle
        package var state: String
        /// "agent" or "task" on the agents' side; a render says nothing here.
        package var topKind: String?
        package var topName: String?
        package var topTool: String?
        package var topWait: String?
        package var topPercent: Int?
        package var topExact: Bool?
        package var topEtaSec: Int?
        /// Seconds it has been in its state.
        package var topAgeSec: Int?
        package var rows: [Row]
        /// The renders' side only: how many shots are being rendered and how many wait their turn; the job the
        /// top render belongs to, and how long until its whole queue is through.
        package var rendering: Int?
        package var queued: Int?
        package var queueEtaSec: Int?
        package var jobTitle: String?
        package var jobDone: Int?
        package var jobTotal: Int?

        func object() -> [String: Any] {
            var o: [String: Any] = ["state": state]
            if let topName {
                var top: [String: Any] = ["name": topName]
                if let topKind { top["kind"] = topKind }
                if let topTool { top["tool"] = topTool }
                if let topWait { top["wait"] = topWait }
                if let topPercent { top["pct"] = topPercent }
                if let topExact { top["exact"] = topExact }
                if let topEtaSec { top["eta"] = topEtaSec }
                if let topAgeSec { top["age"] = topAgeSec }
                o["top"] = top
            }
            o["rows"] = rows.map { r -> [String: Any] in
                var row: [String: Any] = ["n": r.name, "s": r.state]
                if !r.tool.isEmpty { row["t"] = r.tool }
                if let age = r.ageSec { row["a"] = age }
                if let percent = r.percent { row["p"] = percent }
                return row
            }
            if let rendering, let queued { o["n"] = ["run": rendering, "queue": queued] }
            if let queueEtaSec { o["qeta"] = queueEtaSec }
            if let jobTitle { o["job"] = ["title": jobTitle, "done": jobDone ?? 0, "total": jobTotal ?? 0] }
            return o
        }
    }

    /// What RenderDock adds for a device that has said it understands it. Not part of the published protocol:
    /// it travels under one extra key, "rd", which other devices never see.
    package struct Extended: Equatable {
        /// error | waiting | working | done | idle
        package var state: String
        package var topKind: String?
        package var topName: String?
        package var topTool: String?
        package var topWait: String?
        package var topPercent: Int?
        package var topExact: Bool?
        package var topEtaSec: Int?
        package var jobTitle: String?
        package var jobDone: Int?
        package var jobTotal: Int?
        package var agents: StateSnapshot.AgentCounts
        package var rows: [Row]
        /// Seconds left to answer the request on the device.
        package var promptLeftSec: Int?
        /// Whose request it is: the session's project and the agent's name. The top item above may be about
        /// something else altogether, so a device must not take the asker's name from there.
        package var promptProject: String?
        package var promptAgent: String?
        /// Only for a device that said it understands these two.
        package var ask: Ask?
        package var note: Note?
        /// Only for a device with a page for each side. The fields above stay as they are, the two sides taken
        /// together; these say what each is doing by itself, and carry the lists (`rows` is then left empty).
        package var renders: Side?
        package var sessions: Side?

        func object() -> [String: Any] {
            var o: [String: Any] = ["state": state,
                                    "agents": ["error": agents.error, "waiting": agents.waiting, "working": agents.working, "done": agents.done, "idle": agents.idle]]
            if let topKind, let topName {
                var top: [String: Any] = ["kind": topKind, "name": topName]
                if let topTool { top["tool"] = topTool }
                if let topWait { top["wait"] = topWait }
                if let topPercent { top["pct"] = topPercent }
                if let topExact { top["exact"] = topExact }
                if let topEtaSec { top["eta"] = topEtaSec }
                o["top"] = top
            }
            if let jobTitle { o["job"] = ["title": jobTitle, "done": jobDone ?? 0, "total": jobTotal ?? 0] }
            if !rows.isEmpty {
                o["rows"] = rows.map { r -> [String: Any] in
                    var row: [String: Any] = ["n": r.name, "t": r.tool, "s": r.state]
                    if let age = r.ageSec { row["a"] = age }
                    if let percent = r.percent { row["p"] = percent }
                    return row
                }
            }
            if let promptLeftSec { o["left"] = promptLeftSec }
            if let promptProject { o["by"] = ["n": promptProject, "t": promptAgent ?? ""] }
            if let ask { o["ask"] = ["id": ask.id, "from": ask.from, "text": ask.text, "choices": ask.choices, "left": ask.leftSec] as [String: Any] }
            if let note { o["note"] = ["id": note.id, "from": note.from, "title": note.title, "body": note.body, "level": note.level] }
            if let renders, let sessions {
                o["r"] = renders.object()
                o["a"] = sessions.object()
            }
            return o
        }
    }

    /// One snapshot of everything, in the shape a device expects.
    package struct Heartbeat: Equatable {
        package var total: Int
        package var running: Int
        package var waiting: Int
        package var msg: String
        package var entries: [String]
        /// Present only while a request may be answered on the device.
        package var prompt: Prompt?
        /// Present only for a device that asked for it, on an encrypted link.
        package var extended: Extended?

        /// One line of JSON, newline-terminated.
        package func line() -> Data {
            var object: [String: Any] = ["total": total, "running": running, "waiting": waiting, "msg": msg, "entries": entries,
                                         "tokens": 0, "tokens_today": 0]
            if let prompt { object["prompt"] = ["id": prompt.id, "tool": prompt.tool, "hint": prompt.hint] }
            if let extended { object["rd"] = extended.object() }
            var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
            data.append(0x0A)
            return data
        }
    }

    package struct Options: Equatable {
        /// The link is encrypted (the device bonded). Without it only counts go out: no names, no requests.
        package var secure: Bool
        /// The device can draw text beyond ASCII. The reference firmware cannot, and may misbehave if sent any.
        package var unicode: Bool
        /// The device said it understands RenderDock's own fields (RenderDock's firmware does).
        package var extended: Bool
        /// …and, among them, questions, notices and tasks from other programs (firmware that reports "rd": 2).
        package var inbox: Bool
        /// Whether a request may be answered on the device at all. When not, the device is only told that
        /// something waits on the Mac.
        package var offerRequests: Bool
        /// …and that it keeps the renders and the agents on pages of their own (firmware that reports "rd": 3),
        /// so each side is described by itself.
        package var pages: Bool

        package init(secure: Bool, unicode: Bool = false, extended: Bool = false, inbox: Bool = false, offerRequests: Bool = true, pages: Bool = false) {
            self.secure = secure
            self.unicode = unicode
            self.extended = extended
            self.inbox = inbox
            self.offerRequests = offerRequests
            self.pages = pages
        }
    }

    /// Builds the snapshot for a device from RenderDock's state, the requests waiting for an answer, and what
    /// other programs have put in the inbox.
    package static func heartbeat(state: StateSnapshot, requests: [ControlRequest], inbox: InboxView = .empty, options: Options, now: Date = Date()) -> Heartbeat {
        let s = state.summary
        let prompt = options.secure && options.offerRequests ? requests.lazy.compactMap { self.prompt(for: $0, options: options) }.first : nil
        let working = inbox.tasks.filter { $0.state == "working" }
        var entries: [String] = []
        if options.secure {
            // What cannot be answered on the device is still worth a line: it is waiting somewhere else.
            for r in requests where prompt?.id != r.id {
                entries.append("\(r.action) \(r.project): answer on the Mac")
            }
            // What other programs sent is not put into these lines: its text goes only to a device that has
            // said it understands it (see `extended`). Every device still gets the counts, and one line saying
            // that a question is waiting.
            for a in state.agents where a.state != "idle" && a.state != "stale" {
                var line = "\(AgentTool.displayName(a.tool)) \(a.project): \(a.state)"
                if a.state == "waiting", let what = a.waitingFor, !what.isEmpty { line += " (\(what))" }
                entries.append(line)
            }
            for job in state.jobs {
                for shot in job.shots where shot.state != "done" && shot.state != "pending" {
                    var line = "\(shot.name): \(shot.state)"
                    if let f = shot.fraction { line += " \(shot.exact ? "" : "~")\(Int((f * 100).rounded(.down)))%" }
                    if let eta = shot.etaSec { line += eta >= 90 ? " ~\(eta / 60)m left" : " ~\(eta)s left" }
                    entries.append(line)
                }
            }
        }
        return Heartbeat(
            total: state.agents.count + state.jobs.count + inbox.tasks.count,
            running: s.agents.working + s.rendering + working.count,
            waiting: s.agents.waiting + s.agents.error + s.stalled + inbox.questions.count,
            msg: fit(prompt.map { "approve: \($0.tool)" } ?? (inbox.questions.isEmpty ? s.line : "a question is waiting"), Limit.msg, unicode: false),
            entries: entries.prefix(Limit.entries).map { fit($0, Limit.entry, unicode: options.unicode, bytes: !options.extended) },
            prompt: prompt,
            extended: options.secure && options.extended
                ? extended(state: state, offered: prompt.flatMap { p in requests.first { $0.id == p.id } }, inbox: options.inbox ? inbox : .empty, options: options, now: now)
                : nil)
    }

    /// A question goes to the device only if the device can draw every character of it. Whether it fits the
    /// screen is for the device to say: it shows "answer on the Mac" for one that does not.
    package static func ask(for question: InboxQuestion, options: Options, now: Date = Date()) -> Ask? {
        guard options.secure, options.extended, options.inbox else { return nil }
        let drawable = options.unicode || ([question.from, question.text] + question.choices).allSatisfy { $0.allSatisfy(\.isASCII) }
        guard drawable, InboxLimits.choices.contains(question.choices.count) else { return nil }
        return Ask(id: question.id, from: question.from, text: question.text, choices: question.choices,
                   leftSec: max(0, Int(question.expiresAt.timeIntervalSince(now).rounded())))
    }

    private static func extended(state: StateSnapshot, offered: ControlRequest?, inbox: InboxView, options: Options, now: Date) -> Extended {
        let s = state.summary
        func name(_ text: String) -> String { fit(text, Limit.name, unicode: options.unicode) }
        var e = Extended(state: s.state, agents: s.agents, rows: [])
        if let top = s.top {
            e.topKind = top.kind
            e.topName = name(top.name)
            e.topTool = top.tool.map(AgentTool.displayName)
            e.topWait = top.waitingFor.map { fit($0, Limit.name, unicode: options.unicode) }
            e.topPercent = top.fraction.map { Int(($0 * 100).rounded(.down)) }
            e.topExact = top.exact
            e.topEtaSec = top.etaSec
            if top.kind == "render", let job = state.jobs.first(where: { $0.shots.contains { $0.name == top.name } }) {
                e.jobTitle = name(job.title)
                e.jobDone = job.shotsDone
                e.jobTotal = job.shotsTotal
            }
        }
        // The list: what needs you first, then what is rendering, then what is working, then what just finished.
        func agentRows(_ states: Set<String>) -> [Row] {
            state.agents.filter { states.contains($0.state) }.map {
                Row(name: name($0.project), tool: AgentTool.displayName($0.tool), state: $0.state, ageSec: $0.sinceSec, percent: nil)
            }
        }
        var shots: [Row] = []
        for job in state.jobs {
            for shot in job.shots where shot.state != "done" && shot.state != "pending" && shot.state != "paused" {
                shots.append(Row(name: name(shot.name), tool: "", state: shot.state == "stalled" ? "waiting" : "working", ageSec: nil,
                                 percent: shot.fraction.map { Int(($0 * 100).rounded(.down)) }))
            }
        }
        func taskRows(_ wanted: String) -> [Row] {
            inbox.tasks.filter { $0.state == wanted }.map {
                Row(name: name($0.title), tool: fit($0.from, InboxLimits.from, unicode: options.unicode), state: $0.state,
                    ageSec: max(0, Int(now.timeIntervalSince($0.state == "working" ? $0.startedAt : $0.updatedAt))),
                    percent: $0.fraction.map { Int(($0 * 100).rounded(.down)) })
            }
        }
        e.rows = Array((agentRows(["error", "waiting"]) + taskRows("error") + shots + taskRows("working") + agentRows(["working"])
            + agentRows(["done"]) + taskRows("done")).prefix(Limit.rows))
        if options.pages {
            // Each side by itself. The renders: what the summary says about them, their job and its queue.
            var r = Side(state: s.renderSide?.state ?? "idle", rows: Array(shots.prefix(Limit.rows)))
            r.rendering = s.rendering
            r.queued = s.queued
            if let top = s.renderSide?.top {
                r.topName = name(top.name)
                r.topPercent = top.fraction.map { Int(($0 * 100).rounded(.down)) }
                r.topExact = top.exact
                r.topEtaSec = top.etaSec
                if let job = state.jobs.first(where: { $0.shots.contains { $0.name == top.name } }) {
                    r.jobTitle = name(job.title)
                    r.jobDone = job.shotsDone
                    r.jobTotal = job.shotsTotal
                    r.queueEtaSec = job.queueEtaSec
                }
            }
            // The agents, with the tasks other programs report on.
            var a = Side(state: s.agentSide?.state ?? "idle",
                         rows: Array((agentRows(["error", "waiting"]) + taskRows("error") + taskRows("working") + agentRows(["working"])
                             + agentRows(["done"]) + taskRows("done")).prefix(Limit.rows)))
            if let top = s.agentSide?.top {
                a.topKind = "agent"
                a.topName = name(top.name)
                a.topTool = top.tool.map(AgentTool.displayName)
                a.topWait = top.waitingFor.map { fit($0, Limit.name, unicode: options.unicode) }
                a.topAgeSec = state.agents.first { $0.project == top.name && $0.state == top.state }?.sinceSec
            }
            e.renders = r
            e.sessions = a
            e.rows = []
        }
        if let offered {
            e.promptLeftSec = max(0, Int(offered.expiresAt.timeIntervalSince(now).rounded()))
            e.promptProject = name(offered.project)
            e.promptAgent = AgentTool.displayName(offered.tool)
        }

        // A task from another program becomes the top item only when it says more than what is already there:
        // renders and sessions keep their place at the same level.
        let rank = ["idle": 0, "done": 1, "working": 2, "waiting": 3, "error": 4]
        func recent(_ wanted: String) -> InboxTask? {
            inbox.tasks.first { $0.state == wanted && now.timeIntervalSince($0.updatedAt) <= Limit.taskEnded }
        }
        if let task = recent("error") ?? inbox.tasks.first(where: { $0.state == "working" }) ?? recent("done"),
           (rank[task.state] ?? 0) > (rank[e.state] ?? 0) {
            e.state = task.state
            e.topKind = "task"
            e.topName = name(task.title)
            e.topTool = task.from.isEmpty ? nil : fit(task.from, InboxLimits.from, unicode: options.unicode)
            e.topWait = nil
            e.topPercent = task.fraction.map { Int(($0 * 100).rounded(.down)) }
            e.topExact = task.fraction == nil ? nil : true
            e.topEtaSec = task.state == "working" ? task.etaSec : nil
            e.jobTitle = nil
            e.jobDone = nil
            e.jobTotal = nil
        }
        // The same on the agents' side by itself, where a task has only the sessions to be weighed against.
        if var a = e.sessions, let task = recent("error") ?? inbox.tasks.first(where: { $0.state == "working" }) ?? recent("done"),
           (rank[task.state] ?? 0) > (rank[a.state] ?? 0) {
            a.state = task.state
            a.topKind = "task"
            a.topName = name(task.title)
            a.topTool = task.from.isEmpty ? nil : fit(task.from, InboxLimits.from, unicode: options.unicode)
            a.topWait = nil
            a.topPercent = task.fraction.map { Int(($0 * 100).rounded(.down)) }
            a.topExact = task.fraction == nil ? nil : true
            a.topEtaSec = task.state == "working" ? task.etaSec : nil
            a.topAgeSec = max(0, Int(now.timeIntervalSince(task.state == "working" ? task.startedAt : task.updatedAt)))
            e.sessions = a
        }
        e.ask = inbox.questions.lazy.compactMap { self.ask(for: $0, options: options, now: now) }.first
        if let notice = inbox.notices.first, now.timeIntervalSince(notice.at) <= Limit.noteLife {
            let drawable = options.unicode || [notice.from, notice.title, notice.body].allSatisfy { $0.allSatisfy(\.isASCII) }
            if drawable {
                e.note = Note(id: notice.id, from: notice.from, title: notice.title, body: notice.body, level: notice.level.rawValue)
            }
        }
        return e
    }

    /// The computer about itself, for a device with a page for it. A line of its own, apart from the snapshots:
    /// these numbers change every few seconds, and a snapshot should go out only when something happened.
    /// Percentages and degrees are whole numbers and sizes are in tenths of a gigabyte, so that the line stays
    /// the same (and is not sent again) while nothing that would show has changed.
    package static func mac(_ m: Metrics, cores: Int) -> Data {
        // Written out by hand: the system's JSON writer turns 21.4 into 21.399999999999999, which is longer on a
        // link that is slow, and different from one sample to the next for no reason anyone could see.
        func tenths(_ bytes: UInt64) -> String {
            let value = (Double(bytes) / 1_073_741_824 * 10).rounded()
            return value.truncatingRemainder(dividingBy: 10) == 0 ? String(Int(value / 10)) : String(format: "%.1f", value / 10)
        }
        let thermal: Int
        switch m.thermal {
        case .nominal: thermal = 0
        case .fair: thermal = 1
        case .serious: thermal = 2
        case .critical: thermal = 3
        @unknown default: thermal = 0
        }
        var o: [String: String] = ["cpu": String(Int((min(1, max(0, m.cpu)) * 100).rounded())), "cores": String(cores),
                                   "mem": "[\(tenths(m.memUsed)),\(tenths(m.memTotal))]", "mp": String(m.memPressure), "swap": tenths(m.swapUsed),
                                   "th": String(thermal), "awake": m.awakeHeld ? "true" : "false"]
        if let gpu = m.gpu { o["gpu"] = String(Int((min(1, max(0, gpu)) * 100).rounded())) }
        if let bytes = m.gpuMemBytes { o["vram"] = tenths(bytes) }
        if let degrees = m.tempC { o["t"] = String(Int(degrees.rounded())) }
        if let degrees = m.tempMaxC { o["tmax"] = String(Int(degrees.rounded())) }
        if let free = m.diskFree { o["disk"] = String(Int(Double(free) / 1_073_741_824)) }
        if let onAC = m.onAC { o["ac"] = onAC ? "true" : "false" }
        if let battery = m.battery { o["bat"] = String(battery) }
        let fields = o.keys.sorted().map { "\"\($0)\":\(o[$0]!)" }.joined(separator: ",")
        return Data("{\"mac\":{\(fields)}}\n".utf8)
    }

    /// A request may go to the device only if it may be allowed from a display at all, and if the device can
    /// show all of it: what cannot be seen whole cannot be approved there.
    package static func prompt(for request: ControlRequest, options: Options) -> Prompt? {
        // The reference firmware's limits are sizes in bytes; RenderDock's own firmware has room for the
        // characters, whatever script they are in, and says so itself when something did not fit.
        func size(_ text: String) -> Int { options.extended ? text.count : text.utf8.count }
        guard request.approvable, !request.detail.isEmpty, size(request.id) <= Limit.id, size(request.action) <= Limit.tool,
              size(request.detail) <= (options.extended ? Limit.hintExtended : Limit.hint) else { return nil }
        guard options.unicode || (request.detail.allSatisfy(\.isASCII) && request.action.allSatisfy(\.isASCII)) else { return nil }
        return Prompt(id: request.id, tool: request.action, hint: request.detail)
    }

    /// Cuts text to a device's limit, and to plain ASCII unless the device can draw more. With `bytes`, the
    /// limit is a size in bytes (what the reference firmware's buffers hold), not a number of characters.
    package static func fit(_ text: String, _ limit: Int, unicode: Bool, bytes: Bool = false) -> String {
        var out = ""
        var gap = false
        for ch in text {
            if ch.isNewline || (!unicode && !ch.isASCII) {
                gap = true   // a run of what cannot be shown becomes one "?"
                continue
            }
            if gap {
                out.append("?")
                gap = false
            }
            out.append(ch)
        }
        if gap { out.append("?") }
        if bytes, out.utf8.count > limit {
            // Whole characters, as many as fit with the mark that says something was cut.
            let mark = unicode ? "…" : "~"
            var cut = ""
            for ch in out {
                if cut.utf8.count + String(ch).utf8.count + mark.utf8.count > limit { break }
                cut.append(ch)
            }
            return cut + mark
        }
        return out.count <= limit ? out : String(out.prefix(max(0, limit - 1))) + (unicode ? "…" : "~")
    }

    /// Sent once on connecting: the time, and the offset of the local time zone.
    package static func timeSync(now: Date = Date(), zone: TimeZone = .current) -> Data {
        Data("{\"time\":[\(Int(now.timeIntervalSince1970)),\(zone.secondsFromGMT(for: now))]}\n".utf8)
    }

    /// Asks the device how it is: its name, whether the link is encrypted, its battery.
    package static let statusRequest = Data("{\"cmd\":\"status\"}\n".utf8)

    /// Bytes cut to what one Bluetooth write can carry. The device puts the line back together.
    package static func chunks(_ data: Data, size: Int) -> [Data] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: data.count, by: size).map { data.subdata(in: $0..<Swift.min($0 + size, data.count)) }
    }

    // MARK: Device → computer

    package struct DeviceStatus: Equatable {
        package var name: String?
        /// The device says the link is encrypted.
        package var secure: Bool
        package var batteryPercent: Int?
        package var onUSB: Bool?
        /// The device understands RenderDock's own fields.
        package var extended: Bool
        /// The device says it can draw text beyond ASCII.
        package var unicode: Bool
        /// The device understands questions, notices and tasks from other programs.
        package var inbox: Bool
        /// The device keeps renders and agents on pages of their own and has one for the computer itself.
        package var pages: Bool

        package init(name: String?, secure: Bool, batteryPercent: Int?, onUSB: Bool?, extended: Bool = false, unicode: Bool = false, inbox: Bool = false,
                     pages: Bool = false) {
            self.name = name
            self.secure = secure
            self.batteryPercent = batteryPercent
            self.onUSB = onUSB
            self.extended = extended
            self.unicode = unicode
            self.inbox = inbox
            self.pages = pages
        }
    }

    package enum Incoming: Equatable {
        /// The user answered the request with this id on the device.
        case permission(id: String, decision: ControlDecision)
        /// The user picked one of a question's answers on the device, counted from 0.
        case choice(id: String, index: Int)
        case status(DeviceStatus)
        case ack(String, ok: Bool)
        case unknown
    }

    package static func parse(_ line: Data) -> Incoming {
        guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return .unknown }
        if o["cmd"] as? String == "permission", let id = o["id"] as? String, !id.isEmpty {
            switch o["decision"] as? String {
            case "once": return .permission(id: id, decision: .allow)
            case "deny": return .permission(id: id, decision: .deny)
            default: return .unknown   // anything else is not an answer
            }
        }
        if o["cmd"] as? String == "choice" {
            // A whole number in range, and nothing else: not "1", not 1.5, not true.
            guard let id = o["id"] as? String, !id.isEmpty, let number = o["index"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let index = Int(exactly: number.doubleValue), InboxLimits.choices.upperBound > index, index >= 0 else { return .unknown }
            return .choice(id: id, index: index)
        }
        if let ack = o["ack"] as? String {
            let ok = o["ok"] as? Bool ?? false
            if ack == "status", ok, let data = o["data"] as? [String: Any] {
                let battery = data["bat"] as? [String: Any]
                return .status(DeviceStatus(name: data["name"] as? String, secure: data["sec"] as? Bool ?? false,
                                            batteryPercent: battery?["pct"] as? Int, onUSB: battery?["usb"] as? Bool,
                                            extended: (data["rd"] as? Int ?? 0) >= 1, unicode: data["utf8"] as? Bool ?? false,
                                            inbox: (data["rd"] as? Int ?? 0) >= 2, pages: (data["rd"] as? Int ?? 0) >= 3))
            }
            return .ack(ack, ok: ok)
        }
        return .unknown
    }

    /// Puts notifications back together into lines. A "line" that grows past the limit is thrown away.
    package struct LineAssembler {
        private var buffer = Data()
        private let limit: Int

        package init(limit: Int = 8192) { self.limit = limit }

        package mutating func feed(_ data: Data) -> [Data] {
            buffer.append(data)
            var lines: [Data] = []
            while let end = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<end]
                if !line.isEmpty { lines.append(Data(line)) }
                buffer.removeSubrange(buffer.startIndex...end)
            }
            if buffer.count > limit { buffer.removeAll() }
            return lines
        }
    }
}
