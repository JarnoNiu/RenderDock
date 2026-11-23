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
    }

    package var type: Kind
    package var jobId: String
    package var jobTitle: String
    package var project: String
    /// Set for `shot.done`.
    package var shot: String?
    package var at: String

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
    package mutating func update(_ groups: [RenderGroup], now: Date = Date()) -> [RenderEvent] {
        defer {
            previous = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            primed = true
        }
        guard primed else { return [] }
        let at = ISO8601DateFormatter().string(from: now)
        func event(_ kind: RenderEvent.Kind, _ g: RenderGroup, shot: String? = nil) -> RenderEvent {
            RenderEvent(type: kind, jobId: g.id, jobTitle: g.title, project: g.project, shot: shot, at: at)
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
        for (id, old) in previous where !seen.contains(id) {
            events.append(event(.jobEnded, old))
        }
        return events
    }
}
