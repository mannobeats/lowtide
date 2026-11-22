import Darwin
import Foundation

/// The process table, read straight from the kernel (`libproc`, `sysctl`; no
/// child processes). Network, System, Protection and the command bar each
/// shape these reads into their own rows.
public enum ProcTable {
    public struct Entry: Sendable, Hashable {
        public var pid: Int32
        public var ppid: Int32
        public var pgid: Int32
        /// The foreground process group of its terminal (0 without one).
        public var tpgid: Int32
        public var uid: uid_t
        /// The longer of the command name and the process name.
        public var name: String
        /// Start time, milliseconds since the epoch.
        public var started: UInt64
    }

    /// Every pid on the system.
    public static func pids() -> [Int32] {
        var capacity = 4096
        while true {
            var pids = [Int32](repeating: 0, count: capacity)
            let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
            guard count > 0 else { return [] }
            if Int(count) < capacity { return pids.prefix(Int(count)).filter { $0 > 0 } }
            capacity *= 2
        }
    }

    public static func entry(_ pid: Int32) -> Entry? {
        guard pid > 0 else { return nil }
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { return nil }
        let comm = cString(bsd.pbi_comm), name = cString(bsd.pbi_name)
        return Entry(pid: pid, ppid: Int32(bitPattern: bsd.pbi_ppid), pgid: Int32(bitPattern: bsd.pbi_pgid),
                     tpgid: Int32(bitPattern: bsd.e_tpgid), uid: bsd.pbi_uid, name: name.count > comm.count ? name : comm,
                     started: bsd.pbi_start_tvsec * 1000 + bsd.pbi_start_tvusec / 1000)
    }

    /// The executable behind a pid (works for every user's processes).
    public static func path(_ pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The folder a process works in (only this user's processes).
    public static func cwd(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = cString(info.pvi_cdir.vip_path)
        return path.isEmpty ? nil : path
    }

    /// The arguments (`argv[0]` first) and environment (`KEY=value`) a
    /// process was started with (only this user's processes).
    public static func launch(_ pid: Int32) -> (args: [String], env: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 256 * 1024
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size >= 4 else { return nil }
        return parseProcargs(Array(buffer.prefix(size)))
    }

    public static func arguments(_ pid: Int32) -> [String]? { launch(pid)?.args }

    /// `KERN_PROCARGS2`: argc, the executable path, padding, argv, then the
    /// environment.
    static func parseProcargs(_ buffer: [UInt8]) -> (args: [String], env: [String])? {
        guard buffer.count >= 4 else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        var index = 4
        // The executable path, then NUL padding.
        while index < buffer.count, buffer[index] != 0 { index += 1 }
        while index < buffer.count, buffer[index] == 0 { index += 1 }
        guard index < buffer.count else { return nil }
        let parts = buffer[index...].split(separator: 0, omittingEmptySubsequences: false)
        var args: [String] = []
        for part in parts.prefix(argc) {
            let text = String(decoding: part, as: UTF8.self)
            let trimmed = String(text.reversed().drop(while: \.isWhitespace).reversed())
            if !trimmed.isEmpty { args.append(trimmed) }
        }
        // Padding follows the last string; Apple's own `key=value`s may too.
        var env: [String] = []
        for part in parts.dropFirst(argc) {
            if part.isEmpty { break }
            let text = String(decoding: part, as: UTF8.self)
            if text.contains("=") { env.append(text) }
        }
        return args.isEmpty ? nil : (args, env)
    }

    /// A fixed C string field (`pbi_name`, `vip_path`) as text.
    static func cString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
