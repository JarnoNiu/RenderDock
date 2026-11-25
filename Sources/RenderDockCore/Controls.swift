import Darwin
import Foundation

// Hands on, carefully (0.4). Everything before this file only looks. This is the part that can stop a render
// and let it go on again, and move it out of the way of whatever else the Mac is doing.
//
// The rules it keeps, whatever is asked of it:
//   - Nothing happens unless a switch for it is on. They are all off to begin with, each is its own, and a
//     switch going off undoes what was done under it.
//   - It acts only on processes RenderDock shows as renders, that belong to this user, and that are still the
//     same processes (same number and same start): a number is handed to another process once its owner is gone.
//   - It lets go only of what it stopped itself. A render stopped by hand in a terminal is left alone by the rules.
//   - Whatever it stopped goes on again when RenderDock quits, and everything it does is written to a log.
//
// Stopping is the system's own SIGSTOP and SIGCONT. "Out of the way" is the system's background band
// (setpriority PRIO_DARWIN_BG): the render keeps going on what the Mac has to spare, and can be put back.

/// A process, named by its number and by when it started.
package struct ProcessRef: Codable, Equatable, Hashable {
    package var pid: Int32
    /// Seconds since 1970.
    package var startedAt: Double

    package init(pid: Int32, startedAt: Double) {
        self.pid = pid
        self.startedAt = startedAt
    }
}

package enum ProcessControl {
    package enum Failure: Error, Equatable {
        /// No process has that number any more.
        case gone
        /// The number now belongs to a process that started at another time.
        case notTheSame
        /// It belongs to another user.
        case notOurs
        /// The system said no; its error number.
        case refused(Int32)
    }

    /// The process with this number as it is now, or nil if there is none.
    package static func ref(for pid: Int32) -> ProcessRef? {
        ProcTable.proc(pid).map { ProcessRef(pid: pid, startedAt: $0.start.timeIntervalSince1970) }
    }

    /// Why `ref` may not be acted on, or nil if it may: it has to be there, be the same process, and be ours.
    package static func problem(with ref: ProcessRef) -> Failure? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard ref.pid > 1 else { return .gone }
        guard proc_pidinfo(ref.pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            // Nothing can be read about another user's process. Asking whether a signal could be sent (signal 0
            // sends none) tells "not ours" from "not there".
            errno = 0
            return kill(ref.pid, 0) == -1 && errno == EPERM ? .notOurs : .gone
        }
        let start = Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1e6
        guard abs(start - ref.startedAt) < 1 else { return .notTheSame }
        guard info.pbi_uid == getuid() else { return .notOurs }
        return nil
    }

    /// Stops the process where it is. Nil when done.
    package static func pause(_ ref: ProcessRef) -> Failure? { signal(ref, SIGSTOP) }

    /// Lets a stopped process go on. Nil when done.
    package static func resume(_ ref: ProcessRef) -> Failure? { signal(ref, SIGCONT) }

    /// Moves the process into the system's background band, or back out of it. Nil when done.
    package static func setYielding(_ ref: ProcessRef, _ on: Bool) -> Failure? {
        if let problem = problem(with: ref) { return problem }
        return setpriority(PRIO_DARWIN_PROCESS, id_t(ref.pid), on ? PRIO_DARWIN_BG : 0) == 0 ? nil : .refused(errno)
    }

    package static func isStopped(_ pid: Int32) -> Bool? { ProcTable.proc(pid)?.stopped }

    /// The priority the scheduler has the process at now. In the background band it is 4 or thereabouts.
    package static func schedulingPriority(_ pid: Int32) -> Int? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return Int(info.pti_priority)
    }

    private static func signal(_ ref: ProcessRef, _ number: Int32) -> Failure? {
        if let problem = problem(with: ref) { return problem }
        return kill(ref.pid, number) == 0 ? nil : .refused(errno)
    }
}

// MARK: What may be done, and why something is held

