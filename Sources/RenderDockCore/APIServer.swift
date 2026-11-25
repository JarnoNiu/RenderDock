import Foundation
import Network

/// The local, read-only API: a very small HTTP server bound to 127.0.0.1.
///
///     GET /v1/state    the current StateSnapshot as JSON
///     GET /v1/events   server-sent events: `state` after every scan, plus `job.started`, `shot.done`, …
///     GET /v1/history  the shots that ended most recently
///     GET /v1/device   from 0.4: a stream of the lines a desk display is sent over Bluetooth, for one that
///                      reads them over Wi-Fi instead (docs/DEVICES.md). Like everything here it only gives:
///                      nothing a display sends back is taken, so nothing can be answered this way.
///
/// Safety properties, on purpose:
/// - It listens on the loopback interface only, so nothing off this Mac can connect.
/// - It only answers GET and never changes anything.
/// - It checks the Host header, so a web page cannot reach it through DNS rebinding, and it sends
///   no CORS headers, so a web page cannot read its responses.
///
/// From 0.4 it can also be reached from the local network, behind a second switch that is off by default:
/// - Only then does it listen on the Mac's other addresses (IPv4), on the same port.
/// - Whatever does not come from this Mac itself must show the token, in an `Authorization: Bearer` header;
///   without it, or with a wrong one, the answer is 401 and nothing else. A connection from this Mac to one
///   of its own network addresses counts as coming from the network.
/// - What comes from 127.0.0.1 is answered exactly as before, token or no token.
/// - It is plain HTTP: the token and the state cross the network unencrypted. That is for a network you
///   trust (your own, at home or in the studio), and the documentation says so.
package final class LocalAPIServer {
    package static let defaultPort: UInt16 = 47600
    private static let maxStreams = 16
    /// Connections open at once, of every kind. Past this a new one is dropped at once: a device without the
    /// token could otherwise open them faster than they time out, until the app has no file handles left.
    private static let maxConnections = 64
    /// What a stream's reader may have waiting, unread. One that stops reading is dropped rather than fed for ever.
    private static let maxUnsent = 30

    package struct Request: Equatable {
        package var method: String
        package var path: String
        package var host: String
        /// What came after "Authorization: Bearer", if anything did.
        package var token: String?

        package init(method: String, path: String, host: String, token: String? = nil) {
            self.method = method
            self.path = path
            self.host = host
            self.token = token
        }
    }

    /// What a request is given, by where it came from and what it showed.
    package enum Access: Equatable {
        case allowed
        /// From this Mac, but addressed to a name that is not this Mac's loopback: a web page trying its luck.
        case forbiddenHost
        /// From the network without the token, or with a wrong one.
        case unauthorized
        /// From the network while access from the network is off. (The listener does not hear such a request
        /// in the first place; this is for the moment a switch is being changed.)
        case closed
    }

    private let queue = DispatchQueue(label: "renderdock.api")
    private var listener: NWListener?
    private var streams: [ObjectIdentifier: NWConnection] = [:]
    /// Displays reading over Wi-Fi, and the last lines they were sent (to greet a new one with, and to repeat).
    private var deviceStreams: [ObjectIdentifier: NWConnection] = [:]
    private var deviceSnapshot: Data?
    private var deviceMac: Data?
    private var deviceBeat: DispatchSourceTimer?
    private var state = Data("{}".utf8)
    private var history = Data("{\"runs\":[]}".utf8)
    private var boundPort: UInt16?
    private var wantRunning = false
    private var lastStateSent = Date.distantPast
    private var discoveryURL: URL?
    /// Access from the local network: off unless switched on, and then only with this token.
    private var lan = false
    private var token: String?
    /// What the listener that exists now was made for, and whether it is up. Which addresses are listened on is
    /// fixed when a listener is made, so "the network may reach it" is true of a listener, not of a wish.
    private var listenerLAN = false
    private var listenerReady = false
    private var listenPort = LocalAPIServer.defaultPort
    /// Every connection that is open, the streams that were let in from the network (by the token), and how
    /// much each stream has been sent that its reader has not taken yet.
    private var live = Set<ObjectIdentifier>()
    private var fromNetwork = Set<ObjectIdentifier>()
    private var unsent: [ObjectIdentifier: Int] = [:]
    /// Called on the main queue whenever the bound port changes (nil when stopped).
    package var onPortChange: ((UInt16?) -> Void)?

    package init() {}

    package var port: UInt16? { queue.sync { boundPort } }
    package var streamCount: Int { queue.sync { streams.count } }
    /// How many displays are reading `/v1/device` now. What they are sent need not be worked out while it is none.
    package var deviceCount: Int { queue.sync { deviceStreams.count } }

    /// Where a running instance says how to reach it: `{"url": "http://127.0.0.1:47600", "port": 47600, "pid": 123}`.
    package static var discoveryFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RenderDock/api.json")
    }

    /// Starts listening. If the port is taken, the next ones are tried (up to ten).
    /// `discovery` is where the port is announced; pass nil to announce nothing.
    /// With `lan` and a token, the Mac's other addresses are listened on too (see the top of this file).
    package func start(preferredPort: UInt16 = defaultPort, discovery: URL? = LocalAPIServer.discoveryFile, lan: Bool = false, token: String? = nil) {
        queue.async {
            guard !self.wantRunning else { return }
            self.wantRunning = true
            self.discoveryURL = discovery
            self.lan = lan && !(token ?? "").isEmpty
            self.token = token
            self.listen(on: preferredPort, attemptsLeft: 10)
        }
    }

    /// Switches access from the local network on or off while running, or changes the token. The port stays.
    /// Without a token it stays off, whatever is asked.
    package func setLAN(_ on: Bool, token: String?) {
        queue.async {
            let want = on && !(token ?? "").isEmpty
            let newToken = token != self.token
            self.lan = want
            self.token = token
            guard self.wantRunning else { return }
            if want != self.listenerLAN {
                // Which addresses are listened on is fixed when a listener is made: make another, on the same
                // port. This goes by what the listener was made for, not by what was last asked: asked twice in
                // a row while the first listener was still coming up, the second asking used to be lost, and
                // everything said the network could reach an API that listened on the loopback alone.
                let port = self.boundPort ?? self.listenPort
                self.listener?.cancel()
                self.listener = nil
                self.listenerReady = false
                self.dropStreams { _ in true }
                self.listen(on: port, attemptsLeft: 10)
            } else if newToken {
                // A new token shuts the old one out, and that has to include whoever is reading a stream that
                // the old one opened. (It used not to: a stream stayed open for as long as its reader held it.)
                self.dropStreams { self.fromNetwork.contains($0) }
            }
        }
    }

    /// Closes the streams that match, of both kinds.
    private func dropStreams(_ which: (ObjectIdentifier) -> Bool) {
        for (id, c) in streams where which(id) { c.cancel(); streams[id] = nil }
        for (id, c) in deviceStreams where which(id) { c.cancel(); deviceStreams[id] = nil }
        fromNetwork = fromNetwork.filter { streams[$0] != nil || deviceStreams[$0] != nil }
        unsent = unsent.filter { streams[$0.key] != nil || deviceStreams[$0.key] != nil }
    }

    /// Sends a stream's reader something more, unless it has stopped taking what it was sent: then it is dropped.
    private func push(_ c: NWConnection, _ data: Data) {
        let id = ObjectIdentifier(c)
        let waiting = (unsent[id] ?? 0) + 1
        guard waiting <= Self.maxUnsent else { return dropStreams { $0 == id } }
        unsent[id] = waiting
        c.send(content: data, completion: .contentProcessed { [weak self] _ in
            guard let self, let n = self.unsent[id] else { return }
            self.unsent[id] = max(0, n - 1)
        })
    }

    package var lanOpen: Bool { queue.sync { listenerLAN && listenerReady } }
    /// How many connections are open now, of every kind.
    package var connectionCount: Int { queue.sync { live.count } }

    /// Stops and waits until the port and the discovery file are released.
    package func stop() {
        queue.sync {
            wantRunning = false
            listener?.cancel()
            listener = nil
            streams.values.forEach { $0.cancel() }
            streams.removeAll()
            deviceStreams.values.forEach { $0.cancel() }
            deviceStreams.removeAll()
            deviceBeat?.cancel()
            deviceBeat = nil
            fromNetwork.removeAll()
            unsent.removeAll()
            listenerReady = false
            listenerLAN = false
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
            for c in Array(self.streams.values) { self.push(c, chunk) }
        }
    }

    /// What a display reading over Wi-Fi is sent: a snapshot line (`BuddyProtocol.Heartbeat.line()`) and the line
    /// about this Mac (`BuddyProtocol.mac`). Either may be nil to leave it as it was. A line that has not
    /// changed is not sent again here; the repeat every ten seconds is what tells a display the link is alive.
    package func publish(deviceSnapshot snapshot: Data? = nil, deviceMac mac: Data? = nil) {
        queue.async {
            var chunk = Data()
            if let snapshot, snapshot != self.deviceSnapshot {
                self.deviceSnapshot = snapshot
                chunk.append(Self.deviceEvent(snapshot))
            }
            if let mac, mac != self.deviceMac {
                self.deviceMac = mac
                chunk.append(Self.deviceEvent(mac))
            }
            guard !chunk.isEmpty, !self.deviceStreams.isEmpty else { return }
            for c in Array(self.deviceStreams.values) { self.push(c, chunk) }
        }
    }

    /// The most recently ended shots, for `GET /v1/history`.
    package func publish(history runs: [HistoryRun]) {
        struct Payload: Encodable { let runs: [HistoryRun] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(Payload(runs: runs)) else { return }
        queue.async { self.history = data }
    }

    // MARK: Listening

    private func listen(on port: UInt16, attemptsLeft: Int) {
        guard wantRunning, let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Off the loopback only when asked to, and then IPv4 only: one kind of address to reason about.
        params.acceptLocalOnly = !lan
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(lan ? .any : .loopback), port: nwPort)
        listenerLAN = lan
        listenerReady = false
        listenPort = port
        guard let l = try? NWListener(using: params) else {
            if attemptsLeft > 0 { listen(on: port &+ 1, attemptsLeft: attemptsLeft - 1) }
            return
        }
        l.stateUpdateHandler = { [weak self, weak l] st in
            guard let self, let l, self.listener === l else { return }
            switch st {
            case .ready:
                self.listenerReady = true
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
        // Never the token: this file says where, not how to get in from elsewhere.
        let info: [String: Any] = ["url": "http://127.0.0.1:\(port)", "port": Int(port), "pid": Int(ProcessInfo.processInfo.processIdentifier), "lan": lan]
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]) { try? data.write(to: url, options: .atomic) }
    }

    // MARK: Connections

    private func accept(_ c: NWConnection) {
        let id = ObjectIdentifier(c)
        guard live.count < Self.maxConnections else { return c.cancel() }
        live.insert(id)
        c.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled:
                self?.live.remove(id)
            case .failed:
                self?.live.remove(id)
                c.cancel()
            default:
                break
            }
        }
        c.start(queue: queue)
        read(c, buffer: Data())
        // A client that connects and never sends a request does not get to hold a connection open. A stream that
        // was opened is past this, either kind. (The display's kind was once left out here, and every display
        // reading over Wi-Fi was cut off after ten seconds and came back three seconds later.)
        queue.asyncAfter(deadline: .now() + deadline) { [weak self] in
            let id = ObjectIdentifier(c)
            guard let self, self.streams[id] == nil, self.deviceStreams[id] == nil else { return }
            c.cancel()
        }
    }

    /// How long a connection may go without having opened a stream before it is dropped: ten seconds. (Settable
    /// so that the checks need not wait that long.)
    package var requestDeadline: TimeInterval {
        get { queue.sync { deadline } }
        set { queue.sync { deadline = newValue } }
    }
    private var deadline: TimeInterval = 10

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
        guard let port = boundPort else { return c.cancel() }
        let fromHere = Self.isLoopback(c.currentPath?.remoteEndpoint ?? c.endpoint)
        switch Self.access(fromThisMac: fromHere, host: r.host, port: port, lan: lan, token: token, presented: r.token) {
        case .allowed:
            break
        case .forbiddenHost:
            return send(c, status: "403 Forbidden", body: Self.message("forbidden: unexpected Host header"))
        case .unauthorized:
            return send(c, status: "401 Unauthorized", body: Self.message("unauthorized: this needs the token, as \"Authorization: Bearer <token>\""),
                        extra: "WWW-Authenticate: Bearer\r\n")
        case .closed:
            return c.cancel()
        }
        guard r.method == "GET" else {
            return send(c, status: "405 Method Not Allowed", body: Self.message("this API is read-only: GET only"), extra: "Allow: GET\r\n")
        }
        switch r.path {
        case "/v1/state":
            send(c, status: "200 OK", body: state)
        case "/v1/history":
            send(c, status: "200 OK", body: history)
        case "/v1/events":
            openStream(c, fromHere: fromHere)
        case "/v1/device":
            openDeviceStream(c, fromHere: fromHere)
        case "/", "/v1":
            let index: [String: Any] = [
                "name": "RenderDock", "version": StateSnapshot.appVersion,
                "endpoints": ["/v1/state", "/v1/events", "/v1/history", "/v1/device"],
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

    private func openStream(_ c: NWConnection, fromHere: Bool) {
        guard streams.count + deviceStreams.count < Self.maxStreams else {
            return send(c, status: "503 Service Unavailable", body: Self.message("too many event streams"))
        }
        let id = ObjectIdentifier(c)
        streams[id] = c
        if !fromHere { fromNetwork.insert(id) }
        var out = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: keep-alive\r\n\r\nretry: 3000\n\n".utf8)
        out.append(Self.sse(event: "state", data: state))
        push(c, out)
        watchForClose(c, id)
    }

    /// A display that reads over Wi-Fi: greeted with the time and the latest lines, then sent each new one.
    private func openDeviceStream(_ c: NWConnection, fromHere: Bool) {
        guard streams.count + deviceStreams.count < Self.maxStreams else {
            return send(c, status: "503 Service Unavailable", body: Self.message("too many streams"))
        }
        let id = ObjectIdentifier(c)
        // Nobody was reading, so what is kept may be from long ago: the first display in is not greeted with it.
        // The app sends what is true now within a second or two.
        if deviceStreams.isEmpty {
            deviceSnapshot = nil
            deviceMac = nil
        }
        deviceStreams[id] = c
        if !fromHere { fromNetwork.insert(id) }
        var out = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: keep-alive\r\n\r\n".utf8)
        out.append(Self.deviceEvent(BuddyProtocol.timeSync()))
        if let deviceSnapshot { out.append(Self.deviceEvent(deviceSnapshot)) }
        if let deviceMac { out.append(Self.deviceEvent(deviceMac)) }
        push(c, out)
        watchForClose(c, id)
        if deviceBeat == nil {
            // A display takes half a minute of silence for a dead link: say it all again every ten seconds, and
            // the time with it (a display's own clock drifts, and it has no other way to hear of a new hour).
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + BuddyProtocol.keepalive, repeating: BuddyProtocol.keepalive)
            timer.setEventHandler { [weak self] in
                guard let self, !self.deviceStreams.isEmpty else { return }
                var again = Self.deviceEvent(BuddyProtocol.timeSync())
                if let line = self.deviceSnapshot { again.append(Self.deviceEvent(line)) }
                if let line = self.deviceMac { again.append(Self.deviceEvent(line)) }
                for c in Array(self.deviceStreams.values) { self.push(c, again) }
            }
            timer.resume()
            deviceBeat = timer
        }
    }

    /// A stream client sends nothing more; a read that completes or fails means it went away.
    private func watchForClose(_ c: NWConnection, _ id: ObjectIdentifier) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, complete, error in
            guard let self else { return }
            if complete || error != nil {
                self.streams[id] = nil
                self.deviceStreams[id] = nil
                self.fromNetwork.remove(id)
                self.unsent[id] = nil
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
        var token: String?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "host" {
                host = value
            } else if name == "authorization" {
                // "Bearer" in any case, one space, then the token; anything else is not a token.
                let words = value.split(separator: " ", omittingEmptySubsequences: true)
                if words.count == 2, words[0].lowercased() == "bearer" { token = String(words[1]) }
            }
        }
        // A token in the address (?token=…) is not read, on purpose: addresses end up in logs and histories.
        let path = String(parts[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        return Request(method: String(parts[0]), path: path, host: host, token: token)
    }

    /// Who is let in. From this Mac: as always, by the Host header. From anywhere else: only while access from
    /// the network is on, and only with the token.
    package static func access(fromThisMac: Bool, host: String, port: UInt16, lan: Bool, token: String?, presented: String?) -> Access {
        if fromThisMac { return hostAllowed(host, port: port) ? .allowed : .forbiddenHost }
        guard lan, let token, !token.isEmpty else { return .closed }
        guard let presented, same(presented, token) else { return .unauthorized }
        return .allowed
    }

    /// Compares two tokens without stopping at the first difference, so that how long it takes says nothing
    /// about how much of a guess was right.
    package static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var difference = UInt8(x.count == y.count ? 0 : 1)
        for i in 0..<max(x.count, y.count) {
            difference |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0)
        }
        return difference == 0
    }

    /// Whether the other end of a connection is this Mac's own loopback. Anything that cannot be told is not.
    package static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        // All of 127.0.0.0/8 is the loopback (the system's own `isLoopback` says so of 127.0.0.1 alone), and
        // nothing with such an address arrives from outside.
        switch host {
        case .ipv4(let address): return address.rawValue.first == 127
        case .ipv6(let address): return address.isLoopback || address.asIPv4?.rawValue.first == 127
        default: return false
        }
    }

    /// A new token: 24 random bytes from the system, as 32 characters that are safe in a header and easy to
    /// paste (letters, digits, "-" and "_").
    package static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            // The system's generator not answering is not something to paper over with a weaker one.
            return ""
        }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The token kept in a file only its owner can read; made on first use. Empty if it can be neither read nor made.
    package static func token(at url: URL, renew: Bool = false) -> String {
        if !renew, let text = try? String(contentsOf: url, encoding: .utf8) {
            let kept = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if kept.count >= 24 { return kept }
        }
        let fresh = newToken()
        guard !fresh.isEmpty else { return "" }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: Data((fresh + "\n").utf8), attributes: [.posixPermissions: 0o600]) else { return "" }
        return fresh
    }

    /// Where the token is kept, unless `RENDERDOCK_API_TOKEN` names another file (for tests).
    package static var tokenFile: URL {
        if let path = ProcessInfo.processInfo.environment["RENDERDOCK_API_TOKEN"], !path.isEmpty { return URL(fileURLWithPath: path) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RenderDock/api-token")
    }

    /// This Mac's IPv4 addresses on its networks (not the loopback, not link-local), as text.
    package static func networkAddresses() -> [String] {
        var out: [String] = []
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let start = first else { return [] }
        defer { freeifaddrs(first) }
        var next: UnsafeMutablePointer<ifaddrs>? = start
        while let entry = next {
            defer { next = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            if !text.hasPrefix("169.254."), !out.contains(text) { out.append(text) }
        }
        return out
    }

    /// Only requests addressed to this machine's loopback name and our port are answered.
    package static func hostAllowed(_ host: String, port: UInt16) -> Bool {
        ["127.0.0.1:\(port)", "localhost:\(port)"].contains(host.lowercased())
    }

    /// One of a display's lines as an event of the stream: the line itself after "data: ", without its line break.
    package static func deviceEvent(_ line: Data) -> Data {
        var out = Data("data: ".utf8)
        out.append(line.last == 0x0A ? line.dropLast() : line)
        out.append(Data("\n\n".utf8))
        return out
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
