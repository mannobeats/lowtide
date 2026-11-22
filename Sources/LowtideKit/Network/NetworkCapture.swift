import Foundation

/// A packet as the Packets page lists it.
public struct PacketRow: Sendable, Hashable, Identifiable {
    public var seq: Int
    public var t: Millis
    public var length: Int
    public var direction: String
    public var proto: String
    public var app: String
    public var src: String
    public var sport: UInt16
    public var dst: String
    public var dport: UInt16
    /// The far side's name, from DNS or TLS.
    public var host: String?
    public var info: String
    public var flags: String
    public var process: String?
    public var id: Int { seq }
}

public struct PacketPage: Sendable {
    public var rows: [PacketRow] = []
    /// Packets in memory, matched or not.
    public var stored = 0
    /// Of those, how many the filter matched.
    public var matched = 0
    public init() {}
}

public struct PacketDetail: Sendable {
    public var row: PacketRow
    public var layers: [PacketLayer]
    /// The first bytes of the frame, as captured.
    public var bytes: [UInt8]
}

/// Packet capture (libpcap): packets tied to the app that owns their local
/// port, decoded and kept in a ring of the newest 20,000.
extension NetworkEngine {
    /// Bytes of each frame kept for the hex view.
    static let keepBytes = 256

    func captureStatus(_ state: NetState) -> CaptureStatus {
        var status = CaptureStatus()
        status.permitted = CaptureAccess.permitted
        status.stored = state.packets.count
        if let session = state.capture {
            let stats = session.stats.withLock { $0 }
            status.running = session.isRunning
            status.interface = session.interface
            status.packets = stats.received
            status.dropped = stats.dropped
            status.error = stats.error
        }
        return status
    }

    public func captureStatus() -> CaptureStatus { state.withLock { captureStatus($0) } }

    /// The interface the default route uses.
    static func defaultInterface() async -> String? {
        guard let out = try? await Shell.run("/sbin/route", ["-n", "get", "default"], timeout: .seconds(5)) else { return nil }
        return out.stdout.split(separator: "\n").lazy.compactMap { line -> String? in
            let text = line.trimmingCharacters(in: .whitespaces)
            return text.hasPrefix("interface: ") ? String(text.dropFirst(11)) : nil
        }.first
    }

    /// Starts capturing on `interface` (default: the default route's).
    public func startCapture(interface: String? = nil) async throws {
        if state.withLock({ $0.capture?.isRunning ?? false }) { return }
        start()
        var chosen = interface
        if chosen == nil { chosen = await Self.defaultInterface() }
        guard let name = chosen else {
            throw LowtideError.commandFailed("No network interface is up.")
        }
        guard name.allSatisfy({ $0.isLetter || $0.isNumber }) else { throw LowtideError.invalid("That isn't an interface name.") }
        guard let device = PCap.interfaces().first(where: { $0.name == name }) else {
            throw LowtideError.notFound("Interface \(name)")
        }
        let session = CaptureSession(interface: name, local: Set(device.addresses))
        try session.start { [weak self] packet in self?.record(packet, local: session.local) }
        state.withLock { $0.capture = session }
        notify()
    }

    /// Stops the capture and waits (up to a second) for its thread to end,
    /// so the overview reports it stopped.
    public func stopCapture() async {
        let session = state.withLock { $0.capture }
        session?.stop()
        for _ in 0..<20 where session?.isRunning == true { try? await Task.sleep(for: .milliseconds(50)) }
        notify()
    }

