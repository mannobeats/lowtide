import Foundation
import Synchronization

/// The network monitor: which app talks to whom, how much and how often,
/// what looks suspicious, and (with capture on) every packet decoded down
/// to DNS names, TLS server names and HTTP requests. Runs from launch to
/// quit; Home, the overnight report and the threat score depend on it.
public final class NetworkEngine: Sendable {
    public static let shared = NetworkEngine()

    let state = Mutex(NetState())
    private let control = Mutex(Control())
    private let demandAt = Atomic<Int64>(0)
    private let boostUntil = Atomic<Int64>(0)
    let geo: GeoIP

    private struct Control {
        var sampler: Task<Void, Never>?
        var signer: Task<Void, Never>?
        var listeners: [UUID: AsyncStream<Void>.Continuation] = [:]
    }

    /// How long a closed connection stays listed.
    static let keepClosedMs: Millis = 10 * 60_000
    static let maxConns = 6_000
    /// An hour of snapshots is kept for replay, the busiest links of each.
    static let keepFramesMs: Millis = 60 * 60_000
    static let frameEdges = 48
    /// "Busiest" ranks by bytes moved over this window.
    static let windowMs: Millis = 5 * 60_000
    /// Snapshot spacing. Each `nettop` snapshot costs ~0.35 s of CPU, so it
    /// runs often only while someone is looking.
    static let watchedMs: Millis = 3_000
    static let backgroundMs: Millis = 10_000
    static let boostedMs: Millis = 1_000

    public init(geo: GeoIP = .shared) {
        self.geo = geo
    }

    // MARK: Running

    /// Starts sampling (once). Loads the memory of normal.
    public func start() {
        control.withLock { control in
            guard control.sampler == nil else { return }
            control.sampler = Task.detached(priority: .utility) { [self] in await sampleLoop() }
            control.signer = Task.detached(priority: .background) { [self] in await signatureLoop() }
        }
    }

    /// Stops sampling (killing a running `nettop`) and any capture, and
    /// saves the memory of normal.
    public func stop() {
        control.withLock { control in
            control.sampler?.cancel()
            control.signer?.cancel()
            control.sampler = nil
            control.signer = nil
        }
        // Quitting: the capture thread ends with the process.
        state.withLock { $0.capture }?.stop()
        save(force: true)
    }

    public var running: Bool { control.withLock { $0.sampler != nil } }

    /// A page that shows network data is on screen: sample every few seconds.
    public func demand() { demandAt.store(.now, ordering: .relaxed) }

    /// Follows a running command closely for the next few seconds (short
    /// connections of an installer are caught).
    public func boost() { boostUntil.store(.now + 3_000, ordering: .relaxed) }

