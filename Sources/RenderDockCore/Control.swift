import CryptoKit
import Foundation

// Answering an agent from RenderDock: "allow once" or "deny" for a request the agent would otherwise ask
// about in its own window. Off unless switched on, and nothing here is installed by RenderDock on its own.
//
// How it fits together:
//   agent  →  its PermissionRequest hook runs `renderdock hook`
//          →  that asks the app over a Unix socket only this user can reach, and waits
//          →  the app shows the request; the user allows it once or denies it
//          →  the answer goes back the same way, and the hook prints it for the agent
// Whenever anything is missing or slow — the app is not running, the feature is off, nobody answers in
// time — the hook prints nothing, and the agent asks in its own window exactly as before.
// See docs/ANSWERING-AGENTS.md.

// MARK: What an agent asks

package enum ControlDecision: String, Codable {
    case allow, deny
    /// No answer from here: the agent's own prompt takes over.
    case none
}

/// What `renderdock hook` reads from the agent on standard input.
package struct HookInput: Equatable {
    package var event: String
    package var sessionId: String
    package var cwd: String
    /// The agent's own name for what it wants to do: Bash, Read, Edit, …
    package var action: String
    /// What it would do, as text: the command, the path, the pattern.
    package var detail: String
    /// Identifies exactly this request: the action and its whole input.
    package var fingerprint: String

    package static func parse(_ data: Data) -> HookInput? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let event = o["hook_event_name"] as? String, let action = o["tool_name"] as? String else { return nil }
        let input = o["tool_input"] as? [String: Any] ?? [:]
        let canonical = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])) ?? Data()
        let digest = SHA256.hash(data: Data(action.utf8) + [0x0A] + canonical)
        return HookInput(event: event, sessionId: o["session_id"] as? String ?? "", cwd: o["cwd"] as? String ?? "",
                         action: action, detail: describe(input),
                         fingerprint: digest.prefix(8).map { String(format: "%02x", $0) }.joined())
    }

    /// A tool's whole input as text a person can read: the main thing first (the command, the path, the
    /// pattern), then every other field by name. Nothing is left out, because what is shown is what is allowed:
    /// a field that is not on the screen must not be able to ride along. An input with a lot in it (an edit's
    /// old and new text, a file's contents) therefore comes out long, and a long request cannot be allowed here.
    static func describe(_ input: [String: Any]) -> String {
        var shown = Set<String>()
        var text = ""
        for key in ["command", "file_path", "notebook_path", "path", "url", "query"] {
            if let main = input[key] as? String, !main.isEmpty {
                shown.insert(key)
                text = main
                if key == "path", let pattern = input["pattern"] as? String {
                    shown.insert("pattern")
                    text = "\(pattern)  in  \(main)"
                }
                break
            }
        }
        if text.isEmpty, let pattern = input["pattern"] as? String, !pattern.isEmpty {
            shown.insert("pattern")
            text = pattern
        }
        for key in input.keys.sorted() where !shown.contains(key) {
            let value: String
            switch input[key] {
            case let string as String: value = string
            case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): value = number.boolValue ? "true" : "false"
            case let number as NSNumber: value = number.stringValue
            case let other?:
                value = (try? JSONSerialization.data(withJSONObject: other, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]))
                    .map { String(decoding: $0, as: UTF8.self) } ?? "?"
            case nil: continue
            }
            text += (text.isEmpty ? "" : "  ·  ") + "\(key): \(value)"
        }
        return text
    }

    /// Whether every character of a text has a shape on the screen. Text that hides something (a character
    /// that reverses the reading order, one with no width, a control code) cannot be shown whole.
    static func isPlain(_ text: String) -> Bool {
        !text.unicodeScalars.contains {
            switch $0.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate, .unassigned: return true
            default: return false
            }
        }
    }
}

/// What the hook prints for the agent. Nil means print nothing, so the agent asks in its own window.
package enum HookOutput {
    package static func permissionRequest(_ decision: ControlDecision) -> String? {
        let body: [String: Any]
        switch decision {
        case .allow: body = ["behavior": "allow"]
        case .deny: body = ["behavior": "deny", "message": "Denied from RenderDock."]
        case .none: return nil
        }
        let object: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": body]]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) }
    }
}

