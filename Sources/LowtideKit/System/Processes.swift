import Darwin
import Foundation
import IOKit
import Security

/// One process this second.
public struct ProcessRow: Sendable, Identifiable, Equatable {
    public var pid: Int32
    public var ppid: Int32
    public var name: String
    public var path: String?
    /// The app bundle it belongs to (the outermost `.app`), for its icon.
    public var app: String?
    /// Percent of one core (100 = one core fully busy).
    public var cpu: Double
    /// Real memory (the footprint Activity Monitor shows).
    public var memory: UInt64
    /// Its share of the CPU and GPU power being drawn, watts.
    public var watts: Double
    /// Bytes per second read and written.
    public var diskRate: Double
    /// Share of the GPU's time, 0–100.
    public var gpu: Double
    public var userOwned: Bool

    public var id: Int32 { pid }

    public init(pid: Int32, ppid: Int32, name: String, path: String?, app: String?, cpu: Double, memory: UInt64,
                watts: Double, diskRate: Double, gpu: Double, userOwned: Bool) {
        self.pid = pid
        self.ppid = ppid
        self.name = name
        self.path = path
        self.app = app
        self.cpu = cpu
        self.memory = memory
        self.watts = watts
        self.diskRate = diskRate
        self.gpu = gpu
        self.userOwned = userOwned
    }

    /// What kind of process, from where it lives.
    public var kind: String { ProcessKind.of(app: app, path: path) }
}

public enum ProcessKind {
    public static func of(app: String?, path: String?) -> String {
        if app != nil {
            return (path?.contains(".app/Contents/MacOS/") ?? false) && !(path?.contains("Helper") ?? false)
                ? "App" : "Part of an app"
        }
        if let path, path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec") { return "macOS service" }
        return "Command-line tool"
    }

    /// A readable name: a versioned install (`~/.local/share/claude/versions/2.1.325`)
    /// is named after the folder it belongs to, not its version.
    public static func displayName(_ name: String, path: String?) -> String {
        guard name.first?.isNumber == true, let path else { return name }
        let skip: Set<String> = ["versions", "bin", "libexec", "current"]
        let parts = path.split(separator: "/").dropLast().reversed()
        return parts.first { part in !skip.contains(String(part)) && part.first?.isNumber == false }.map(String.init) ?? name
    }

    /// `/Applications/Claude.app/Contents/Frameworks/…/Helper` → the Claude app.
    public static func appBundle(_ path: String) -> String? {
        if let range = path.range(of: ".app/") { return String(path[..<range.lowerBound]) + ".app" }
        return path.hasSuffix(".app") ? path : nil
    }
}

/// A connected internet socket's far end.
public struct ProcessPeer: Sendable, Hashable {
    public var ip: String
    public var port: UInt16
}

/// Everything worth knowing about one process.
public struct ProcessDetail: Sendable, Equatable {
    public var pid: Int32
    public var name: String
    public var path: String?
    public var app: String?
    public var command: String?
    public var cwd: String?
    public var user: String
    public var started: Date
    public var parent: (pid: Int32, name: String)?
    public var children: [(pid: Int32, name: String)]
    public var threads: Int?
    /// Total CPU time since it started, seconds.
    public var cpuSeconds: Double
    public var memory: UInt64
    public var peakMemory: UInt64
    public var diskRead: UInt64
    public var diskWritten: UInt64
    /// Instructions per cycle over its life: how efficiently it runs.
    public var ipc: Double?
    public var gpuSeconds: Double
    public var connections: [ProcessPeer]
    /// The developer team that signed it, when readable.
    public var team: String?
    public var apple: Bool

    public static func == (a: ProcessDetail, b: ProcessDetail) -> Bool {
        a.pid == b.pid && a.cpuSeconds == b.cpuSeconds && a.memory == b.memory && a.children.map(\.pid) == b.children.map(\.pid)
            && a.connections == b.connections && a.threads == b.threads && a.team == b.team
    }
}

