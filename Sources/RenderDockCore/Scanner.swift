import AVFoundation
import Foundation

/// Recognises render jobs from the process tree and the output directories. Read-only throughout: sends no signals and writes no files.
package final class TaskScanner {
    package init() {}

    private enum LeafKind { case blender, composite, ffmpeg }

    private struct Leaf {
        let proc: Proc
        let kind: LeafKind
    }

    private struct Stream {
        let proc: Proc
        let specs: [(scene: String, shot: String)]
    }

    private struct FrameStats {
        var done = 0
        var latest: String?
        var lastAt: Date?
        var secPerFrame: Double?
    }

    private var cpuPrev: [Int32: (ns: UInt64, at: Date)] = [:]
    private var scriptCache: [String: (mtime: Date, note: String?)] = [:]
    private var frameCache: [String: (at: Date, stats: FrameStats)] = [:]
    private var mp4Cache: [String: (mtime: Date, seconds: Double?, fps: Double?)] = [:]
    private var anchorsCache: [String: (mtime: Date, frames: Int?)] = [:]

    private static let shells: Set<String> = ["zsh", "bash", "sh", "dash", "fish"]
    private static let imageExts: Set<String> = ["png", "jpg", "jpeg", "exr", "tif", "tiff", "webp", "bmp", "tga"]
    private static let scriptExts: Set<String> = ["sh", "zsh", "bash", "py", "js", "mjs", "cjs", "ts"]

    // MARK: Scanning

    package func scan(now: Date = Date()) -> [RenderGroup] {
        let snap = ProcSnapshot()

        // 1. Leaves: the processes doing the actual work
        var blenderLeaves: [Leaf] = []
        var nodeCandidates: [Proc] = []
        var ffmpegCandidates: [Proc] = []
        for p in snap.table.values {
            let lower = p.name.lowercased()
            if lower == "blender" {
                let a = snap.args(p.pid)
                if a.contains("-b") || a.contains("--background") { blenderLeaves.append(Leaf(proc: p, kind: .blender)) }
            } else if lower == "node" {
                let a = snap.args(p.pid)
                if a.contains("--scene"), a.contains(where: { $0.hasSuffix("render.mjs") }) { nodeCandidates.append(p) }
            } else if lower == "ffmpeg" {
                if now.timeIntervalSince(p.start) >= 3 { ffmpegCandidates.append(p) }
            }
        }
        let blenderPids = Set(blenderLeaves.map(\.proc.pid))
        var leaves = blenderLeaves
        var compositePids = Set<Int32>()
        for n in nodeCandidates where blenderPids.isDisjoint(with: snap.descendants(of: n.pid)) {
            leaves.append(Leaf(proc: n, kind: .composite))
            compositePids.insert(n.pid)
        }
        for f in ffmpegCandidates where !hasAncestor(f, in: compositePids, snap) {
            leaves.append(Leaf(proc: f, kind: .ffmpeg))
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
        return groups.sorted {
            $0.state.rawValue != $1.state.rawValue ? $0.state.rawValue < $1.state.rawValue : $0.startedAt < $1.startedAt
        }
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

        // The queued shots (scene:shot list)
        var streamProcs: [String: [Proc]] = [:]
        var streamSpecs: [String: [(scene: String, shot: String)]] = [:]
        for pid in [root.pid] + desc {
            guard let p = snap.table[pid], Self.shells.contains(p.name.lowercased()) else { continue }
            let specs = snap.args(pid).dropFirst().compactMap(Self.parseSpec)
            guard !specs.isEmpty else { continue }
            let key = specs.map { "\($0.scene):\($0.shot)" }.joined(separator: " ")
            streamProcs[key, default: []].append(p)
            streamSpecs[key] = specs
        }
        // A subshell in a pipeline has exactly the same command line as the main shell: keep only the main one (the one whose parent does not have that same command line)
        var streams: [Stream] = []
        for (key, procs) in streamProcs {
            let pids = Set(procs.map(\.pid))
            let main = procs.first { !pids.contains($0.ppid) } ?? procs[0]
            streams.append(Stream(proc: main, specs: streamSpecs[key] ?? []))
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
                let key = "\(spec.scene)-\(spec.shot)"
                var item = RenderItem(id: "\(groupId)/\(stream.proc.pid)/\(key)", name: Self.specName(spec), state: .pending)
                if let leaf = leaves.first(where: { sdescSet.contains($0.proc.pid) && !used.contains($0.proc.pid) && matches($0.proc, spec, snap) }) {
                    used.insert(leaf.proc.pid)
                    fill(&item, leaf: leaf, spec: spec, snap: snap, now: now)
                    if current == nil { current = i }
                } else if current == nil, sdesc.contains(where: { snap.args($0).contains { $0.contains(key) } }) {
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
                    let mp4 = "\(scwd)/out/\(spec.scene)-\(spec.shot).mp4"
                    if let m = mtime(mp4), m >= stream.proc.start {
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
            var item = RenderItem(id: "\(groupId)/p\(leaf.proc.pid)", name: leafName(leaf, snap), state: .preparing)
            fill(&item, leaf: leaf, spec: nil, snap: snap, now: now)
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
        let title = note.map(Self.shortTitle) ?? scriptName ?? items.first?.name ?? root.name
        let keepAwake = ([root.pid] + desc).contains { snap.table[$0]?.name == "caffeinate" }
        let home = leaves.first.map { snap.cwd($0.proc.pid) } ?? rootCwd
        return RenderGroup(
            id: groupId, title: title, script: scriptName, scriptPath: scriptPath, note: note,
            project: projectName(home.isEmpty ? rootCwd : home), cwd: home.isEmpty ? rootCwd : home,
            startedAt: root.start, keepAwake: keepAwake, state: state, items: items
        )
    }

    // MARK: Progress of one shot

    private func fill(_ item: inout RenderItem, leaf: Leaf, spec: (scene: String, shot: String)?, snap: ProcSnapshot, now: Date) {
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
            if let out = plan.outDir, isDirectory(out) {
                item.outDir = out
                let st = frameStats(out, since: p.start, now: now, only: plan.frames)
                item.framesDone = st.done
                item.latestFrame = st.latest
                item.lastFrameAt = st.lastAt
                item.secPerFrame = st.secPerFrame
                if let exact = progressFile(out) {
                    item.framesDone = exact.done
                    item.framesTotal = exact.total
                } else if let frames = plan.frames, !frames.isEmpty {
                    // The frame range is on the command line (-s/-e/-a or -f): the total is exact
                    item.framesTotal = frames.count
                } else if let est = estimatedTotal(out: out, args: a, procStart: p.start), est >= st.done {
                    item.framesTotal = est
                    item.totalIsEstimate = true
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

        case .composite:
            item.state = p.stopped ? .paused : .compositing
            let scene = spec?.scene ?? Self.argValue(a, ["--scene"]) ?? ""
            let shot = spec?.shot ?? Self.argValue(a, ["--shot"]) ?? ""
            let key = "\(scene)-\(shot)"
            let framesDir = "\(cwd)/out/frames/\(key)"
            if isDirectory(framesDir), let total = anchorsFrameCount("\(cwd)/out/blender/\(key)/anchors.json") {
                let st = frameStats(framesDir, since: p.start, now: now)
                // Compositing empties the directory when it starts; a directory older than the process has not been emptied yet, so count 0 frames
                let fresh = (mtime(framesDir) ?? .distantPast) >= p.start
                item.outDir = framesDir
                item.framesDone = fresh ? min(st.done, total) : 0
                item.framesTotal = total
                item.latestFrame = fresh ? st.latest : nil
                item.lastFrameAt = fresh ? st.lastAt : nil
                item.secPerFrame = fresh ? st.secPerFrame : nil
            }

        case .ffmpeg:
            item.state = p.stopped ? .paused : .encoding
            if let last = a.last, !last.hasPrefix("-") { item.outDir = (resolve(last, cwd) as NSString).deletingLastPathComponent }
        }
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
        var frames: [Int: (at: Date, path: String, rank: Int)] = [:]
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
                if rank > cur.rank { cur.rank = rank; cur.path = f.path }
                frames[idx] = cur
            } else {
                frames[idx] = (at, f.path, rank)
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
        frameCache[cacheKey] = (now, stats)
        if frameCache.count > 64 { frameCache = frameCache.filter { now.timeIntervalSince($0.value.at) < 60 } }
        return stats
    }

    private struct BlenderPlan {
        var outDir: String?
        /// Frame numbers given explicitly on the command line; nil when not given (the range is stored in the .blend and can't be seen from outside).
        var frames: Set<Int>?
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
        return plan
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

    private func anchorsFrameCount(_ path: String) -> Int? {
        guard let m = mtime(path) else { return nil }
        if let c = anchorsCache[path], c.mtime == m { return c.frames }
        var count: Int?
        if let data = FileManager.default.contents(atPath: path),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let arr = obj["frames"] as? [Any] { count = arr.count }
            else if let dict = obj["frames"] as? [String: Any] { count = dict.count }
        }
        anchorsCache[path] = (m, count)
        return count
    }

    // MARK: Process-tree checks

    private func root(of p: Proc, _ snap: ProcSnapshot) -> Proc {
        var root = p
        var hops = 0
        while hops < 16, let parent = snap.table[root.ppid], parent.pid > 1, isScriptHost(parent, snap) {
            root = parent
            hops += 1
        }
        return root
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

    package static func parseSpec(_ arg: String) -> (scene: String, shot: String)? {
        let parts = arg.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        let ok: (Substring) -> Bool = { $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") } }
        guard ok(parts[0]), ok(parts[1]), parts[0].contains(where: \.isLetter) else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    private func matches(_ p: Proc, _ spec: (scene: String, shot: String), _ snap: ProcSnapshot) -> Bool {
        let a = snap.args(p.pid)
        if let sc = Self.argValue(a, ["--scene"]), let sh = Self.argValue(a, ["--shot"]) { return sc == spec.scene && sh == spec.shot }
        let key = "\(spec.scene)-\(spec.shot)"
        return a.contains { $0.contains(key) }
    }

    package static func specName(_ spec: (scene: String, shot: String)) -> String {
        spec.scene == spec.shot || spec.scene.hasSuffix("-\(spec.shot)") ? spec.scene : "\(spec.scene) · \(spec.shot)"
    }

    private func leafName(_ leaf: Leaf, _ snap: ProcSnapshot) -> String {
        let a = snap.args(leaf.proc.pid)
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
