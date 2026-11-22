import CryptoKit
import Darwin
import Foundation
import os

/// Fleet: saved hosts, watched agentless over SSH. Every minute a small
/// read-only POSIX sh snapshot runs on each watched server, and the result
/// is compared with what is normal for it: its listening ports, the
/// countries it talks to, and who signs in.
public enum Fleet {
    public static let interval: Duration = .seconds(60)
    static let stagger: Duration = .seconds(2)
    static let maxParallel = 4
    static let probeTimeout: TimeInterval = 30
    static let historyLimit = 60
    static let eventLimit = 30
    static let learningProbes = 3
    static let failedLoginsNotice = 20
    static let diskNotice = 0.9
    static let maxPeers = 200

    /// What runs on the server: read-only, one marker line per section.
    public static let script = #"""
        export LC_ALL=C PATH="$PATH:/usr/sbin:/sbin"
        echo @@host; hostname 2>/dev/null || uname -n
        echo @@os; uname -sr
        echo @@uptime
        if [ -r /proc/uptime ]; then cut -d' ' -f1 /proc/uptime
        else b=$(sysctl -n kern.boottime 2>/dev/null | sed 's/.*sec = \([0-9]*\).*/\1/'); [ -n "$b" ] && echo $(( $(date +%s) - b )); fi
        echo @@load; cat /proc/loadavg 2>/dev/null || sysctl -n vm.loadavg 2>/dev/null
        echo @@cpus; nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null
        echo @@mem; grep -E '^(MemTotal|MemAvailable):' /proc/meminfo 2>/dev/null
        echo @@disk; df -Pk / 2>/dev/null | tail -n 1
        echo @@listen; ss -Htulnp 2>/dev/null || netstat -tulnp 2>/dev/null
        echo @@peers; ss -Htnp state established 2>/dev/null || netstat -tnp 2>/dev/null | grep ESTABLISHED
        echo @@users; who 2>/dev/null
        echo @@failed
        if command -v journalctl >/dev/null 2>&1 && { [ "$(id -u)" = 0 ] || id -Gn 2>/dev/null | grep -qwE 'adm|systemd-journal|wheel'; }; then
          journalctl -u ssh -u sshd --since '1 hour ago' --no-pager 2>/dev/null | grep -cE 'Failed password|Invalid user'
        elif [ -r /var/log/auth.log ]; then
          tail -n 3000 /var/log/auth.log | grep -cE 'sshd.*(Failed password|Invalid user)'
        fi
        echo @@end

