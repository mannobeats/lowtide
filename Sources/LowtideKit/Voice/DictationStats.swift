import Foundation

/// One stretch of dictation added up.
public struct DictationTally: Codable, Equatable, Sendable {
    public var dictations = 0
    public var words = 0
    public var seconds = 0.0
    public var elapsedMs = 0

    public init(dictations: Int = 0, words: Int = 0, seconds: Double = 0, elapsedMs: Int = 0) {
        self.dictations = dictations
        self.words = words
        self.seconds = seconds
        self.elapsedMs = elapsedMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dictations = try c.decodeIfPresent(Int.self, forKey: .dictations) ?? 0
        words = try c.decodeIfPresent(Int.self, forKey: .words) ?? 0
        seconds = try c.decodeIfPresent(Double.self, forKey: .seconds) ?? 0
        elapsedMs = try c.decodeIfPresent(Int.self, forKey: .elapsedMs) ?? 0
    }

    public static func + (a: DictationTally, b: DictationTally) -> DictationTally {
        DictationTally(dictations: a.dictations + b.dictations, words: a.words + b.words,
              seconds: a.seconds + b.seconds, elapsedMs: a.elapsedMs + b.elapsedMs)
    }
}

/// Running totals, without a word of what was said, so they count with
/// history off too. Saved as `dictation-stats.json`.
public struct DictationStats: Codable, Equatable, Sendable {
    /// Local day (days since 1970, as a string key) to that day's totals.
    public var days: [String: DictationTally] = [:]
    public var models: [String: DictationTally] = [:]
    /// App name to dictations typed into it.
    public var apps: [String: Int] = [:]
    /// Dictations that heard nothing, and ones that ended in an error.
    public var empty = 0
    public var failed = 0
    /// Unix milliseconds counting began.
    public var since: Int64 = 0

    /// A typist's pace, for the time dictation saved.
    public static let typingWPM = 40.0

