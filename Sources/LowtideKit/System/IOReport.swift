import Foundation
import IOKit

/// Power, frequency and residency from IOReport, the counters Apple's own
/// `powermetrics` reads, without root. Two samples a second apart give
/// energy (watts) per block and how long each CPU cluster, core and the GPU
/// spent in each performance state (activity and average clock).
///
/// IOReport is a private library, so its functions are looked up at run
/// time; on a Mac without it (or a future one that drops a symbol) the
/// sampler is simply absent and the monitor shows what else it can.
final class PowerSampler {
    struct Reading {
        var power = PowerDraw()
        var gpuActive: Double = 0
        var gpuMHz = 0
        var clusters: [ClusterLoad] = []
        /// Per core, in IOReport's order (efficiency cores first).
        var cores: [ClusterLoad] = []
        var memRead: Double = 0
        var memWrite: Double = 0
        var traffic: [MemoryTraffic] = []
    }

    private let api: IOReportAPI
    private let subscription: OpaquePointer
    private let channels: CFMutableDictionary
    private var previous: (sample: CFDictionary, at: ContinuousClock.Instant)?
    private let tables: FrequencyTables

    init?() {
        guard let api = IOReportAPI.shared,
              let energy = api.copyChannels("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue()
        else { return nil }
        for (group, sub) in [("CPU Stats", "CPU Complex Performance States"),
                             ("CPU Stats", "CPU Core Performance States"),
                             ("GPU Stats", "GPU Performance States"),
                             // Bytes each client moved through the memory controller.
                             ("AMC Stats", "Perf Counters")] {
            if let more = api.copyChannels(group as CFString, sub as CFString, 0, 0, 0)?.takeRetainedValue() {
                api.mergeChannels(energy, more, nil)
            }
        }
        guard let channels = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, energy) else { return nil }
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = api.createSubscription(nil, channels, &subscribed, 0, nil) else { return nil }
        subscribed?.release()
        self.api = api
        self.subscription = subscription
        self.channels = channels
        tables = FrequencyTables.load()
    }

    deinit {
        // The subscription is a CF object (Create rule).
        Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(subscription)).release()
    }

    /// Forgets the last sample, so the next reading starts a fresh interval.
    func reset() { previous = nil }

    /// Everything since the previous call (nil on the first).
    func sample() -> Reading? {
        guard let now = api.createSamples(subscription, channels, nil)?.takeRetainedValue() else { return nil }
        let at = ContinuousClock.now
        defer { previous = (now, at) }
        guard let before = previous,
              let delta = api.createSamplesDelta(before.sample, now, nil)?.takeRetainedValue() else { return nil }
        let seconds = max((at - before.at).seconds, 0.05)
        return parse(delta, seconds: seconds)
    }

    private func parse(_ delta: CFDictionary, seconds: Double) -> Reading {
        var out = Reading()
        guard let items = (delta as NSDictionary)["IOReportChannels"] as? [NSDictionary] else { return out }
        var energy = EnergyTotals()
        for item in items {
            let channel = item as CFDictionary
            let group = api.string(api.channelGroup(channel))
            switch group {
            case "Energy Model":
                let value = api.integerValue(channel, 0)
                let unit = api.string(api.unitLabel(channel))
                energy.add(name: api.string(api.channelName(channel)), watts: IOReportMath.watts(value, unit: unit, seconds: seconds))
            case "CPU Stats":
                let name = api.string(api.channelName(channel))
                let table = name.hasPrefix("E") || name.contains("ECPU") ? tables.ecpu : tables.pcpu
                let (active, mhz) = IOReportMath.residency(states(channel), table: table, byVoltage: true)
                let load = ClusterLoad(name: name, active: active, mhz: mhz)
                if api.string(api.channelSubGroup(channel)) == "CPU Core Performance States" {
                    out.cores.append(load)
                } else {
                    out.clusters.append(load)
                }
            case "GPU Stats":
                guard api.string(api.channelName(channel)) == "GPUPH" else { continue }
                let (active, mhz) = IOReportMath.residency(states(channel), table: tables.gpu, byVoltage: false)
                out.gpuActive = active
                out.gpuMHz = mhz
            case "AMC Stats":
                let bytes = api.integerValue(channel, 0)
                guard bytes > 0 else { continue }
                IOReportMath.addTraffic(name: api.string(api.channelName(channel)), rate: Double(bytes) / seconds, to: &out)
            default:
                continue
            }
        }
        out.power = energy.power
        out.traffic.sort { $0.bytes > $1.bytes }
        return out
    }

    private func states(_ channel: CFDictionary) -> [(name: String, time: Int64)] {
        let count = api.stateCount(channel)
        guard count > 0 else { return [] }
        return (0..<count).map { (api.string(api.stateName(channel, $0)), api.stateResidency(channel, $0)) }
    }
}