/// The process table, straight from the kernel (`libproc`, no child processes).
public enum ProcessTable {
    struct Info {
        var pid: Int32
        var ppid: Int32
        var uid: uid_t
        var name: String
        var started: Date
    }

    static func info(_ pid: Int32) -> Info? {
        ProcTable.entry(pid).map {
            Info(pid: $0.pid, ppid: $0.ppid, uid: $0.uid, name: $0.name, started: Date(timeIntervalSince1970: Double($0.started) / 1000))
        }
    }

    /// The far ends of a process's connected internet sockets (only this
    /// user's processes).
    static func peers(_ pid: Int32) -> [ProcessPeer] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let count = Int(bytes) / MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let written = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bytes)
        guard written > 0 else { return [] }
        var seen = Set<ProcessPeer>()
        var out: [ProcessPeer] = []
        for fd in fds.prefix(Int(written) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.stride)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  let peer = peer(info), seen.insert(peer).inserted else { continue }
            out.append(peer)
        }
        return out
    }

    static func peer(_ info: socket_fdinfo) -> ProcessPeer? {
        let kind = info.psi.soi_kind
        guard kind == SOCKINFO_IN || kind == SOCKINFO_TCP else { return nil }
        let sock = info.psi.soi_proto.pri_in
        let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: sock.insi_fport))
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        var address = sock.insi_faddr
        switch Int32(sock.insi_vflag) {
        case INI_IPV4:
            var v4 = address.ina_46.i46a_addr4
            guard v4.s_addr != 0 else { return nil }
            inet_ntop(AF_INET, &v4, &text, socklen_t(text.count))
        case INI_IPV6:
            guard withUnsafeBytes(of: &address.ina_6, { $0.contains { $0 != 0 } }) else { return nil }
            inet_ntop(AF_INET6, &address.ina_6, &text, socklen_t(text.count))
        default:
            return nil
        }
        guard port != 0 else { return nil }
        return ProcessPeer(ip: String(cBuffer: text), port: port)
    }

    static func userName(_ uid: uid_t) -> String {
        guard let record = getpwuid(uid), let name = record.pointee.pw_name else { return String(uid) }
        return String(cString: name)
    }

    /// The developer team that signed a file or bundle, read from its
    /// signature without running `codesign`.
    static func team(_ path: String) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code
        else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// GPU time per pid (nanoseconds), summed over the pid's GPU clients.
    static func gpuTime() -> [Int32: UInt64] {
        var out: [Int32: UInt64] = [:]
        IORegistry.withServices("IOAccelerator") { accelerators in
            for accelerator in accelerators {
                let children = IORegistry.children(accelerator)
                defer { IORegistry.release(children) }
                for child in children {
                    guard let creator = IORegistry.property(child, "IOUserClientCreator") as? String,
                          let pid = gpuClientPID(creator),
                          let uses = IORegistry.property(child, "AppUsage") as? [[String: Any]] else { continue }
                    let used = uses.reduce(UInt64(0)) { $0 + UInt64(max(($1["accumulatedGPUTime"] as? NSNumber)?.int64Value ?? 0, 0)) }
                    out[pid, default: 0] += used
                }
            }
        }
        return out
    }

    /// `pid 812, WindowServer` → 812.
    static func gpuClientPID(_ creator: String) -> Int32? {
        guard creator.hasPrefix("pid ") else { return nil }
        return Int32(creator.dropFirst(4).prefix { $0.isNumber })
    }

    /// Everything about one process; nil once it's gone.
    @concurrent
    public static func detail(_ pid: Int32) async -> ProcessDetail? {
        guard let info = info(pid) else { return nil }
        var usage = rusage_info_v4()
        let hasUsage = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        } == 0
        var task = proc_taskinfo()
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.stride)
        let threads = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize ? Int(task.pti_threadnum) : nil
        let table = ProcTable.pids().compactMap(Self.info)
        let path = ProcTable.path(pid)
        let app = path.flatMap(ProcessKind.appBundle)
        let parentName: String? = info.ppid > 0
            ? table.first { $0.pid == info.ppid }?.name ?? (info.ppid == 1 ? "launchd" : "pid \(info.ppid)") : nil
        let signed = app ?? path
        let team = signed.flatMap(Self.team)
        let apple = team == nil && (signed.map(isSystemPath) ?? false)
        let args = ProcTable.arguments(pid)
        return ProcessDetail(
            pid: pid, name: ProcessKind.displayName(info.name, path: path), path: path, app: app, command: args?.joined(separator: " "), cwd: ProcTable.cwd(pid),
            user: userName(info.uid), started: info.started,
            parent: parentName.map { (info.ppid, $0) },
            children: table.filter { $0.ppid == pid }.map { ($0.pid, $0.name) },
            threads: threads,
            cpuSeconds: hasUsage ? Double(usage.ri_user_time + usage.ri_system_time) * timebase / 1e9 : 0,
            memory: hasUsage ? usage.ri_phys_footprint : 0,
            peakMemory: hasUsage ? usage.ri_lifetime_max_phys_footprint : 0,
            diskRead: hasUsage ? usage.ri_diskio_bytesread : 0,
            diskWritten: hasUsage ? usage.ri_diskio_byteswritten : 0,
            ipc: hasUsage && usage.ri_cycles > 0 ? Double(usage.ri_instructions) / Double(usage.ri_cycles) : nil,
            gpuSeconds: Double(gpuTime()[pid] ?? 0) / 1e9,
            connections: peers(pid), team: team, apple: apple)
    }

    static func isSystemPath(_ path: String) -> Bool {
        path.hasPrefix("/System/") || (path.hasPrefix("/usr/") && !path.hasPrefix("/usr/local/"))
            || path.hasPrefix("/sbin/") || path.hasPrefix("/bin/")
    }

    /// Nanoseconds per Mach time unit (1 on Intel, 125/3 on Apple silicon).
    static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info.denom == 0 ? 1 : Double(info.numer) / Double(info.denom)
    }()
}

