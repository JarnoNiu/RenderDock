import Foundation
import Network

/// The local, read-only API: a very small HTTP server bound to 127.0.0.1.
///
///     GET /v1/state    the current StateSnapshot as JSON
///     GET /v1/events   server-sent events: `state` after every scan, plus `job.started`, `shot.done`, …
///
/// Safety properties, on purpose:
/// - It listens on the loopback interface only, so nothing off this Mac can connect.
/// - It only answers GET and never changes anything.
/// - It checks the Host header, so a web page cannot reach it through DNS rebinding, and it sends
///   no CORS headers, so a web page cannot read its responses.
package final class LocalAPIServer {
    package static let defaultPort: UInt16 = 47600
    private static let maxStreams = 16

    package struct Request: Equatable {
        package var method: String
        package var path: String
        package var host: String

        package init(method: String, path: String, host: String) {
            self.method = method
            self.path = path
            self.host = host
        }
    }

    private let queue = DispatchQueue(label: "renderdock.api")
    private var listener: NWListener?
    private var streams: [ObjectIdentifier: NWConnection] = [:]
    private var state = Data("{}".utf8)
    private var boundPort: UInt16?
    private var wantRunning = false
    private var lastStateSent = Date.distantPast
    private var discoveryURL: URL?
    /// Called on the main queue whenever the bound port changes (nil when stopped).
    package var onPortChange: ((UInt16?) -> Void)?

    package init() {}

    package var port: UInt16? { queue.sync { boundPort } }
    package var streamCount: Int { queue.sync { streams.count } }

    /// Where a running instance says how to reach it: `{"url": "http://127.0.0.1:47600", "port": 47600, "pid": 123}`.
    package static var discoveryFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RenderDock/api.json")
    }

    /// Starts listening. If the port is taken, the next ones are tried (up to ten).
    /// `discovery` is where the port is announced; pass nil to announce nothing.
    package func start(preferredPort: UInt16 = defaultPort, discovery: URL? = LocalAPIServer.discoveryFile) {
        queue.async {
            guard !self.wantRunning else { return }
            self.wantRunning = true
            self.discoveryURL = discovery
            self.listen(on: preferredPort, attemptsLeft: 10)
        }
    }

    /// Stops and waits until the port and the discovery file are released.
    package func stop() {
        queue.sync {
            wantRunning = false
            listener?.cancel()
            listener = nil
            streams.values.forEach { $0.cancel() }
            streams.removeAll()
            if boundPort != nil, let url = discoveryURL { try? FileManager.default.removeItem(at: url) }
            boundPort = nil
        }
        notifyPort(nil)
    }

    /// New state after a scan. Events are sent to stream clients first, then the state itself.
    package func publish(state newState: Data, events: [RenderEvent] = []) {
        queue.async {
            self.state = newState
            guard !self.streams.isEmpty else { return }
            var chunk = Data()
            for e in events { chunk.append(Self.sse(event: e.type.rawValue, data: e.json())) }
            // Events always go out; the full state at most once a second (a small display needs no more).
            let now = Date()
            if now.timeIntervalSince(self.lastStateSent) >= 0.95 {
                chunk.append(Self.sse(event: "state", data: newState))
                self.lastStateSent = now
            }
            guard !chunk.isEmpty else { return }
            for c in self.streams.values { c.send(content: chunk, completion: .contentProcessed { _ in }) }
        }
    }

    // MARK: Listening

    private func listen(on port: UInt16, attemptsLeft: Int) {
        guard wantRunning, let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.acceptLocalOnly = true
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        guard let l = try? NWListener(using: params) else {
            if attemptsLeft > 0 { listen(on: port &+ 1, attemptsLeft: attemptsLeft - 1) }
            return
        }
        l.stateUpdateHandler = { [weak self, weak l] st in
            guard let self, let l, self.listener === l else { return }
            switch st {
            case .ready:
                self.boundPort = port
                self.writeDiscovery(port)
                self.notifyPort(port)
            case .failed:
                l.cancel()
                self.listener = nil
                if attemptsLeft > 0 { self.listen(on: port &+ 1, attemptsLeft: attemptsLeft - 1) }
            default:
                break
            }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener = l
        l.start(queue: queue)
    }

    private func notifyPort(_ port: UInt16?) {
        let callback = onPortChange
        DispatchQueue.main.async { callback?(port) }
    }

    private func writeDiscovery(_ port: UInt16) {
        guard let url = discoveryURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info: [String: Any] = ["url": "http://127.0.0.1:\(port)", "port": Int(port), "pid": Int(ProcessInfo.processInfo.processIdentifier)]
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]) { try? data.write(to: url, options: .atomic) }
    }

    // MARK: Connections

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        read(c, buffer: Data())
        // A client that connects and never sends a request does not get to hold a connection open.
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.streams[ObjectIdentifier(c)] == nil else { return }
            c.cancel()
        }
    }

    private func read(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let request = Self.parseRequest(buf) {
                self.respond(c, request)
            } else if error != nil || complete || buf.count > 16_384 {
                c.cancel()
            } else {
                self.read(c, buffer: buf)
            }
        }
    }

    private func respond(_ c: NWConnection, _ r: Request) {
        guard let port = boundPort, Self.hostAllowed(r.host, port: port) else {
            return send(c, status: "403 Forbidden", body: Self.message("forbidden: unexpected Host header"))
        }
        guard r.method == "GET" else {
            return send(c, status: "405 Method Not Allowed", body: Self.message("this API is read-only: GET only"), extra: "Allow: GET\r\n")
        }
        switch r.path {
        case "/v1/state":
            send(c, status: "200 OK", body: state)
        case "/v1/events":
            openStream(c)
        case "/", "/v1":
            let index: [String: Any] = [
                "name": "RenderDock", "version": StateSnapshot.appVersion,
                "endpoints": ["/v1/state", "/v1/events"],
                "docs": "https://github.com/JarnoNiu/RenderDock/blob/main/docs/API.md",
            ]
            send(c, status: "200 OK", body: (try? JSONSerialization.data(withJSONObject: index, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8))
        default:
            send(c, status: "404 Not Found", body: Self.message("not found"))
        }
    }

    private func send(_ c: NWConnection, status: String, body: Data, extra: String = "") {
        var out = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\(extra)Connection: close\r\n\r\n".utf8)
        out.append(body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }

    private func openStream(_ c: NWConnection) {
        guard streams.count < Self.maxStreams else {
            return send(c, status: "503 Service Unavailable", body: Self.message("too many event streams"))
        }
        let id = ObjectIdentifier(c)
        streams[id] = c
        var out = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: keep-alive\r\n\r\nretry: 3000\n\n".utf8)
        out.append(Self.sse(event: "state", data: state))
        c.send(content: out, completion: .contentProcessed { _ in })
        watchForClose(c, id)
    }

    /// A stream client sends nothing more; a read that completes or fails means it went away.
    private func watchForClose(_ c: NWConnection, _ id: ObjectIdentifier) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, complete, error in
            guard let self else { return }
            if complete || error != nil {
                self.streams[id] = nil
                c.cancel()
            } else {
                self.watchForClose(c, id)
            }
        }
    }

    // MARK: Pure helpers (covered by rd-checks)

    /// Parses the request line and the Host header once the header block is complete; nil until then.
    package static func parseRequest(_ data: Data) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count >= 2 else { return Request(method: "", path: "", host: "") }
        var host = ""
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].lowercased() == "host" {
                host = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let path = String(parts[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        return Request(method: String(parts[0]), path: path, host: host)
    }

    /// Only requests addressed to this machine's loopback name and our port are answered.
    package static func hostAllowed(_ host: String, port: UInt16) -> Bool {
        ["127.0.0.1:\(port)", "localhost:\(port)"].contains(host.lowercased())
    }

    /// One server-sent event. `data` must be single-line (the snapshot and event encoders guarantee that).
    package static func sse(event: String, data: Data) -> Data {
        var out = Data("event: \(event)\ndata: ".utf8)
        out.append(data)
        out.append(Data("\n\n".utf8))
        return out
    }

    private static func message(_ text: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["error": text])) ?? Data("{}".utf8)
    }
}