/// Energy channels, summed by block.
struct EnergyTotals {
    var power = PowerDraw()
    /// The chip's own CPU total, when it reports one.
    private var cpuTotal: Double = 0
    /// The per-cluster CPU channels, when it doesn't.
    private var cpuTyped: Double = 0

    mutating func add(name: String, watts: Double) {
        if name == "CPU Energy" || (name.hasPrefix("DIE_") && name.hasSuffix("CPU Energy")) {
            cpuTotal += watts
        } else if name.hasSuffix("CPU Energy") || name.hasSuffix("_CPU") {
            cpuTyped += watts
        } else if name == "GPU Energy" || name == "GPU" {
            power.gpu += watts
        } else if name.hasPrefix("ANE") {
            power.ane += watts
        } else if name.hasPrefix("DRAM") {
            power.dram += watts
        }
        power.cpu = cpuTotal > 0 ? cpuTotal : cpuTyped
    }
}

/// The arithmetic behind the readings, kept apart so it can be tested.
enum IOReportMath {
    /// Joules (in the channel's unit) over an interval, as watts.
    static func watts(_ value: Int64, unit: String, seconds: Double) -> Double {
        let perSecond = Double(value) / seconds
        switch unit.trimmingCharacters(in: .whitespaces) {
        case "mJ": return perSecond / 1e3
        case "nJ": return perSecond / 1e9
        default: return perSecond / 1e6
        }
    }

    /// Share of time active (0–100) and the residency-weighted clock of a
    /// state channel. CPU states are named `V<n>P<m>` after their voltage
    /// step; GPU states are listed in table order.
    static func residency(_ states: [(name: String, time: Int64)], table: [Int], byVoltage: Bool) -> (Double, Int) {
        var total: Int64 = 0, active: Int64 = 0
        var weighted = 0.0
        var index = 0
        for state in states {
            total += state.time
            if ["IDLE", "OFF", "DOWN"].contains(state.name) { continue }
            active += state.time
            var slot = index
            if byVoltage, state.name.hasPrefix("V") {
                let digits = state.name.dropFirst().prefix { $0.isNumber }
                slot = Int(digits) ?? index
            }
            if table.indices.contains(slot) { weighted += Double(table[slot]) * Double(state.time) }
            index += 1
        }
        guard total > 0 else { return (0, 0) }
        let share = Double(active) / Double(total) * 100
        return (share, active > 0 ? Int(weighted / Double(active)) : 0)
    }

    /// Who an AMC client counter belongs to.
    static func client(_ name: String) -> String {
        if name.hasPrefix("PCPU") || name.hasPrefix("ECPU") || name.hasPrefix("MCPU") { return "CPU" }
        if name.hasPrefix("GFX") { return "GPU" }
        if name.hasPrefix("ANE") { return "Neural Engine" }
        if name.hasPrefix("DISP") { return "Display" }
        if name.hasPrefix("ANS") { return "SSD" }
        if ["ISP", "AVE", "AVD", "PRORES"].contains(where: name.hasPrefix) { return "Media" }
        return "I/O"
    }

    static func addTraffic(name: String, rate: Double, to out: inout PowerSampler.Reading) {
        switch name {
        case "DCS RD": out.memRead += rate
        case "DCS WR": out.memWrite += rate
        case _ where name.hasSuffix(" DCS RD") || name.hasSuffix(" DCS WR"):
            let who = client(name)
            if let i = out.traffic.firstIndex(where: { $0.client == who }) {
                out.traffic[i].bytes += rate
            } else {
                out.traffic.append(MemoryTraffic(client: who, bytes: rate))
            }
        default: break
        }
    }

