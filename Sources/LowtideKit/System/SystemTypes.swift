import Foundation

/// The chip: its name, how many cores of each kind, GPU cores and memory.
public struct ChipInfo: Sendable, Equatable {
    public var name: String
    public var efficiency: Int
    public var performance: Int
    public var gpuCores: Int
    public var memory: UInt64

    public init(name: String, efficiency: Int, performance: Int, gpuCores: Int, memory: UInt64) {
        self.name = name
        self.efficiency = efficiency
        self.performance = performance
        self.gpuCores = gpuCores
        self.memory = memory
    }

    public var cores: Int { efficiency + performance }
}

/// One logical CPU this second.
public struct CoreLoad: Sendable, Equatable {
    public enum Kind: Sendable { case efficiency, performance }
    public var kind: Kind
    /// Busy share from the scheduler, 0–100.
    public var usage: Double
    /// Average clock while running; 0 when idle or unknown.
    public var mhz: Int
}

/// A CPU cluster (or a single core) from IOReport's residency counters.
public struct ClusterLoad: Sendable, Equatable {
    public var name: String
    /// Share of the interval spent running, 0–100.
    public var active: Double
    /// Average clock while running, MHz.
    public var mhz: Int

    public init(name: String, active: Double, mhz: Int) {
        self.name = name
        self.active = active
        self.mhz = mhz
    }
}

/// Watts per block of the chip, and the whole Mac from the SMC.
public struct PowerDraw: Sendable, Equatable {
    public var cpu: Double = 0
    public var gpu: Double = 0
    public var ane: Double = 0
    public var dram: Double = 0
    /// The whole Mac (0 when the SMC doesn't say).
    public var system: Double = 0
    /// Whether the chip reports CPU energy at all. Some macOS releases
    /// leave its CPU channels at zero; then CPU watts are unknown, not 0.
    public var cpuReported = true
    /// The same for memory (DRAM) energy.
    public var dramReported = true

    public init(cpu: Double = 0, gpu: Double = 0, ane: Double = 0, dram: Double = 0, system: Double = 0) {
        self.cpu = cpu
        self.gpu = gpu
        self.ane = ane
        self.dram = dram
        self.system = system
    }

    /// The chip's blocks together.
    public var chip: Double { cpu + gpu + ane + dram }
    /// The larger of the SMC's whole-Mac figure and the chip's sum.
    public var total: Double { max(system, chip) }
}

/// Who moved bytes through the memory controller.
public struct MemoryTraffic: Sendable, Equatable {
    public var client: String
    /// Bytes per second, read plus write.
    public var bytes: Double
}

public enum MemoryPressure: String, Sendable {
    case normal, warning, critical
}

public struct MemoryState: Sendable, Equatable {
    public var total: UInt64 = 0
    /// What Activity Monitor calls "Memory Used": apps, wired, compressed.
    public var used: UInt64 = 0
    public var app: UInt64 = 0
    public var wired: UInt64 = 0
    public var compressed: UInt64 = 0
    /// Files kept in memory, given back on demand.
    public var cached: UInt64 = 0
    public var swapUsed: UInt64 = 0
    public var swapTotal: UInt64 = 0
    public var pressure: MemoryPressure = .normal

    public init() {}

    public var usedShare: Double { total == 0 ? 0 : Double(used) / Double(total) }
}

/// Bytes per second through the Mac's network interfaces.
public struct NetworkRate: Sendable, Equatable {
    public var bytesIn: Double = 0
    public var bytesOut: Double = 0
    /// The busiest interface this second (`en0`).
    public var interface: String?

    public init(bytesIn: Double = 0, bytesOut: Double = 0, interface: String? = nil) {
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.interface = interface
    }
}

/// The home volume's size and what's free (including purgeable space).
public struct DiskSpace: Sendable, Equatable {
    public var total: Int64
    public var available: Int64
    public var usedShare: Double { total > 0 ? min(max(1 - Double(available) / Double(total), 0), 1) : 0 }
}

/// 0 nominal … 3 critical (ProcessInfo.thermalState).
public enum ThermalLevel: Int, Sendable, Comparable {
    case nominal, fair, serious, critical
    public static func < (a: ThermalLevel, b: ThermalLevel) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .nominal: "Normal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        }
    }
}