/// Rates per process between calls. Owned by the system monitor.
final class ProcessSampler {
    private struct Counters {
        var cpuNS: Double
        var disk: UInt64
        var gpuNS: UInt64
    }

    private var previous: (at: ContinuousClock.Instant, counters: [Int32: Counters])?
    private let me = getuid()
    /// A process's path never changes; reading it is the costliest call.
    /// Keyed by pid and start time, so a reused pid reads afresh.
    private var paths: [Int32: (started: Date, path: String?)] = [:]

    func reset() { previous = nil }

    /// Every process this user can read. `cpuWatts`/`gpuWatts` and `load`
    /// (the machine's CPU as percent of one core summed over cores, and GPU
    /// percent) share the power out by true share, even when some processes
    /// can't be read.
    func list(cpuWatts: Double, gpuWatts: Double, load: (cpu: Double, gpu: Double)) -> [ProcessRow] {
        let now = ContinuousClock.now
        let gpu = ProcessTable.gpuTime()
        let seconds = previous.map { (now - $0.at).seconds } ?? 0
        var counters: [Int32: Counters] = [:]
        var rows: [ProcessRow] = []
        var livePaths: [Int32: (started: Date, path: String?)] = [:]
        for pid in ProcTable.pids() {
            guard let info = ProcessTable.info(pid) else { continue }
            var usage = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            } == 0
            guard ok else { continue }
            let c = Counters(cpuNS: Double(usage.ri_user_time + usage.ri_system_time) * ProcessTable.timebase,
                             disk: usage.ri_diskio_bytesread + usage.ri_diskio_byteswritten, gpuNS: gpu[pid] ?? 0)
            counters[pid] = c
            var cpu = 0.0, disk = 0.0, gpuShare = 0.0
            if seconds > 0, let before = previous?.counters[pid] {
                cpu = max(c.cpuNS - before.cpuNS, 0) / seconds / 1e9 * 100
                disk = Double(c.disk >= before.disk ? c.disk - before.disk : 0) / seconds
                gpuShare = min(Double(c.gpuNS >= before.gpuNS ? c.gpuNS - before.gpuNS : 0) / seconds / 1e9 * 100, 100)
            }
            let cached = paths[pid].flatMap { $0.started == info.started ? $0 : nil }
            let path = cached?.path ?? (cached == nil ? ProcTable.path(pid) : nil)
            livePaths[pid] = (info.started, path)
            rows.append(ProcessRow(pid: pid, ppid: info.ppid, name: ProcessKind.displayName(info.name, path: path), path: path,
                                   app: path.flatMap(ProcessKind.appBundle), cpu: cpu, memory: usage.ri_phys_footprint,
                                   watts: 0, diskRate: disk, gpu: gpuShare, userOwned: info.uid == me))
        }
        paths = livePaths
        previous = (now, counters)
        ProcessSampler.sharePower(&rows, cpuWatts: cpuWatts, gpuWatts: gpuWatts, load: load)
        return rows
    }

    /// Power follows each process's share of the machine's CPU and GPU time.
    static func sharePower(_ rows: inout [ProcessRow], cpuWatts: Double, gpuWatts: Double, load: (cpu: Double, gpu: Double)) {
        let cpuSum = max(load.cpu, rows.reduce(0) { $0 + $1.cpu })
        let gpuSum = max(load.gpu, rows.reduce(0) { $0 + $1.gpu })
        for i in rows.indices {
            let cpu = cpuSum > 0 ? rows[i].cpu / cpuSum * cpuWatts : 0
            let gpu = gpuSum > 0 ? rows[i].gpu / gpuSum * gpuWatts : 0
            rows[i].watts = cpu + gpu
        }
    }
}

