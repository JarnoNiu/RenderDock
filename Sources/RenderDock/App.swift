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
        let key = "\(active)|\(fraction.map { Int($0 * 40) } ?? -1)|\(groups.pausedCount)|\(groups.stalledCount)|\(store.agentSummary ?? "")"
        guard key != lastKey else { return }
        lastKey = key
        item.button?.image = Self.ringImage(fraction: fraction, active: active > 0, paused: active == 0 && groups.pausedCount > 0)
        item.button?.attributedTitle = NSAttributedString(
            string: active > 0 ? " \(active)" : "",
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
        let agentLine = store.agentSummary.map { L("\nAgent：\($0)", "\nAgents: \($0)") } ?? ""
        item.button?.toolTip = L("渲染坞：\(store.summary)\(agentLine)", "RenderDock: \(store.summary)\(agentLine)")
    }

    /// For the debug hook: the menu as it would open now, as titles (submenus nested), without opening it.
    func debugMenu() -> [[String: Any]] {
        guard let menu = item.menu else { return [] }
        menuNeedsUpdate(menu)
        func rows(_ menu: NSMenu) -> [[String: Any]] {
            menu.items.filter { !$0.isSeparatorItem }.map { item in
                var row: [String: Any] = ["title": item.title, "enabled": item.isEnabled, "on": item.state == .on]
                if let sub = item.submenu { row["items"] = rows(sub) }
                return row
            }
        }
        return rows(menu)
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
        if let agentSummary = store.agentSummary {
            let agentHead = NSMenuItem(title: L("Agent：\(agentSummary)", "Agents: \(agentSummary)"), action: nil, keyEquivalent: "")
            agentHead.isEnabled = false
            menu.addItem(agentHead)
            for s in store.agents.filter({ $0.state != .idle }).prefix(8) {
                var line = "\(AgentTool.displayName(s.tool)) · \(s.project) — \(s.state.label)"
                if s.state == .waiting, let what = s.waitingFor, !what.isEmpty { line += "（\(what)）" }
                let mi = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                mi.isEnabled = false
                mi.indentationLevel = 1
                menu.addItem(mi)
            }
        }
        menu.addItem(.separator())
        add(menu, store.expanded ? L("收起面板", "Collapse Panel") : L("展开面板", "Expand Panel"), #selector(togglePanel))
        add(menu, L("显示悬浮胶囊", "Show Floating Capsule"), #selector(toggleCapsule), on: panel?.isVisible == true)
        add(menu, L("回到右上角", "Move to Top-Right"), #selector(resetPosition))
        menu.addItem(.separator())
        add(menu, L("渲染时保持唤醒", "Keep Awake While Rendering"), #selector(toggleAwake), on: store.keepAwakeWhileRendering)
        add(menu, L("显示 Agent 任务（只读）", "Show Agents' Sessions (read-only)"), #selector(toggleAgents), on: store.agentsEnabled)
        if store.agentsEnabled {
            add(menu, L("显示会话标题", "Show Session Titles"), #selector(toggleAgentTitles), on: store.agentTitles)
        }
        let failed = L("（没能启动）", " (could not start)")
        add(menu, L("在这里答复 agent 的请求", "Answer Agents' Requests Here") + (store.controlFailed ? failed : ""), #selector(toggleControl), on: store.controlEnabled)
        add(menu, L("接收其他程序的通知、进度和提问", "Take Notices, Progress and Questions from Other Programs") + (store.inboxFailed ? failed : ""),
            #selector(toggleInbox), on: store.inboxEnabled)

        // A device on the desk
        let deviceItem = NSMenuItem(title: L("桌面小设备", "Desk Device"), action: nil, keyEquivalent: "")
        let deviceMenu = NSMenu()
        add(deviceMenu, L("连接蓝牙小设备", "Connect a Bluetooth Device"), #selector(toggleDevice), on: store.deviceEnabled)
        if store.deviceEnabled {
            let line = NSMenuItem(title: store.deviceStatus.text, action: nil, keyEquivalent: "")
            line.isEnabled = false
            deviceMenu.addItem(line)
            // Where the status alone would leave the user stuck, a second line says what to do.
            if let hint = store.deviceStatus.hint {
                let more = NSMenuItem(title: hint, action: nil, keyEquivalent: "")
                more.isEnabled = false
                deviceMenu.addItem(more)
            }
            add(deviceMenu, L("可以在设备上答复 agent 的请求", "Agents' Requests May Be Answered on the Device"), #selector(toggleDeviceAnswers), on: store.deviceAnswers)
            add(deviceMenu, L("设备能显示中文", "The Device Can Show Chinese"), #selector(toggleDeviceUnicode), on: store.deviceUnicode)
            // Wi-Fi for where Bluetooth does not reach: only for a display that keeps pages (it reads the same stream),
            // and only settable while it is on the encrypted link.
            if case .connected(_, true, _) = store.deviceStatus, store.device.pages {
                deviceMenu.addItem(.separator())
                let state = store.device.wifi
                let words: String
                switch state {
                case 1: words = L("Wi-Fi：已设好，蓝牙不在时会用", "Wi-Fi: set, used when Bluetooth is away")
                case 2: words = L("Wi-Fi：正在连", "Wi-Fi: joining")
                case 3: words = L("Wi-Fi：连着，在读数据", "Wi-Fi: on, reading")
                case 4: words = L("Wi-Fi：连不上（名字或密码不对、太远，或不是 2.4 GHz）", "Wi-Fi: could not join (name or password, out of range, or not 2.4 GHz)")
                case 5: words = L("Wi-Fi：口令被拒（会自动更新；没恢复就重新设一次）", "Wi-Fi: the token was refused (it is told the new one; set it up again if that does not help)")
                case 6: words = L("Wi-Fi：连上了，这台电脑没有应答", "Wi-Fi: joined, this Mac did not answer")
                default: words = L("Wi-Fi：没有设置", "Wi-Fi: not set")
                }
                let wifiLine = NSMenuItem(title: words, action: nil, keyEquivalent: "")
                wifiLine.isEnabled = false
                deviceMenu.addItem(wifiLine)
                add(deviceMenu, L("让它在蓝牙够不着时走 Wi-Fi…", "Let It Use Wi-Fi Where Bluetooth Does Not Reach…"), #selector(giveDeviceWiFi))
                if (state ?? 0) != 0 { add(deviceMenu, L("让它忘掉 Wi-Fi", "Have It Forget Wi-Fi"), #selector(forgetDeviceWiFi)) }
                deviceMenu.addItem(.separator())
            }
            add(deviceMenu, L("忘记这台设备", "Forget This Device"), #selector(forgetDevice))
        }
        deviceItem.submenu = deviceMenu
        menu.addItem(deviceItem)
        let where_ = store.apiPort.map { "（127.0.0.1:\($0)）" } ?? ""
        let whereEn = store.apiPort.map { " (127.0.0.1:\($0))" } ?? ""
        add(menu, L("本机接口\(where_)", "Local API\(whereEn)"), #selector(toggleAPI), on: store.apiEnabled)
        if store.apiEnabled {
            // Reaching the API from other devices: a switch of its own, off by default, and never without the token.
            let lanItem = NSMenuItem(title: L("从局域网访问接口", "The API from the Local Network"), action: nil, keyEquivalent: "")
            let lanMenu = NSMenu()
            add(lanMenu, L("允许局域网里的设备访问，凭口令", "Allow Devices on the Local Network, with the Token"), #selector(toggleLAN), on: store.lanEnabled)
            if store.lanEnabled, let port = store.apiPort {
                let addresses = LocalAPIServer.networkAddresses()
                for address in addresses.prefix(3) {
                    let line = NSMenuItem(title: "http://\(address):\(port)", action: nil, keyEquivalent: "")
                    line.isEnabled = false
                    lanMenu.addItem(line)
                }
                if addresses.isEmpty {
                    let line = NSMenuItem(title: L("这台电脑现在没有连着网络", "This Mac is not on a network right now"), action: nil, keyEquivalent: "")
                    line.isEnabled = false
                    lanMenu.addItem(line)
                }
                add(lanMenu, L("复制口令", "Copy the Token"), #selector(copyAPIToken))
                add(lanMenu, L("换一个口令（旧的立即失效）", "New Token (the Old One Stops Working)"), #selector(renewAPIToken))
                let warning = NSMenuItem(title: L("不加密：只在信得过的网络里用", "Not encrypted: for a network you trust"), action: nil, keyEquivalent: "")
                warning.isEnabled = false
                lanMenu.addItem(warning)
            }
            lanItem.submenu = lanMenu
            menu.addItem(lanItem)
        }

        // Hands on: pausing, letting go, moving out of the way. Five switches, all off to begin with, each its own.
        let handsItem = NSMenuItem(title: L("动手控制渲染（默认全关）", "Hands On the Renders (All Off by Default)"), action: nil, keyEquivalent: "")
        let handsMenu = NSMenu()
        add(handsMenu, L("可以在面板上暂停和继续", "Pause and Resume from the Dock"), #selector(toggleHandsPause), on: store.handsSettings.manual)
        add(handsMenu, L("可以在面板上让渲染让路", "Move a Render Out of the Way from the Dock"), #selector(toggleHandsYield), on: store.handsSettings.yield)
        handsMenu.addItem(.separator())
        add(handsMenu, L("一次只渲一条，渲完自动继续下一条", "One Job at a Time, the Next Goes On When One Ends"), #selector(toggleHandsTurns), on: store.handsSettings.turns)
        add(handsMenu, L("电脑用电池时暂停渲染", "Pause Renders While on Battery"), #selector(toggleHandsBattery), on: store.handsSettings.pauseOnBattery)
        add(handsMenu, L("电脑过热降速时暂停渲染", "Pause Renders While Slowed Down for Heat"), #selector(toggleHandsHeat), on: store.handsSettings.pauseWhenHot)
        handsMenu.addItem(.separator())
        add(handsMenu, L("打开操作记录", "Open the Log of What Was Done"), #selector(openHandsLog))
        handsItem.submenu = handsMenu
        menu.addItem(handsItem)

        // MQTT: for a home-automation system. Nothing is sent unless the settings file names a broker and switches it on.
        let mqttItem = NSMenuItem(title: "MQTT", action: nil, keyEquivalent: "")
        let mqttMenu = NSMenu()
        let mqttLine = NSMenuItem(title: store.mqttStatus ?? L("没有设置，什么都不发", "Not set up: nothing is sent"), action: nil, keyEquivalent: "")
        mqttLine.isEnabled = false
        mqttMenu.addItem(mqttLine)
        add(mqttMenu, L("编辑 MQTT 设置…", "Edit MQTT Settings…"), #selector(editMQTTSettings))
        mqttItem.submenu = mqttMenu
        menu.addItem(mqttItem)

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
        add(sub, L("Agent 会话也通知", "Notify About Agents' Sessions Too"), #selector(toggleAgentNotifications), on: store.notifier.agentsEnabled)
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

    /// Switching one of these on is asked about first, in so many words: from then on RenderDock may stop a
    /// render. Switching it off needs no asking, and undoes what was done under it.
    private func toggleHands(_ key: WritableKeyPath<ControlSettings, Bool>, what: String, detail: String) {
        if store.handsSettings[keyPath: key] {
            store.handsSettings[keyPath: key] = false
            return
        }
        let alert = NSAlert()
        alert.messageText = what
        alert.informativeText = detail + L("\n\n渲染坞只动它显示为渲染的、属于你的进程；它停掉的任务，在它退出时会自动继续；每一次动作都写进操作记录。这个开关随时可以关，关掉会立即还原它做过的事。",
                                           "\n\nRenderDock acts only on processes of yours that it shows as renders. What it stopped goes on again when RenderDock quits, and everything it does is written to the log. The switch can be turned off at any time, which at once undoes what was done under it.")
        alert.addButton(withTitle: L("打开", "Turn On"))
        alert.addButton(withTitle: L("取消", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { store.handsSettings[keyPath: key] = true }
    }
    @objc private func toggleHandsPause() {
        toggleHands(\.manual, what: L("让渲染坞可以暂停和继续渲染？", "Let RenderDock pause and resume renders?"),
                    detail: L("打开后，面板上每条任务会多一个暂停/继续按钮。暂停是让渲染进程停在原地，继续后接着渲，不丢进度。", "Each job in the dock gets a pause and resume button. Pausing stops the render process where it is; resumed, it goes on from there and loses nothing."))
    }
    @objc private func toggleHandsYield() {
        toggleHands(\.yield, what: L("让渲染坞可以让渲染「让路」？", "Let RenderDock move a render out of the way?"),
                    detail: L("打开后，面板上每条任务会多一个「让路」按钮：让这条任务只用电脑空出来的力气，会渲得慢一些，可以随时恢复。", "Each job in the dock gets a button that lets it run on what the Mac has to spare: slower, and it can be put back at any time."))
    }
    @objc private func toggleHandsTurns() {
        toggleHands(\.turns, what: L("一次只渲一条？", "Render one job at a time?"),
                    detail: L("打开后，同时在跑的几条任务里只让最早开始的那一条渲，其余的自动暂停；前一条结束，下一条自动继续。你手动暂停或手动继续的任务不受这条规则管。", "Of the jobs running at once, only the one that began first goes on; the others are paused, and each goes on when the one before it has ended. A job you paused or let go by hand is left out of this."))
    }
    @objc private func toggleHandsBattery() {
        toggleHands(\.pauseOnBattery, what: L("电脑用电池时暂停渲染？", "Pause renders while the Mac is on its battery?"),
                    detail: L("打开后，拔掉电源时所有在渲的任务自动暂停，接回电源后自动继续。", "When the power adapter is unplugged, every job that is rendering is paused; plugged in again, they go on."))
    }
    @objc private func toggleHandsHeat() {
        toggleHands(\.pauseWhenHot, what: L("电脑过热降速时暂停渲染？", "Pause renders while the Mac is slowed down for heat?"),
                    detail: L("打开后，系统因为过热开始降速时，所有在渲的任务自动暂停；凉下来满一分钟后自动继续。", "When the system starts slowing the Mac down for heat, every job that is rendering is paused; they go on once it has been cool for a full minute."))
    }
    @objc private func openHandsLog() {
        let url = Store.handsLog
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? L("还没有做过任何动作。\n", "Nothing has been done yet.\n").write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }
    @objc private func toggleLAN() { store.lanEnabled.toggle() }
    @objc private func copyAPIToken() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(store.apiToken, forType: .string)
    }
    @objc private func renewAPIToken() { store.renewAPIToken() }
    @objc private func toggleAgents() { store.agentsEnabled.toggle() }
    @objc private func toggleAgentTitles() { store.agentTitles.toggle() }
    @objc private func toggleAgentNotifications() { store.notifier.agentsEnabled.toggle() }
    @objc private func toggleControl() { store.controlEnabled.toggle() }
    @objc private func toggleInbox() { store.inboxEnabled.toggle() }
    @objc private func toggleDevice() { store.deviceEnabled.toggle() }
    @objc private func toggleDeviceUnicode() { store.deviceUnicode.toggle() }
    @objc private func toggleDeviceAnswers() { store.deviceAnswers.toggle() }
    @objc private func forgetDevice() { store.device.forget() }

    /// Debug only: the sheet below drawn into a picture, without showing it, with made-up networks in its list.
    func debugWiFiSheet(_ path: String) {
        let sheet = WiFiSheet()
        if path.hasSuffix("-looking.png") { sheet.looking() } else {
            sheet.fill([.init(name: "Studio-2.4G", signal: -48), .init(name: "Studio-Guest", signal: -63, open: true), .init(name: "隔壁工作室", signal: -80)])
        }
        let alert = sheet.alert
        alert.window.appearance = NSAppearance(named: .aqua)   // a window that is not on screen draws light text on nothing otherwise
        alert.layout()
        guard let view = alert.window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Has the display look for the networks around it, lets one be picked from what it found, takes the
    /// password, and hands both over on a yes. The names come from the display and from nowhere on this Mac;
    /// the password is typed here and kept nowhere on this Mac.
    @objc private func giveDeviceWiFi() {
        let sheet = WiFiSheet()
        sheet.looking()
        store.lookForNetworks { [weak sheet] list in sheet?.fill(list) }
        NSApp.activate(ignoringOtherApps: true)
        guard sheet.alert.runModal() == .alertFirstButtonReturn else { return }
        let ssid = sheet.ssid
        guard !ssid.isEmpty else { return }
        store.giveDeviceWiFi(ssid: ssid, password: sheet.password.stringValue) { problem in
            guard let problem else { return }
            let failed = NSAlert()
            failed.messageText = L("没能交给小屏", "It could not be handed to the display")
            failed.informativeText = problem.text
            NSApp.activate(ignoringOtherApps: true)
            failed.runModal()
        }
    }
    @objc private func forgetDeviceWiFi() { store.forgetDeviceWiFi() }
    @objc private func editPushSettings() { store.notifier.openSettings() }
    @objc private func editMQTTSettings() { store.openMQTTSettings() }
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

/// The sheet that sets the desk display up for Wi-Fi: a list of the networks the display itself found (so the
/// name is picked, not typed, and is one the display can reach from where it stands), a field for the password,
/// and in so many words what will be handed over and what that switches on.
final class WiFiSheet: NSObject {
    let alert = NSAlert()
    let password = NSSecureTextField(frame: .zero)
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let name = NSTextField(frame: .zero)
    private static let width: CGFloat = 420
    /// What a line of the list is: a network the display found, "another one, typed", or a line that only says something.
    private enum Line: Int { case network, other, words }

    override init() {
        super.init()
        alert.messageText = L("让桌面小屏在蓝牙够不着时走 Wi-Fi？", "Let the desk display use Wi-Fi where Bluetooth does not reach?")
        alert.informativeText = L("网络从小屏自己搜到的里面选，密码在这里输入，经加密的蓝牙连接交给小屏。渲染坞不保存密码。",
                                  "Pick the network from those the display itself found and type its password here. Both go to the display over the encrypted Bluetooth link. RenderDock does not keep the password.")
        // The rest is too much for an alert's own narrow column: it goes with the fields, at a width that reads.
        let width = Self.width
        let detail = NSTextField(wrappingLabelWithString: L("""
            交给小屏的有四样：Wi-Fi 的名称和密码、这台电脑在网络上的名字和地址、读取接口用的口令。

            · 小屏把它们存在自己身上，没有加密：拿到这块板子并把它接到电脑上的人能读出来。
            · 这会打开「本机接口」和「从局域网访问接口」。后者带口令，但不加密，只适合信得过的网络。
            · 走 Wi-Fi 时小屏只能看，不能在上面答复请求和提问；也比蓝牙费电。
            · 选这台电脑现在连着的那个网络。参考的那块小屏只支持 2.4 GHz，只有 5 GHz 的网络它搜不到。
            """, """
            The display is handed four things: the network's name and password, this Mac's name and address on the network, and the token for reading the API.

            · It keeps them on itself, unencrypted: somebody who has the board and plugs it into a computer can read them out.
            · This switches on the Local API and access to it from the local network. That has a token and no encryption: for a network you trust.
            · Over Wi-Fi the display only shows; requests and questions cannot be answered on it. It also draws more power than Bluetooth.
            · Pick the network this Mac is on. The reference display works on 2.4 GHz only and does not find a network that is 5 GHz only.
            """))
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        detail.preferredMaxLayoutWidth = width
        let detailHeight = ceil(detail.sizeThatFits(NSSize(width: width, height: 2000)).height)
        password.frame = NSRect(x: 0, y: 0, width: width, height: 24)
        password.placeholderString = L("Wi-Fi 密码（不用密码的网络留空）", "Password (leave empty for a network without one)")
        popup.frame = NSRect(x: 0, y: 32, width: width, height: 26)
        popup.target = self
        popup.action = #selector(picked)
        popup.autoenablesItems = false
        name.frame = NSRect(x: 212, y: 33, width: width - 212, height: 24)
        name.placeholderString = L("Wi-Fi 名称", "Network name")
        name.isHidden = true
        detail.frame = NSRect(x: 0, y: 70, width: width, height: detailHeight)
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 70 + detailHeight))
        [detail, popup, name, password].forEach { fields.addSubview($0) }
        alert.accessoryView = fields
        alert.addButton(withTitle: L("交给小屏", "Hand It Over"))
        alert.addButton(withTitle: L("取消", "Cancel"))
        alert.window.initialFirstResponder = password
    }

    /// The network to hand over: the one picked, or the one typed.
    var ssid: String {
        switch Line(rawValue: popup.selectedItem?.tag ?? Line.words.rawValue) {
        case .network: return popup.selectedItem?.representedObject as? String ?? ""
        case .other: return name.stringValue.trimmingCharacters(in: .whitespaces)
        default: return ""
        }
    }

    /// While the display is looking: one line that says so, and nothing to confirm yet.
    func looking() {
        popup.removeAllItems()
        add(L("正在让小屏找附近的 Wi-Fi…", "The display is looking for networks…"), .words, enabled: false)
        settle()
    }

    /// What the display found, strongest first; nil if it did not answer. A name can still be typed either way
    /// (a network that hides its name is not found).
    func fill(_ list: [BuddyProtocol.SeenNetwork]?) {
        popup.removeAllItems()
        for net in list ?? [] {
            var title = net.name + "　·　" + Self.strength(net.signal)
            if net.open { title += L("　·　不用密码", " · no password") }
            add(title, .network, enabled: true).representedObject = net.name
        }
        if (list ?? []).isEmpty {
            add(list == nil ? L("小屏没有回答", "The display did not answer") : L("小屏没有搜到网络", "The display found no network"), .words, enabled: false)
        }
        popup.menu?.addItem(.separator())
        add(L("其他网络（手动输入名称）…", "Another network (type its name)…"), .other, enabled: true)
        popup.selectItem(at: (list ?? []).isEmpty ? popup.numberOfItems - 1 : 0)
        settle()
    }

    private static func strength(_ signal: Int?) -> String {
        guard let signal else { return L("信号未知", "signal unknown") }
        return signal >= -60 ? L("信号强", "strong") : (signal >= -75 ? L("信号中", "fair") : L("信号弱", "weak"))
    }

    @discardableResult
    private func add(_ title: String, _ line: Line, enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.tag = line.rawValue
        item.isEnabled = enabled
        popup.menu?.addItem(item)
        return item
    }

    @objc private func picked() { settle() }

    /// The name field shows beside the list only for "another network"; the first button waits for something to hand over.
    private func settle() {
        let line = Line(rawValue: popup.selectedItem?.tag ?? Line.words.rawValue) ?? .words
        name.isHidden = line != .other
        popup.frame.size.width = line == .other ? 204 : Self.width
        alert.buttons.first?.isEnabled = line != .words
        if line == .other { alert.window.makeFirstResponder(name) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = Store()
    private var panel: PanelController!
    private var status: StatusItemController!
    private let preview = PreviewController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        quitCleanlyOnSIGTERM()
        panel = PanelController(store: store)
        status = StatusItemController(store: store, panel: panel)
        store.onChange = { [weak self] in self?.status.update() }
        store.onPreview = { [weak self] item in
            guard let dir = item.outDir else { return }
            self?.preview.show(dir: dir, title: item.name)
        }
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

    /// Debug commands (`RenderDock --send "<command>"`): expand, collapse, reset, pin, stress on|off, shot <path>, state <path>,
    /// mouse x1,y1 [x2,y2 …] (screen coordinates; one point is a click, several points are a drag),
    /// menu <path> (the menu bar item's menu as titles), device-status pairing-gone|connecting|looking <name>
    /// (what the menu would say about the Bluetooth link in that state; no Bluetooth is touched),
    /// inbox <path> (what other programs have put in), pick <n> (answers the oldest waiting question with that answer),
    /// preview <folder>, preview-frame <n>, preview-follow on|off, preview-state <path>, preview-shot <path>
    /// (the larger look at a folder of frames: open it, move in it, and read back what it shows),
    /// wifi-sheet <path> (the sheet that asks for a network for the desk display, as a picture),
    /// hands …, hands-as …, hands-job …, hands-state <path> (the switches for pausing and the rest, what the rules
    /// are told about the Mac, a job's buttons, and what is held; only a demo instance stops anything, and there
    /// only on paper).
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
        case "stress": store.stress = arg != "off"   // demo only: every readout at its widest, to watch the live window follow
        case "answer":   // "answer allow <id>" / "answer deny <id>": what a click on the panel's buttons does
            let words = arg.split(separator: " ").map(String.init)
            if words.count == 2, let decision = ControlDecision(rawValue: words[0]) { store.answer(words[1], decision) }
        case "requests":   // write the waiting requests to a file: id, action, approvable
            let list = store.requests.map { ["id": $0.id, "action": $0.action, "project": $0.project, "approvable": $0.approvable] as [String: Any] }
            if let data = try? JSONSerialization.data(withJSONObject: list, options: [.sortedKeys]) { try? data.write(to: URL(fileURLWithPath: arg)) }
        case "menu":
            if let data = try? JSONSerialization.data(withJSONObject: status.debugMenu(), options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: arg))
            }
        case "device-status":
            let words = arg.split(separator: " ", maxSplits: 1).map(String.init)
            let name = words.count > 1 ? words[1] : BuddyProtocol.namePrefix
            switch words.first {
            case "pairing-gone": store.deviceStatus = .pairingGone(name)
            case "connecting": store.deviceStatus = .connecting(name)
            case "looking": store.deviceStatus = .looking
            default: break
            }
        case "pick":   // "pick 1": what a click on that answer of the oldest waiting question does
            if let index = Int(arg), let question = store.inbox.questions.first { store.answerQuestion(question.id, index) }
        case "inbox":  // write what other programs have put in: notices, tasks and questions
            let view = store.inbox
            let all: [String: Any] = [
                "notices": view.notices.map { ["from": $0.from, "title": $0.title, "body": $0.body, "level": $0.level.rawValue] },
                "tasks": view.tasks.map { ["from": $0.from, "id": $0.id, "title": $0.title, "state": $0.state, "percent": $0.fraction.map { Int(($0 * 100).rounded()) } ?? -1] as [String: Any] },
                "questions": view.questions.map { ["from": $0.from, "text": $0.text, "choices": $0.choices] as [String: Any] },
            ]
            if let data = try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: arg)) }
        case "preview":        // "preview <folder>": the larger look at the frames in that folder
            preview.show(dir: arg, title: (arg as NSString).lastPathComponent)
        case "preview-frame":  // "preview-frame 12": go to the frame at that place in the list, as a drag of the slider does
            if let n = Int(arg) { preview.model.show(n, byHand: true) }
        case "preview-follow": preview.model.follow = arg != "off"
        case "preview-state":  // which frame is up, of how many, and whether the newest is followed
            let m = preview.model
            let now: [String: Any] = ["count": m.frames.count, "index": m.index, "number": m.current?.number ?? -1, "follow": m.follow,
                                      "file": (m.imagePath as NSString).lastPathComponent]
            if let data = try? JSONSerialization.data(withJSONObject: now, options: [.sortedKeys]) { try? data.write(to: URL(fileURLWithPath: arg)) }
        case "preview-shot": preview.debugShot(arg)
        case "wifi-sheet": status.debugWiFiSheet(arg)   // "wifi-sheet <path>": the sheet that asks for a network, as a picture, not shown
        case "hands":          // "hands pause|yield|turns|battery|heat on|off": a switch, without the question a click would be asked
            let words = arg.split(separator: " ").map(String.init)
            if words.count == 2 {
                let on = words[1] == "on"
                switch words[0] {
                case "pause": store.handsSettings.manual = on
                case "yield": store.handsSettings.yield = on
                case "turns": store.handsSettings.turns = on
                case "battery": store.handsSettings.pauseOnBattery = on
                case "heat": store.handsSettings.pauseWhenHot = on
                default: break
                }
            }
        case "hands-as":       // "hands-as battery|mains|hot|cool|real": what the rules are told about the Mac
            switch arg {
            case "battery": store.debugOnBattery = true
            case "mains": store.debugOnBattery = false
            case "hot": store.debugHot = true
            case "cool": store.debugHot = false
            default: store.debugOnBattery = nil; store.debugHot = nil
            }
            store.tickHands()
            store.onChange?()
        case "hands-job":      // "hands-job pause|resume|yield <n>": what the button on the n-th job's card does
            let words = arg.split(separator: " ").map(String.init)
            if words.count == 2, let n = Int(words[1]), store.groups.indices.contains(n) {
                let id = store.groups[n].id
                switch words[0] {
                case "pause": store.pauseJob(id)
                case "resume": store.resumeJob(id)
                case "yield": store.toggleYield(id)
                default: break
                }
            }
        case "hands-state":    // what is held and why, what is out of the way, and the last lines of the log
            let titles = Dictionary(store.groups.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
            let now: [String: Any] = [
                "switches": ["pause": store.handsSettings.manual, "yield": store.handsSettings.yield, "turns": store.handsSettings.turns,
                             "battery": store.handsSettings.pauseOnBattery, "heat": store.handsSettings.pauseWhenHot],
                "held": Dictionary(store.hands.held.map { (titles[$0.key] ?? $0.key, $0.value.reasons.map(\.rawValue).sorted()) }, uniquingKeysWith: { a, _ in a }),
                "yielding": store.hands.yielding.keys.map { titles[$0] ?? $0 }.sorted(),
                "log": store.handsLines,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: now, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: arg)) }
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