    public init(since: Int64 = 0) { self.since = since }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        days = try c.decodeIfPresent([String: DictationTally].self, forKey: .days) ?? [:]
        models = try c.decodeIfPresent([String: DictationTally].self, forKey: .models) ?? [:]
        apps = try c.decodeIfPresent([String: Int].self, forKey: .apps) ?? [:]
        empty = try c.decodeIfPresent(Int.self, forKey: .empty) ?? 0
        failed = try c.decodeIfPresent(Int.self, forKey: .failed) ?? 0
        since = try c.decodeIfPresent(Int64.self, forKey: .since) ?? 0
    }

    public mutating func add(at ms: Int64, model: String, app: String, words: Int, seconds: Double,
                             elapsedMs: Int, zone: TimeZone = .current) {
        let one = DictationTally(dictations: 1, words: words, seconds: seconds, elapsedMs: elapsedMs)
        let day = String(Self.localDay(ms, zone: zone))
        days[day] = (days[day] ?? DictationTally()) + one
        models[model] = (models[model] ?? DictationTally()) + one
        if !app.isEmpty { apps[app, default: 0] += 1 }
    }

    /// The day of `ms` in `zone`, as days since 1970, with that instant's own
    /// offset (using today's for every day would put a dictation near
    /// midnight across a daylight-saving change a day off).
    public static func localDay(_ ms: Int64, zone: TimeZone = .current) -> Int {
        let seconds = Double(ms) / 1000
        let offset = Double(zone.secondsFromGMT(for: Date(timeIntervalSince1970: seconds)))
        return Int(((seconds + offset) / 86_400).rounded(.down))
    }

    public static func today(_ now: Date = Date(), zone: TimeZone = .current) -> Int {
        localDay(UnixTime.ms(now), zone: zone)
    }

    /// The days from `from` (nil: all of them) to today, added up.
    public func total(from: Int? = nil) -> DictationTally {
        days.reduce(DictationTally()) { sum, entry in
            guard let from else { return sum + entry.value }
            return (Int(entry.key) ?? .min) >= from ? sum + entry.value : sum
        }
    }

    /// Anything has been counted at all.
    public var counted: Bool { total().dictations + empty + failed > 0 }

    /// Words a minute while speaking.
    public var pace: Int {
        let all = total()
        return all.seconds > 0 ? Int((Double(all.words) / (all.seconds / 60)).rounded()) : 0
    }

    /// Seconds saved against typing at `typingWPM`.
    public var saved: Double {
        let all = total()
        return max(0, Double(all.words) / Self.typingWPM * 60 - all.seconds - Double(all.elapsedMs) / 1000)
    }

    /// The apps dictated into most, most first.
    public func topApps(_ count: Int = 5) -> [(app: String, count: Int)] {
        apps.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(count).map { ($0.key, $0.value) }
    }

    /// Each model's speed: seconds of speech per second of waiting, the
    /// most used first.
    public var speeds: [(model: String, ratio: Double, dictations: Int)] {
        models.filter { $0.value.elapsedMs > 0 && $0.value.seconds > 0 }
            .sorted { $0.value.dictations != $1.value.dictations ? $0.value.dictations > $1.value.dictations : $0.key < $1.key }
            .map { ($0.key, $0.value.seconds / (Double($0.value.elapsedMs) / 1000), $0.value.dictations) }
    }

    /// Words a day for the `count` days up to `today`, oldest first.
    public func strip(today: Int, count: Int = 30) -> [(day: Int, words: Int)] {
        (0..<count).map { i in
            let day = today - count + 1 + i
            return (day, days[String(day)]?.words ?? 0)
        }
    }

    /// Totals worked out from the history kept so far, for the first time
    /// stats are read.
    public static func rebuilt(from history: [DictationEntry], now: Int64, zone: TimeZone = .current) -> DictationStats {
        var stats = DictationStats(since: now)
        for entry in history {
            stats.since = min(stats.since, entry.at)
            stats.add(at: entry.at, model: entry.model, app: entry.app, words: wordCount(entry.text),
                      seconds: entry.seconds, elapsedMs: entry.elapsedMs, zone: zone)
        }
        return stats
    }
}

/// `45 s`, `12 min`, `3 h 20 min`.
public func spokenDuration(_ seconds: Double) -> String {
    if seconds < 59.5 { return "\(Int(seconds.rounded())) s" }
    let minutes = Int((seconds / 60).rounded())
    if minutes < 60 { return "\(minutes) min" }
    let rest = minutes % 60
    return "\(minutes / 60) h" + (rest > 0 ? " \(rest) min" : "")
}

/// The stats file. Counts only, never the words.
public actor DictationStatsStore {
    private let url: URL
    private let history: DictationHistory

    public init(url: URL = JSONStore.url("dictation-stats.json"), history: DictationHistory) {
        self.url = url
        self.history = history
    }

    /// The saved totals; the first time, worked out from history and saved,
    /// so clearing history later doesn't take them away.
    public func load(now: Int64 = UnixTime.ms()) async -> DictationStats {
        if let data = try? Data(contentsOf: url), let stats = try? JSONDecoder().decode(DictationStats.self, from: data) {
            return stats
        }
        let stats = DictationStats.rebuilt(from: await history.load(), now: now)
        JSONStore.write(stats, to: url)
        return stats
    }

    public func change(_ edit: @Sendable (inout DictationStats) -> Void) async {
        var stats = await load()
        edit(&stats)
        JSONStore.write(stats, to: url)
    }

    /// Adds one dictation: the counts only.
    public func count(_ result: DictationResult, now: Int64 = UnixTime.ms()) async {
        let words = wordCount(result.text)
        await change { $0.add(at: now, model: result.model, app: result.app, words: words,
                              seconds: result.seconds, elapsedMs: result.elapsedMs) }
    }

    /// Starts over from now: an empty file, so they aren't rebuilt from history.
    public func reset(now: Int64 = UnixTime.ms()) {
        JSONStore.write(DictationStats(since: now), to: url)
    }
}
