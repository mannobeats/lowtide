import Foundation
import Testing
@testable import LowtideKit

@Suite struct SystemMathTests {
    @Test func residencyWeightsClocksByTime() {
        // An M-series P cluster: idle half the time, the rest split between
        // two voltage steps.
        let states: [(name: String, time: Int64)] = [("IDLE", 500), ("V0P5", 0), ("V2P3", 250), ("V5P1", 250)]
        let table = [600, 912, 1284, 1752, 2004, 3228]
        let (active, mhz) = IOReportMath.residency(states, table: table, byVoltage: true)
        #expect(active == 50)
        #expect(mhz == (1284 + 3228) / 2)
        // GPU states are in table order, whatever their names.
        let gpu: [(name: String, time: Int64)] = [("OFF", 900), ("P1", 50), ("P2", 50)]
        let (g, gmhz) = IOReportMath.residency(gpu, table: [389, 486, 648], byVoltage: false)
        #expect(abs(g - 10) < 0.0001)
        #expect(gmhz == (389 + 486) / 2)
        #expect(IOReportMath.residency([], table: table, byVoltage: true) == (0, 0))
        #expect(IOReportMath.residency([("IDLE", 100)], table: table, byVoltage: true) == (0, 0))
    }

    @Test func energyUnitsBecomeWatts() {
        #expect(IOReportMath.watts(5_000, unit: "mJ", seconds: 1) == 5)
        #expect(IOReportMath.watts(2_000_000, unit: "uJ", seconds: 2) == 1)
        #expect(IOReportMath.watts(3_000_000_000, unit: "nJ ", seconds: 1) == 3)
    }

    @Test func energyChannelsSumByBlock() {
        var totals = EnergyTotals()
        // M1-style: per-cluster channels only.
        totals.add(name: "ECPU0_CPU", watts: 0.2)
        totals.add(name: "PCPU0_CPU", watts: 1.5)
        totals.add(name: "GPU Energy", watts: 0.4)
        totals.add(name: "ANE0", watts: 0.1)
        totals.add(name: "DRAM0", watts: 0.3)
        #expect(abs(totals.power.cpu - 1.7) < 1e-9)
        // A chip total wins over the clusters.
        totals.add(name: "CPU Energy", watts: 2.0)
        #expect(totals.power.cpu == 2.0)
        #expect(totals.power.gpu == 0.4 && totals.power.ane == 0.1 && totals.power.dram == 0.3)
        #expect(abs(totals.power.total - 2.8) < 1e-9)
    }

    @Test func memoryTrafficGoesToItsClient() {
        var out = PowerSampler.Reading()
        IOReportMath.addTraffic(name: "DCS RD", rate: 4e9, to: &out)
        IOReportMath.addTraffic(name: "DCS WR", rate: 1e9, to: &out)
        IOReportMath.addTraffic(name: "PCPU0 DCS RD", rate: 2e9, to: &out)
        IOReportMath.addTraffic(name: "ECPU DCS WR", rate: 1e9, to: &out)
        IOReportMath.addTraffic(name: "GFX DCS RD", rate: 5e8, to: &out)
        IOReportMath.addTraffic(name: "AVD0 DCS RD", rate: 1e8, to: &out)
        IOReportMath.addTraffic(name: "SOMETHING", rate: 9e9, to: &out)
        #expect(out.memRead == 4e9 && out.memWrite == 1e9)
        #expect(out.traffic.first { $0.client == "CPU" }?.bytes == 3e9)
        #expect(out.traffic.first { $0.client == "GPU" }?.bytes == 5e8)
        #expect(out.traffic.first { $0.client == "Media" }?.bytes == 1e8)
        #expect(IOReportMath.client("DISP0") == "Display" && IOReportMath.client("ANS2") == "SSD")
        #expect(IOReportMath.client("PCIe") == "I/O")
    }