    /// A DVFS table (`voltage-states*`): 8-byte entries, the first 4 the
    /// clock in Hz (M1–M4) or kHz (M5), in MHz here; zero entries skipped.
    static func frequencyTable(_ data: Data) -> [Int] {
        let bytes = [UInt8](data)
        return stride(from: 0, to: bytes.count - 7, by: 8).compactMap { offset in
            let raw = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[offset + 3]) << 24
            let mhz = raw >= 100_000_000 ? Int(raw / 1_000_000) : raw >= 100_000 ? Int(raw / 1000) : 0
            return mhz > 0 ? mhz : nil
        }
    }
}

/// Clock tables for the efficiency cores, performance cores and GPU.
struct FrequencyTables {
    var ecpu: [Int] = []
    var pcpu: [Int] = []
    var gpu: [Int] = []

    static func load() -> FrequencyTables {
        var tables = FrequencyTables()
        IORegistry.withServices("AppleARMIODevice") { entries in
            for entry in entries where IORegistry.name(entry) == "pmgr" {
                func table(_ key: String) -> [Int]? {
                    (IORegistry.property(entry, key) as? Data).map(IOReportMath.frequencyTable).flatMap { $0.isEmpty ? nil : $0 }
                }
                tables.ecpu = table("voltage-states1-sram") ?? table("voltage-states9-sram") ?? []
                tables.pcpu = table("voltage-states5-sram") ?? []
                tables.gpu = table("voltage-states9-sram") ?? table("voltage-states9") ?? []
            }
        }
        return tables
    }
}

/// The IOReport functions, found in `/usr/lib/libIOReport.dylib` at run time.
struct IOReportAPI: @unchecked Sendable {
    // @unchecked: only immutable C function pointers, safe to share.
    typealias CopyChannels = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    typealias Merge = @convention(c) (CFMutableDictionary, CFMutableDictionary, CFTypeRef?) -> Void
    typealias Subscribe = @convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> OpaquePointer?
    typealias Samples = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    typealias Delta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    typealias ChannelString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    typealias Integer = @convention(c) (CFDictionary, Int32) -> Int64
    typealias Count = @convention(c) (CFDictionary) -> Int32
    typealias StateName = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?

    let copyChannels: CopyChannels
    let mergeChannels: Merge
    let createSubscription: Subscribe
    let createSamples: Samples
    let createSamplesDelta: Delta
    let channelGroup: ChannelString
    let channelSubGroup: ChannelString
    let channelName: ChannelString
    let unitLabel: ChannelString
    let integerValue: Integer
    let stateCount: Count
    let stateName: StateName
    let stateResidency: Integer

    static let shared: IOReportAPI? = {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func load<T>(_ name: String, _: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let copy = load("IOReportCopyChannelsInGroup", CopyChannels.self),
              let merge = load("IOReportMergeChannels", Merge.self),
              let subscribe = load("IOReportCreateSubscription", Subscribe.self),
              let samples = load("IOReportCreateSamples", Samples.self),
              let delta = load("IOReportCreateSamplesDelta", Delta.self),
              let group = load("IOReportChannelGetGroup", ChannelString.self),
              let subGroup = load("IOReportChannelGetSubGroup", ChannelString.self),
              let name = load("IOReportChannelGetChannelName", ChannelString.self),
              let unit = load("IOReportChannelGetUnitLabel", ChannelString.self),
              let integer = load("IOReportSimpleGetIntegerValue", Integer.self),
              let count = load("IOReportStateGetCount", Count.self),
              let stateName = load("IOReportStateGetNameForIndex", StateName.self),
              let residency = load("IOReportStateGetResidency", Integer.self)
        else { return nil }
        return IOReportAPI(copyChannels: copy, mergeChannels: merge, createSubscription: subscribe,
                           createSamples: samples, createSamplesDelta: delta, channelGroup: group,
                           channelSubGroup: subGroup, channelName: name, unitLabel: unit, integerValue: integer,
                           stateCount: count, stateName: stateName, stateResidency: residency)
    }()

    /// A channel string the caller doesn't own (Get rule).
    func string(_ value: Unmanaged<CFString>?) -> String {
        value.map { $0.takeUnretainedValue() as String } ?? ""
    }
}

extension Duration {
    /// The duration in seconds, as a Double.
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