// MARK: Policy

/// What may be allowed from RenderDock at all. Anything else can only be denied here, or left to the agent's own window.
package struct ControlPolicy: Codable, Equatable {
    /// The agent's action names that may be allowed. Read-only ones by default.
    package var approvable: [String]
    /// How long a request waits for an answer here before the agent's own prompt takes over.
    package var timeoutSec: Int
    /// A request whose text is longer than this, or runs over several lines, cannot be shown whole, so it cannot be allowed here.
    package var maxDetail: Int

    package init(approvable: [String] = ["Read", "Glob", "Grep", "LS"], timeoutSec: Int = 100, maxDetail: Int = 160) {
        self.approvable = approvable
        self.timeoutSec = timeoutSec
        self.maxDetail = maxDetail
    }

    package static func load(from url: URL) -> ControlPolicy {
        guard let data = try? Data(contentsOf: url), let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return ControlPolicy() }
        var p = ControlPolicy()
        if let list = o["approvable"] as? [String] { p.approvable = list }
        if let t = o["timeoutSec"] as? Int { p.timeoutSec = min(max(t, 5), 110) }   // always inside the hook's own time limit
        if let m = o["maxDetail"] as? Int { p.maxDetail = min(max(m, 20), 400) }
        return p
    }

    /// May this be allowed from here? If not, why not, in the UI language.
    package func verdict(action: String, detail: String) -> (approvable: Bool, reason: String?) {
        guard approvable.contains(action) else {
            return (false, L("「\(action)」这一类要在电脑上处理", "\"\(action)\" has to be handled on the computer"))
        }
        guard detail.count <= maxDetail, !detail.contains(where: \.isNewline) else {
            return (false, L("内容太长，这里显示不全，要在电脑上处理", "Too long to show whole here; handle it on the computer"))
        }
        guard HookInput.isPlain(detail), HookInput.isPlain(action) else {
            return (false, L("内容里有显示不出来的字符，要在电脑上处理", "It contains characters that cannot be shown; handle it on the computer"))
        }
        return (true, nil)
    }
}

/// One request waiting for an answer.
package struct ControlRequest: Identifiable, Equatable {
    /// Five lowercase letters. A decision names the request by this.
    package var id: String
    /// Which agent: claude-code, …
    package var tool: String
    package var sessionId: String
    package var project: String
    package var action: String
    package var detail: String
    package var fingerprint: String
    package var receivedAt: Date
    package var expiresAt: Date
    package var approvable: Bool
    package var reason: String?

    package init(id: String, tool: String, sessionId: String, project: String, action: String, detail: String, fingerprint: String,
                 receivedAt: Date, expiresAt: Date, approvable: Bool, reason: String? = nil) {
        self.id = id
        self.tool = tool
        self.sessionId = sessionId
        self.project = project
        self.action = action
        self.detail = detail
        self.fingerprint = fingerprint
        self.receivedAt = receivedAt
        self.expiresAt = expiresAt
        self.approvable = approvable
        self.reason = reason
    }
}

// MARK: Where things live

