import Foundation

/// What the pages ask the monitor, each answered from one snapshot of the
/// state under the lock.
extension NetworkEngine {
    /// Apps with their connections and scores, busiest first.
    func apps(_ state: NetState) -> [NetApp] {
        var groups: [String: NetApp] = [:]
        var order: [String] = []
        for proc in state.procs.values.sorted(by: { $0.pid < $1.pid }) {
            let id = proc.identity
            if groups[id] == nil {
                order.append(id)
                groups[id] = NetApp(id: id, name: proc.name, app: proc.app, path: proc.path, pids: [], signature: proc.signature,
                                    rateIn: 0, rateOut: 0, bytesIn: 0, bytesOut: 0, recentBytes: 0, conns: 0, hosts: 0,
                                    listens: [], score: 0, reasons: [])
            }
            groups[id]!.pids.append(proc.pid)
            groups[id]!.rateIn += proc.rateIn
            groups[id]!.rateOut += proc.rateOut
            groups[id]!.bytesIn += proc.bytesIn
            groups[id]!.bytesOut += proc.bytesOut
            groups[id]!.listens += proc.listens
            // The main executable names the group, not a helper.
            if proc.app != nil, let path = proc.path, path.components(separatedBy: ".app/").count == 2 {
                groups[id]!.path = path
                groups[id]!.signature = proc.signature
            }
        }
        var remoteHosts: [String: Set<String>] = [:]
        var remotePorts: [String: [UInt16]] = [:]
        var pidGroup: [Int32: String] = [:]
        for proc in state.procs.values { pidGroup[proc.pid] = proc.identity }
        for conn in state.conns.values where conn.open && conn.remote {
            guard let id = pidGroup[conn.pid] else { continue }
            groups[id]?.conns += 1
            remoteHosts[id, default: []].insert(conn.socket.remoteIP)
            remotePorts[id, default: []].append(conn.socket.remotePort)
        }
        let home = Paths.home.path
        var rows: [NetApp] = []
        for id in order {
            guard var row = groups[id], row.bytesIn + row.bytesOut > 0 || row.conns > 0 || !row.listens.isEmpty else { continue }
            row.hosts = remoteHosts[id]?.count ?? 0
            row.listens = Array(Set(row.listens)).sorted()
            row.recentBytes = state.window[id]?.reduce(0) { $0 + $1.bytes } ?? 0
            if state.selfID != id {
                let opens = state.opens.filter { row.pids.contains($0.key.pid) }
                    .sorted { $0.key.remote < $1.key.remote }
                    .map { (host: state.hosts[$0.key.remote] ?? $0.key.remote, times: $0.value) }
                (row.score, row.reasons) = ThreatScore.score(.init(
                    signature: row.signature, path: row.path, listens: row.listens, bytesOut: row.bytesOut, bytesIn: row.bytesIn,
                    hosts: row.hosts, remotePorts: remotePorts[id] ?? [], opens: opens, home: home))
            }
            rows.append(row)
        }
        return rows.sorted { ($0.rate, $0.bytesIn + $0.bytesOut, $1.name) > ($1.rate, $1.bytesIn + $1.bytesOut, $0.name) }
    }

    func connRow(_ state: NetState, _ conn: ConnRecord) -> NetConn {
        let proc = state.procs[conn.pid]
        return NetConn(
            id: conn.id, pid: conn.pid, app: proc?.name ?? "pid \(conn.pid)", appID: proc?.identity ?? "",
            appPath: proc?.app ?? proc?.path, proto: conn.socket.proto,
            local: conn.socket.localIP, localPort: conn.socket.localPort,
            remote: conn.socket.remoteIP, remotePort: conn.socket.remotePort, host: state.hosts[conn.socket.remoteIP],
            service: NetService.name(conn.socket.remotePort) ?? (conn.socket.listening ? NetService.name(conn.socket.localPort) : nil),
            state: conn.state, iface: conn.iface, rttMs: conn.rttAvg ?? conn.rttMin,
            bytesIn: conn.bytesIn, bytesOut: conn.bytesOut, rateIn: conn.rateIn, rateOut: conn.rateOut,
            firstSeen: conn.firstSeen, closedAt: conn.closedAt, listening: conn.socket.listening,
            country: conn.place?.country, org: conn.place?.org, asn: conn.place?.asn)
    }

    /// The shortest round trip for a connection: its own, else one measured
    /// to the same network.
    func rtt(_ state: NetState, _ conn: ConnRecord) -> Double? {
        conn.rttMin ?? conn.rttAvg ?? GeoIP.prefix(conn.socket.remoteIP).flatMap { state.rttByPrefix[$0] }
    }

