import Foundation
import Testing
@testable import LowtideKit

/// Frames built byte by byte, the way they arrive off the wire.
private enum Wire {
    static func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }

    static func ethernet(_ type: Int, _ payload: [UInt8]) -> [UInt8] {
        [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF] + be16(type) + payload
    }

    static func ipv4(_ proto: UInt8, src: [UInt8], dst: [UInt8], _ payload: [UInt8], fragment: Int = 0x4000) -> [UInt8] {
        [0x45, 0] + be16(20 + payload.count) + be16(0x1234) + be16(fragment) + [64, proto, 0, 0] + src + dst + payload
    }

    static func ipv6(_ next: UInt8, src: [UInt8], dst: [UInt8], _ payload: [UInt8]) -> [UInt8] {
        [0x60, 0, 0, 0] + be16(payload.count) + [next, 57] + src + dst + payload
    }

    static func udp(_ sport: Int, _ dport: Int, _ payload: [UInt8]) -> [UInt8] {
        be16(sport) + be16(dport) + be16(8 + payload.count) + [0, 0] + payload
    }

    static func tcp(_ sport: Int, _ dport: Int, flags: UInt8, _ payload: [UInt8]) -> [UInt8] {
        be16(sport) + be16(dport) + be32(1000) + be32(2000) + [0x50, flags] + be16(65535) + [0, 0, 0, 0] + payload
    }

    /// A response for example.com A 93.184.216.34, the answer's name compressed.
    static let dnsResponse: [UInt8] = [0x12, 0x34, 0x81, 0x80, 0, 1, 0, 1, 0, 0, 0, 0]
        + [7] + Array("example".utf8) + [3] + Array("com".utf8) + [0, 0, 1, 0, 1]
        + [0xC0, 12, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 93, 184, 216, 34]

    static func clientHello(_ name: String) -> [UInt8] {
        let host = Array(name.utf8)
        let sni = [0, 0] + be16(host.count + 5) + be16(host.count + 3) + [0] + be16(host.count) + host
        let body = [3, 3] + [UInt8](repeating: 0, count: 32) + [0] + [0, 2, 0x13, 0x01] + [1, 0] + be16(sni.count) + sni
        let hello = [1, 0] + be16(body.count) + body
        return [0x16, 3, 1] + be16(hello.count) + hello
    }

    static let mac: [UInt8] = [192, 168, 1, 4]
    static let resolver: [UInt8] = [192, 168, 1, 1]
}

@Suite struct NetworkPacketTests {
    @Test func decodesDNSOverEthernetAndIPv4() throws {
        let frame = Wire.ethernet(0x0800, Wire.ipv4(17, src: Wire.resolver, dst: Wire.mac, Wire.udp(53, 51_000, Wire.dnsResponse)))
        let decoded = try #require(PacketDecoder.decode(link: 1, frame))
        #expect(decoded.proto == "UDP" && decoded.sport == 53 && decoded.dport == 51_000)
        #expect(decoded.sourceText == "192.168.1.1" && decoded.destinationText == "192.168.1.4")
        #expect(decoded.ethernet?.etherType == 0x0800)
        let kind = PacketDecoder.classify(proto: decoded.proto, sport: decoded.sport, dport: decoded.dport, payload: frame[decoded.payload])
        #expect(kind.app == "DNS")
        let dns = try #require(kind.dns)
        #expect(dns.response && dns.name == "example.com" && dns.qtype == "A" && dns.rcode == "NOERROR")
        #expect(dns.answers == ["93.184.216.34"])
        #expect(kind.info == "A example.com → 93.184.216.34")
        let layers = PacketDecoder.layers(link: 1, frame, app: kind.app, info: kind.info)
        #expect(layers.map(\.name) == ["Ethernet", "IPv4", "UDP", "DNS"])
        #expect(layers[0].fields.first?.value == "aa:bb:cc:dd:ee:ff")
    }

    @Test func endsDNSPointerLoops() {
        let looped: [UInt8] = [0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0xC0, 12]
        #expect(PacketDecoder.parseDNS(looped[...]) == nil)
        #expect(PacketDecoder.parseDNS([0, 1, 2][...]) == nil)
        // Answers that run past the end stop the list, not the decoder.
        let cut = Array(Wire.dnsResponse.dropLast(3))
        #expect(PacketDecoder.parseDNS(cut[...])?.answers == [])
    }