/// One second of the machine.
public struct SystemSample: Sendable, Equatable {
    public var time: Date
    /// Average of every core, 0–100.
    public var cpu: Double
    public var cores: [CoreLoad]
    public var clusters: [ClusterLoad]
    /// GPU busy share, 0–100.
    public var gpu: Double
    public var gpuMHz: Int
    public var power: PowerDraw
    public var cpuTemp: Double
    public var gpuTemp: Double
    public var memory: MemoryState
    /// Disk bytes per second.
    public var diskRead: Double
    public var diskWrite: Double
    /// Memory bandwidth, bytes per second.
    public var memRead: Double
    public var memWrite: Double
    /// Who moved those bytes, busiest first.
    public var memTraffic: [MemoryTraffic]
    public var fanRPM: [Double]
    public var thermal: ThermalLevel
    public var network: NetworkRate
    /// Refreshed every minute; nil until first read.
    public var disk: DiskSpace?
    /// Charge and charging, nil on a Mac without a battery.
    public var battery: BatteryState?

    public init(time: Date = .now, cpu: Double = 0, cores: [CoreLoad] = [], clusters: [ClusterLoad] = [],
                gpu: Double = 0, gpuMHz: Int = 0, power: PowerDraw = .init(), cpuTemp: Double = 0,
                gpuTemp: Double = 0, memory: MemoryState = .init(), diskRead: Double = 0, diskWrite: Double = 0,
                memRead: Double = 0, memWrite: Double = 0, memTraffic: [MemoryTraffic] = [], fanRPM: [Double] = [],
                thermal: ThermalLevel = .nominal, network: NetworkRate = .init(), disk: DiskSpace? = nil,
                battery: BatteryState? = nil) {
        self.time = time
        self.cpu = cpu
        self.cores = cores
        self.clusters = clusters
        self.gpu = gpu
        self.gpuMHz = gpuMHz
        self.power = power
        self.cpuTemp = cpuTemp
        self.gpuTemp = gpuTemp
        self.memory = memory
        self.diskRead = diskRead
        self.diskWrite = diskWrite
        self.memRead = memRead
        self.memWrite = memWrite
        self.memTraffic = memTraffic
        self.fanRPM = fanRPM
        self.thermal = thermal
        self.network = network
        self.disk = disk
        self.battery = battery
    }

    public var memoryBandwidth: Double { memRead + memWrite }
}

/// A temperature sensor.
public struct Sensor: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case cpu, gpu, soc, memory, storage, battery, other
    }
    public var name: String
    public var kind: Kind
    public var celsius: Double
    public var id: String { name }

    public init(name: String, kind: Kind, celsius: Double) {
        self.name = name
        self.kind = kind
        self.celsius = celsius
    }
}

public struct Fan: Sendable, Equatable {
    public var rpm: Double
    public var min: Double
    public var max: Double

    public init(rpm: Double, min: Double, max: Double) {
        self.rpm = rpm
        self.min = min
        self.max = max
    }

    /// How far between its slowest and fastest, 0–1.
    public var share: Double { max > min ? Swift.min(Swift.max((rpm - min) / (max - min), 0), 1) : 0 }
}

public struct BatteryState: Sendable, Equatable {
    public var percent: Double
    public var charging: Bool
    public var plugged: Bool
    /// Positive while charging, negative while draining.
    public var watts: Double
    public var celsius: Double
    public var cycles: Int
    /// Full charge now against when new, 0–100 (0 when unknown).
    public var health: Double
    /// Minutes to empty or full; nil while macOS is still estimating.
    public var minutes: Int?

    public init(percent: Double, charging: Bool, plugged: Bool, watts: Double, celsius: Double, cycles: Int,
                health: Double, minutes: Int?) {
        self.percent = percent
        self.charging = charging
        self.plugged = plugged
        self.watts = watts
        self.celsius = celsius
        self.cycles = cycles
        self.health = health
        self.minutes = minutes
    }
}

/// What changes slowly: every sensor, fan limits, the battery's detail.
public struct SystemDetail: Sendable, Equatable {
    public var sensors: [Sensor] = []
    public var fans: [Fan] = []
    public var battery: BatteryState?

    public init(sensors: [Sensor] = [], fans: [Fan] = [], battery: BatteryState? = nil) {
        self.sensors = sensors
        self.fans = fans
        self.battery = battery
    }

    public var isEmpty: Bool { sensors.isEmpty && fans.isEmpty && battery == nil }
}

/// One tick of the monitor: always a sample; the detail every few ticks.
public struct SystemUpdate: Sendable {
    public var sample: SystemSample
    public var detail: SystemDetail?
}
