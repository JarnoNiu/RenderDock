import Foundation

/// What the desktop widget shows. The app writes it as one small file in its own folder; the widget, which runs
/// in a sandbox of its own, may read that folder and nothing else of the user's. No path is in it.
package struct WidgetData: Codable, Equatable {
    /// The render in front: the one the capsule shows.
    package struct Focus: Codable, Equatable {
        package var name: String
        package var job: String
        /// 0…1, nil when the render does not say how far along it is.
        package var fraction: Double?
        /// The total behind the fraction is an estimate.
        package var estimate: Bool
        /// Seconds left for this shot, as estimated when the file was written.
        package var etaSec: Double?
        package var framesDone: Int?

        package init(name: String, job: String, fraction: Double?, estimate: Bool, etaSec: Double?, framesDone: Int?) {
            self.name = name
            self.job = job
            self.fraction = fraction
            self.estimate = estimate
            self.etaSec = etaSec
            self.framesDone = framesDone
        }
    }

    /// When this was written.
    package var at: Date
    /// "rendering", "paused", "stalled", "waiting", "idle", or "off" (RenderDock has quit).
    package var state: String
    /// Shots rendering now, shots paused, shots that stopped moving, jobs waiting their turn.
    package var active: Int
    package var paused: Int
    package var stalled: Int
    package var queued: Int
    package var focus: Focus?
    /// The focus shot's job as a queue: how many of its shots are through, of how many.
    package var shotsDone: Int?
    package var shotsTotal: Int?
    /// Seconds until that whole queue is through, as estimated when the file was written.
    package var queueEtaSec: Double?
    package var agentsWaiting: Int
    package var agentsWorking: Int
    package var agentsFailed: Int
    /// The app's language: the widget says its few words in the same one.
    package var chinese: Bool

    package init(at: Date, state: String, active: Int = 0, paused: Int = 0, stalled: Int = 0, queued: Int = 0, focus: Focus? = nil,
                 shotsDone: Int? = nil, shotsTotal: Int? = nil, queueEtaSec: Double? = nil,
                 agentsWaiting: Int = 0, agentsWorking: Int = 0, agentsFailed: Int = 0, chinese: Bool) {
        self.at = at
        self.state = state
        self.active = active
        self.paused = paused
        self.stalled = stalled
        self.queued = queued
        self.focus = focus
        self.shotsDone = shotsDone
        self.shotsTotal = shotsTotal
        self.queueEtaSec = queueEtaSec
        self.agentsWaiting = agentsWaiting
        self.agentsWorking = agentsWorking
        self.agentsFailed = agentsFailed
        self.chinese = chinese
    }

    package static let kind = "io.github.jarnoniu.renderdock.widget.status"
    package static let fileName = "widget.json"
    /// Past this age, with a render said to be going, the file is no longer taken at its word: the app that
    /// writes it every half minute has stopped doing so.
    package static let stale: TimeInterval = 180

    /// The file in the app's folder, by the user's real home (inside a sandbox the usual lookup gives the
    /// sandbox's own container instead).
    package static var sharedURL: URL {
        if let path = ProcessInfo.processInfo.environment["RENDERDOCK_WIDGET"], !path.isEmpty { return URL(fileURLWithPath: path) }
        let home = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/RenderDock/" + fileName)
    }

    package static func read(from url: URL = sharedURL) -> WidgetData? {
        guard let data = try? Data(contentsOf: url), data.count < 65_536 else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard var read = try? decoder.decode(WidgetData.self, from: data) else { return nil }
        // Counts are counts: what is drawn from them (a row of marks, a number) expects them small and not negative.
        func count(_ n: Int) -> Int { min(max(n, 0), 9_999) }
        read.active = count(read.active)
        read.paused = count(read.paused)
        read.stalled = count(read.stalled)
        read.queued = count(read.queued)
        read.agentsWaiting = count(read.agentsWaiting)
        read.agentsWorking = count(read.agentsWorking)
        read.agentsFailed = count(read.agentsFailed)
        read.shotsDone = read.shotsDone.map(count)
        read.shotsTotal = read.shotsTotal.map(count)
        if let frames = read.focus?.framesDone { read.focus?.framesDone = min(max(frames, 0), 99_999_999) }
        return read
    }

    @discardableResult
    package func write(to url: URL = sharedURL) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// The same, apart from when it was written: nothing a reader would see differently.
    package func sameContent(as other: WidgetData) -> Bool {
        var a = self, b = other
        a.at = Date(timeIntervalSince1970: 0)
        b.at = a.at
        return a == b
    }

    /// The same situation: the same shot in the same state, the same counts. How far along it is and how long
    /// it has left are not part of that: those move all the time.
    package func sameSituation(as other: WidgetData) -> Bool {
        var a = self, b = other
        for i in 0..<2 {
            var d = i == 0 ? a : b
            d.at = Date(timeIntervalSince1970: 0)
            d.queueEtaSec = nil
            if var f = d.focus {
                f.etaSec = nil
                f.framesDone = nil
                // Whether there is a percentage at all is part of the situation; which one is not.
                f.fraction = f.fraction == nil ? nil : 0
                d.focus = f
            }
            if i == 0 { a = d } else { b = d }
        }
        return a == b
    }

    /// A render with a percentage and a time left moves by itself between two writings, and the widget can
    /// carry it forward without being told.
    package var movesByItself: Bool {
        state == "rendering" && focus?.fraction != nil && (focus?.etaSec ?? 0) > 0
    }

    /// As it would stand at `date` if the render kept its pace: the fraction further along, the times shorter.
    /// Never past 99 percent (only the app can say a shot is through), and never carried more than a quarter of
    /// an hour.
    package func carried(to date: Date) -> WidgetData {
        guard movesByItself, var f = focus, let fraction = f.fraction, let eta = f.etaSec else { return self }
        let passed = min(900, max(0, date.timeIntervalSince(at)))
        guard passed > 0 else { return self }
        var next = self
        f.fraction = min(0.99, fraction + (1 - fraction) * passed / eta)
        f.etaSec = max(0, eta - passed)
        next.focus = f
        if let queue = queueEtaSec { next.queueEtaSec = max(0, queue - passed) }
        next.at = at.addingTimeInterval(passed)
        return next
    }

    /// Whether the widget should be asked to read again, given what it was last told and when. Yes when the
    /// situation changed (another shot, a pause, a session waiting); yes when the render has drifted from where
    /// the widget will have carried it by itself, though not more often than once a minute; and every ten
    /// minutes regardless. A widget is not meant to be told every second, and the system would stop listening.
    package static func worthTelling(_ data: WidgetData, told: WidgetData?, toldAt: Date) -> Bool {
        guard let told else { return true }
        if !data.sameSituation(as: told) { return true }
        let since = data.at.timeIntervalSince(toldAt)
        if since >= 600 { return true }
        guard since >= 60 else { return false }
        let expected = told.carried(to: data.at)
        if let now = data.focus?.fraction, let then = expected.focus?.fraction, abs(now - then) > 0.03 { return true }
        if let now = data.focus?.etaSec, let then = expected.focus?.etaSec, abs(now - then) > max(120, then * 0.25) { return true }
        return false
    }

    /// Whether the file is to be believed at `now`. One that says "rendering" and has not been rewritten for
    /// minutes is from an app that is no longer there.
    package func believable(at now: Date) -> Bool {
        switch state {
        case "off", "idle": return true
        default: return now.timeIntervalSince(at) < Self.stale + 900
        }
    }

    /// Made up, for the widget gallery and the pictures in the docs.
    package static func sample(chinese: Bool, at: Date = Date()) -> WidgetData {
        WidgetData(at: at, state: "rendering", active: 2, paused: 0, stalled: 0, queued: 1,
                   focus: Focus(name: "s040_explode", job: chinese ? "产品片 · 主镜头" : "Product film · hero shots", fraction: 0.65, estimate: false, etaSec: 1500, framesDone: 470),
                   shotsDone: 3, shotsTotal: 8, queueEtaSec: 17100, agentsWaiting: 1, agentsWorking: 2, agentsFailed: 0, chinese: chinese)
    }
}
