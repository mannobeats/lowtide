import Foundation

/// One dictation kept in history, on this Mac only. The file is
/// `dictation-history.json`, a list of these, so an imported one reads.
public struct DictationEntry: Codable, Identifiable, Hashable, Sendable {
    /// Unix milliseconds when it was kept; also its id.
    public var id: Int64
    public var text: String
    public var raw: String
    public var app: String
    public var bundleId: String
    public var model: String
    public var seconds: Double
    public var elapsedMs: Int
    /// Unix milliseconds.
    public var at: Int64

    public init(id: Int64, text: String, raw: String = "", app: String = "", bundleId: String = "",
                model: String = "", seconds: Double = 0, elapsedMs: Int = 0, at: Int64) {
        self.id = id
        self.text = text
        self.raw = raw
        self.app = app
        self.bundleId = bundleId
        self.model = model
        self.seconds = seconds
        self.elapsedMs = elapsedMs
        self.at = at
    }

    public var date: Date { Date(timeIntervalSince1970: Double(at) / 1000) }
}

/// What history keeps, and for how long.
public struct HistoryRules: Equatable, Sendable {
    /// 0 keeps entries until cleared.
    public var keepDays: Int
    public var excluded: Set<String>

    public init(keepDays: Int, excluded: Set<String>) {
        self.keepDays = keepDays
        self.excluded = excluded
    }

    public init(_ prefs: VoicePrefs) {
        self.init(keepDays: prefs.keepDays, excluded: prefs.excludedIDs)
    }

    /// Drops what's past its days or from an app since left out; true when
    /// anything went.
    @discardableResult
    public func prune(_ entries: inout [DictationEntry], now: Int64) -> Bool {
        let cutoff = now - Int64(max(keepDays, 0)) * 86_400_000
        let before = entries.count
        entries.removeAll { (keepDays > 0 && $0.at < cutoff) || excluded.contains($0.bundleId) }
        return entries.count != before
    }
}

/// The history file. One writer at a time.
public actor DictationHistory {
    public static let limit = 500
    private let url: URL

    public init(url: URL = JSONStore.url("dictation-history.json")) {
        self.url = url
    }

    public func load() -> [DictationEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([DictationEntry].self, from: data)) ?? []
    }

    private func save(_ entries: [DictationEntry]) {
        JSONStore.write(entries, to: url)
    }

    /// History as the rules now allow, saved back if that dropped any.
    public func tidy(_ rules: HistoryRules, now: Int64 = UnixTime.ms()) -> [DictationEntry] {
        var entries = load()
        if rules.prune(&entries, now: now) { save(entries) }
        return entries
    }

    /// Keeps a result unless it came from a password field or a left-out app.
    @discardableResult
    public func remember(_ result: DictationResult, rules: HistoryRules, now: Int64 = UnixTime.ms()) -> Bool {
        guard !result.secure, !rules.excluded.contains(result.bundleId), !result.text.isEmpty else { return false }
        var entries = load()
        // Two in the same millisecond keep apart.
        let id = max(now, (entries.first?.id ?? 0) + 1)
        entries.insert(DictationEntry(
            id: id, text: result.text, raw: result.raw, app: result.app, bundleId: result.bundleId,
            model: result.model, seconds: result.seconds, elapsedMs: result.elapsedMs, at: now), at: 0)
        rules.prune(&entries, now: now)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        save(entries)
        return true
    }

    /// Forgets one entry, or all of them when `id` is nil.
    public func forget(_ id: Int64?) {
        var entries = load()
        if let id { entries.removeAll { $0.id == id } } else { entries.removeAll() }
        save(entries)
    }

    /// The newest text, for Paste and Copy last dictation after a restart.
    public func newest() -> String? {
        load().first.map(\.text).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// The time, in the units the files use.
public enum UnixTime {
    public static func ms(_ date: Date = Date()) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
}
