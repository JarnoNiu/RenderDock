import Foundation

/// The state every display reads: the panel today, the local API, and whatever hardware comes later.
/// This is the wire format of `GET /v1/state` (see docs/API.md). Field names are a contract: add, never rename.
/// It deliberately carries no file-system paths.
package struct StateSnapshot: Codable, Equatable {
    package struct Focus: Codable, Equatable {
        package var name: String
        package var state: String
        package var framesDone: Int?
        package var framesTotal: Int?
        /// 0…1, present only when the total is known (exactly or as an estimate).
        package var fraction: Double?
        /// True when `framesTotal` is exact; false when it is an estimate or unknown.
        package var exact: Bool
        package var etaSec: Int?
    }

    /// How many agent sessions are in each state.
    package struct AgentCounts: Codable, Equatable {
        package var error: Int
        package var waiting: Int
        package var working: Int
        package var done: Int
        package var idle: Int
        package var stale: Int
    }

    /// The one thing a small display should show.
    package struct Top: Codable, Equatable {
        /// agent | render
        package var kind: String
        /// An agent session's project, or a shot's name.
        package var name: String
        /// error | waiting | working | done, in the vocabulary agents and renders share.
        package var state: String
        package var tool: String?
        package var waitingFor: String?
        package var fraction: Double?
        package var exact: Bool?
        package var etaSec: Int?
    }

    /// One side of what is going on, by itself: the renders, or the coding agents. For a display that keeps the
    /// two on pages of their own.
    package struct SideSummary: Codable, Equatable {
        /// error | waiting | working | done | idle
        package var state: String
        /// What that word is about. Absent when idle.
        package var top: Top?
    }

    package struct Summary: Codable, Equatable {
        package var rendering: Int
        package var paused: Int
        package var stalled: Int
        package var queued: Int
        /// The shot a small display should show: the furthest-along running one, if any.
        package var focus: Focus?
        package var agents: AgentCounts
        /// Renders and agents together, as one word: error | waiting | working | done | idle. What a single light shows.
        package var state: String
        /// What that word is about. Absent when idle.
        package var top: Top?
        /// One line of plain ASCII, at most 23 characters, for the smallest displays: "1 waiting | render 62%".
        package var line: String
        /// The renders alone, and the agents alone: `state` and `top` above are the two taken together, and say
        /// nothing about the side that is less urgent. (From 0.4.)
        package var renderSide: SideSummary?
        package var agentSide: SideSummary?
    }

    package struct Shot: Codable, Equatable {
        package var id: String
        package var name: String
        /// rendering | compositing | finishing | encoding | starting | paused | stalled | pending | done
        package var state: String
        package var framesDone: Int?
        package var framesTotal: Int?
        package var fraction: Double?
        package var exact: Bool
        package var secPerFrame: Double?
        package var etaSec: Int?
        package var pid: Int32?
        /// Samples done / samples per frame of the frame in progress, when the job reports it.
        package var sampleDone: Int?
        package var sampleTotal: Int?
        /// Recent frames with an unusually small file, and recent frames that took unusually long. Hints only; absent when there are none.
        package var smallFrames: [Int]?
        package var slowFrames: [Int]?
    }

    package struct Job: Codable, Equatable {
        package var id: String
        package var title: String
        package var project: String
        package var script: String?
        /// running | stalled | paused | queued
        package var state: String
        package var startedAt: String
        package var keepAwake: Bool
        package var shotsDone: Int
        package var shotsTotal: Int
        /// For a running queue: seconds until every shot is through. Always an estimate.
        package var queueEtaSec: Int?
        /// True when some shots have never run before and were given the queue's average.
        package var queueEtaRough: Bool?
        package var shots: [Shot]
    }

    /// One session of a coding agent. No title and no path: only what a display outside this Mac may show.
    package struct Agent: Codable, Equatable {
        package var id: String
        /// claude-code | codex | hermes
        package var tool: String
        package var project: String
        /// error | waiting | working | done | idle | stale
        package var state: String
        /// What it is waiting for, in the tool's own words. Present only while waiting.
        package var waitingFor: String?
        /// Seconds since it entered this state, when that is known.
        package var sinceSec: Int?
        /// official: the tool's own command reported it. files: read from the tool's local files, best effort.
        package var source: String
    }

    package struct Machine: Codable, Equatable {
        package var cpu: Double
        package var gpu: Double?
        package var gpuMemBytes: UInt64?
        package var memUsed: UInt64
        package var memTotal: UInt64
        /// 1 normal, 2 warning, 4 critical (the system's own memory-pressure level).
        package var memPressure: Int
        package var swapUsed: UInt64
        package var swapTotal: UInt64
        package var tempC: Double?
        package var diskFree: UInt64?
        package var onAC: Bool?
        /// Something is holding a sleep assertion: the Mac will not idle-sleep.
        package var awake: Bool
    }

    package var version: Int
    package var app: String
    package var host: String
    package var updatedAt: String
    package var summary: Summary
    package var jobs: [Job]
    /// Coding agents' sessions, most urgent first. Empty when none are found or the feature is off.
    package var agents: [Agent]
    package var metrics: Machine

    package static let appVersion = "0.3.1-dev"

    /// - Parameter recent: the shots that ended most recently. One that ended in the last few minutes still counts
    ///   towards the overall state: a light stays green for a while after a render finishes.
    package static func make(groups: [RenderGroup], metrics m: Metrics, agents: [AgentSession] = [], recent: [HistoryRun] = [],
                             now: Date = Date(), host: String? = nil) -> StateSnapshot {
        let iso = ISO8601DateFormatter()
        func shot(_ i: RenderItem) -> Shot {
            Shot(id: i.id, name: i.name, state: i.state.wireName, framesDone: i.framesDone, framesTotal: i.framesTotal,
                 fraction: i.fraction.map(round3), exact: (i.framesTotal != nil || i.mediaTotal != nil) && !i.totalIsEstimate,
                 secPerFrame: i.secPerFrame.map(round3), etaSec: i.eta.map { Int($0.rounded()) }, pid: i.pid,
                 sampleDone: i.sampleDone, sampleTotal: i.sampleTotal,
                 smallFrames: i.smallFrames.isEmpty ? nil : i.smallFrames, slowFrames: i.slowFrames.isEmpty ? nil : i.slowFrames)
        }
        let jobs = groups.map { g in
            Job(id: g.id, title: g.title, project: g.project, script: g.script, state: g.state.wireName,
                startedAt: iso.string(from: g.startedAt), keepAwake: g.keepAwake,
                shotsDone: g.doneCount, shotsTotal: g.items.count,
                queueEtaSec: g.queueETA.map { Int($0.seconds.rounded()) }, queueEtaRough: g.queueETA.map { $0.guessed > 0 },
                shots: g.items.map(shot))
        }
        let focus = groups.focusItem.map { i in
            Focus(name: i.name, state: i.state.wireName, framesDone: i.framesDone, framesTotal: i.framesTotal,
                  fraction: i.fraction.map(round3), exact: (i.framesTotal != nil || i.mediaTotal != nil) && !i.totalIsEstimate,
                  etaSec: i.eta.map { Int($0.rounded()) })
        }
        return StateSnapshot(
            version: 1, app: "RenderDock \(appVersion)", host: host ?? (Host.current().localizedName ?? "Mac"),
            updatedAt: iso.string(from: now),
            summary: summary(groups: groups, agents: agents, recent: recent, focus: focus, now: now),
            jobs: jobs,
            agents: agents.byUrgency.map { a in
                Agent(id: a.id, tool: a.tool, project: a.project, state: a.state.rawValue, waitingFor: a.waitingFor,
                      sinceSec: a.since.map { max(0, Int(now.timeIntervalSince($0).rounded())) }, source: a.source)
            },
            metrics: Machine(cpu: round3(m.cpu), gpu: m.gpu.map(round3), gpuMemBytes: m.gpuMemBytes, memUsed: m.memUsed,
                             memTotal: m.memTotal, memPressure: m.memPressure, swapUsed: m.swapUsed, swapTotal: m.swapTotal,
                             tempC: m.tempC.map { ($0 * 10).rounded() / 10 }, diskFree: m.diskFree, onAC: m.onAC, awake: m.awakeHeld))
    }

    /// How long a finished or failed render keeps counting towards the overall state.
    package static let recentWindow: TimeInterval = 300
    /// The longest `summary.line`.
    package static let lineLimit = 23

    private static func summary(groups: [RenderGroup], agents: [AgentSession], recent: [HistoryRun], focus: Focus?, now: Date) -> Summary {
        let fresh = recent.filter { run in run.endedAt.map { now.timeIntervalSince1970 - $0 < recentWindow && now.timeIntervalSince1970 >= $0 } ?? false }
        let failedRun = fresh.first { $0.outcome == "failed" }
        // Only an exit status of 0 is a finish. A job that merely vanished is not claimed as done.
        let finishedRun = groups.isEmpty ? fresh.first { $0.outcome == "finished" } : nil
        let stalledItem = groups.allItems.first { $0.state == .stalled }
        let urgent = agents.byUrgency
        func agentTop(_ state: AgentState) -> Top? {
            urgent.first { $0.state == state }.map {
                Top(kind: "agent", name: $0.project, state: state.rawValue, tool: $0.tool, waitingFor: state == .waiting ? $0.waitingFor : nil)
            }
        }
        func renderTop(_ name: String, _ state: AgentState) -> Top { Top(kind: "render", name: name, state: state.rawValue) }

        let state: AgentState
        let top: Top?
        if agents.count(.error) > 0 || failedRun != nil {
            state = .error
            top = agentTop(.error) ?? failedRun.map { renderTop($0.shot, .error) }
        } else if agents.count(.waiting) > 0 || stalledItem != nil {
            state = .waiting
            top = agentTop(.waiting) ?? stalledItem.map { renderTop($0.name, .waiting) }
        } else if groups.activeCount > 0 || agents.count(.working) > 0 {
            state = .working
            // A render has a percentage, which says more on a small screen than "working".
            if groups.activeCount > 0, let f = focus {
                top = Top(kind: "render", name: f.name, state: AgentState.working.rawValue, fraction: f.fraction, exact: f.exact, etaSec: f.etaSec)
            } else {
                top = agentTop(.working)
            }
        } else if agents.count(.done) > 0 || finishedRun != nil {
            state = .done
            top = agentTop(.done) ?? finishedRun.map { renderTop($0.shot, .done) }
        } else {
            state = .idle
            top = nil
        }

        // Each side by itself, in the same order of urgency.
        let renderSide: SideSummary
        if let failedRun {
            renderSide = SideSummary(state: AgentState.error.rawValue, top: renderTop(failedRun.shot, .error))
        } else if let stalledItem {
            renderSide = SideSummary(state: AgentState.waiting.rawValue, top: renderTop(stalledItem.name, .waiting))
        } else if groups.activeCount > 0 {
            renderSide = SideSummary(state: AgentState.working.rawValue, top: focus.map {
                Top(kind: "render", name: $0.name, state: AgentState.working.rawValue, fraction: $0.fraction, exact: $0.exact, etaSec: $0.etaSec)
            })
        } else if let finishedRun {
            renderSide = SideSummary(state: AgentState.done.rawValue, top: renderTop(finishedRun.shot, .done))
        } else {
            renderSide = SideSummary(state: AgentState.idle.rawValue, top: nil)
        }
        let agentsAre: AgentState = agents.count(.error) > 0 ? .error : (agents.count(.waiting) > 0 ? .waiting
            : (agents.count(.working) > 0 ? .working : (agents.count(.done) > 0 ? .done : .idle)))
        let agentSide = SideSummary(state: agentsAre.rawValue, top: agentsAre == .idle ? nil : agentTop(agentsAre))

        // The line: most urgent first, as many parts as fit.
        var parts: [String] = []
        let failed = agents.count(.error) + (failedRun == nil ? 0 : 1)
        if failed > 0 { parts.append("\(failed) failed") }
        let waiting = agents.count(.waiting) + groups.stalledCount
        if waiting > 0 { parts.append("\(waiting) waiting") }
        if groups.activeCount > 0 {
            if let f = focus, let fraction = f.fraction {
                parts.append("render \(f.exact ? "" : "~")\(Int((fraction * 100).rounded(.down)))%")
            } else {
                parts.append("\(groups.activeCount) rendering")
            }
        }
        if agents.count(.working) > 0 { parts.append("\(agents.count(.working)) working") }
        let done = agents.count(.done) + (finishedRun == nil ? 0 : 1)
        if done > 0 { parts.append("\(done) done") }
        var line = ""
        for part in parts {
            let next = line.isEmpty ? part : line + " | " + part
            if next.count > lineLimit { break }
            line = next
        }
        if line.isEmpty { line = "idle" }

        return Summary(rendering: groups.activeCount, paused: groups.pausedCount, stalled: groups.stalledCount,
                       queued: groups.waitingCount, focus: focus,
                       agents: AgentCounts(error: agents.count(.error), waiting: agents.count(.waiting), working: agents.count(.working),
                                           done: agents.count(.done), idle: agents.count(.idle), stale: agents.count(.stale)),
                       state: state.rawValue, top: top, line: line, renderSide: renderSide, agentSide: agentSide)
    }

    /// Compact single-line JSON (safe to send as one server-sent-event line).
    package func json(pretty: Bool = false) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("{}".utf8)
    }

    private static func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
}

extension ItemState {
    /// Stable English name used on the wire, independent of the UI language.
    package var wireName: String { self == .preparing ? "starting" : rawValue }
}

extension GroupState {
    package var wireName: String {
        switch self {
        case .running: return "running"
        case .stalled: return "stalled"
        case .paused: return "paused"
        case .waiting: return "queued"
        }
    }
}
