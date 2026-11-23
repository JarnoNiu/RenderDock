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
    /// Notifications on this Mac and through the channels in notify.json.
    @ObservationIgnored let notifier = Notifier()

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
        guard apiEnabled else { return }
        api.publish(state: StateSnapshot.make(groups: groups, metrics: metrics, now: now).json(), events: events)
    }

    /// Release the port and the discovery file before the app exits.
    func shutdown() {
        if apiEnabled { api.stop() }
    }

    static let historyLength = 60

    /// Rescan right away (used when the panel expands).
    func refreshNow() { if !demo { scanTasks() } }

    /// Demo mode: fictional jobs and metrics, nothing is read from the machine.
    @ObservationIgnored private(set) var demo = false

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
        sampleMetrics()
        scanTasks()
        timers.append(Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.sampleMetrics() })
        // Scan jobs every 3 s while expanded, every 6 s while collapsed
        timers.append(Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            // …and every 3 s while something is listening on the event stream
            let lively = self.expanded || (self.apiEnabled && self.api.streamCount > 0)
            if Date().timeIntervalSince(self.now) >= (lively ? 2.9 : 5.9) { self.scanTasks() }
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
        let g = scanner.scan()
        groups = g
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
            let g = self.scanner.scan()
            let ended = self.scanner.lastEnded   // how jobs that just disappeared ended, where a wrapper recorded it
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

    /// Jobs are rendering, but nothing is keeping the Mac awake.
    var sleepRisk: Bool { groups.activeCount > 0 && !metrics.awakeHeld }
}