        """#

    // MARK: Types

    public struct Listener: Equatable, Hashable, Sendable {
        public var proto: String
        public var address: String
        public var port: Int
        public var process: String?
    }

    public struct Peer: Equatable, Hashable, Sendable {
        public var ip: String
        public var port: Int
        public var localPort: Int
        public var process: String?
        /// Connections folded into this row (same address and process).
        public var count: Int
        public var country: String?
        public var org: String?
    }

    public struct Login: Equatable, Hashable, Sendable {
        public var user: String
        public var tty: String
        public var since: String
        public var from: String?
    }

    public struct Snapshot: Equatable, Sendable {
        public var hostname = ""
        public var os = ""
        public var uptime: Int?
        public var load: [Double]?
        public var cpus: Int?
        /// Bytes.
        public var memTotal: Int64?
        public var memAvailable: Int64?
        /// Bytes, of `/`.
        public var diskTotal: Int64?
        public var diskUsed: Int64?
        public var listeners: [Listener] = []
        public var peers: [Peer] = []
        public var users: [Login] = []
        /// Failed SSH logins in the last hour; nil when the server won't say.
        public var failedLogins: Int?
        /// Peer countries, sorted.
        public var countries: [String] = []

        public var memShare: Double? {
            guard let total = memTotal, total > 0, let available = memAvailable else { return nil }
            return 1 - Double(available) / Double(total)
        }
        public var diskShare: Double? {
            guard let total = diskTotal, total > 0, let used = diskUsed else { return nil }
            return Double(used) / Double(total)
        }
        /// Load average over cores, so 1 means every core busy.
        public var loadShare: Double? { load.map { $0[0] / Double(max(1, cpus ?? 1)) } }
    }

    public struct Point: Equatable, Sendable {
        public var t: Date
        public var load: Double
        /// Share of memory in use, 0–1.
        public var mem: Double
    }

    public struct Event: Equatable, Sendable, Identifiable {
        public enum Severity: String, Sendable { case alert, notice }
        public var id = UUID()
        public var t: Date
        public var severity: Severity
        public var text: String
    }

    public enum State: String, Sendable {
        case ok, unreachable, needsKey, probing
    }

    public struct Place: Equatable, Sendable {
        public var country: String?
        public var org: String?
        public init(country: String?, org: String?) {
            self.country = country
            self.org = org
        }
    }

    /// A watched host, as the monitor probes it.
    public struct Target: Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var endpoint: SSHEndpoint
        public var secrets: [AskpassSecret]
        public init(id: String, name: String, endpoint: SSHEndpoint, secrets: [AskpassSecret] = []) {
            self.id = id
            self.name = name
            self.endpoint = endpoint
            self.secrets = secrets
        }
    }

    public struct Server: Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var host: String
        public var user: String
        public var state: State = .probing
        /// A probe is running now.
        public var busy = false
        public var error: String?
        public var lastProbe: Date?
        public var lastOK: Date?
        public var rtt: Int?
        /// Where the server itself is.
        public var place: Place?
        public var snapshot: Snapshot?
        public var history: [Point] = []
        public var events: [Event] = []
        /// Still learning what is normal (first probes).
        public var learning = true
        var due: Date = .distantFuture

        init(_ target: Target, due: Date) {
            id = target.id
            name = target.name
            host = target.endpoint.host
            user = target.endpoint.user
            self.due = due
        }

        public static func == (a: Server, b: Server) -> Bool {
            a.id == b.id && a.state == b.state && a.busy == b.busy && a.lastProbe == b.lastProbe && a.error == b.error
                && a.name == b.name && a.events.count == b.events.count
        }
    }

    /// What is normal for one server.
    struct Known: Codable, Equatable, Sendable {
        var probes = 0
        var ports: Set<String> = []
        var countries: Set<String> = []
        var users: Set<String> = []
    }

    // MARK: Parsing

    static func sections(_ out: String) -> [String: [String]] {
        var map: [String: [String]] = [:]
        var current = ""
        for raw in out.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("@@") {
                current = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
                map[current, default: []] = map[current] ?? []
            } else if !current.isEmpty, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                map[current, default: []].append(line)
            }
        }
        return map
    }

    /// `[::ffff:1.2.3.4]:443`, `127.0.0.53%lo:53`, `:::22` → (address, port).
    static func splitEndpoint(_ token: String) -> (String, Int)? {
        guard let colon = token.lastIndex(of: ":"), let port = Int(token[token.index(after: colon)...]) else { return nil }
        var address = String(token[..<colon])
        address = address.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let percent = address.firstIndex(of: "%") { address = String(address[..<percent]) }
        if address.hasPrefix("::ffff:") { address = String(address.dropFirst(7)) }
        return (address, port)
    }

    /// `users:(("sshd",pid=812,fd=3))` or netstat's `812/sshd`.
    static func processName(_ tokens: [Substring]) -> String? {
        if let users = tokens.first(where: { $0.hasPrefix("users:") }) {
            let parts = users.split(separator: "\"", omittingEmptySubsequences: false)
            return parts.count > 1 ? String(parts[1]) : nil
        }
        for token in tokens {
            guard let slash = token.firstIndex(of: "/") else { continue }
            let pid = token[..<slash], name = token[token.index(after: slash)...]
            if !pid.isEmpty, pid.allSatisfy(\.isNumber), !name.isEmpty {
                return String(name).trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            }
        }
        return nil
    }

    /// One line of `ss` or `netstat`: protocol, local and peer endpoints, process.
    static func socketLine(_ line: String) -> (proto: String, local: (String, Int), peer: (String, Int)?, process: String?)? {
        let tokens = line.split(whereSeparator: \.isWhitespace)
        let first = tokens.first.map(String.init) ?? ""
        let proto = first.hasPrefix("udp") ? "udp" : "tcp"
        let endpoints = tokens.filter { $0.contains(":") && !$0.hasPrefix("users:") }
        guard let localToken = endpoints.first, let local = splitEndpoint(String(localToken)) else { return nil }
        let peer = endpoints.count > 1 ? splitEndpoint(String(endpoints[1])) : nil
        return (proto, local, peer, processName(tokens))
    }

    static func isLoopback(_ address: String) -> Bool {
        address.hasPrefix("127.") || address == "::1" || address == "localhost"
    }

    static func parseListeners(_ lines: [String]) -> [Listener] {
        var seen = Set<String>()
        return lines.compactMap(socketLine).compactMap { line -> Listener? in
            let listener = Listener(proto: line.proto, address: line.local.0, port: line.local.1, process: line.process)
            return seen.insert("\(listener.proto) \(listener.address) \(listener.port)").inserted ? listener : nil
        }
        .sorted { ($0.port, $0.proto, $0.address) < ($1.port, $1.proto, $1.address) }
    }

    static func parsePeers(_ lines: [String]) -> [Peer] {
        var rows: [Peer] = []
        // A busy server has thousands of connections: fold by key, not by scan.
        var index: [String: Int] = [:]
        for line in lines {
            guard let parsed = socketLine(line), let peer = parsed.peer, !isLoopback(peer.0) else { continue }
            let key = "\(peer.0)\u{0}\(parsed.process ?? "")"
            if let row = index[key] {
                rows[row].count += 1
                continue
            }
            index[key] = rows.count
            rows.append(Peer(ip: peer.0, port: peer.1, localPort: parsed.local.1, process: parsed.process, count: 1))
        }
        rows.sort { $0.count != $1.count ? $0.count > $1.count : $0.ip < $1.ip }
        return Array(rows.prefix(maxPeers))
    }

    /// `root     pts/0        2024-05-01 10:11 (203.0.113.9)`.
    static func parseUsers(_ lines: [String]) -> [Login] {
        lines.compactMap { line in
            var head = Substring(line)
            var from: String?
            if let open = line.firstIndex(of: "(") {
                head = line[..<open]
                from = line[line.index(after: open)...].trimmingCharacters(in: CharacterSet(charactersIn: ")"))
            }
            let tokens = head.split(whereSeparator: \.isWhitespace)
            guard let user = tokens.first else { return nil }
            return Login(user: String(user), tty: tokens.count > 1 ? String(tokens[1]) : "",
                         since: tokens.dropFirst(2).joined(separator: " "), from: from?.isEmpty == false ? from : nil)
        }
    }

    static func meminfo(_ lines: [String], _ key: String) -> Int64? {
        for line in lines where line.hasPrefix(key) {
            let rest = line.dropFirst(key.count).drop { $0 == ":" }
            if let kb = rest.split(whereSeparator: \.isWhitespace).first.flatMap({ Int64($0) }) { return kb * 1024 }
        }
        return nil
    }

    public static func parse(_ out: String) -> Snapshot {
        let map = sections(out)
        func first(_ key: String) -> String? { map[key]?.first?.trimmingCharacters(in: .whitespaces) }
        var s = Snapshot()
        s.hostname = first("host") ?? ""
        s.os = first("os") ?? ""
        s.uptime = first("uptime").flatMap(Double.init).map { Int($0) }
        // `/proc/loadavg` or macOS `{ 1.20 1.31 1.40 }`.
        if let line = first("load") {
            let values = line.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }.prefix(3)
            if values.count == 3 { s.load = Array(values) }
        }
        s.cpus = first("cpus").flatMap { Int($0) }
        s.memTotal = meminfo(map["mem"] ?? [], "MemTotal")
        s.memAvailable = meminfo(map["mem"] ?? [], "MemAvailable")
        if let line = first("disk") {
            let numbers = line.split(whereSeparator: \.isWhitespace).dropFirst().prefix(3).compactMap { Int64($0) }
            if numbers.count == 3 {
                // Used as df counts it: everything but what is still available.
                s.diskTotal = numbers[0] * 1024
                s.diskUsed = max(0, numbers[0] - numbers[2]) * 1024
            }
        }
        s.listeners = parseListeners(map["listen"] ?? [])
        s.peers = parsePeers(map["peers"] ?? [])
        s.users = parseUsers(map["users"] ?? [])
        s.failedLogins = first("failed").flatMap { Int($0) }
        return s
    }

    // MARK: What's normal

    /// Learns the first probes; afterwards returns what breaks the pattern.
    static func learn(_ known: inout Known, _ snapshot: Snapshot) -> [(Event.Severity, String)] {
        let learning = known.probes < learningProbes
        known.probes += 1
        var events: [(Event.Severity, String)] = []
        for listener in snapshot.listeners where !isLoopback(listener.address) {
            if known.ports.insert("\(listener.proto)/\(listener.port)").inserted, !learning {
                events.append((.alert, "New listening port \(listener.proto) \(listener.port) on \(listener.address) (\(listener.process ?? "an unknown process"))"))
            }
        }
        for login in snapshot.users where known.users.insert(login.user).inserted && !learning {
            events.append((.alert, "New user logged in: \(login.user)\(login.from.map { " from \($0)" } ?? "")"))
        }
        for country in snapshot.countries where known.countries.insert(country).inserted && !learning {
            events.append((.notice, "First connection with a peer in \(country)"))
        }
        return events
    }

    /// Crossings of the thresholds since the previous snapshot.
    static func thresholds(_ previous: Snapshot?, _ snapshot: Snapshot) -> [(Event.Severity, String)] {
        var events: [(Event.Severity, String)] = []
        let failed = snapshot.failedLogins ?? 0
        if failed > failedLoginsNotice, (previous?.failedLogins ?? 0) <= failedLoginsNotice || previous == nil {
            events.append((.notice, "\(failed) failed SSH logins in the last hour"))
        }
        func full(_ s: Snapshot?) -> Bool { (s?.diskShare ?? 0) > diskNotice }
        if full(snapshot), !full(previous) {
            events.append((.notice, "Disk / is \(Int(((snapshot.diskShare ?? 0) * 100).rounded()))% full"))
        }
        return events
    }

    enum Outcome: Equatable {
        case ok(String)
        case needsKey(String)
        case unreachable(String)
    }

    static func classify(status: Int32?, stdout: String, stderr: String) -> Outcome {
        if stdout.contains("@@end") { return .ok(stdout) }
        if ["Permission denied", "no more authentication methods", "passphrase"].contains(where: stderr.contains) {
            return .needsKey("Sign-in failed. Background checks can't type: give this host a key or a saved password, or add its key to ssh-agent.")
        }
        let last = stderr.split(separator: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if last.isEmpty { return .unreachable("ssh exited with \(status.map(String.init) ?? "a signal")") }
        return .unreachable(last)
    }

    /// A folder only this user can enter, for the shared connections'
    /// sockets. Not `%C` in it: ssh adds 17 characters while it creates the
    /// socket, and the whole must fit the 104-byte socket path limit.
    static func controlPath(_ endpoint: SSHEndpoint) throws -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "lowtide-fleet")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(dir.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw LowtideError.denied("\(dir.path) is not a private folder")
        }
        let jump = endpoint.jump.map { "\($0.user)@\($0.host):\($0.port)" } ?? ""
        let digest = SHA256.hash(data: Data("\(endpoint.user)@\(endpoint.host):\(endpoint.port) \(jump)".utf8))
        return dir.appending(path: digest.prefix(8).map { String(format: "%02x", $0) }.joined()).path
    }
}

/// Probes the watched hosts every minute, a few at a time, never two
/// probes of one host at once.
public actor FleetMonitor {
    public static let shared = FleetMonitor()

    private var targets: [Fleet.Target] = []
    private var servers: [String: Fleet.Server] = [:]
    private var baseline: [String: Fleet.Known]
    private var running = 0
    private var loop: Task<Void, Never>?
    private let baselineFile = "fleet-baseline.json"

    private static let geo = OSAllocatedUnfairLock<(@Sendable (String) -> Fleet.Place?)?>(initialState: nil)

    /// Where an address is (country, organisation), from the app's geo database.
    public static func setGeoLookup(_ lookup: @escaping @Sendable (String) -> Fleet.Place?) {
        geo.withLock { $0 = lookup }
    }

    static func place(_ ip: String) -> Fleet.Place? { geo.withLock { $0 }?(ip) }

    init() {
        baseline = JSONStore.load(baselineFile, default: [String: Fleet.Known]())
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.schedule()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Replaces the watched list. New servers are staggered a couple of
    /// seconds apart; servers no longer watched are forgotten (their
    /// baseline stays).
    public func watch(_ targets: [Fleet.Target]) {
        let ids = Set(targets.map(\.id))
        servers = servers.filter { ids.contains($0.key) || $0.value.busy }
        var fresh = 0.0
        for target in targets where servers[target.id] == nil {
            servers[target.id] = Fleet.Server(target, due: Date().addingTimeInterval(fresh * 2))
            fresh += 1
        }
        for target in targets {
            servers[target.id]?.name = target.name
        }
        self.targets = targets
    }

    /// Every watched server, in the order they were given.
    public func status() -> [Fleet.Server] {
        targets.compactMap { servers[$0.id] }
    }

    private func schedule() {
        let now = Date()
        for target in targets {
            guard running < Fleet.maxParallel else { return }
            guard let server = servers[target.id], !server.busy, server.due <= now else { continue }
            running += 1
            // Claimed here so the next tick doesn't pick it again.
            servers[target.id]?.due = .distantFuture
            Task { [weak self] in
                _ = await self?.probe(target)
                await self?.finished()
            }
        }
    }

    private func finished() { running -= 1 }

    /// Probes one server now. Nil when it is already being probed.
    @discardableResult
    public func probe(_ target: Fleet.Target) async -> Fleet.Server? {
        if servers[target.id] == nil { servers[target.id] = Fleet.Server(target, due: .distantFuture) }
        guard servers[target.id]?.busy == false else { return nil }
        servers[target.id]?.busy = true
        let started = Date()
        let outcome = await Self.run(target)
        let rtt = Int(Date().timeIntervalSince(started) * 1000)
        let place = await Self.locate(target.endpoint.host)
        let now = Date()
        guard var server = servers[target.id] else { return nil }
        server.busy = false
        server.lastProbe = now
        server.due = now.addingTimeInterval(60)
        server.name = target.name
        server.host = target.endpoint.host
        server.user = target.endpoint.user
        if let place { server.place = place }
        switch outcome {
        case .ok(let out):
            server.rtt = rtt
            apply(&server, target: target, snapshot: Fleet.parse(out), now: now)
        case .needsKey(let error):
            fail(&server, .needsKey, error)
        case .unreachable(let error):
            fail(&server, .unreachable, error)
        }
        servers[target.id] = server
        return server
    }

    private func record(_ server: inout Fleet.Server, _ severity: Fleet.Event.Severity, _ text: String, at now: Date) {
        server.events.append(Fleet.Event(t: now, severity: severity, text: text))
        if server.events.count > Fleet.eventLimit { server.events.removeFirst(server.events.count - Fleet.eventLimit) }
    }

    private func apply(_ server: inout Fleet.Server, target: Fleet.Target, snapshot: Fleet.Snapshot, now: Date) {
        var snapshot = snapshot
        var countries = Set<String>()
        for index in snapshot.peers.indices {
            if let place = Self.place(snapshot.peers[index].ip) {
                snapshot.peers[index].country = place.country
                snapshot.peers[index].org = place.org
                if let country = place.country { countries.insert(country) }
            }
        }
        snapshot.countries = countries.sorted()
        var known = baseline[target.id] ?? Fleet.Known()
        var events = Fleet.learn(&known, snapshot)
        baseline[target.id] = known
        JSONStore.save(baseline, to: baselineFile)
        server.learning = known.probes < Fleet.learningProbes
        events += Fleet.thresholds(server.snapshot, snapshot)
        for (severity, text) in events { record(&server, severity, text, at: now) }
        server.history.append(Fleet.Point(t: now, load: snapshot.load?[0] ?? 0, mem: snapshot.memShare ?? 0))
        if server.history.count > Fleet.historyLimit { server.history.removeFirst(server.history.count - Fleet.historyLimit) }
        server.state = .ok
        server.error = nil
        server.lastOK = now
        server.snapshot = snapshot
    }

    private func fail(_ server: inout Fleet.Server, _ state: Fleet.State, _ error: String) {
        if server.state == .ok, state == .unreachable { record(&server, .notice, "Unreachable: \(error)", at: Date()) }
        server.state = state
        server.error = error
    }

    static func locate(_ host: String) async -> Fleet.Place? {
        guard geo.withLock({ $0 }) != nil else { return nil }
        return await Task.detached {
            var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0,
                                 ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
            defer { freeaddrinfo(result) }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(first.pointee.ai_addr, first.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0,
                              NI_NUMERICHOST) == 0 else { return nil }
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            return place(String(decoding: bytes, as: UTF8.self))
        }.value
    }

    /// Runs the snapshot over ssh, the script on stdin.
    static func run(_ target: Fleet.Target) async -> Fleet.Outcome {
        let args: [String]
        var environment = RemoteProcess.sshEnvironment()
        var token: String?
        do {
            let hasSecrets = !target.secrets.isEmpty
            args = try SSHCommand.probe(target.endpoint, controlPath: try Fleet.controlPath(target.endpoint), batch: !hasSecrets)
            if hasSecrets {
                // Saved passwords and passphrases work in the background too;
                // anything else ssh asks (a one-time code) is refused.
                let ticket = try AskpassServer.shared.register(secrets: target.secrets, interactive: false, label: target.name)
                environment.merge(ticket.environment) { _, new in new }
                token = ticket.token
            }
        } catch {
            return .unreachable(error.localizedDescription)
        }
        let ticket = token
        defer { if let ticket { AskpassServer.shared.unregister(ticket) } }
        let result = await RemoteProcess.run(SSHCommand.program, args, environment: environment, input: Data(Fleet.script.utf8),
                                             timeout: Fleet.probeTimeout) { pid in
            if let ticket { AskpassServer.shared.attach(ticket, pid: pid) }
        }
        if result.timedOut { return .unreachable("No answer in \(Int(Fleet.probeTimeout)) s") }
        return Fleet.classify(status: result.status, stdout: result.stdout, stderr: result.stderr)
    }
}