    @Test func frequencyTablesReadHzAndKHz() {
        func entry(_ value: UInt32) -> [UInt8] {
            withUnsafeBytes(of: value.littleEndian, Array.init) + [0, 0, 0, 0]
        }
        // M1–M4 store Hz; M5 stores kHz; zero rows are skipped.
        let hz = Data(entry(600_000_000) + entry(0) + entry(3_228_000_000))
        #expect(IOReportMath.frequencyTable(hz) == [600, 3228])
        let khz = Data(entry(1_260_000) + entry(4_608_000))
        #expect(IOReportMath.frequencyTable(khz) == [1260, 4608])
        #expect(IOReportMath.frequencyTable(Data([1, 2, 3])) == [])
    }

    @Test func coreUsageFromTicks() {
        let before: [(busy: UInt64, total: UInt64)] = [(100, 1000), (50, 1000), (10, 10)]
        let now: [(busy: UInt64, total: UInt64)] = [(150, 1100), (50, 1200), (10, 10)]
        let usage = Host.usage(from: before, to: now)
        #expect(usage == [50, 0, 0])
    }

    @Test func memoryMatchesActivityMonitor() {
        var stats = vm_statistics64()
        stats.internal_page_count = 500_000
        stats.purgeable_count = 20_000
        stats.wire_count = 150_000
        stats.compressor_page_count = 50_000
        stats.external_page_count = 300_000
        var state = MemoryState()
        Host.apply(stats, page: 16384, to: &state)
        #expect(state.app == 480_000 * 16384)
        #expect(state.used == (480_000 + 150_000 + 50_000) * 16384)
        #expect(state.cached == 320_000 * 16384)
        #expect(Host.pressure(4) == .critical && Host.pressure(2) == .warning && Host.pressure(1) == .normal)
    }
}

@Suite struct SystemSensorTests {
    @Test func smcKeysName() {
        #expect(SensorNames.smc("Tp09") == (.cpu, "Performance core"))
        #expect(SensorNames.smc("Te05") == (.cpu, "Efficiency core"))
        #expect(SensorNames.smc("TCMz") == (.cpu, "CPU die"))
        #expect(SensorNames.smc("Tg0f") == (.gpu, "GPU"))
        #expect(SensorNames.smc("TPD0") == (.soc, "SoC package"))
        #expect(SensorNames.smc("TH0x") == (.storage, "SSD"))
        #expect(SensorNames.smc("TB0T") == (.battery, "Battery"))
        #expect(SensorNames.smc("Tb0P") == (.other, "Board"))
        #expect(SensorNames.smc("Tm0P") == (.memory, "Memory"))
        #expect(SensorNames.smc("TW0P") == (.other, "Wireless"))
        #expect(SensorNames.smc("T") == (.other, "Sensor"))
    }

    @Test func hidSensorsName() {
        #expect(SensorNames.hidName("pACC MTR Temp Sensor3") == "Performance cores 3")
        #expect(SensorNames.hidName("eACC MTR Temp Sensor0") == "Efficiency cores 0")
        #expect(SensorNames.hidName("GPU MTR Temp Sensor1") == "GPU 1")
        #expect(SensorNames.hidName("NAND CH0 temp") == "SSD")
        #expect(SensorNames.hidName("gas gauge battery") == "Battery")
        #expect(SensorNames.hidName("PMU tdie5") == "SoC die 5")
        #expect(SensorNames.hidName("PMU TP3w") == "PMU TP3w")
        #expect(SensorNames.hidKind("pACC MTR Temp Sensor3") == .cpu)
        #expect(SensorNames.hidKind("PMU tdie5") == .soc)
        #expect(SensorNames.hidKind("gas gauge battery") == .battery)
        #expect(SensorNames.hidKind("NAND CH0 temp") == .storage)
    }

    @Test func smcValuesDecode() {
        let flt = withUnsafeBytes(of: Float(41.5).bitPattern.littleEndian, Array.init) + [UInt8](repeating: 0, count: 28)
        #expect(SMC.decode(flt, size: 4, type: SMC.fourCC("flt ")) == 41.5)
        #expect(SMC.decode([0x09, 0x60] + [UInt8](repeating: 0, count: 30), size: 2, type: SMC.fourCC("ui16")) == 2400)
        #expect(SMC.decode([3] + [UInt8](repeating: 0, count: 31), size: 1, type: SMC.fourCC("ui8 ")) == 3)
        #expect(SMC.decode([0, 0, 1, 0] + [UInt8](repeating: 0, count: 28), size: 4, type: SMC.fourCC("ui32")) == 256)
        #expect(SMC.decode([UInt8](repeating: 0, count: 32), size: 2, type: SMC.fourCC("fp88")) == nil)
        #expect(SMC.fourCC("#KEY") == 0x234b_4559)
    }

