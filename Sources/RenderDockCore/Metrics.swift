import Darwin
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

package struct Metrics: Equatable {
    /// 0…1
    package var cpu: Double = 0
    package var gpu: Double?
    package var gpuMemBytes: UInt64?
    package var memUsed: UInt64 = 0
    package var memTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    /// 1 normal, 2 warning, 4 critical (the system's own memory pressure level)
    package var memPressure: Int = 1
    package var swapUsed: UInt64 = 0
    package var swapTotal: UInt64 = 0
    /// Average and maximum of the chip's die temperature sensors (°C)
    package var tempC: Double?
    package var tempMaxC: Double?
    package var thermal: ProcessInfo.ThermalState = .nominal
    package var diskFree: UInt64?
    package var diskTotal: UInt64?
    package var onAC: Bool?
    package var battery: Int?
    /// Something on the system is preventing idle sleep (caffeinate etc.)
    package var awakeHeld = false
    /// The fans, and what the whole machine draws in watts, as its controller reports them (see `SMCReader`).
    /// Empty and nil on a Mac that does not say.
    package var fans: [Fan] = []
    package var powerW: Double?

    /// The fastest fan, in turns a minute; and how far the hardest-working one is between its slowest and fastest.
    package var fanRpm: Double? { fans.map(\.rpm).max() }
    package var fanFraction: Double? { fans.compactMap(\.fraction).max() }

    package var memFraction: Double { memTotal > 0 ? min(1, Double(memUsed) / Double(memTotal)) : 0 }
    package var swapFraction: Double { swapTotal > 0 ? min(1, Double(swapUsed) / Double(swapTotal)) : 0 }

    package init() {}
}

// IOHID temperature sensors (private API; needs no admin rights on Apple silicon).
@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: AnyObject, _ matching: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: AnyObject) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: AnyObject, _ key: CFString) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: AnyObject, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: AnyObject, _ field: Int32) -> Double

/// Samples system metrics. Reads system APIs only: no subprocesses, no admin rights.
package final class MetricsSampler {
    package init() {}

    private var prevTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
    private var hidClient: AnyObject?
    private var dieSensors: [AnyObject] = []
    private var sampleCount = 0
    private var slow = Metrics()
    private lazy var controller = SMCReader()

    package func sample() -> Metrics {
        var m = Metrics()
        m.cpu = cpuUsage()
        readMemory(&m)
        readGPU(&m)
        m.thermal = ProcessInfo.processInfo.thermalState
        m.awakeHeld = awakeAssertionHeld()
        // Read every time: the draw moves quickly, and what a shot used is added up from these readings.
        m.fans = controller?.fans() ?? []
        m.powerW = controller?.systemPower()
        // Slow-changing values are sampled only every few rounds
        if sampleCount % 3 == 0 {
            readTemperature(&slow)
            readDisk(&slow)
            readPower(&slow)
        }
        sampleCount += 1
        m.tempC = slow.tempC
        m.tempMaxC = slow.tempMaxC
        m.diskFree = slow.diskFree
        m.diskTotal = slow.diskTotal
        m.onAC = slow.onAC
        m.battery = slow.battery
        return m
    }

    private func cpuUsage() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let now = (UInt64(info.cpu_ticks.0), UInt64(info.cpu_ticks.1), UInt64(info.cpu_ticks.2), UInt64(info.cpu_ticks.3))
        defer { prevTicks = now }
        guard let p = prevTicks else { return 0 }
        let busy = Double((now.0 &- p.user) &+ (now.1 &- p.system) &+ (now.3 &- p.nice))
        let idle = Double(now.2 &- p.idle)
        let total = busy + idle
        return total > 0 ? busy / total : 0
    }

    private func readMemory(_ m: inout Metrics) {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            // Same definition as "Memory Used" in Activity Monitor: App Memory + Wired Memory + Compressed
            let page = UInt64(vm_kernel_page_size)
            let app = UInt64(vm.internal_page_count) >= UInt64(vm.purgeable_count)
                ? UInt64(vm.internal_page_count) - UInt64(vm.purgeable_count) : 0
            m.memUsed = (app + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * page
        }
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 { m.memPressure = Int(level) }
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            m.swapUsed = swap.xsu_used
            m.swapTotal = swap.xsu_total
        }
    }

    private func readGPU(_ m: inout Metrics) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let perf = dict["PerformanceStatistics"] as? [String: Any] {
                if let util = (perf["Device Utilization %"] as? NSNumber)?.doubleValue {
                    m.gpu = max(m.gpu ?? 0, min(1, util / 100))
                }
                if let used = (perf["In use system memory"] as? NSNumber)?.uint64Value {
                    m.gpuMemBytes = max(m.gpuMemBytes ?? 0, used)
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }

    private func readTemperature(_ m: inout Metrics) {
        if hidClient == nil {
            guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)?.takeRetainedValue() else { return }
            _ = IOHIDEventSystemClientSetMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
            hidClient = client
            let services = (IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() as? [AnyObject]) ?? []
            // Keep only the on-die sensors (PMU tdie*); tdev and tcal are not chip temperatures
            dieSensors = services.filter {
                let name = (IOHIDServiceClientCopyProperty($0, "Product" as CFString)?.takeRetainedValue() as? String) ?? ""
                return name.lowercased().contains("tdie")
            }
        }
        var values: [Double] = []
        for s in dieSensors {
            guard let event = IOHIDServiceClientCopyEvent(s, 15, 0, 0)?.takeRetainedValue() else { continue }
            let v = IOHIDEventGetFloatValue(event, 15 << 16)
            if v > 0, v < 130 { values.append(v) }
        }
        guard !values.isEmpty else { m.tempC = nil; m.tempMaxC = nil; return }
        m.tempC = values.reduce(0, +) / Double(values.count)
        m.tempMaxC = values.max()
    }

    private func readDisk(_ m: inout Metrics) {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) else { return }
        if let free = v.volumeAvailableCapacityForImportantUsage { m.diskFree = UInt64(max(0, free)) }
        if let total = v.volumeTotalCapacity { m.diskTotal = UInt64(max(0, total)) }
    }

    private func readPower(_ m: inout Metrics) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            if let state = d[kIOPSPowerSourceStateKey] as? String { m.onAC = state == kIOPSACPowerValue }
            if let cap = d[kIOPSCurrentCapacityKey] as? Int { m.battery = cap }
        }
    }

    private func awakeAssertionHeld() -> Bool {
        var ref: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&ref) == kIOReturnSuccess, let dict = ref?.takeRetainedValue() as? [String: Any] else { return false }
        let count = { (key: String) in (dict[key] as? NSNumber)?.intValue ?? 0 }
        return count("PreventUserIdleSystemSleep") > 0 || count("PreventSystemSleep") > 0
    }
}

/// "Keep Awake While Rendering": the app holds its own assertion against idle sleep, equivalent to caffeinate -i; no system settings are changed.
package final class AwakeHolder {
    package init() {}

    private var assertion: IOPMAssertionID = 0
    package private(set) var holding = false

    package func set(_ on: Bool) {
        guard on != holding else { return }
        if on {
            let rc = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                L("渲染坞：有渲染任务在跑", "RenderDock: render jobs are running") as CFString, &assertion)
            holding = rc == kIOReturnSuccess
        } else {
            IOPMAssertionRelease(assertion)
            holding = false
        }
    }
}