/// The switches. All off unless the user turns them on, one by one.
package struct ControlSettings: Codable, Equatable {
    /// A job may be paused and let go on from the dock.
    package var manual = false
    /// A job may be moved out of the way (and back) from the dock.
    package var yield = false
    /// One job at a time: the others wait, and each goes on when the one before it has ended.
    package var turns = false
    /// Renders stop while the Mac runs from its battery.
    package var pauseOnBattery = false
    /// Renders stop while the system is slowing the Mac down for heat.
    package var pauseWhenHot = false

    package init(manual: Bool = false, yield: Bool = false, turns: Bool = false, pauseOnBattery: Bool = false, pauseWhenHot: Bool = false) {
        self.manual = manual
        self.yield = yield
        self.turns = turns
        self.pauseOnBattery = pauseOnBattery
        self.pauseWhenHot = pauseWhenHot
    }

    package var any: Bool { manual || yield || turns || pauseOnBattery || pauseWhenHot }
    /// A rule that acts by itself is on.
    package var anyAutomatic: Bool { turns || pauseOnBattery || pauseWhenHot }
}

package enum HoldReason: String, Codable, CaseIterable {
    /// The user paused it in the dock.
    case manual
    /// It is waiting for the job before it to end.
    case turns
    /// The Mac runs from its battery.
    case battery
    /// The system is slowing the Mac down for heat.
    case heat

    package var automatic: Bool { self != .manual }
}

/// A job RenderDock is holding: why, and which processes it stopped to do so.
package struct Hold: Codable, Equatable {
    package var reasons: Set<HoldReason>
    package var processes: [ProcessRef]
    package var since: Double

    package init(reasons: Set<HoldReason>, processes: [ProcessRef], since: Double) {
        self.reasons = reasons
        self.processes = processes
        self.since = since
    }
}

/// What the rules need to know about a job.
package struct ControlJob: Equatable {
    package var id: String
    package var title: String
    package var startedAt: Double
    /// Some of its shots are using the machine now.
    package var active: Bool
    /// Its render processes: the ones doing the work, running or stopped.
    package var processes: [ProcessRef]

    package init(id: String, title: String, startedAt: Double, active: Bool, processes: [ProcessRef]) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.active = active
        self.processes = processes
    }

    /// A job as the scanner found it. Only shots with a process of their own count.
    package static func from(_ group: RenderGroup) -> ControlJob {
        let working = group.items.filter { $0.pid != nil && ($0.state.isActive || $0.state == .paused || $0.state == .stalled) }
        return ControlJob(id: group.id, title: group.title, startedAt: group.startedAt.timeIntervalSince1970,
                          active: working.contains { $0.state.isActive || $0.state == .stalled },
                          processes: working.compactMap { $0.pid.flatMap(ProcessControl.ref(for:)) })
    }
}

