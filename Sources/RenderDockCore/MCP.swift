import Foundation

// The entry for other programs (docs/AGENT-ENTRY.md), offered a second way: as a Model Context Protocol server
// over standard input and output, for agents that would rather call a tool than run a command.
//
// The transport is the protocol's "stdio" one: each message is one line of JSON-RPC 2.0, in on standard input
// and out on standard output, and nothing else may be written to standard output. This file is the protocol
// only. What a tool does is handed in (`Backend`), so that all of it can be checked without the app running.

package struct MCPServer {
    /// What the tools reach. In the command-line tool these are the same calls `renderdock notify`, `progress`,
    /// `ask` and `status` make.
    package struct Backend {
        package var notify: (_ title: String, _ body: String, _ level: InboxLevel, _ from: String) -> InboxClient.Sent
        package var progress: (_ name: String, _ title: String?, _ percent: Double?, _ etaSec: Int?, _ state: String, _ from: String) -> InboxClient.Sent
        package var ask: (_ text: String, _ choices: [String], _ timeoutSec: Int, _ from: String) -> InboxClient.Answer
        /// What is rendering and what the agents' sessions are doing, as a few lines of text.
        package var status: () -> String

        package init(notify: @escaping (String, String, InboxLevel, String) -> InboxClient.Sent,
                     progress: @escaping (String, String?, Double?, Int?, String, String) -> InboxClient.Sent,
                     ask: @escaping (String, [String], Int, String) -> InboxClient.Answer,
                     status: @escaping () -> String) {
            self.notify = notify
            self.progress = progress
            self.ask = ask
            self.status = status
        }
    }

    /// The revisions of the protocol this speaks, newest first. A client that asks for one of them gets it;
    /// one that asks for anything else is offered the newest, and decides for itself whether to go on.
    package static let versions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    package static let notTaking = "RenderDock is not taking this: it is not running, or \"Take Notices, Progress and Questions from Other Programs\" is off in its menu"

    private let backend: Backend
    /// Who is speaking, when it was said on the command line or in RENDERDOCK_FROM. Otherwise the client's own
    /// name from its first message is used. It is shown as given; nothing checks it.
    private let fixedFrom: String?
    private var clientName = ""

    package init(backend: Backend, from: String? = nil) {
        self.backend = backend
        self.fixedFrom = (from ?? "").isEmpty ? nil : from
    }

    private var from: String { fixedFrom ?? clientName }

    // MARK: One message in, at most one out

    /// Takes one line. Returns the line to write back (without the line break), or nil when nothing is owed:
    /// a notification, or a line that is somebody's answer to a request this server never made.
    package mutating func handle(_ line: Data) -> Data? {
        guard let parsed = try? JSONSerialization.jsonObject(with: line) else {
            return Self.failure(id: NSNull(), code: -32700, message: "parse error: not JSON")
        }
        // Several messages in one array were allowed once and no longer are; nothing here needs them.
        guard let message = parsed as? [String: Any] else {
            return Self.failure(id: NSNull(), code: -32600, message: "invalid request: one message per line")
        }
        let id = message["id"]
        guard let method = message["method"] as? String else {
            // A response (to nothing this server asked), or not a request at all.
            if message["result"] != nil || message["error"] != nil { return nil }
            return Self.failure(id: id ?? NSNull(), code: -32600, message: "invalid request: no method")
        }
        // No id: a notification. It is never answered, whatever it says.
        guard let id, !(id is NSNull) else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            if let info = params["clientInfo"] as? [String: Any], let name = info["name"] as? String { clientName = InboxLimits.tidy(name, InboxLimits.from) }
            let asked = params["protocolVersion"] as? String ?? ""
            let result: [String: Any] = [
                "protocolVersion": Self.versions.contains(asked) ? asked : Self.versions[0],
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "renderdock", "title": "RenderDock", "version": StateSnapshot.appVersion],
                "instructions": "RenderDock is a small dock on this Mac that shows render progress and what coding agents are doing, "
                    + "and can pass that on to a display on the desk. Use `notify` to tell the user something, `progress` to show how far "
                    + "a long task of yours has got, and `ask` to put a short question with two to four answers in front of them and wait "
                    + "for the one they pick. `ask` is for a choice, not for permission: nothing is approved by answering it. "
                    + "`status` says what is rendering and what other sessions are doing.",
            ]
            return Self.success(id: id, result)
        case "ping":
            return Self.success(id: id, [:])
        case "tools/list":
            return Self.success(id: id, ["tools": Self.tools])
        case "tools/call":
            guard let name = params["name"] as? String else { return Self.failure(id: id, code: -32602, message: "invalid params: no tool named") }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            guard let outcome = call(name, arguments) else { return Self.failure(id: id, code: -32602, message: "unknown tool: \(name)") }
            return Self.success(id: id, ["content": [["type": "text", "text": outcome.text]], "isError": outcome.isError])
        default:
            return Self.failure(id: id, code: -32601, message: "method not found: \(method)")
        }
    }

    // MARK: The tools

    /// What a tool call came to: the text to give back, and whether it counts as having failed. A question
    /// nobody answered has not failed; it has an answer of its own ("no answer"), which the caller must hear.
    package struct Outcome: Equatable {
        package var text: String
        package var isError: Bool
    }

    private func call(_ name: String, _ a: [String: Any]) -> Outcome? {
        func text(_ key: String) -> String? { a[key] as? String }
        /// A whole number, given as one (not as "3", not as 3.5, not as true).
        func whole(_ key: String) -> Int? {
            guard let number = a[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), let value = Int(exactly: number.doubleValue) else { return nil }
            return value
        }
        func number(_ key: String) -> Double? {
            guard let number = a[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return number.doubleValue
        }
        func wrong(_ what: String) -> Outcome { Outcome(text: what, isError: true) }
        func sent(_ result: InboxClient.Sent, _ done: String) -> Outcome {
            switch result {
            case .ok: return Outcome(text: done, isError: false)
            case .refused(let reason): return wrong("refused: \(reason)")
            case .unavailable: return wrong(Self.notTaking)
            }
        }
        switch name {
        case "notify":
            let body = text("body") ?? "", title = text("title") ?? ""
            guard !body.isEmpty || !title.isEmpty else { return wrong("nothing to say: give `body`, `title`, or both") }
            var level = InboxLevel.info
            if a["level"] != nil {
                guard let known = text("level").flatMap(InboxLevel.init(rawValue:)) else { return wrong("`level` is \"info\", \"done\" or \"error\"") }
                level = known
            }
            return sent(backend.notify(title, body, level, from), "shown")
        case "progress":
            guard let task = text("name"), !task.isEmpty else { return wrong("`name` is needed: one short name for the task, the same every time") }
            var percent: Double?
            if a["percent"] != nil {
                guard let value = number("percent"), (0...100).contains(value) else { return wrong("`percent` is a number from 0 to 100") }
                percent = value
            }
            var eta: Int?
            if a["eta_seconds"] != nil {
                guard let value = whole("eta_seconds"), value >= 0 else { return wrong("`eta_seconds` is a whole number of seconds") }
                eta = value
            }
            let state = text("state") ?? "working"
            guard ["working", "done", "failed"].contains(state) else { return wrong("`state` is \"working\", \"done\" or \"failed\"") }
            return sent(backend.progress(task, text("title"), percent, eta, state, from), state == "working" ? "shown" : "shown as \(state)")
        case "ask":
            let question = InboxLimits.oneLine(text("question") ?? "")
            guard let raw = a["choices"] as? [Any], raw.allSatisfy({ $0 is String }) else { return wrong("`choices` is a list of two to four short answers") }
            let choices = raw.compactMap { $0 as? String }.map(InboxLimits.oneLine)
            if let problem = InboxLimits.problem(question: question, choices: choices) { return wrong(problem) }
            var timeout = InboxLimits.askTimeoutDefault
            if a["timeout_seconds"] != nil {
                guard let value = whole("timeout_seconds"), InboxLimits.askTimeout.contains(value) else {
                    return wrong("`timeout_seconds` is a whole number from \(InboxLimits.askTimeout.lowerBound) to \(InboxLimits.askTimeout.upperBound)")
                }
                timeout = value
            }
            switch backend.ask(question, choices, timeout, from) {
            case .chosen(_, let label): return Outcome(text: label, isError: false)
            case .none(let reason): return Outcome(text: "no answer (\(reason)): nobody picked one. Do not take that for any of the answers.", isError: false)
            case .refused(let reason): return wrong("refused: \(reason)")
            case .unavailable: return wrong(Self.notTaking)
            }
        case "status":
            return Outcome(text: backend.status(), isError: false)
        default:
            return nil
        }
    }

    /// The tools as they are listed: a name, what it is for, and the shape of what it takes.
    package static let tools: [[String: Any]] = [
        [
            "name": "notify",
            "title": "Tell the user something",
            "description": "Shows a short notice on RenderDock (and on a desk display, if one is connected), for something the user should see "
                + "without having to look at this session: a long job finished, something failed, a result is ready. "
                + "Text is cut to one line of \(InboxLimits.title) characters for the title and \(InboxLimits.body) for the body. Not for a question: use `ask`.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "body": ["type": "string", "description": "What to say, in a sentence or two."],
                    "title": ["type": "string", "description": "A few words to put above it. Optional."],
                    "level": ["type": "string", "enum": ["info", "done", "error"], "description": "How it went: \"done\", \"error\", or plain \"info\" (the default)."],
                ] as [String: Any],
                "required": ["body"],
            ] as [String: Any],
        ],
        [
            "name": "progress",
            "title": "Show how far a task has got",
            "description": "Shows a long task of yours in RenderDock's list, with a percentage if you have one. Call it again with the same `name` "
                + "as the task moves on, and once more with `state` \"done\" or \"failed\" when it ends. A task not reported on for ten minutes is dropped.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "One short name for the task (\(InboxLimits.taskName) characters at most), the same on every call."],
                    "title": ["type": "string", "description": "What to show instead of the name. Optional."],
                    "percent": ["type": "number", "minimum": 0, "maximum": 100, "description": "How far along, 0 to 100. Leave it out if you cannot say."],
                    "eta_seconds": ["type": "integer", "minimum": 0, "description": "Seconds you expect it still to take. Optional."],
                    "state": ["type": "string", "enum": ["working", "done", "failed"], "description": "\"working\" (the default), or how it ended."],
                ] as [String: Any],
                "required": ["name"],
            ] as [String: Any],
        ],
        [
            "name": "ask",
            "title": "Ask the user to pick an answer",
            "description": "Puts a short question with two to four answers in front of the user, on RenderDock and on a desk display, and waits for "
                + "the one they pick. Returns that answer's text. If nobody picks one in time it returns \"no answer\", which is not a yes. "
                + "It is for a choice between ways to go on, not for permission to do something risky: an answer here approves nothing by itself. "
                + "The question is \(InboxLimits.question) characters at most and each answer \(InboxLimits.choice); longer ones are refused, not cut.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "question": ["type": "string", "description": "The question, one line."],
                    "choices": ["type": "array", "items": ["type": "string"], "minItems": 2, "maxItems": 4, "description": "The answers to pick from, each a word or two."],
                    "timeout_seconds": ["type": "integer", "minimum": InboxLimits.askTimeout.lowerBound, "maximum": InboxLimits.askTimeout.upperBound,
                                        "description": "How long to wait for an answer. \(InboxLimits.askTimeoutDefault) if left out."],
                ] as [String: Any],
                "required": ["question", "choices"],
            ] as [String: Any],
        ],
        [
            "name": "status",
            "title": "What is going on on this Mac",
            "description": "What is rendering right now (which shots, how far, how long to go) and what coding agents' sessions are doing, "
                + "as RenderDock sees it. Read-only. Takes a second or two.",
            "inputSchema": ["type": "object", "properties": [String: Any]()] as [String: Any],
        ],
    ]

    // MARK: Lines out

    private static func line(_ object: [String: Any]) -> Data {
        // What cannot be written as JSON must not be handed to the writer: it does not fail, it raises. An id
        // can be such a thing (a number too large to be one parses, on this system, as minus infinity). The
        // answer then goes out without the id it cannot repeat.
        var object = object
        if !JSONSerialization.isValidJSONObject(object) {
            object["id"] = NSNull()
            guard JSONSerialization.isValidJSONObject(object) else {
                return Data("{\"error\":{\"code\":-32603,\"message\":\"internal error\"},\"id\":null,\"jsonrpc\":\"2.0\"}".utf8)
            }
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }

    private static func success(id: Any, _ result: [String: Any]) -> Data {
        line(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func failure(id: Any, code: Int, message: String) -> Data {
        line(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }
}
