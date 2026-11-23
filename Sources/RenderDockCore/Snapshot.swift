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
        package var shots: [Shot]
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
    package var metrics: Machine

    package static let appVersion = "0.2.0-dev"

    package static func make(groups: [RenderGroup], metrics m: Metrics, now: Date = Date(), host: String? = nil) -> StateSnapshot {
        let iso = ISO8601DateFormatter()
        func shot(_ i: RenderItem) -> Shot {
            Shot(id: i.id, name: i.name, state: i.state.wireName, framesDone: i.framesDone, framesTotal: i.framesTotal,
                 fraction: i.fraction.map(round3), exact: i.framesTotal != nil && !i.totalIsEstimate,
                 secPerFrame: i.secPerFrame.map(round3), etaSec: i.eta.map { Int($0.rounded()) }, pid: i.pid,
                 sampleDone: i.sampleDone, sampleTotal: i.sampleTotal)
        }
        let jobs = groups.map { g in
            Job(id: g.id, title: g.title, project: g.project, script: g.script, state: g.state.wireName,
                startedAt: iso.string(from: g.startedAt), keepAwake: g.keepAwake,
                shotsDone: g.doneCount, shotsTotal: g.items.count, shots: g.items.map(shot))
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
