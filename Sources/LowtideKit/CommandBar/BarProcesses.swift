import Darwin
import Foundation

/// The person's own processes, and ending them.
public enum Processes {
    public struct Info: Equatable, Sendable {
        public var pid: pid_t
        public var ppid: pid_t
        public var uid: uid_t
        public var name: String
        public var path: String?
    }

    public enum KillMode: String, Sendable {
        /// Asks it to stop (SIGTERM).
        case term
        /// At once (SIGKILL).
        case kill
        /// Its children first, then it.
        case tree
        /// Every process with the same name.
        case all
    }

    /// Every process this user owns, except launchd and Lowtide, by name.
    public static func own() -> [Info] {
        let me = getpid(), uid = getuid()
        return all().filter { $0.pid > 1 && $0.pid != me && $0.uid == uid }
            .sorted { ($0.name.lowercased(), $0.pid) < ($1.name.lowercased(), $1.pid) }
    }

    static func all() -> [Info] { ProcTable.pids().compactMap(info) }

    static func info(_ pid: pid_t) -> Info? {
        ProcTable.entry(pid).map { Info(pid: $0.pid, ppid: $0.ppid, uid: $0.uid, name: $0.name, path: ProcTable.path(pid)) }
    }

    /// `root` and its descendants, deepest first, from a (pid, ppid) table.
    static func treeOrder(_ root: pid_t, _ table: [(pid_t, pid_t)]) -> [pid_t] {
        var children: [pid_t: [pid_t]] = [:]
        for (pid, ppid) in table { children[ppid, default: []].append(pid) }
        var order = [root]
        var i = 0
        while i < order.count {
            for kid in children[order[i]] ?? [] where !order.contains(kid) { order.append(kid) }
            i += 1
        }
        return order.reversed()
    }

    /// The pids a kill request reaches, all owned by this user.
    static func targets(_ pid: pid_t, _ mode: KillMode, owned: [Info]) -> [pid_t] {
        guard let target = owned.first(where: { $0.pid == pid }) else { return [] }
        switch mode {
        case .term, .kill: return [pid]
        case .tree: return treeOrder(pid, owned.map { ($0.pid, $0.ppid) })
        case .all: return owned.filter { $0.name == target.name }.map(\.pid)
        }
    }

    /// Ends a process of this user.
    public static func kill(_ pid: pid_t, mode: KillMode) throws {
        guard pid > 1, pid != getpid() else { throw LowtideError.invalid("That process can't be stopped from here.") }
        let targets = targets(pid, mode, owned: own())
        guard !targets.isEmpty else { throw LowtideError.notFound("That process (or it isn't yours)") }
        let signal = mode == .kill ? SIGKILL : SIGTERM
        let sent = targets.filter { Darwin.kill($0, signal) == 0 }.count
        guard sent > 0 else { throw LowtideError.denied("Couldn't signal the process.") }
    }
}
