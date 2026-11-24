import AppKit
import ImageIO
import Observation
import SwiftUI
import RenderDockCore

/// Which corner of the window the panel expands from.
struct Anchor: Equatable {
    enum H: String { case left, center, right }
    enum V: String { case top, bottom }
    var h: H
    var v: V

    var unitPoint: UnitPoint {
        UnitPoint(x: h == .left ? 0 : (h == .center ? 0.5 : 1), y: v == .top ? 0 : 1)
    }

    var alignment: Alignment {
        switch (h, v) {
        case (.left, .top): return .topLeading
        case (.center, .top): return .top
        case (.right, .top): return .topTrailing
        case (.left, .bottom): return .bottomLeading
        case (.center, .bottom): return .bottom
        case (.right, .bottom): return .bottomTrailing
        }
    }
}

@Observable
final class Store {
    var groups: [RenderGroup] = []
    /// The shots that ended most recently, newest first.
    var recentRuns: [HistoryRun] = []
    var metrics = Metrics()
    var cpuHistory: [Double] = []
    var gpuHistory: [Double] = []
    var memHistory: [Double] = []
    var tempHistory: [Double] = []
    /// Shot id → thumbnail of its latest frame
    var thumbs: [String: NSImage] = [:]
    var expanded = false
    var pinned = false
    var anchor = Anchor(h: .right, v: .top)
    var now = Date()
    var scanned = false
    /// Maximum height of the job list (depends on the screen it is on)
    var listMaxHeight: CGFloat = 420
    /// Natural height of the job list content (measured before expanding; follows the content afterwards)
    var listContentHeight: CGFloat = 0
    var keepAwakeWhileRendering = UserDefaults.standard.bool(forKey: "keepAwakeWhileRendering") {
        didSet {
            UserDefaults.standard.set(keepAwakeWhileRendering, forKey: "keepAwakeWhileRendering")
            updateAwake()
        }
    }

    // MARK: Coding agents' sessions (read-only; on unless switched off in the menu)