    @Test func readsTLSServerNamesOverIPv6() throws {
        let src: [UInt8] = [0x26, 0x00] + [UInt8](repeating: 0, count: 13) + [5]
        let dst: [UInt8] = [0x26, 0x06, 0x47, 0x00] + [UInt8](repeating: 0, count: 11) + [1]
        let frame = Wire.ethernet(0x86DD, Wire.ipv6(6, src: src, dst: dst, Wire.tcp(52_000, 443, flags: 0x18, Wire.clientHello("api.github.com"))))
        let decoded = try #require(PacketDecoder.decode(link: 1, frame))
        #expect(decoded.ip.version == 6 && decoded.proto == "TCP" && decoded.flags == "ACK,PSH")
        #expect(decoded.destinationText == "2606:4700::1")
        let kind = PacketDecoder.classify(proto: "TCP", sport: 52_000, dport: 443, payload: frame[decoded.payload])
        #expect(kind.app == "TLS" && kind.sni == "api.github.com" && kind.request)
        #expect(kind.info == "Client Hello · api.github.com")
    }

    @Test func readsHTTPOverLoopback() throws {
        let request = Array("GET /v1/x HTTP/1.1\r\nHost: a.io\r\n\r\n".utf8)
        // BSD loopback: a 4-byte address family, then IP.
        let frame: [UInt8] = [2, 0, 0, 0] + Wire.ipv4(6, src: [127, 0, 0, 1], dst: [127, 0, 0, 1], Wire.tcp(50_000, 8080, flags: 0x18, request))
        let decoded = try #require(PacketDecoder.decode(link: 0, frame))
        let kind = PacketDecoder.classify(proto: decoded.proto, sport: decoded.sport, dport: decoded.dport, payload: frame[decoded.payload])
        #expect(kind.app == "HTTP" && kind.info == "GET /v1/x HTTP/1.1 · a.io" && kind.request)
        let response = PacketDecoder.classify(proto: "TCP", sport: 8080, dport: 50_000, payload: Array("HTTP/1.1 200 OK\r\n".utf8)[...])
        #expect(response.app == "HTTP" && !response.request)
        #expect(PacketDecoder.parseHTTP([0x16, 0x03, 0x01][...]) == nil)
    }

