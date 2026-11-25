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

/// How close the time-left estimates were, for one kind of estimate and one stretch of time left.
package struct EstimateLine: Codable, Equatable {
    /// "shot" (the time left of the shot in progress) or "queue" (the time left of a whole queue).
    package var kind: String
    /// "all", or how much time really was left: "under 10 min", "10 to 60 min", "1 to 4 h", "over 4 h".
    package var horizon: String
    /// How many estimates, and how many shots or queues they were about.
    package var estimates: Int
    package var targets: Int
    /// The middle one of how far off they were, in seconds, whichever way.
    package var medianOff: Double
    /// The same as a percentage of the time that really was left.
    package var medianOffPercent: Double
    /// The middle one of (estimated - actual): above zero, the estimates said longer than it took.
    package var medianBias: Double
    /// The share of estimates within a fifth of the time that really was left, 0 to 1.
    package var withinFifth: Double
}

/// The estimates RenderDock showed, held against what happened afterwards.
package struct EstimateReport: Codable, Equatable {
    /// The first and the last estimate looked at.
    package var from: Double?
    package var to: Double?
    package var lines: [EstimateLine]
    /// Estimates left out, by reason: "still running", "did not finish", "queue changed", "already over".
    package var leftOut: [String: Int]

    /// Nothing recorded, or no history at all.
    package static let nothing = EstimateReport(from: nil, to: nil, lines: [], leftOut: [:])
}