    /// A signal after every snapshot.
    public func updates() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        control.withLock { $0.listeners[id] = continuation }
        continuation.onTermination = { [weak self] _ in self?.control.withLock { _ = $0.listeners.removeValue(forKey: id) } }
        return stream
    }

    func notify() {
        for listener in control.withLock({ Array($0.listeners.values) }) { listener.yield() }
    }

    private func sampleLoop() async {
        await Shell.ready()
        let selfID = ProcTable.path(getpid()).map { Nettop.appBundle($0) ?? $0 }
        state.withLock { state in
            state.selfID = selfID
            state.baseline.load(now: .now, from: JSONStore.load(Baseline.Memory.self, from: Baseline.file))
            state.ledger.data = JSONStore.load(Ledger.Days.self, from: Ledger.file) ?? Ledger.Days()
            state.ledger.loaded = true
            state.ledger.savedAt = .now
        }
        var last: Millis = 0
        var first = true
        while !Task.isCancelled {
            let now = Millis.now
            let every = now < boostUntil.load(ordering: .relaxed) ? Self.boostedMs
                : now - demandAt.load(ordering: .relaxed) < 5_000 ? Self.watchedMs : Self.backgroundMs
            if now - last >= every {
                do {
                    let out = try await Shell.run("/usr/bin/nettop", Nettop.arguments, timeout: .seconds(20))
                    guard !Task.isCancelled else { break }
                    let rows = Nettop.parse(out.stdout)
                    // The first snapshot seeds byte counters; rates start with the second.
                    commit(rows, first: first, elapsed: max(1, now - last), now: .now)
                    first = false
                    save(force: false)
                    notify()
                } catch {
                    if !Task.isCancelled { Log.network.error("nettop: \(error.localizedDescription, privacy: .public)") }
                }
                last = now
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Saves the baseline and the ledger every five minutes (and at quit),
    /// writing outside the lock.
    func save(force: Bool) {
        let now = Millis.now
        let (memory, ledger) = state.withLock { state -> (Baseline.Memory?, Ledger.Days?) in
            var memory: Baseline.Memory?
            var ledger: Ledger.Days?
            if state.baseline.loaded, state.baseline.dirty, force || now - state.baseline.savedAt >= 5 * 60_000 {
                memory = state.baseline.memory
                state.baseline.dirty = false
                state.baseline.savedAt = now
            }
            if state.ledger.loaded, state.ledger.dirty, force || now - state.ledger.savedAt >= 5 * 60_000 {
                state.ledger.prune(now: now)
                ledger = state.ledger.data
                state.ledger.dirty = false
                state.ledger.savedAt = now
            }
            return (memory, ledger)
        }
        if let memory { JSONStore.save(memory, to: Baseline.file) }
        if let ledger { JSONStore.save(ledger, to: Ledger.file) }
    }

    // MARK: Snapshots

    static func perSecond(_ bytes: Int64, _ elapsed: Millis) -> Int64 { bytes * 1000 / max(1, elapsed) }

    /// Folds one `nettop` snapshot into the state.
    func commit(_ rows: [NettopRow], first: Bool, elapsed: Millis, now: Millis) {
        let lookups = Dictionary(rows.lazy.filter { !$0.socket.listening && !$0.socket.loopback }
            .map { ($0.socket.remoteIP, ()) }, uniquingKeysWith: { a, _ in a })
        // Geo lookups and process paths happen before taking the lock.
        var places: [String: Place] = [:]
        for ip in lookups.keys { if let place = geo.lookup(ip) { places[ip] = place } }
        let known = state.withLock { state in Set(state.procs.values.map { "\($0.pid) \($0.rawName)" }) }
        var newProcs: [Int32: (String, String?)] = [:]
        for row in rows where !known.contains("\(row.pid) \(row.name)") && newProcs[row.pid] == nil {
            newProcs[row.pid] = (row.name, ProcTable.path(row.pid))
        }
        state.withLock { state in
            commit(&state, rows: rows, first: first, elapsed: elapsed, now: now, places: places, newProcs: newProcs)
        }
    }

    func commit(_ state: inout NetState, rows: [NettopRow], first: Bool, elapsed: Millis, now: Millis,
                places: [String: Place], newProcs: [Int32: (String, String?)]) {
        var seen: Set<String> = []
        var sample = NetSample()
        sample.t = now
        var portOwner: [PortKey: Int32] = [:]
        for pid in state.procs.keys {
            state.procs[pid]?.rateIn = 0
            state.procs[pid]?.rateOut = 0
        }
        for row in rows {
            let key = "\(row.pid) \(row.socket.key)"
            seen.insert(key)
            portOwner[PortKey(proto: row.socket.proto, port: row.socket.localPort)] = row.pid
            ensureProcess(&state, pid: row.pid, name: row.name, path: newProcs[row.pid]?.1, now: now)
            // nettop reports totals since each socket opened; what moved since
            // the last snapshot is the difference (all of it for a new socket).
            let previous = state.conns[key]
            let movedIn = max(0, row.bytesIn - (previous?.bytesIn ?? 0))
            let movedOut = max(0, row.bytesOut - (previous?.bytesOut ?? 0))
            let rateIn = first ? 0 : Self.perSecond(movedIn, elapsed)
            let rateOut = first ? 0 : Self.perSecond(movedOut, elapsed)
            let outward = !row.socket.listening && !row.socket.loopback
            if outward {
                sample.bytesIn += rateIn
                sample.bytesOut += rateOut
                if let rtt = row.rttMin ?? row.rttAvg, row.socket.proto == "tcp", let prefix = GeoIP.prefix(row.socket.remoteIP) {
                    state.rttByPrefix[prefix] = min(state.rttByPrefix[prefix] ?? .infinity, rtt)
                }
            }
            if !first, outward, let proc = state.procs[row.pid] {
                state.baseline.addUpload(proc.name, movedOut)
                let place = previous?.place ?? places[row.socket.remoteIP]
                let host = state.hosts[row.socket.remoteIP]
                state.ledger.add(now: now, app: proc.name, country: place?.country, host: host, bytesIn: movedIn, bytesOut: movedOut)
                state.away?.add(app: proc.name, country: place?.country, host: host, bytesIn: movedIn, bytesOut: movedOut)
                if movedIn + movedOut > 0 { state.window[proc.identity, default: []].append((now, movedIn + movedOut)) }
            }
            if var proc = state.procs[row.pid] {
                proc.bytesIn += movedIn
                proc.bytesOut += movedOut
                proc.rateIn += rateIn
                proc.rateOut += rateOut
                proc.lastSeen = now
                if row.socket.listening, row.socket.proto == "tcp", !row.socket.localIP.hasPrefix("127."), row.socket.localIP != "::1" {
                    proc.listens.insert(row.socket.localPort)
                }
                state.procs[row.pid] = proc
            }
            if var conn = previous {
                conn.bytesIn = row.bytesIn
                conn.bytesOut = row.bytesOut
                conn.rateIn = rateIn
                conn.rateOut = rateOut
                conn.state = row.state
                conn.rttMin = row.rttMin ?? conn.rttMin
                conn.rttAvg = row.rttAvg ?? conn.rttAvg
                conn.lastSeen = now
                conn.closedAt = nil
                state.conns[key] = conn
            } else {
                if !first, !row.socket.listening {
                    sample.newConns += 1
                    let open = OpenKey(pid: row.pid, remote: row.socket.remoteIP)
                    state.opens[open, default: []].append(now)
                    if state.opens[open]!.count > 12 { state.opens[open]!.removeFirst() }
                }
                state.nextID += 1
                state.conns[key] = ConnRecord(
                    id: state.nextID, pid: row.pid, socket: row.socket, iface: row.iface, state: row.state,
                    rttMin: row.rttMin, rttAvg: row.rttAvg, bytesIn: row.bytesIn, bytesOut: row.bytesOut,
                    rateIn: rateIn, rateOut: rateOut, firstSeen: now, lastSeen: now, closedAt: nil,
                    preexisting: first, place: row.socket.listening ? nil : places[row.socket.remoteIP])
            }
        }
        for (key, conn) in state.conns where conn.open && !seen.contains(key) {
            state.conns[key]?.closedAt = now
            state.conns[key]?.rateIn = 0
            state.conns[key]?.rateOut = 0
        }
        state.conns = state.conns.filter { $0.value.closedAt.map { now - $0 < Self.keepClosedMs } ?? true }
        if state.conns.count > Self.maxConns {
            let closed = state.conns.compactMap { key, conn in conn.closedAt.map { ($0, key) } }.sorted { $0.0 < $1.0 }
            for (_, key) in closed.prefix(state.conns.count - Self.maxConns) { state.conns.removeValue(forKey: key) }
        }
        state.procs = state.procs.filter { now - $0.value.lastSeen < Self.keepClosedMs }
        state.opens = state.opens.filter { ($0.value.last ?? 0) > now - 30 * 60_000 }
        state.window = state.window.compactMapValues { list in
            let kept = list.filter { $0.t > now - Self.windowMs }
            return kept.isEmpty ? nil : kept
        }
        if state.rttByPrefix.count > 20_000 { state.rttByPrefix.removeAll() }
        state.portOwner = portOwner
        sample.active = state.conns.values.filter { $0.open && !$0.socket.listening }.count
        // Counted by the packet capture since the last snapshot; per second.
        func rate(_ count: Int) -> Int { Int(Self.perSecond(Int64(count), elapsed)) }
        sample.packets = rate(state.pendingPackets)
        sample.dns = rate(state.pendingDNS)
        sample.http = rate(state.pendingHTTP)
        sample.newConns = rate(sample.newConns)
        state.pendingPackets = 0
        state.pendingDNS = 0
        state.pendingHTTP = 0
        state.edgePackets = state.pendingEdgePackets.mapValues(rate)
        state.pendingEdgePackets = [:]
        if !first { recordFrame(&state, sample) }
        state.series.append(sample)
        state.sampled = true
        observe(&state, now: now)
    }

    private func ensureProcess(_ state: inout NetState, pid: Int32, name: String, path: String?, now: Millis) {
        // A pid reused by another program shows up under a new name.
        if state.procs[pid]?.rawName == name { return }
        let path = path ?? ProcTable.path(pid)
        let app = path.flatMap(Nettop.appBundle)
        let display = app.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
            ?? path.map(Nettop.toolName) ?? name
        var signature = Signature.pending
        if let path {
            if let known = state.signatures[path] { signature = known } else if !state.signatureQueue.contains(path) {
                state.signatureQueue.append(path)
            }
        }
        state.procs[pid] = ProcRecord(pid: pid, rawName: name, name: display, path: path, app: app,
                                      signature: signature, lastSeen: now)
    }

    /// Remembers which links moved data in this snapshot.
    private func recordFrame(_ state: inout NetState, _ sample: NetSample) {
        var edges: [OpenKey: FrameEdge] = [:]
        for conn in state.conns.values where conn.rateIn + conn.rateOut > 0 && conn.remote {
            guard let proc = state.procs[conn.pid] else { continue }
            let host = state.hosts[conn.socket.remoteIP] ?? conn.socket.remoteIP
            let key = OpenKey(pid: conn.pid, remote: host)
            var edge = edges[key] ?? FrameEdge(app: proc.name, host: host, place: conn.place, rtt: nil, rateIn: 0, rateOut: 0)
            edge.rateIn += conn.rateIn
            edge.rateOut += conn.rateOut
            if let rtt = conn.rttMin ?? conn.rttAvg { edge.rtt = min(edge.rtt ?? .infinity, Float(rtt)) }
            edges[key] = edge
        }
        let busiest = edges.values.sorted { $0.rateIn + $0.rateOut > $1.rateIn + $1.rateOut }.prefix(Self.frameEdges)
        state.frames.append(Frame(t: sample.t, rateIn: sample.bytesIn, rateOut: sample.bytesOut, edges: Array(busiest)))
        if let cut = state.frames.firstIndex(where: { sample.t - $0.t <= Self.keepFramesMs }), cut > 0 {
            state.frames.removeFirst(cut)
        }
    }

    // MARK: Signatures

    private func signatureLoop() async {
        while !Task.isCancelled {
            let next = state.withLock { state -> String? in
                while let path = state.signatureQueue.first {
                    state.signatureQueue.removeFirst()
                    if state.signatures[path] == nil { return path }
                }
                return nil
            }
            guard let path = next else {
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }
            let signature: Signature
            if let out = try? await Shell.run("/usr/bin/codesign", ["-dv", "--verbose=2", path], timeout: .seconds(20)) {
                signature = Nettop.parseSignature(out.stderr)
            } else {
                signature = .unknown
            }
            state.withLock { state in
                state.signatures[path] = signature
                for (pid, proc) in state.procs where proc.path == path { state.procs[pid]?.signature = signature }
            }
        }
    }

    // MARK: Events

    /// Adds an event to the shared log (the timeline, the dossier, the
    /// overnight report, notifications). Other spaces raise theirs here.
    public func push(_ event: NetEvent) {
        state.withLock { Self.add(&$0, event) }
        notify()
    }

    static func add(_ state: inout NetState, _ event: NetEvent) {
        var event = event
        state.nextEvent += 1
        event.id = state.nextEvent
        state.away?.events.append(event)
        state.history.append(event)
        let week = event.t - 7 * 86_400_000
        if state.history.count > 3_000 || (state.history.first?.t ?? event.t) < week {
            state.history.removeAll { $0.t < week }
            if state.history.count > 3_000 { state.history.removeFirst(state.history.count - 3_000) }
        }
        state.events.append(event)
        if state.events.count > 1_000 { state.events.removeFirst(state.events.count - 1_000) }
    }

    /// Learns from the current state and records what breaks the pattern.
    private func observe(_ state: inout NetState, now: Millis) {
        guard state.baseline.loaded else { return }
        var online: [String: Set<Baseline.CountryVia>] = [:]
        for conn in state.conns.values where conn.open && conn.remote {
            guard let proc = state.procs[conn.pid] else { continue }
            var places = online[proc.name] ?? []
            if let country = conn.place?.country { places.insert(.init(country: country, org: conn.place?.org)) }
            online[proc.name] = places
        }
        var found = state.baseline.observe(online: online, now: now)
        for row in apps(state) where row.flagged && state.baseline.flagged.insert(row.name).inserted {
            let why = row.reasons.first?.label.lowercased() ?? ""
            found.append(NetEvent(t: now, kind: "flagged", severity: .alert, app: row.name,
                                  text: "\(row.name) looks suspicious (\(row.score)): \(why)"))
        }
        for event in found { Self.add(&state, event) }
        let hourAgo = now - Self.keepFramesMs
        if let cut = state.events.firstIndex(where: { $0.t >= hourAgo }) {
            if cut > 0 { state.events.removeFirst(cut) }
        } else {
            state.events.removeAll()
        }
    }

    /// Alerts newer than `id`, for notifications while the window is hidden.
    public func alerts(after id: Int) -> [NetEvent] {
        state.withLock { $0.events.filter { $0.id > id && $0.severity == .alert } }
    }

    public var lastEventID: Int { state.withLock { $0.nextEvent } }

    /// Every event of the last `days` (the assistant reads these).
    public func history(since t: Millis) -> [NetEvent] {
        state.withLock { $0.history.filter { $0.t >= t } }
    }

    /// Every app's traffic over the last `days` days, from the ledger.
    public func ledger(days: Int) -> [String: Tally] {
        state.withLock { $0.ledger.since(now: .now, days: days) }
    }
}
