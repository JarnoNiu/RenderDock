import Foundation

/// Reads the log a render's output is redirected to (`blender -b … > render.log`), so that such a job
/// shows exact progress with no wrapper and no hook. Read-only: the file is only ever opened for reading.
package final class LogFollower {
    package init() {}

    private struct State {
        var path: String
        var offset: UInt64 = 0
        var parser: ProgressParser
        var pending = Data()
    }

    private var states: [Int32: State] = [:]
    /// A log this far behind is not worth catching up on in one scan.
    private static let maxCatchUp: UInt64 = 64 * 1024 * 1024

    /// What the process has written to its standard output so far, as progress. Nil when its output is not a
    /// regular file (a terminal, a pipe), or when nothing in the file looks like render progress.
    package func progress(pid: Int32, totalFromCommandLine: Int?) -> ProgressParser? {
        guard let path = ProcTable.regularFile(pid: pid, fd: 1) else {
            states[pid] = nil
            return nil
        }
        var st = states[pid].flatMap { $0.path == path ? $0 : nil }
            ?? State(path: path, parser: ProgressParser(totalFromCommandLine: totalFromCommandLine))
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < st.offset {   // the file was truncated: start over
            st = State(path: path, parser: ProgressParser(totalFromCommandLine: totalFromCommandLine))
        }
        guard size - st.offset <= Self.maxCatchUp else { return nil }
        if size > st.offset {
            try? handle.seek(toOffset: st.offset)
            st.pending.append(handle.readData(ofLength: Int(size - st.offset)))
            st.offset = size
            while let i = st.pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = String(decoding: st.pending[st.pending.startIndex..<i], as: UTF8.self)
                st.pending.removeSubrange(st.pending.startIndex...i)
                // Several renders may append to one log. What came before the previous render's last line,
                // or before this render announced its range, belongs to an earlier run.
                if line.hasSuffix("Blender quit") || line.contains("Rendering animation (frames") {
                    st.parser = ProgressParser(totalFromCommandLine: totalFromCommandLine)
                }
                st.parser.feed(line)
            }
            if st.pending.count > 1_048_576 { st.pending.removeAll() }
        }
        states[pid] = st
        let p = st.parser
        return p.done > 0 || p.total != nil || p.frame != nil ? p : nil
    }

    func forget(except alive: Set<Int32>) {
        states = states.filter { alive.contains($0.key) }
    }
}
