import Darwin
import Foundation
import IOKit.ps

/// The live numbers the Island shows while it's open: CPU and memory in use,
/// network down and up, and the battery. Read only while it's open.
public struct IslandStats: Equatable, Sendable {
    public var cpu: Double?
    public var memory: Double?
    public var rateIn: Double = 0
    public var rateOut: Double = 0
    public var battery: Double?

    public init(cpu: Double? = nil, memory: Double? = nil, rateIn: Double = 0, rateOut: Double = 0, battery: Double? = nil) {
        self.cpu = cpu
        self.memory = memory
        self.rateIn = rateIn
        self.rateOut = rateOut
        self.battery = battery
    }
}

/// Takes `IslandStats` samples; rates come from the difference between two.
public struct IslandSampler: Sendable {
    private var lastTicks: (busy: UInt64, total: UInt64)?
    private var lastBytes: (down: UInt64, up: UInt64, at: Date)?

    public init() {}

    public mutating func sample(now: Date = Date()) -> IslandStats {
        var stats = IslandStats()
        if let ticks = Self.cpuTicks() {
            if let last = lastTicks, ticks.total > last.total {
                stats.cpu = Double(ticks.busy - last.busy) / Double(ticks.total - last.total)
            }
            lastTicks = ticks
        }
        stats.memory = Self.memoryUsed()
        let bytes = Self.networkBytes()
        if let last = lastBytes {
            let seconds = max(now.timeIntervalSince(last.at), 0.001)
            stats.rateIn = Double(bytes.down &- last.down) / seconds
            stats.rateOut = Double(bytes.up &- last.up) / seconds
            if bytes.down < last.down || bytes.up < last.up { stats.rateIn = 0; stats.rateOut = 0 }
        }
        lastBytes = (bytes.down, bytes.up, now)
        stats.battery = Self.battery()
        return stats
    }

    static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return (user + system + nice, user + system + nice + idle)
    }

    /// The share of memory in use the way Activity Monitor counts it: app
    /// memory, wired and compressed.
    static func memoryUsed() -> Double? {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = Double(getpagesize())
        let used = (Double(info.internal_page_count) - Double(info.purgeable_count) + Double(info.wire_count)
            + Double(info.compressor_page_count)) * page
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        return total > 0 ? min(max(used / total, 0), 1) : nil
    }

    /// Bytes received and sent on every interface but loopback.
    static func networkBytes() -> (down: UInt64, up: UInt64) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return (0, 0) }
        defer { freeifaddrs(head) }
        var down: UInt64 = 0, up: UInt64 = 0
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0, let raw = entry.ifa_data else { continue }
            let data = raw.assumingMemoryBound(to: if_data.self).pointee
            down += UInt64(data.ifi_ibytes)
            up += UInt64(data.ifi_obytes)
        }
        return (down, up)
    }

    /// The internal battery's charge, 0 to 1, or nil on a Mac without one.
    static func battery() -> Double? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return Double(current) / Double(max)
        }
        return nil
    }
}
