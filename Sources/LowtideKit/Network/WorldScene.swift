import CoreGraphics
import Foundation

/// The dotted world in a rectangle: an equirectangular projection of the
/// land grid's latitude band, centred, with a margin.
public struct WorldProjection: Sendable {
    public let size: CGSize
    public let scale: Double
    public let x0: Double
    public let y0: Double
    public let latMax: Double
    public let latMin: Double

    public init(size: CGSize, world: WorldData = .shared, pad: Double = 28) {
        self.size = size
        latMax = world.latMax
        latMin = world.latMin
        let span = latMax - latMin
        scale = max(0.1, min((size.width - pad * 2) / 360, (size.height - pad * 2) / span))
        x0 = (size.width - 360 * scale) / 2
        y0 = (size.height - span * scale) / 2
    }

    public func project(_ p: GeoPoint) -> CGPoint {
        CGPoint(x: x0 + (p.lon + 180) * scale, y: y0 + (latMax - min(max(p.lat, latMin), latMax)) * scale)
    }

    public var width: Double { 360 * scale }
    public var height: Double { (latMax - latMin) * scale }
}

/// The map's nodes and links for one moment, in view coordinates.
public struct MapScene: Sendable {
    public enum Kind: Sendable, Hashable {
        case home
        case country(String)
        /// Servers whose round trip rules out the country they're registered in.
        case nearby
    }

    public struct Node: Sendable, Identifiable, Hashable {
        public var id: String
        public var kind: Kind
        public var label: String
        public var sub: String
        /// Who runs its servers, busiest first.
        public var owners: [String]
        /// Apps talking to it.
        public var apps: [String]
        /// Countries its servers are registered in (the nearby edge has several).
        public var countries: [String]
        public var point: CGPoint
        public var r: Double
        public var active: Bool
        public var flagged: Bool
        /// Always labelled, not only on hover or lock.
        public var pinned: Bool
        public var rate: Int64
        /// The fastest round trip to its servers, when measured.
        public var bestRTT: Double?
        /// Drawn nearer home than its label point because its servers answer
        /// from within this many km.
        public var anchoredWithin: Double?
    }

    /// A quadratic curve: start, control, end.
    public struct Segment: Sendable, Hashable {
        public var p0: CGPoint
        public var c: CGPoint
        public var p1: CGPoint

        public func at(_ u: Double) -> CGPoint {
            let a = (1 - u) * (1 - u), b = 2 * (1 - u) * u, d = u * u
            return CGPoint(x: a * p0.x + b * c.x + d * p1.x, y: a * p0.y + b * c.y + d * p1.y)
        }
    }

    public struct Link: Sendable, Identifiable, Hashable {
        public var id: String
        public var app: String
        public var to: String
        public var active: Bool
        public var flagged: Bool
        public var rateIn: Int64
        public var rateOut: Int64
        /// Packets a second (capture on), else 0.
        public var packets: Int
        public var segment: Segment
        /// Seconds a particle takes end to end.
        public var travel: Double
    }

    public var nodes: [Node] = []
    public var links: [Link] = []
    public var home: CGPoint = .zero

    public init() {}

    public static let homeID = "home"
    public static let nearbyID = "nearby"

    /// A stable small number from a string, for placement that doesn't jump.
    public static func hash(_ text: String) -> Double {
        var h = 7
        for unit in text.utf16 { h = (h * 31 + Int(unit)) % 1_000_003 }
        return Double(h) / 1_000_003
    }

    /// An arc that rises up the screen like a flight path.
    public static func bend(_ from: CGPoint, _ to: CGPoint, lift: Double) -> Segment {
        let dx = to.x - from.x, dy = to.y - from.y
        let length = max(hypot(dx, dy), 1)
        var nx = -dy / length, ny = dx / length
        if ny > 0 { nx = -nx; ny = -ny }
        return Segment(p0: from, c: CGPoint(x: (from.x + to.x) / 2 + nx * lift, y: (from.y + to.y) / 2 + ny * lift), p1: to)
    }

    /// Particles a second a link emits one way: real packets when captured,
    /// otherwise a log of the byte rate (a 50 MB/s download mustn't bury the
    /// rest), and a trickle for every open link.
    public static func emission(rate: Int64, packets: Int, capturing: Bool) -> Double {
        if capturing, packets > 0 { return min(22, Double(packets) / 6 + 0.4) / 2 }
        return 0.1 + min(14, log2(1 + Double(rate) / 1500) * 0.9)
    }