    @Test func batteryFromRegistry() {
        // Real AppleSmartBattery values (a MacBook Pro on battery).
        let props: [String: Any] = [
            "CurrentCapacity": 81, "MaxCapacity": 100, "AppleRawMaxCapacity": 6075, "DesignCapacity": 6249,
            "Voltage": 12_408, "InstantAmperage": NSNumber(value: UInt64(18_446_744_073_709_550_872)),
            "IsCharging": false, "ExternalConnected": false, "Temperature": 3061, "CycleCount": 212,
            "AvgTimeToEmpty": 312, "AvgTimeToFull": 65535,
        ]
        let b = Battery.parse(props)!
        #expect(b.percent == 81)
        #expect(!b.charging && !b.plugged)
        #expect(abs(b.watts - (12.408 * -0.744)) < 0.001)
        #expect(abs(b.celsius - 30.61) < 0.001)
        #expect(b.cycles == 212)
        #expect(abs(b.health - 97.2) < 0.1)
        #expect(b.minutes == 312)
        // Charging: the time to empty is ignored, an absurd time to full too.
        var charging = props
        charging["IsCharging"] = true
        #expect(Battery.parse(charging)?.minutes == nil)
        #expect(Battery.parse(["MaxCapacity": 100]) == nil)
    }

    @Test func fansShareTheirRange() {
        #expect(Fan(rpm: 2500, min: 1000, max: 4000).share == 0.5)
        #expect(Fan(rpm: 0, min: 1000, max: 4000).share == 0)
        #expect(Fan(rpm: 1200, min: 0, max: 0).share == 0)
    }
}

@Suite struct SystemNetworkTests {
    @Test func ratesSkipTunnelsAndResets() {
        let before = [Counters.Interface(name: "en0", bytesIn: 1_000, bytesOut: 500),
                      Counters.Interface(name: "utun3", bytesIn: 0, bytesOut: 0),
                      Counters.Interface(name: "lo0", bytesIn: 0, bytesOut: 0),
                      Counters.Interface(name: "en5", bytesIn: 9_000, bytesOut: 9_000)]
        let now = [Counters.Interface(name: "en0", bytesIn: 3_000, bytesOut: 1_500),
                   Counters.Interface(name: "utun3", bytesIn: 50_000, bytesOut: 50_000),
                   Counters.Interface(name: "lo0", bytesIn: 80_000, bytesOut: 80_000),
                   // Came back after a replug: counters restarted.
                   Counters.Interface(name: "en5", bytesIn: 100, bytesOut: 0),
                   Counters.Interface(name: "en7", bytesIn: 4, bytesOut: 4)]
        let rate = Counters.rate(from: before, to: now, seconds: 2)
        #expect(rate.bytesIn == 1_000 && rate.bytesOut == 500)
        #expect(rate.interface == "en0")
        #expect(Counters.rate(from: before, to: now, seconds: 0) == NetworkRate())
    }

    @Test func diskShareIsClamped() {
        #expect(DiskSpace(total: 1000, available: 250).usedShare == 0.75)
        #expect(DiskSpace(total: 0, available: 0).usedShare == 0)
    }
}

