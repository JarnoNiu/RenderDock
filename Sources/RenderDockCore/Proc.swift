import Darwin
import Foundation

/// Read-only snapshot of one process. Arguments and working directory are fetched on demand (only for processes that may be render-related).
struct Proc {
    let pid: Int32
    let ppid: Int32
    let start: Date
    /// Suspended by `kill -STOP` (process state T).
    let stopped: Bool
    /// Executable name, e.g. Blender, zsh, node.
    let name: String
}

enum ProcTable {
    private static let timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t()
        mach_timebase_info(&t)
        return t
    }()

    static func allPids() -> [Int32] {
        let cap = proc_listallpids(nil, 0)
        guard cap > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(cap) + 128)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        return n > 0 ? Array(pids.prefix(Int(n))).filter { $0 > 0 } : []
    }

    static func proc(_ pid: Int32) -> Proc? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        var name = cString(info.pbi_name)
        if name.isEmpty { name = cString(info.pbi_comm) }
        let start = Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1e6)
        return Proc(pid: pid, ppid: Int32(info.pbi_ppid), start: start, stopped: info.pbi_status == 4 /* SSTOP */, name: name)
    }

    /// Command-line arguments (argv); empty when they can't be read (another user's process).
    static func args(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = 4
        while i < size, buf[i] != 0 { i += 1 }   // executable path
        while i < size, buf[i] == 0 { i += 1 }   // padding zeros
        var out: [String] = []
        while i < size, out.count < Int(argc) {
            let s = i
            while i < size, buf[i] != 0 { i += 1 }
            out.append(String(decoding: buf[s..<i], as: UTF8.self))
            i += 1
        }
        return out
    }

    static func cwd(_ pid: Int32) -> String {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return "" }
        return cString(info.pvi_cdir.vip_path)
    }

    /// Cumulative CPU time (nanoseconds) and memory footprint (bytes; the same figure as the Memory column in Activity Monitor).
    static func usage(_ pid: Int32) -> (cpuNs: UInt64, footprint: UInt64)? {
        var ru = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &ru) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard rc == 0 else { return nil }
        // On Apple silicon these two times are in mach time units and must be converted to nanoseconds.
        let ticks = ru.ri_user_time &+ ru.ri_system_time
        let ns = ticks &* UInt64(timebase.numer) / UInt64(max(timebase.denom, 1))
        return (ns, ru.ri_phys_footprint)
    }

    private static func cString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

/// The process table used for one scan: parent/child links, arguments fetched on demand.
final class ProcSnapshot {
    private(set) var table: [Int32: Proc] = [:]
    private(set) var children: [Int32: [Int32]] = [:]
    private var argsCache: [Int32: [String]] = [:]
    private var cwdCache: [Int32: String] = [:]

    init() {
        for pid in ProcTable.allPids() {
            guard let p = ProcTable.proc(pid) else { continue }
            table[pid] = p
            children[p.ppid, default: []].append(pid)
        }
        for key in children.keys { children[key]?.sort() }
    }

    func args(_ pid: Int32) -> [String] {
        if let a = argsCache[pid] { return a }
        let a = ProcTable.args(pid)
        argsCache[pid] = a
        return a
    }

    func cwd(_ pid: Int32) -> String {
        if let c = cwdCache[pid] { return c }
        let c = ProcTable.cwd(pid)
        cwdCache[pid] = c
        return c
    }

    /// All descendants (not including the process itself), in ascending PID order.
    func descendants(of pid: Int32) -> [Int32] {
        var out: [Int32] = []
        var stack = children[pid] ?? []
        var seen = Set<Int32>()
        while let p = stack.popLast() {
            guard seen.insert(p).inserted else { continue }
            out.append(p)
            stack.append(contentsOf: children[p] ?? [])
        }
        return out.sorted()
    }
}