    /// One node per country (owners listed, no invented cities), and one
    /// "Nearby edge" beside home for servers whose round trip rules out
    /// the country they're registered in.
    public static func world(size: CGSize, edges: [NetEdge], flagged: Set<String>, home: HomeLocation,
                             world: WorldData = .shared) -> MapScene {
        let projection = WorldProjection(size: size, world: world)
        var scene = MapScene()
        let origin = projection.project(home.point)
        scene.home = origin
        scene.nodes.append(Node(id: homeID, kind: .home, label: home.city.map { "This Mac · \($0.name)" } ?? "This Mac", sub: "",
                                owners: [], apps: [], countries: [], point: origin, r: 5, active: true, flagged: false,
                                pinned: true, rate: 0, bestRTT: nil, anchoredWithin: nil))
        let margin = home.uncertaintyKm + 150

        struct Group {
            var edges: [NetEdge] = []
            var reach: Double? = 0
        }
        var groups: [String: Group] = [:]
        for edge in edges {
            guard let country = edge.country, world.countries[country] != nil else { continue }
            let verdict = Plausibility.check(home: home.point, country: country, rttMs: edge.rttMs, margin: margin, world: world)
            let key = verdict == .plausible || verdict == .unknown ? country : nearbyID
            var group = groups[key] ?? Group()
            group.edges.append(edge)
            // The node must stand for every server in it: an unmeasured one lifts the limit.
            if let rtt = edge.rttMs, let known = group.reach { group.reach = max(known, rtt * Plausibility.kmPerMs + margin) } else { group.reach = nil }
            groups[key] = group
        }
        let rate = { (list: [NetEdge]) in list.reduce(Int64(0)) { $0 + $1.rateIn + $1.rateOut } }
        let ranked = groups.sorted { (rate($0.value.edges), $1.key) > (rate($1.value.edges), $0.key) }
        for (rank, (key, group)) in ranked.enumerated() {
            let total = rate(group.edges)
            let apps = Array(Set(group.edges.map(\.app))).sorted()
            var byOwner: [String: Int64] = [:]
            for edge in group.edges { byOwner[edge.org ?? "Unknown owner", default: 0] += edge.rateIn + edge.rateOut + 1 }
            let owners = byOwner.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
            let countries = Array(Set(group.edges.compactMap(\.country))).sorted()
            let best = group.edges.compactMap(\.rttMs).min()
            let point: CGPoint
            var anchored: Double?
            let kind: Kind
            if key == nearbyID {
                kind = .nearby
                // Beside home, up and to the right, a fixed distance on screen.
                point = CGPoint(x: origin.x + 30, y: origin.y - 24)
            } else {
                kind = .country(key)
                let label = world.countries[key]!.label
                let anchor = world.anchor(of: key, home: home.point, reach: group.reach) ?? label
                if anchor != label { anchored = group.reach }
                point = projection.project(anchor)
            }
            let ownerText = owners.count > 2 ? "\(owners.prefix(2).joined(separator: ", ")) +\(owners.count - 2)"
                : owners.joined(separator: ", ")
            let label = key == nearbyID ? "Nearby edge" : world.name(key)
            let sub = total > 0 ? "\(ownerText) · \(Format.rate(Double(total)))" : "\(ownerText) · idle"
            scene.nodes.append(Node(
                id: key == nearbyID ? nearbyID : "c:\(key)", kind: kind, label: label, sub: sub, owners: owners, apps: apps,
                countries: countries, point: point, r: 2.5 + min(6, log2(1 + Double(total) / 20_000)), active: total > 0,
                flagged: apps.contains(where: flagged.contains), pinned: rank < 6 || key == nearbyID, rate: total,
                bestRTT: best, anchoredWithin: anchored))
            let to = key == nearbyID ? nearbyID : "c:\(key)"
            let length = hypot(point.x - origin.x, point.y - origin.y)
            for app in apps {
                let mine = group.edges.filter { $0.app == app }
                let rateIn = mine.reduce(Int64(0)) { $0 + $1.rateIn }, rateOut = mine.reduce(Int64(0)) { $0 + $1.rateOut }
                let fan = (hash(app) - 0.5) * 24
                scene.links.append(Link(
                    id: "\(app)|\(to)", app: app, to: to, active: rateIn + rateOut > 0, flagged: flagged.contains(app),
                    rateIn: rateIn, rateOut: rateOut, packets: mine.reduce(0) { $0 + $1.packets },
                    segment: bend(origin, point, lift: max(18, length * 0.24) + fan),
                    travel: 0.9 + length / max(size.width, 1) * 2.6))
            }
        }
        return scene
    }
}