@Suite struct SystemProcessTests {
    @Test func findsTheOuterApp() {
        #expect(ProcessKind.appBundle("/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper")
            == "/Applications/Claude.app")
        #expect(ProcessKind.appBundle("/usr/sbin/cfprefsd") == nil)
        #expect(ProcessKind.appBundle("/Applications/Safari.app") == "/Applications/Safari.app")
    }

    @Test func versionedInstallsTakeTheirFolderName() {
        #expect(ProcessKind.displayName("2.1.325", path: "/Users/me/.local/share/claude/versions/2.1.325") == "claude")
        #expect(ProcessKind.displayName("1.2", path: "/opt/tool/1.2/bin/1.2") == "tool")
        #expect(ProcessKind.displayName("node", path: "/opt/homebrew/bin/node") == "node")
        #expect(ProcessKind.displayName("2.1.325", path: nil) == "2.1.325")
    }

    @Test func kindsFromPaths() {
        #expect(ProcessKind.of(app: "/Applications/Xcode.app", path: "/Applications/Xcode.app/Contents/MacOS/Xcode") == "App")
        #expect(ProcessKind.of(app: "/Applications/Slack.app",
                               path: "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper")
            == "Part of an app")
        #expect(ProcessKind.of(app: nil, path: "/usr/libexec/trustd") == "macOS service")
        #expect(ProcessKind.of(app: nil, path: "/opt/homebrew/bin/node") == "Command-line tool")
        #expect(ProcessKind.of(app: nil, path: nil) == "Command-line tool")
    }

    @Test func procArgsParse() {
        // argc 3, exec path, NUL padding, argv, then the environment.
        var buffer = withUnsafeBytes(of: UInt32(3).littleEndian, Array.init)
        buffer += Array("/opt/homebrew/bin/node".utf8) + [0, 0, 0, 0]
        buffer += Array("node".utf8) + [0] + Array("server.js".utf8) + [0] + Array("--port=3000".utf8) + [0]
        buffer += Array("PATH=/usr/bin".utf8) + [0, 0]
        #expect(ProcTable.parseProcargs(buffer)?.args == ["node", "server.js", "--port=3000"])
        #expect(ProcTable.parseProcargs([0, 0])?.args == nil)
        #expect(ProcTable.parseProcargs(withUnsafeBytes(of: UInt32(0).littleEndian, Array.init) + [0x2f, 0])?.args == nil)
    }

    @Test func gpuClientsNameTheirPid() {
        #expect(ProcessTable.gpuClientPID("pid 812, WindowServer") == 812)
        #expect(ProcessTable.gpuClientPID("pid 4, kernel_task") == 4)
        #expect(ProcessTable.gpuClientPID("WindowServer") == nil)
    }

    @Test func powerIsSharedByLoad() {
        var rows = [ProcessRow(pid: 1, ppid: 0, name: "a", path: nil, app: nil, cpu: 100, memory: 0, watts: 0,
                               diskRate: 0, gpu: 50, userOwned: true),
                    ProcessRow(pid: 2, ppid: 0, name: "b", path: nil, app: nil, cpu: 100, memory: 0, watts: 0,
                               diskRate: 0, gpu: 0, userOwned: true)]
        // The machine was busier than the rows we could read: 400% CPU.
        ProcessSampler.sharePower(&rows, cpuWatts: 8, gpuWatts: 4, load: (400, 50))
        #expect(rows[0].watts == 2 + 4)
        #expect(rows[1].watts == 2)
        ProcessSampler.sharePower(&rows, cpuWatts: 0, gpuWatts: 0, load: (0, 0))
        #expect(rows.allSatisfy { $0.watts == 0 })
    }

    @Test func treeEndsChildrenFirst() {
        let table: [(pid: Int32, ppid: Int32)] = [(10, 1), (11, 10), (12, 10), (13, 11), (20, 1)]
        let order = ProcessControl.treeOrder(10, table: table)
        #expect(order.last == 10)
        #expect(order.firstIndex(of: 13)! < order.firstIndex(of: 11)!)
        #expect(Set(order) == [10, 11, 12, 13])
    }

    @Test func refusesToEndProtectedPids() async {
        await #expect(throws: LowtideError.self) { try await ProcessControl.end(1, mode: .quit) }
        await #expect(throws: LowtideError.self) { try await ProcessControl.end(0, mode: .forceQuit) }
    }
}

