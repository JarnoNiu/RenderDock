import Foundation

// A way in for any program on this Mac: a script, or an agent that knows nothing of RenderDock beyond one
// command. It can do three things:
//
//   notify    put a short notice on the dock (and on a desk device)
//   progress  show how far a task of its own has got, as RenderDock shows a render's
//   ask       put a question with two to four answers, and wait for the user's pick
//
// This is not the channel for approving what an agent wants to do (that is Control.swift, with its own rules).
// A question here is the caller's own question, the answer goes back to the caller and to nobody else, and
// nothing is allowed or refused by it. Off unless switched on. See docs/AGENT-ENTRY.md.

// MARK: What arrives

package enum InboxLevel: String, Codable {
    case info, done, error
}

/// A short notice. It stays for a while and then goes.
package struct InboxNotice: Identifiable, Equatable {
    package var id: String
    /// Who sent it, in the sender's own words. Not checked: any program of this user can say anything here.
    package var from: String
    package var title: String
    package var body: String
    package var level: InboxLevel
    package var at: Date

    package init(id: String, from: String, title: String, body: String, level: InboxLevel, at: Date) {
        self.id = id
        self.from = from
        self.title = title
        self.body = body
        self.level = level
        self.at = at
    }
}

/// A task some program is reporting on.
package struct InboxTask: Identifiable, Equatable {
    /// The sender's own name for the task; a later report with the same sender and name updates it.
    package var id: String
    package var from: String
    package var title: String
    /// 0…1, or nil when the sender does not know how far along it is.
    package var fraction: Double?
    package var etaSec: Int?
    /// working | done | error
    package var state: String
    package var startedAt: Date
    package var updatedAt: Date

    package init(id: String, from: String, title: String, fraction: Double?, etaSec: Int?, state: String, startedAt: Date, updatedAt: Date) {
        self.id = id
        self.from = from
        self.title = title
        self.fraction = fraction
        self.etaSec = etaSec
        self.state = state
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }
}

/// A question waiting for one of its answers.
package struct InboxQuestion: Identifiable, Equatable {
    package var id: String
    package var from: String
    package var text: String
    package var choices: [String]
    package var askedAt: Date
    package var expiresAt: Date

    package init(id: String, from: String, text: String, choices: [String], askedAt: Date, expiresAt: Date) {
        self.id = id
        self.from = from
        self.text = text
        self.choices = choices
        self.askedAt = askedAt
        self.expiresAt = expiresAt
    }
}

/// Everything in the inbox at one moment, for whoever draws it.
package struct InboxView: Equatable {
    /// Newest first.
    package var notices: [InboxNotice] = []
    /// Most recently reported first.
    package var tasks: [InboxTask] = []
    /// Oldest first: that one is answered first.
    package var questions: [InboxQuestion] = []

    package init(notices: [InboxNotice] = [], tasks: [InboxTask] = [], questions: [InboxQuestion] = []) {
        self.notices = notices
        self.tasks = tasks
        self.questions = questions
    }

    package static let empty = InboxView()
    package var isEmpty: Bool { notices.isEmpty && tasks.isEmpty && questions.isEmpty }
}