package struct ControlPaths: Equatable {
    package var directory: URL
    package var socket: URL { directory.appendingPathComponent("sock") }
    package var token: URL { directory.appendingPathComponent("token") }
    package var audit: URL { directory.appendingPathComponent("audit.jsonl") }
    package var policy: URL { directory.appendingPathComponent("control.json") }

    package init(directory: URL) { self.directory = directory }

    /// `~/Library/Application Support/RenderDock/control`, or the RENDERDOCK_CONTROL environment variable (used when testing).
    package static var standard: ControlPaths {
        if let custom = ProcessInfo.processInfo.environment["RENDERDOCK_CONTROL"], !custom.isEmpty {
            return ControlPaths(directory: URL(fileURLWithPath: custom))
        }
        return ControlPaths(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RenderDock/control"))
    }
}

// MARK: The app's side

/// Holds the requests that are waiting, and gives each its answer. Listens on a Unix socket in a directory only
/// this user can enter; each start writes a fresh token that a caller must present.
package final class ControlBroker {
    private let paths: ControlPaths
    private let queue = DispatchQueue(label: "renderdock.control")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var token = ""
    private var waiting: [String: (request: ControlRequest, fd: Int32, watch: DispatchSourceRead?)] = [:]
    /// Called on the main queue whenever the list of waiting requests changes.
    package var onChange: (() -> Void)?

    package init(paths: ControlPaths = .standard) { self.paths = paths }

    package var isRunning: Bool { queue.sync { listenFD >= 0 } }

    /// The requests waiting now, oldest first.
    package var pending: [ControlRequest] {
        queue.sync { waiting.values.map(\.request).sorted { $0.receivedAt < $1.receivedAt } }
    }

    /// Starts listening. False if the socket could not be set up (for instance the path is too long for a Unix socket).
    @discardableResult
    package func start() -> Bool {
        queue.sync {
            guard listenFD < 0 else { return true }
            let fm = FileManager.default
            try? fm.createDirectory(at: paths.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.directory.path)
            unlink(paths.socket.path)

            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let path = paths.socket.path
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            guard path.utf8.count < capacity else { return false }
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                raw.copyBytes(from: path.utf8)
            }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return false }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0, listen(fd, 16) == 0 else {
                close(fd)
                return false
            }
            chmod(path, 0o600)

            token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
            fm.createFile(atPath: paths.token.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])

            listenFD = fd
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.accept() }
            source.resume()
            acceptSource = source
            return true
        }
    }

    /// Stops listening. Everything still waiting is released without an answer, so the agents ask in their own windows.
    package func stop() {
        queue.sync {
            guard listenFD >= 0 else { return }
            for id in Array(waiting.keys) { finish(id, .none, source: "stopped") }
            acceptSource?.cancel()
            acceptSource = nil
            close(listenFD)
            listenFD = -1
            unlink(paths.socket.path)
            try? FileManager.default.removeItem(at: paths.token)
        }
        notify()
    }

    /// Answers a waiting request. False if there is no such request any more, or if it may not be allowed from here.
    @discardableResult
    package func decide(id: String, _ decision: ControlDecision, source: String) -> Bool {
        let done: Bool = queue.sync {
            guard let entry = waiting[id], decision != .none else { return false }
            if decision == .allow, !entry.request.approvable { return false }
            finish(id, decision, source: source)
            return true
        }
        if done { notify() }
        return done
    }

    // MARK: internals (all on `queue`)

    private func accept() {
        let fd = Darwin.accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        // The whole first line has one second to arrive: this queue also answers the panel, and a caller that
        // connects and says nothing must not hold it.
        guard let line = ControlWire.readLine(fd, limit: 262_144, within: 1),
              let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              message["token"] as? String == token, !token.isEmpty,
              let hookText = message["hook"] as? String, let hook = HookInput.parse(Data(hookText.utf8)),
              hook.event == "PermissionRequest" else {
            close(fd)
            return
        }
        let policy = ControlPolicy.load(from: paths.policy)
        let now = Date()
        var id = Self.newID()
        while waiting[id] != nil { id = Self.newID() }
        let verdict = policy.verdict(action: hook.action, detail: hook.detail)
        let request = ControlRequest(
            id: id, tool: message["tool"] as? String ?? AgentTool.claudeCode, sessionId: hook.sessionId,
            project: AgentSupport.project(hook.cwd), action: hook.action,
            detail: hook.detail.split(whereSeparator: \.isNewline).joined(separator: " ⏎ "), fingerprint: hook.fingerprint,
            receivedAt: now, expiresAt: now.addingTimeInterval(TimeInterval(policy.timeoutSec)),
            approvable: verdict.approvable, reason: verdict.reason)

        // If the caller goes away (the user answered in the agent's own window, or the hook was stopped), drop the request.
        let watch = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        watch.setEventHandler { [weak self] in
            // Anything it sends after the request is read and thrown away; the end of the stream is what matters.
            var scratch = [UInt8](repeating: 0, count: 256)
            if recv(fd, &scratch, scratch.count, MSG_DONTWAIT) == 0 {
                self?.finish(id, .none, source: "gone")
                self?.notify()
            }
        }
        // The connection is closed when the watch is over, not before: a handler already on its way must not
        // find the number given to somebody else's connection.
        watch.setCancelHandler { close(fd) }
        watch.resume()
        waiting[id] = (request, fd, watch)

        queue.asyncAfter(deadline: .now() + .seconds(policy.timeoutSec)) { [weak self] in
            guard let self, self.waiting[id]?.request.fingerprint == request.fingerprint else { return }
            self.finish(id, .none, source: "timeout")
            self.notify()
        }
        notify()
    }

    /// Sends the answer, closes the connection, and writes the record. One answer per request, ever.
    private func finish(_ id: String, _ decision: ControlDecision, source: String) {
        guard let entry = waiting.removeValue(forKey: id) else { return }
        ControlWire.writeLine(entry.fd, ["id": id, "decision": decision.rawValue, "fingerprint": entry.request.fingerprint])
        if let watch = entry.watch { watch.cancel() } else { close(entry.fd) }
        let r = entry.request
        let record: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()), "id": id, "tool": r.tool, "project": r.project, "action": r.action,
            "detail": String(r.detail.prefix(200)), "fingerprint": r.fingerprint, "decision": decision.rawValue, "source": source,
            "waitedSec": Int(Date().timeIntervalSince(r.receivedAt).rounded()),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        if !FileManager.default.fileExists(atPath: paths.audit.path) {
            FileManager.default.createFile(atPath: paths.audit.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        if let handle = try? FileHandle(forWritingTo: paths.audit) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data + [0x0A])
            try? handle.close()
        }
    }

    private func notify() {
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }

    /// Five letters from a–z without l, so an id read off a small screen is never mistaken.
    static func newID() -> String {
        let letters = Array("abcdefghijkmnopqrstuvwxyz")
        return String((0..<5).map { _ in letters.randomElement()! })
    }

    /// The record of every answer given (and every request that ran out of time), newest last.
    package static func auditRecords(paths: ControlPaths = .standard, limit: Int = 50) -> [[String: Any]] {
        guard let text = try? String(contentsOf: paths.audit, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").suffix(limit).compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    }
}

// MARK: The hook's side

package enum ControlClient {
    /// Asks the app about a request and waits for its answer. `.none` if the app is not listening, does not
    /// answer in time, or anything at all goes wrong: the hook then prints nothing.
    package static func ask(hookJSON: Data, tool: String = AgentTool.claudeCode, paths: ControlPaths = .standard, timeout: TimeInterval = 105) -> ControlDecision {
        guard let token = try? String(contentsOf: paths.token, encoding: .utf8), !token.isEmpty else { return .none }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = paths.socket.path
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return .none }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .none }
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return .none }
        guard ControlWire.writeLine(fd, ["token": token, "tool": tool, "hook": String(decoding: hookJSON, as: UTF8.self)]) else { return .none }

        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, Int32(max(0, timeout) * 1000)) > 0,
              let line = ControlWire.readLine(fd, limit: 4096),
              let answer = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let decision = (answer["decision"] as? String).flatMap(ControlDecision.init(rawValue:)) else { return .none }
        // The answer must be for exactly what was asked.
        if let asked = HookInput.parse(hookJSON), answer["fingerprint"] as? String != asked.fingerprint { return .none }
        return decision
    }
}

