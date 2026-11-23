import Foundation
import SQLite3

/// One shot as it was seen from start to end.
package struct HistoryRun: Codable, Equatable {
    package var id: Int64
    package var jobId: String
    package var jobTitle: String
    package var project: String
    package var script: String?
    package var shot: String
    package var startedAt: Double
    package var endedAt: Double?
    package var framesDone: Int?
    package var framesTotal: Int?
    /// The total was exact, not an estimate.
    package var exact: Bool
    package var secPerFrame: Double?
    /// "done" (the queue moved on), "finished" / "failed" (a wrapper recorded the exit status), or "ended" (gone, reason unknown).
    package var outcome: String?
    package var exitCode: Int32?

    package init(id: Int64, jobId: String, jobTitle: String, project: String, script: String?, shot: String, startedAt: Double,
                 endedAt: Double?, framesDone: Int?, framesTotal: Int?, exact: Bool, secPerFrame: Double?, outcome: String?, exitCode: Int32?) {
        self.id = id
        self.jobId = jobId
        self.jobTitle = jobTitle
        self.project = project
        self.script = script
        self.shot = shot
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.framesDone = framesDone
        self.framesTotal = framesTotal
        self.exact = exact
        self.secPerFrame = secPerFrame
        self.outcome = outcome
        self.exitCode = exitCode
    }

    package var duration: Double? { endedAt.map { max(0, $0 - startedAt) } }
}

/// How long a whole queue still needs. Always an estimate.
package struct QueueETA: Equatable {
    package var seconds: Double
    /// Shots whose remaining time comes from their own progress or from an earlier run of the same shot.
    package var known: Int
    /// Shots that never ran before and were given this queue's average.
    package var guessed: Int

    package init(seconds: Double, known: Int, guessed: Int) {
        self.seconds = seconds
        self.known = known
        self.guessed = guessed
    }
}