package enum InboxLimits {
    package static let from = 24
    package static let title = 40
    package static let body = 140
    package static let question = 120
    package static let choice = 14
    package static let choices = 2...4
    package static let taskName = 40
    package static let notices = 8
    package static let tasks = 8
    package static let questions = 4
    /// A notice goes after this long.
    package static let noticeLife: TimeInterval = 600
    /// A task nobody has reported on for this long is taken to be gone; a finished one is kept this long.
    package static let taskQuiet: TimeInterval = 600
    package static let taskDone: TimeInterval = 300
    package static let askTimeout = 5...600
    package static let askTimeoutDefault = 120
    /// More than this many notices in a minute and the rest are refused. The same for questions, with a lower
    /// number: each one may raise a notification on the Mac and light a device.
    package static let noticesPerMinute = 30
    package static let questionsPerMinute = 12

    /// The text as one line: line breaks become spaces, and what cannot be seen (control characters) is dropped.
    package static func oneLine(_ text: String) -> String {
        let visible = String(text.unicodeScalars.filter { $0.properties.generalCategory != .control || $0 == "\n" || $0 == "\r" || $0 == "\t" }.map(Character.init))
        return visible.split(whereSeparator: { $0.isNewline || $0 == "\t" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// One line of text, cut to `limit`. For what is only read; a question and its answers are never cut (see `problem`).
    package static func tidy(_ text: String, _ limit: Int) -> String {
        let line = oneLine(text)
        return line.count <= limit ? line : String(line.prefix(max(0, limit - 1))) + "…"
    }

    /// Why a question cannot be asked as it stands, or nil if it can. A question that is too long is refused,
    /// not shortened: the user would be answering something other than what was asked.
    package static func problem(question: String, choices: [String]) -> String? {
        if question.isEmpty { return "nothing asked" }
        if question.count > InboxLimits.question { return "the question is too long (\(InboxLimits.question) characters at most)" }
        if !InboxLimits.choices.contains(choices.count) { return "a question needs two to four answers" }
        if choices.contains(where: \.isEmpty) { return "an answer is empty" }
        if let long = choices.first(where: { $0.count > InboxLimits.choice }) { return "the answer \"\(long)\" is too long (\(InboxLimits.choice) characters at most)" }
        if Set(choices).count != choices.count { return "two answers are the same" }
        return nil
    }
}

// MARK: Where things live

package struct InboxPaths: Equatable {
    package var directory: URL
    package var socket: URL { directory.appendingPathComponent("sock") }
    package var token: URL { directory.appendingPathComponent("token") }

    package init(directory: URL) { self.directory = directory }

    /// `~/Library/Application Support/RenderDock/inbox`, or the RENDERDOCK_INBOX environment variable (used when testing).
    package static var standard: InboxPaths {
        if let custom = ProcessInfo.processInfo.environment["RENDERDOCK_INBOX"], !custom.isEmpty {
            return InboxPaths(directory: URL(fileURLWithPath: custom))
        }
        return InboxPaths(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RenderDock/inbox"))
    }
}

// MARK: The app's side

/// Takes notices, progress reports and questions on a Unix socket in a directory only this user can enter, and
/// holds them until they have gone stale, been answered, or been dismissed. Nothing is written to disk.
package final class InboxServer {
    private let paths: InboxPaths
    private let queue = DispatchQueue(label: "renderdock.inbox")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var sweep: DispatchSourceTimer?
    private var token = ""
    private var notices: [InboxNotice] = []
    private var tasks: [String: InboxTask] = [:]
    private var waiting: [String: (question: InboxQuestion, fd: Int32, watch: DispatchSourceRead?)] = [:]
    private var recentNotices: [Date] = []
    private var recentQuestions: [Date] = []
    /// Called on the main queue whenever what the inbox holds changes.
    package var onChange: (() -> Void)?
    /// Called on the main queue with each notice as it arrives, and each question as it is asked.
    package var onArrival: ((InboxNotice?, InboxQuestion?) -> Void)?

    package init(paths: InboxPaths = .standard) { self.paths = paths }

    package var isRunning: Bool { queue.sync { listenFD >= 0 } }

    package var view: InboxView {
        queue.sync {
            InboxView(notices: notices.sorted { $0.at > $1.at },
                      tasks: tasks.values.sorted { $0.updatedAt > $1.updatedAt },
                      questions: waiting.values.map(\.question).sorted { $0.askedAt < $1.askedAt })
        }
    }

    /// Starts listening. False if the socket could not be set up.
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
            guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
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

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 15, repeating: 15)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                if self.prune(now: Date()) { self.notify() }
            }
            timer.resume()
            sweep = timer
            return true
        }
    }

    /// Stops listening and forgets everything. Whoever is waiting for an answer is told there will be none.
    package func stop() {
        queue.sync {
            guard listenFD >= 0 else { return }
            for id in Array(waiting.keys) { finish(id, index: nil, reason: "stopped") }
            notices = []
            tasks = [:]
            sweep?.cancel()
            sweep = nil
            acceptSource?.cancel()
            acceptSource = nil
            close(listenFD)
            listenFD = -1
            unlink(paths.socket.path)
            try? FileManager.default.removeItem(at: paths.token)
        }
        notify()
    }

    /// The user's pick for a question. False if there is no such question any more, or no such answer.
    @discardableResult
    package func answer(id: String, index: Int) -> Bool {
        let done: Bool = queue.sync {
            guard let entry = waiting[id], entry.question.choices.indices.contains(index) else { return false }
            finish(id, index: index, reason: nil)
            return true
        }
        if done { notify() }
        return done
    }

    /// Takes a question off without answering it: the caller is told nobody answered.
    package func dismissQuestion(_ id: String) {
        queue.sync { finish(id, index: nil, reason: "dismissed") }
        notify()
    }

    package func dismissNotice(_ id: String) {
        queue.sync { notices.removeAll { $0.id == id } }
        notify()
    }

    package func dismissTask(_ id: String) {
        queue.sync { tasks[id] = nil }
        notify()
    }

    // MARK: internals (all on `queue`)

    /// Drops what has gone stale. True if anything went.
    private func prune(now: Date) -> Bool {
        let before = (notices.count, tasks.count)
        notices.removeAll { now.timeIntervalSince($0.at) > InboxLimits.noticeLife }
        tasks = tasks.filter { _, task in
            now.timeIntervalSince(task.updatedAt) <= (task.state == "working" ? InboxLimits.taskQuiet : InboxLimits.taskDone)
        }
        return before != (notices.count, tasks.count)
    }

    private func accept() {
        let fd = Darwin.accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        // The whole first line has one second to arrive: this queue also serves the panel, and a caller that
        // connects and says nothing must not hold it.
        guard let line = ControlWire.readLine(fd, limit: 16_384, within: 1),
              let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              message["token"] as? String == token, !token.isEmpty else {
            close(fd)
            return
        }
        func refuse(_ reason: String) {
            ControlWire.writeLine(fd, ["ok": false, "reason": reason])
            close(fd)
        }
        let now = Date()
        let from = InboxLimits.tidy(message["from"] as? String ?? "", InboxLimits.from)
        switch message["op"] as? String {
        case "notify":
            let title = InboxLimits.tidy(message["title"] as? String ?? "", InboxLimits.title)
            let body = InboxLimits.tidy(message["body"] as? String ?? "", InboxLimits.body)
            guard !title.isEmpty || !body.isEmpty else { return refuse("nothing to say") }
            recentNotices.removeAll { now.timeIntervalSince($0) > 60 }
            guard recentNotices.count < InboxLimits.noticesPerMinute else { return refuse("too many notices") }
            recentNotices.append(now)
            let notice = InboxNotice(id: newID(), from: from, title: title, body: body,
                                     level: (message["level"] as? String).flatMap(InboxLevel.init(rawValue:)) ?? .info, at: now)
            notices.append(notice)
            if notices.count > InboxLimits.notices { notices.removeFirst(notices.count - InboxLimits.notices) }
            ControlWire.writeLine(fd, ["ok": true, "id": notice.id])
            close(fd)
            notify()
            DispatchQueue.main.async { [weak self] in self?.onArrival?(notice, nil) }

        case "progress":
            let name = InboxLimits.tidy(message["id"] as? String ?? "", InboxLimits.taskName)
            guard !name.isEmpty else { return refuse("a task needs a name") }
            let key = from + "/" + name
            var task = tasks[key] ?? InboxTask(id: key, from: from, title: name, fraction: nil, etaSec: nil, state: "working", startedAt: now, updatedAt: now)
            if tasks[key] == nil, tasks.count >= InboxLimits.tasks {
                _ = prune(now: now)
                guard tasks.count < InboxLimits.tasks else { return refuse("too many tasks") }
            }
            if let title = message["title"] as? String, !title.isEmpty { task.title = InboxLimits.tidy(title, InboxLimits.title) }
            if let percent = (message["percent"] as? NSNumber)?.doubleValue { task.fraction = min(1, max(0, percent / 100)) }
            task.etaSec = (message["eta"] as? NSNumber).map { max(0, $0.intValue) }
            switch message["state"] as? String {
            case "done": task.state = "done"; task.fraction = 1; task.etaSec = nil
            case "failed", "error": task.state = "error"; task.etaSec = nil
            default: task.state = "working"
            }
            task.updatedAt = now
            tasks[key] = task
            ControlWire.writeLine(fd, ["ok": true])
            close(fd)
            notify()

        case "ask":
            let text = InboxLimits.oneLine(message["text"] as? String ?? "")
            let choices = (message["choices"] as? [String] ?? []).map(InboxLimits.oneLine)
            if let problem = InboxLimits.problem(question: text, choices: choices) { return refuse(problem) }
            guard waiting.count < InboxLimits.questions else { return refuse("too many questions waiting") }
            recentQuestions.removeAll { now.timeIntervalSince($0) > 60 }
            guard recentQuestions.count < InboxLimits.questionsPerMinute else { return refuse("too many questions") }
            recentQuestions.append(now)
            let seconds = min(InboxLimits.askTimeout.upperBound, max(InboxLimits.askTimeout.lowerBound,
                                                                     (message["timeout"] as? NSNumber)?.intValue ?? InboxLimits.askTimeoutDefault))
            var id = newID()
            while waiting[id] != nil { id = newID() }
            let question = InboxQuestion(id: id, from: from, text: text, choices: choices, askedAt: now, expiresAt: now.addingTimeInterval(TimeInterval(seconds)))
            // If the caller goes away, so does its question.
            let watch = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            watch.setEventHandler { [weak self] in
                // Anything it sends after the question is read and thrown away; the end of the stream is what matters.
                var scratch = [UInt8](repeating: 0, count: 256)
                if recv(fd, &scratch, scratch.count, MSG_DONTWAIT) == 0 {
                    self?.finish(id, index: nil, reason: "gone")
                    self?.notify()
                }
            }
            // Closed when the watch is over, not before: a handler already on its way must not find the number
            // given to somebody else's connection.
            watch.setCancelHandler { close(fd) }
            watch.resume()
            waiting[id] = (question, fd, watch)
            queue.asyncAfter(deadline: .now() + .seconds(seconds)) { [weak self] in
                guard let self, self.waiting[id]?.question.askedAt == question.askedAt else { return }
                self.finish(id, index: nil, reason: "timeout")
                self.notify()
            }
            notify()
            DispatchQueue.main.async { [weak self] in self?.onArrival?(nil, question) }

        default:
            refuse("unknown request")
        }
    }

    /// Sends the caller its answer, or the reason there is none, and lets the question go. Once per question.
    private func finish(_ id: String, index: Int?, reason: String?) {
        guard let entry = waiting.removeValue(forKey: id) else { return }
        if let index {
            ControlWire.writeLine(entry.fd, ["ok": true, "index": index, "choice": entry.question.choices[index]])
        } else {
            ControlWire.writeLine(entry.fd, ["ok": false, "reason": reason ?? "no answer"])
        }
        if let watch = entry.watch { watch.cancel() } else { close(entry.fd) }
    }

    private func notify() {
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }

    private func newID() -> String { ControlBroker.newID() }
}

