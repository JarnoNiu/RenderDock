import Foundation
import Network

// Publishing what RenderDock sees to an MQTT broker, so that a home-automation system (Home Assistant, or
// anything else that speaks MQTT) can show it or act on it: a light that turns green when the queue is done.
//
// Nothing is published unless a settings file names a broker and says `"enabled": true`. What goes out is a
// summary: the overall state, counts, the percentage and name of the shot in front. Never a path, never an
// agent's project or session title. See docs/MQTT.md.

// MARK: Settings

package struct MQTTSettings: Codable, Equatable {
    package var enabled: Bool
    package var host: String
    /// 1883, or 8883 with `tls`, unless given.
    package var port: Int?
    package var tls: Bool?
    package var username: String?
    package var password: String?
    /// The first part of every topic. "renderdock" unless given; give each Mac its own when there are several.
    package var topic: String?
    /// False to leave the shot's and the job's names out (the counts and the percentage still go).
    package var names: Bool?
    /// False to not announce the sensors to Home Assistant.
    package var homeAssistant: Bool?
    /// "homeassistant" unless given.
    package var discoveryPrefix: String?

    package init(enabled: Bool = true, host: String, port: Int? = nil, tls: Bool? = nil, username: String? = nil, password: String? = nil,
                 topic: String? = nil, names: Bool? = nil, homeAssistant: Bool? = nil, discoveryPrefix: String? = nil) {
        self.enabled = enabled
        self.host = host
        self.port = port
        self.tls = tls
        self.username = username
        self.password = password
        self.topic = topic
        self.names = names
        self.homeAssistant = homeAssistant
        self.discoveryPrefix = discoveryPrefix
    }

    package var resolvedPort: Int { port ?? (tls == true ? 8883 : 1883) }
    package var base: String { MQTTTopics.clean(topic ?? "renderdock") }

    /// `~/Library/Application Support/RenderDock/mqtt.json`, or the RENDERDOCK_MQTT environment variable (used when testing).
    package static var file: URL {
        if let custom = ProcessInfo.processInfo.environment["RENDERDOCK_MQTT"], !custom.isEmpty { return URL(fileURLWithPath: custom) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RenderDock/mqtt.json")
    }

    /// The settings in the file, if there are any and they name a broker. A missing or broken file means none.
    package static func load(from url: URL = file) -> MQTTSettings? {
        guard let data = try? Data(contentsOf: url), let settings = try? JSONDecoder().decode(MQTTSettings.self, from: data),
              !settings.host.isEmpty else { return nil }
        return settings
    }

    /// What the file starts out as when the menu creates it: complete, and switched off.
    package static let template = """
    {
      "enabled": false,
      "host": "192.168.1.10",
      "port": 1883,
      "tls": false,
      "username": "",
      "password": "",
      "topic": "renderdock",
      "names": true,
      "homeAssistant": true
    }

    """
}

// MARK: What is published

package enum MQTTTopics {
    package struct Message: Equatable {
        package var topic: String
        package var payload: String
        package var retain: Bool
    }

    /// A topic part with nothing in it that MQTT gives a meaning to.
    package static func clean(_ text: String) -> String {
        let kept = text.unicodeScalars.filter { $0 != "#" && $0 != "+" && $0.value >= 0x20 && $0 != " " }
        let out = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return out.isEmpty ? "renderdock" : out
    }

    package static func availability(_ settings: MQTTSettings) -> String { settings.base + "/availability" }
    package static func state(_ settings: MQTTSettings) -> String { settings.base + "/state" }

    /// The one document that carries everything, as a retained message on `<topic>/state`.
    package static func statePayload(_ snapshot: StateSnapshot, settings: MQTTSettings) -> String {
        let s = snapshot.summary
        let focus = s.focus
        let named = settings.names != false
        // The job the shot in front belongs to.
        let job = focus.flatMap { f in snapshot.jobs.first { $0.shots.contains { $0.name == f.name } } }
        let object: [String: Any] = [
            "state": s.state,
            "rendering": s.rendering,
            "paused": s.paused,
            "stalled": s.stalled,
            "queued": s.queued,
            // Always a number, so that a gauge has something to show: 0 while nothing renders.
            "progress": focus?.fraction.map { Int(($0 * 100).rounded(.down)) } ?? 0,
            "exact": focus?.exact ?? false,
            "eta": focus?.etaSec ?? 0,
            "shot": named ? (focus?.name ?? "") : "",
            "job": named ? (job?.title ?? "") : "",
            "agents_waiting": s.agents.waiting,
            "agents_working": s.agents.working,
            "agents_error": s.agents.error,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// The announcements Home Assistant reads to create the sensors by itself (its "MQTT discovery").
    package static func discovery(_ settings: MQTTSettings, version: String) -> [Message] {
        let node = "renderdock_" + settings.base.map { $0.isLetter || $0.isNumber ? String($0).lowercased() : "_" }.joined()
        let prefix = clean(settings.discoveryPrefix ?? "homeassistant")
        let device: [String: Any] = ["identifiers": [node], "name": "RenderDock", "manufacturer": "RenderDock", "model": "macOS app", "sw_version": version]
        func entity(_ kind: String, _ id: String, _ name: String, _ template: String, _ more: [String: Any] = [:]) -> Message {
            var config: [String: Any] = [
                "name": name, "unique_id": "\(node)_\(id)", "object_id": "\(node)_\(id)",
                "state_topic": state(settings), "value_template": template,
                "availability_topic": availability(settings), "device": device,
            ]
            more.forEach { config[$0.key] = $0.value }
            let data = (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
            return Message(topic: "\(prefix)/\(kind)/\(node)/\(id)/config", payload: String(decoding: data, as: UTF8.self), retain: true)
        }
        var out = [
            entity("sensor", "state", "State", "{{ value_json.state }}", ["icon": "mdi:state-machine"]),
            entity("sensor", "progress", "Progress", "{{ value_json.progress }}", ["unit_of_measurement": "%", "icon": "mdi:progress-clock", "state_class": "measurement"]),
            entity("sensor", "eta", "Time left", "{{ value_json.eta }}", ["unit_of_measurement": "s", "device_class": "duration"]),
            entity("sensor", "rendering", "Rendering", "{{ value_json.rendering }}", ["icon": "mdi:movie-open-play", "state_class": "measurement"]),
            entity("sensor", "queued", "Queued", "{{ value_json.queued }}", ["icon": "mdi:tray-full", "state_class": "measurement"]),
            entity("sensor", "agents_waiting", "Agents waiting", "{{ value_json.agents_waiting }}", ["icon": "mdi:hand-back-right", "state_class": "measurement"]),
            entity("sensor", "agents_working", "Agents working", "{{ value_json.agents_working }}", ["icon": "mdi:robot", "state_class": "measurement"]),
            entity("binary_sensor", "active", "Rendering now", "{{ 'ON' if value_json.rendering > 0 else 'OFF' }}", ["device_class": "running"]),
            entity("binary_sensor", "attention", "Needs attention",
                   "{{ 'ON' if (value_json.stalled > 0 or value_json.agents_waiting > 0 or value_json.agents_error > 0) else 'OFF' }}", ["device_class": "problem"]),
        ]
        if settings.names != false {
            out.append(entity("sensor", "shot", "Shot", "{{ value_json.shot }}", ["icon": "mdi:filmstrip"]))
            out.append(entity("sensor", "job", "Job", "{{ value_json.job }}", ["icon": "mdi:briefcase-outline"]))
        }
        return out
    }
}

// MARK: The wire

/// MQTT 3.1.1 packets, as many kinds as a publisher needs. Pure, so the checks can look at the bytes.
package enum MQTTPacket {
    private static func text(_ s: String) -> [UInt8] {
        let bytes = Array(s.utf8.prefix(65_535))
        return [UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)] + bytes
    }

    /// The "remaining length" every packet carries: seven bits at a time, lowest first.
    package static func length(_ n: Int) -> [UInt8] {
        var out: [UInt8] = []
        var rest = max(0, n)
        repeat {
            var byte = UInt8(rest % 128)
            rest /= 128
            if rest > 0 { byte |= 0x80 }
            out.append(byte)
        } while rest > 0
        return out
    }

    /// CONNECT, with a "last will": what the broker says on our behalf if the connection drops without a goodbye.
    package static func connect(clientID: String, username: String?, password: String?, keepAlive: Int, willTopic: String, willMessage: String) -> Data {
        var flags: UInt8 = 0x02 | 0x04 | 0x20   // clean session, will, will retain (will QoS 0)
        var payload = text(clientID) + text(willTopic) + text(willMessage)
        if let username, !username.isEmpty {
            flags |= 0x80
            payload += text(username)
            if let password, !password.isEmpty {
                flags |= 0x40
                payload += text(password)
            }
        }
        let header = text("MQTT") + [0x04, flags, UInt8((keepAlive >> 8) & 0xFF), UInt8(keepAlive & 0xFF)]
        return Data([0x10] + length(header.count + payload.count) + header + payload)
    }

    /// PUBLISH at quality-of-service 0: sent once, not acknowledged.
    package static func publish(topic: String, payload: String, retain: Bool) -> Data {
        let body = text(topic) + Array(payload.utf8)
        return Data([retain ? 0x31 : 0x30] + length(body.count) + body)
    }

    package static let ping = Data([0xC0, 0x00])
    package static let disconnect = Data([0xE0, 0x00])

    /// The next whole packet in what the broker has sent so far, taken off the front. Nil until one is complete.
    package static func next(in buffer: inout Data) -> (type: UInt8, body: Data)? {
        guard buffer.count >= 2 else { return nil }
        var length = 0, shift = 0, used = 1
        while true {
            guard used < buffer.count else { return nil }
            let byte = buffer[buffer.startIndex + used]
            length |= Int(byte & 0x7F) << shift
            used += 1
            if byte & 0x80 == 0 { break }
            shift += 7
            if shift > 21 { buffer.removeAll(); return nil }   // not MQTT
        }
        guard buffer.count >= used + length else { return nil }
        let type = buffer[buffer.startIndex] >> 4
        let body = buffer.subdata(in: (buffer.startIndex + used)..<(buffer.startIndex + used + length))
        buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + used + length))
        return (type, body)
    }
}

// MARK: The connection

/// Keeps one connection to the broker, says "online" on it, announces the sensors once, and publishes the
/// state whenever it changes. Comes back by itself after a broken connection, waiting longer each time.
package final class MQTTClient {
    package enum Status: Equatable {
        case connecting
        case connected
        /// Not connected, with the reason in plain words; trying again later.
        case failed(String)
        case stopped
    }

    private let settings: MQTTSettings
    private let version: String
    private let queue = DispatchQueue(label: "renderdock.mqtt")
    private var connection: NWConnection?
    private var inbox = Data()
    private var ready = false
    private var failures = 0
    private var stopped = true
    private var lastPayload: String?
    private var pending: String?
    private var ticker: DispatchSourceTimer?
    private var state = Status.stopped
    /// Called on the main queue when the status changes.
    package var onStatus: ((Status) -> Void)?

    package init(settings: MQTTSettings, version: String) {
        self.settings = settings
        self.version = version
    }

    package var status: Status { queue.sync { state } }

    package func start() {
        queue.async {
            guard self.stopped else { return }
            self.stopped = false
            self.failures = 0
            self.open()
        }
    }

    /// Says "offline", says goodbye, and closes. (If the app goes away before that is out, the broker says
    /// "offline" for it: that is what the last will given on connecting is for.)
    package func stop() {
        queue.async {
            guard !self.stopped else { return }
            self.stopped = true
            self.ticker?.cancel()
            self.ticker = nil
            let connection = self.connection
            self.connection = nil
            if self.ready, let connection {
                connection.send(content: MQTTPacket.publish(topic: MQTTTopics.availability(self.settings), payload: "offline", retain: true) + MQTTPacket.disconnect,
                                completion: .contentProcessed { _ in connection.cancel() })
                self.queue.asyncAfter(deadline: .now() + 1) { connection.cancel() }
            } else {
                connection?.cancel()
            }
            self.ready = false
            self.set(.stopped)
        }
    }

    /// Publishes the state, unless it is the same as what was published last.
    package func publish(state snapshot: StateSnapshot) {
        let payload = MQTTTopics.statePayload(snapshot, settings: settings)
        queue.async {
            guard !self.stopped, payload != self.lastPayload else { return }
            self.pending = payload
            self.flush()
        }
    }

    // MARK: on `queue`

    private func set(_ new: Status) {
        guard new != state else { return }
        state = new
        DispatchQueue.main.async { self.onStatus?(new) }
    }

    private func flush() {
        guard ready, let connection, let payload = pending else { return }
        pending = nil
        lastPayload = payload
        connection.send(content: MQTTPacket.publish(topic: MQTTTopics.state(settings), payload: payload, retain: true), completion: .contentProcessed { _ in })
    }

    private func open() {
        guard !stopped, let port = NWEndpoint.Port(rawValue: UInt16(clamping: settings.resolvedPort)) else { return }
        set(.connecting)
        inbox = Data()
        ready = false
        let connection = NWConnection(host: NWEndpoint.Host(settings.host), port: port, using: settings.tls == true ? .tls : .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] new in
            guard let self, self.connection === connection else { return }
            switch new {
            case .ready:
                let id = "renderdock-" + String(UUID().uuidString.prefix(8)).lowercased()
                connection.send(content: MQTTPacket.connect(clientID: id, username: self.settings.username, password: self.settings.password, keepAlive: 60,
                                                             willTopic: MQTTTopics.availability(self.settings), willMessage: "offline"),
                                completion: .contentProcessed { _ in })
                self.receive(on: connection)
            case .failed(let error):
                self.dropped(connection, why: error.localizedDescription)
            case .waiting(let error):
                // The broker cannot be reached right now. Network.framework would keep waiting; give up and try again later instead.
                self.dropped(connection, why: error.localizedDescription)
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)
        // A broker that accepts the connection and then says nothing is not a broker.
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.connection === connection, !self.ready, !self.stopped else { return }
            self.dropped(connection, why: "no answer from the broker")
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, finished, error in
            guard let self, self.connection === connection else { return }
            if let data { self.inbox.append(data) }
            while let packet = MQTTPacket.next(in: &self.inbox) {
                if packet.type == 2 {   // CONNACK
                    let code = packet.body.count >= 2 ? packet.body[packet.body.startIndex + 1] : 255
                    if code == 0 {
                        self.accepted(connection)
                    } else {
                        let reasons: [UInt8: String] = [1: "the broker does not speak this version of MQTT", 2: "the broker refused the client's name",
                                                        3: "the broker is unavailable", 4: "wrong user name or password", 5: "not authorised"]
                        self.dropped(connection, why: reasons[code] ?? "the broker refused the connection (\(code))")
                        return
                    }
                }
                // PINGRESP and anything else: nothing to do.
            }
            if finished || error != nil {
                self.dropped(connection, why: error?.localizedDescription ?? "the broker closed the connection")
                return
            }
            self.receive(on: connection)
        }
    }

    private func accepted(_ connection: NWConnection) {
        ready = true
        failures = 0
        set(.connected)
        var packets = MQTTPacket.publish(topic: MQTTTopics.availability(settings), payload: "online", retain: true)
        if settings.homeAssistant != false {
            for m in MQTTTopics.discovery(settings, version: version) { packets += MQTTPacket.publish(topic: m.topic, payload: m.payload, retain: m.retain) }
        }
        connection.send(content: packets, completion: .contentProcessed { _ in })
        // What was last published goes again: the broker may be a new one, or have lost what it kept.
        if pending == nil { pending = lastPayload }
        lastPayload = nil
        flush()
        ticker?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self, self.ready, self.connection === connection else { return }
            connection.send(content: MQTTPacket.ping, completion: .contentProcessed { _ in })
        }
        timer.resume()
        ticker = timer
    }

    private func dropped(_ connection: NWConnection, why: String) {
        guard self.connection === connection else { return }
        connection.cancel()
        self.connection = nil
        ready = false
        ticker?.cancel()
        ticker = nil
        guard !stopped else { return }
        failures += 1
        set(.failed(why))
        // 5, 10, 20 … 120 seconds.
        let wait = min(120.0, 5.0 * pow(2.0, Double(min(failures - 1, 5))))
        queue.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, !self.stopped, self.connection == nil else { return }
            self.open()
        }
    }
}
