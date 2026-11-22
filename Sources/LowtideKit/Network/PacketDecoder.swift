import Foundation

/// A link-layer type as libpcap reports it.
public enum LinkType: Int32, Sendable {
    /// BSD loopback and `utun`: a 4-byte address family, host byte order.
    case null = 0
    case ethernet = 1
    /// Raw IP (BSD's `DLT_RAW`).
    case raw = 12
    case rawLinktype = 101
    /// OpenBSD loopback: the family in network byte order.
    case loop = 108
}

/// One captured frame, decoded far enough to be readable: addresses,
/// ports, TCP flags, and the transport payload's place in the bytes.
public struct DecodedFrame: Sendable, Equatable {
    public struct Ethernet: Sendable, Equatable {
        public var source: [UInt8]
        public var destination: [UInt8]
        public var etherType: UInt16
    }

    public struct IPHeader: Sendable, Equatable {
        public var version: Int
        public var source: [UInt8]
        public var destination: [UInt8]
        /// TTL or hop limit.
        public var ttl: Int
        /// Total length (IPv4) or payload length (IPv6).
        public var length: Int
        public var identification: Int?
        public var dontFragment: Bool?
    }

    public var ethernet: Ethernet?
    public var ip: IPHeader
    /// `TCP`, `UDP`, `ICMP`, `ICMPv6`, or `IP` for anything else.
    public var proto: String
    public var sport: UInt16 = 0
    public var dport: UInt16 = 0
    /// `SYN,ACK`.
    public var flags: String = ""
    public var sequence: UInt32?
    public var acknowledgment: UInt32?
    public var window: UInt16?
    public var udpLength: UInt16?
    public var payload: Range<Int>

    public var sourceText: String { PacketDecoder.addressText(ip.source) }
    public var destinationText: String { PacketDecoder.addressText(ip.destination) }
}

/// What the payload turned out to be.
public struct Classified: Sendable, Equatable {
    /// `DNS`, `mDNS`, `TLS`, `HTTP`, `QUIC`, `SSH`… or empty.
    public var app = ""
    public var info = ""
    public var dns: DNSMessage?
    public var sni: String?
    /// A new request: a TLS Client Hello or an HTTP request line.
    public var request = false
}

public struct DNSMessage: Sendable, Equatable {
    public var response: Bool
    public var rcode: String
    public var name: String
    public var qtype: String
    public var answers: [String]

    public var summary: String {
        if !response { return "Query \(qtype) \(name)" }
        return answers.isEmpty ? "\(qtype) \(name) → \(rcode)" : "\(qtype) \(name) → \(answers.joined(separator: ", "))"
    }
}

/// One layer of a packet for the detail view.
public struct PacketLayer: Sendable, Hashable {
    public var name: String
    public var fields: [Field]
    public struct Field: Sendable, Hashable {
        public var name: String
        public var value: String
    }
}

/// Decoders for the layers the inspector shows. Every read is bounds-checked:
/// these bytes come off the wire.
public enum PacketDecoder {
    public static func decode(link: Int32, _ data: [UInt8]) -> DecodedFrame? {
        switch LinkType(rawValue: link) {
        case .ethernet:
            guard data.count >= 14 else { return nil }
            var type = be16(data, 12) ?? 0
            var at = 14
            // 802.1Q VLAN tags.
            while type == 0x8100 || type == 0x88A8, let inner = be16(data, at + 2) {
                type = inner
                at += 4
            }
            let ethernet = DecodedFrame.Ethernet(source: Array(data[6..<12]), destination: Array(data[0..<6]), etherType: type)
            guard type == 0x0800 || type == 0x86DD else { return nil }
            var frame = ip(data, at)
            frame?.ethernet = ethernet
            return frame
        case .null, .loop:
            return data.count > 4 ? ip(data, 4) : nil
        case .raw, .rawLinktype:
            return ip(data, 0)
        case nil:
            return nil
        }
    }

