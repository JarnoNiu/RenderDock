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

    // MARK: Hands on (0.4): pausing, letting go, moving out of the way. Every switch is off unless turned on in the menu.

    /// The five switches (see `ControlSettings`). Each is its own; a switch going off undoes what was done under it.
    var handsSettings = ControlSettings(manual: UserDefaults.standard.bool(forKey: "handsPause"), yield: UserDefaults.standard.bool(forKey: "handsYield"),
                                        turns: UserDefaults.standard.bool(forKey: "handsTurns"), pauseOnBattery: UserDefaults.standard.bool(forKey: "handsOnBattery"),
                                        pauseWhenHot: UserDefaults.standard.bool(forKey: "handsWhenHot")) {
        didSet {
            guard handsSettings != oldValue else { return }
            let d = UserDefaults.standard
            d.set(handsSettings.manual, forKey: "handsPause")
            d.set(handsSettings.yield, forKey: "handsYield")
            d.set(handsSettings.turns, forKey: "handsTurns")
            d.set(handsSettings.pauseOnBattery, forKey: "handsOnBattery")
            d.set(handsSettings.pauseWhenHot, forKey: "handsWhenHot")
            hands.settings = handsSettings
            tickHands()
            onChange?()
        }
    }
    /// Goes up whenever something is held, let go or moved, so that what shows it is drawn again.
    private(set) var handsVersion = 0
    /// For the debug hook: as if the Mac were on its battery, or slowed down for heat, whatever it really is.
    @ObservationIgnored var debugOnBattery: Bool?
    @ObservationIgnored var debugHot: Bool?
    @ObservationIgnored private(set) lazy var hands: ControlEngine = makeHands()

    /// Where what is held is remembered, and where what was done is written down.
    static var handsFolder: URL {
        if let path = ProcessInfo.processInfo.environment["RENDERDOCK_HANDS"], !path.isEmpty { return URL(fileURLWithPath: path) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RenderDock")
    }
    static var handsLog: URL { handsFolder.appendingPathComponent("controls.log") }

    private func makeHands() -> ControlEngine {
        // Only the installed app reaches real processes. In demo mode the jobs are made up, so "stopping" one
        // changes nothing but what is shown; and a copy started from a build folder for testing is refused
        // outright, so that no test can ever stop a real render, whatever switches it is started with.
        let actuator: ControlEngine.Actuator
        if demo {
            actuator = ControlEngine.Actuator(pause: { _ in nil }, resume: { _ in nil }, yield: { _, _ in nil })
        } else if Bundle.main.bundlePath.hasSuffix(".app") {
            actuator = .system
        } else {
            actuator = ControlEngine.Actuator(pause: { _ in .refused(0) }, resume: { _ in .refused(0) }, yield: { _, _ in .refused(0) })
        }
        let keep = demo ? nil : Self.handsFolder.appendingPathComponent("controls.json")
        return ControlEngine(settings: handsSettings, actuator: actuator, stateFile: keep, log: { [weak self] line in self?.noteHands(line) })
    }

    /// One line in the log of what was done, with the time. The log is kept to its last few hundred lines.
    private func noteHands(_ line: String) {
        handsLines.append(line)
        if handsLines.count > 50 { handsLines.removeFirst(handsLines.count - 50) }
        guard !demo || ProcessInfo.processInfo.environment["RENDERDOCK_HANDS"] != nil else { return }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let url = Self.handsLog
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        text += "\(stamp.string(from: Date())) \(line)\n"
        let kept = text.split(separator: "\n", omittingEmptySubsequences: true).suffix(400).joined(separator: "\n") + "\n"
        try? kept.write(to: url, atomically: true, encoding: .utf8)
    }
    /// The last lines of that log, for the debug hook.
    @ObservationIgnored private(set) var handsLines: [String] = []

    /// The jobs as the rules see them. In demo mode the processes are made up to match the made-up jobs.
    private var handsJobs: [ControlJob] {
        guard demo else { return groups.map(ControlJob.from) }
        return groups.map { g in
            let working = g.items.filter { $0.pid != nil }
            let stopped = hands.held[g.id] != nil
            return ControlJob(id: g.id, title: g.title, startedAt: g.startedAt.timeIntervalSince1970,
                              active: !stopped && working.contains { $0.state.isActive }, processes: working.compactMap { $0.pid }.map { ProcessRef(pid: $0, startedAt: 1) })
        }
    }

    /// Applies the rules that are on. With every switch off and nothing held, it does not so much as look.
    func tickHands() {
        guard handsSettings.any || !hands.isIdle else { return }
        let before = (hands.held, hands.yielding)
        hands.tick(jobs: handsJobs, onBattery: debugOnBattery ?? (metrics.onAC == false),
                   hot: debugHot ?? (metrics.thermal == .serious || metrics.thermal == .critical))
        if before.0 != hands.held || before.1 != hands.yielding { handsVersion += 1 }
    }

    /// Whether the dock may offer its buttons for this job: it has a render process of its own.
    func canHandle(_ group: RenderGroup) -> Bool { group.items.contains { $0.pid != nil && ($0.state.isActive || $0.state == .paused || $0.state == .stalled) } }
    func holdReasons(_ id: String) -> [HoldReason] { hands.reasons(for: id) }
    func isYielding(_ id: String) -> Bool { hands.isYielding(id) }

    func pauseJob(_ id: String) {
        guard let job = handsJobs.first(where: { $0.id == id }) else { return }
        hands.pause(job)
        handsVersion += 1
        onChange?()
    }

    func resumeJob(_ id: String) {
        guard let job = handsJobs.first(where: { $0.id == id }) else { return }
        hands.resume(job)
        handsVersion += 1
        onChange?()
    }

    func toggleYield(_ id: String) {
        guard let job = handsJobs.first(where: { $0.id == id }) else { return }
        hands.setYielding(job, !hands.isYielding(id))
        handsVersion += 1
        onChange?()
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

    /// Why the display could not be given a network, in words for the user.
    enum WiFiProblem: Error {
        case notLinked, noNetwork, noAPI

        var text: String {
            switch self {
            case .notLinked: return L("小屏现在没有通过蓝牙加密连着。先让它连上再试。", "The display is not on an encrypted Bluetooth link right now. Connect it first.")
            case .noNetwork: return L("这台电脑现在没有连着网络，没有地址可以告诉小屏。", "This Mac is not on a network right now, so there is no address to give the display.")
            case .noAPI: return L("本机接口没能启动，小屏没有地方可读。", "The local API did not start, so the display would have nowhere to read from.")
            }
        }
    }

    /// Gives the desk display a network to join and this Mac's place on it, over the encrypted Bluetooth link,
    /// so that it can go on showing things where Bluetooth does not reach. The display reads the API, so the API
    /// and access to it from the network (with the token) are switched on if they were off. The password is
    /// passed on to the display and kept nowhere on this Mac.
    func giveDeviceWiFi(ssid: String, password: String, done: @escaping (WiFiProblem?) -> Void) {
        guard !demo, device.secure else { return done(.notLinked) }
        guard let address = LocalAPIServer.networkAddresses().first else { return done(.noNetwork) }
        if !apiEnabled { apiEnabled = true }
        if !lanEnabled { lanEnabled = true }
        // The port is known a moment after the API starts listening.
        var tries = 0
        func send() {
            guard let port = apiPort, api.lanOpen else {
                tries += 1
                guard tries < 25 else { return done(.noAPI) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { send() }
                return
            }
            let host = Self.nameOnTheNetwork(or: address)
            let line = BuddyProtocol.wifi(ssid: ssid, password: password, host: host, ip: address, port: port, token: apiToken)
            guard device.sendSettings(line) else { return done(.notLinked) }
            UserDefaults.standard.set(device.identifier, forKey: Self.wifiGivenKey)
            placeTold = Self.place(host: host, address: address, port: port, token: apiToken)
            done(nil)
        }
        send()
    }

    /// Asks the display which networks it can see from where it stands. Answers once: the list as the display
    /// gave it, or nil if it is not on the encrypted link or said nothing for twelve seconds.
    func lookForNetworks(done: @escaping ([BuddyProtocol.SeenNetwork]?) -> Void) {
        guard !demo, device.secure else { return done(nil) }
        var answered = false
        func answer(_ list: [BuddyProtocol.SeenNetwork]?) {
            guard !answered else { return }
            answered = true
            device.onNetworks = nil
            done(list)
        }
        device.onNetworks = { list in answer(list) }
        guard device.sendSettings(BuddyProtocol.wifiScan) else { return answer(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { answer(nil) }
    }

    /// Has the display forget the network it was given. (The API and its switches are left as they are.)
    @discardableResult
    func forgetDeviceWiFi() -> Bool {
        guard !demo, device.sendSettings(BuddyProtocol.wifiOff) else { return false }
        UserDefaults.standard.removeObject(forKey: Self.wifiGivenKey)
        placeTold = nil
        return true
    }

    /// Which display this Mac gave a network to (as macOS knows it here): only that one is told where the Mac is.
    private static let wifiGivenKey = "deviceWiFiGivenTo"
    /// Where the display was last told this Mac is, on this connection: said again only when it has changed.
    @ObservationIgnored private var placeTold: String?
    private static func place(host: String, address: String, port: UInt16, token: String) -> String { "\(host) \(address) \(port) \(token)" }
    private static func nameOnTheNetwork(or address: String) -> String {
        let name = ProcessInfo.processInfo.hostName
        return name.hasSuffix(".local") ? name : address
    }

    /// A display that reads over Wi-Fi was told where this Mac is when it was set up. The address, the port and
    /// the token can all change afterwards (a new token above all). Whenever the display this Mac set up is on
    /// the encrypted Bluetooth link, it is told again if any of them differs: without the network's password,
    /// which RenderDock does not have. Nothing is sent while the network may not reach the API.
    func refreshDevicePlace() {
        guard !demo else { return }
        guard device.secure else { placeTold = nil; return }
        guard (device.wifi ?? 0) > 0, apiEnabled, lanEnabled, api.lanOpen, let port = apiPort,
              let given = UserDefaults.standard.string(forKey: Self.wifiGivenKey), given == device.identifier,
              let address = LocalAPIServer.networkAddresses().first else { return }
        let host = Self.nameOnTheNetwork(or: address)
        let place = Self.place(host: host, address: address, port: port, token: apiToken)
        guard place != placeTold else { return }
        if device.sendSettings(BuddyProtocol.wifiPlace(host: host, ip: address, port: port, token: apiToken)) { placeTold = place }
    }
    @ObservationIgnored let device = DeviceLink()

    private func applyDevice() {
        guard !demo else { return }
        if deviceEnabled {
            device.onStatus = { [weak self] in
                guard let self else { return }
                self.deviceStatus = self.device.status
                self.refreshDevicePlace()
                self.onChange?()
            }
            device.onReady = { [weak self] in
                self?.sendToDevice()
                self?.sendMacToDevice(now: true)   // the device has just said what it understands, or the link has just become encrypted
            }
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
                                                                           offerRequests: deviceAnswers, pages: device.pages)))
    }

    /// This Mac's own numbers, for a device with a page for them. They are measured every two seconds; the device
    /// is told every four at most, and only what has changed (the link leaves out a line it has just sent).
    @ObservationIgnored private var macSentAt = Date.distantPast
    private func sendMacToDevice(now: Bool = false) {
        guard deviceEnabled, !demo, device.isConnected, device.pages else { return }
        guard now || Date().timeIntervalSince(macSentAt) >= 4 else { return }
        macSentAt = Date()
        device.sendMac(BuddyProtocol.mac(metrics, cores: ProcessInfo.processInfo.activeProcessorCount))
    }

    @ObservationIgnored private let scanner = TaskScanner()
    @ObservationIgnored private let sampler = MetricsSampler()
    @ObservationIgnored private let awake = AwakeHolder()
    @ObservationIgnored private let work = DispatchQueue(label: "renderdock.scan", qos: .utility)
    @ObservationIgnored private var timers: [Timer] = []
    @ObservationIgnored private var thumbSource: [String: String] = [:]
    @ObservationIgnored private var scanning = false
    @ObservationIgnored var onChange: (() -> Void)?
    /// A shot's thumbnail was clicked: open the larger look at its frames.
    @ObservationIgnored var onPreview: ((RenderItem) -> Void)?

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
    /// Whether the API may also be reached from the local network. Off by default, a switch of its own, and it
    /// does nothing while the API itself is off. From the network every request needs the token.
    var lanEnabled = UserDefaults.standard.bool(forKey: "lanAPI") {
        didSet {
            UserDefaults.standard.set(lanEnabled, forKey: "lanAPI")
            api.setLAN(lanEnabled, token: lanEnabled ? apiToken : nil)
            onChange?()
        }
    }
    /// The token a device on the network has to show. Made the first time it is needed, kept in a file only
    /// this user can read.
    var apiToken: String { LocalAPIServer.token(at: LocalAPIServer.tokenFile) }
    /// A new token: whatever was using the old one is shut out from that moment.
    func renewAPIToken() {
        let fresh = LocalAPIServer.token(at: LocalAPIServer.tokenFile, renew: true)
        api.setLAN(lanEnabled, token: lanEnabled ? fresh : nil)
        refreshDevicePlace()   // a display reading over Wi-Fi would be shut out by the new token
        onChange?()
    }
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
            api.start(discovery: CommandLine.arguments.contains("--demo") ? nil : LocalAPIServer.discoveryFile,
                      lan: lanEnabled, token: lanEnabled ? apiToken : nil)
            publish()
        } else {
            api.stop()
        }
    }

    /// Hand the latest state to the API. The detector runs on every scan so it always has the previous one.
    func publish(outcomes: [String: JobOutcome] = [:]) {
        tickHands()
        let events = detector.update(groups, now: now, outcomes: outcomes)
        notifier.handle(events)
        sendToDevice()
        mqtt?.publish(state: snapshot(now: now))
        guard apiEnabled else { return }
        api.publish(state: snapshot(now: now).json(), events: events)
        publishForWiFi(now: now)
    }

    /// What a display reading over Wi-Fi is sent. Not worked out while none is reading.
    private func publishForWiFi(now: Date) {
        guard apiEnabled, api.deviceCount > 0 else { return }
        // This Mac's own numbers go with it, every three seconds at most (they change at every look).
        var mac: Data?
        if now.timeIntervalSince(macForWiFiAt) >= 3 {
            macForWiFiAt = now
            mac = BuddyProtocol.mac(metrics, cores: ProcessInfo.processInfo.activeProcessorCount)
        }
        api.publish(deviceSnapshot: BuddyProtocol.heartbeat(state: snapshot(now: now), requests: requests, inbox: inbox, options: .overWiFi, now: now).line(),
                    deviceMac: mac)
    }
    @ObservationIgnored private var macForWiFiAt = Date.distantPast

    /// Hand the state to the API again after something other than a job scan changed it, with what happened to the agents.
    private func publishState(events: [RenderEvent] = []) {
        notifier.handle(events)
        sendToDevice()
        mqtt?.publish(state: snapshot(now: Date()))
        guard apiEnabled else { return }
        api.publish(state: snapshot(now: Date()).json(), events: events)
        publishForWiFi(now: Date())
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
        // Nothing RenderDock stopped stays stopped once it is gone, and nothing it moved stays moved.
        if !hands.isIdle { hands.releaseEverything(why: "RenderDock is quitting") }
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
        sendMacToDevice()
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
        let watts = metrics.powerW   // read here, on the main queue, for the scan below
        work.async { [weak self] in
            guard let self else { return }
            var g = self.scanner.scan()
            let ended = self.scanner.lastEnded   // how jobs that just disappeared ended, where a wrapper recorded it
            // Remember what was seen, and use what is remembered: queue estimates and the recent list.
            self.history?.record(g, outcomes: ended, powerW: watts)
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
