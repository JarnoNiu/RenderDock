import AppKit
import RenderDockCore
import UserNotifications

/// Turns events into notifications: on this Mac (opt-in, the system asks for permission once) and through
/// the channels in `notify.json` (nothing is sent anywhere unless you put a channel there).
final class Notifier {
    private(set) var lastError: String?
    /// Called on the main queue when `lastError` changes.
    var onChange: (() -> Void)?

    var systemEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "notifySystem") }
        set { UserDefaults.standard.set(newValue, forKey: "notifySystem") }
    }

    /// Channels that are switched on in the settings file.
    var activeChannels: [NotifyChannel] { Notify.loadConfig().channels.filter { $0.enabled != false } }

    /// UNUserNotificationCenter needs a real app bundle; the bare binary (`--dump`, checks) has none.
    private var canUseSystem: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    /// Turning it on asks macOS for permission the first time. `done` reports whether notifications are allowed.
    func setSystemEnabled(_ on: Bool, done: @escaping (Bool) -> Void) {
        guard on else {
            systemEnabled = false
            return done(false)
        }
        guard canUseSystem else { return done(false) }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async {
                self.systemEnabled = granted
                done(granted)
            }
        }
    }

    func handle(_ events: [RenderEvent]) {
        guard !events.isEmpty else { return }
        // When the last job ends, say so in that job's message instead of sending a second notification.
        let endsQueue = events.contains { $0.type == .allEnded }
        let jobsEnded = events.filter { $0.type == .jobEnded }
        for e in events {
            if e.type == .allEnded, !jobsEnded.isEmpty { continue }
            let last = endsQueue && e.type == .jobEnded && e == jobsEnded.last
            guard let m = Notify.message(for: e, lastOne: last) else { continue }
            deliver(title: m.title, body: m.body, event: e.type.rawValue, job: e.jobTitle, project: e.project)
        }
    }

    func sendTest() {
        deliver(title: L("渲染坞测试通知", "RenderDock test notification"),
                body: L("看到这条，说明通知是通的。", "If you can read this, notifications work."),
                event: "test", job: "", project: "", force: true)
    }

    private func deliver(title: String, body: String, event: String, job: String, project: String, force: Bool = false) {
        if systemEnabled, canUseSystem, force || Notify.defaultEvents.contains(event) {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
                if let error { self.report(L("系统通知：", "System notification: ") + error.localizedDescription) }
            }
        }
        for channel in Notify.loadConfig().channels where force ? channel.enabled != false : channel.wants(event) {
            guard let out = Notify.request(for: channel, title: title, body: body, event: event, job: job, project: project),
                  let url = URL(string: out.url) else {
                report(L("推送渠道 \(channel.type) 的设置不完整", "Channel \(channel.type) is missing a setting"))
                continue
            }
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.httpMethod = out.method
            out.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            request.httpBody = out.body
            URLSession.shared.dataTask(with: request) { _, response, error in
                if let error {
                    self.report("\(channel.type): \(error.localizedDescription)")
                } else if let http = response as? HTTPURLResponse, http.statusCode >= 300 {
                    self.report("\(channel.type): HTTP \(http.statusCode)")
                } else {
                    self.report(nil)
                }
            }.resume()
        }
    }

    private func report(_ error: String?) {
        DispatchQueue.main.async {
            guard self.lastError != error else { return }
            self.lastError = error
            self.onChange?()
        }
    }

    /// Opens the settings file in the default editor, creating it from the template (owner-only: it will hold keys).
    func openSettings() {
        let url = Notify.configFile
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data(Notify.template.utf8), attributes: [.posixPermissions: 0o600])
        }
        NSWorkspace.shared.open(url)
    }
}
