import Foundation

/// Something that happened between two scans. Sent on the event stream; later the source of notifications.
package struct RenderEvent: Codable, Equatable {
    package enum Kind: String, Codable {
        case jobStarted = "job.started"
        case shotDone = "shot.done"
        case jobStalled = "job.stalled"
        case jobPaused = "job.paused"
        case jobResumed = "job.resumed"
        /// The job's processes are gone. RenderDock cannot tell success from failure from the outside,
        /// so this is deliberately not called "done".
        case jobEnded = "job.ended"
        /// The last job has gone: nothing is rendering or queued any more.
        case allEnded = "all.ended"
        /// A coding agent's session has been waiting for the user for a few seconds.
        case agentWaiting = "agent.waiting"
        /// A session that was working has finished its turn.
        case agentDone = "agent.done"
        case agentError = "agent.error"
        /// Sessions were working or waiting; now none is.
        case agentsIdle = "agents.idle"

        /// Events about coding agents' sessions rather than render jobs.
        package var isAgent: Bool { rawValue.hasPrefix("agent") }
    }

    package var type: Kind
    package var jobId: String
    package var jobTitle: String
    package var project: String
    /// Set for `shot.done`.
    package var shot: String?
    /// Set for `job.ended` when the job was started with `renderdock run`: "finished" (exit status 0) or "failed".
    package var outcome: String?
    package var exitCode: Int32?
    package var at: String
    /// Agent events only. For these, `jobId` is the session's id and `jobTitle` is the tool's name
    /// (never the session's own title), and `project` is the project it works in.
    package var tool: String?
    /// Set for `agent.waiting`: what it waits for, in the tool's own words.
    package var waitingFor: String?
    /// Set for `agent.done` when known: how long the turn ran.
    package var durationSec: Int?

    package init(type: Kind, jobId: String, jobTitle: String, project: String, shot: String? = nil,
                 outcome: String? = nil, exitCode: Int32? = nil, at: String,
                 tool: String? = nil, waitingFor: String? = nil, durationSec: Int? = nil) {
        self.type = type
        self.jobId = jobId
        self.jobTitle = jobTitle
        self.project = project
        self.shot = shot
        self.outcome = outcome
        self.exitCode = exitCode
        self.at = at
        self.tool = tool
        self.waitingFor = waitingFor
        self.durationSec = durationSec
    }

    package func json() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("{}".utf8)
    }
}

/// Compares each scan with the previous one. Pure: no clocks, no I/O, so it can be checked in isolation.
package struct EventDetector {
    private var previous: [String: RenderGroup] = [:]
    private var primed = false

    package init() {}

    /// The first call only records what is already running: jobs that were there before RenderDock
    /// started looking are not announced as "started".
    /// `outcomes`: how jobs that have just disappeared ended, by job id, where that is known.
    package mutating func update(_ groups: [RenderGroup], now: Date = Date(), outcomes: [String: JobOutcome] = [:]) -> [RenderEvent] {
        defer {
            previous = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            primed = true
        }
        guard primed else { return [] }
        let at = ISO8601DateFormatter().string(from: now)
        func event(_ kind: RenderEvent.Kind, _ g: RenderGroup, shot: String? = nil) -> RenderEvent {
            RenderEvent(type: kind, jobId: g.id, jobTitle: g.title, project: g.project, shot: shot, outcome: nil, exitCode: nil, at: at)
        }
        var events: [RenderEvent] = []
        var seen = Set<String>()
        for g in groups {
            seen.insert(g.id)
            guard let old = previous[g.id] else {
                events.append(event(.jobStarted, g))
                continue
            }
            let wasDone = Set(old.items.filter { $0.state == .done }.map(\.id))
            for item in g.items where item.state == .done && !wasDone.contains(item.id) {
                events.append(event(.shotDone, g, shot: item.name))
            }
            if g.state != old.state {
                switch (old.state, g.state) {
                case (_, .stalled): events.append(event(.jobStalled, g))
                case (_, .paused): events.append(event(.jobPaused, g))
                case (.paused, .running), (.stalled, .running): events.append(event(.jobResumed, g))
                default: break
                }
            }
        }
        for (id, old) in previous.sorted(by: { $0.key < $1.key }) where !seen.contains(id) {
            var e = event(.jobEnded, old)
            if let o = outcomes[id] {
                e.outcome = o.finished ? "finished" : "failed"
                e.exitCode = o.exitCode
            }
            events.append(e)
        }
        if groups.isEmpty, !previous.isEmpty {
            events.append(RenderEvent(type: .allEnded, jobId: "", jobTitle: "", project: "", shot: nil, outcome: nil, exitCode: nil, at: at))
        }
        return events
    }
}

/// The same for coding agents' sessions: compares each scan with the previous one.
package struct AgentEventDetector {
    /// A session must have been waiting this long before it is announced: a prompt answered at once is not news.
    package static let waitingDelay: TimeInterval = 8

    private var previous: [String: AgentSession] = [:]
    /// Sessions whose current wait has been announced (or was already going on when RenderDock started looking).
    private var announced = Set<String>()
    private var waitingSince: [String: Date] = [:]
    /// When the turn in progress began, kept while the session works or waits.
    private var turnSince: [String: Date] = [:]
    private var primed = false

    package init() {}

    /// The first call only records what is already going on: nothing that was there before is announced.
    package mutating func update(_ sessions: [AgentSession], now: Date = Date()) -> [RenderEvent] {
        let at = ISO8601DateFormatter().string(from: now)
        func event(_ kind: RenderEvent.Kind, _ s: AgentSession, duration: Int? = nil) -> RenderEvent {
            RenderEvent(type: kind, jobId: s.id, jobTitle: AgentTool.displayName(s.tool), project: s.project, at: at,
                        tool: s.tool, waitingFor: kind == .agentWaiting ? s.waitingFor : nil, durationSec: duration)
        }
        var events: [RenderEvent] = []
        for s in sessions.byUrgency {
            let old = previous[s.id]
            if s.state == .working, turnSince[s.id] == nil { turnSince[s.id] = s.since ?? now }
            switch s.state {
            case .waiting:
                let began = waitingSince[s.id] ?? s.since ?? now
                waitingSince[s.id] = began
                if turnSince[s.id] == nil { turnSince[s.id] = began }
                if !primed {
                    announced.insert(s.id)
                } else if !announced.contains(s.id), now.timeIntervalSince(began) >= Self.waitingDelay {
                    announced.insert(s.id)
                    events.append(event(.agentWaiting, s))
                }
            case .error:
                if primed, old?.state != .error { events.append(event(.agentError, s)) }
            case .done:
                if primed, let old, old.state == .working || old.state == .waiting {
                    let duration = turnSince[s.id].map { Int(max(0, (s.since ?? now).timeIntervalSince($0)).rounded()) }
                    events.append(event(.agentDone, s, duration: duration))
                }
            default:
                break
            }
            if s.state != .waiting {
                announced.remove(s.id)
                waitingSince[s.id] = nil
            }
            if s.state != .working, s.state != .waiting { turnSince[s.id] = nil }
        }
        let ids = Set(sessions.map(\.id))
        announced.formIntersection(ids)
        waitingSince = waitingSince.filter { ids.contains($0.key) }
        turnSince = turnSince.filter { ids.contains($0.key) }

        func busy(_ s: AgentSession) -> Bool { s.state == .working || s.state == .waiting }
        if primed, previous.values.contains(where: busy), !sessions.contains(where: busy) {
            events.append(RenderEvent(type: .agentsIdle, jobId: "", jobTitle: "", project: "", at: at))
        }
        previous = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        primed = true
        return events
    }
}
