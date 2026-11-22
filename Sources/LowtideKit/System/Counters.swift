import Darwin
import Foundation
import IOKit

/// The battery, from the AppleSmartBattery registry entry.
enum Battery {
    static func read() -> BatteryState? {
        IORegistry.withServices("AppleSmartBattery") { entries in
            entries.first.flatMap(IORegistry.properties).flatMap(parse)
        }
    }

    /// The registry's properties as a battery; nil without a charge reading.
    static func parse(_ props: [String: Any]) -> BatteryState? {
        // Newer macOS keeps the raw capacities only inside `BatteryData`.
        let data = props["BatteryData"] as? [String: Any] ?? [:]
        func number(_ key: String) -> Double? { ((props[key] ?? data[key]) as? NSNumber)?.doubleValue }
        func flag(_ key: String) -> Bool { (props[key] as? Bool) ?? false }
        guard let current = number("CurrentCapacity") else { return nil }
        let max = Swift.max(number("MaxCapacity") ?? 100, 1)
        let rawMax = number("AppleRawMaxCapacity") ?? number("NominalChargeCapacity")
        let design = number("DesignCapacity")
        let volts = (number("Voltage") ?? 0) / 1000
        // InstantAmperage is a signed milliamp count stored unsigned.
        let amps = (props["InstantAmperage"] as? NSNumber).map { Double(Int32(truncatingIfNeeded: $0.int64Value)) } ?? 0
        let charging = flag("IsCharging")
        let minutes = number(charging ? "AvgTimeToFull" : "AvgTimeToEmpty").flatMap { $0 > 0 && $0 < 6000 ? Int($0) : nil }
        var health = 0.0
        if let rawMax, let design, design > 0 { health = Swift.min(rawMax / design * 100, 100) }
        return BatteryState(percent: Swift.min(current / max * 100, 100), charging: charging,
                            plugged: flag("ExternalConnected"), watts: volts * amps / 1000,
                            celsius: number("Temperature").map { $0 / 100 } ?? 0, cycles: Int(number("CycleCount") ?? 0),
                            health: health, minutes: minutes)
    }
}

/// Counters the kernel keeps since boot: disk bytes and network bytes.
enum Counters {
    /// Bytes read and written by every disk since boot.
    static func diskBytes() -> (read: UInt64, written: UInt64) {
        IORegistry.withServices("IOBlockStorageDriver") { entries in
            entries.reduce(into: (UInt64(0), UInt64(0))) { sum, entry in
                guard let stats = IORegistry.property(entry, "Statistics") as? [String: Any] else { return }
                sum.0 += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                sum.1 += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
        }
    }

    /// One interface's byte counters.
    struct Interface: Equatable {
        var name: String
        var bytesIn: UInt64
        var bytesOut: UInt64
    }

    /// 64-bit byte counters of every interface (`NET_RT_IFLIST2`; `getifaddrs`
    /// only has 32-bit ones, which wrap every 4 GB).
    static func interfaces() -> [Interface] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, 6, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 6, &buffer, &size, nil, 0) == 0 else { return [] }
        var out: [Interface] = []
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= size {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= size {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                    if if_indextoname(UInt32(info.ifm_index), &name) != nil {
                        out.append(Interface(name: String(cBuffer: name), bytesIn: info.ifm_data.ifi_ibytes,
                                             bytesOut: info.ifm_data.ifi_obytes))
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return out
    }

    /// Interfaces whose traffic is the Mac's own: not loopback, and not the
    /// tunnels and peer-to-peer links that carry the same bytes again.
    static func counts(_ name: String) -> Bool {
        let skip = ["lo", "utun", "gif", "stf", "awdl", "llw", "bridge", "anpi", "ipsec", "ap", "XHC", "vmenet"]
        return !skip.contains { name.hasPrefix($0) }
    }

    /// Rates between two readings, and the busiest interface.
    static func rate(from before: [Interface], to now: [Interface], seconds: Double) -> NetworkRate {
        guard seconds > 0 else { return NetworkRate() }
        var rate = NetworkRate()
        var busiest = 0.0
        for interface in now where counts(interface.name) {
            guard let old = before.first(where: { $0.name == interface.name }) else { continue }
            // A counter that went backwards was reset (the interface came back).
            let down = interface.bytesIn >= old.bytesIn ? Double(interface.bytesIn - old.bytesIn) : 0
            let up = interface.bytesOut >= old.bytesOut ? Double(interface.bytesOut - old.bytesOut) : 0
            rate.bytesIn += down / seconds
            rate.bytesOut += up / seconds
            if down + up > busiest {
                busiest = down + up
                rate.interface = interface.name
            }
        }
        return rate
    }

    /// The home volume's size and free space, counting purgeable space as
    /// free like Finder does. Slow (hundreds of ms): call off the main thread.
    static func diskSpace() -> DiskSpace? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, total > 0 else { return nil }
        return DiskSpace(total: Int64(total), available: values.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}
