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

    package init(type: Kind, jobId: String, jobTitle: String, project: String, shot: String? = nil,
                 outcome: String? = nil, exitCode: Int32? = nil, at: String) {
        self.type = type
        self.jobId = jobId
        self.jobTitle = jobTitle
        self.project = project
        self.shot = shot
        self.outcome = outcome
        self.exitCode = exitCode
        self.at = at
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