    /// Decodes a captured frame outside the lock, then files it.
    func record(_ packet: CaptureSession.Packet, local: Set<String>) {
        guard let frame = PacketDecoder.decode(link: packet.link, packet.bytes) else { return }
        let src = frame.sourceText, dst = frame.destinationText
        let direction = local.contains(src) ? "out" : local.contains(dst) ? "in" : "local"
        let remote = direction == "in" ? src : dst
        let localPort = direction == "in" ? frame.dport : frame.sport
        let payload = packet.bytes[frame.payload]
        let kind = PacketDecoder.classify(proto: frame.proto, sport: frame.sport, dport: frame.dport, payload: payload)
        let info = !kind.info.isEmpty ? kind.info
            : frame.proto == "TCP" ? "\(frame.sport) → \(frame.dport) [\(frame.flags)] \(payload.count) bytes"
            : frame.proto == "UDP" ? "\(frame.sport) → \(frame.dport) \(payload.count) bytes" : frame.proto
        state.withLock { state in
            // nettop lists QUIC flows apart from plain UDP sockets.
            let keys = frame.proto == "TCP" ? ["tcp"] : ["udp", "quic"]
            var pid: Int32?
            if direction != "local" {
                for key in keys where pid == nil { pid = state.portOwner[PortKey(proto: key, port: localPort)] }
            }
            state.pendingPackets += 1
            if let pid { state.pendingEdgePackets[OpenKey(pid: pid, remote: remote), default: 0] += 1 }
            if kind.request { state.pendingHTTP += 1 }
            if let name = kind.sni { remember(&state, ip: remote, name: name) }
            if kind.app == "DNS", let dns = kind.dns {
                if !dns.response { state.pendingDNS += 1 }
                for answer in dns.answers where MMDBReader.parse(answer) != nil { remember(&state, ip: answer, name: dns.name) }
                state.dnsSeq += 1
                state.dns.append(DNSRecord(id: state.dnsSeq, t: packet.t, name: dns.name, qtype: dns.qtype, answers: dns.answers,
                                           rcode: dns.response ? dns.rcode : nil, server: dns.response ? src : dst,
                                           suspicious: ThreatScore.oddDomain(dns.name)))
            }
            state.packetSeq += 1
            state.packets.append(CapturedPacket(
                seq: state.packetSeq, t: packet.t, length: packet.length, direction: direction, proto: frame.proto, app: kind.app,
                src: src, sport: frame.sport, dst: dst, dport: frame.dport, flags: frame.flags, info: info, pid: pid,
                link: packet.link, bytes: Array(packet.bytes.prefix(Self.keepBytes))))
        }
    }

    private func remember(_ state: inout NetState, ip: String, name: String) {
        if state.hosts.count > 50_000 { state.hosts.removeAll() }
        state.hosts[ip] = name
    }

    private func row(_ state: NetState, _ p: CapturedPacket) -> PacketRow {
        let remote = p.direction == "in" ? p.src : p.dst
        return PacketRow(seq: p.seq, t: p.t, length: p.length, direction: p.direction, proto: p.proto, app: p.app,
                         src: p.src, sport: p.sport, dst: p.dst, dport: p.dport, host: state.hosts[remote], info: p.info,
                         flags: p.flags, process: p.pid.flatMap { state.procs[$0]?.name })
    }

    /// The newest `limit` packets matching `filter`, older than `before`
    /// when given (for scrolling back), oldest first.
    public func packets(filter text: String, before: Int? = nil, limit: Int = 500) -> PacketPage {
        let filter = PacketFilter(text)
        let limit = min(limit, 5_000)
        return state.withLock { locked in
            let state = locked
            var page = PacketPage()
            page.stored = state.packets.count
            for packet in state.packets.newestFirst {
                if let before, packet.seq >= before { continue }
                if !filter.terms.isEmpty {
                    let names = { (ip: String) in "\(ip) \(state.hosts[ip] ?? "")".lowercased() }
                    let subject = PacketFilter.Subject(
                        proto: packet.proto, app: packet.app, direction: packet.direction, sport: packet.sport, dport: packet.dport,
                        length: packet.length, info: packet.info, sourceNames: names(packet.src), destinationNames: names(packet.dst),
                        process: packet.pid.flatMap { state.procs[$0]?.name.lowercased() })
                    guard filter.matches(subject) else { continue }
                }
                page.matched += 1
                if page.rows.count < limit { page.rows.append(row(state, packet)) }
            }
            page.rows.reverse()
            return page
        }
    }

    public func packet(seq: Int) -> PacketDetail? {
        state.withLock { state in
            guard let packet = state.packets.newestFirst.first(where: { $0.seq == seq }) else { return nil }
            return PacketDetail(row: row(state, packet),
                                layers: PacketDecoder.layers(link: packet.link, packet.bytes, app: packet.app, info: packet.info),
                                bytes: packet.bytes)
        }
    }
}
