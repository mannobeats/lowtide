import Foundation
import Testing
@testable import LowtideKit

/// Writes a tiny MaxMind DB: one node splitting the IPv4 space in half.
private enum MMDBWriter {
    static func ctrl(_ type: Int, _ size: Int) -> [UInt8] {
        precondition(size < 29)
        return type < 8 ? [UInt8(type << 5 | size)] : [UInt8(size), UInt8(type - 7)]
    }
    static func string(_ s: String) -> [UInt8] { ctrl(2, s.utf8.count) + Array(s.utf8) }
    static func uint(_ type: Int, _ value: UInt64) -> [UInt8] {
        var bytes: [UInt8] = []
        var v = value
        while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return ctrl(type, bytes.count) + bytes
    }
    static func map(_ pairs: [(String, [UInt8])]) -> [UInt8] {
        ctrl(7, pairs.count) + pairs.flatMap { string($0.0) + $0.1 }
    }
    static func double(_ d: Double) -> [UInt8] {
        let bits = d.bitPattern
        return ctrl(3, 8) + (0..<8).reversed().map { UInt8(bits >> (UInt64($0) * 8) & 0xFF) }
    }
    static func pointer(_ offset: Int) -> [UInt8] { [UInt8(0x20 | (offset >> 8) & 0x7), UInt8(offset & 0xFF)] }

    static func file(recordSize: Int) -> Data {
        // Data A at offset 0; data B points back at A's country string.
        let country = string("US")
        let a = map([("country", map([("iso_code", country)])), ("n", uint(6, 7)), ("d", double(1.5)),
                     ("list", ctrl(11, 2) + ctrl(14, 1) + string("x")), ("neg", ctrl(8, 4) + [0xFF, 0xFF, 0xFF, 0xFE])])
        let countryOffset = 1 + string("country").count + 1 + string("iso_code").count
        let b = map([("country", map([("iso_code", pointer(countryOffset))]))])
        let dataSection = a + b
        let nodeCount = 1
        let left = nodeCount + 16, right = nodeCount + 16 + a.count
        var tree: [UInt8]
        switch recordSize {
        case 24: tree = be(left, 3) + be(right, 3)
        case 28: tree = be(left & 0xFFFFFF, 3) + [UInt8((left >> 24) << 4 | (right >> 24))] + be(right & 0xFFFFFF, 3)
        default: tree = be(left, 4) + be(right, 4)
        }
        let meta = map([("node_count", uint(6, UInt64(nodeCount))), ("record_size", uint(5, UInt64(recordSize))),
                        ("ip_version", uint(5, 4)), ("database_type", string("Test"))])
        let marker: [UInt8] = [0xAB, 0xCD, 0xEF] + Array("MaxMind.com".utf8)
        return Data(tree + [UInt8](repeating: 0, count: 16) + dataSection + marker + meta)
    }
    static func be(_ v: Int, _ n: Int) -> [UInt8] { (0..<n).reversed().map { UInt8(v >> ($0 * 8) & 0xFF) } }
}

@Suite struct NetworkGeoTests {
    @Test(arguments: [24, 28, 32])
    func readsEveryRecordSize(size: Int) throws {
        let db = try MMDBReader(data: MMDBWriter.file(recordSize: size))
        #expect(db.recordSize == size && db.nodeCount == 1 && db.databaseType == "Test")
        let low = try #require(db.lookup("10.1.2.3"))
        #expect(low["country"]?["iso_code"]?.string == "US")
        #expect(low["n"] == .uint(7))
        #expect(low["d"] == .double(1.5))
        #expect(low["list"] == .array([.bool(true), .string("x")]))
        #expect(low["neg"] == .int(-2))
        // B reaches the same string through a pointer.
        #expect(db.lookup("200.1.1.1", path: ["country", "iso_code"])?.string == "US")
        #expect(db.lookup("10.0.0.1", path: ["missing"]) == nil)
        // An IPv6 address in an IPv4 database has no record.
        #expect(db.lookup("2001:db8::1") == nil)
    }

