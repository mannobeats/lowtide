import Foundation
import Synchronization

/// A place on the globe, in degrees.
public struct GeoPoint: Sendable, Hashable, Codable {
    public var lat: Double
    public var lon: Double
    public init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }

    /// Great-circle distance in kilometres.
    public func distance(to other: GeoPoint) -> Double {
        let r = 6371.0
        let p1 = lat * .pi / 180, p2 = other.lat * .pi / 180
        let dp = p2 - p1, dl = (other.lon - lon) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }
}

/// The world map's data (Natural Earth, public domain): land as a dot grid,
/// every country's label point and name, and per country the points
/// (boundary and interior) the distance check measures to.
public struct WorldData: Sendable {
    public struct Country: Sendable {
        public let code: String
        public let name: String
        /// Where its label and node go.
        public let label: GeoPoint
    }

    public let step: Double
    public let latMax: Double
    public let latMin: Double
    public let cols: Int
    public let rows: Int
    /// One bit per cell, row by row from `latMax` down, least significant bit first.
    let land: [UInt8]
    public let countries: [String: Country]
    let points: [String: [GeoPoint]]

    public static let shared: WorldData = load()

    /// Centres of the land cells, row by row.
    public var landCells: [GeoPoint] {
        var cells: [GeoPoint] = []
        cells.reserveCapacity(9_000)
        for row in 0..<rows {
            for col in 0..<cols {
                let i = row * cols + col
                guard i / 8 < land.count, land[i / 8] >> (i % 8) & 1 == 1 else { continue }
                cells.append(GeoPoint(lat: latMax - (Double(row) + 0.5) * step, lon: -180 + (Double(col) + 0.5) * step))
            }
        }
        return cells
    }

    public func name(_ code: String?) -> String {
        guard let code else { return "Unknown" }
        return countries[code]?.name ?? code
    }

    /// Kilometres from `point` to the nearest part of a country (0 inside
    /// it, give or take the grid's 70 km), or nil for a code without a shape.
    public func distance(from point: GeoPoint, to code: String) -> Double? {
        // Home rarely moves and the map asks about the same countries every
        // snapshot (and on every hover): remember the answers.
        let key = "\(code)|\(point.lat)|\(point.lon)"
        if let hit = Self.distances.withLock({ $0[key] }) { return hit }
        let found = measure(from: point, to: code)
        Self.distances.withLock {
            if $0.count > 5_000 { $0.removeAll() }
            $0[key] = found
        }
        return found
    }

    private static let distances = Mutex<[String: Double?]>([:])

    private func measure(from point: GeoPoint, to code: String) -> Double? {
        guard let list = points[code], !list.isEmpty else {
            return countries[code].map { point.distance(to: $0.label) }
        }
        var best = Double.infinity
        for p in list {
            // Cheap reject before the trigonometry: a degree of latitude is 111 km.
            if abs(p.lat - point.lat) * 111 > best { continue }
            best = min(best, point.distance(to: p))
        }
        return best
    }

    /// Where to draw a country's node for servers measured within `reach`
    /// km of `home`: its label point when that is in reach, else the part
    /// of the country in reach that lies closest to the label (Canadian
    /// servers 9 ms from New York sit near Montreal, not in Nunavut).
    public func anchor(of code: String, home: GeoPoint, reach: Double?) -> GeoPoint? {
        guard let label = countries[code]?.label else { return nil }
        guard let reach, home.distance(to: label) > reach, let list = points[code] else { return label }
        let inReach = list.filter { home.distance(to: $0) <= reach }
        if let best = inReach.min(by: { $0.distance(to: label) < $1.distance(to: label) }) { return best }
        return list.min { home.distance(to: $0) < home.distance(to: $1) } ?? label
    }

