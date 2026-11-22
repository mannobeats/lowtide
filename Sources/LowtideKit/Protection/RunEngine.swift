import CoreServices
import Darwin
import Foundation

/// A terminal Lowtide runs: its id and its shell's pid. The engine reads
/// the shell's terminal to see which job is in the foreground.
public struct TerminalShell: Sendable, Hashable {
    public var id: String
    public var shell: Int32
    public init(id: String, shell: Int32) {
        self.id = id
        self.shell = shell
    }
}

/// One connection the network monitor saw, for byte counts and names.
public struct RunConnection: Sendable, Hashable {
    public var id: UInt64
    public var pid: Int32
    public var app: String
    public var ip: String
    public var port: UInt16
    public var bytesIn: UInt64
    public var bytesOut: UInt64
    /// When the monitor first saw it, ms.
    public var firstSeen: UInt64
    public var host: String?
    public var org: String?
    public var country: String?

    public init(id: UInt64, pid: Int32, app: String, ip: String, port: UInt16, bytesIn: UInt64, bytesOut: UInt64,
                firstSeen: UInt64, host: String? = nil, org: String? = nil, country: String? = nil) {
        self.id = id
        self.pid = pid
        self.app = app
        self.ip = ip
        self.port = port
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.firstSeen = firstSeen
        self.host = host
        self.org = org
        self.country = country
    }
}

/// What other spaces tell the engine. Every part is optional: without the
/// terminals only installers are followed; without the network monitor
/// destinations come from the processes' own sockets (no byte counts) and
/// names from reverse DNS.
public struct RunSources: Sendable {
    /// Lowtide's local terminals (not SSH sessions).
    public var terminals: (@Sendable () -> [TerminalShell])?
    /// Connections the network monitor sees now.
    public var connections: (@Sendable () async -> [RunConnection])?
    /// A name learned from DNS answers or TLS for an address.
    public var hostName: (@Sendable (String) async -> String?)?
    /// Who runs an address and where (`Cloudflare`, `US`).
    public var place: (@Sendable (String) async -> (org: String?, country: String?)?)?
    /// Asks the network monitor to sample faster for a while.
    public var boost: (@Sendable () -> Void)?

    public init(terminals: (@Sendable () -> [TerminalShell])? = nil,
                connections: (@Sendable () async -> [RunConnection])? = nil,
                hostName: (@Sendable (String) async -> String?)? = nil,
                place: (@Sendable (String) async -> (org: String?, country: String?)?)? = nil,
                boost: (@Sendable () -> Void)? = nil) {
        self.terminals = terminals
        self.connections = connections
        self.hostName = hostName
        self.place = place
        self.boost = boost
    }
}

/// Something Protection tells the person about: an install that did
/// something unusual, a decoy read, newly exposed secrets.
public struct ProtectionAlert: Sendable, Hashable {
    public enum Kind: String, Sendable { case tripwire, decoy, exposure }
    public var kind: Kind
    public var severity: Severity
    public var subject: String
    public var text: String
    public var at: UInt64

    public init(kind: Kind, severity: Severity, subject: String, text: String, at: UInt64 = Clock.now) {
        self.kind = kind
        self.severity = severity
        self.subject = subject
        self.text = text
        self.at = at
    }
}

