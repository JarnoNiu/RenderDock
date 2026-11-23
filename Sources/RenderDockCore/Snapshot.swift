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

    package struct Summary: Codable, Equatable {
        package var rendering: Int
        package var paused: Int
        package var stalled: Int
        package var queued: Int
        /// The shot a small display should show: the furthest-along running one, if any.
        package var focus: Focus?
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

    package static let appVersion = "0.2.0"

    package static func make(groups: [RenderGroup], metrics m: Metrics, agents: [AgentSession] = [], now: Date = Date(), host: String? = nil) -> StateSnapshot {
        let iso = ISO8601DateFormatter()
        func shot(_ i: RenderItem) -> Shot {
            Shot(id: i.id, name: i.name, state: i.state.wireName, framesDone: i.framesDone, framesTotal: i.framesTotal,
                 fraction: i.fraction.map(round3), exact: i.framesTotal != nil && !i.totalIsEstimate,
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
                  fraction: i.fraction.map(round3), exact: i.framesTotal != nil && !i.totalIsEstimate,
                  etaSec: i.eta.map { Int($0.rounded()) })
        }
        return StateSnapshot(
            version: 1, app: "RenderDock \(appVersion)", host: host ?? (Host.current().localizedName ?? "Mac"),
            updatedAt: iso.string(from: now),
            summary: Summary(rendering: groups.activeCount, paused: groups.pausedCount, stalled: groups.stalledCount,
                             queued: groups.waitingCount, focus: focus),
            jobs: jobs,
            agents: agents.byUrgency.map { a in
                Agent(id: a.id, tool: a.tool, project: a.project, state: a.state.rawValue, waitingFor: a.waitingFor,
                      sinceSec: a.since.map { max(0, Int(now.timeIntervalSince($0).rounded())) }, source: a.source)
            },
            metrics: Machine(cpu: round3(m.cpu), gpu: m.gpu.map(round3), gpuMemBytes: m.gpuMemBytes, memUsed: m.memUsed,
                             memTotal: m.memTotal, memPressure: m.memPressure, swapUsed: m.swapUsed, swapTotal: m.swapTotal,
                             tempC: m.tempC.map { ($0 * 10).rounded() / 10 }, diskFree: m.diskFree, onAC: m.onAC, awake: m.awakeHeld))
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