    @Test func handlesVLANsFragmentsAndOddFrames() throws {
        let inner = Wire.ipv4(17, src: Wire.mac, dst: Wire.resolver, Wire.udp(51_000, 123, [1, 2, 3]))
        let tagged = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x81, 0x00, 0x00, 0x05, 0x08, 0x00] + inner
        let vlan = try #require(PacketDecoder.decode(link: 1, tagged))
        #expect(vlan.proto == "UDP" && PacketDecoder.classify(proto: "UDP", sport: 51_000, dport: 123, payload: [][...]).app == "NTP")
        // A later fragment has no transport header to read.
        let fragment = Wire.ipv4(6, src: Wire.mac, dst: Wire.resolver, [1, 2, 3, 4], fragment: 0x0010)
        #expect(PacketDecoder.decode(link: 12, fragment)?.proto == "IP")
        // ARP and runts are skipped.
        #expect(PacketDecoder.decode(link: 1, Wire.ethernet(0x0806, [0, 1])) == nil)
        #expect(PacketDecoder.decode(link: 1, [1, 2, 3]) == nil)
        #expect(PacketDecoder.decode(link: 999, inner) == nil)
        // ICMP is named.
        #expect(PacketDecoder.decode(link: 12, Wire.ipv4(1, src: Wire.mac, dst: Wire.resolver, [8, 0, 0, 0]))?.proto == "ICMP")
    }

    @Test func survivesGarbage() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<3_000 {
            let length = Int.random(in: 0..<200, using: &generator)
            var bytes = (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }
            if !bytes.isEmpty, Bool.random() { bytes[0] = Bool.random() ? 0x45 : 0x60 }
            for link: Int32 in [0, 1, 12] {
                if let frame = PacketDecoder.decode(link: link, bytes) {
                    _ = PacketDecoder.classify(proto: frame.proto, sport: frame.sport, dport: frame.dport, payload: bytes[frame.payload])
                    _ = PacketDecoder.layers(link: link, bytes, app: "", info: "")
                }
            }
            _ = PacketDecoder.parseDNS(bytes[...])
            _ = PacketDecoder.parseSNI(bytes[...])
        }
    }

    @Test func dumpsHex() {
        let lines = PacketDecoder.hexDump(Array("Hello, packets!!x".utf8))
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("0000  48 65 6c 6c 6f") && lines[0].hasSuffix("Hello, packets!!"))
        #expect(lines[1].hasPrefix("0010  78") && lines[1].hasSuffix("x"))
    }

    @Test func parsesTheFilterLanguage() {
        let filter = PacketFilter("tcp -mdns port:443,8443 host:apple len>100 out hello app:chrome !len<5")
        #expect(filter.terms.map(\.negate) == [false, true, false, false, false, false, false, false, true])
        #expect(filter.terms[0].term == .proto(["tcp"]))
        #expect(filter.terms[1].term == .app(["mdns"]))
        #expect(filter.terms[2].term == .port([443, 8443]))
        #expect(filter.terms[3].term == .host(["apple"]))
        #expect(filter.terms[4].term == .lenOver(100))
        #expect(filter.terms[5].term == .direction("out"))
        #expect(filter.terms[6].term == .text("hello"))
        #expect(filter.terms[7].term == .process(["chrome"]))
        #expect(filter.terms[8].term == .lenUnder(5))
        #expect(PacketFilter("-dns,mdns,tls").terms.first?.term == .app(["dns", "mdns", "tls"]))
    }

    @Test func matchesPackets() {
        func subject(_ app: String, dport: UInt16 = 443, length: Int = 1200) -> PacketFilter.Subject {
            .init(proto: "TCP", app: app, direction: "out", sport: 50_000, dport: dport, length: length, info: "Client Hello · api.github.com",
                  sourceNames: "192.168.1.4 ", destinationNames: "140.82.113.25 api.github.com", process: "google chrome")
        }
        #expect(PacketFilter("tls app:chrome host:github port:443 out len>1000").matches(subject("TLS")))
        #expect(!PacketFilter("-tls").matches(subject("TLS")))
        // "Undecoded": none of the known protocols.
        #expect(PacketFilter("-dns,mdns,tls,quic,http").matches(subject("")))
        #expect(!PacketFilter("tcp -port:443,80").matches(subject("TLS")))
        #expect(PacketFilter("hello").matches(subject("TLS")))
        #expect(!PacketFilter("nothing").matches(subject("TLS")))
        #expect(PacketFilter("github").matches(subject("TLS")))
        #expect(PacketFilter("").matches(subject("TLS")))
    }

    /// libpcap through dlsym: listing devices needs no root; opening one
    /// The capture command works on a Mac without Wireshark: it makes the
    /// access_bpf group when missing, adds the user and hands them the devices.
    @Test func captureAccessCommandMakesTheGroupWhenMissing() throws {
        let command = try #require(CaptureAccess.allowCommand(user: "ada"))
        #expect(command.contains("dscl . -read /Groups/access_bpf"))
        #expect(command.contains("|| /usr/sbin/dseditgroup -o create"))
        #expect(command.contains("dseditgroup -o edit -a ada -t user access_bpf"))
        #expect(command.contains("chown ada:access_bpf /dev/bpf*"))
        #expect(CaptureAccess.allowCommand(user: "ada; rm -rf ~") == nil)
        #expect(CaptureAccess.allowCommand(user: "") == nil)
    }

    /// without access to /dev/bpf* fails with a clear reason, not a crash.
    @Test func bindsLibpcap() throws {
        let interfaces = PCap.interfaces()
        #expect(!interfaces.isEmpty && !interfaces.contains { $0.name == "lo0" })
        #expect(interfaces.allSatisfy { !$0.addresses.isEmpty })
        guard !CaptureAccess.permitted, let first = interfaces.first else { return }
        let session = CaptureSession(interface: first.name, local: Set(first.addresses))
        #expect(throws: LowtideError.self) { try session.start { _ in } }
        #expect(!session.isRunning)
    }
}
