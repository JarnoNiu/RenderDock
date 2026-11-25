import CoreBluetooth
import Foundation
import RenderDockCore

/// The computer's side of the Bluetooth link to a small device on the desk (see `BuddyProtocol` and docs/DEVICES.md).
/// Off unless switched on: no Bluetooth object exists, and macOS is not asked for permission, until `start()`.
///
/// Run against one device so far (the desk display in firmware/desk-display): finding it, pairing with a passkey,
/// the encrypted link, the snapshot, and going back to it after the device restarts. An answer coming back from
/// the device has not been tried over the air yet.
final class DeviceLink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    enum Status: Equatable {
        case off
        /// This copy is not a proper app bundle, so macOS would not let it use Bluetooth.
        case unavailable
        case bluetoothOff
        case notAllowed
        case looking
        case connecting(String)
        /// This Mac still holds a pairing with the device, and the device no longer has its half (its whole flash
        /// was written again, or its memory was cleared). Nothing connects until the user forgets the device in
        /// System Settings → Bluetooth; see `hint`.
        case pairingGone(String)
        case connected(name: String, secure: Bool, battery: Int?)

        var text: String {
            switch self {
            case .off: return L("没有打开", "Off")
            case .unavailable: return L("这一份不是正式的应用包，用不了蓝牙", "This copy is not an app bundle and cannot use Bluetooth")
            case .bluetoothOff: return L("蓝牙没开", "Bluetooth is off")
            case .notAllowed: return L("没有蓝牙权限：到 系统设置 → 隐私与安全性 → 蓝牙 里允许", "No Bluetooth permission: allow it in System Settings → Privacy & Security → Bluetooth")
            case .looking: return L("正在找设备…", "Looking for a device…")
            case .connecting(let name): return L("正在连接 \(name)…", "Connecting to \(name)…")
            case .pairingGone(let name): return L("\(name) 已经没有和这台电脑的配对了", "\(name) no longer has its pairing with this Mac")
            case .connected(let name, let secure, let battery):
                let power = battery.map { L(" · 电量 \($0)%", " · battery \($0)%") } ?? ""
                return secure ? L("已连接 \(name)\(power)", "Connected to \(name)\(power)")
                              : L("已连接 \(name)\(power) · 连接未加密，只发计数", "Connected to \(name)\(power) · not encrypted, counts only")
            }
        }