@Suite struct SystemFormatTests {
    @Test func formats() {
        #expect(SystemFormat.memory(17_179_869_184) == "16 GB")
        #expect(SystemFormat.memory(6_764_573_491) == "6.3 GB")
        #expect(SystemFormat.memory(512) == "512 B")
        #expect(SystemFormat.clock(3228) == "3.23 GHz")
        #expect(SystemFormat.clock(912) == "912 MHz")
        #expect(SystemFormat.watts(12.44) == "12.4 W")
        #expect(SystemFormat.watts(0.421) == "0.42 W")
        #expect(SystemFormat.rate(1_240_000) == "1.2 MB/s")
        #expect(SystemFormat.amount(340_400) == "340 KB")
        #expect(SystemFormat.celsius(0) == "–" && SystemFormat.celsius(64.4) == "64°C")
        #expect(SystemFormat.minutes(134) == "2 h 14 min")
        #expect(SystemFormat.cpuTime(4.24) == "4.2 s")
        #expect(SystemFormat.cpuTime(723) == "12 min 3 s")
        #expect(SystemFormat.cpuTime(11_520) == "3 h 12 min")
        let now = Date()
        #expect(SystemFormat.running(since: now.addingTimeInterval(-14 * 60), now: now) == "14 min")
        #expect(SystemFormat.running(since: now.addingTimeInterval(-(3 * 3600 + 120)), now: now) == "3 h 2 min")
        #expect(SystemFormat.running(since: now.addingTimeInterval(-5 * 86_400), now: now) == "5 days")
    }

    @Test func peakBandwidthByChip() {
        #expect(SystemFormat.peakBandwidth("Apple M3 Max") == 400)
        #expect(SystemFormat.peakBandwidth("Apple M4 Pro") == 273)
        #expect(SystemFormat.peakBandwidth("Apple M4") == 120)
        #expect(SystemFormat.peakBandwidth("Apple M1") == 68)
        #expect(SystemFormat.peakBandwidth("Intel Core i9") == nil)
    }

    @Test func moodFollowsHeat() {
        #expect(SystemFormat.mood(thermal: .nominal, cpuTemp: 50) == "Running cool")
        #expect(SystemFormat.mood(thermal: .nominal, cpuTemp: 88) == "Running warm")
        #expect(SystemFormat.mood(thermal: .fair, cpuTemp: 50) == "Running warm")
        #expect(SystemFormat.mood(thermal: .critical, cpuTemp: 50) == "Running hot")
    }
}

/// Reads this Mac. Loose checks: every Mac has memory and cores.
@Suite struct SystemLiveTests {
    @Test func monitorReadsThisMac() async throws {
        let monitor = SystemMonitor()
        await monitor.prime()
        try await Task.sleep(for: .milliseconds(400))
        let update = await monitor.step()
        let s = update.sample
        let chip = await monitor.chip()
        #expect(chip.cores > 0)
        #expect(s.memory.total > 0 && s.memory.used > 0 && s.memory.used <= s.memory.total)
        #expect(s.cores.count == chip.cores)
        #expect((0...100).contains(s.cpu))
        #expect(update.detail != nil)
        _ = await monitor.processList()
        try await Task.sleep(for: .milliseconds(300))
        let processes = await monitor.processList()
        #expect(processes.contains { $0.pid == getpid() })
        let detail = await ProcessTable.detail(getpid())
        #expect(detail?.pid == getpid())
        #expect((detail?.cpuSeconds ?? 0) > 0)
        print("""
        chip \(chip.name) \(chip.performance)P+\(chip.efficiency)E gpu \(chip.gpuCores)
        cpu \(Int(s.cpu))% clusters \(s.clusters.map { "\($0.name) \(Int($0.active))% \($0.mhz)" })
        gpu \(Int(s.gpu))% \(s.gpuMHz) MHz · power cpu \(s.power.cpu) gpu \(s.power.gpu) ane \(s.power.ane) dram \(s.power.dram) sys \(s.power.system)
        temps cpu \(s.cpuTemp) gpu \(s.gpuTemp) · sensors \(update.detail?.sensors.count ?? 0) fans \(s.fanRPM)
        mem \(SystemFormat.memory(s.memory.used)) of \(SystemFormat.memory(s.memory.total)) bw \(s.memRead + s.memWrite) traffic \(s.memTraffic.map(\.client))
        net \(s.network) disk \(String(describing: s.disk)) battery \(String(describing: update.detail?.battery))
        processes \(processes.count) top \(processes.sorted { $0.cpu > $1.cpu }.prefix(3).map { "\($0.name) \($0.cpu)" })
        """)
    }
}
