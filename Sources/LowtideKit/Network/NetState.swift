import Foundation

/// A fixed-capacity buffer that drops its oldest items.
struct Ring<Element> {
    private var storage: [Element] = []
    private var head = 0
    let capacity: Int

    init(capacity: Int) { self.capacity = capacity }

    var count: Int { storage.count }
    var isEmpty: Bool { storage.isEmpty }

    mutating func append(_ item: Element) {
        if storage.count < capacity {
            storage.append(item)
        } else {
            storage[head] = item
            head = (head + 1) % capacity
        }
    }

    /// Oldest first.
    var elements: [Element] {
        storage.count < capacity ? storage : Array(storage[head...] + storage[..<head])
    }

    /// Newest first, lazily.
    var newestFirst: some Sequence<Element> {
        let n = storage.count
        let start = storage.count < capacity ? 0 : head
        return (0..<n).lazy.map { [storage] i in storage[(start + n - 1 - i) % n] }
    }

    var last: Element? {
        guard !storage.isEmpty else { return nil }
        return storage.count < capacity ? storage.last : storage[(head + capacity - 1) % capacity]
    }

    mutating func removeAll() {
        storage.removeAll()
        head = 0
    }
}

struct ProcRecord {
    var pid: Int32
    /// nettop's (truncated) name, to notice a reused pid.
    var rawName: String
    var name: String
    var path: String?
    var app: String?
    var signature: Signature
    var lastSeen: Millis
    var bytesIn: Int64 = 0
    var bytesOut: Int64 = 0
    var rateIn: Int64 = 0
    var rateOut: Int64 = 0
    /// TCP ports it accepts connections on from the network.
    var listens: Set<UInt16> = []

    /// Everything grouped under one app: Chrome's helpers count as Chrome.
    var identity: String { app ?? path ?? name }
}

struct ConnRecord {
    var id: Int
    var pid: Int32
    var socket: NetSocket
    var iface: String
    var state: String
    var rttMin: Double?
    var rttAvg: Double?
    var bytesIn: Int64
    var bytesOut: Int64
    var rateIn: Int64
    var rateOut: Int64
    var firstSeen: Millis
    var lastSeen: Millis
    var closedAt: Millis?
    /// Open at launch: opened before we were watching.
    var preexisting: Bool
    var place: Place?

    var open: Bool { closedAt == nil }
    /// A connection out to the internet or the LAN (not a listener, not loopback).
    var remote: Bool { !socket.listening && !socket.loopback }
}

/// One link's traffic at one snapshot, for replay.
struct FrameEdge {
    var app: String
    var host: String
    var place: Place?
    var rtt: Float?
    var rateIn: Int64
    var rateOut: Int64
}

/// The map at one snapshot: total rates and the links that moved.
struct Frame {
    var t: Millis
    var rateIn: Int64
    var rateOut: Int64
    var edges: [FrameEdge]
}

struct CapturedPacket {
    var seq: Int
    var t: Millis
    var length: Int
    /// `in`, `out`, or `local` (neither side is this Mac).
    var direction: String
    var proto: String
    var app: String
    var src: String
    var sport: UInt16
    var dst: String
    var dport: UInt16
    var flags: String
    var info: String
    var pid: Int32?
    var link: Int32
    var bytes: [UInt8]
}

struct OpenKey: Hashable {
    var pid: Int32
    var remote: String
}

struct PortKey: Hashable {
    var proto: String
    var port: UInt16
}

/// Everything the monitor knows, behind one lock.
struct NetState {
    var procs: [Int32: ProcRecord] = [:]
    var conns: [String: ConnRecord] = [:]
    var series = Ring<NetSample>(capacity: 300)
    var nextID = 0
    /// When each (pid, remote) pair opened its last connections: beacons.
    var opens: [OpenKey: [Millis]] = [:]
    /// Names learned from DNS answers and TLS server names, by IP.
    var hosts: [String: String] = [:]
    var dns = Ring<DNSRecord>(capacity: 5_000)
    var dnsSeq = 0
    var packets = Ring<CapturedPacket>(capacity: 20_000)
    var packetSeq = 0
    var portOwner: [PortKey: Int32] = [:]
    var pendingPackets = 0
    var pendingDNS = 0
    var pendingHTTP = 0
    var pendingEdgePackets: [OpenKey: Int] = [:]
    var edgePackets: [OpenKey: Int] = [:]
    var signatures: [String: Signature] = [:]
    var signatureQueue: [String] = []
    var baseline = Baseline()
    var ledger = Ledger()
    /// Every event for a week (the timeline keeps an hour).
    var history: [NetEvent] = []
    /// Set while nobody is at the Mac: the night shift's tally.
    var away: AwayTally?
    var events: [NetEvent] = []
    var nextEvent = 0
    var frames: [Frame] = []
    /// The best round trip seen per network (/24, /48), so a QUIC or UDP
    /// flow without its own measurement can borrow one.
    var rttByPrefix: [String: Double] = [:]
    /// Bytes each app moved per snapshot over the last minutes.
    var window: [String: [(t: Millis, bytes: Int64)]] = [:]
    var sampled = false
    var selfID: String?
    var capture: CaptureSession?
}
