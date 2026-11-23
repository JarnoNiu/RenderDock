import Foundation

package enum ItemState: String {
    case rendering, compositing, finishing, encoding, preparing, paused, stalled, pending, done

    /// States that are actively using the machine.
    package var isActive: Bool {
        switch self {
        case .rendering, .compositing, .finishing, .encoding, .preparing: return true
        default: return false
        }
    }

    package var label: String {
        switch self {
        case .rendering: return L("渲染", "Rendering")
        case .compositing: return L("合成", "Compositing")
        case .finishing: return L("收尾", "Finishing")
        case .encoding: return L("编码", "Encoding")
        case .preparing: return L("准备中", "Starting")
        case .paused: return L("已暂停", "Paused")
        case .stalled: return L("可能卡住", "Stalled")
        case .pending: return L("待渲", "Up next")
        case .done: return L("完成", "Done")
        }
    }
}

/// One shot (a Blender process, or one scene:shot entry in a queue script).
package struct RenderItem: Identifiable, Equatable {
    package var id: String
    package var name: String
    package var state: ItemState
    package var framesDone: Int?
    package var framesTotal: Int?
    /// The total frame count is estimated from an older clip's duration; it is not exact.
    package var totalIsEstimate = false
    package var secPerFrame: Double?
    package var lastFrameAt: Date?
    package var outDir: String?
    package var latestFrame: String?
    package var pid: Int32?
    package var cpuCores: Double?
    package var memBytes: UInt64?
    package var startedAt: Date?
    /// Progress inside the current frame, when the job reports it (samples done / samples per frame).
    package var sampleDone: Int?
    package var sampleTotal: Int?
    /// Recent frames whose file is far smaller than usual (possibly empty or black), and recent frames
    /// that took far longer than usual (a hard frame, or the job was paused). Hints, not verdicts.
    package var smallFrames: [Int] = []
    package var slowFrames: [Int] = []

    package init(id: String, name: String, state: ItemState) {
        self.id = id
        self.name = name
        self.state = state
    }

    package var fraction: Double? {
        guard let d = framesDone, let t = framesTotal, t > 0 else { return nil }
        var done = Double(d)
        // Count the part of the current frame that is already sampled, so a long frame still moves the bar.
        if d < t, let sd = sampleDone, let st = sampleTotal, st > 0 { done += min(1, Double(sd) / Double(st)) }
        return min(1, done / Double(t))
    }

    /// Time remaining (seconds). Only available while running, with a known total and a known time per frame.
    package var eta: TimeInterval? {
        guard state == .rendering || state == .compositing,
              let d = framesDone, let t = framesTotal, let s = secPerFrame, t > d else { return nil }
        return Double(t - d) * s
    }
}

package enum GroupState: Int {
    case running = 0, stalled, paused, waiting

    package var label: String {
        switch self {
        case .running: return L("进行中", "Running")
        case .stalled: return L("可能卡住", "Stalled")
        case .paused: return L("已暂停", "Paused")
        case .waiting: return L("排队等待", "Queued")
        }
    }
}

/// One job: the outermost script and the shots under it.
package struct RenderGroup: Identifiable, Equatable {
    package var id: String
    package var title: String
    /// Script file name, e.g. render_all.sh.
    package var script: String?
    package var scriptPath: String?
    /// Full text of the script's first comment line.
    package var note: String?
    /// The project it belongs to (repository directory name).
    package var project: String
    package var cwd: String
    package var startedAt: Date
    /// A caffeinate process in this job is keeping the Mac awake.
    package var keepAwake: Bool
    package var state: GroupState
    package var items: [RenderItem]
    /// For a running queue: time until every shot is through. An estimate, filled in from history.
    package var queueETA: QueueETA?

    package init(id: String, title: String, script: String?, scriptPath: String?, note: String?, project: String, cwd: String,
                 startedAt: Date, keepAwake: Bool, state: GroupState, items: [RenderItem]) {
        self.id = id
        self.title = title
        self.script = script
        self.scriptPath = scriptPath
        self.note = note
        self.project = project
        self.cwd = cwd
        self.startedAt = startedAt
        self.keepAwake = keepAwake
        self.state = state
        self.items = items
    }

    package var doneCount: Int { items.filter { $0.state == .done }.count }
    package var activeItems: [RenderItem] { items.filter { $0.state.isActive } }
}

extension Array where Element == RenderGroup {
    package var allItems: [RenderItem] { flatMap(\.items) }
    package var activeCount: Int { allItems.filter { $0.state.isActive }.count }
    package var pausedCount: Int { allItems.filter { $0.state == .paused }.count }
    package var stalledCount: Int { allItems.filter { $0.state == .stalled }.count }
    package var waitingCount: Int { filter { $0.state == .waiting }.count }

    /// The shot shown on the capsule: prefer active ones that have a percentage.
    package var focusItem: RenderItem? {
        let active = allItems.filter { $0.state.isActive }
        if let best = active.filter({ $0.fraction != nil }).max(by: { ($0.fraction ?? 0) < ($1.fraction ?? 0) }) { return best }
        if let first = active.first(where: { $0.state == .rendering }) ?? active.first { return first }
        return allItems.first { $0.state == .stalled } ?? allItems.first { $0.state == .paused }
    }
}

package enum Fmt {
    package static func bytes(_ b: UInt64, digits: Int = 1) -> String {
        let gb = Double(b) / 1_073_741_824
        if gb >= 100 { return String(format: "%.0f GB", gb) }
        if gb >= 1 { return String(format: "%.\(digits)f GB", gb) }
        return String(format: "%.0f MB", Double(b) / 1_048_576)
    }

    /// "2d 3h", "3h 49m", "12m", "45s" (in the current UI language).
    package static func duration(_ s: TimeInterval) -> String {
        let t = Int(max(0, s))
        if t >= 86_400 { return L("\(t / 86_400) 天 \(t % 86_400 / 3600) 时", "\(t / 86_400)d \(t % 86_400 / 3600)h") }
        if t >= 3600 { return L("\(t / 3600) 时 \(t % 3600 / 60) 分", "\(t / 3600)h \(t % 3600 / 60)m") }
        if t >= 60 { return L("\(t / 60) 分", "\(t / 60)m") }
        return L("\(t) 秒", "\(t)s")
    }

    package static func secPerFrame(_ s: Double) -> String {
        s >= 10 ? String(format: L("%.0f 秒/帧", "%.0f s/frame"), s) : String(format: L("%.1f 秒/帧", "%.1f s/frame"), s)
    }

    package static func percent(_ f: Double) -> String { "\(Int((f * 100).rounded(.down)))%" }

    package static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}