    @Test func rejectsWhatIsntMMDB() {
        #expect(throws: MMDBReader.Failure.notMMDB) { try MMDBReader(data: Data(repeating: 7, count: 100)) }
        // Truncated tree: lookups fail quietly instead of reading past the end.
        var data = MMDBWriter.file(recordSize: 24)
        data.replaceSubrange(0..<6, with: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        if let db = try? MMDBReader(data: data) { #expect(db.lookup("10.0.0.1") == nil) }
    }

    @Test func parsesAddresses() {
        #expect(MMDBReader.parse("8.8.8.8") == [8, 8, 8, 8])
        #expect(MMDBReader.parse("fe80::1%en0")?.count == 16)
        #expect(MMDBReader.parse("not an ip") == nil)
    }

    @Test func findsPublicAddressesInTheBundledDatabases() throws {
        let geo = GeoIP.shared
        #expect(geo.available)
        let google = try #require(geo.lookup("8.8.8.8"))
        #expect(google.country == "US" && google.org == "Google" && google.asn == 15169)
        let cloudflare = try #require(geo.lookup("2606:4700:3036::6815:4582"))
        #expect(cloudflare.org?.hasPrefix("Cloudflare") == true)
        #expect(geo.lookup("34.40.0.146")?.country != nil)
        for ip in ["192.168.1.4", "10.0.0.1", "127.0.0.1", "fe80::1%en0", "100.72.1.1", "::1", "172.20.0.1", "fd00::1"] {
            #expect(geo.lookup(ip) == nil, "\(ip)")
        }
    }

    @Test func tidiesOwners() {
        #expect(GeoIP.tidyOrg("Amazon.com, Inc.") == "Amazon.com")
        #expect(GeoIP.tidyOrg("CLOUDFLARENET") == "Cloudflarenet")
        #expect(GeoIP.tidyOrg("GOOGLE-CLOUD-PLATFORM") == "Google-Cloud-Platform")
        #expect(GeoIP.tidyOrg("Akamai Technologies, Inc.") == "Akamai Technologies")
        #expect(GeoIP.prefix("104.16.1.2") == "104.16.1")
        #expect(GeoIP.prefix("2606:4700:3036::1") == "260647003036")
    }

    @Test func loadsTheWorld() {
        let world = WorldData.shared
        #expect(world.cols == 300 && world.rows == 118)
        #expect(world.landCells.count > 5_000)
        #expect(world.countries["TW"]?.name == "Taiwan")
        #expect(world.name("DE") == "Germany")
        #expect(world.name(nil) == "Unknown")
    }

    static let newYork = GeoPoint(lat: 40.714, lon: -74.006)

    @Test func measuresDistanceToTheNearestPartOfACountry() throws {
        let world = WorldData.shared
        // Inside: zero, give or take the grid.
        #expect(try #require(world.distance(from: Self.newYork, to: "US")) < 150)
        // Canada's nearest border is a few hundred km from New York.
        let canada = try #require(world.distance(from: Self.newYork, to: "CA"))
        #expect(canada > 250 && canada < 700)
        #expect(try #require(world.distance(from: Self.newYork, to: "AU")) > 14_000)
        // Overseas territories have codes of their own: France is in Europe, not Martinique.
        #expect(try #require(world.distance(from: Self.newYork, to: "FR")) > 5_000)
        #expect(try #require(world.distance(from: Self.newYork, to: "NL")) > 5_000)
        #expect(world.name("US") == "United States")
        #expect(Self.newYork.distance(to: GeoPoint(lat: 51.507, lon: -0.128)) > 5_500)
    }

    @Test func judgesPlacementByRoundTrip() {
        let margin = 150.0
        // 1.1.1.1 registered in Australia, answering in 9 ms: a nearby edge.
        if case .nearby(let reach, let distance) = Plausibility.check(home: Self.newYork, country: "AU", rttMs: 9, margin: margin) {
            #expect(reach == 900 && distance > 14_000)
        } else {
            Issue.record("Australia at 9 ms should be a nearby edge")
        }
        // Google in Germany at 110 ms: 11,000 km of reach covers it.
        #expect(Plausibility.check(home: Self.newYork, country: "DE", rttMs: 110, margin: margin) == .plausible)
        // A US server at 5 ms from inside the US.
        #expect(Plausibility.check(home: GeoPoint(lat: 39.1, lon: -94.6), country: "US", rttMs: 5, margin: margin) == .plausible)
        // Germany at 18 ms from New York cannot be.
        #expect(Plausibility.check(home: Self.newYork, country: "DE", rttMs: 18, margin: margin) != .plausible)
        // No round trip: nothing to judge.
        #expect(Plausibility.check(home: Self.newYork, country: "DE", rttMs: nil, margin: margin) == .unknown)
    }

    @Test func anchorsAPlausibleCountryWithinReach() throws {
        let world = WorldData.shared
        // Canada at 9 ms from New York: drawn in reach, not in central Canada.
        let anchor = try #require(world.anchor(of: "CA", home: Self.newYork, reach: 900 + 150))
        #expect(Self.newYork.distance(to: anchor) <= 1_050)
        #expect(try #require(world.distance(from: anchor, to: "CA")) < 1)
        // Far enough reach: the label point.
        let label = try #require(world.countries["CA"]?.label)
        #expect(world.anchor(of: "CA", home: Self.newYork, reach: 20_000) == label)
        #expect(world.anchor(of: "CA", home: Self.newYork, reach: nil) == label)
    }

    @Test func readsTimeZonesAndCities() throws {
        let point = try #require(HomeLocation.parseISO6709("+4043-07400"))
        #expect(abs(point.lat - 40.716) < 0.01 && abs(point.lon + 74) < 0.01)
        let sydney = try #require(HomeLocation.parseISO6709("-3352+15113"))
        #expect(abs(sydney.lat + 33.866) < 0.01 && abs(sydney.lon - 151.216) < 0.01)
        #expect(abs((HomeLocation.parseISO6709("+404251-0740023")?.lat ?? 0) - 40.714) < 0.01)
        let table = "#code\tcoordinates\tTZ\nUS\t+404251-0740023\tAmerica/New_York\tEastern\n"
        #expect(HomeLocation.zonePoint("America/New_York", table: table) != nil)
        #expect(HomeLocation.zonePoint("Mars/Olympus", table: table) == nil)

        #expect(City.all.count > 400)
        #expect(City.search("san fr").first?.name == "San Francisco")
        #expect(City.search("zurich").first?.name == "Zurich")
        #expect(City.search("Montréal").first?.name == "Montreal")
        #expect(City.search("").isEmpty)
    }

    @Test func keepsThePickedCity() throws {
        let defaults = try #require(UserDefaults(suiteName: "lowtide-tests-\(UUID())"))
        // Without a city: the time zone's point, no city name.
        let zoned = HomeLocation.current(defaults: defaults, timeZone: TimeZone(identifier: "America/New_York")!)
        #expect(zoned.city == nil && zoned.uncertaintyKm > 1_000)
        let berlin = try #require(City.search("Berlin").first)
        HomeLocation.set(berlin, defaults: defaults)
        let home = HomeLocation.current(defaults: defaults)
        #expect(home.city == berlin && home.point == berlin.point)
        HomeLocation.set(nil, defaults: defaults)
        #expect(HomeLocation.current(defaults: defaults).city == nil)
    }

    @Test func placesOneNodePerCountryAndANearbyEdge() throws {
        func edge(_ app: String, _ host: String, _ country: String?, _ org: String?, rtt: Double?, rate: Int64 = 1_000) -> NetEdge {
            NetEdge(app: app, host: host, ip: "", port: 443, proto: "tcp", rateIn: rate, rateOut: 0, packets: 0, conns: 1,
                    country: country, org: org, asn: nil, rttMs: rtt)
        }
        let newYork = try #require(City.search("New York").first)
        let home = HomeLocation(point: newYork.point, city: newYork)
        let edges = [
            edge("Safari", "one.one.one.one", "AU", "Cloudflare", rtt: 9),
            edge("Chrome", "dns.google", "US", "Google", rtt: 12),
            edge("Chrome", "s3.amazonaws.com", "US", "Amazon.com", rtt: 30, rate: 50_000),
            edge("Slack", "34.40.0.146", "DE", "Google", rtt: 110),
            edge("Zoom", "zoom.us", "CA", "Zoom", rtt: 9),
            edge("Tool", "10.0.0.2", nil, nil, rtt: 1),
        ]
        let scene = MapScene.world(size: CGSize(width: 1000, height: 500), edges: edges, flagged: ["Slack"], home: home)
        #expect(scene.nodes.first?.label == "This Mac · New York")
        // One US node with both owners, busiest first.
        let us = try #require(scene.nodes.first { $0.id == "c:US" })
        #expect(us.owners == ["Amazon.com", "Google"] && us.apps == ["Chrome"])
        #expect(scene.nodes.filter { $0.label == "United States" }.count == 1)
        // Australia at 9 ms is a nearby edge beside home, and says so.
        let nearby = try #require(scene.nodes.first { $0.kind == .nearby })
        #expect(nearby.label == "Nearby edge" && nearby.countries == ["AU"] && nearby.owners == ["Cloudflare"])
        #expect(hypot(nearby.point.x - scene.home.x, nearby.point.y - scene.home.y) < 50)
        #expect(!scene.nodes.contains { $0.id == "c:AU" })
        // Germany at 110 ms is plausible and flagged through Slack.
        #expect(scene.nodes.first { $0.id == "c:DE" }?.flagged == true)
        // Canada at 9 ms: drawn near home, not at its label in the north.
        let canada = try #require(scene.nodes.first { $0.id == "c:CA" })
        #expect(canada.anchoredWithin != nil)
        let projection = WorldProjection(size: CGSize(width: 1000, height: 500))
        let label = projection.project(try #require(WorldData.shared.countries["CA"]?.label))
        #expect(canada.point.y > label.y)
        // Local addresses have no place on the map.
        #expect(scene.links.count == 4 && !scene.links.contains { $0.app == "Tool" })
        #expect(scene.links.first { $0.app == "Slack" }?.flagged == true)
    }

    @Test func emitsParticlesByTraffic() {
        #expect(MapScene.emission(rate: 0, packets: 0, capturing: false) == 0.1)
        #expect(MapScene.emission(rate: 50_000_000, packets: 0, capturing: false) <= 14.1)
        #expect(MapScene.emission(rate: 0, packets: 600, capturing: true) == 11)
        let arc = MapScene.bend(.zero, CGPoint(x: 100, y: 0), lift: 20)
        #expect(arc.c.y < 0 && arc.at(0) == .zero && arc.at(1) == CGPoint(x: 100, y: 0))
        #expect(MapScene.hash("Safari") == MapScene.hash("Safari") && MapScene.hash("a") != MapScene.hash("b"))
    }
}