/// What RenderDock remembers: every shot it watched, with its duration and outcome, and how its frame count grew.
/// A small SQLite file next to the preferences. It holds titles and shot names, never file-system paths.
/// Not thread-safe: use it from one queue.
package final class HistoryStore {
    private var db: OpaquePointer?
    /// Shots being watched right now: item id → row, last frame count, last state.
    private var open: [String: (row: Int64, done: Int?, state: ItemState)] = [:]
    private var firstRecord = true
    /// When an estimate was last written down, by what it was about.
    private var estimateNoted: [String: Double] = [:]
    /// Estimates are written down this often, per shot and per queue: often enough to see how they move, seldom
    /// enough that a day's queue is a few hundred rows.
    package static let estimateEvery: Double = 60

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
        // The time left that was shown: for a shot (key: its row in runs) and for a whole queue (key: the job's id),
        // with how many shots were still to go, so that a queue cut short is not taken for a wrong estimate.
        exec("CREATE TABLE IF NOT EXISTS estimates (at REAL NOT NULL, kind TEXT NOT NULL, key TEXT NOT NULL, seconds REAL NOT NULL, rough INTEGER NOT NULL DEFAULT 0, shots_left INTEGER NOT NULL DEFAULT 1)")
        exec("CREATE INDEX IF NOT EXISTS estimates_key ON estimates(kind, key, at)")
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
        // What the estimates say, so that they can be held against what happens.
        for g in groups where g.state == .running {
            for item in g.items where item.state.isActive {
                guard let eta = item.eta, let o = open[item.id] else { continue }
                noteEstimate(kind: "shot", key: String(o.row), seconds: eta, rough: item.totalIsEstimate, shotsLeft: 1, at: t)
            }
            if let q = queueETA(for: g, now: now) {
                noteEstimate(kind: "queue", key: g.id, seconds: q.seconds, rough: q.guessed > 0,
                             shotsLeft: g.items.filter { $0.state != .done }.count, at: t)
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

    private func noteEstimate(kind: String, key: String, seconds: Double, rough: Bool, shotsLeft: Int, at t: Double) {
        let id = kind + ":" + key
        if let last = estimateNoted[id], t - last < Self.estimateEvery { return }
        if estimateNoted.count > 400 { estimateNoted = estimateNoted.filter { t - $0.value < 3600 } }
        estimateNoted[id] = t
        run("INSERT INTO estimates (at, kind, key, seconds, rough, shots_left) VALUES (?, ?, ?, ?, ?, ?)", [t, kind, key, seconds, rough ? 1 : 0, shotsLeft])
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
        exec("DELETE FROM estimates WHERE at < \(cutoff)")
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

    // MARK: Estimates against what happened

    /// How close the estimates of the last `days` days were. Only estimates whose shot or queue has since come to
    /// its end are counted; the rest are reported as left out, with the reason.
    ///
    /// A shot's estimate is of its frames: it is held against the next moment the count reached the total (a shot
    /// may count its frames twice over, once rendering and once compositing), or, when that fell between two looks,
    /// against the moment the shot was no longer in progress. A shot counts as having come
    /// to its end if the queue moved past it, if a wrapper said it exited cleanly, or if it was gone with at least
    /// 98 in 100 of an exact number of frames counted (the last few are often written between two looks, and
    /// nothing says how such a shot ended). A queue's estimate is held
    /// against the end of its last shot, and only if as many shots ended after the estimate as it said were left:
    /// a queue stopped half-way, or one that grew, says nothing about the estimate.
    package func estimateReport(days: Double = 30, now: Date = Date()) -> EstimateReport {
        let since = now.timeIntervalSince1970 - days * 86_400
        var checks: [(kind: String, target: String, at: Double, estimated: Double, actual: Double)] = []
        var leftOut: [String: Int] = [:]

        struct ShotEnd { var endedAt: Double?; var outcome: String?; var fullAt: [Double] = []; var nearlyAll = false }
        var shotEnds: [String: ShotEnd] = [:]
        for row in query("SELECT at, key, seconds FROM estimates WHERE kind = 'shot' AND at >= ? ORDER BY at", [since], {
            (sqlite3_column_double($0, 0), Self.text($0, 1) ?? "", sqlite3_column_double($0, 2))
        }) {
            if shotEnds[row.1] == nil {
                let id = Int64(row.1) ?? -1
                var end = query("SELECT ended_at, outcome, frames_done, frames_total, exact FROM runs WHERE id = ?", [id], { stmt -> ShotEnd in
                    var e = ShotEnd(endedAt: Self.double(stmt, 0), outcome: Self.text(stmt, 1))
                    if let done = Self.int(stmt, 2), let total = Self.int(stmt, 3), total > 0, sqlite3_column_int(stmt, 4) != 0 {
                        e.nearlyAll = Double(done) >= Double(total) * 0.98
                    }
                    return e
                }).first ?? ShotEnd(endedAt: nil, outcome: "forgotten")
                end.fullAt = query("""
                    SELECT s.at FROM samples s JOIN runs r ON r.id = s.run_id
                    WHERE s.run_id = ? AND r.exact = 1 AND r.frames_total IS NOT NULL AND s.frames_done >= r.frames_total ORDER BY s.at
                    """, [id], { sqlite3_column_double($0, 0) })
                shotEnds[row.1] = end
            }
            guard let end = shotEnds[row.1] else { continue }
            guard let endedAt = end.endedAt else { leftOut[end.outcome == "forgotten" ? "did not finish" : "still running", default: 0] += 1; continue }
            let fullAt = end.fullAt.first { $0 >= row.0 }
            guard end.outcome == "done" || end.outcome == "finished" || fullAt != nil || end.nearlyAll else { leftOut["did not finish", default: 0] += 1; continue }
            let actual = (fullAt ?? endedAt) - row.0
            guard actual > 0 else { leftOut["already over", default: 0] += 1; continue }
            checks.append(("shot", row.1, row.0, row.2, actual))
        }

        struct QueueRuns { var ends: [Double]; var open: Bool; var failed: Bool }
        var queues: [String: QueueRuns] = [:]
        for row in query("SELECT at, key, seconds, shots_left FROM estimates WHERE kind = 'queue' AND at >= ? ORDER BY at", [since], {
            (sqlite3_column_double($0, 0), Self.text($0, 1) ?? "", sqlite3_column_double($0, 2), Int(sqlite3_column_int64($0, 3)))
        }) {
            if queues[row.1] == nil {
                let runs = query("SELECT ended_at, outcome FROM runs WHERE job_id = ?", [row.1], { (Self.double($0, 0), Self.text($0, 1)) })
                queues[row.1] = QueueRuns(ends: runs.compactMap { $0.0 }, open: runs.contains { $0.0 == nil }, failed: runs.contains { $0.1 == "failed" })
            }
            guard let q = queues[row.1] else { continue }
            if q.open { leftOut["still running", default: 0] += 1; continue }
            let after = q.ends.filter { $0 > row.0 }
            if q.failed || after.count < row.3 { leftOut["did not finish", default: 0] += 1; continue }
            if after.count > row.3 { leftOut["queue changed", default: 0] += 1; continue }
            guard let end = after.max(), end > row.0 else { leftOut["already over", default: 0] += 1; continue }
            checks.append(("queue", row.1, row.0, row.2, end - row.0))
        }

        func middle(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return 0 }
            return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        }
        let horizons: [(String, Range<Double>)] = [("all", 0..<Double.infinity), ("under 10 min", 0..<600), ("10 to 60 min", 600..<3600),
                                                   ("1 to 4 h", 3600..<14_400), ("over 4 h", 14_400..<Double.infinity)]
        var lines: [EstimateLine] = []
        for kind in ["shot", "queue"] {
            for (name, range) in horizons {
                let part = checks.filter { $0.kind == kind && range.contains($0.actual) }
                guard !part.isEmpty else { continue }
                let off = part.map { abs($0.estimated - $0.actual) }
                lines.append(EstimateLine(kind: kind, horizon: name, estimates: part.count, targets: Set(part.map { $0.target }).count,
                                          medianOff: middle(off), medianOffPercent: middle(part.map { abs($0.estimated - $0.actual) / $0.actual * 100 }),
                                          medianBias: middle(part.map { $0.estimated - $0.actual }),
                                          withinFifth: Double(part.filter { abs($0.estimated - $0.actual) <= $0.actual * 0.2 }.count) / Double(part.count)))
            }
        }
        return EstimateReport(from: checks.map { $0.at }.min(), to: checks.map { $0.at }.max(), lines: lines, leftOut: leftOut)
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