    private static func load() -> WorldData {
        struct File: Decodable {
            var step, latMax, latMin: Double
            var cols, rows: Int
            var land: String
            var countries: [String: [Value]]
            enum Value: Decodable {
                case number(Double), text(String)
                init(from decoder: Decoder) throws {
                    let c = try decoder.singleValueContainer()
                    if let n = try? c.decode(Double.self) { self = .number(n) } else { self = .text(try c.decode(String.self)) }
                }
            }
        }
        let file = (try? Data(contentsOf: AppResources.url("geo/world.json"))).flatMap { try? JSONDecoder().decode(File.self, from: $0) }
        var countries: [String: Country] = [:]
        for (code, values) in file?.countries ?? [:] {
            guard values.count == 3, case .number(let lon) = values[0], case .number(let lat) = values[1],
                  case .text(let name) = values[2] else { continue }
            countries[code] = Country(code: code, name: name, label: GeoPoint(lat: lat, lon: lon))
        }
        let points = (try? Data(contentsOf: AppResources.url("geo/country-points.bin"))).map(parsePoints) ?? [:]
        if file == nil { Log.network.error("world map data missing") }
        return WorldData(step: file?.step ?? 1.2, latMax: file?.latMax ?? 84, latMin: file?.latMin ?? -58,
                         cols: file?.cols ?? 0, rows: file?.rows ?? 0,
                         land: file.flatMap { Data(base64Encoded: $0.land) }.map(Array.init) ?? [],
                         countries: countries, points: points)
    }

    /// `country-points.bin`: a count, then per country its two-letter code,
    /// a point count and the points as little-endian Int16 (lon, lat) × 100.
    static func parsePoints(_ data: Data) -> [String: [GeoPoint]] {
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func i16(_ at: Int) -> Double { Double(Int16(bitPattern: UInt16(u16(at)))) / 100 }
        guard bytes.count >= 2 else { return [:] }
        var out: [String: [GeoPoint]] = [:]
        var at = 2
        for _ in 0..<u16(0) {
            guard at + 4 <= bytes.count else { break }
            let code = String(decoding: bytes[at..<at + 2], as: UTF8.self)
            let n = u16(at + 2)
            at += 4
            guard at + n * 4 <= bytes.count else { break }
            var list: [GeoPoint] = []
            list.reserveCapacity(n)
            for k in 0..<n { list.append(GeoPoint(lat: i16(at + k * 4 + 2), lon: i16(at + k * 4))) }
            out[code] = list
            at += n * 4
        }
        return out
    }
}

/// Whether a server can be where its address is registered, judged by
/// physics: light in fibre covers about 200 km per millisecond, so a round
/// trip of `rtt` ms reaches at most `rtt × 100` km away. Anycast networks
/// (Cloudflare, Google's resolvers) register one country and answer from
/// the data centre nearest you; the round trip gives them away.
public enum Plausibility {
    public static let kmPerMs = 100.0

    public enum Verdict: Sendable, Equatable {
        /// No round trip to judge by.
        case unknown
        case plausible
        /// The registered country is `distance` km away, but the server
        /// answered from within `reach` km.
        case nearby(reach: Double, distance: Double)
    }

    /// `margin` covers how roughly home is known.
    public static func check(home: GeoPoint, country: String?, rttMs: Double?, margin: Double,
                             world: WorldData = .shared) -> Verdict {
        guard let country, let rttMs, rttMs > 0, let distance = world.distance(from: home, to: country) else {
            return .unknown
        }
        let reach = rttMs * kmPerMs
        return distance > reach + margin ? .nearby(reach: reach, distance: distance) : .plausible
    }
}

/// A city a person can pick as where their Mac is.
public struct City: Sendable, Hashable, Codable, Identifiable {
    public var name: String
    public var country: String
    public var lat: Double
    public var lon: Double
    public var id: String { "\(name)|\(country)" }
    public var point: GeoPoint { GeoPoint(lat: lat, lon: lon) }

    public init(name: String, country: String, lat: Double, lon: Double) {
        self.name = name
        self.country = country
        self.lat = lat
        self.lon = lon
    }