    /// Everything the Live page shows.
    public func overview() -> NetOverview {
        state.withLock { state in
            var out = NetOverview()
            out.ready = state.sampled
            let apps = apps(state)
            var appOfPid: [Int32: String] = [:]
            for row in apps { for pid in row.pids { appOfPid[pid] = row.name } }
            var edges: [String: NetEdge] = [:]
            var servers: Set<String> = []
            for conn in state.conns.values where conn.open && !conn.socket.listening {
                servers.insert(conn.socket.remoteIP)
                guard conn.remote else { continue }
                let app = appOfPid[conn.pid] ?? state.procs[conn.pid]?.name ?? "pid \(conn.pid)"
                let host = state.hosts[conn.socket.remoteIP] ?? conn.socket.remoteIP
                let id = "\(app)|\(host)"
                var edge = edges[id] ?? NetEdge(
                    app: app, host: host, ip: conn.socket.remoteIP, port: conn.socket.remotePort, proto: conn.socket.proto,
                    rateIn: 0, rateOut: 0, packets: 0, conns: 0, country: conn.place?.country, org: conn.place?.org,
                    asn: conn.place?.asn, rttMs: nil)
                edge.rateIn += conn.rateIn
                edge.rateOut += conn.rateOut
                edge.packets += state.edgePackets[OpenKey(pid: conn.pid, remote: conn.socket.remoteIP)] ?? 0
                edge.conns += 1
                if let rtt = rtt(state, conn) { edge.rttMs = min(edge.rttMs ?? .infinity, rtt) }
                edges[id] = edge
            }
            out.edges = Array(edges.values.sorted { ($0.rateIn + $0.rateOut, $0.packets, $0.conns, $1.id) > ($1.rateIn + $1.rateOut, $1.packets, $1.conns, $0.id) }.prefix(120))
            out.recent = state.conns.values.filter { !$0.preexisting && !$0.socket.listening }
                .sorted { $0.firstSeen > $1.firstSeen }.prefix(40).map { connRow(state, $0) }
            out.hosts = servers.count
            out.domainAlerts = Array(state.dns.newestFirst.lazy.filter { $0.suspicious != nil }.prefix(30))
            out.series = Array(state.series.elements.suffix(120))
            out.events = Array(state.events.suffix(40).reversed())
            out.learning = state.baseline.learning(.now)
            out.apps = Array(apps.prefix(60))
            out.capture = captureStatus(state)
            return out
        }
    }

    /// Every open connection and those closed in the last ten minutes.
    public func connections() -> [NetConn] {
        state.withLock { state in
            state.conns.values.map { connRow(state, $0) }
                .sorted { ($1.closedAt == nil ? 1 : 0, $0.rate, $0.firstSeen) > ($0.closedAt == nil ? 1 : 0, $1.rate, $1.firstSeen) }
        }
    }

    /// Lookups seen while capturing, newest first.
    public func dns(limit: Int = 2_000) -> [DNSRecord] {
        state.withLock { Array($0.dns.newestFirst.prefix(limit)) }
    }

    /// The last hour: total traffic at every snapshot, and every event.
    public func timeline() -> NetTimeline {
        state.withLock { state in
            var out = NetTimeline()
            out.points = state.frames.map { TimelinePoint(t: $0.t, rateIn: $0.rateIn, rateOut: $0.rateOut) }
            out.events = state.events
            return out
        }
    }

    /// The map as it was at `t`: the snapshot closest to it.
    public func frame(at t: Millis) -> NetFrameView? {
        state.withLock { state in
            guard let frame = state.frames.min(by: { abs($0.t - t) < abs($1.t - t) }) else { return nil }
            return NetFrameView(t: frame.t, edges: frame.edges.map { edge in
                NetEdge(app: edge.app, host: edge.host, ip: "", port: 0, proto: "", rateIn: edge.rateIn, rateOut: edge.rateOut,
                        packets: 0, conns: 1, country: edge.place?.country, org: edge.place?.org, asn: edge.place?.asn,
                        rttMs: edge.rtt.map(Double.init))
            })
        }
    }