        /// What the user can do about it, where there is something to do. A second line under the status.
        var hint: String? {
            switch self {
            case .pairingGone:
                return L("到 系统设置 → 蓝牙 里忽略这台设备，等半分钟，会重新配对",
                         "Forget it in System Settings → Bluetooth and wait half a minute: it pairs again")
            default: return nil
            }
        }
    }

    /// All four are called on the main queue.
    var onStatus: (() -> Void)?
    /// The device answered "which networks do you see".
    var onNetworks: (([BuddyProtocol.SeenNetwork]) -> Void)?
    /// The device is ready for a snapshot, or what may be sent to it has changed.
    var onReady: (() -> Void)?
    /// The user answered, on the device, a request this link offered there.
    var onAnswer: ((String, ControlDecision) -> Void)?
    /// The user picked, on the device, an answer to a question this link offered there (its number, from 0).
    var onChoice: ((String, Int) -> Void)?

    private let queue = DispatchQueue(label: "renderdock.device")
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var assembler = BuddyProtocol.LineAssembler()
    /// The ids of the requests offered on this connection. An answer for anything else is ignored.
    private var offered = Set<String>()
    /// The same for questions from other programs, kept apart: a pick is never taken for an approval, nor the other way round.
    private var offeredAsks = Set<String>()
    private var lastLine: Data?
    private var keepalive: DispatchSourceTimer?
    private var ticks = 0
    private var state = Status.off
    private var deviceExtended = false
    private var deviceUnicode = false
    private var deviceInbox = false
    private var devicePages = false
    private var deviceWiFi: Int?
    private var deviceWiFiWas: Int?
    private var lastMac: Data?
    /// Connections in a row that ended before the link was encrypted. Each one waits longer before the next try,
    /// so a pairing the user dismissed does not come back every two seconds.
    private var failures = 0
    /// The name of the device that refused this Mac because it no longer has the pairing. While it is set the
    /// status says so (the tries in between do not take that line away) and the tries are far apart.
    private var gone: String?
    /// The name the connection under way was started with.
    private var attempting = ""
    /// What happened on the link lately: events and sizes only, never what a line said. Kept in a small file
    /// (`logURL`), because a link that will not come up can only be diagnosed from what each side saw.
    private var trace: [String] = []
    private var lastWriteError = ""

    /// How often the link is looked after, and how many of those make one repeat of the snapshot.
    private static let tick: TimeInterval = 2
    private static let heartbeatTicks = max(1, Int(BuddyProtocol.keepalive / tick))

    private static let service = CBUUID(string: BuddyProtocol.service)
    private static let rxUUID = CBUUID(string: BuddyProtocol.rx)
    private static let txUUID = CBUUID(string: BuddyProtocol.tx)
    private static let rememberedKey = "devicePeripheral"

    var status: Status { queue.sync { state } }

    /// The device reported an encrypted link. Until it does, only counts are sent.
    var secure: Bool {
        if case .connected(_, let secure, _) = status { return secure }
        return false
    }

    var isConnected: Bool {
        if case .connected = status { return true }
        return false
    }

    /// The device said it understands RenderDock's own fields, and that it can draw text beyond ASCII.
    var extended: Bool { queue.sync { deviceExtended } }
    var unicode: Bool { queue.sync { deviceUnicode } }
    /// …and that it understands questions, notices and tasks from other programs.
    var inbox: Bool { queue.sync { deviceInbox } }
    /// …and that it keeps renders and agents on pages of their own, with one for this Mac.
    var pages: Bool { queue.sync { devicePages } }
    /// How the device says its Wi-Fi is doing (see `BuddyProtocol.DeviceStatus.wifi`); nil if it has none.
    var wifi: Int? { queue.sync { deviceWiFi } }
    /// …and how its last use of Wi-Fi went (see `BuddyProtocol.DeviceStatus.wifiWas`); nil if it has not said.
    var wifiWas: Int? { queue.sync { deviceWiFiWas } }
    /// The device RenderDock goes back to, as macOS knows it on this Mac. Nil when none is remembered.
    var identifier: String? { UserDefaults.standard.string(forKey: Self.rememberedKey) }

    /// Sends the device a line that is not a snapshot: its Wi-Fi settings, or the word to forget them. Only on
    /// an encrypted link; false if there is none. Then asks how it is doing, so the menu can say.
    @discardableResult
    func sendSettings(_ line: Data) -> Bool {
        queue.sync {
            guard case .connected(_, true, _) = self.state, let p = self.peripheral, self.rx != nil, p.state == .connected else { return false }
            self.write(line)
            self.note("sent the device a line about its Wi-Fi (\(line.count) bytes)")
            self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.write(BuddyProtocol.statusRequest) }
            return true
        }
    }

    /// `~/Library/Application Support/RenderDock/device-link.log`: the last hundred or so events, rewritten whole.
    /// Nil for a copy that is not an app bundle: it cannot use Bluetooth, so it has nothing to report, and a
    /// copy started for testing must not write over the installed app's log. (One did, once: a test instance
    /// with the link "on" noted "switched off" on its way out.) RENDERDOCK_DEVICE_LOG names another file.
    static let logURL: URL? = {
        if let path = ProcessInfo.processInfo.environment["RENDERDOCK_DEVICE_LOG"], !path.isEmpty { return URL(fileURLWithPath: path) }
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return nil }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RenderDock/device-link.log")
    }()

    func start() {
        queue.async {
            guard self.central == nil else { return }
            // Without an Info.plist that says why, macOS ends a process that touches Bluetooth.
            guard Bundle.main.bundlePath.hasSuffix(".app"), Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil else {
                self.set(.unavailable)
                return
            }
            self.set(.looking)
            self.central = CBCentralManager(delegate: self, queue: self.queue)
        }
    }

    func stop() {
        queue.async {
            self.keepalive?.cancel()
            self.keepalive = nil
            if let p = self.peripheral { self.central?.cancelPeripheralConnection(p) }
            self.central?.stopScan()
            self.central = nil
            self.reset()
            self.failures = 0
            self.gone = nil
            self.note("switched off")
            self.set(.off)
        }
    }

    /// Forgets the device this Mac connects to, so the next one found is taken.
    func forget() {
        UserDefaults.standard.removeObject(forKey: Self.rememberedKey)
        queue.async {
            if let p = self.peripheral { self.central?.cancelPeripheralConnection(p) }
            self.reset()
            self.failures = 0
            self.gone = nil
            self.note("forgot the device")
            if self.central?.state == .poweredOn { self.look() }
        }
    }

    /// Sends a snapshot. It is also what the keepalive repeats until the next one.
    func send(_ heartbeat: BuddyProtocol.Heartbeat) {
        queue.async {
            // Only what can actually go out counts as offered. Between a disconnect and the next connection there
            // is nothing to send to, and an id noted then would be taken for one offered on the next link.
            guard case .connected = self.state, let p = self.peripheral, self.rx != nil, p.state == .connected else { return }
            if let prompt = heartbeat.prompt { self.offered.insert(prompt.id) }
            if let ask = heartbeat.extended?.ask { self.offeredAsks.insert(ask.id) }
            let line = heartbeat.line()
            guard line != self.lastLine else { return }
            self.lastLine = line
            self.write(line)
        }
    }

    /// This Mac's own numbers (`BuddyProtocol.mac`), for a device that has a page for them. Like everything but
    /// counts, they go out only on an encrypted link; and only when the line differs from the last one sent.
    func sendMac(_ line: Data) {
        queue.async {
            guard case .connected(_, true, _) = self.state, self.devicePages, let p = self.peripheral, self.rx != nil, p.state == .connected else { return }
            guard line != self.lastMac else { return }
            self.lastMac = line
            self.write(line)
        }
    }

    // MARK: on `queue`

    private func set(_ new: Status) {
        if gone != nil {
            switch new {
            case .looking, .connecting: return
            default: break
            }
        }
        guard new != state else { return }
        state = new
        DispatchQueue.main.async { self.onStatus?() }
    }

    private func note(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        trace.append("\(formatter.string(from: Date())) \(text)")
        if trace.count > 120 { trace.removeFirst(trace.count - 120) }
        guard let url = Self.logURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (trace.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private var isSecure: Bool {
        if case .connected(_, true, _) = state { return true }
        return false
    }

    private func reset() {
        peripheral = nil
        rx = nil
        offered = []
        offeredAsks = []
        lastLine = nil
        lastMac = nil
        lastWriteError = ""
        assembler = BuddyProtocol.LineAssembler()
        deviceExtended = false
        deviceUnicode = false
        deviceInbox = false
        devicePages = false
        deviceWiFi = nil
    }

    private func look() {
        guard let central, central.state == .poweredOn, peripheral == nil else { return }
        set(.looking)
        // A device that was chosen before is the only one this Mac goes back to.
        if let text = UserDefaults.standard.string(forKey: Self.rememberedKey), let id = UUID(uuidString: text),
           let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            if gone == nil { note("going back to the remembered device") }
            connect(known, name: known.name ?? BuddyProtocol.namePrefix)
            return
        }
        if gone == nil { note(UserDefaults.standard.string(forKey: Self.rememberedKey) == nil ? "scanning" : "scanning for the remembered device") }
        // A device's name may arrive in a second packet, after the first sighting. Asking to be told of every
        // sighting is what makes sure the one that carries the name is seen.
        central.scanForPeripherals(withServices: [Self.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    private func connect(_ p: CBPeripheral, name: String) {
        peripheral = p
        p.delegate = self
        central?.stopScan()
        attempting = name
        if gone == nil { note("connecting to \(name)") }
        set(.connecting(name))
        central?.connect(p, options: nil)
    }

    private func write(_ data: Data) {
        guard let peripheral, let rx, peripheral.state == .connected else { return }
        let type: CBCharacteristicWriteType = rx.properties.contains(.write) ? .withResponse : .withoutResponse
        // Each piece fits one packet, whichever way it is written: a longer write "with response" would be split
        // by macOS into a queued write, which small devices do not all take.
        for chunk in BuddyProtocol.chunks(data, size: max(20, peripheral.maximumWriteValueLength(for: .withoutResponse))) {
            peripheral.writeValue(chunk, for: rx, type: type)
        }
    }

    private func startKeepalive() {
        keepalive?.cancel()
        ticks = 0
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.tick, repeating: Self.tick)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.ticks += 1
            if self.ticks % Self.heartbeatTicks == 0 {
                if let line = self.lastLine { self.write(line) }
                // The device takes this Mac's numbers for stale after three quarters of a minute without them.
                if let mac = self.lastMac { self.write(mac) }
            }
            // The device says nothing until the link is encrypted, and pairing takes as long as the user takes to
            // type six digits. So for the first minute and a half it is asked often; after that, now and then
            // (for the battery, and in case the answer changes).
            let waitingForPairing = !self.isSecure && self.ticks <= 45
            if waitingForPairing || self.ticks % (Self.heartbeatTicks * 3) == 0 { self.write(BuddyProtocol.statusRequest) }
        }
        timer.resume()
        keepalive = timer
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: note("Bluetooth is on"); look()
        case .resetting: note("Bluetooth is resetting"); reset(); gone = nil; set(.looking)
        case .poweredOff: note("Bluetooth is off"); reset(); gone = nil; set(.bluetoothOff)
        case .unauthorized: note("no Bluetooth permission"); reset(); gone = nil; set(.notAllowed)
        case .unsupported: note("Bluetooth is not supported here"); reset(); gone = nil; set(.unavailable)
        default: break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.peripheral == nil else { return }
        // Once a device has been chosen, that one and no other: anything else nearby with the right name is
        // passed over until the user asks to forget the device.
        if let text = UserDefaults.standard.string(forKey: Self.rememberedKey), let remembered = UUID(uuidString: text),
           peripheral.identifier != remembered {
            return
        }
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        guard name.hasPrefix(BuddyProtocol.namePrefix) else { return }
        connect(peripheral, name: name)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if gone != nil {
            // The refusal comes before this point, so getting here means the old pairing is out of the way.
            gone = nil
            set(.connecting(attempting))
        }
        note("connected")
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if pairingIsGone(error) { return }
        note("could not connect\(Self.brief(error))")
        reset()
        set(.looking)
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.look() }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if pairingIsGone(error) { return }
        let wasSecure = isSecure
        failures = wasSecure ? 0 : failures + 1
        // 2, 4, 8 … 60 seconds after a connection that never got as far as an encrypted link.
        let wait = wasSecure ? 2.0 : min(60.0, pow(2.0, Double(min(failures, 6))))
        note("disconnected\(Self.brief(error)); looking again in \(Int(wait)) s")
        keepalive?.cancel()
        keepalive = nil
        reset()
        set(.looking)   // not "connected" a moment longer: nothing may be sent, offered or taken until the next link is up
        queue.asyncAfter(deadline: .now() + wait) { [weak self] in self?.look() }
    }

    /// The device refused this Mac because it no longer has the pairing (see `BuddyProtocol.pairingGone`): say so,
    /// and try again only now and then. Nothing this app can do brings the link back; forgetting the device in
    /// System Settings is the user's to do, and macOS pairs afresh on the first connection after that.
    /// False for any other error, which is then handled as before.
    private func pairingIsGone(_ error: Error?) -> Bool {
        let e = error as NSError?
        guard BuddyProtocol.pairingGone(domain: e?.domain, code: e?.code) else { return false }
        let wait = BuddyProtocol.retryWhilePairingGone
        if gone == nil {
            note("the device no longer has this Mac's pairing\(Self.brief(error)): it has to be forgotten in Bluetooth settings; trying every \(Int(wait)) s until then")
        }
        let name = attempting.isEmpty ? BuddyProtocol.namePrefix : attempting
        keepalive?.cancel()
        keepalive = nil
        reset()
        gone = name
        set(.pairingGone(name))
        queue.asyncAfter(deadline: .now() + wait) { [weak self] in self?.look() }
        return true
    }

    /// An error as a short tail for the trace: its domain and number, which is all that is needed to look it up.
    private static func brief(_ error: Error?) -> String {
        guard let error = error as NSError? else { return "" }
        return " (\(error.domain) \(error.code))"
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            note("the service was not found\(Self.brief(error))")
            return
        }
        peripheral.discoverCharacteristics([Self.rxUUID, Self.txUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        rx = service.characteristics?.first { $0.uuid == Self.rxUUID }
        let tx = service.characteristics?.first { $0.uuid == Self.txUUID }
        note("characteristics: write \(rx != nil), notify \(tx != nil)\(Self.brief(error))")
        // A device that wants an encrypted link asks macOS to pair, on connecting or on the first thing it refuses.
        if let tx { peripheral.setNotifyValue(true, for: tx) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.txUUID, peripheral === self.peripheral else { return }
        if error != nil {
            note("subscribing was refused\(Self.brief(error)); trying again")
            // A device may refuse until pairing is done. Ask again for as long as it stays connected.
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.peripheral === peripheral, peripheral.state == .connected else { return }
                peripheral.setNotifyValue(true, for: characteristic)
            }
            return
        }
        guard characteristic.isNotifying, rx != nil else { return }
        note("subscribed")
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.rememberedKey)
        set(.connected(name: peripheral.name ?? BuddyProtocol.namePrefix, secure: false, battery: nil))
        // The owner's name is part of the protocol too. RenderDock does not send one.
        write(BuddyProtocol.timeSync())
        write(BuddyProtocol.statusRequest)
        startKeepalive()
        DispatchQueue.main.async { self.onReady?() }
    }

    /// A write the device refused. Only the first of a kind is noted: while pairing they all fail the same way.
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let text = Self.brief(error)
        guard text != lastWriteError else { return }
        lastWriteError = text
        note(text.isEmpty ? "writes go through" : "a write was refused\(text)")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.txUUID, let value = characteristic.value else { return }
        for line in assembler.feed(value) {
            switch BuddyProtocol.parse(line) {
            case .permission(let id, let decision):
                // Only an answer to something this link put on the device counts, and only once.
                guard isSecure else {
                    note("an answer on a link that is not encrypted: ignored")
                    continue
                }
                guard offered.remove(id) != nil else {
                    note("an answer for a request that was not offered: ignored")
                    continue
                }
                note("an answer from the device: \(decision)")
                DispatchQueue.main.async { self.onAnswer?(id, decision) }
            case .choice(let id, let index):
                guard isSecure else {
                    note("a pick on a link that is not encrypted: ignored")
                    continue
                }
                guard offeredAsks.remove(id) != nil else {
                    note("a pick for a question that was not offered: ignored")
                    continue
                }
                note("a pick from the device")
                DispatchQueue.main.async { self.onChoice?(id, index) }
            case .status(let device):
                guard case .connected(let name, let wasSecure, _) = state else { continue }
                let changed = device.secure != wasSecure || device.extended != deviceExtended || device.unicode != deviceUnicode || device.inbox != deviceInbox
                    || device.pages != devicePages
                deviceExtended = device.extended
                deviceUnicode = device.unicode
                deviceInbox = device.inbox
                devicePages = device.pages
                if device.wifi != deviceWiFi || device.wifiWas != deviceWiFiWas {
                    deviceWiFi = device.wifi
                    deviceWiFiWas = device.wifiWas
                    DispatchQueue.main.async { self.onStatus?() }
                }
                set(.connected(name: device.name ?? name, secure: device.secure, battery: device.batteryPercent))
                if changed {
                    note("the device says: encrypted \(device.secure), RenderDock's fields \(device.extended), beyond ASCII \(device.unicode), questions and notices \(device.inbox), pages \(device.pages)")
                    if device.secure && !wasSecure {
                        failures = 0
                        write(BuddyProtocol.timeSync())   // the one sent on connecting was refused if pairing was not done yet
                    }
                    lastLine = nil   // what may be sent has changed
                    lastMac = nil
                    DispatchQueue.main.async { self.onReady?() }
                }
            case .networks(let list):
                guard isSecure else { continue }
                note("the device sees \(list.count) networks")
                DispatchQueue.main.async { self.onNetworks?(list) }
            case .ack, .unknown:
                continue
            }
        }
    }
}
