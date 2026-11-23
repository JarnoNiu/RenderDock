import AppKit
import Foundation
import RenderDockCore

let cli = CommandLine.arguments

if cli.contains("--dump") || cli.contains("--status") {
    // Print the scan result only, without any UI: `--status` as text, `--status --json` as the API's state document.
    let scanner = TaskScanner()
    _ = scanner.scan()
    let sampler = MetricsSampler()
    _ = sampler.sample()
    Thread.sleep(forTimeInterval: 1.2)
    let groups = scanner.scan()
    let m = sampler.sample()
    if cli.contains("--json") {
        print(String(decoding: StateSnapshot.make(groups: groups, metrics: m).json(pretty: true), as: UTF8.self))
        exit(0)
    }
    for g in groups {
        print(L("■ \(g.title)  [\(g.state.label)]  \(g.project) · \(g.script ?? "-") · 已运行 \(Fmt.duration(Date().timeIntervalSince(g.startedAt)))\(g.keepAwake ? " · 防睡眠" : "")", "■ \(g.title)  [\(g.state.label)]  \(g.project) · \(g.script ?? "-") · up \(Fmt.duration(Date().timeIntervalSince(g.startedAt)))\(g.keepAwake ? " · kept awake" : "")"))
        for i in g.items {
            var line = "   - \(i.name)  \(i.state.label)"
            if let d = i.framesDone {
                line += "  \(d)" + (i.framesTotal.map { "/\(i.totalIsEstimate ? "≈" : "")\($0)" } ?? "") + L(" 帧", " frames")
            }
            if let f = i.fraction { line += "  \(Fmt.percent(f))" }
            if let s = i.secPerFrame { line += "  \(Fmt.secPerFrame(s))" }
            if let e = i.eta { line += L("  剩约 \(Fmt.duration(e))", "  ~\(Fmt.duration(e)) left") }
            if let c = i.cpuCores { line += String(format: L("  %.1f 核", "  %.1f cores"), c) }
            if let b = i.memBytes { line += "  \(Fmt.bytes(b))" }
            if let p = i.pid { line += "  pid \(p)" }
            print(line)
        }
    }
    print(String(format: L("CPU %.0f%%  GPU %@  显存 %@  内存 %@/%@（压力 %d）  交换 %@/%@  温度 %@  磁盘剩 %@  %@  防睡眠断言 %@", "CPU %.0f%%  GPU %@  VRAM %@  Memory %@/%@ (pressure %d)  Swap %@/%@  Temp %@  Disk free %@  %@  Sleep assertion %@"),
                 m.cpu * 100,
                 m.gpu.map { String(format: "%.0f%%", $0 * 100) } ?? "-",
                 m.gpuMemBytes.map { Fmt.bytes($0) } ?? "-",
                 Fmt.bytes(m.memUsed), Fmt.bytes(m.memTotal), m.memPressure,
                 Fmt.bytes(m.swapUsed), Fmt.bytes(m.swapTotal),
                 m.tempC.map { String(format: L("%.0f℃（最高 %.0f）", "%.0f°C (max %.0f)"), $0, m.tempMaxC ?? $0) } ?? "-",
                 m.diskFree.map { Fmt.bytes($0) } ?? "-",
                 m.onAC == true ? L("接电源", "on AC") : (m.battery.map { L("电池 \($0)%", "battery \($0)%") } ?? "-"),
                 m.awakeHeld ? L("有", "yes") : L("无", "no")))
    exit(0)
}

if let i = cli.firstIndex(of: "--snapshot"), i + 1 < cli.count {
    // Render the capsule and the panel to PNGs without opening a window: for checking the UI.
    _ = NSApplication.shared
    let dir = cli[i + 1]
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let store = Store()
    // `--at <seconds>` picks the moment of the demo to draw (the demo cycles: at 15 s a session is asking for permission).
    let at = cli.firstIndex(of: "--at").flatMap { $0 + 1 < cli.count ? Double(cli[$0 + 1]) : nil } ?? 7
    if cli.contains("--demo") { store.loadDemo(at) } else { store.loadOnce() }
    store.listMaxHeight = 4000
    let suffix = cli.contains("--demo") ? "-\(Lang.current.rawValue)" : ""
    MainActor.assumeIsolated {
        renderSnapshot(CapsuleView(store: store), to: "\(dir)/capsule\(suffix).png")
        renderSnapshot(PanelView(store: store), to: "\(dir)/panel\(suffix).png")
    }
    exit(0)
}

if let i = cli.firstIndex(of: "--reel"), i + 1 < cli.count {
    // Render the demo reel (PNG frames) for the README GIF.
    _ = NSApplication.shared
    MainActor.assumeIsolated { _ = renderReel(to: cli[i + 1]) }
    exit(0)
}

if let i = cli.firstIndex(of: "--icon"), i + 1 < cli.count {
    _ = NSApplication.shared
    MainActor.assumeIsolated { renderIcon(to: cli[i + 1]) }
    exit(0)
}

if let i = cli.firstIndex(of: "--send"), i + 1 < cli.count {
    // Send a debug command to the running RenderDock.
    DistributedNotificationCenter.default().postNotificationName(debugCommandName, object: cli[i + 1], userInfo: nil, deliverImmediately: true)
    Thread.sleep(forTimeInterval: 0.15)
    exit(0)
}

if let i = cli.firstIndex(of: "--login"), i + 1 < cli.count {
    // Launch at login: on / off / status. Must be run from the copy installed in Applications.
    do {
        switch cli[i + 1] {
        case "on": try LoginItem.set(true)
        case "off": try LoginItem.set(false)
        default: break
        }
        print(LoginItem.statusText)
        exit(0)
    } catch {
        print(L("失败：\(error.localizedDescription)", "Failed: \(error.localizedDescription)"))
        exit(1)
    }
}

// Allow only one instance. A --demo instance may run next to the real one (start it with `open -n`).
if !cli.contains("--demo"), let id = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