// MARK: The caller's side

package enum InboxClient {
    /// `unavailable`: the app is not listening (not running, or the entry is switched off).
    package enum Sent: Equatable {
        case ok(id: String?)
        case refused(String)
        case unavailable
    }

    package enum Answer: Equatable {
        case chosen(index: Int, label: String)
        /// Nobody answered: it ran out of time, was dismissed, or the app stopped.
        case none(String)
        case refused(String)
        case unavailable
    }

    private enum Reply {
        case object([String: Any])
        /// Nothing is listening there.
        case noOne
        /// It was taken, and then nothing came back in time (or the connection was closed without a word).
        case silence
    }

    /// Sends one request and waits up to `wait` seconds for the reply.
    private static func send(_ object: [String: Any], paths: InboxPaths, wait: TimeInterval) -> Reply {
        guard let token = try? String(contentsOf: paths.token, encoding: .utf8), !token.isEmpty else { return .noOne }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = paths.socket.path
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return .noOne }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .noOne }
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return .noOne }
        var message = object
        message["token"] = token
        guard ControlWire.writeLine(fd, message) else { return .noOne }
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, Int32(max(0, wait) * 1000)) > 0, let line = ControlWire.readLine(fd, limit: 4096),
              let reply = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return .silence }
        return .object(reply)
    }

    private static func sent(_ reply: Reply) -> Sent {
        // A notice or a report is answered at once. Silence means whatever is there is not RenderDock's entry.
        guard case .object(let reply) = reply else { return .unavailable }
        if reply["ok"] as? Bool == true { return .ok(id: reply["id"] as? String) }
        return .refused(reply["reason"] as? String ?? "refused")
    }

    // What is only read is cut to its limit here, before it is sent: however much a caller passes, the line
    // that goes over the socket stays small, and the answer says what happened instead of nothing coming back.
    package static func notify(title: String, body: String, level: InboxLevel = .info, from: String, paths: InboxPaths = .standard) -> Sent {
        sent(send(["op": "notify", "from": InboxLimits.tidy(from, InboxLimits.from), "title": InboxLimits.tidy(title, InboxLimits.title),
                   "body": InboxLimits.tidy(body, InboxLimits.body), "level": level.rawValue], paths: paths, wait: 5))
    }

    /// `state`: "working", "done" or "failed".
    package static func progress(name: String, title: String?, percent: Double?, etaSec: Int?, state: String = "working", from: String,
                                 paths: InboxPaths = .standard) -> Sent {
        var message: [String: Any] = ["op": "progress", "from": InboxLimits.tidy(from, InboxLimits.from),
                                      "id": InboxLimits.tidy(name, InboxLimits.taskName), "state": state]
        if let title { message["title"] = InboxLimits.tidy(title, InboxLimits.title) }
        if let percent { message["percent"] = percent }
        if let etaSec { message["eta"] = etaSec }
        return sent(send(message, paths: paths, wait: 5))
    }

    package static func ask(text: String, choices: [String], timeoutSec: Int = InboxLimits.askTimeoutDefault, from: String,
                            paths: InboxPaths = .standard) -> Answer {
        let seconds = min(InboxLimits.askTimeout.upperBound, max(InboxLimits.askTimeout.lowerBound, timeoutSec))
        // A question is never cut, so one that cannot be asked as it stands is refused here, with the reason.
        let question = InboxLimits.oneLine(text), answers = choices.map(InboxLimits.oneLine)
        if let problem = InboxLimits.problem(question: question, choices: answers) { return .refused(problem) }
        let reply: [String: Any]
        switch send(["op": "ask", "from": InboxLimits.tidy(from, InboxLimits.from), "text": question, "choices": answers, "timeout": seconds],
                    paths: paths, wait: TimeInterval(seconds + 5)) {
        case .object(let object): reply = object
        case .noOne: return .unavailable
        case .silence: return .none("timeout")
        }
        if reply["ok"] as? Bool == true, let index = reply["index"] as? Int, let label = reply["choice"] as? String {
            return .chosen(index: index, label: label)
        }
        let reason = reply["reason"] as? String ?? "no answer"
        return ["timeout", "dismissed", "stopped", "gone"].contains(reason) ? .none(reason) : .refused(reason)
    }
}