/// Ends processes. Only this user's processes; the kernel refuses others.
public enum ProcessControl {
    public enum Mode: Sendable {
        /// Asks it to quit (SIGTERM), as if you chose Quit in it.
        case quit
        /// Stops it at once (SIGKILL).
        case forceQuit
        /// Asks it and everything it started to quit, children first.
        case quitTree
    }

    /// `root` and its descendants, deepest first, from a (pid, ppid) table.
    static func treeOrder(_ root: Int32, table: [(pid: Int32, ppid: Int32)]) -> [Int32] {
        var children: [Int32: [Int32]] = [:]
        for row in table { children[row.ppid, default: []].append(row.pid) }
        var order = [root]
        var seen: Set<Int32> = [root]
        var i = 0
        while i < order.count {
            for kid in children[order[i]] ?? [] where seen.insert(kid).inserted { order.append(kid) }
            i += 1
        }
        return order.reversed()
    }

    /// Ends one process (and with `.quitTree` its children first).
    @concurrent
    public static func end(_ pid: Int32, mode: Mode) async throws {
        guard pid > 1 else { throw LowtideError.denied("That process can't be ended.") }
        let me = getuid()
        let owned = ProcTable.pids().compactMap(ProcessTable.info).filter { $0.uid == me }
        guard let target = owned.first(where: { $0.pid == pid }) else {
            throw LowtideError.notFound("That process (or one you own)")
        }
        let targets = mode == .quitTree ? treeOrder(pid, table: owned.map { ($0.pid, $0.ppid) }) : [target.pid]
        let signal = mode == .forceQuit ? SIGKILL : SIGTERM
        let sent = targets.filter { $0 > 1 && kill($0, signal) == 0 }.count
        guard sent > 0 else {
            throw LowtideError.denied(String(cString: strerror(errno)).capitalizedFirst)
        }
    }
}

extension String {
    /// "operation not permitted" → "Operation not permitted".
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
