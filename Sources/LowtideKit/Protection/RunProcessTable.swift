import Darwin
import Foundation
import Synchronization

/// One process, as the kernel describes it.
public struct RunProcInfo: Sendable, Hashable {
    public var pid: Int32
    public var ppid: Int32
    public var pgid: Int32
    /// The foreground process group of its terminal (0 without one).
    public var tpgid: Int32
    public var uid: UInt32
    /// The short command name.
    public var comm: String
    /// Start time, milliseconds since the epoch.
    public var started: UInt64
}

/// A connected internet socket's far end.
public struct SocketPeer: Sendable, Hashable {
    public var ip: String
    public var port: UInt16
    public var loopback: Bool
}

/// A process that started while the table was being watched.
public struct ProcessStart: Sendable, Hashable {
    public var pid: Int32
    public var comm: String
    public var path: String?
    public var parent: String?
    public var started: UInt64
}

/// The process table, read straight from the kernel (`libproc`, no child
/// processes): parents, groups, start times, arguments, working folders and
/// sockets. `refresh()` keeps a snapshot and remembers which processes
/// started recently, so the decoys can ask "what launched around then?"
/// long after a short-lived process is gone.
public enum RunProcessTable {
    // MARK: Reading one process

    /// Parent, group, owner, name and start of one process.
    public static func info(_ pid: Int32) -> RunProcInfo? {
        ProcTable.entry(pid).map {
            RunProcInfo(pid: $0.pid, ppid: $0.ppid, pgid: $0.pgid, tpgid: $0.tpgid, uid: $0.uid, comm: $0.name, started: $0.started)
        }
    }

    /// The far ends of a process's connected internet sockets, read from
    /// its file descriptors (cheap; only this user's processes).
    public static func peers(_ pid: Int32) -> [SocketPeer] {
        let entry = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: 1024)
        let bytes = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard bytes > 0 else { return [] }
        return fds.prefix(Int(bytes) / entry)
            .filter { $0.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) }
            .compactMap { socketPeer(pid, $0.proc_fd) }
    }

    static func socketPeer(_ pid: Int32, _ fd: Int32) -> SocketPeer? {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        guard proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, size) == size else { return nil }
        // SOCKINFO_IN and SOCKINFO_TCP both start with `in_sockinfo`.
        guard info.psi.soi_kind == SOCKINFO_IN || info.psi.soi_kind == SOCKINFO_TCP else { return nil }
        let insi = info.psi.soi_proto.pri_in
        // Ports are stored in network byte order in the low 16 bits.
        let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: insi.insi_fport))
        var address = insi.insi_faddr
        let ip: String, loopback: Bool
        switch insi.insi_vflag {
        case UInt8(INI_IPV4):
            let v4 = address.ina_46.i46a_addr4
            guard v4.s_addr != 0 else { return nil }
            ip = withUnsafeBytes(of: &address.ina_46.i46a_addr4) { render(AF_INET, $0, length: INET_ADDRSTRLEN) }
            loopback = (UInt32(bigEndian: v4.s_addr) >> 24) == 127
        case UInt8(INI_IPV6):
            let raw = withUnsafeBytes(of: address.ina_6) { Array($0) }
            guard raw.contains(where: { $0 != 0 }) else { return nil }
            ip = withUnsafeBytes(of: &address.ina_6) { render(AF_INET6, $0, length: INET6_ADDRSTRLEN) }
            loopback = raw == [UInt8](repeating: 0, count: 15) + [1]
                || (raw[10] == 0xff && raw[11] == 0xff && raw[12] == 127)
        default:
            return nil
        }
        return port == 0 ? nil : SocketPeer(ip: ip, port: port, loopback: loopback)
    }

    static func render(_ family: Int32, _ address: UnsafeRawBufferPointer, length: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: Int(length))
        _ = inet_ntop(family, address.baseAddress, &buffer, socklen_t(length))
        let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return text.hasPrefix("::ffff:") && text.contains(".") ? String(text.dropFirst(7)) : text
    }

    /// Sends a signal (`SIGTERM`, or `SIGKILL` with `force`) to one of this
    /// user's processes.
    public static func signal(_ pid: Int32, force: Bool) -> Bool {
        pid > 1 && kill(pid, force ? SIGKILL : SIGTERM) == 0
    }

    public static var currentUID: UInt32 { getuid() }

    /// Walks up from `pid`: is `ancestor` one of its parents?
    public static func descends(_ pid: Int32, from ancestor: Int32, in table: [Int32: RunProcInfo]) -> Bool {
        var current = pid
        for _ in 0..<64 {
            guard let info = table[current] else { return false }
            if info.ppid == ancestor { return true }
            if info.ppid <= 1 { return false }
            current = info.ppid
        }
        return false
    }

    // MARK: The shared snapshot

    /// How long starts are remembered.
    static let keepStarts: UInt64 = 15 * 60_000

    private struct State {
        var procs: [Int32: RunProcInfo] = [:]
        var starts: [ProcessStart] = []
    }

    private static let state = Mutex(State())

    /// Reads the whole table now and returns it; processes new since the
    /// last read join the start history.
    @discardableResult
    public static func refresh(now: UInt64 = Clock.now) -> [Int32: RunProcInfo] {
        let old = state.withLock { $0.procs }
        var procs: [Int32: RunProcInfo] = [:]
        procs.reserveCapacity(old.count + 16)
        var fresh: [RunProcInfo] = []
        for pid in ProcTable.pids() {
            guard let info = info(pid) else { continue }
            // A pid seen before under the same start time is the same process.
            if !old.isEmpty, old[pid]?.started != info.started { fresh.append(info) }
            procs[pid] = info
        }
        let starts = fresh.map {
            ProcessStart(pid: $0.pid, comm: $0.comm, path: ProcTable.path($0.pid), parent: procs[$0.ppid]?.comm, started: $0.started)
        }
        state.withLock { table in
            table.procs = procs
            table.starts.append(contentsOf: starts)
            let cutoff = now > keepStarts ? now - keepStarts : 0
            if let keep = table.starts.firstIndex(where: { $0.started >= cutoff }) {
                table.starts.removeFirst(keep)
            } else {
                table.starts.removeAll()
            }
            if table.starts.count > 5000 { table.starts.removeFirst(table.starts.count - 5000) }
        }
        return procs
    }

    /// The last snapshot.
    public static var snapshot: [Int32: RunProcInfo] { state.withLock { $0.procs } }

    /// Processes that started between `from` and `to` (milliseconds).
    public static func starts(from: UInt64, to: UInt64) -> [ProcessStart] {
        state.withLock { $0.starts.filter { $0.started >= from && $0.started <= to } }
    }
}

/// Milliseconds since the epoch, the unit every receipt and decoy uses.
public enum Clock {
    public static var now: UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
    public static func date(_ ms: UInt64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
}