enum ControlWire {
    /// One line of JSON, newline-terminated.
    @discardableResult
    static func writeLine(_ fd: Int32, _ object: [String: Any]) -> Bool {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return false }
        data.append(0x0A)
        return data.withUnsafeBytes { raw -> Bool in
            var sent = 0
            while sent < raw.count {
                let n = write(fd, raw.baseAddress! + sent, raw.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    /// One line, without its newline. With `within`, the whole line has that many seconds to arrive, however
    /// slowly the other end sends it.
    static func readLine(_ fd: Int32, limit: Int, within: TimeInterval? = nil) -> Data? {
        let deadline = within.map { Date().addingTimeInterval($0) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < limit {
            if let deadline {
                let left = deadline.timeIntervalSinceNow
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard left > 0, poll(&descriptor, 1, Int32(left * 1000) + 1) > 0 else { return nil }
            }
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { return nil }
            if let end = buffer[..<n].firstIndex(of: 0x0A) {
                data.append(contentsOf: buffer[..<end])
                return data
            }
            data.append(contentsOf: buffer[..<n])
        }
        return nil
    }
}

// MARK: Putting the hook into an agent's settings (only ever at the user's own command)

/// Adds or removes the one hook entry RenderDock needs in a Claude Code settings file. Pure: it turns the
/// file's contents into new contents and touches nothing itself.
package enum HookSettings {
    /// The hook entry, recognisable later by its command.
    static func entry(command: String) -> [String: Any] {
        ["hooks": [["type": "command", "command": command, "timeout": 120]]]
    }

    static func isOurHook(_ hook: Any) -> Bool {
        ((hook as? [String: Any])?["command"] as? String).map { $0.hasSuffix(" hook") && $0.lowercased().contains("renderdock") } ?? false
    }

    static func isOurs(_ group: Any) -> Bool {
        ((group as? [String: Any])?["hooks"] as? [Any])?.contains(where: isOurHook) ?? false
    }

    /// The groups with RenderDock's hook taken out of each. A group that held nothing else goes with it; a
    /// group that also holds a hook of the user's own keeps that hook and everything else about itself.
    static func withoutOurs(_ groups: [Any]) -> [Any] {
        groups.compactMap { group -> Any? in
            guard isOurs(group), var object = group as? [String: Any], let hooks = object["hooks"] as? [Any] else { return group }
            let rest = hooks.filter { !isOurHook($0) }
            if rest.isEmpty { return nil }
            object["hooks"] = rest
            return object
        }
    }

    /// Where the copy of a settings file as it was before the hook went in is kept, and the mark that says
    /// RenderDock created the file: in RenderDock's own directory, not next to the settings, so that nothing
    /// extra appears inside a project (where it could be committed by accident).
    package static func keepsakes(for settings: URL, paths: ControlPaths = .standard) -> (directory: URL, backup: URL, created: URL) {
        let digest = SHA256.hash(data: Data(settings.standardizedFileURL.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let directory = paths.directory.appendingPathComponent("hook-backups")
        return (directory, directory.appendingPathComponent("\(digest).before.json"), directory.appendingPathComponent("\(digest).created"))
    }

    /// The settings with RenderDock's PermissionRequest hook added. Nil if `original` is not a JSON object.
    package static func adding(command: String, to original: Data?) -> Data? {
        var root: [String: Any] = [:]
        if let original, !original.isEmpty {
            guard let parsed = (try? JSONSerialization.jsonObject(with: original)) as? [String: Any] else { return nil }
            root = parsed
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var groups = withoutOurs(hooks["PermissionRequest"] as? [Any] ?? [])
        groups.append(entry(command: command))
        hooks["PermissionRequest"] = groups
        root["hooks"] = hooks
        return encode(root)
    }

    /// The settings with RenderDock's hook taken out, and nothing else changed. Nil if `original` is not a JSON object.
    package static func removing(from original: Data) -> Data? {
        guard var root = (try? JSONSerialization.jsonObject(with: original)) as? [String: Any] else { return nil }
        guard var hooks = root["hooks"] as? [String: Any], let groups = hooks["PermissionRequest"] as? [Any] else { return original }
        guard groups.contains(where: isOurs) else { return original }
        let rest = withoutOurs(groups)
        if rest.isEmpty { hooks["PermissionRequest"] = nil } else { hooks["PermissionRequest"] = rest }
        if hooks.isEmpty { root["hooks"] = nil } else { root["hooks"] = hooks }
        return encode(root)
    }

    package static func isInstalled(in original: Data?) -> Bool {
        guard let original, let root = (try? JSONSerialization.jsonObject(with: original)) as? [String: Any],
              let groups = (root["hooks"] as? [String: Any])?["PermissionRequest"] as? [Any] else { return false }
        return groups.contains(where: isOurs)
    }

    private static func encode(_ root: [String: Any]) -> Data? {
        guard var data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return nil }
        data.append(0x0A)
        return data
    }
}
