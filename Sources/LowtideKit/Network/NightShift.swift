import CoreGraphics
import Foundation
import Synchronization

/// What happened while you were away: written when you come back, or on
/// request for the last hour. Saved as `nightshift.json`.
public struct Briefing: Sendable, Codable, Hashable, Identifiable {
    public struct AppLine: Sendable, Codable, Hashable {
        public var name: String
        public var bytesIn: Int64
        public var bytesOut: Int64
        public var countries: [String]
        public var hosts: [String]
    }

    public struct EventLine: Sendable, Codable, Hashable {
        public var t: Millis
        public var kind: String
        public var severity: String
        public var subject: String
        public var text: String
    }

    public struct InstallLine: Sendable, Codable, Hashable {
        public var id: Int64
        public var t: Millis
        public var command: String
        /// `info`, `notice` or `alert`.
        public var verdict: String
        public var source: String
        public init(id: Int64, t: Millis, command: String, verdict: String, source: String) {
            self.id = id
            self.t = t
            self.command = command
            self.verdict = verdict
            self.source = source
        }
    }

    public var id: Int64
    /// `away` (written when you came back) or `brief` (asked for).
    public var kind: String
    public var start: Millis
    public var end: Millis
    public var slept: [[Millis]]
    public var sleptMs: Millis
    public var uploaded: Int64
    public var downloaded: Int64
    public var apps: [AppLine]
    public var appCount: Int
    public var countries: [String]
    public var newApps: [String]
    public var events: [EventLine]
    public var installs: [InstallLine]
    /// Alerts and notices worth opening.
    public var attention: Int
    public var headline: String
    public var seen: Bool
}

/// The night shift: notices when nobody is at the Mac (no keyboard or
/// mouse for five minutes, or asleep), tallies what happens meanwhile, and
/// writes a briefing for when you come back.
public final class NightShift: Sendable {
    public static let shared = NightShift(engine: .shared)

    /// No input for this long means you are away.
    static let awayAfter: Double = 300
    /// Input this recent means you are back.
    static let backWithin: Double = 10
    /// Shorter absences are not worth a briefing.
    static let minAwayMs: Millis = 20 * 60_000
    /// A gap this long between ticks means the Mac slept.
    static let sleepGapMs: Millis = 90_000
    static let keep = 30
    static let file = "nightshift.json"

    /// Installs that ran between two times, from the install watch. Set by
    /// the Protection space at launch; nil until then.
    public static let installs = Mutex<(@Sendable (Millis, Millis) -> [Briefing.InstallLine])?>(nil)

    private struct Shift {
        var loaded = false
        var briefings: [Briefing] = []
        var awaySince: Millis?
        var slept: [[Millis]] = []
        var lastTick: Millis = 0
    }

    private let engine: NetworkEngine
    private let shift = Mutex(Shift())
    private let ticker = Mutex<Task<Void, Never>?>(nil)

    init(engine: NetworkEngine) { self.engine = engine }

