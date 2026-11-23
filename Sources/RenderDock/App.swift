import AppKit
import SwiftUI
import RenderDockCore

/// Menu bar item: a small progress ring plus the number of shots rendering; its menu lists the jobs and a few toggles.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store: Store
    private weak var panel: PanelController?
    private var lastKey = ""

    init(store: Store, panel: PanelController) {
        self.store = store
        self.panel = panel
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.button?.imagePosition = .imageLeading
        update()
    }

    func update() {
        let groups = store.groups
        let active = groups.activeCount
        let fraction = groups.focusItem?.fraction
        let key = "\(active)|\(fraction.map { Int($0 * 40) } ?? -1)|\(groups.pausedCount)|\(groups.stalledCount)"
        guard key != lastKey else { return }
        lastKey = key
        item.button?.image = Self.ringImage(fraction: fraction, active: active > 0, paused: active == 0 && groups.pausedCount > 0)
        item.button?.attributedTitle = NSAttributedString(
            string: active > 0 ? " \(active)" : "",
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
        item.button?.toolTip = L("渲染坞：\(store.summary)", "RenderDock: \(store.summary)")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let head = NSMenuItem(title: store.summary, action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        for g in store.groups.prefix(12) {
            var line = "\(g.title) — \(g.state.label)"
            if g.items.count > 1 { line += L("  \(g.doneCount)/\(g.items.count) 段", "  \(g.doneCount)/\(g.items.count) shots") }
            if let i = g.activeItems.first {
                if let f = i.fraction { line += "  \(i.totalIsEstimate ? "≈" : "")\(Fmt.percent(f))" }
                else if let d = i.framesDone { line += L("  \(d) 帧", "  \(d) frames") }
            }
            let mi = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            mi.isEnabled = false
            mi.indentationLevel = 1
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        add(menu, store.expanded ? L("收起面板", "Collapse Panel") : L("展开面板", "Expand Panel"), #selector(togglePanel))
        add(menu, L("显示悬浮胶囊", "Show Floating Capsule"), #selector(toggleCapsule), on: panel?.isVisible == true)
        add(menu, L("回到右上角", "Move to Top-Right"), #selector(resetPosition))
        menu.addItem(.separator())
        add(menu, L("渲染时保持唤醒", "Keep Awake While Rendering"), #selector(toggleAwake), on: store.keepAwakeWhileRendering)
        let where_ = store.apiPort.map { "（127.0.0.1:\($0)）" } ?? ""
        let whereEn = store.apiPort.map { " (127.0.0.1:\($0))" } ?? ""
        add(menu, L("本机接口\(where_)", "Local API\(whereEn)"), #selector(toggleAPI), on: store.apiEnabled)

        // Notifications
        let notify = NSMenuItem(title: L("通知", "Notifications"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        add(sub, L("在这台 Mac 上通知", "Notify on This Mac"), #selector(toggleSystemNotifications), on: store.notifier.systemEnabled)
        let channels = store.notifier.activeChannels
        let info = NSMenuItem(title: channels.isEmpty
            ? L("手机推送：还没有设置", "Phone push: not set up")
            : L("手机推送：\(channels.map(\.type).joined(separator: "、"))", "Phone push: \(channels.map(\.type).joined(separator: ", "))"), action: nil, keyEquivalent: "")
        info.isEnabled = false
        sub.addItem(info)
        if let error = store.notifier.lastError {
            let failed = NSMenuItem(title: L("上次推送没成功：\(error)", "Last push failed: \(error)"), action: nil, keyEquivalent: "")
            failed.isEnabled = false
            sub.addItem(failed)
        }
        add(sub, L("编辑推送设置…", "Edit Push Settings…"), #selector(editPushSettings))
        add(sub, L("发送测试通知", "Send a Test Notification"), #selector(sendTestNotification))
        notify.submenu = sub
        menu.addItem(notify)
        let login = NSMenuItem(title: LoginItem.installed ? L("登录时启动", "Launch at Login") : L("登录时启动（要先装到「应用程序」）", "Launch at Login (install to Applications first)"),
                               action: LoginItem.installed ? #selector(toggleLogin) : nil, keyEquivalent: "")
        login.target = self
        login.state = LoginItem.enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        add(menu, L("退出渲染坞", "Quit RenderDock"), #selector(quit), key: "q")
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, on: Bool? = nil, key: String = "") {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self
        if let on { mi.state = on ? .on : .off }
        menu.addItem(mi)
    }

    @objc private func togglePanel() {
        panel?.show()
        panel?.toggle()
    }

    @objc private func toggleCapsule() {
        guard let panel else { return }
        if panel.isVisible { panel.hide() } else { panel.show() }
        UserDefaults.standard.set(!panel.isVisible, forKey: "capsuleHidden")
    }

    @objc private func resetPosition() { panel?.resetPosition() }
    @objc private func toggleAwake() { store.keepAwakeWhileRendering.toggle() }
    @objc private func toggleAPI() { store.apiEnabled.toggle() }
    @objc private func editPushSettings() { store.notifier.openSettings() }
    @objc private func sendTestNotification() { store.notifier.sendTest() }

    @objc private func toggleSystemNotifications() {
        let turnOn = !store.notifier.systemEnabled
        store.notifier.setSystemEnabled(turnOn) { allowed in
            guard turnOn, !allowed else { return }
            // macOS said no (or was told no earlier): say where to change that.
            let alert = NSAlert()
            alert.messageText = L("系统没有允许渲染坞发通知", "macOS is not allowing RenderDock to send notifications")
            alert.informativeText = L("到「系统设置 → 通知 → RenderDock」里打开「允许通知」，再回来勾选这一项。",
                                      "Turn on Allow Notifications under System Settings → Notifications → RenderDock, then tick this item again.")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func toggleLogin() {
        do {
            try LoginItem.set(!LoginItem.enabled)
        } catch {
            let alert = NSAlert()
            alert.messageText = L("没能改动登录时启动", "Couldn't change Launch at Login")
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }

    private static func ringImage(fraction: Double?, active: Bool, paused: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let r = rect.insetBy(dx: 2.5, dy: 2.5)
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let track = NSBezierPath(ovalIn: r)
            track.lineWidth = 2
            NSColor.black.withAlphaComponent(active ? 0.3 : 0.85).setStroke()
            track.stroke()
            if active {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: r.width / 2, startAngle: 90,
                              endAngle: 90 - 360 * CGFloat(max(0.06, fraction ?? 0.28)), clockwise: true)
                arc.lineWidth = 2
                arc.lineCapStyle = .round
                NSColor.black.setStroke()
                arc.stroke()
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: center.x - 1.6, y: center.y - 1.6, width: 3.2, height: 3.2)).fill()
            } else if paused {
                NSColor.black.setFill()
                NSBezierPath(rect: NSRect(x: center.x - 2.4, y: center.y - 2.4, width: 1.7, height: 4.8)).fill()
                NSBezierPath(rect: NSRect(x: center.x + 0.7, y: center.y - 2.4, width: 1.7, height: 4.8)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

let debugCommandName = Notification.Name("io.github.jarnoniu.renderdock.command")

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = Store()
    private var panel: PanelController!
    private var status: StatusItemController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        quitCleanlyOnSIGTERM()
        panel = PanelController(store: store)
        status = StatusItemController(store: store, panel: panel)
        store.onChange = { [weak self] in self?.status.update() }
        if CommandLine.arguments.contains("--demo") { store.startDemo() } else { store.start() }
        if !UserDefaults.standard.bool(forKey: "capsuleHidden") { panel.show() }
        // The debug hook is off by default: commands are only accepted when launched with --debug
        guard CommandLine.arguments.contains("--debug") else { return }
        DistributedNotificationCenter.default().addObserver(
            forName: debugCommandName, object: nil, queue: .main
        ) { [weak self] note in
            self?.handle(command: (note.object as? String) ?? "")
        }
    }

    /// Debug commands (`RenderDock --send "<command>"`): expand, collapse, reset, pin, shot <path>, state <path>,
    /// mouse x1,y1 [x2,y2 …] (screen coordinates; one point is a click, several points are a drag).
    private func handle(command: String) {
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        guard let verb = parts.first else { return }
        let arg = parts.count > 1 ? parts[1] : ""
        switch verb {
        case "expand": panel.setExpanded(true)
        case "collapse": panel.setExpanded(false)
        case "reset": panel.resetPosition()
        case "pin": store.pinned = arg == "on" ? true : (arg == "off" ? false : !store.pinned)
        case "notify-test": store.notifier.sendTest()
        case "shot": panel.debugShot(arg)
        case "state":
            if let data = try? JSONSerialization.data(withJSONObject: panel.debugState(), options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: arg))
            }
        case "mouse":
            let pts = arg.split(separator: " ").compactMap { pair -> NSPoint? in
                let xy = pair.split(separator: ",").compactMap { Double($0) }
                return xy.count == 2 ? NSPoint(x: xy[0], y: xy[1]) : nil
            }
            panel.debugMouse(pts)
        default: break
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) { store.shutdown() }

    /// `kill` (which is how the install script asks a running copy to quit) would otherwise end the process
    /// without `applicationWillTerminate`, leaving the API's discovery file behind.
    private var termSource: DispatchSourceSignal?

    private func quitCleanlyOnSIGTERM() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        termSource = source
    }
}

/// Renders a view to a PNG (for checking the UI; there is no behind-window blur).
@MainActor
func renderSnapshot<V: View>(_ view: V, to path: String) {
    let backdrop = LinearGradient(
        colors: [Color(red: 0.16, green: 0.22, blue: 0.42), Color(red: 0.36, green: 0.22, blue: 0.46), Color(red: 0.80, green: 0.46, blue: 0.36)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    let content = view
        .padding(30)
        .background(backdrop)
        .environment(\.snapshotMode, true)
        .environment(\.colorScheme, .dark)
    let renderer = ImageRenderer(content: content)
    renderer.scale = 2
    guard let cg = renderer.cgImage else {
        print(L("渲染失败：\(path)", "Render failed: \(path)"))
        return
    }
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: path))
    print(L("已写出 \(path)（\(cg.width)×\(cg.height)）", "Wrote \(path) (\(cg.width)×\(cg.height))"))
}

/// App icon: a progress ring and three small bars on a dark rounded square.
struct AppIconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 186, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.13, green: 0.16, blue: 0.24), Color(red: 0.04, green: 0.05, blue: 0.09)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 186, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom), lineWidth: 6))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 14)
            Circle().stroke(.white.opacity(0.12), lineWidth: 62).frame(width: 500, height: 500)
            Circle().trim(from: 0, to: 0.72)
                .stroke(AngularGradient(colors: [Theme.mint, Theme.aqua], center: .center, startAngle: .degrees(0), endAngle: .degrees(260)),
                        style: StrokeStyle(lineWidth: 62, lineCap: .round))
                .frame(width: 500, height: 500)
                .rotationEffect(.degrees(-90))
            HStack(alignment: .bottom, spacing: 30) {
                Capsule().fill(Theme.mint).frame(width: 46, height: 120)
                Capsule().fill(Theme.aqua).frame(width: 46, height: 200)
                Capsule().fill(Theme.lilac).frame(width: 46, height: 156)
            }
            .offset(y: 14)
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor
func renderIcon(to path: String) {
    let renderer = ImageRenderer(content: AppIconView())
    renderer.scale = 1
    guard let cg = renderer.cgImage, let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: path))
}