    /// Sessions of coding agents on this Mac, most urgent first.
    var agents: [AgentSession] = []
    var agentsEnabled = (UserDefaults.standard.object(forKey: "showAgents") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(agentsEnabled, forKey: "showAgents")
            if agentsEnabled { scanAgents() } else {
                agents = []
                agentDetector = AgentEventDetector()   // start afresh: nothing is announced when it is switched back on
            }
            publishState()
            onChange?()
        }
    }
    /// Show each session's own name in the panel. Names stay on this Mac either way.
    var agentTitles = (UserDefaults.standard.object(forKey: "agentTitles") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(agentTitles, forKey: "agentTitles")
            onChange?()
        }
    }
    @ObservationIgnored private let agentScanner = AgentScanner()
    @ObservationIgnored private let agentWork = DispatchQueue(label: "renderdock.agents", qos: .utility)
    @ObservationIgnored private var scanningAgents = false
    @ObservationIgnored private var lastAgentScan = Date.distantPast
    @ObservationIgnored private var agentDetector = AgentEventDetector()

    // MARK: Answering agents (off unless switched on in the menu or with `--control`)

    /// Requests from agents that are waiting for an answer here, oldest first.
    var requests: [ControlRequest] = []
    /// Whether RenderDock takes agents' permission requests at all. Off by default. Even when it is on, an
    /// agent only asks here if the user has put the hook into that agent's settings themselves.
    var controlEnabled = UserDefaults.standard.bool(forKey: "answerAgents") || CommandLine.arguments.contains("--control") {
        didSet {
            UserDefaults.standard.set(controlEnabled, forKey: "answerAgents")
            applyControl()
            onChange?()
        }
    }
    @ObservationIgnored private let broker = ControlBroker()
    /// The switch is on and the listener could not be started (the menu says so, instead of looking fine).
    var controlFailed = false
    /// When the cards in the panel last changed places. A click that lands just after is not taken: the card
    /// under the pointer may not be the one that was read.
    @ObservationIgnored private var cardsMovedAt = Date.distantPast
    private static let cardsSettle: TimeInterval = 0.6

    private func applyControl() {
        guard !demo else { return }
        if controlEnabled {
            broker.onChange = { [weak self] in
                guard let self else { return }
                let pending = self.broker.pending
                if pending.map(\.id) != self.requests.map(\.id) { self.cardsMovedAt = Date() }
                self.requests = pending
                self.now = Date()
                self.sendToDevice()
                self.onChange?()
            }
            controlFailed = !broker.start()
        } else {
            broker.stop()
            requests = []
            controlFailed = false
        }
    }

    /// The user's answer to one request, from the panel.
    func answer(_ id: String, _ decision: ControlDecision) {
        if demo {
            requests.removeAll { $0.id == id }
            onChange?()
        } else if Date().timeIntervalSince(cardsMovedAt) >= Self.cardsSettle {
            broker.decide(id: id, decision, source: "panel")
        }
    }

    // MARK: The entry for other programs (off unless switched on in the menu or with `--inbox`)

    /// Notices, tasks and questions other programs have sent through `renderdock notify|progress|ask`.
    var inbox = InboxView.empty
    /// Whether RenderDock takes them at all. Off by default: until it is on, nothing listens and the commands
    /// say so and exit.
    var inboxEnabled = UserDefaults.standard.bool(forKey: "agentInbox") || CommandLine.arguments.contains("--inbox") {
        didSet {
            UserDefaults.standard.set(inboxEnabled, forKey: "agentInbox")
            applyInbox()
            onChange?()
        }
    }
    @ObservationIgnored private let inboxServer = InboxServer()
    var inboxFailed = false

    private func applyInbox() {
        guard !demo else { return }
        if inboxEnabled {
            inboxServer.onChange = { [weak self] in
                guard let self else { return }
                let view = self.inboxServer.view
                if view.questions.map(\.id) != self.inbox.questions.map(\.id) { self.cardsMovedAt = Date() }
                self.inbox = view
                self.now = Date()
                self.sendToDevice()
                self.onChange?()
            }
            // A new notice or question is announced on this Mac (if notifications here are on), never further.
            inboxServer.onArrival = { [weak self] notice, question in
                guard let self else { return }
                if let notice { self.notifier.inbox(title: notice.title, body: notice.body, from: notice.from) }
                if let question { self.notifier.inbox(title: L("有个问题在等你回答", "A question is waiting for you"), body: question.text, from: question.from) }
            }
            inboxFailed = !inboxServer.start()
        } else {
            inboxServer.stop()
            inbox = .empty
            inboxFailed = false
        }
    }

    /// The user's pick for a question, from the panel.
    func answerQuestion(_ id: String, _ index: Int) {
        if demo {
            inbox.questions.removeAll { $0.id == id }
            demoQuestionAnswered = true
            onChange?()
        } else if Date().timeIntervalSince(cardsMovedAt) >= Self.cardsSettle {
            inboxServer.answer(id: id, index: index)
        }
    }

    func dismissQuestion(_ id: String) {
        if demo {
            inbox.questions.removeAll { $0.id == id }
            demoQuestionAnswered = true
            onChange?()
        } else {
            inboxServer.dismissQuestion(id)
        }
    }

    func dismissNotice(_ id: String) {
        if demo { inbox.notices.removeAll { $0.id == id }; onChange?() } else { inboxServer.dismissNotice(id) }
    }

    func dismissTask(_ id: String) {
        if demo { inbox.tasks.removeAll { $0.id == id }; onChange?() } else { inboxServer.dismissTask(id) }
    }

    // MARK: A device on the desk (off unless switched on in the menu)

    /// Whether RenderDock looks for a Bluetooth device and feeds it. Off by default; switching it on is what
    /// makes macOS ask for Bluetooth permission.
    var deviceEnabled = UserDefaults.standard.bool(forKey: "deviceLink") {
        didSet {
            UserDefaults.standard.set(deviceEnabled, forKey: "deviceLink")
            applyDevice()
            onChange?()
        }
    }
    /// The device can draw text beyond ASCII (the reference firmware cannot).
    var deviceUnicode = UserDefaults.standard.bool(forKey: "deviceUnicode") {
        didSet {
            UserDefaults.standard.set(deviceUnicode, forKey: "deviceUnicode")
            sendToDevice()
        }
    }
    /// Whether an agent's permission request may be answered on the device. Off by default, and separate from
    /// the link itself: a device can show what is going on without being a place where things are approved.
    /// (Questions from other programs are not approvals and do not depend on this.)
    var deviceAnswers = UserDefaults.standard.bool(forKey: "deviceAnswers") {
        didSet {
            UserDefaults.standard.set(deviceAnswers, forKey: "deviceAnswers")
            sendToDevice()
            onChange?()
        }
    }
    var deviceStatus = DeviceLink.Status.off
    @ObservationIgnored let device = DeviceLink()

    private func applyDevice() {
        guard !demo else { return }
        if deviceEnabled {
            device.onStatus = { [weak self] in
                guard let self else { return }
                self.deviceStatus = self.device.status
                self.onChange?()
            }
            device.onReady = { [weak self] in self?.sendToDevice() }
            // An answer from the device goes through the same broker as one from the panel: it must be for a
            // request that may be allowed from a display, it counts once, and it is written to the record.
            device.onAnswer = { [weak self] id, decision in
                guard let self, self.deviceAnswers else { return }
                self.broker.decide(id: id, decision, source: "device")
            }
            // A pick for another program's question goes to that program and nowhere else.
            device.onChoice = { [weak self] id, index in self?.inboxServer.answer(id: id, index: index) }
            device.start()
        } else {
            device.stop()
            deviceStatus = .off
        }
    }

    /// Hands the device the current snapshot. What it gets depends on whether the link is encrypted.
    private func sendToDevice() {
        guard deviceEnabled, !demo, device.isConnected else { return }
        device.send(BuddyProtocol.heartbeat(state: snapshot(now: Date()), requests: requests, inbox: inbox,
                                            options: BuddyProtocol.Options(secure: device.secure, unicode: deviceUnicode || device.unicode,
                                                                           extended: device.extended, inbox: device.inbox,
                                                                           offerRequests: deviceAnswers)))
    }

    @ObservationIgnored private let scanner = TaskScanner()
    @ObservationIgnored private let sampler = MetricsSampler()
    @ObservationIgnored private let awake = AwakeHolder()
    @ObservationIgnored private let work = DispatchQueue(label: "renderdock.scan", qos: .utility)
    @ObservationIgnored private var timers: [Timer] = []
    @ObservationIgnored private var thumbSource: [String: String] = [:]
    @ObservationIgnored private var scanning = false
    @ObservationIgnored var onChange: (() -> Void)?

    // MARK: Local API (off unless switched on in the menu, with `--api`, or `defaults write … localAPI -bool true`)

    /// The local read-only API on 127.0.0.1. Off by default: nothing listens unless you ask for it.
    var apiEnabled = UserDefaults.standard.bool(forKey: "localAPI") || CommandLine.arguments.contains("--api") {
        didSet {
            UserDefaults.standard.set(apiEnabled, forKey: "localAPI")
            applyAPI()
        }
    }
    /// The port the API is listening on, once it is up.
    var apiPort: UInt16?
    @ObservationIgnored private let api = LocalAPIServer()
    @ObservationIgnored private var detector = EventDetector()
    /// What RenderDock remembers. Only ever touched on the scan queue. Nil if the file cannot be opened.
    @ObservationIgnored private lazy var history: HistoryStore? = HistoryStore()
    /// Notifications on this Mac and through the channels in notify.json.
    @ObservationIgnored let notifier = Notifier()

    // MARK: MQTT (off unless mqtt.json names a broker and says "enabled": true)

    /// What the menu says about the MQTT connection. Nil when there are no settings, or they are switched off.
    var mqttStatus: String?
    @ObservationIgnored private var mqtt: MQTTClient?
    @ObservationIgnored private var mqttSettings: MQTTSettings?
    @ObservationIgnored private var mqttChecked = Date.distantPast

    /// Reads the settings file again, and connects, reconnects or disconnects to match it. The file is looked
    /// at every few seconds, so a change takes effect without restarting.
    private func applyMQTT() {
        guard !demo else { return }
        mqttChecked = Date()
        let wanted = MQTTSettings.load().flatMap { $0.enabled ? $0 : nil }
        guard wanted != mqttSettings else { return }
        mqtt?.stop()
        mqtt = nil
        mqttSettings = wanted
        mqttStatus = nil
        if let wanted {
            let client = MQTTClient(settings: wanted, version: StateSnapshot.appVersion)
            client.onStatus = { [weak self] status in
                guard let self, self.mqtt === client else { return }
                switch status {
                case .connecting: self.mqttStatus = L("正在连接 \(wanted.host)…", "Connecting to \(wanted.host)…")
                case .connected: self.mqttStatus = L("已连接 \(wanted.host)", "Connected to \(wanted.host)")
                case .failed(let why): self.mqttStatus = L("连不上 \(wanted.host)：\(why)", "Cannot reach \(wanted.host): \(why)")
                case .stopped: self.mqttStatus = nil
                }
                self.onChange?()
            }
            mqtt = client
            client.start()
            client.publish(state: snapshot(now: Date()))
        }
        onChange?()
    }

    /// Opens the settings file in the default editor, creating it from the template (owner-only: it may hold a password).
    func openMQTTSettings() {
        let url = MQTTSettings.file
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data(MQTTSettings.template.utf8), attributes: [.posixPermissions: 0o600])
        }
        NSWorkspace.shared.open(url)
    }

    private func applyAPI() {
        if apiEnabled {
            api.onPortChange = { [weak self] port in
                self?.apiPort = port
                self?.onChange?()
            }
            // A --demo instance never overwrites the discovery file of the real one.
            api.start(discovery: CommandLine.arguments.contains("--demo") ? nil : LocalAPIServer.discoveryFile)
            publish()
        } else {
            api.stop()
        }
    }

    /// Hand the latest state to the API. The detector runs on every scan so it always has the previous one.
    func publish(outcomes: [String: JobOutcome] = [:]) {
        let events = detector.update(groups, now: now, outcomes: outcomes)
        notifier.handle(events)
        sendToDevice()
        mqtt?.publish(state: snapshot(now: now))
        guard apiEnabled else { return }
        api.publish(state: snapshot(now: now).json(), events: events)
    }

    /// Hand the state to the API again after something other than a job scan changed it, with what happened to the agents.
    private func publishState(events: [RenderEvent] = []) {
        notifier.handle(events)
        sendToDevice()
        mqtt?.publish(state: snapshot(now: Date()))
        guard apiEnabled else { return }
        api.publish(state: snapshot(now: Date()).json(), events: events)
    }

    /// Demo mode: run the made-up sessions through the detector, so the event stream shows agent events too.
    func publishAgentEvents(now: Date) {
        let events = agentDetector.update(agents, now: now)
        if !events.isEmpty { publishState(events: events) }
    }

    /// The state document as it stands. A render that ended a few minutes ago still counts towards the overall state.
    private func snapshot(now: Date) -> StateSnapshot {
        StateSnapshot.make(groups: groups, metrics: metrics, agents: agents, recent: recentRuns, now: now)
    }

    /// Release the port and the discovery file before the app exits.
    func shutdown() {
        if apiEnabled { api.stop() }
        if controlEnabled { broker.stop() }   // release anything waiting, so the agents ask in their own windows
        if inboxEnabled { inboxServer.stop() }   // whoever is waiting for an answer is told there will be none
        mqtt?.stop()   // says "offline" on the way out
        if deviceEnabled { device.stop() }
    }

    static let historyLength = 60

    /// Rescan right away (used when the panel expands).
    func refreshNow() {
        guard !demo else { return }
        scanTasks()
        scanAgents()
    }

    /// Look at the agents' sessions, off the main thread. They are read, never changed.
    private func scanAgents() {
        guard agentsEnabled, !demo, !scanningAgents else { return }
        scanningAgents = true
        lastAgentScan = Date()
        agentWork.async { [weak self] in
            guard let self else { return }
            let found = self.agentScanner.scan()
            DispatchQueue.main.async {
                self.scanningAgents = false
                guard self.agentsEnabled else { return }
                // The detector sees every scan, changed or not: a wait is announced only once it has lasted a while.
                let events = self.agentDetector.update(found)
                let changed = found != self.agents
                if changed { self.agents = found }
                if changed || !events.isEmpty { self.publishState(events: events) }
                if changed { self.onChange?() }
            }
        }
    }

    /// Demo mode: fictional jobs and metrics, nothing is read from the machine.
    @ObservationIgnored private(set) var demo = false
    /// Demo mode, for checking layout: push every readout to its widest (see `applyStress`).
    @ObservationIgnored var stress = false
    /// Demo mode: the made-up requests of this cycle have been shown already.
    @ObservationIgnored var demoAnswered = false
    /// Demo mode: the made-up question of this cycle has been answered or dismissed.
    @ObservationIgnored var demoQuestionAnswered = false

    func startDemo() {
        demo = true
        if apiEnabled { applyAPI() }
        let began = Date()
        loadDemo(0)
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.loadDemo(Date().timeIntervalSince(began))
        }
        RunLoop.main.add(timer, forMode: .common)
        timers.append(timer)
    }

    func start() {
        if apiEnabled { applyAPI() }
        if controlEnabled { applyControl() }
        if inboxEnabled { applyInbox() }
        if deviceEnabled { applyDevice() }
        applyMQTT()
        work.async { [weak self] in self?.history?.prune() }
        sampleMetrics()
        scanTasks()
        scanAgents()
        timers.append(Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.sampleMetrics() })
        // Scan jobs every 3 s while expanded, every 6 s while collapsed
        timers.append(Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            // …and every 3 s while something is listening on the event stream
            let lively = self.expanded || (self.apiEnabled && self.api.streamCount > 0)
            if Date().timeIntervalSince(self.now) >= (lively ? 2.9 : 5.9) { self.scanTasks() }
            if Date().timeIntervalSince(self.lastAgentScan) >= (lively ? 2.9 : 5.9) { self.scanAgents() }
            if Date().timeIntervalSince(self.mqttChecked) >= 5 { self.applyMQTT() }
        })
        timers.forEach { RunLoop.main.add($0, forMode: .common) }
    }

    /// Sample everything once, synchronously (for still snapshots).
    func loadOnce() {
        _ = scanner.scan()
        _ = sampler.sample()
        for i in 0..<8 {
            Thread.sleep(forTimeInterval: 0.25)
            apply(sampler.sample())
            if i == 3 { _ = scanner.scan() }
        }
        var g = scanner.scan()
        for i in g.indices { g[i].queueETA = history?.queueETA(for: g[i]) }
        recentRuns = history?.recent(limit: 4) ?? []
        groups = g
        agents = agentsEnabled ? agentScanner.scan() : []
        scanned = true
        now = Date()
        for item in g.allItems {
            if let path = item.latestFrame, let img = Self.thumbnail(path) { thumbs[item.id] = img }
        }
    }

    private func sampleMetrics() {
        work.async { [weak self] in
            guard let self else { return }
            let m = self.sampler.sample()
            DispatchQueue.main.async { self.apply(m) }
        }
    }

    private func apply(_ m: Metrics) {
        metrics = m
        push(&cpuHistory, m.cpu)
        push(&gpuHistory, m.gpu ?? 0)
        push(&memHistory, m.memFraction)
        push(&tempHistory, m.tempC.map { min(1, max(0, ($0 - 30) / 75)) } ?? 0)
    }

    private func push(_ a: inout [Double], _ v: Double) {
        a.append(v)
        if a.count > Self.historyLength { a.removeFirst(a.count - Self.historyLength) }
    }

    private func scanTasks() {
        guard !scanning else { return }
        scanning = true
        work.async { [weak self] in
            guard let self else { return }
            var g = self.scanner.scan()
            let ended = self.scanner.lastEnded   // how jobs that just disappeared ended, where a wrapper recorded it
            // Remember what was seen, and use what is remembered: queue estimates and the recent list.
            self.history?.record(g, outcomes: ended)
            for i in g.indices { g[i].queueETA = self.history?.queueETA(for: g[i]) }
            let recent = self.history?.recent(limit: 50) ?? []
            // Rebuild a thumbnail only when the latest frame has changed
            var fresh: [String: NSImage] = [:]
            var sources: [String: String] = [:]
            for item in g.allItems {
                guard let path = item.latestFrame else { continue }
                sources[item.id] = path
                if self.thumbSource[item.id] != path, let img = Self.thumbnail(path) { fresh[item.id] = img }
            }
            DispatchQueue.main.async {
                self.scanning = false
                self.groups = g
                self.recentRuns = Array(recent.prefix(4))
                if self.apiEnabled { self.api.publish(history: recent) }
                self.scanned = true
                self.now = Date()
                var t = self.thumbs.filter { sources[$0.key] != nil }
                for (id, img) in fresh {
                    t[id] = img
                    self.thumbSource[id] = sources[id]
                }
                self.thumbSource = self.thumbSource.filter { sources[$0.key] != nil }
                self.thumbs = t
                self.updateAwake()
                self.publish(outcomes: ended)
                self.onChange?()
            }
        }
    }

    private func updateAwake() {
        awake.set(keepAwakeWhileRendering && groups.activeCount > 0)
    }

    static func thumbnail(_ path: String, maxPixel: Int = 220) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // MARK: Summaries for the UI

    var summary: String {
        let g = groups
        var parts: [String] = []
        if g.activeCount > 0 { parts.append(L("\(g.activeCount) 段在渲", "\(g.activeCount) rendering")) }
        if g.stalledCount > 0 { parts.append(L("\(g.stalledCount) 段可能卡住", "\(g.stalledCount) stalled")) }
        if g.pausedCount > 0 { parts.append(L("\(g.pausedCount) 段暂停", "\(g.pausedCount) paused")) }
        if g.waitingCount > 0 { parts.append(L("\(g.waitingCount) 条排队", "\(g.waitingCount) queued")) }
        return parts.isEmpty ? L("没有渲染任务", "No render jobs") : parts.joined(separator: " · ")
    }

    /// One line about the agents' sessions, or nil when there is nothing to say.
    var agentSummary: String? {
        let a = agents
        var parts: [String] = []
        if a.count(.error) > 0 { parts.append(L("\(a.count(.error)) 个出错", "\(a.count(.error)) failed")) }
        if a.count(.waiting) > 0 { parts.append(L("\(a.count(.waiting)) 个等你", "\(a.count(.waiting)) need you")) }
        if a.count(.working) > 0 { parts.append(L("\(a.count(.working)) 个在干活", "\(a.count(.working)) working")) }
        if a.count(.done) > 0 { parts.append(L("\(a.count(.done)) 个刚做完", "\(a.count(.done)) just finished")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Sessions that are waiting for the user, or failed: the ones worth an interruption.
    var agentsNeedingYou: [AgentSession] { agents.filter { $0.state == .waiting || $0.state == .error } }

    /// Jobs are rendering, but nothing is keeping the Mac awake.
    var sleepRisk: Bool { groups.activeCount > 0 && !metrics.awakeHeld }
}
