import Foundation
import IOKit

/// One fan, as the Mac reports it.
package struct Fan: Equatable {
    /// Turns a minute, now.
    package var rpm: Double
    /// The slowest and the fastest it runs, when the Mac says.
    package var min: Double?
    package var max: Double?

    package init(rpm: Double, min: Double? = nil, max: Double? = nil) {
        self.rpm = rpm
        self.min = min
        self.max = max
    }

    /// Where it is between its slowest and its fastest, 0…1. Nil when the Mac does not say what those are.
    package var fraction: Double? {
        guard let min, let max, max > min else { return nil }
        return Swift.min(1, Swift.max(0, (rpm - min) / (max - min)))
    }
}

/// Reads a few values from the Mac's System Management Controller: how fast the fans turn, and how much power
/// the whole machine is drawing. It goes through the controller's own user client, which any program may open:
/// no admin rights, no helper, and nothing is ever written to it.
///
/// Which values exist depends on the Mac (a desktop has no battery, some laptops have no fan). One that is not
/// there reads as nil and is then simply not shown: never as nought.
package final class SMCReader {
    private var connection: io_connect_t = 0

    package init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
    }

    deinit { if connection != 0 { IOServiceClose(connection) } }

    /// The fans the Mac says it has, in its own order. Empty when it has none or will not say.
    package func fans() -> [Fan] {
        guard let count = value("FNum"), count >= 1, count <= 8 else { return [] }
        return (0..<Int(count)).compactMap { n in
            guard let rpm = value("F\(n)Ac"), rpm >= 0 else { return nil }
            return Fan(rpm: rpm, min: value("F\(n)Mn"), max: value("F\(n)Mx"))
        }
    }

    /// What the whole machine is drawing, in watts, as the controller reports it. Not measured at the wall.
    package func systemPower() -> Double? {
        guard let watts = value("PSTR"), watts > 0, watts < 2000 else { return nil }
        return watts
    }

    /// One key as a number, or nil if the Mac has no such key or its kind of value is not one read here.
    package func value(_ key: String) -> Double? {
        guard key.utf8.count == 4 else { return nil }
        var ask = Param()
        ask.key = Self.code(key)
        ask.data8 = 9   // "what kind of value is this, and how long"
        guard let info = call(&ask) else { return nil }
        var read = Param()
        read.key = Self.code(key)
        read.keyInfo.dataSize = info.keyInfo.dataSize
        read.data8 = 5   // "read it"
        guard let out = call(&read) else { return nil }
        let size = Int(Swift.min(info.keyInfo.dataSize, 32))
        let bytes = withUnsafeBytes(of: out.bytes) { Array($0.prefix(size)) }
        return Self.decode(type: Self.text(info.keyInfo.dataType), bytes: bytes)
    }

    // MARK: Pure helpers (covered by rd-checks)

    /// The value in a key's bytes, by the kind the controller says it is. Apple silicon keeps a float as the
    /// processor has it; the older fixed-point kinds are written high byte first.
    package static func decode(type: String, bytes: [UInt8]) -> Double? {
        func high16() -> UInt16? { bytes.count >= 2 ? UInt16(bytes[0]) << 8 | UInt16(bytes[1]) : nil }
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let value = bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
            return value.isFinite ? Double(value) : nil
        case "ui8 ": return bytes.first.map(Double.init)
        case "ui16": return high16().map(Double.init)
        case "ui32": return bytes.count >= 4 ? Double(bytes.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }) : nil
        case "fpe2": return high16().map { Double($0) / 4 }                               // 14 bits and 2: a fan on an Intel Mac
        case "sp78": return high16().map { Double(Int16(bitPattern: $0)) / 256 }         // signed, 8 bits after the point
        default: return nil
        }
    }

    package static func code(_ key: String) -> UInt32 { key.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }

    package static func text(_ code: UInt32) -> String {
        String(bytes: [UInt8(code >> 24), UInt8((code >> 16) & 255), UInt8((code >> 8) & 255), UInt8(code & 255)], encoding: .ascii) ?? ""
    }

    // MARK: The controller's own layout (80 bytes; nothing here is ours to choose)

    private struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
    private struct Limits { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, memory: UInt32 = 0 }
    private struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0; var dataAttributes: UInt8 = 0 }
    private struct Param {
        var key: UInt32 = 0
        var version = Version()
        var limits = Limits()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0, status: UInt8 = 0, data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
            = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private func call(_ input: inout Param) -> Param? {
        var output = Param()
        var size = MemoryLayout<Param>.size
        // 2 is the one call this user client has for all of it; what is wanted goes in `data8`.
        let result = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<Param>.size, &output, &size)
        return result == kIOReturnSuccess && output.result == 0 ? output : nil
    }
}
