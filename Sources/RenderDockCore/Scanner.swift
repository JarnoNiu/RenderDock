import AVFoundation
import Foundation

/// Recognises render jobs from the process tree and the output directories. Read-only throughout: sends no signals and writes no files.
package final class TaskScanner {
    package init() {}

    /// `reported`: a job that is not a Blender render but tells us about itself (it was started with `renderdock run`).
    /// `comfy`: a ComfyUI server with something in its queue.
    private enum LeafKind { case blender, adapter, ffmpeg, reported, comfy }

    private struct Leaf {
        let proc: Proc
        let kind: LeafKind
        /// For `.adapter`: which rule matched.
        var rule: Int? = nil
    }

    private struct Stream {
        let proc: Proc
        /// The rule that reads this script's queue, and the items it lists.
        let rule: QueueRule
        let specs: [QueueRule.Item]
    }

    private struct FrameStats {
        var done = 0
        var latest: String?
        var lastAt: Date?
        var secPerFrame: Double?
        var smallFrames: [Int] = []
        var slowFrames: [Int] = []
    }

    private var cpuPrev: [Int32: (ns: UInt64, at: Date)] = [:]
    private var scriptCache: [String: (mtime: Date, note: String?)] = [:]
    private var frameCache: [String: (at: Date, stats: FrameStats)] = [:]
    private var mp4Cache: [String: (mtime: Date, seconds: Double?, fps: Double?)] = [:]
    private var anchorsCache: [String: (mtime: Date, frames: Int?)] = [:]
    /// Extra detection rules from adapters.json, reloaded when the file changes.
    private var rules = AdapterRules()
    private var rulesStamp: Date?
    private let logs = LogFollower()
    private let comfy = ComfyTracker()
    /// What each ComfyUI server's queue holds, as of this scan. Keyed by the server's pid.
    private var comfyViews: [Int32: ComfyTracker.View] = [:]
    /// Reports written by wrapped jobs, by pid, as of this scan.
    private var reports: [Int32: JobReport] = [:]
    private var previousGroups: [RenderGroup] = []
    /// How the jobs that disappeared in the latest scan ended, for those that reported it. Keyed by group id.
    package private(set) var lastEnded: [String: JobOutcome] = [:]

    private static let shells: Set<String> = ["zsh", "bash", "sh", "dash", "fish"]
    private static let imageExts: Set<String> = ["png", "jpg", "jpeg", "exr", "tif", "tiff", "webp", "bmp", "tga"]
    private static let scriptExts: Set<String> = ["sh", "zsh", "bash", "py", "js", "mjs", "cjs", "ts"]

    // MARK: Scanning

    package func scan(now: Date = Date()) -> [RenderGroup] {
        let snap = ProcSnapshot()

        // 1. Leaves: the processes doing the actual work
        var blenderLeaves: [Leaf] = []
        loadRules()
        var adapterCandidates: [(proc: Proc, rule: Int)] = []
        let adapterProcesses = Set(rules.adapters.map { $0.process.lowercased() })
        var ffmpegCandidates: [Proc] = []
        var comfyServers: [(proc: Proc, port: Int)] = []
        for p in snap.table.values {
            let lower = p.name.lowercased()
            if adapterProcesses.contains(lower) {
                let a = snap.args(p.pid)
                if let i = rules.adapters.firstIndex(where: { $0.matches(process: p.name, args: a) }) { adapterCandidates.append((p, i)) }
            }
            if lower == "blender" {
                let a = snap.args(p.pid)
                if a.contains("-b") || a.contains("--background") { blenderLeaves.append(Leaf(proc: p, kind: .blender)) }
            } else if lower == "ffmpeg" {
                if now.timeIntervalSince(p.start) >= 3 { ffmpegCandidates.append(p) }
            } else if rules.comfyui != false, lower.hasPrefix("python"),
                      let port = ComfyUI.port(processName: p.name, arguments: snap.args(p.pid), cwd: snap.cwd(p.pid)) {
                comfyServers.append((p, port))
            }
        }
        // A ComfyUI server counts as a job only while its queue has something in it.
        comfyViews = [:]
        for (p, port) in comfyServers {
            if let view = comfy.view(pid: p.pid, port: port, now: now) { comfyViews[p.pid] = view }
        }
        comfy.forget(except: Set(comfyServers.map(\.proc.pid)))
        let blenderPids = Set(blenderLeaves.map(\.proc.pid))
        var leaves = blenderLeaves
        var adapterPids = Set<Int32>()
        for (p, i) in adapterCandidates where !blenderPids.contains(p.pid) {
            if let below = rules.adapters[i].notAbove?.lowercased(),
               snap.descendants(of: p.pid).contains(where: { snap.table[$0]?.name.lowercased() == below }) { continue }
            leaves.append(Leaf(proc: p, kind: .adapter, rule: i))
            adapterPids.insert(p.pid)
        }
        for f in ffmpegCandidates where !adapterPids.contains(f.pid) && !hasAncestor(f, in: adapterPids, snap) {
            leaves.append(Leaf(proc: f, kind: .ffmpeg))
        }
        for (p, _) in comfyServers where comfyViews[p.pid] != nil && !adapterPids.contains(p.pid) {
            leaves.append(Leaf(proc: p, kind: .comfy))
        }

        // Jobs that report on themselves. Each report is matched by pid and start time, so a recycled pid is not mistaken for it.
        reports = Dictionary(ReportStore.all().map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let known = Set(leaves.map(\.proc.pid))
        for (pid, r) in reports where r.exitCode == nil && !known.contains(pid) {
            guard let p = snap.table[pid], report(for: p) != nil else { continue }
            leaves.append(Leaf(proc: p, kind: .reported))
        }

        // 2. From each leaf, walk up to the outermost script; that is the job group
        var leavesByRoot: [Int32: [Leaf]] = [:]
        for leaf in leaves {
            leavesByRoot[root(of: leaf.proc, snap).pid, default: []].append(leaf)
        }
        // Scripts wrapped in caffeinate that currently have no render process: queued
        var covered = Set<Int32>()
        for r in leavesByRoot.keys {
            covered.insert(r)
            covered.formUnion(snap.descendants(of: r))
        }
        for p in snap.table.values.sorted(by: { $0.pid < $1.pid }) where !covered.contains(p.pid) && isScriptHost(p, snap) {
            let kids = snap.children[p.pid] ?? []
            guard kids.contains(where: { snap.table[$0]?.name == "caffeinate" }) else { continue }
            let r = root(of: p, snap)
            guard !covered.contains(r.pid) else { continue }
            leavesByRoot[r.pid] = []
            covered.insert(r.pid)
            covered.formUnion(snap.descendants(of: r.pid))
        }

        // 3. Assemble
        var groups: [RenderGroup] = []
        for (rootPid, rootLeaves) in leavesByRoot {
            guard let rootProc = snap.table[rootPid] else { continue }
            groups.append(buildGroup(root: rootProc, leaves: rootLeaves, snap: snap, now: now))
        }
        cpuPrev = cpuPrev.filter { snap.table[$0.key] != nil }
        logs.forget(except: Set(snap.table.keys))
        let sorted = groups.sorted {
            $0.state.rawValue != $1.state.rawValue ? $0.state.rawValue < $1.state.rawValue : $0.startedAt < $1.startedAt
        }
        lastEnded = outcomes(ofGroupsMissingFrom: sorted)
        previousGroups = sorted
        return sorted
    }

    /// For jobs that were there last scan and are gone now: their exit status, where a wrapper recorded one.
    /// The wrapper writes it a moment after its child exits, so a report that is still open gets a short grace period.
    private func outcomes(ofGroupsMissingFrom current: [RenderGroup]) -> [String: JobOutcome] {
        let alive = Set(current.map(\.id))
        var result: [String: JobOutcome] = [:]
        for group in previousGroups where !alive.contains(group.id) {
            let pids = group.items.compactMap(\.pid).filter { reports[$0] != nil }
            guard !pids.isEmpty else { continue }
            var codes: [Int32] = []
            for attempt in 0..<8 {
                codes = pids.compactMap { ReportStore.read(pid: $0)?.exitCode }
                if codes.count == pids.count { break }
                if attempt < 7 { Thread.sleep(forTimeInterval: 0.2) }
            }
            if !codes.isEmpty { result[group.id] = JobOutcome(exitCode: codes.first { $0 != 0 } ?? 0) }
        }
        return result
    }

    // MARK: Job groups

    private func buildGroup(root: Proc, leaves: [Leaf], snap: ProcSnapshot, now: Date) -> RenderGroup {
        let rootArgs = snap.args(root.pid)
        let rootCwd = snap.cwd(root.pid)
        let desc = snap.descendants(of: root.pid)
        let groupId = "g\(root.pid)-\(Int(root.start.timeIntervalSince1970))"

        // Script path and title
        var scriptPath: String?
        if let rel = scriptArg(rootArgs, name: root.name) {
            let bases = [snap.table[root.ppid].map { snap.cwd($0.pid) } ?? "", rootCwd]
            scriptPath = bases.map { resolve(rel, $0) }.first { FileManager.default.fileExists(atPath: $0) }
        }
        let note = scriptPath.flatMap(scriptNote)

        // The queued shots: what each script's command line lists, read by the first queue rule that finds any
        // (the rules in adapters.json, then the standard `scene:shot`).
        var streamProcs: [String: [Proc]] = [:]
        var streamSpecs: [String: (rule: QueueRule, items: [QueueRule.Item])] = [:]
        let queueRules = rules.queueRules
        for pid in [root.pid] + desc {
            guard let p = snap.table[pid], Self.shells.contains(p.name.lowercased()) else { continue }
            let arguments = Array(snap.args(pid).dropFirst())
            for (index, rule) in queueRules.enumerated() {
                let listed = rule.items(in: arguments)
                guard !listed.isEmpty else { continue }
                let key = "\(index) " + listed.map(\.key).joined(separator: " ")
                streamProcs[key, default: []].append(p)
                streamSpecs[key] = (rule, listed)
                break
            }
        }
        // A subshell in a pipeline has exactly the same command line as the main shell: keep only the main one (the one whose parent does not have that same command line)
        var streams: [Stream] = []
        for (key, procs) in streamProcs {
            let pids = Set(procs.map(\.pid))
            let main = procs.first { !pids.contains($0.ppid) } ?? procs[0]
            guard let found = streamSpecs[key] else { continue }
            streams.append(Stream(proc: main, rule: found.rule, specs: found.items))
        }
        streams.sort { $0.proc.pid < $1.proc.pid }

        var items: [RenderItem] = []
        var used = Set<Int32>()
        for stream in streams {
            let sdesc = snap.descendants(of: stream.proc.pid)
            let sdescSet = Set(sdesc)
            let scwd = snap.cwd(stream.proc.pid)
            var built: [RenderItem] = []
            var current: Int?
            for (i, spec) in stream.specs.enumerated() {
                let key = spec.key
                var item = RenderItem(id: "\(groupId)/\(stream.proc.pid)/\(key)", name: stream.rule.title(for: spec), state: .pending)
                if let leaf = leaves.first(where: { sdescSet.contains($0.proc.pid) && !used.contains($0.proc.pid) && stream.rule.matches(arguments: snap.args($0.proc.pid), spec) }) {
                    used.insert(leaf.proc.pid)
                    fill(&item, leaf: leaf, snap: snap, now: now)
                    if current == nil { current = i }
                } else if current == nil, sdesc.contains(where: { stream.rule.follows(arguments: snap.args($0), spec) }) {
                    // This shot's post-processing (re-pasting, flicker check, etc.) is running
                    item.state = .finishing
                    current = i
                }
                built.append(item)
            }
            if let c = current {
                for i in built.indices where i < c { built[i].state = .done }
            } else {
                // Between two shots, or the whole stream is paused: check whether each clip file was written after this stream started
                var firstOpen: Int?
                for i in built.indices {
                    let spec = stream.specs[i]
                    let doneFile = stream.rule.doneFile.flatMap {
                        AdapterRules.expand($0, args: [], cwd: scwd, extra: spec.fields)
                    }
                    if let doneFile, let m = mtime(doneFile), m >= stream.proc.start {
                        built[i].state = .done
                    } else if firstOpen == nil {
                        firstOpen = i
                    }
                }
                if let f = firstOpen { built[f].state = stream.proc.stopped ? .paused : .preparing }
            }
            items.append(contentsOf: built)
        }
        // Leaves that are in no list each count as a shot of their own
        for leaf in leaves.sorted(by: { $0.proc.pid < $1.proc.pid }) where !used.contains(leaf.proc.pid) {
            if leaf.kind == .comfy, let view = comfyViews[leaf.proc.pid] {
                // A ComfyUI server: each prompt in its queue is a shot. The ones that have left the queue are
                // done, the one running is tied to the server's process, the rest are up next.
                func name(_ prompt: ComfyUI.Prompt) -> String { L("第 \(prompt.number) 个", "prompt \(prompt.number)") }
                func id(_ prompt: ComfyUI.Prompt) -> String { "\(groupId)/c\(prompt.id)" }
                for prompt in view.done { items.append(RenderItem(id: id(prompt), name: name(prompt), state: .done)) }
                for prompt in view.running {
                    var item = RenderItem(id: id(prompt), name: name(prompt), state: .rendering)
                    fill(&item, leaf: leaf, snap: snap, now: now)
                    items.append(item)
                }
                for prompt in view.pending { items.append(RenderItem(id: id(prompt), name: name(prompt), state: .pending)) }
                continue
            }
            var item = RenderItem(id: "\(groupId)/p\(leaf.proc.pid)", name: leafName(leaf, snap), state: .preparing)
            fill(&item, leaf: leaf, snap: snap, now: now)
            items.append(item)
        }

        let state: GroupState
        if items.contains(where: { $0.state.isActive }) {
            state = .running
        } else if items.contains(where: { $0.state == .stalled }) {
            state = .stalled
        } else if items.contains(where: { $0.state == .paused }) || root.stopped {
            state = .paused
        } else {
            state = .waiting
        }

        let scriptName = scriptPath.map { ($0 as NSString).lastPathComponent }
        var title = note.map(Self.shortTitle) ?? scriptName ?? items.first?.name ?? root.name
        if leaves.count == 1, leaves[0].kind == .comfy { title = "ComfyUI" }
        // A single job that was given a name (`renderdock run --name …`) is called that.
        if items.count == 1, let leaf = leaves.first, let given = report(for: leaf.proc)?.name { title = given }
        let keepAwake = ([root.pid] + desc).contains { snap.table[$0]?.name == "caffeinate" }
        let home = leaves.first.map { snap.cwd($0.proc.pid) } ?? rootCwd
        return RenderGroup(
            id: groupId, title: title, script: scriptName, scriptPath: scriptPath, note: note,
            project: projectName(home.isEmpty ? rootCwd : home), cwd: home.isEmpty ? rootCwd : home,
            startedAt: root.start, keepAwake: keepAwake, state: state, items: items
        )
    }

    // MARK: Progress of one shot

    private func fill(_ item: inout RenderItem, leaf: Leaf, snap: ProcSnapshot, now: Date) {
        let p = leaf.proc
        let a = snap.args(p.pid)
        let cwd = snap.cwd(p.pid)
        item.pid = p.pid
        item.startedAt = p.start
        if let u = ProcTable.usage(p.pid) {
            item.memBytes = u.footprint
            if let prev = cpuPrev[p.pid], now.timeIntervalSince(prev.at) > 0.5, u.cpuNs >= prev.ns {
                item.cpuCores = Double(u.cpuNs - prev.ns) / 1e9 / now.timeIntervalSince(prev.at)
            }
            cpuPrev[p.pid] = (u.cpuNs, now)
        }

        switch leaf.kind {
        case .blender:
            let plan = blenderPlan(a, cwd: cwd)
            let rep = report(for: p)
            var hasProgressFile = false
            if let out = plan.outDir ?? rep?.outDir, isDirectory(out) {
                item.outDir = out
                let st = frameStats(out, since: p.start, now: now, only: plan.rough ? nil : plan.frames)
                item.framesDone = st.done
                item.latestFrame = st.latest
                item.lastFrameAt = st.lastAt
                item.secPerFrame = st.secPerFrame
                item.smallFrames = st.smallFrames
                item.slowFrames = st.slowFrames
                if let exact = progressFile(out) {
                    hasProgressFile = true
                    item.framesDone = exact.done
                    item.framesTotal = exact.total
                } else if let frames = plan.frames, !frames.isEmpty {
                    // The frame range is on the command line (-s/-e/-a or -f), or in the .blend it names: the
                    // total is exact, unless a script on the command line may change it first.
                    item.framesTotal = frames.count
                    item.totalIsEstimate = plan.rough
                } else if let est = estimatedTotal(out: out, args: a, procStart: p.start), est >= st.done {
                    item.framesTotal = est
                    item.totalIsEstimate = true
                }
            }
            if let rep {
                // Started with `renderdock run`: the job's own count is exact, whatever the command line says.
                apply(rep, to: &item)
            } else if !hasProgressFile, let log = logs.progress(pid: p.pid, totalFromCommandLine: plan.rough ? nil : plan.frames?.count) {
                // Its output goes to a log file: read Blender's own frame lines from there.
                item.framesDone = log.done
                if let total = log.total {
                    item.framesTotal = total
                    item.totalIsEstimate = false
                }
                item.sampleDone = log.sampleDone
                item.sampleTotal = log.sampleTotal
                if item.outDir == nil, let dir = log.outDir, isDirectory(dir) {
                    let st = frameStats(dir, since: p.start, now: now)
                    item.outDir = dir
                    item.latestFrame = st.latest
                    item.lastFrameAt = st.lastAt
                    item.secPerFrame = st.secPerFrame
                    item.smallFrames = st.smallFrames
                    item.slowFrames = st.slowFrames
                }
            }
            if p.stopped {
                item.state = .paused
            } else if (item.framesDone ?? 0) == 0 {
                item.state = .preparing
            } else if let last = item.lastFrameAt, now.timeIntervalSince(last) > max(300, 10 * (item.secPerFrame ?? 30)) {
                item.state = .stalled
            } else {
                item.state = .rendering
            }

        case .adapter:
            guard let index = leaf.rule, rules.adapters.indices.contains(index) else { break }
            let rule = rules.adapters[index]
            item.state = p.stopped ? .paused : rule.itemState
            if let template = rule.frames, let dir = AdapterRules.expand(template, args: a, cwd: cwd), isDirectory(dir) {
                let st = frameStats(dir, since: p.start, now: now)
                // A step that empties its folder when it starts: until the folder is newer than the process, nothing in it is ours.
                let fresh = rule.freshDir == true ? (mtime(dir) ?? .distantPast) >= p.start : true
                item.outDir = dir
                item.framesDone = fresh ? st.done : 0
                item.latestFrame = fresh ? st.latest : nil
                item.lastFrameAt = fresh ? st.lastAt : nil
                item.secPerFrame = fresh ? st.secPerFrame : nil
            }
            if let total = adapterTotal(rule, args: a, cwd: cwd) {
                item.framesTotal = total
                if let done = item.framesDone { item.framesDone = min(done, total) }
            }

        case .reported:
            if let rep = report(for: p) {
                apply(rep, to: &item)
                if let out = rep.outDir, isDirectory(out) {
                    item.outDir = out
                    item.latestFrame = frameStats(out, since: p.start, now: now).latest
                }
            }
            item.state = p.stopped ? .paused : .rendering

        case .comfy:
            // The prompt that is running. ComfyUI does not say how far along it is to anyone but the tab that queued it.
            item.state = p.stopped ? .paused : .rendering

        case .ffmpeg:
            item.state = p.stopped ? .paused : .encoding
            if let last = a.last, !last.hasPrefix("-") { item.outDir = (resolve(last, cwd) as NSString).deletingLastPathComponent }
            // An encode says how far along it is in its own output. That is read from the wrapper's report when
            // it was started with `renderdock run`, or from the file its standard error is redirected to.
            if let rep = report(for: p) {
                apply(rep, to: &item)
            } else if let log = logs.progress(pid: p.pid, totalFromCommandLine: nil, fd: 2, ffmpegArguments: a) {
                item.mediaDone = log.mediaDone
                item.mediaTotal = log.mediaTotal
                item.mediaSpeed = log.mediaSpeed
                item.totalIsEstimate = log.mediaTotal != nil && log.mediaTotalIsRough
            }
        }
    }

    private func loadRules() {
        let stamp = mtime(AdapterRules.file.path)
        guard stamp != rulesStamp else { return }
        rulesStamp = stamp
        rules = stamp == nil ? AdapterRules() : AdapterRules.load()
    }

    private func adapterTotal(_ rule: LeafAdapter, args: [String], cwd: String) -> Int? {
        guard let source = rule.total else { return nil }
        if let arg = source.arg, let n = Self.argValue(args, [arg]).flatMap({ Int($0) }), n > 0 { return n }
        if let template = source.jsonFile, let key = source.countOf,
           let path = AdapterRules.expand(template, args: args, cwd: cwd) {
            return jsonCount(path, key: key)
        }
        return nil
    }

    private func report(for p: Proc) -> JobReport? {
        guard let r = reports[p.pid], abs(p.start.timeIntervalSince1970 - r.startedAt) < 10 else { return nil }
        return r
    }

    private func apply(_ rep: JobReport, to item: inout RenderItem) {
        item.framesDone = rep.done
        if let total = rep.total {
            item.framesTotal = total
            item.totalIsEstimate = false
        }
        item.sampleDone = rep.sampleDone
        item.sampleTotal = rep.sampleTotal
        if rep.mediaDone != nil {
            // An encode: its progress is in seconds of output, and it has no frames to speak of.
            item.framesDone = nil
            item.mediaDone = rep.mediaDone
            item.mediaTotal = rep.mediaTotal
            item.mediaSpeed = rep.mediaSpeed
            item.totalIsEstimate = rep.mediaTotal != nil && rep.mediaRough == true
        }
        if item.secPerFrame == nil { item.secPerFrame = rep.secPerFrame }
        if item.lastFrameAt == nil, let last = rep.recent.last { item.lastFrameAt = Date(timeIntervalSince1970: last) }
    }

    /// Frames in the output directory, deduplicated by frame number (one frame may have several images: beauty, shadow, …).
    private func frameStats(_ dir: String, since: Date, now: Date, only: Set<Int>? = nil) -> FrameStats {
        let cacheKey = only == nil ? dir : "\(dir)|\(only!.count)|\(only!.min() ?? 0)"
        if let c = frameCache[cacheKey], now.timeIntervalSince(c.at) < 2.5 { return c.stats }
        var stats = FrameStats()
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: dir), includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        // frame number → (time written, file used for the thumbnail, that file's rank)
        var frames: [Int: (at: Date, path: String, rank: Int, size: Int)] = [:]
        for f in files {
            let name = f.lastPathComponent
            guard !name.hasPrefix("_"), Self.imageExts.contains(f.pathExtension.lowercased()),
                  let idx = Self.frameIndex(name) else { continue }
            if let only, !only.contains(idx) { continue }
            let v = try? f.resourceValues(forKeys: Set(keys))
            let at = v?.contentModificationDate ?? .distantPast
            let lower = name.lowercased()
            let rank = (lower.contains("shadow") || lower.contains("mask") ? 0 : 1_000_000_000) + (v?.fileSize ?? 0)
            if var cur = frames[idx] {
                if at > cur.at { cur.at = at }
                if rank > cur.rank { cur.rank = rank; cur.path = f.path; cur.size = v?.fileSize ?? 0 }
                frames[idx] = cur
            } else {
                frames[idx] = (at, f.path, rank, v?.fileSize ?? 0)
            }
        }
        stats.done = frames.count
        let byTime = frames.values.sorted { $0.at < $1.at }
        stats.lastAt = byTime.last?.at
        // The newest frame may still be being written: use the newest frame finished at least 1.5 s ago for the thumbnail
        stats.latest = (byTime.last { now.timeIntervalSince($0.at) > 1.5 } ?? byTime.last)?.path
        let recent = byTime.filter { $0.at >= since.addingTimeInterval(-1) }.suffix(31).map(\.at)
        if recent.count >= 3 {
            let deltas = zip(recent.dropFirst(), recent).map { $0.timeIntervalSince($1) }.sorted()
            let median = deltas[deltas.count / 2]
            if median > 0 { stats.secPerFrame = median }
        }
        // Odd frames among this run's, leaving out any that may still be being written.
        let settled = frames.filter { $0.value.at >= since.addingTimeInterval(-1) && now.timeIntervalSince($0.value.at) > 2 }
        let odd = Self.oddFrames(settled.map { (index: $0.key, at: $0.value.at, size: $0.value.size) })
        stats.smallFrames = odd.small
        stats.slowFrames = odd.slow
        frameCache[cacheKey] = (now, stats)
        if frameCache.count > 64 { frameCache = frameCache.filter { now.timeIntervalSince($0.value.at) < 60 } }
        return stats
    }

    /// Frames worth a second look among the most recent ones (at most `window`). Needs a dozen frames to judge by.
    /// small: the file is under a quarter of the usual size, where the usual size is at least 20 KB.
    /// slow: the gap before the frame was over five times the usual gap and over 20 s.
    package static func oddFrames(_ frames: [(index: Int, at: Date, size: Int)], window: Int = 60) -> (small: [Int], slow: [Int]) {
        let recent = Array(frames.sorted { $0.at < $1.at }.suffix(window))
        guard recent.count >= 12 else { return ([], []) }
        let sizes = recent.map(\.size).sorted()
        let usualSize = sizes[sizes.count / 2]
        let small = usualSize >= 20_000 ? recent.filter { $0.size * 4 < usualSize }.map(\.index) : []
        let gaps = zip(recent.dropFirst(), recent).map { (index: $0.index, gap: $0.at.timeIntervalSince($1.at)) }
        let sortedGaps = gaps.map(\.gap).sorted()
        let usualGap = sortedGaps[sortedGaps.count / 2]
        let slow = usualGap > 0 ? gaps.filter { $0.gap > 5 * usualGap && $0.gap > 20 }.map(\.index) : []
        return (Array(small.suffix(5)), Array(slow.suffix(5)))
    }

    private struct BlenderPlan {
        var outDir: String?
        /// The frames to be rendered: given on the command line, or read from the .blend when the command line
        /// leaves the range to the file. Nil when neither says.
        var frames: Set<Int>?
        /// The frames come from the .blend and a script on the command line may change them before the render
        /// starts: a best guess, not a count to hold the job to.
        var rough = false
    }

    /// What was read from each .blend, kept until the file changes.
    private var blendCache: [String: (stamp: Date?, scenes: [BlendFile.SceneRange]?)] = [:]

    private func blendRange(_ path: String, scene: String?) -> BlendFile.FrameRange? {
        let stamp = mtime(path)
        if blendCache[path] == nil || blendCache[path]?.stamp != stamp {
            if blendCache.count > 64 { blendCache.removeAll() }
            blendCache[path] = (stamp, stamp == nil ? nil : BlendFile.scenes(at: path))
        }
        guard let all = blendCache[path]?.scenes else { return nil }
        if let scene { return all.first { $0.name == scene }?.range }
        return (all.first { $0.active } ?? (all.count == 1 ? all.first : nil))?.range
    }

    /// Reads Blender's command line. Before `--` are Blender's own arguments (-o, -s, -e, -j, -a, -f); after it are the script's own (--out).
    private func blenderPlan(_ args: [String], cwd: String) -> BlenderPlan {
        let split = args.firstIndex(of: "--") ?? args.count
        let own = Array(args[..<split])
        let custom = Array(args[split...])
        var plan = BlenderPlan()

        var out = Self.argValue(custom, ["--out", "--output"]).map { resolve($0, cwd) }
        if out == nil, let o = Self.argValue(own, ["-o", "--render-output"]) {
            if o.hasPrefix("//") {
                // Blender convention: a leading // means relative to the .blend file's directory
                if let blend = own.first(where: { $0.hasSuffix(".blend") }) {
                    out = resolve(String(o.dropFirst(2)), (resolve(blend, cwd) as NSString).deletingLastPathComponent)
                }
            } else {
                out = resolve(o, cwd)
            }
        }
        if let o = out, o.contains("#") || !isDirectory(o) { out = (o as NSString).deletingLastPathComponent }
        plan.outDir = out

        plan.frames = Self.blenderFrames(own)
        if plan.frames == nil, let fromFile = Self.blenderFramesFromFile(own, read: { [self] file, scene in blendRange(resolve(file, cwd), scene: scene) }) {
            plan.frames = fromFile.frames
            plan.rough = fromFile.rough
        }
        return plan
    }

    /// The frames `blender -b file.blend -a` renders when the command line leaves all or part of the range to the
    /// file: `-s`, `-e` and `-j` where given, the scene's own values where not. `read` returns the range stored
    /// in a .blend for a scene (nil for the active one). `rough` is true when a script on the command line could
    /// change the range before the render starts.
    package static func blenderFramesFromFile(_ own: [String], read: (String, String?) -> BlendFile.FrameRange?) -> (frames: Set<Int>, rough: Bool)? {
        guard own.contains("-a") || own.contains("--render-anim"), argValue(own, ["-f", "--render-frame"]) == nil,
              let file = own.first(where: { $0.lowercased().hasSuffix(".blend") }),
              let stored = read(file, argValue(own, ["-S", "--scene"])) else { return nil }
        let start = argValue(own, ["-s", "--frame-start"]).flatMap { Int($0) } ?? stored.start
        let end = argValue(own, ["-e", "--frame-end"]).flatMap { Int($0) } ?? stored.end
        let jump = max(1, argValue(own, ["-j", "--frame-jump"]).flatMap { Int($0) } ?? stored.step)
        guard let frames = BlendFile.FrameRange(start: start, end: end, step: jump).frames else { return nil }
        let scripted = own.contains { ["-P", "--python", "--python-expr", "--python-text"].contains($0) }
        return (frames, scripted)
    }

    /// The frames a Blender command line asks for (`-f 1..250`, or `-s 1 -e 250 [-j 2] -a`); nil when it does not say.
    /// `own` is the part of the command line before `--`.
    package static func blenderFrames(_ own: [String]) -> Set<Int>? {
        if let list = argValue(own, ["-f", "--render-frame"]) { return parseFrameList(list) }
        guard own.contains("-a") || own.contains("--render-anim"),
              let start = argValue(own, ["-s", "--frame-start"]).flatMap({ Int($0) }),
              let end = argValue(own, ["-e", "--frame-end"]).flatMap({ Int($0) }), end >= start, end - start < 2_000_000 else { return nil }
        let jump = max(1, argValue(own, ["-j", "--frame-jump"]).flatMap { Int($0) } ?? 1)
        return Set(stride(from: start, through: end, by: jump))
    }

    /// `-f 1,5,9` or `-f 1..250`. Signed relative forms (+10, -1) can't be resolved; returns nil.
    package static func parseFrameList(_ text: String) -> Set<Int>? {
        var frames = Set<Int>()
        for part in text.split(separator: ",") {
            if let r = part.range(of: "..") {
                guard let a = Int(part[..<r.lowerBound]), let b = Int(part[r.upperBound...]), b >= a, b - a < 2_000_000,
                      !part.hasPrefix("+"), !part.hasPrefix("-") else { return nil }
                frames.formUnion(a...b)
            } else {
                guard !part.hasPrefix("+"), !part.hasPrefix("-"), let n = Int(part) else { return nil }
                frames.insert(n)
            }
        }
        return frames.isEmpty ? nil : frames
    }

    package static func frameIndex(_ name: String) -> Int? {
        let stem = (name as NSString).deletingPathExtension
        var best = "", cur = ""
        for ch in stem {
            if ch.isASCII, ch.isNumber {
                cur.append(ch)
            } else {
                if cur.count >= best.count, !cur.isEmpty { best = cur }
                cur = ""
            }
        }
        if cur.count >= best.count, !cur.isEmpty { best = cur }
        return best.isEmpty ? nil : Int(best)
    }

    /// Progress protocol: render-progress.json in the output directory, {"done": 12, "total": 720}.
    private func progressFile(_ dir: String) -> (done: Int, total: Int)? {
        guard let data = FileManager.default.contents(atPath: "\(dir)/render-progress.json"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let done = (obj["done"] as? NSNumber)?.intValue,
              let total = (obj["total"] as? NSNumber)?.intValue, total > 0 else { return nil }
        return (done, total)
    }

    /// Estimates the total frame count from an older clip of the same name: duration × frame rate. The old clip must predate this render.
    private func estimatedTotal(out: String, args: [String], procStart: Date) -> Int? {
        let name = (out as NSString).lastPathComponent
        let parent = (out as NSString).deletingLastPathComponent
        let grand = (parent as NSString).deletingLastPathComponent
        for path in ["\(parent)/\(name).mp4", "\(grand)/\(name).mp4"] {
            guard let m = mtime(path), m < procStart else { continue }
            if mp4Cache[path]?.mtime != m {
                let asset = AVURLAsset(url: URL(fileURLWithPath: path))
                let seconds = CMTimeGetSeconds(asset.duration)
                let fps = asset.tracks(withMediaType: .video).first.map { Double($0.nominalFrameRate) }
                mp4Cache[path] = (m, seconds.isFinite && seconds > 0 ? seconds : nil, fps)
            }
            guard let c = mp4Cache[path], let seconds = c.seconds else { continue }
            let fps = Self.argValue(args, ["--fps"]).flatMap(Double.init) ?? c.fps ?? 30
            let total = Int((seconds * fps).rounded())
            if total > 0 { return total }
        }
        return nil
    }

    /// Number of entries under `key` (an array or an object) in a JSON file. Cached until the file changes.
    private func jsonCount(_ path: String, key: String) -> Int? {
        guard let m = mtime(path) else { return nil }
        let cacheKey = path + "|" + key
        if let c = anchorsCache[cacheKey], c.mtime == m { return c.frames }
        var count: Int?
        if let data = FileManager.default.contents(atPath: path),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let arr = obj[key] as? [Any] { count = arr.count }
            else if let dict = obj[key] as? [String: Any] { count = dict.count }
        }
        anchorsCache[cacheKey] = (m, count)
        return count
    }

    // MARK: Process-tree checks

    private func root(of p: Proc, _ snap: ProcSnapshot) -> Proc {
        var root = p
        var cur = p
        var hops = 0
        while hops < 16, let parent = snap.table[cur.ppid], parent.pid > 1 {
            if isScriptHost(parent, snap) {
                root = parent
            } else if !isWrapper(parent, snap) {
                break
            }
            cur = parent
            hops += 1
        }
        return root
    }

    /// `renderdock run -- …` sits between a script and its render. It is looked through, never shown as the job itself.
    private func isWrapper(_ p: Proc, _ snap: ProcSnapshot) -> Bool {
        let name = p.name.lowercased()
        guard name == "renderdock" || name == "renderdock-cli" else { return false }
        return snap.args(p.pid).dropFirst().first == "run"
    }

    /// A shell / node / python that is running a script file. One-off commands such as `zsh -c "…"` (tool wrappers) don't count.
    private func isScriptHost(_ p: Proc, _ snap: ProcSnapshot) -> Bool {
        let n = p.name.lowercased()
        let isShell = Self.shells.contains(n)
        guard isShell || n == "node" || n.hasPrefix("python") else { return false }
        if !isShell, p.ppid <= 1 { return false }   // long-running services are not jobs
        return scriptArg(snap.args(p.pid), name: p.name) != nil
    }

    private func scriptArg(_ args: [String], name: String) -> String? {
        let isShell = Self.shells.contains(name.lowercased())
        for a in args.dropFirst() {
            if a.hasPrefix("-") {
                // -c, -lc and the like: what follows is a command string, not a script
                if isShell, !a.hasPrefix("--"), a.contains("c") { return nil }
                continue
            }
            if isShell { return a }
            return Self.scriptExts.contains((a as NSString).pathExtension.lowercased()) ? a : nil
        }
        return nil
    }

    private func hasAncestor(_ p: Proc, in set: Set<Int32>, _ snap: ProcSnapshot) -> Bool {
        var cur = p
        var hops = 0
        while hops < 16, let parent = snap.table[cur.ppid], parent.pid > 1 {
            if set.contains(parent.pid) { return true }
            cur = parent
            hops += 1
        }
        return false
    }

    /// One `scene:shot` item, as the standard queue rule reads it.
    package static func parseSpec(_ arg: String) -> (scene: String, shot: String)? {
        guard let item = QueueRule.standard.parse(arg), item.values.count == 2 else { return nil }
        return (item.values[0], item.values[1])
    }

    package static func specName(_ spec: (scene: String, shot: String)) -> String {
        spec.scene == spec.shot || spec.scene.hasSuffix("-\(spec.shot)") ? spec.scene : "\(spec.scene) · \(spec.shot)"
    }

    private func leafName(_ leaf: Leaf, _ snap: ProcSnapshot) -> String {
        let a = snap.args(leaf.proc.pid)
        if let given = report(for: leaf.proc)?.name { return given }   // `renderdock run --name …`
        if leaf.kind == .reported { return leaf.proc.name }
        if leaf.kind == .adapter, let i = leaf.rule, rules.adapters.indices.contains(i), let template = rules.adapters[i].title,
           let title = AdapterRules.expand(template, args: a, cwd: snap.cwd(leaf.proc.pid)) { return title }
        if let sc = Self.argValue(a, ["--scene"]) {
            return Self.specName((sc, Self.argValue(a, ["--shot"]) ?? sc))
        }
        if let seg = Self.argValue(a, ["--seg", "--segment", "--name"]) { return seg }
        if leaf.kind == .ffmpeg, let last = a.last, !last.hasPrefix("-") { return (last as NSString).lastPathComponent }
        if let blend = a.first(where: { $0.hasSuffix(".blend") }) { return ((blend as NSString).lastPathComponent as NSString).deletingPathExtension }
        if let out = Self.argValue(a, ["--out", "--output", "-o", "--render-output"]) {
            let o = out.contains("#") ? (out as NSString).deletingLastPathComponent : out
            return (o as NSString).lastPathComponent
        }
        if let py = Self.argValue(a, ["--python", "-P"]) { return (py as NSString).lastPathComponent }
        return "\(leaf.proc.name) \(leaf.proc.pid)"
    }

    // MARK: Helpers

    package static func argValue(_ args: [String], _ names: [String]) -> String? {
        for (i, a) in args.enumerated() {
            if names.contains(a), i + 1 < args.count { return args[i + 1] }
            for n in names where n.hasPrefix("--") && a.hasPrefix("\(n)=") { return String(a.dropFirst(n.count + 1)) }
        }
        return nil
    }

    private func resolve(_ path: String, _ base: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return (expanded as NSString).standardizingPath }
        return ((base as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private func mtime(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// The script's first comment line.
    private func scriptNote(_ path: String) -> String? {
        guard let m = mtime(path) else { return nil }
        if let c = scriptCache[path], c.mtime == m { return c.note }
        var note: String?
        if let fh = FileHandle(forReadingAtPath: path) {
            let head = String(decoding: fh.readData(ofLength: 4096), as: UTF8.self)
            try? fh.close()
            for raw in head.split(separator: "\n").prefix(12) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("#!") || line.isEmpty { continue }
                let body: Substring
                if line.hasPrefix("#") { body = line.drop { $0 == "#" } }
                else if line.hasPrefix("//") { body = line.dropFirst(2) }
                else { break }
                let text = body.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { note = text; break }
            }
        }
        scriptCache[path] = (m, note)
        return note
    }

    /// The title is the comment up to the first "（", "：" or "。".
    package static func shortTitle(_ note: String) -> String {
        var end = note.endIndex
        var depth = 0
        for i in note.indices {
            let ch = note[i]
            if ch == "「" || ch == "《" { depth += 1 }
            if ch == "」" || ch == "》" { depth = max(0, depth - 1) }
            guard depth == 0, i > note.startIndex else { continue }
            if "（：。(；".contains(ch) { end = i; break }
            // ASCII ":" / "." / " - " end the title only when followed by a space or the end of the line
            let next = note.index(after: i)
            let atBreak = next == note.endIndex || note[next] == " "
            if (ch == ":" || ch == ".") && atBreak { end = i; break }
            if ch == " ", next != note.endIndex, "-–—".contains(note[next]) { end = i; break }
        }
        let t = String(note[..<end]).trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? note : t
    }

    /// Project name: for a worktree, the main repository's name; otherwise walk up until a .git is found.
    private func projectName(_ cwd: String) -> String {
        var dir = cwd
        while dir.count > 1 {
            let dotGit = "\(dir)/.git"
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDir) {
                // In a linked worktree `.git` is a file: "gitdir: <main repo>/.git/worktrees/<name>". Name the main repo.
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
}
