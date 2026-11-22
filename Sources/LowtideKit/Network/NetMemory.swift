import Foundation

/// Memory of normal: which apps go online, the countries they reach and
/// how much they usually upload, kept across launches. What breaks the
/// pattern becomes an event. Saved as `network-baseline.json`.
struct Baseline {
    /// With no memory yet, everything is new: stay quiet while learning.
    static let learningMs: Millis = 10 * 60_000
    /// Minutes of history before an app's usual upload means anything.
    static let settledMinutes = 30
    static let spikeFactor = 10.0
    static let spikeMinBytes: Int64 = 20_000_000
    static let maxApps = 2_000
    static let maxCountries = 120
    static let file = "network-baseline.json"

    struct Known: Codable {
        var firstSeen: Millis = 0
        var countries: Set<String> = []
        var minutes = 0
        var usualOut = 0.0
    }

    struct Memory: Codable {
        var created: Millis = 0
        var apps: [String: Known] = [:]
    }

    var memory = Memory()
    var loaded = false
    var learningUntil: Millis = 0
    var dirty = false
    var savedAt: Millis = 0
    var minuteStart: Millis = 0
    /// Bytes each app uploaded this minute.
    var minuteOut: [String: Int64] = [:]
    /// Apps already flagged this launch (each raises one event).
    var flagged: Set<String> = []

    mutating func load(now: Millis, from stored: Memory?) {
        loaded = true
        memory = stored ?? Memory()
        if memory.created == 0 { memory.created = now }
        // A memory still inside its first ten minutes keeps learning.
        learningUntil = memory.created + Self.learningMs
        minuteStart = now
        savedAt = now
    }

    func learning(_ now: Millis) -> Bool { now < learningUntil }

    mutating func addUpload(_ app: String, _ bytes: Int64) {
        if bytes > 0 { minuteOut[app, default: 0] += bytes }
    }

    func firstSeen(_ app: String) -> Millis? { memory.apps[app]?.firstSeen }
    func knownCountries(_ app: String) -> Int { memory.apps[app]?.countries.count ?? 0 }
    func usualOut(_ app: String) -> Double? {
        memory.apps[app].flatMap { $0.minutes >= Self.settledMinutes ? $0.usualOut : nil }
    }

    /// Learns from the apps online now (and the countries and owners each
    /// reaches); returns what broke the pattern.
    mutating func observe(online: [String: Set<CountryVia>], now: Millis) -> [NetEvent] {
        let quiet = learning(now)
        var found: [NetEvent] = []
        for (app, places) in online.sorted(by: { $0.key < $1.key }) {
            let fresh = memory.apps[app] == nil
            if fresh {
                guard memory.apps.count < Self.maxApps else { continue }
                memory.apps[app] = Known(firstSeen: now)
                dirty = true
                if !quiet {
                    found.append(NetEvent(t: now, kind: "firstApp", severity: .notice, app: app,
                                          text: "\(app) went online for the first time"))
                }
            }
            guard var known = memory.apps[app] else { continue }
            for place in places.sorted(by: { $0.country < $1.country })
            where known.countries.count < Self.maxCountries && known.countries.insert(place.country).inserted {
                dirty = true
                // An app's very first countries are not news; a new one after it settled is.
                if !(quiet || fresh || known.countries.count == 1) {
                    let via = place.org.map { " via \($0)" } ?? ""
                    found.append(NetEvent(t: now, kind: "newCountry", severity: .notice, app: app,
                                          text: "\(app) reached \(WorldData.shared.name(place.country)) for the first time\(via)",
                                          country: place.country))
                }
            }
            memory.apps[app] = known
        }
        // Once a minute: each app's upload against its usual.
        if now - minuteStart >= 60_000 {
            let uploads = minuteOut
            minuteOut = [:]
            minuteStart = now
            for app in online.keys {
                guard var known = memory.apps[app] else { continue }
                let out = uploads[app] ?? 0
                let usual = max(known.usualOut, 1)
                if known.minutes >= Self.settledMinutes, out >= Self.spikeMinBytes, Double(out) > Self.spikeFactor * usual {
                    found.append(NetEvent(t: now, kind: "uploadSpike", severity: .alert, app: app,
                                          text: "\(app) uploaded \(Int((Double(out) / 1e6).rounded())) MB in a minute, \(Int((Double(out) / usual).rounded()))× its usual"))
                }
                known.usualOut = known.minutes == 0 ? Double(out) : known.usualOut * 0.95 + Double(out) * 0.05
                known.minutes += 1
                memory.apps[app] = known
                dirty = true
            }
        }
        return found
    }