/// Command receipts and the install tripwire. Every command started in one
/// of Lowtide's terminals, and every package installer started anywhere on
/// the Mac, is followed from start to finish: the processes it spawned, the
/// hosts they reached, the files that changed while it ran, and what it
/// left running. When it ends, the run becomes a receipt; an installer that
/// did something unusual raises the tripwire.
///
/// Limits, by design: processes are sampled four times a second while
/// something runs (twice when idle) and sockets once per sample, so
/// something that starts and ends between samples can be missed, and file
/// changes are "while it ran", not proven to be its own.
public actor RunEngine {
    public static let shared = RunEngine()

    /// Finished runs kept (and saved).
    static let keepRuns = 300
    /// How long an ended run waits for late file events and one more
    /// network sample before it is written up.
    static let settle: UInt64 = 2000
    /// Distinct changed paths counted per run, at most.
    static let maxPaths = 200_000
    /// How long a new process is re-read: npm starts titled `npm` and
    /// renames itself `npm install …` a moment later.
    static let young: UInt64 = 3000

    struct ConnSeen {
        var ip: String
        var port: UInt16
        var app: String
        var host: String?
        var org: String?
        var country: String?
        var bytesIn: UInt64
        var bytesOut: UInt64
    }

    struct Peer: Hashable { let ip: String, port: UInt16 }

    struct Active {
        var id: UInt64
        var source: Run.Source
        var pty: String?
        var root: Int32
        /// The terminal job's process group.
        var group: Int32?
        var command: String
        var cwd: String?
        var started: UInt64
        var ended: UInt64?
        var ecosystem: Ecosystem?
        var pids: [Int32: RunWriteUp.Seen] = [:]
        var alive: Set<Int32> = []
        var conns: [UInt64: ConnSeen] = [:]
        /// Far ends read from the processes' own sockets, with the process
        /// (no byte counts, but nothing slips between network samples).
        var peers: [Peer: String] = [:]
        var paths: [String: RunWriteUp.Change] = [:]
        /// Hosts this install should talk to, and their addresses.
        var expectedHosts: [String] = []
        var expectedIPs: Set<String> = []

        var view: ActiveRun {
            ActiveRun(id: id, source: source, ptyId: pty, command: command, started: started, ecosystem: ecosystem,
                      processes: pids.count, dests: Set(conns.values.map(\.ip)).union(peers.keys.map(\.ip)).count,
                      files: paths.count)
        }
    }

    private var active: [Active] = []
    private var done: [Run] = []
    private var nextID: UInt64 = 0
    private var known: [Int32: RunProcInfo] = [:]
    private var watcher: ChangeWatcher?
    private var watched: Set<String> = []
    private var idleSince: UInt64 = 0
    private var sources = RunSources()
    private var onFinished: (@Sendable (Run) -> Void)?
    private var onAlert: (@Sendable (ProtectionAlert) -> Void)?
    private var loop: Task<Void, Never>?
    private let file: URL
    private let home: String

    public init(file: URL = JSONStore.url("runs.json"), home: String = Paths.home.path) {
        self.file = file
        self.home = home
        let saved = (try? Data(contentsOf: file)).flatMap { try? JSONStore.decoder.decode([Run].self, from: $0) }
        done = saved ?? []
        nextID = done.map(\.id).max() ?? 0
    }

    // MARK: Lifecycle

    public func start(sources: RunSources, finished: @escaping @Sendable (Run) -> Void,
                      alert: @escaping @Sendable (ProtectionAlert) -> Void) {
        self.sources = sources
        onFinished = finished
        onAlert = alert
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let busy = await self.tick(now: Clock.now)
                try? await Task.sleep(for: .milliseconds(busy ? 250 : 500))
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        watcher?.stop()
        watcher = nil
        watched = []
    }

    /// Replaces what other spaces provide (integration wires these).
    public func setSources(_ sources: RunSources) { self.sources = sources }

    // MARK: What the pages read

    /// Finished runs, newest first (installs only when asked).
    public func list(installsOnly: Bool = false) -> [Run] {
        installsOnly ? done.filter { $0.ecosystem != nil } : done
    }

    /// Commands and installers being followed right now.
    public func following() -> [ActiveRun] { active.filter { $0.ended == nil }.map(\.view) }

    /// Runs that ended in a window, for the overnight report and Ask.
    public func runs(from: UInt64, to: UInt64) -> [Run] { done.filter { $0.ended >= from && $0.started <= to } }

    /// Forgets every finished run.
    public func clear() {
        done.removeAll()
        save()
    }

    /// Stops a process a run left behind (only one of this user's, and only
    /// one a run recorded with its start time, so a later process given the
    /// same pid is never reached).
    public func stopLeftBehind(pid: Int32, force: Bool) throws {
        let started = done.flatMap(\.procs.leftRunning).filter { $0.pid == pid }.compactMap(\.started)
        guard pid != getpid(), let info = RunProcessTable.info(pid), info.uid == RunProcessTable.currentUID,
              started.contains(info.started)
        else { throw LowtideError.invalid("That process was not left behind by a run.") }
        guard RunProcessTable.signal(pid, force: force) else { throw LowtideError.commandFailed("Couldn't stop process \(pid)") }
    }

    private func save() { JSONStore.write(done, to: file) }

    // MARK: Following

    /// One sample; true while something is being followed.
    func tick(now: UInt64) async -> Bool {
        // Read the process table now: a one-second install is over in four ticks.
        let snapshot = RunProcessTable.refresh(now: now)
        guard !snapshot.isEmpty else { return !active.isEmpty }
        followTerminals(snapshot, now: now)
        detectInstallers(snapshot, now: now)
        known = snapshot
        for index in active.indices {
            grow(&active[index], snapshot, now: now)
            if active[index].ended == nil { collectPeers(&active[index]) }
        }
        // Fast network sampling costs CPU: only for installs, and for the
        // first half minute of anything else.
        if active.contains(where: { $0.ended == nil && ($0.ecosystem != nil || now - $0.started < 30_000) }) {
            sources.boost?()
        }
        if !active.isEmpty, let connections = sources.connections {
            collectNet(await connections())
        }
        let settled = active.filter { $0.ended.map { now >= $0 + Self.settle } ?? false }
        active.removeAll { $0.ended.map { now >= $0 + Self.settle } ?? false }
        updateWatcher(now: now)
        for run in settled {
            let sources = self.sources, home = self.home
            Task.detached(priority: .utility) { [weak self] in
                let written = await Self.writeUp(run, snapshot: snapshot, sources: sources, home: home)
                await self?.finish(written)
            }
        }
        return !active.isEmpty
    }

    private func followTerminals(_ snapshot: [Int32: RunProcInfo], now: UInt64) {
        let terminals = sources.terminals?() ?? []
        for terminal in terminals {
            let group = snapshot[terminal.shell]?.tpgid ?? 0
            let running = group > 0 && group != terminal.shell
            if let index = active.firstIndex(where: { $0.pty == terminal.id && $0.ended == nil }) {
                if running, active[index].group == group {
                    refreshCommand(&active[index], snapshot, now: now)
                    continue
                }
                active[index].ended = now
            }
            if running { active.append(begin(.terminal, pty: terminal.id, root: group, group: group, now: now)) }
        }
        // Closed terminals end their runs.
        let open = Set(terminals.map(\.id))
        for index in active.indices where active[index].ended == nil {
            if let pty = active[index].pty, !open.contains(pty) { active[index].ended = now }
        }
    }

    /// A terminal job's command line: the pipeline the shell started, in
    /// order (`curl … | sh` is two processes). Its parts are the shell's own
    /// children; what they start in turn is not part of the line.
    static func jobCommand(_ group: Int32, _ snapshot: [Int32: RunProcInfo]) -> [[String]] {
        let shell = snapshot[group]?.ppid
        return snapshot.values
            .filter { $0.pgid == group && $0.ppid == shell }
            .sorted { ($0.started, $0.pid) < ($1.started, $1.pid) }
            .compactMap { ProcTable.arguments($0.pid) }
    }

    static func describe(_ parts: [[String]]) -> (String, Ecosystem?) {
        let line = parts.map { $0.joined(separator: " ") }.joined(separator: " | ")
        let shown = parts.map(RunRules.displayCommand).joined(separator: " | ")
        return (shown, RunRules.installer(line.split(separator: " ").map(String.init)))
    }

    /// A pipeline's later parts start a moment after its first: re-read the
    /// command line during the first seconds.
    private func refreshCommand(_ run: inout Active, _ snapshot: [Int32: RunProcInfo], now: UInt64) {
        guard let group = run.group, now - run.started <= 3000 else { return }
        let (command, ecosystem) = Self.describe(Self.jobCommand(group, snapshot))
        guard !command.isEmpty, command != run.command else { return }
        run.command = command
        if run.ecosystem == nil, ecosystem != nil {
            run.ecosystem = ecosystem
            resolveExpected(&run)
        }
    }

    private func begin(_ source: Run.Source, pty: String?, root: Int32, group: Int32?, now: UInt64) -> Active {
        nextID += 1
        let parts = group.map { Self.jobCommand($0, known) } ?? [ProcTable.arguments(root)].compactMap { $0 }
        let (command, ecosystem) = Self.describe(parts)
        var run = Active(id: nextID, source: source, pty: pty, root: root, group: group, command: command,
                         cwd: ProcTable.cwd(root), started: now, ecosystem: ecosystem)
        resolveExpected(&run)
        return run
    }

    /// Resolves the hosts an install is expected to reach, in the background.
    private func resolveExpected(_ run: inout Active) {
        guard let ecosystem = run.ecosystem else { return }
        let hosts = Array(Set(ecosystem.expectedHosts + RunRules.urlHosts(run.command) + configuredRegistries())).sorted()
        run.expectedHosts = hosts
        let id = run.id
        Task.detached(priority: .utility) { [weak self] in
            let ips = Self.resolve(hosts)
            await self?.addExpected(ips, to: id)
        }
    }

    private func addExpected(_ ips: Set<String>, to id: UInt64) {
        guard let index = active.firstIndex(where: { $0.id == id }) else { return }
        active[index].expectedIPs.formUnion(ips)
    }

    static func resolve(_ hosts: [String]) -> Set<String> {
        var ips: Set<String> = []
        for host in hosts {
            var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                                 ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, "443", &hints, &result) == 0 else { continue }
            var cursor = result
            while let entry = cursor {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0,
                               NI_NUMERICHOST) == 0 {
                    ips.insert(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
                }
                cursor = entry.pointee.ai_next
            }
            freeaddrinfo(result)
        }
        return ips
    }

    /// Registries the person set up themselves (`registry=` in ~/.npmrc,
    /// `index-url` in pip.conf) are expected too.
    private func configuredRegistries() -> [String] {
        ["/.npmrc", "/.config/pip/pip.conf", "/.pip/pip.conf"].flatMap { name -> [String] in
            guard let text = try? String(contentsOfFile: home + name, encoding: .utf8) else { return [] }
            return text.split(separator: "\n")
                .filter { $0.contains("registry") || $0.contains("index-url") }
                .flatMap { RunRules.urlHosts($0) }
        }
    }

    private func detectInstallers(_ snapshot: [Int32: RunProcInfo], now: UInt64) {
        guard !known.isEmpty else { return }
        let uid = RunProcessTable.currentUID
        for info in snapshot.values where info.uid == uid && now >= info.started && now - info.started < Self.young {
            let pid = info.pid
            let followed = active.contains { run in
                run.root == pid || run.pids[pid] != nil || run.group == info.pgid
                    || RunProcessTable.descends(pid, from: run.root, in: snapshot)
                    || run.pids.keys.contains { RunProcessTable.descends(pid, from: $0, in: snapshot) }
            }
            guard !followed, let args = ProcTable.arguments(pid), RunRules.installerProcess(args) != nil else { continue }
            active.append(begin(.detected, pty: nil, root: pid, group: nil, now: now))
        }
    }

    /// Adds the run's new descendants, and notices what has exited.
    private func grow(_ run: inout Active, _ snapshot: [Int32: RunProcInfo], now: UInt64) {
        for _ in 0..<6 {
            var added = false
            for info in snapshot.values where run.pids[info.pid] == nil {
                let belongs = info.pid == run.root || run.group == info.pgid || run.pids[info.ppid] != nil
                // Older processes that happen to share a group are not ours.
                guard belongs, info.started + 1000 >= run.started else { continue }
                let (args, env) = ProcTable.launch(info.pid) ?? ([], [])
                run.pids[info.pid] = RunWriteUp.Seen(comm: info.comm, ppid: info.ppid, started: info.started, lastSeen: now,
                                                     args: args, script: RunRules.script(of: args, env: env))
                added = true
            }
            if !added { break }
        }
        run.alive = []
        for (pid, seen) in run.pids where snapshot[pid]?.started == seen.started {
            run.alive.insert(pid)
            run.pids[pid]?.lastSeen = now
        }
        // An installer found elsewhere ends with its first process.
        if run.source == .detected, run.ended == nil, !run.alive.contains(run.root), now - run.started > 1000 {
            run.ended = now
        }
    }

    /// Where the run's live processes are connected right now.
    private func collectPeers(_ run: inout Active) {
        for pid in run.alive {
            guard let comm = run.pids[pid]?.comm else { continue }
            for peer in RunProcessTable.peers(pid) where !peer.loopback && run.peers.count <= 500 {
                let key = Peer(ip: peer.ip, port: peer.port)
                if run.peers[key] == nil { run.peers[key] = comm }
            }
        }
    }

    /// Connections opened by any of the runs' processes since each began.
    private func collectNet(_ connections: [RunConnection]) {
        var owner: [Int32: Int] = [:]
        for (index, run) in active.enumerated() {
            for pid in run.pids.keys { owner[pid] = index }
        }
        for conn in connections {
            guard let index = owner[conn.pid], conn.firstSeen + 2000 >= active[index].started else { continue }
            var seen = active[index].conns[conn.id] ?? ConnSeen(ip: conn.ip, port: conn.port, app: conn.app, host: nil,
                                                                 org: conn.org, country: conn.country, bytesIn: 0, bytesOut: 0)
            seen.bytesIn = max(seen.bytesIn, conn.bytesIn)
            seen.bytesOut = max(seen.bytesOut, conn.bytesOut)
            if seen.host == nil { seen.host = conn.host }
            active[index].conns[conn.id] = seen
        }
    }

    // MARK: File changes

    /// Folders watched while anything runs.
    private func watchRoots() -> Set<String> {
        var roots = Set([home, "/opt/homebrew", "/usr/local", "/Applications", "/Library/LaunchAgents", "/Library/LaunchDaemons"]
            .filter { FileManager.default.fileExists(atPath: $0) })
        for run in active {
            if let cwd = run.cwd, RunRules.under(cwd, home) == nil, cwd != home, cwd != "/" { roots.insert(cwd) }
        }
        return roots
    }

    private func updateWatcher(now: UInt64) {
        if active.isEmpty {
            // Linger a little: late events of the last run still arrive.
            if watcher != nil, now - idleSince > 10_000 {
                watcher?.stop()
                watcher = nil
                watched = []
            }
            return
        }
        idleSince = now
        let roots = watchRoots()
        guard !roots.isSubset(of: watched) || watcher == nil else { return }
        watcher?.stop()
        watched = watched.union(roots)
        watcher = ChangeWatcher(paths: Array(watched)) { [weak self] changes in
            Task { await self?.record(changes) }
        }
    }

    func record(_ raw: [(String, Bool)]) {
        let now = Clock.now
        // FSEvents reports real paths; places are judged against `home`.
        let real = realpath(home, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? home
        let changes = real == home ? raw
            : raw.map { path, created in (RunRules.under(path, real).map { home + "/" + $0 } ?? path, created) }
        for index in active.indices {
            if let ended = active[index].ended, now > ended + Self.settle { continue }
            let cwd = active[index].cwd
            for (path, created) in changes {
                if active[index].paths[path] != nil {
                    if created { active[index].paths[path]?.created = true }
                } else if active[index].paths.count < Self.maxPaths,
                          let place = RunRules.place(of: path, home: home, cwd: cwd) {
                    active[index].paths[path] = RunWriteUp.Change(place: place, created: created)
                }
            }
        }
    }

    // MARK: Writing it up

    /// Reverse DNS, for destinations no DNS answer or TLS name has named.
    static func reverseName(_ ip: String) async -> String? {
        guard let out = try? await Shell.run("/usr/bin/host", ["-W", "1", ip], timeout: .seconds(3)) else { return nil }
        guard let range = out.stdout.range(of: "domain name pointer ") else { return nil }
        let name = out.stdout[range.upperBound...].prefix { $0 != "\n" }
        return name.hasSuffix(".") ? String(name.dropLast()) : String(name)
    }

    static func dests(_ run: Active, sources: RunSources) async -> [RunDest] {
        var byIP: [String: RunDest] = [:]
        for conn in run.conns.values {
            var dest = byIP[conn.ip] ?? RunDest(ip: conn.ip, org: conn.org, country: conn.country,
                                                expected: run.expectedIPs.contains(conn.ip))
            dest.bytesIn += conn.bytesIn
            dest.bytesOut += conn.bytesOut
            if dest.host == nil { dest.host = conn.host }
            if !dest.apps.contains(conn.app) { dest.apps.append(conn.app) }
            if conn.port != 0, !dest.ports.contains(conn.port) { dest.ports.append(conn.port) }
            byIP[conn.ip] = dest
        }
        for (peer, app) in run.peers {
            var dest: RunDest
            if let known = byIP[peer.ip] {
                dest = known
            } else {
                let place = await sources.place?(peer.ip)
                dest = RunDest(ip: peer.ip, org: place?.org, country: place?.country,
                               expected: run.expectedIPs.contains(peer.ip))
            }
            if !dest.apps.contains(app) { dest.apps.append(app) }
            if !dest.ports.contains(peer.port) { dest.ports.append(peer.port) }
            byIP[peer.ip] = dest
        }
        // Names learned from DNS answers and TLS (packet capture on).
        if let hostName = sources.hostName {
            for (ip, dest) in byIP where dest.host == nil { byIP[ip]?.host = await hostName(ip) }
        }
        var list = Array(byIP.values)
        // Name what is still anonymous (a few, in parallel).
        let anonymous = list.indices.filter { list[$0].host == nil }.prefix(16)
        await withTaskGroup(of: (Int, String?).self) { group in
            for index in anonymous {
                let ip = list[index].ip
                group.addTask { (index, await reverseName(ip)) }
            }
            for await (index, name) in group { list[index].host = name }
        }
        for index in list.indices {
            if let host = list[index].host, run.expectedHosts.contains(where: { RunRules.hostMatches(host, $0) }) {
                list[index].expected = true
            }
            list[index].ports.sort()
        }
        list.sort { ($0.bytesIn + $0.bytesOut, $1.ip) > ($1.bytesIn + $1.bytesOut, $0.ip) }
        return Array(list.prefix(60))
    }

    static func writeUp(_ active: Active, snapshot: [Int32: RunProcInfo], sources: RunSources, home: String) async -> Run {
        let alive = { (pid: Int32, seen: RunWriteUp.Seen) in snapshot[pid]?.started == seen.started }
        let rootAlive = active.pids[active.root].map { alive(active.root, $0) } ?? false
        let dests = await dests(active, sources: sources)
        let gone = Set(active.paths.keys.filter { !Decoys.exists($0) })
        var run = Run(
            id: active.id, source: active.source, ptyId: active.pty, command: active.command,
            cwd: active.cwd.map { $0.replacingFirst(home, with: "~") }, started: active.started,
            ended: active.ended ?? Clock.now, ecosystem: active.ecosystem,
            net: NetSummary(bytesIn: dests.reduce(0) { $0 + $1.bytesIn }, bytesOut: dests.reduce(0) { $0 + $1.bytesOut },
                            dests: dests),
            procs: RunWriteUp.processes(active.pids, root: active.root, alive: alive),
            files: RunWriteUp.files(active.paths, gone: gone, home: home, cwd: active.cwd),
            packages: active.ecosystem == nil ? [] : RunWriteUp.packages(active.paths.keys, gone: gone))
        RunWriteUp.judge(&run, rootAlive: rootAlive, home: home)
        return run
    }

    private func finish(_ run: Run) {
        guard RunWriteUp.worthKeeping(run) else { return }
        if run.ecosystem != nil, run.verdict != .info {
            let short = RunRules.shortForAlert(run.command)
            onAlert?(ProtectionAlert(kind: .tripwire, severity: run.verdict, subject: short,
                                     text: "\(short): \(run.findings.first?.text ?? "")"))
        }
        done.insert(run, at: 0)
        if done.count > Self.keepRuns { done.removeLast(done.count - Self.keepRuns) }
        save()
        onFinished?(run)
    }
}

/// FSEvents on a set of folders, with each change's path and whether it
/// created the file. Metadata-only changes (times, permissions, extended
/// attributes) are left out: the decoys re-arm through access times, for
/// one. The callback runs on a private queue.
final class ChangeWatcher: @unchecked Sendable {
    // `stream` is created in init and only touched again by `stop()`, which
    // the engine calls from its actor; FSEvents serialises its callbacks.
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "dev.lowtide.runs.fsevents")
    private let handler: @Sendable ([(String, Bool)]) -> Void

    init?(paths: [String], handler: @escaping @Sendable ([(String, Bool)]) -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil,
                                           release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<ChangeWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let content = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
                | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified)
            var changes: [(String, Bool)] = []
            for index in 0..<min(count, list.count) {
                let flag = flags[index]
                guard flag & content != 0 else { continue }
                changes.append((list[index], flag & UInt32(kFSEventStreamEventFlagItemCreated) != 0))
            }
            if !changes.isEmpty { watcher.handler(changes) }
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
            UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