    static func ip(_ data: [UInt8], _ start: Int) -> DecodedFrame? {
        guard start < data.count else { return nil }
        let version = Int(data[start] >> 4)
        var next: Int
        var at: Int
        var end = data.count
        var header: DecodedFrame.IPHeader
        var fragmented = false
        if version == 4 {
            let ihl = Int(data[start] & 0x0F) * 4
            guard ihl >= 20, start + ihl <= data.count, let total = be16(data, start + 2), let id = be16(data, start + 4),
                  let frag = be16(data, start + 6) else { return nil }
            header = .init(version: 4, source: Array(data[start + 12..<start + 16]), destination: Array(data[start + 16..<start + 20]),
                           ttl: Int(data[start + 8]), length: Int(total), identification: Int(id), dontFragment: frag & 0x4000 != 0)
            next = Int(data[start + 9])
            at = start + ihl
            end = min(data.count, start + max(Int(total), ihl))
            fragmented = frag & 0x1FFF != 0
        } else if version == 6 {
            guard start + 40 <= data.count, let payload = be16(data, start + 4) else { return nil }
            header = .init(version: 6, source: Array(data[start + 8..<start + 24]), destination: Array(data[start + 24..<start + 40]),
                           ttl: Int(data[start + 7]), length: Int(payload), identification: nil, dontFragment: nil)
            next = Int(data[start + 6])
            at = start + 40
            end = min(data.count, at + Int(payload))
            // Extension headers before the transport.
            var hops = 0
            while hops < 8, [0, 43, 44, 51, 60].contains(next), at + 8 <= end {
                hops += 1
                let following = Int(data[at])
                switch next {
                case 44:
                    fragmented = (be16(data, at + 2) ?? 0) & 0xFFF8 != 0
                    at += 8
                case 51:
                    at += (Int(data[at + 1]) + 2) * 4
                default:
                    at += (Int(data[at + 1]) + 1) * 8
                }
                next = following
            }
        } else {
            return nil
        }
        var frame = DecodedFrame(ip: header, proto: "IP", payload: min(at, end)..<end)
        guard !fragmented, at <= end else { return frame }
        switch next {
        case 6:
            guard at + 20 <= end, let sport = be16(data, at), let dport = be16(data, at + 2),
                  let seq = be32(data, at + 4), let ack = be32(data, at + 8), let window = be16(data, at + 14) else { return frame }
            let offset = Int(data[at + 12] >> 4) * 4
            let bits = data[at + 13]
            frame.proto = "TCP"
            frame.sport = sport
            frame.dport = dport
            frame.sequence = seq
            frame.acknowledgment = ack
            frame.window = window
            frame.flags = [(0x02, "SYN"), (0x10, "ACK"), (0x01, "FIN"), (0x04, "RST"), (0x08, "PSH")]
                .filter { bits & UInt8($0.0) != 0 }.map(\.1).joined(separator: ",")
            let body = min(end, at + max(offset, 20))
            frame.payload = body..<end
        case 17:
            guard at + 8 <= end, let sport = be16(data, at), let dport = be16(data, at + 2), let length = be16(data, at + 4) else {
                return frame
            }
            frame.proto = "UDP"
            frame.sport = sport
            frame.dport = dport
            frame.udpLength = length
            frame.payload = (at + 8)..<min(end, max(at + 8, at + Int(length)))
        case 1:
            frame.proto = "ICMP"
            frame.payload = end..<end
        case 58:
            frame.proto = "ICMPv6"
            frame.payload = end..<end
        default:
            frame.payload = end..<end
        }
        return frame
    }

    /// What a payload is: DNS, TLS (with the server name a Client Hello
    /// asks for), HTTP request and status lines, SSH, QUIC and friends.
    public static func classify(proto: String, sport: UInt16, dport: UInt16, payload: ArraySlice<UInt8>) -> Classified {
        var out = Classified()
        let either = { (ports: Set<UInt16>) in ports.contains(sport) || ports.contains(dport) }
        if proto == "UDP", either([53, 5353]) {
            out.app = either([5353]) ? "mDNS" : "DNS"
            if let dns = parseDNS(payload) {
                out.info = dns.summary
                out.dns = dns
            }
        } else if proto == "TCP", let first = payload.first {
            if let name = parseSNI(payload) {
                out.app = "TLS"
                out.info = "Client Hello · \(name)"
                out.sni = name
                out.request = true
            } else if (0x14...0x17).contains(first), payload.dropFirst().first == 3 {
                out.app = "TLS"
                out.info = first == 0x17 ? "Application data" : first == 0x15 ? "Alert" : "Handshake"
            } else if let line = parseHTTP(payload) {
                out.app = "HTTP"
                out.request = !line.hasPrefix("HTTP/")
                out.info = line
            } else if either([22]) {
                out.app = "SSH"
            }
        } else if proto == "UDP" {
            out.app = either([443]) ? "QUIC" : either([123]) ? "NTP" : either([67, 68]) ? "DHCP" : either([1900]) ? "SSDP" : ""
        }
        return out
    }

    // MARK: DNS

    static func qtypeName(_ code: UInt16) -> String {
        switch code {
        case 1: "A"
        case 2: "NS"
        case 5: "CNAME"
        case 6: "SOA"
        case 12: "PTR"
        case 15: "MX"
        case 16: "TXT"
        case 28: "AAAA"
        case 33: "SRV"
        case 64: "SVCB"
        case 65: "HTTPS"
        case 255: "ANY"
        default: "other"
        }
    }

