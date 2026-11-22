import Foundation

/// The packet filter language: `tcp dns in port:443,8443 host:apple
/// app:chrome len>1000 -mdns text`. Every term must match; `-` or `!`
/// negates; commas mean "any of".
public struct PacketFilter: Sendable, Equatable {
    public enum Term: Sendable, Equatable {
        case proto([String])
        case app([String])
        case direction(String)
        case port([UInt16])
        case host([String])
        case process([String])
        case lenOver(Int)
        case lenUnder(Int)
        case text(String)
    }

    public var terms: [(negate: Bool, term: Term)]

    static let protos: Set<String> = ["tcp", "udp", "icmp", "icmpv6"]
    static let apps: Set<String> = ["dns", "mdns", "tls", "http", "quic", "ntp", "dhcp", "ssdp", "ssh"]

    public init(_ text: String) {
        terms = text.split(whereSeparator: \.isWhitespace).compactMap { raw in
            var token = Substring(raw)
            var negate = false
            if (token.hasPrefix("-") || token.hasPrefix("!")), token.count > 1 {
                negate = true
                token = token.dropFirst()
            }
            return Self.term(String(token)).map { (negate, $0) }
        }
    }

    public static func == (a: PacketFilter, b: PacketFilter) -> Bool {
        a.terms.count == b.terms.count && zip(a.terms, b.terms).allSatisfy { $0.negate == $1.negate && $0.term == $1.term }
    }

    static func term(_ token: String) -> Term? {
        let lower = token.lowercased()
        func list(_ v: Substring) -> [String] { v.split(separator: ",").map(String.init) }
        func value(_ keys: [String]) -> Substring? {
            keys.lazy.compactMap { lower.hasPrefix($0) ? lower.dropFirst($0.count) : nil }.first
        }
        if let v = value(["port:", "port="]) { return .port(v.split(separator: ",").compactMap { UInt16($0) }) }
        if let v = value(["host:", "ip:"]) { return .host(list(v)) }
        if let v = value(["app:", "proc:"]) { return .process(list(v)) }
        if let v = value(["proto:"]) { return .proto(list(v)) }
        if let v = value(["len>"]) { return Int(v).map(Term.lenOver) }
        if let v = value(["len<"]) { return Int(v).map(Term.lenUnder) }
        if ["in", "out", "local"].contains(lower) { return .direction(lower) }
        let parts = lower.split(separator: ",").map(String.init)
        if !parts.isEmpty, parts.allSatisfy(protos.contains) { return .proto(parts) }
        if !parts.isEmpty, parts.allSatisfy(apps.contains) { return .app(parts) }
        return .text(lower.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
    }

    /// What a term can ask about one packet.
    public struct Subject {
        public var proto: String
        public var app: String
        public var direction: String
        public var sport: UInt16
        public var dport: UInt16
        public var length: Int
        public var info: String
        /// "ip name" for each side, lowercased.
        public var sourceNames: String
        public var destinationNames: String
        /// The owning process's name, lowercased.
        public var process: String?

        public init(proto: String, app: String, direction: String, sport: UInt16, dport: UInt16, length: Int, info: String,
                    sourceNames: String, destinationNames: String, process: String?) {
            self.proto = proto
            self.app = app
            self.direction = direction
            self.sport = sport
            self.dport = dport
            self.length = length
            self.info = info
            self.sourceNames = sourceNames
            self.destinationNames = destinationNames
            self.process = process
        }
    }

    public func matches(_ s: Subject) -> Bool {
        terms.allSatisfy { negate, term in
            let hit: Bool = switch term {
            case .proto(let list): list.contains { $0.caseInsensitiveCompare(s.proto) == .orderedSame }
            case .app(let list): list.contains { $0.caseInsensitiveCompare(s.app) == .orderedSame }
            case .direction(let dir): s.direction == dir
            case .port(let ports): ports.contains(s.sport) || ports.contains(s.dport)
            case .host(let list): list.contains { s.sourceNames.contains($0) || s.destinationNames.contains($0) }
            case .process(let list): s.process.map { name in list.contains { name.contains($0) } } ?? false
            case .lenOver(let n): s.length > n
            case .lenUnder(let n): s.length < n
            case .text(let needle):
                s.info.lowercased().contains(needle) || s.sourceNames.contains(needle) || s.destinationNames.contains(needle)
                    || (s.process?.contains(needle) ?? false)
            }
            return hit != negate
        }
    }
}
