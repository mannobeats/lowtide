import Foundation

/// Milliseconds since 1970, the unit every network timestamp uses (and the
/// one its saved files use).
public typealias Millis = Int64

public extension Millis {
    static var now: Millis { Millis(Date().timeIntervalSince1970 * 1000) }
    var date: Date { Date(timeIntervalSince1970: Double(self) / 1000) }
}

/// Who signed an app's binary.
public enum Signature: Sendable, Hashable, Codable {
    case pending, apple, appStore, developer(String), development(String), adHoc, unsigned, unknown

    public var label: String {
        switch self {
        case .apple: "Apple"
        case .appStore: "App Store"
        case .developer(let who): who.replacingOccurrences(of: #" \([A-Z0-9]+\)$"#, with: "", options: .regularExpression)
        case .development(let who): "Development build · \(who)"
        case .adHoc: "Ad hoc signature"
        case .unsigned: "Not signed"
        case .pending: "Checking signature…"
        case .unknown: "Unknown signature"
        }
    }
}

/// One reason in a threat score.
public struct ScoreReason: Sendable, Hashable, Codable {
    public var label: String
    public var points: Int
}

/// Something that broke the pattern: for the timeline, the dossier and the
/// overnight report. Other spaces raise their own (`tripwire`, `canary`…).
public struct NetEvent: Sendable, Hashable, Codable, Identifiable {
    public enum Severity: String, Sendable, Codable { case notice, alert }
    public var id: Int
    public var t: Millis
    /// `firstApp`, `newCountry`, `uploadSpike`, `flagged`, and from other
    /// features `tripwire`, `canary`, `exposure`, `fleet`, `away`.
    public var kind: String
    public var severity: Severity
    public var app: String
    public var text: String
    public var country: String?

    public init(t: Millis, kind: String, severity: Severity, app: String, text: String, country: String? = nil) {
        id = 0
        self.t = t
        self.kind = kind
        self.severity = severity
        self.app = app
        self.text = text
        self.country = country
    }
}

/// The whole Mac's traffic at one snapshot (rates per second).
public struct NetSample: Sendable, Hashable, Codable {
    public var t: Millis = 0
    public var bytesIn: Int64 = 0
    public var bytesOut: Int64 = 0
    /// Connections opened per second: the closest thing to requests a
    /// second without looking inside the traffic.
    public var newConns: Int = 0
    public var active: Int = 0
    public var packets: Int = 0
    public var dns: Int = 0
    public var http: Int = 0
    public init() {}
}

/// One DNS lookup seen in captured packets.
public struct DNSRecord: Sendable, Hashable, Identifiable {
    public var id: Int
    public var t: Millis
    public var name: String
    public var qtype: String
    public var answers: [String]
    /// `NOERROR`, `NXDOMAIN`… (nil for a query not yet answered).
    public var rcode: String?
    public var server: String
    public var suspicious: String?
}

/// An app on the network: its processes together (Chrome's helpers count as Chrome).
public struct NetApp: Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    /// The `.app` bundle, for its icon.
    public var app: String?
    public var path: String?
    public var pids: [Int32]
    public var signature: Signature
    public var rateIn: Int64
    public var rateOut: Int64
    public var bytesIn: Int64
    public var bytesOut: Int64
    /// Moved over the last five minutes: what "busiest" ranks by.
    public var recentBytes: Int64
    public var conns: Int
    public var hosts: Int
    public var listens: [UInt16]
    public var score: Int
    public var reasons: [ScoreReason]

    public var rate: Int64 { rateIn + rateOut }
    public var flagged: Bool { score >= ThreatScore.flag }
}

/// One app's traffic to one server name, for the map.
public struct NetEdge: Sendable, Hashable, Identifiable {
    public var app: String
    public var host: String
    public var ip: String
    public var port: UInt16
    public var proto: String
    public var rateIn: Int64
    public var rateOut: Int64
    /// Packets in the last second while capturing, else 0.
    public var packets: Int
    public var conns: Int
    public var country: String?
    public var org: String?
    public var asn: UInt32?
    /// The shortest round trip measured to it (or to its network).
    public var rttMs: Double?
    public var id: String { "\(app)|\(host)" }
}

