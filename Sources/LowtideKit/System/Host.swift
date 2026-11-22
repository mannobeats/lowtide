import Darwin
import Foundation
import IOKit

/// What the kernel says about CPU load and memory, and the chip itself.
enum Host {
    /// Busy and total ticks per logical CPU since boot.
    static func coreTicks() -> [(busy: UInt64, total: UInt64)] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        // Four states per CPU: user, system, idle, nice.
        let states = Int(CPU_STATE_MAX)
        return (0..<Int(count)).map { cpu in
            let base = cpu * states
            func tick(_ state: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[base + Int(state)])) }
            let user = tick(CPU_STATE_USER), system = tick(CPU_STATE_SYSTEM)
            let idle = tick(CPU_STATE_IDLE), nice = tick(CPU_STATE_NICE)
            return (user + system + nice, user + system + idle + nice)
        }
    }

    /// Per-core busy share (0–100) between two tick readings.
    static func usage(from before: [(busy: UInt64, total: UInt64)], to now: [(busy: UInt64, total: UInt64)]) -> [Double] {
        zip(now, before).map { now, before in
            let total = now.total &- before.total
            guard now.total > before.total, total > 0 else { return 0 }
            let busy = now.busy >= before.busy ? now.busy - before.busy : 0
            return min(Double(busy) / Double(total) * 100, 100)
        }
    }

    static func memory() -> MemoryState {
        var state = MemoryState()
        state.total = Sysctl.int("hw.memsize").map { UInt64($0) } ?? 0
        let page = UInt64(Sysctl.int("hw.pagesize") ?? 16384)
        if let swap = Sysctl.value("vm.swapusage", as: xsw_usage.self) {
            state.swapUsed = swap.xsu_used
            state.swapTotal = swap.xsu_total
        }
        state.pressure = pressure(Sysctl.int("kern.memorystatus_vm_pressure_level"))
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let ok = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard ok == KERN_SUCCESS else { return state }
        apply(stats, page: page, to: &state)
        return state
    }

    /// Activity Monitor's arithmetic: app memory is anonymous pages less
    /// purgeable ones; used is app + wired + compressed.
    static func apply(_ stats: vm_statistics64, page: UInt64, to state: inout MemoryState) {
        func pages(_ n: UInt32) -> UInt64 { UInt64(n) * page }
        let anonymous = stats.internal_page_count >= stats.purgeable_count ? stats.internal_page_count - stats.purgeable_count : 0
        state.app = pages(anonymous)
        state.wired = pages(stats.wire_count)
        state.compressed = pages(stats.compressor_page_count)
        state.cached = pages(stats.external_page_count) + pages(stats.purgeable_count)
        state.used = state.app + state.wired + state.compressed
    }

    static func pressure(_ level: Int64?) -> MemoryPressure {
        switch level {
        case 4: .critical
        case 2: .warning
        default: .normal
        }
    }

    static func thermal() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .nominal
        }
    }

    static func chip() -> ChipInfo {
        let levels = Sysctl.int("hw.nperflevels") ?? 1
        // perflevel0 is the fastest tier; the last is the efficiency tier.
        var performance = Int(Sysctl.int("hw.perflevel0.logicalcpu") ?? 0)
        let efficiency = levels > 1 ? Int(Sysctl.int("hw.perflevel1.logicalcpu") ?? 0) : 0
        if performance == 0 { performance = Int(Sysctl.int("hw.logicalcpu") ?? 0) }
        return ChipInfo(name: Sysctl.string("machdep.cpu.brand_string"), efficiency: efficiency,
                        performance: performance, gpuCores: gpuCores(),
                        memory: Sysctl.int("hw.memsize").map { UInt64($0) } ?? 0)
    }

    /// The GPU's core count, from the accelerator's registry entry.
    static func gpuCores() -> Int {
        IORegistry.withServices("AGXAccelerator") { entries in
            entries.first.flatMap { IORegistry.property($0, "gpu-core-count") as? Int } ?? 0
        }
    }

    /// The Mac's model identifier (`Mac15,6`).
    static let model: String = Sysctl.string("hw.model")
}