    /// A name at `pos`, following compression pointers (bounded, so a
    /// pointer loop in a hostile packet ends). Returns the name and the
    /// position after it in the message.
    static func readName(_ msg: ArraySlice<UInt8>, _ start: Int) -> (String, Int)? {
        var labels: [String] = []
        var pos = start
        var end: Int?
        for _ in 0..<64 {
            guard let length = byte(msg, pos) else { return nil }
            if length == 0 { return (labels.joined(separator: "."), end ?? pos + 1) }
            if length & 0xC0 == 0xC0 {
                guard let low = byte(msg, pos + 1) else { return nil }
                if end == nil { end = pos + 2 }
                pos = Int(length & 0x3F) << 8 | Int(low)
                continue
            }
            let from = msg.startIndex + pos + 1, to = from + Int(length)
            guard to <= msg.endIndex else { return nil }
            labels.append(String(decoding: msg[from..<to], as: UTF8.self))
            pos += 1 + Int(length)
        }
        return nil
    }

    public static func parseDNS(_ msg: ArraySlice<UInt8>) -> DNSMessage? {
        guard msg.count >= 12, let flags = be16(msg, 2), let questions = be16(msg, 4), let count = be16(msg, 6),
              questions > 0, let (name, after) = readName(msg, 12), let qtype = be16(msg, after) else { return nil }
        var pos = after + 4
        var answers: [String] = []
        for _ in 0..<min(Int(count), 32) {
            guard let (_, next) = readName(msg, pos), let kind = be16(msg, next), let length = be16(msg, next + 8) else { break }
            let data = next + 10
            let from = msg.startIndex + data, to = from + Int(length)
            guard to <= msg.endIndex else { break }
            switch kind {
            case 1 where length == 4: answers.append(addressText(Array(msg[from..<to])))
            case 28 where length == 16: answers.append(addressText(Array(msg[from..<to])))
            case 5: if let (target, _) = readName(msg, data) { answers.append(target) }
            default: break
            }
            pos = data + Int(length)
        }
        let rcode = switch flags & 0xF {
        case 0: "NOERROR"
        case 2: "SERVFAIL"
        case 3: "NXDOMAIN"
        case 5: "REFUSED"
        default: "ERROR"
        }
        return DNSMessage(response: flags & 0x8000 != 0, rcode: rcode, name: name, qtype: qtypeName(qtype), answers: answers)
    }

    // MARK: TLS and HTTP

    /// The server name a TLS Client Hello asks for.
    public static func parseSNI(_ p: ArraySlice<UInt8>) -> String? {
        guard p.count >= 43, byte(p, 0) == 0x16, byte(p, 5) == 0x01 else { return nil }
        // Record header (5), handshake header (4), version (2), random (32).
        var pos = 5 + 4 + 2 + 32
        guard let session = byte(p, pos) else { return nil }
        pos += 1 + Int(session)
        guard let suites = be16(p, pos) else { return nil }
        pos += 2 + Int(suites)
        guard let methods = byte(p, pos) else { return nil }
        pos += 1 + Int(methods)
        guard let extensions = be16(p, pos) else { return nil }
        let end = min(pos + 2 + Int(extensions), p.count)
        pos += 2
        while pos + 4 <= end {
            guard let kind = be16(p, pos), let length = be16(p, pos + 2) else { return nil }
            pos += 4
            if kind == 0 {
                // server_name list: list length (2), type (1), name length (2).
                guard let nameLength = be16(p, pos + 3) else { return nil }
                let from = p.startIndex + pos + 5, to = from + Int(nameLength)
                guard to <= p.endIndex else { return nil }
                let name = String(decoding: p[from..<to], as: UTF8.self)
                return name.isEmpty ? nil : name
            }
            pos += Int(length)
        }
        return nil
    }