package enum ControlPlanner {
    /// The reasons each job should be held for by the rules, as things stand. Pure: no process is looked at.
    ///
    /// - `held`: what is held now. A job held by hand stays held by hand, and is out of the taking of turns.
    /// - `freed`: jobs the user let go on by hand. No rule holds them again while they last.
    /// - A job that is neither at work nor held by RenderDock (ended, or stopped by somebody in a terminal) is
    ///   not in it at all: the rules neither stop it nor let it go.
    package static func wanted(jobs: [ControlJob], held: [String: Hold], freed: Set<String>, settings: ControlSettings,
                               onBattery: Bool, hot: Bool) -> [String: Set<HoldReason>] {
        var out: [String: Set<HoldReason>] = [:]
        let inPlay = jobs.filter { ($0.active || held[$0.id] != nil) && !freed.contains($0.id) && !$0.processes.isEmpty }
        for job in inPlay {
            var reasons = Set<HoldReason>()
            if settings.pauseOnBattery && onBattery { reasons.insert(.battery) }
            if settings.pauseWhenHot && hot { reasons.insert(.heat) }
            out[job.id] = reasons
        }
        if settings.turns {
            // Oldest first; a job held by hand is not waited for.
            let queue = inPlay.filter { !(held[$0.id]?.reasons.contains(.manual) ?? false) }
                .sorted { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
            for job in queue.dropFirst() { out[job.id, default: []].insert(.turns) }
        }
        return out
    }
}

// MARK: Doing it, and remembering what was done

/// Holds what RenderDock has stopped or moved out of the way, applies the rules, and undoes its own work.
/// It reaches processes only through `Actuator`, so that all of it can be checked without stopping anything.
package final class ControlEngine {
    package struct Actuator {
        package var pause: (ProcessRef) -> ProcessControl.Failure?
        package var resume: (ProcessRef) -> ProcessControl.Failure?
        package var yield: (ProcessRef, Bool) -> ProcessControl.Failure?

        package init(pause: @escaping (ProcessRef) -> ProcessControl.Failure?, resume: @escaping (ProcessRef) -> ProcessControl.Failure?,
                     yield: @escaping (ProcessRef, Bool) -> ProcessControl.Failure?) {
            self.pause = pause
            self.resume = resume
            self.yield = yield
        }

        /// The real thing.
        package static let system = Actuator(pause: ProcessControl.pause, resume: ProcessControl.resume, yield: ProcessControl.setYielding)
    }

    private struct Saved: Codable {
        var held: [String: Hold] = [:]
        var yielding: [String: [ProcessRef]] = [:]
        var freed: [String] = []
        var titles: [String: String] = [:]
    }

    package private(set) var held: [String: Hold] = [:]
    /// Jobs moved out of the way, with the processes that were moved.
    package private(set) var yielding: [String: [ProcessRef]] = [:]
    private var freed = Set<String>()
    private var titles: [String: String] = [:]
    private var coolSince: Double?
    private var heat = false
    /// With every switch off there is nothing left to remember about what the user let go by hand.
    package var settings: ControlSettings {
        didSet { if !settings.any { freed.removeAll() } }
    }
    private let actuator: Actuator
    private let stateFile: URL?
    private let log: (String) -> Void

    /// How long the Mac has to have been cool again before renders stopped for heat go on.
    package static let coolFor: Double = 60

    /// `stateFile`: where what is held is remembered across a restart (nil: nowhere).
    package init(settings: ControlSettings = ControlSettings(), actuator: Actuator = .system, stateFile: URL? = nil, log: @escaping (String) -> Void = { _ in }) {
        self.settings = settings
        self.actuator = actuator
        self.stateFile = stateFile
        self.log = log
        if let stateFile, let data = try? Data(contentsOf: stateFile), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            held = saved.held
            yielding = saved.yielding
            freed = Set(saved.freed)
            titles = saved.titles
        }
    }

    package var isIdle: Bool { held.isEmpty && yielding.isEmpty }

    /// Why a job is held, most telling first; empty if RenderDock is not holding it.
    package func reasons(for job: String) -> [HoldReason] {
        guard let hold = held[job] else { return [] }
        return [HoldReason.manual, .heat, .battery, .turns].filter(hold.reasons.contains)
    }

    package func isYielding(_ job: String) -> Bool { yielding[job] != nil }

    // MARK: The rules

    /// Call after every scan. Applies the rules that are on, lets go of what a rule no longer wants, and forgets
    /// jobs that are gone. With every switch off and nothing held, it does nothing at all.
    package func tick(jobs: [ControlJob], onBattery: Bool, hot: Bool, now: Date = Date()) {
        let t = now.timeIntervalSince1970
        // Heat goes away slowly: stopped renders cool the Mac, and letting them go at once would only bring it back.
        if hot {
            heat = true
            coolSince = nil
        } else if heat {
            if coolSince == nil { coolSince = t }
            if let since = coolSince, t - since >= Self.coolFor { heat = false }
        }
        guard settings.any || !isIdle else {
            freed.removeAll()
            return
        }
        var changed = false
        let byId = Dictionary(jobs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for job in jobs { titles[job.id] = job.title }

        // What is gone is forgotten: a hold on processes that have all ended holds nothing.
        for (id, hold) in held where hold.processes.allSatisfy({ ProcessControl.problem(with: $0) != nil }) && byId[id]?.processes.isEmpty != false {
            held[id] = nil
            note("forgot \(name(id)): its processes have ended")
            changed = true
        }
        for (id, moved) in yielding where moved.allSatisfy({ ProcessControl.problem(with: $0) != nil }) && byId[id]?.processes.isEmpty != false {
            yielding[id] = nil
            changed = true
        }
        freed = freed.filter { byId[$0] != nil }
        titles = titles.filter { byId[$0.key] != nil || held[$0.key] != nil || yielding[$0.key] != nil }

        // A switch that went off undoes what was done under it.
        if !settings.manual {
            for id in held.keys where held[id]?.reasons.contains(.manual) == true { changed = drop(.manual, from: id, why: "the switch for pausing by hand is off") || changed }
        }
        if !settings.yield {
            for id in Array(yielding.keys) { changed = setYield(id, false, processes: [], why: "the switch for moving out of the way is off") || changed }
        }

        let wanted = ControlPlanner.wanted(jobs: jobs, held: held, freed: freed, settings: settings, onBattery: onBattery, hot: heat)
        for job in jobs {
            let now = held[job.id]?.reasons.filter(\.automatic) ?? []
            let want = wanted[job.id] ?? []
            for reason in HoldReason.allCases where reason.automatic {
                if want.contains(reason) && !now.contains(reason) {
                    changed = add(reason, to: job, at: t) || changed
                } else if !want.contains(reason) && now.contains(reason) {
                    changed = drop(reason, from: job.id, why: Self.over(reason)) || changed
                }
            }
            // A held job that has started another process (its script moved on) has that one stopped too.
            if var hold = held[job.id] {
                let fresh = job.processes.filter { !hold.processes.contains($0) }
                if job.active, !fresh.isEmpty {
                    for process in fresh where actuator.pause(process) == nil { hold.processes.append(process) }
                    held[job.id] = hold
                    changed = true
                }
            }
        }
        // A hold whose job the scanner no longer shows, and that no rule asks for: let go.
        for (id, hold) in held where byId[id] == nil {
            for reason in hold.reasons where reason.automatic { changed = drop(reason, from: id, why: "the job is no longer shown") || changed }
        }
        if changed { save() }
    }

    // MARK: By hand

    /// Pauses a job from the dock. False (and nothing done) unless the switch for it is on.
    @discardableResult
    package func pause(_ job: ControlJob, now: Date = Date()) -> Bool {
        guard settings.manual, !job.processes.isEmpty else { return false }
        titles[job.id] = job.title
        freed.remove(job.id)
        let done = add(.manual, to: job, at: now.timeIntervalSince1970)
        save()
        return done
    }

    /// Lets a job go on from the dock, whoever stopped it and for whatever reason; the rules then leave it be
    /// for as long as it lasts. False (and nothing done) unless the switch for pausing by hand is on.
    @discardableResult
    package func resume(_ job: ControlJob) -> Bool {
        guard settings.manual else { return false }
        titles[job.id] = job.title
        let ours = held[job.id]?.processes ?? []
        var any = false
        for process in Set(ours + job.processes) where actuator.resume(process) == nil { any = true }
        held[job.id] = nil
        freed.insert(job.id)
        note("let \(name(job.id)) go on: by hand")
        save()
        return any
    }

    /// Moves a job out of the way, or back. False (and nothing done) unless the switch for it is on.
    @discardableResult
    package func setYielding(_ job: ControlJob, _ on: Bool) -> Bool {
        guard settings.yield else { return false }
        titles[job.id] = job.title
        let done = setYield(job.id, on, processes: job.processes, why: "by hand")
        save()
        return done
    }

    /// Undoes everything: lets go of all that is held and moves back all that was moved. For when RenderDock quits.
    package func releaseEverything(why: String) {
        for id in Array(held.keys) {
            for process in held[id]?.processes ?? [] { _ = actuator.resume(process) }
            note("let \(name(id)) go on: \(why)")
        }
        held.removeAll()
        for id in Array(yielding.keys) { _ = setYield(id, false, processes: [], why: why) }
        freed.removeAll()
        save()
    }

    // MARK: Pieces

    private static func because(_ reason: HoldReason) -> String {
        switch reason {
        case .manual: return "by hand"
        case .turns: return "waiting for the job before it"
        case .battery: return "the Mac is on its battery"
        case .heat: return "the Mac is being slowed down for heat"
        }
    }

    private static func over(_ reason: HoldReason) -> String {
        switch reason {
        case .manual: return "by hand"
        case .turns: return "the job before it has ended"
        case .battery: return "the Mac is on mains again"
        case .heat: return "the Mac has cooled"
        }
    }

    private func name(_ id: String) -> String { "\"\(titles[id] ?? id)\"" }

    private func note(_ line: String) { log(line) }

    /// Holds `job` for one more reason; stops its processes if it was not held yet.
    private func add(_ reason: HoldReason, to job: ControlJob, at t: Double) -> Bool {
        if var hold = held[job.id] {
            guard !hold.reasons.contains(reason) else { return false }
            hold.reasons.insert(reason)
            held[job.id] = hold
            note("also holding \(name(job.id)): \(Self.because(reason))")
            return true
        }
        var stopped: [ProcessRef] = []
        for process in job.processes {
            if let failure = actuator.pause(process) {
                note("could not pause a process of \(name(job.id)): \(failure)")
            } else {
                stopped.append(process)
            }
        }
        guard !stopped.isEmpty else { return false }
        held[job.id] = Hold(reasons: [reason], processes: stopped, since: t)
        note("paused \(name(job.id)) (\(stopped.count) process\(stopped.count == 1 ? "" : "es")): \(Self.because(reason))")
        return true
    }

    /// Takes one reason away; the job goes on when none is left.
    private func drop(_ reason: HoldReason, from id: String, why: String) -> Bool {
        guard var hold = held[id], hold.reasons.contains(reason) else { return false }
        hold.reasons.remove(reason)
        if hold.reasons.isEmpty {
            for process in hold.processes {
                if let failure = actuator.resume(process), failure != .gone { note("could not let a process of \(name(id)) go on: \(failure)") }
            }
            held[id] = nil
            note("let \(name(id)) go on: \(why)")
        } else {
            held[id] = hold
            note("\(name(id)) is still held (\(hold.reasons.map(\.rawValue).sorted().joined(separator: ", "))): \(why)")
        }
        return true
    }

    private func setYield(_ id: String, _ on: Bool, processes: [ProcessRef], why: String) -> Bool {
        if on {
            guard yielding[id] == nil, !processes.isEmpty else { return false }
            let moved = processes.filter { actuator.yield($0, true) == nil }
            guard !moved.isEmpty else { return false }
            yielding[id] = moved
            note("moved \(name(id)) out of the way: \(why)")
        } else {
            guard let moved = yielding[id] else { return false }
            for process in moved { _ = actuator.yield(process, false) }
            yielding[id] = nil
            note("moved \(name(id)) back: \(why)")
        }
        return true
    }

    private func save() {
        guard let stateFile else { return }
        if isIdle && freed.isEmpty {
            try? FileManager.default.removeItem(at: stateFile)
            return
        }
        let saved = Saved(held: held, yielding: yielding, freed: freed.sorted(), titles: titles.filter { held[$0.key] != nil || yielding[$0.key] != nil })
        try? FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: stateFile, options: .atomic) }
    }
}