    public static let all: [City] = {
        guard let data = try? Data(contentsOf: AppResources.url("geo/cities.json")),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else { return [] }
        return rows.compactMap { row in
            guard row.count == 4, let name = row[0] as? String, let country = row[1] as? String,
                  let lat = (row[2] as? NSNumber)?.doubleValue, let lon = (row[3] as? NSNumber)?.doubleValue else { return nil }
            return City(name: name, country: country, lat: lat, lon: lon)
        }
    }()

    /// Cities whose name (or country) starts with or contains `query`, best first.
    public static func search(_ query: String, in list: [City] = all, world: WorldData = .shared) -> [City] {
        let q = query.trimmingCharacters(in: .whitespaces).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard !q.isEmpty else { return [] }
        func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let scored: [(Int, City)] = list.compactMap { city in
            let name = fold(city.name)
            if name == q { return (0, city) }
            if name.hasPrefix(q) { return (1, city) }
            if name.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { return (2, city) }
            if name.contains(q) { return (3, city) }
            if fold(world.name(city.country)).hasPrefix(q) || fold(city.country) == q { return (4, city) }
            return nil
        }
        return scored.sorted { ($0.0, $0.1.name) < ($1.0, $1.1.name) }.map(\.1)
    }
}

/// Where this Mac is: a city the person picked, else only the time zone's
/// region (which sets the map's centre, never a city name).
public struct HomeLocation: Sendable, Equatable {
    public var point: GeoPoint
    /// The city the person picked.
    public var city: City?

    /// How far off the point may be: a picked city is close; a time zone
    /// spans a continent's width.
    public var uncertaintyKm: Double { city == nil ? 1_500 : 150 }

    public static let key = "network.homeCity"

    public static func current(defaults: UserDefaults = .standard, timeZone: TimeZone = .current) -> HomeLocation {
        if let id = defaults.string(forKey: key), let city = City.all.first(where: { $0.id == id }) {
            return HomeLocation(point: city.point, city: city)
        }
        return HomeLocation(point: zonePoint(timeZone.identifier) ?? GeoPoint(lat: 20, lon: 0), city: nil)
    }

    public static func set(_ city: City?, defaults: UserDefaults = .standard) {
        if let city { defaults.set(city.id, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    /// The coordinates `zone.tab` gives a time zone (`America/New_York`).
    public static func zonePoint(_ zone: String, table: String? = nil) -> GeoPoint? {
        let text = table ?? (try? String(contentsOfFile: "/usr/share/zoneinfo/zone.tab", encoding: .utf8)) ?? ""
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3, fields[2] == zone else { continue }
            return parseISO6709(String(fields[1]))
        }
        return nil
    }

    /// ISO 6709 as zone.tab writes it: `+4043-07400` or `+404251-0740023`.
    public static func parseISO6709(_ text: String) -> GeoPoint? {
        let chars = Array(text)
        guard chars.count > 5, let split = chars.dropFirst().firstIndex(where: { $0 == "+" || $0 == "-" }) else { return nil }
        func degrees(_ part: ArraySlice<Character>, width: Int) -> Double? {
            guard let sign = part.first, sign == "+" || sign == "-" else { return nil }
            let digits = Array(part.dropFirst())
            guard digits.count >= width + 2, let whole = Double(String(digits[0..<width])),
                  let minutes = Double(String(digits[width..<width + 2])) else { return nil }
            let seconds = digits.count >= width + 4 ? Double(String(digits[width + 2..<width + 4])) ?? 0 : 0
            return (sign == "-" ? -1 : 1) * (whole + minutes / 60 + seconds / 3600)
        }
        guard let lat = degrees(chars[..<split], width: 2), let lon = degrees(chars[split...], width: 3) else { return nil }
        return GeoPoint(lat: lat, lon: lon)
    }
}