    /// `GET /path · host` for a request, the status line for a response.
    public static func parseHTTP(_ p: ArraySlice<UInt8>) -> String? {
        let head = p.prefix(1024)
        let starts = ["GET ", "POST ", "PUT ", "DELETE ", "HEAD ", "PATCH ", "OPTIONS ", "CONNECT ", "HTTP/1."]
        guard starts.contains(where: { head.starts(with: $0.utf8) }) else { return nil }
        let text = String(decoding: head, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first.map({ String($0.prefix(160)) }) else { return nil }
        let host = lines.dropFirst().lazy.compactMap { line -> String? in
            guard let colon = line.firstIndex(of: ":"), line[..<colon].lowercased() == "host" else { return nil }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }.first
        return host.map { "\(first) · \($0)" } ?? first
    }

    // MARK: Detail

    /// The packet's layers, field by field, for the inspector.
    public static func layers(link: Int32, _ data: [UInt8], app: String, info: String) -> [PacketLayer] {
        guard let frame = decode(link: link, data) else { return [] }
        typealias F = PacketLayer.Field
        var layers: [PacketLayer] = []
        if let eth = frame.ethernet {
            let mac = { (m: [UInt8]) in m.map { String(format: "%02x", $0) }.joined(separator: ":") }
            let type = eth.etherType == 0x0800 ? "IPv4" : eth.etherType == 0x86DD ? "IPv6" : "other"
            layers.append(PacketLayer(name: "Ethernet", fields: [
                F(name: "Source", value: mac(eth.source)), F(name: "Destination", value: mac(eth.destination)),
                F(name: "Type", value: "\(type) (0x\(String(format: "%04x", eth.etherType)))"),
            ]))
        }
        if frame.ip.version == 4 {
            layers.append(PacketLayer(name: "IPv4", fields: [
                F(name: "Source", value: frame.sourceText), F(name: "Destination", value: frame.destinationText),
                F(name: "TTL", value: "\(frame.ip.ttl)"), F(name: "Total length", value: "\(frame.ip.length)"),
                F(name: "Identification", value: "\(frame.ip.identification ?? 0)"),
                F(name: "Don't fragment", value: frame.ip.dontFragment == true ? "Yes" : "No"),
            ]))
        } else {
            layers.append(PacketLayer(name: "IPv6", fields: [
                F(name: "Source", value: frame.sourceText), F(name: "Destination", value: frame.destinationText),
                F(name: "Hop limit", value: "\(frame.ip.ttl)"), F(name: "Payload length", value: "\(frame.ip.length)"),
            ]))
        }
        if frame.proto == "TCP" {
            layers.append(PacketLayer(name: "TCP", fields: [
                F(name: "Source port", value: "\(frame.sport)"), F(name: "Destination port", value: "\(frame.dport)"),
                F(name: "Flags", value: frame.flags.isEmpty ? "none" : frame.flags),
                F(name: "Sequence", value: "\(frame.sequence ?? 0)"), F(name: "Acknowledgment", value: "\(frame.acknowledgment ?? 0)"),
                F(name: "Window", value: "\(frame.window ?? 0)"),
            ]))
        } else if frame.proto == "UDP" {
            layers.append(PacketLayer(name: "UDP", fields: [
                F(name: "Source port", value: "\(frame.sport)"), F(name: "Destination port", value: "\(frame.dport)"),
                F(name: "Length", value: "\(frame.udpLength ?? 0)"),
            ]))
        }
        if !app.isEmpty { layers.append(PacketLayer(name: app, fields: [F(name: "Summary", value: info)])) }
        return layers
    }

    /// `16  00 01 …  ..` lines: offset, hex, printable text.
    public static func hexDump(_ bytes: [UInt8]) -> [String] {
        stride(from: 0, to: bytes.count, by: 16).map { offset in
            let chunk = bytes[offset..<min(offset + 16, bytes.count)]
            let hex = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
            let text = String(chunk.map { (32..<127).contains($0) ? Character(UnicodeScalar($0)) : "." })
            return String(format: "%04x", offset) + "  " + hex.padding(toLength: 47, withPad: " ", startingAt: 0) + "  " + text
        }
    }

    public static func addressText(_ bytes: [UInt8]) -> String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let family = bytes.count == 4 ? AF_INET : AF_INET6
        guard bytes.count == 4 || bytes.count == 16 else { return "" }
        return bytes.withUnsafeBytes { raw in
            guard inet_ntop(family, raw.baseAddress, &buffer, socklen_t(buffer.count)) != nil else { return "" }
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }

    // Offsets are relative to the slice's start.
    static func byte(_ p: ArraySlice<UInt8>, _ at: Int) -> UInt8? {
        let i = p.startIndex + at
        return at >= 0 && i < p.endIndex ? p[i] : nil
    }

    static func be16(_ p: ArraySlice<UInt8>, _ at: Int) -> UInt16? {
        guard let a = byte(p, at), let b = byte(p, at + 1) else { return nil }
        return UInt16(a) << 8 | UInt16(b)
    }

    static func be16(_ p: [UInt8], _ at: Int) -> UInt16? { be16(p[...], at) }

    static func be32(_ p: [UInt8], _ at: Int) -> UInt32? {
        guard let hi = be16(p, at), let lo = be16(p, at + 2) else { return nil }
        return UInt32(hi) << 16 | UInt32(lo)
    }
}
