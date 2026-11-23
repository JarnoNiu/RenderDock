import Foundation

/// One place a notification goes besides the Mac itself. Read from `notify.json`; nothing is sent unless you add one.
///
///     {"type": "bark",     "key": "…"}                                  optional "server" for a self-hosted one
///     {"type": "ntfy",     "topic": "…"}                                optional "server"
///     {"type": "feishu",   "url": "https://open.feishu.cn/open-apis/bot/v2/hook/…"}
///     {"type": "wecom",    "url": "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=…"}
///     {"type": "dingtalk", "url": "https://oapi.dingtalk.com/robot/send?access_token=…"}
///     {"type": "telegram", "token": "…", "chat_id": "…"}
///     {"type": "webhook",  "url": "…", "method": "POST", "headers": {…}, "body": "… {title} … {body} …"}
///
/// Every channel may carry `"events": ["job.ended", …]` and `"enabled": false`.
package struct NotifyChannel: Codable, Equatable {
    package var type: String
    package var key: String?
    package var topic: String?
    package var server: String?
    package var url: String?
    package var token: String?
    package var chatId: String?
    package var method: String?
    package var headers: [String: String]?
    package var body: String?
    package var events: [String]?
    package var enabled: Bool?

    enum CodingKeys: String, CodingKey {
        case type, key, topic, server, url, token, method, headers, body, events, enabled
        case chatId = "chat_id"
    }

    package init(type: String) { self.type = type }

    package func wants(_ event: String) -> Bool {
        enabled != false && (events ?? Notify.defaultEvents).contains(event)
    }
}

package struct NotifyConfig: Codable, Equatable {
    package var channels: [NotifyChannel]

    package init(channels: [NotifyChannel] = []) { self.channels = channels }
}

/// An HTTP request, described rather than sent, so the checks can look at it.
package struct OutgoingRequest: Equatable {
    package var url: String
    package var method: String
    package var headers: [String: String]
    package var body: Data?
}