    /// Seconds since the last keyboard, mouse or trackpad input.
    public static func idleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }

    public func start() {
        ticker.withLock { task in
            guard task == nil else { return }
            task = Task.detached(priority: .background) { [self] in
                while !Task.isCancelled {
                    tick(now: .now, idle: Self.idleSeconds())
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }
    }

    public func stop() {
        ticker.withLock { $0?.cancel(); $0 = nil }
    }

    private func loadIfNeeded(_ shift: inout Shift) {
        guard !shift.loaded else { return }
        shift.loaded = true
        shift.briefings = JSONStore.load([Briefing].self, from: Self.file) ?? []
    }

    /// One look at the clock and the input: away, back, or asleep.
    func tick(now: Millis, idle: Double) {
        var written: Briefing?
        var toSave: [Briefing]?
        shift.withLock { shift in
            loadIfNeeded(&shift)
            let last = shift.lastTick
            shift.lastTick = now
            // The Mac slept (the lid closed): that counts as away from the start.
            if last > 0, now - last > Self.sleepGapMs {
                if shift.awaySince == nil { begin(&shift, since: last) }
                shift.slept.append([last, now])
            }
            if shift.awaySince == nil, idle >= Self.awayAfter {
                begin(&shift, since: now - Millis(idle * 1000))
            } else if let since = shift.awaySince, idle < Self.backWithin {
                let slept = shift.slept
                shift.slept = []
                shift.awaySince = nil
                let tally = engine.state.withLock { state -> AwayTally? in
                    defer { state.away = nil }
                    return state.away
                }
                if now - since >= Self.minAwayMs, let tally {
                    let briefing = Self.build(kind: "away", apps: tally.apps, events: tally.events, start: since, end: now,
                                              slept: slept, installs: Self.installLines(since, now))
                    shift.briefings.insert(briefing, at: 0)
                    if shift.briefings.count > Self.keep { shift.briefings.removeLast(shift.briefings.count - Self.keep) }
                    toSave = shift.briefings
                    written = briefing
                }
            }
        }
        if let toSave { JSONStore.save(toSave, to: Self.file) }
        if let written {
            engine.push(NetEvent(t: now, kind: "away", severity: .notice, app: "Night shift", text: written.headline))
        }
    }

    private func begin(_ shift: inout Shift, since: Millis) {
        shift.awaySince = since
        shift.slept = []
        engine.state.withLock { $0.away = AwayTally() }
    }

    static func installLines(_ start: Millis, _ end: Millis) -> [Briefing.InstallLine] {
        installs.withLock { $0 }?(start, end) ?? []
    }

    // MARK: Reading

    public var briefings: [Briefing] {
        shift.withLock { loadIfNeeded(&$0); return $0.briefings }
    }

    /// The newest briefing not opened yet.
    public var unseen: Briefing? { briefings.first { !$0.seen } }

    public func markSeen(_ id: Int64) {
        let list = shift.withLock { shift -> [Briefing] in
            loadIfNeeded(&shift)
            for i in shift.briefings.indices where shift.briefings[i].id == id { shift.briefings[i].seen = true }
            return shift.briefings
        }
        JSONStore.save(list, to: Self.file)
    }

    public struct Status: Sendable {
        public var away: Bool
        public var since: Millis?
        public var idleSeconds: Double
        public init(away: Bool, since: Millis?, idleSeconds: Double) {
            self.away = away
            self.since = since
            self.idleSeconds = idleSeconds
        }
    }

    public var status: Status {
        let since = shift.withLock { $0.awaySince }
        return Status(away: since != nil, since: since, idleSeconds: Self.idleSeconds())
    }

    /// Briefings that overlap a window (for the assistant).
    public func between(_ from: Millis, _ to: Millis) -> [Briefing] {
        briefings.filter { $0.end >= from && $0.start <= to }
    }

    /// "What happened in the last hour?", from the replay history, without
    /// waiting to be away.
    public func brief(minutes: Int, now: Millis = .now) -> Briefing {
        let start = now - Millis(min(max(minutes, 1), 60)) * 60_000
        let (apps, events, slept) = engine.state.withLock { state -> ([String: Tally], [NetEvent], [[Millis]]) in
            var apps: [String: Tally] = [:]
            var slept: [[Millis]] = []
            var previous: Millis?
            for frame in state.frames where frame.t >= start {
                let gap = previous.map { frame.t - $0 } ?? 3_000
                if gap > Self.sleepGapMs, let from = previous { slept.append([from, frame.t]) }
                previous = frame.t
                // Rates are per second; a frame stands for the time since the last.
                let seconds = min(gap, 15_000) / 1000
                for edge in frame.edges {
                    var part = Tally(bytesIn: edge.rateIn * seconds, bytesOut: edge.rateOut * seconds)
                    if let country = edge.place?.country { part.countries.insert(country) }
                    part.hosts.insert(edge.host)
                    apps[edge.app, default: Tally()].merge(part)
                }
            }
            return (apps, state.events.filter { $0.t >= start }, slept)
        }
        return Self.build(kind: "brief", apps: apps, events: events, start: start, end: now, slept: slept,
                          installs: Self.installLines(start, now))
    }

    // MARK: Writing

    static func build(kind: String, apps: [String: Tally], events: [NetEvent], start: Millis, end: Millis,
                      slept: [[Millis]], installs: [Briefing.InstallLine]) -> Briefing {
        var lines = apps.map { name, tally in
            Briefing.AppLine(name: name, bytesIn: tally.bytesIn, bytesOut: tally.bytesOut,
                             countries: tally.countries.sorted(), hosts: Array(tally.hosts.sorted().prefix(12)))
        }.sorted { ($0.bytesOut * 4 + $0.bytesIn, $1.name) > ($1.bytesOut * 4 + $1.bytesIn, $0.name) }
        let countries = Set(lines.flatMap(\.countries)).sorted()
        let eventLines = events.reversed().prefix(120).map {
            Briefing.EventLine(t: $0.t, kind: $0.kind, severity: $0.severity.rawValue, subject: $0.app, text: $0.text)
        }
        let newApps = eventLines.filter { $0.kind == "firstApp" }.map(\.subject)
        let attention = eventLines.filter { ($0.severity == "alert" || $0.kind != "firstApp") && $0.kind != "away" }.count
            + installs.filter { $0.verdict != "info" }.count
        let uploaded = lines.reduce(0) { $0 + $1.bytesOut }
        let downloaded = lines.reduce(0) { $0 + $1.bytesIn }
        let count = lines.count
        lines = Array(lines.prefix(12))
        var briefing = Briefing(
            id: end, kind: kind, start: start, end: end, slept: slept, sleptMs: slept.reduce(0) { $0 + ($1.count == 2 ? $1[1] - $1[0] : 0) },
            uploaded: uploaded, downloaded: downloaded, apps: lines, appCount: count, countries: countries, newApps: newApps,
            events: Array(eventLines), installs: installs, attention: attention, headline: "", seen: kind == "brief")
        briefing.headline = headline(briefing)
        return briefing
    }

    static func headline(_ b: Briefing) -> String {
        let moved = Format.bytes(b.uploaded + b.downloaded)
        if b.attention == 0 {
            return "Quiet. \(moved) moved by \(Format.count(b.appCount, "app")), nothing out of pattern."
        }
        let first = (b.events.first { $0.severity == "alert" } ?? b.events.first)?.text ?? ""
        return "\(Format.count(b.attention, "thing")) to look at. \(first)".trimmingCharacters(in: .whitespaces)
    }
}