    struct CountryVia: Hashable {
        var country: String
        var org: String?
    }
}

/// One app's traffic over a stretch of time.
public struct Tally: Sendable, Codable, Hashable {
    public var bytesIn: Int64 = 0
    public var bytesOut: Int64 = 0
    public var countries: Set<String> = []
    public var hosts: Set<String> = []
    static let maxHosts = 40

    public init(bytesIn: Int64 = 0, bytesOut: Int64 = 0, countries: Set<String> = [], hosts: Set<String> = []) {
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.countries = countries
        self.hosts = hosts
    }

    mutating func add(country: String?, host: String?, bytesIn: Int64, bytesOut: Int64) {
        self.bytesIn += bytesIn
        self.bytesOut += bytesOut
        if let country { countries.insert(country) }
        if let host, hosts.count < Self.maxHosts { hosts.insert(host) }
    }

    mutating func merge(_ other: Tally) {
        bytesIn += other.bytesIn
        bytesOut += other.bytesOut
        countries.formUnion(other.countries)
        for host in other.hosts.sorted() where hosts.count < Self.maxHosts { hosts.insert(host) }
    }
}

/// Long memory of traffic: how much each app moved each day and where to,
/// kept for five weeks. Saved as `ledger.json`.
struct Ledger {
    static let file = "ledger.json"
    static let dayMs: Millis = 86_400_000
    static let keepDays: Millis = 35

    /// Day number (days since 1970, UTC, as text) → app → tally.
    struct Days: Codable {
        var days: [String: [String: Tally]] = [:]
    }

    var data = Days()
    var loaded = false
    var dirty = false
    var savedAt: Millis = 0

    mutating func add(now: Millis, app: String, country: String?, host: String?, bytesIn: Int64, bytesOut: Int64) {
        guard bytesIn + bytesOut > 0 else { return }
        let day = String(now / Self.dayMs)
        data.days[day, default: [:]][app, default: Tally()].add(country: country, host: host, bytesIn: bytesIn, bytesOut: bytesOut)
        dirty = true
    }

    mutating func prune(now: Millis) {
        let oldest = now / Self.dayMs - Self.keepDays
        data.days = data.days.filter { (Millis($0.key) ?? 0) >= oldest }
    }

    /// Every app's traffic over the last `days` days (today included).
    func since(now: Millis, days: Int) -> [String: Tally] {
        let first = now / Self.dayMs - Millis(max(days, 1) - 1)
        var out: [String: Tally] = [:]
        for (day, apps) in data.days where (Millis(day) ?? 0) >= first {
            for (app, tally) in apps { out[app, default: Tally()].merge(tally) }
        }
        return out
    }
}

/// What happened while nobody was at the Mac.
struct AwayTally {
    var apps: [String: Tally] = [:]
    /// Events, kept here because the live log only holds an hour.
    var events: [NetEvent] = []

    mutating func add(app: String, country: String?, host: String?, bytesIn: Int64, bytesOut: Int64) {
        guard bytesIn + bytesOut > 0 else { return }
        apps[app, default: Tally()].add(country: country, host: host, bytesIn: bytesIn, bytesOut: bytesOut)
    }
}