    /// Everything known about one app, for its dossier.
    public func dossier(app name: String) -> NetDossier? {
        let found = state.withLock { state -> NetDossier? in
            guard let app = apps(state).first(where: { $0.name == name }) else { return nil }
            var hosts: [String: DossierHost] = [:]
            for conn in state.conns.values where app.pids.contains(conn.pid) && conn.remote {
                let host = state.hosts[conn.socket.remoteIP] ?? conn.socket.remoteIP
                var row = hosts[host] ?? DossierHost(
                    host: host, ip: conn.socket.remoteIP, port: conn.socket.remotePort, service: NetService.name(conn.socket.remotePort),
                    country: conn.place?.country, org: conn.place?.org, asn: conn.place?.asn, rttMs: nil,
                    bytesIn: 0, bytesOut: 0, rateIn: 0, rateOut: 0, conns: 0)
                row.bytesIn += conn.bytesIn
                row.bytesOut += conn.bytesOut
                row.rateIn += conn.rateIn
                row.rateOut += conn.rateOut
                row.conns += conn.open ? 1 : 0
                if let rtt = rtt(state, conn) { row.rttMs = min(row.rttMs ?? .infinity, rtt) }
                hosts[host] = row
            }
            let history = state.frames.map { frame in
                let mine = frame.edges.filter { $0.app == name }
                return TimelinePoint(t: frame.t, rateIn: mine.reduce(0) { $0 + $1.rateIn }, rateOut: mine.reduce(0) { $0 + $1.rateOut })
            }
            let intervals = state.opens.filter { app.pids.contains($0.key.pid) }.flatMap { _, opens in
                zip(opens.dropFirst(), opens).map { Double($0 - $1) / 1000 }
            }
            return NetDossier(
                app: app, processes: [],
                hosts: Array(hosts.values.sorted { ($0.rateIn + $0.rateOut, $0.bytesIn + $0.bytesOut) > ($1.rateIn + $1.rateOut, $1.bytesIn + $1.bytesOut) }.prefix(60)),
                history: history, intervals: intervals, firstSeen: state.baseline.firstSeen(name),
                countriesKnown: state.baseline.knownCountries(name), usualOut: state.baseline.usualOut(name),
                events: state.events.filter { $0.app == name })
        }
        guard var dossier = found else { return nil }
        // The process tree comes from the kernel, outside the lock.
        dossier.processes = NetProcess.lineage(of: dossier.app.pids)
        return dossier
    }

    /// The numbers for the menu bar and Home.
    public struct Summary: Sendable {
        public var rateIn: Int64 = 0
        public var rateOut: Int64 = 0
        public var active = 0
        public var appsOnline = 0
        public var top: [(name: String, rateIn: Int64, rateOut: Int64)] = []
        public var flagged: [(name: String, score: Int)] = []
        public var capturing = false
        /// Moved since midnight (UTC day, as the ledger keeps it).
        public var todayIn: Int64 = 0
        public var todayOut: Int64 = 0
        /// Alerts in the last 24 hours, and the newest one's text.
        public var alerts = 0
        public var lastAlert: String?
    }

    public func summary() -> Summary {
        state.withLock { state in
            let now = Millis.now
            var out = Summary()
            for tally in state.ledger.since(now: now, days: 1).values {
                out.todayIn += tally.bytesIn
                out.todayOut += tally.bytesOut
            }
            let recent = state.history.filter { $0.severity == .alert && $0.t >= now - 86_400_000 }
            out.alerts = recent.count
            out.lastAlert = recent.last?.text
            let last = state.series.last ?? NetSample()
            out.rateIn = last.bytesIn
            out.rateOut = last.bytesOut
            out.active = last.active
            let rows = apps(state)
            out.appsOnline = rows.count
            out.top = rows.filter { $0.rate > 0 }.prefix(4).map { ($0.name, $0.rateIn, $0.rateOut) }
            out.flagged = rows.filter(\.flagged).sorted { $0.score > $1.score }.prefix(3).map { ($0.name, $0.score) }
            out.capturing = state.capture?.isRunning ?? false
            return out
        }
    }

    /// Names learned for an address from DNS answers or TLS (capture on).
    public func hostName(for ip: String) -> String? { state.withLock { $0.hosts[ip] } }

    /// Remote connections a set of processes opened since `since`, for the
    /// install watch (which follows what a command really talks to).
    public struct ProcessConnection: Sendable, Hashable {
        public var id: Int
        public var pid: Int32
        public var app: String
        public var ip: String
        public var port: UInt16
        public var host: String?
        public var place: Place?
        public var firstSeen: Millis
        public var bytesIn: Int64
        public var bytesOut: Int64
    }

    public func connections(of pids: Set<Int32>, since: Millis) -> [ProcessConnection] {
        state.withLock { state in
            state.conns.values.filter { pids.contains($0.pid) && $0.remote && $0.firstSeen + 2_000 >= since }.map { conn in
                ProcessConnection(id: conn.id, pid: conn.pid, app: state.procs[conn.pid]?.name ?? "pid \(conn.pid)",
                                  ip: conn.socket.remoteIP, port: conn.socket.remotePort, host: state.hosts[conn.socket.remoteIP],
                                  place: conn.place, firstSeen: conn.firstSeen, bytesIn: conn.bytesIn, bytesOut: conn.bytesOut)
            }
        }
    }

    /// The traffic series for widgets and Home (rates per snapshot).
    public func series(last count: Int) -> [NetSample] {
        state.withLock { Array($0.series.elements.suffix(count)) }
    }
}