/// One socket, as the Connections view lists it.
public struct NetConn: Sendable, Hashable, Identifiable {
    public var id: Int
    public var pid: Int32
    public var app: String
    public var appID: String
    public var appPath: String?
    public var proto: String
    public var local: String
    public var localPort: UInt16
    public var remote: String
    public var remotePort: UInt16
    public var host: String?
    public var service: String?
    public var state: String
    public var iface: String
    public var rttMs: Double?
    public var bytesIn: Int64
    public var bytesOut: Int64
    public var rateIn: Int64
    public var rateOut: Int64
    public var firstSeen: Millis
    public var closedAt: Millis?
    public var listening: Bool
    public var country: String?
    public var org: String?
    public var asn: UInt32?
    public var rate: Int64 { rateIn + rateOut }
}

/// How this Mac reaches the internet.
public struct NetLink: Sendable, Hashable {
    public var interface: String?
    public var ip: String?
    public var gateway: String?
    public var dns: String?
    /// The default route goes through a tunnel (`utun`, `ipsec`).
    public var vpn = false
    public init(interface: String? = nil, ip: String? = nil, gateway: String? = nil, dns: String? = nil, vpn: Bool = false) {
        self.interface = interface
        self.ip = ip
        self.gateway = gateway
        self.dns = dns
        self.vpn = vpn
    }
}

public struct CaptureStatus: Sendable, Hashable {
    public var running = false
    /// `/dev/bpf*` is readable by this user, so capture can start.
    public var permitted = false
    public var interface: String?
    public var error: String?
    public var packets: Int = 0
    public var dropped: Int = 0
    public var stored: Int = 0
    public init() {}
}

/// Everything the Live page shows, from one snapshot.
public struct NetOverview: Sendable {
    public var series: [NetSample] = []
    public var apps: [NetApp] = []
    public var edges: [NetEdge] = []
    public var recent: [NetConn] = []
    public var domainAlerts: [DNSRecord] = []
    public var capture = CaptureStatus()
    /// Distinct servers with an open connection.
    public var hosts = 0
    public var events: [NetEvent] = []
    /// Still learning what's normal (the first ten minutes of memory).
    public var learning = false
    /// At least one snapshot has been taken.
    public var ready = false
    public init() {}
}

public struct TimelinePoint: Sendable, Hashable {
    public var t: Millis
    public var rateIn: Int64
    public var rateOut: Int64
}

public struct NetTimeline: Sendable {
    public var points: [TimelinePoint] = []
    public var events: [NetEvent] = []
    public init() {}
}

/// The map as it was at one moment of the last hour.
public struct NetFrameView: Sendable {
    public var t: Millis
    public var edges: [NetEdge]
}

public struct ProcNode: Sendable, Hashable, Identifiable {
    public var pid: Int32
    public var ppid: Int32
    public var name: String
    /// One of the app's own processes (not an ancestor).
    public var own: Bool
    public var id: Int32 { pid }
}

public struct DossierHost: Sendable, Hashable, Identifiable {
    public var host: String
    public var ip: String
    public var port: UInt16
    public var service: String?
    public var country: String?
    public var org: String?
    public var asn: UInt32?
    public var rttMs: Double?
    public var bytesIn: Int64
    public var bytesOut: Int64
    public var rateIn: Int64
    public var rateOut: Int64
    public var conns: Int
    public var id: String { host }
}

/// Everything known about one app.
public struct NetDossier: Sendable {
    public var app: NetApp
    public var processes: [ProcNode]
    public var hosts: [DossierHost]
    /// Its traffic at every snapshot of the last hour.
    public var history: [TimelinePoint]
    /// Seconds between connections it opened to the same server: a regular
    /// rhythm is a beacon.
    public var intervals: [Double]
    public var firstSeen: Millis?
    public var countriesKnown: Int
    /// Its usual upload per minute, once there's enough history.
    public var usualOut: Double?
    public var events: [NetEvent]
}

/// Well-known services by port.
public enum NetService {
    public static func name(_ port: UInt16) -> String? {
        switch port {
        case 20, 21: "ftp"
        case 22: "ssh"
        case 25, 465, 587: "smtp"
        case 53: "dns"
        case 67, 68: "dhcp"
        case 80, 8080: "http"
        case 110, 995: "pop3"
        case 123: "ntp"
        case 143, 993: "imap"
        case 443, 8443: "https"
        case 853: "dns-over-tls"
        case 1900: "ssdp"
        case 3478, 3479: "stun"
        case 5223: "apple-push"
        case 5353: "mdns"
        default: nil
        }
    }
}
