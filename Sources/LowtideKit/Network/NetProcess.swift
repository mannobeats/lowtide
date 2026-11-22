import Darwin
import Foundation

/// The process table, read straight from the kernel (`libproc`, no child
/// processes): parents, owners, start times, arguments and working folders.
public enum NetProcess {
    public struct Info: Sendable, Hashable {
        public var pid: Int32
        public var ppid: Int32
        public var uid: UInt32
        /// The command name (up to 32 characters).
        public var name: String
        public var started: Millis
    }

    public static func info(_ pid: Int32) -> Info? {
        ProcTable.entry(pid).map { Info(pid: $0.pid, ppid: $0.ppid, uid: $0.uid, name: $0.name, started: Millis($0.started)) }
    }

    /// The command line, shortened for display.
    public static func commandLine(_ pid: Int32) -> String? {
        guard let args = ProcTable.arguments(pid) else { return nil }
        let line = args.joined(separator: " ")
        return line.count > 400 ? String(line.prefix(400)) + "…" : line
    }

    /// The pids, each with the chain of parents that launched it, oldest first.
    public static func lineage(of pids: [Int32]) -> [ProcNode] {
        var nodes: [ProcNode] = []
        var seen: Set<Int32> = []
        for pid in pids {
            var chain: [ProcNode] = []
            var current = pid
            while seen.insert(current).inserted {
                guard let info = info(current) else {
                    // launchd can't be read without root; it's always pid 1.
                    if current == 1 { chain.append(ProcNode(pid: 1, ppid: 0, name: "launchd", own: false)) }
                    break
                }
                let name = ProcTable.path(current).map { ($0 as NSString).lastPathComponent } ?? info.name
                chain.append(ProcNode(pid: current, ppid: info.ppid, name: name, own: pids.contains(current)))
                if current <= 1 { break }
                current = info.ppid
            }
            nodes += chain.reversed()
        }
        return nodes
    }

    /// Sends SIGTERM (or SIGKILL when forced).
    public static func signal(_ pid: Int32, force: Bool) -> Bool {
        kill(pid, force ? SIGKILL : SIGTERM) == 0
    }
}