package enum Notify {
    /// What is announced unless a channel says otherwise. `shot.done` is left out: a long queue would be noisy.
    package static let defaultEvents = ["job.ended", "job.stalled", "all.ended"]

    /// Override with the RENDERDOCK_NOTIFY environment variable (used when testing).
    package static var configFile: URL {
        if let custom = ProcessInfo.processInfo.environment["RENDERDOCK_NOTIFY"], !custom.isEmpty { return URL(fileURLWithPath: custom) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RenderDock/notify.json")
    }

    package static func loadConfig(from url: URL = configFile) -> NotifyConfig {
        guard let data = try? Data(contentsOf: url), let config = try? JSONDecoder().decode(NotifyConfig.self, from: data) else {
            return NotifyConfig()
        }
        return config
    }

    /// The starter file written when the settings are first opened. Every example is switched off.
    package static let template = """
    {
      "channels": [
        { "type": "bark", "key": "YOUR_DEVICE_KEY", "enabled": false },
        { "type": "ntfy", "topic": "your-topic-name", "enabled": false },
        { "type": "feishu", "url": "https://open.feishu.cn/open-apis/bot/v2/hook/YOUR_HOOK", "enabled": false },
        { "type": "wecom", "url": "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=YOUR_KEY", "enabled": false },
        { "type": "webhook", "url": "http://127.0.0.1:9000/hook",
          "body": "{\\"title\\": \\"{title}\\", \\"text\\": \\"{body}\\", \\"event\\": \\"{event}\\"}", "enabled": false }
      ]
    }

    """

    /// The words for an event, in the UI language. Nil for events that are not worth a notification.
    /// `lastOne`: nothing else is rendering or queued after this.
    package static func message(for e: RenderEvent, lastOne: Bool = false) -> (title: String, body: String)? {
        let tail = lastOne ? L(" · 队列已空", " · nothing else is running") : ""
        switch e.type {
        case .jobEnded:
            switch e.outcome {
            case "finished": return (L("渲染完成", "Render finished"), e.jobTitle + tail)
            case "failed": return (L("渲染失败", "Render failed"), e.jobTitle + L(" · 退出码 \(e.exitCode ?? -1)", " · exit status \(e.exitCode ?? -1)") + tail)
            default: return (L("渲染任务已结束", "Render job ended"), e.jobTitle + tail)
            }
        case .jobStalled:
            return (L("渲染可能卡住了", "Render may be stalled"), e.jobTitle)
        case .shotDone:
            return (L("一段渲完", "Shot done"), e.shot.map { "\(e.jobTitle) · \($0)" } ?? e.jobTitle)
        case .allEnded:
            return (L("全部渲染任务已结束", "All render jobs have ended"), "")
        case .jobStarted, .jobPaused, .jobResumed:
            return nil
        }
    }

    /// Builds the request a channel needs for one message; nil when the channel is missing what it needs.
    package static func request(for c: NotifyChannel, title: String, body: String, event: String, job: String = "", project: String = "") -> OutgoingRequest? {
        func json(_ object: Any) -> Data? { try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) }
        let jsonHeaders = ["Content-Type": "application/json; charset=utf-8"]
        let text = body.isEmpty ? title : "\(title)\n\(body)"
        func base(_ fallback: String) -> String {
            var s = (c.server?.isEmpty == false ? c.server! : fallback)
            while s.hasSuffix("/") { s.removeLast() }
            return s
        }
        switch c.type.lowercased() {
        case "bark":
            guard let key = c.key, !key.isEmpty else { return nil }
            return OutgoingRequest(url: base("https://api.day.app") + "/push", method: "POST", headers: jsonHeaders,
                                   body: json(["device_key": key, "title": title, "body": body.isEmpty ? title : body, "group": "RenderDock"]))
        case "ntfy":
            guard let topic = c.topic, !topic.isEmpty else { return nil }
            return OutgoingRequest(url: base("https://ntfy.sh") + "/", method: "POST", headers: jsonHeaders,
                                   body: json(["topic": topic, "title": title, "message": body.isEmpty ? title : body]))
        case "feishu", "lark":
            guard let url = c.url, !url.isEmpty else { return nil }
            return OutgoingRequest(url: url, method: "POST", headers: jsonHeaders, body: json(["msg_type": "text", "content": ["text": text]]))
        case "wecom", "dingtalk":
            guard let url = c.url, !url.isEmpty else { return nil }
            return OutgoingRequest(url: url, method: "POST", headers: jsonHeaders, body: json(["msgtype": "text", "text": ["content": text]]))
        case "telegram":
            guard let token = c.token, !token.isEmpty, let chat = c.chatId, !chat.isEmpty else { return nil }
            return OutgoingRequest(url: "https://api.telegram.org/bot\(token)/sendMessage", method: "POST", headers: jsonHeaders,
                                   body: json(["chat_id": chat, "text": text]))
        case "webhook":
            guard let url = c.url, !url.isEmpty else { return nil }
            var headers = c.headers ?? [:]
            let isJSON = (headers.first { $0.key.lowercased() == "content-type" }?.value ?? "application/json").lowercased().contains("json")
            if !headers.keys.contains(where: { $0.lowercased() == "content-type" }) { headers["Content-Type"] = "application/json; charset=utf-8" }
            let values = ["title": title, "body": body, "event": event, "job": job, "project": project]
            // In a JSON body the placeholders sit inside string literals, so the values are escaped accordingly.
            func escaped(_ s: String) -> String {
                guard isJSON, let d = try? JSONSerialization.data(withJSONObject: [s]), let t = String(data: d, encoding: .utf8) else { return s }
                return String(t.dropFirst(2).dropLast(2))
            }
            func fill(_ template: String, escape: Bool) -> String {
                values.reduce(template) { $0.replacingOccurrences(of: "{\($1.key)}", with: escape ? escaped($1.value) : $1.value) }
            }
            let payload = c.body.map { fill($0, escape: true) }
                ?? String(decoding: json(["title": title, "body": body, "event": event, "job": job, "project": project]) ?? Data(), as: UTF8.self)
            let method = (c.method ?? "POST").uppercased()
            return OutgoingRequest(url: url, method: method, headers: headers, body: method == "GET" ? nil : Data(payload.utf8))
        default:
            return nil
        }
    }
}
