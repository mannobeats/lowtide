import Foundation

/// The system monitor: Apple silicon power, clocks, temperatures, fans,
/// memory, disks, network and processes, read natively without root.
/// Someone drives it once a second (`step`) while something on screen needs
/// it; between runs it holds nothing open but its IOKit connections.
public actor SystemMonitor {
    public static let shared = SystemMonitor()

    private var power: PowerSampler?
    private var smc: SMC?
    private var hid: HIDThermals?
    private var opened = false
    private var temperatureKeys: [String] = []
    private var ticks: [(busy: UInt64, total: UInt64)] = []
    private var disk: (read: UInt64, written: UInt64) = (0, 0)
    private var interfaces: [Counters.Interface] = []
    private var at: ContinuousClock.Instant?
    private var tick = 0
    private var diskSpace: DiskSpace?
    private var diskSpaceAt: ContinuousClock.Instant?
    private var detail = SystemDetail()
    private var latest: SystemSample?
    private let processes = ProcessSampler()
    private var chipInfo: ChipInfo?
    /// Set once CPU energy reads above zero: until then it isn't reported.
    private var cpuEnergySeen = false
    private var dramEnergySeen = false

    public init() {}

    /// The chip, read once.
    public func chip() -> ChipInfo {
        if let chipInfo { return chipInfo }
        let chip = Host.chip()
        chipInfo = chip
        return chip
    }

    /// Opens the counters and takes the first reading, so the next `step`
    /// has an interval to measure. Call when sampling (re)starts.
    public func prime() {
        if !opened {
            opened = true
            power = PowerSampler()
            smc = SMC()
            hid = HIDThermals()
            temperatureKeys = smc?.temperatureKeys() ?? []
            Log.system.info("monitor: IOReport \(self.power != nil), SMC \(self.smc != nil) with \(self.temperatureKeys.count) temperature keys")
        }
        power?.reset()
        _ = power?.sample()
        processes.reset()
        ticks = Host.coreTicks()
        disk = Counters.diskBytes()
        interfaces = Counters.interfaces()
        at = .now
        tick = 0
    }

    /// One reading since the last. The detail (every sensor, fans, battery)
    /// comes every third call.
    public func step() -> SystemUpdate {
        if at == nil { prime() }
        let now = ContinuousClock.now
        let seconds = max((now - (at ?? now)).seconds, 0.05)
        at = now
        let chip = chip()
        let reading = power?.sample() ?? PowerSampler.Reading()

        let newTicks = Host.coreTicks()
        let usage = Host.usage(from: ticks, to: newTicks)
        ticks = newTicks
        // Logical CPUs and IOReport's core channels share an order:
        // efficiency cores first.
        let cores = usage.enumerated().map { i, u in
            CoreLoad(kind: i < chip.efficiency ? .efficiency : .performance, usage: u,
                     mhz: reading.cores.indices.contains(i) ? reading.cores[i].mhz : 0)
        }

        // The SMC has every sensor; the HID hub is the fallback.
        var sensors = smc?.temperatures(temperatureKeys) ?? []
        if sensors.isEmpty { sensors = hid?.read() ?? [] }
        let fans = smc?.fans() ?? []

        let newDisk = Counters.diskBytes()
        let diskRead = Double(newDisk.read >= disk.read ? newDisk.read - disk.read : 0) / seconds
        let diskWrite = Double(newDisk.written >= disk.written ? newDisk.written - disk.written : 0) / seconds
        disk = newDisk

        let newInterfaces = Counters.interfaces()
        let network = Counters.rate(from: interfaces, to: newInterfaces, seconds: seconds)
        interfaces = newInterfaces

        // Free space counts purgeable files, which is slow: once a minute.
        if diskSpaceAt.map({ (now - $0).seconds > 60 }) ?? true {
            diskSpace = Counters.diskSpace()
            diskSpaceAt = now
        }

        tick += 1
        var newDetail: SystemDetail?
        if tick % 3 == 1 {
            var battery = Battery.read()
            // Newer macOS hides the pack's temperature; the SMC still has it.
            if var b = battery, b.celsius <= 0 {
                b.celsius = Self.average(sensors.filter { $0.kind == .battery }.map(\.celsius))
                battery = b
            }
            detail = SystemDetail(sensors: sensors, fans: fans, battery: battery)
            newDetail = detail
        }

        var power = reading.power
        power.system = smc?.systemPower() ?? 0
        if power.cpu > 0 { cpuEnergySeen = true }
        power.cpuReported = cpuEnergySeen
        if power.dram > 0 { dramEnergySeen = true }
        power.dramReported = dramEnergySeen
        let sample = SystemSample(
            time: .now,
            cpu: usage.isEmpty ? 0 : usage.reduce(0, +) / Double(usage.count),
            cores: cores,
            // ECPM/PCPM are the clusters' memory complexes, not cores.
            clusters: reading.clusters.filter { !$0.name.contains("CPM") },
            gpu: reading.gpuActive, gpuMHz: reading.gpuMHz, power: power,
            cpuTemp: Self.average(sensors.filter { $0.kind == .cpu }.map(\.celsius)),
            gpuTemp: Self.average(sensors.filter { $0.kind == .gpu }.map(\.celsius)),
            memory: Host.memory(), diskRead: diskRead, diskWrite: diskWrite,
            memRead: reading.memRead, memWrite: reading.memWrite, memTraffic: reading.traffic,
            fanRPM: fans.map(\.rpm), thermal: Host.thermal(), network: network, disk: diskSpace,
            battery: detail.battery)
        latest = sample
        return SystemUpdate(sample: sample, detail: newDetail)
    }

    /// Every readable process, with rates since the previous call and its
    /// share of the power the latest sample saw.
    public func processList() -> [ProcessRow] {
        let s = latest
        return processes.list(cpuWatts: s?.power.cpu ?? 0, gpuWatts: s?.power.gpu ?? 0,
                              load: ((s?.cpu ?? 0) * Double(s?.cores.count ?? 0), s?.gpu ?? 0))
    }

    /// Starts the next process list's interval afresh (after a pause).
    public func resetProcesses() { processes.reset() }

    static func average(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }
}