/// What RenderDock remembers: every shot it watched, with its duration and outcome, and how its frame count grew.
/// A small SQLite file next to the preferences. It holds titles and shot names, never file-system paths.
/// Not thread-safe: use it from one queue.
package final class HistoryStore {
    private var db: OpaquePointer?
    /// Shots being watched right now: item id → row, last frame count, last state.
    private var open: [String: (row: Int64, done: Int?, state: ItemState)] = [:]
    private var firstRecord = true

    /// Override with the RENDERDOCK_HISTORY environment variable (used when testing).
    package static var defaultFile: URL {
        if let custom = ProcessInfo.processInfo.environment["RENDERDOCK_HISTORY"], !custom.isEmpty { return URL(fileURLWithPath: custom) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RenderDock/history.sqlite")
    }

    /// `readOnly`: for callers that only look things up (the command line). Opens nothing if the file does not
    /// exist yet, and never creates or changes it.
    package init?(file: URL = HistoryStore.defaultFile, readOnly: Bool = false) {
        if readOnly {
            guard FileManager.default.fileExists(atPath: file.path),
                  sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                sqlite3_close(db)
                return nil
            }
            return
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(file.path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        exec("PRAGMA journal_mode = WAL")
        exec("""
            CREATE TABLE IF NOT EXISTS runs (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              item_id TEXT NOT NULL UNIQUE,
              job_id TEXT NOT NULL, job_title TEXT NOT NULL, project TEXT NOT NULL, script TEXT, shot TEXT NOT NULL,
              started_at REAL NOT NULL, updated_at REAL NOT NULL, ended_at REAL,
              frames_done INTEGER, frames_total INTEGER, exact INTEGER NOT NULL DEFAULT 0,
              sec_per_frame REAL, outcome TEXT, exit_code INTEGER
            )
            """)
        exec("CREATE INDEX IF NOT EXISTS runs_shot ON runs(project, shot, ended_at)")
        exec("CREATE INDEX IF NOT EXISTS runs_job ON runs(job_id)")
        exec("CREATE TABLE IF NOT EXISTS samples (run_id INTEGER NOT NULL, at REAL NOT NULL, frames_done INTEGER NOT NULL)")
        exec("CREATE INDEX IF NOT EXISTS samples_run ON samples(run_id, at)")
        // Shots that were still open when RenderDock last quit: keep watching them if they are still there.
        for row in query("SELECT item_id, id, frames_done FROM runs WHERE ended_at IS NULL", [], { stmt in
            (Self.text(stmt, 0) ?? "", sqlite3_column_int64(stmt, 1), Self.int(stmt, 2))
        }) {
            open[row.0] = (row.1, row.2, .rendering)
        }
    }

    deinit { sqlite3_close(db) }

    // MARK: Recording

    /// Call once per scan. `outcomes`: how jobs that have just disappeared ended, where a wrapper recorded it.
    package func record(_ groups: [RenderGroup], outcomes: [String: JobOutcome] = [:], now: Date = Date()) {
        let t = now.timeIntervalSince1970
        exec("BEGIN")
        var seen = Set<String>()
        for g in groups {
            for item in g.items where item.state != .pending {
                if item.state == .done {
                    // The queue has moved past this shot.
                    if let o = open[item.id] {
                        seen.insert(item.id)
                        finish(row: o.row, at: t, outcome: "done", exitCode: nil)
                        open[item.id] = nil
                    }
                    continue
                }
                seen.insert(item.id)
                if let o = open[item.id] {
                    guard o.done != item.framesDone || o.state != item.state else { continue }
                    run("UPDATE runs SET updated_at = ?, frames_done = ?, frames_total = ?, exact = ?, sec_per_frame = ? WHERE id = ?",
                        [t, item.framesDone, item.framesTotal, item.framesTotal != nil && !item.totalIsEstimate ? 1 : 0, item.secPerFrame, o.row])
                    if o.done != item.framesDone, let d = item.framesDone {
                        run("INSERT INTO samples (run_id, at, frames_done) VALUES (?, ?, ?)", [o.row, t, d])
                    }
                    open[item.id] = (o.row, item.framesDone, item.state)
                } else {
                    run("""
                        INSERT INTO runs (item_id, job_id, job_title, project, script, shot, started_at, updated_at, frames_done, frames_total, exact, sec_per_frame)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(item_id) DO UPDATE SET ended_at = NULL, outcome = NULL, exit_code = NULL, updated_at = excluded.updated_at
                        """,
                        [item.id, g.id, g.title, g.project, g.script, item.name, item.startedAt?.timeIntervalSince1970 ?? t, t,
                         item.framesDone, item.framesTotal, item.framesTotal != nil && !item.totalIsEstimate ? 1 : 0, item.secPerFrame])
                    let row = query("SELECT id FROM runs WHERE item_id = ?", [item.id], { sqlite3_column_int64($0, 0) }).first ?? 0
                    if let d = item.framesDone { run("INSERT INTO samples (run_id, at, frames_done) VALUES (?, ?, ?)", [row, t, d]) }
                    open[item.id] = (row, item.framesDone, item.state)
                }
            }
        }
        // Shots that have gone.
        let jobOf = Dictionary(groups.flatMap { g in g.items.map { ($0.id, g.id) } }, uniquingKeysWith: { a, _ in a })
        for (itemId, o) in open where !seen.contains(itemId) {
            let jobId = jobOf[itemId] ?? query("SELECT job_id FROM runs WHERE id = ?", [o.row], { Self.text($0, 0) ?? "" }).first ?? ""
            if firstRecord {
                // It ended while RenderDock was not running: the last time it was seen is the best we know.
                run("UPDATE runs SET ended_at = updated_at, outcome = 'ended' WHERE id = ?", [o.row])
            } else if let outcome = outcomes[jobId] {
                finish(row: o.row, at: t, outcome: outcome.finished ? "finished" : "failed", exitCode: outcome.exitCode)
            } else {
                finish(row: o.row, at: t, outcome: "ended", exitCode: nil)
            }
            open[itemId] = nil
        }
        firstRecord = false
        exec("COMMIT")
    }

    private func finish(row: Int64, at: Double, outcome: String, exitCode: Int32?) {
        run("UPDATE runs SET ended_at = ?, updated_at = ?, outcome = ?, exit_code = ? WHERE id = ?", [at, at, outcome, exitCode.map { Int($0) }, row])
        // The last frames land between two scans. A shot known to have completed, with an exact total, rendered all of it.
        if outcome == "done" || outcome == "finished" {
            run("UPDATE runs SET frames_done = frames_total WHERE id = ? AND exact = 1 AND frames_total IS NOT NULL", [row])
        }
    }

    /// Forgets shots that ended long ago.
    package func prune(olderThanDays days: Double = 90, now: Date = Date()) {
        let cutoff = now.timeIntervalSince1970 - days * 86_400
        exec("DELETE FROM samples WHERE run_id IN (SELECT id FROM runs WHERE ended_at IS NOT NULL AND ended_at < \(cutoff))")
        exec("DELETE FROM runs WHERE ended_at IS NOT NULL AND ended_at < \(cutoff)")
    }

    // MARK: Reading

    private static let columns = "id, job_id, job_title, project, script, shot, started_at, ended_at, frames_done, frames_total, exact, sec_per_frame, outcome, exit_code"

    private static func runRow(_ s: OpaquePointer) -> HistoryRun {
        HistoryRun(id: sqlite3_column_int64(s, 0), jobId: text(s, 1) ?? "", jobTitle: text(s, 2) ?? "", project: text(s, 3) ?? "",
                   script: text(s, 4), shot: text(s, 5) ?? "", startedAt: sqlite3_column_double(s, 6), endedAt: double(s, 7),
                   framesDone: int(s, 8), framesTotal: int(s, 9), exact: sqlite3_column_int(s, 10) != 0, secPerFrame: double(s, 11),
                   outcome: text(s, 12), exitCode: int(s, 13).map { Int32($0) })
    }

    /// The shots that ended most recently, newest first.
    package func recent(limit: Int = 20) -> [HistoryRun] {
        query("SELECT \(Self.columns) FROM runs WHERE ended_at IS NOT NULL ORDER BY ended_at DESC, id DESC LIMIT ?", [limit], Self.runRow)
    }

    /// How long this shot took the last time it ran to the end. Nil if it never has.
    package func expectedDuration(project: String, shot: String) -> Double? {
        query("""
            SELECT ended_at - started_at FROM runs
            WHERE project = ? AND shot = ? AND ended_at IS NOT NULL AND outcome IN ('done', 'finished') AND ended_at > started_at
            ORDER BY ended_at DESC LIMIT 1
            """, [project, shot], { sqlite3_column_double($0, 0) }).first
    }

    private func finishedDurations(jobId: String) -> [Double] {
        query("SELECT ended_at - started_at FROM runs WHERE job_id = ? AND outcome IN ('done', 'finished') AND ended_at > started_at",
              [jobId], { sqlite3_column_double($0, 0) })
    }

    private func startOfOpenRun(itemId: String) -> Double? {
        query("SELECT started_at FROM runs WHERE item_id = ? AND ended_at IS NULL", [itemId], { sqlite3_column_double($0, 0) }).first
    }

    /// Time until every shot of a running queue is through. Nil for single jobs, for queues that are not running,
    /// and when there is nothing to base an estimate on.
    ///
    /// A shot in progress uses its own time left, or what is left of its previous duration, whichever is longer
    /// (a shot is more than its render: compositing and checks follow). A shot still to come uses its previous
    /// duration, or failing that the average of this queue's finished shots. Parallel streams of one queue are
    /// added up separately and the longest one counts.
    package func queueETA(for group: RenderGroup, now: Date = Date()) -> QueueETA? {
        guard group.items.count > 1, group.state == .running else { return nil }
        let t = now.timeIntervalSince1970
        let finished = finishedDurations(jobId: group.id)
        var average: Double? = finished.isEmpty ? nil : finished.reduce(0, +) / Double(finished.count)
        if average == nil {
            // Nothing finished yet: the shot in progress, projected to its end, stands in for the others.
            for item in group.items where item.state.isActive {
                if let eta = item.eta, let start = startOfOpenRun(itemId: item.id) ?? item.startedAt?.timeIntervalSince1970 {
                    average = (t - start) + eta
                    break
                }
            }
        }
        var streams: [String: Double] = [:]
        var known = 0, guessed = 0
        for item in group.items where item.state != .done {
            let parts = item.id.split(separator: "/")
            let stream = parts.count >= 2 ? String(parts[1]) : item.id
            let previous = expectedDuration(project: group.project, shot: item.name)
            let remaining: Double
            if item.state.isActive {
                let elapsed = (startOfOpenRun(itemId: item.id) ?? item.startedAt?.timeIntervalSince1970).map { t - $0 } ?? 0
                let byHistory = previous.map { max(0, $0 - elapsed) }
                guard let r = [item.eta, byHistory].compactMap({ $0 }).max() ?? average.map({ max(0, $0 - elapsed) }) else { return nil }
                remaining = r
                if item.eta != nil || previous != nil { known += 1 } else { guessed += 1 }
            } else if let p = previous {
                remaining = item.fraction.map { p * (1 - $0) } ?? p
                known += 1
            } else if let a = average {
                remaining = item.fraction.map { a * (1 - $0) } ?? a
                guessed += 1
            } else {
                return nil
            }
            streams[stream, default: 0] += remaining
        }
        guard let longest = streams.values.max() else { return nil }
        return QueueETA(seconds: longest, known: known, guessed: guessed)
    }

    // MARK: SQLite plumbing

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    private func prepare(_ sql: String, _ binds: [Any?]) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        for (i, value) in binds.enumerated() {
            let n = Int32(i + 1)
            switch value {
            case let v as String: sqlite3_bind_text(stmt, n, v, -1, Self.transient)
            case let v as Int: sqlite3_bind_int64(stmt, n, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, n, v)
            case let v as Double: sqlite3_bind_double(stmt, n, v)
            default: sqlite3_bind_null(stmt, n)
            }
        }
        return stmt
    }

    private func run(_ sql: String, _ binds: [Any?]) {
        guard let stmt = prepare(sql, binds) else { return }
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    private func query<T>(_ sql: String, _ binds: [Any?], _ row: (OpaquePointer) -> T) -> [T] {
        guard let stmt = prepare(sql, binds) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(row(stmt)) }
        return out
    }

    private static func text(_ s: OpaquePointer, _ i: Int32) -> String? {
        sqlite3_column_text(s, i).map { String(cString: $0) }
    }

    private static func int(_ s: OpaquePointer, _ i: Int32) -> Int? {
        sqlite3_column_type(s, i) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(s, i))
    }

    private static func double(_ s: OpaquePointer, _ i: Int32) -> Double? {
        sqlite3_column_type(s, i) == SQLITE_NULL ? nil : sqlite3_column_double(s, i)
    }
}
