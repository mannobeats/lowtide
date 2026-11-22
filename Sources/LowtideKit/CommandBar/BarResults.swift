import Foundation

/// What the bar lists for a query: ranked rows and section headings.
public struct BarResults {
    /// Row index → section heading.
    public var headings: [Int: String] = [:]
    public var rows: [BarRow] = []

    public init(headings: [Int: String] = [:], rows: [BarRow] = []) {
        self.headings = headings
        self.rows = rows
    }

    /// How many leading rows ⌘1–9 reach as Quick access (0 off the empty bar).
    public var quickCount: Int {
        guard headings[0] == BarSearch.quickAccess else { return 0 }
        let next = headings.keys.filter { $0 > 0 }.min()
        return min(9, next ?? rows.count)
    }
}

/// Everything searchable for one opening of the bar.
public struct BarPools {
    public var answer: BarRow?
    /// Everything searchable, in pool order (extensions, Lowtide, tools, …).
    public var catalog: [BarRow] = []
    public var emoji: [BarRow] = []
    public var files: [BarRow] = []
    public var quit: [BarRow] = []
    public var script: BarRow?
    public var url: BarRow?

    public init() {}
}

/// Assembles the list: the empty bar (Quick access, most used, suggestions,
/// groups), a category's own list, or the typed search across every source.
public struct BarSearch {
    public var prefs: BarPrefs
    public var habits: BarHabits
    public var now: Date

    public init(prefs: BarPrefs, habits: BarHabits = BarHabits(), now: Date = .now) {
        self.prefs = prefs
        self.habits = habits
        self.now = now
    }

    static let quickAccess = "Quick access"
    static let maxRows = 12
    static let maxCategory = 40
    /// Room for every extension on the empty bar.
    static let maxGroup = 16
    static let suggestions = 6

    static let bias: [BarSource: Int] = [
        .apps: 80, .files: -40, .macSettings: -40,
        // Lowtide's own Processes page before Activity Monitor; what you pick
        // still teaches the bar (habits outrank this).
        .lowtide: 90,
    ]
    static let caps: [BarSource: Int] = [.apps: 5, .emoji: 6, .files: 4, .folders: 4, .macSettings: 4, .quit: 3]

    /// Suggestions before any habit forms.
    static let curated = [
        "lowtide.ask", "lowtide.page:network/live", "lowtide.page:protection/permissions", "tools.pickColor", "tools.awake",
        "action.darkMode", "action.lockScreen", "ext.processes", "ext.emoji",
    ]

    /// Pinned rows outrank any amount of use (usage tops out at 480).
    static let pinBoost = 500
    /// Quick access whose name holds the query beats any other row's exact
    /// name; only your own names (aliases, 1100+) rank higher.
    static let quickPriority = 1000
    static let titleTier = 3

    func visible(_ row: BarRow) -> Bool {
        !prefs.hidden.contains(row.stableKey) && !prefs.disabled.contains(row.source)
    }

    struct Ranked {
        var boost: Int, index: Int, priority: Int, score: Int, tier: Int
        var row: BarRow

        static func before(_ a: Ranked, _ b: Ranked) -> Bool {
            if a.priority != b.priority { return a.priority > b.priority }
            if a.tier != b.tier { return a.tier > b.tier }
            if a.score + a.boost != b.score + b.boost { return a.score + a.boost > b.score + b.boost }
            return a.index < b.index
        }
    }

    func rank(_ rows: [BarRow], _ query: String) -> [BarRow] {
        var ranked: [Ranked] = []
        for (index, row) in rows.enumerated() {
            let alias = prefs.aliases[row.stableKey]
            let candidate = alias.map { Ranking.Candidate(title: row.title, keywords: row.keywords + [$0]) }
                ?? row.candidate ?? Ranking.Candidate(title: row.title, keywords: row.keywords)
            guard let match = Ranking.textMatch(query, candidate) else { continue }
            let habit = habits.boost(query, id: row.id, now: now)
            let hit = Ranking.aliasHit(query, alias)
            var boost = (row.active ? 20 : 0) + (Self.bias[row.source] ?? 0)
            boost += row.counts ? Ranking.usageBoost(prefs.usage[row.id], now: now) : 0
            let pinned = prefs.pins.contains(row.stableKey)
            boost += pinned ? Self.pinBoost : 0
            boost += habit.exact ? 0 : habit.boost
            let quick = pinned && match.tier >= Self.titleTier ? Self.quickPriority : 0
            ranked.append(Ranked(boost: boost, index: index, priority: max(hit, habit.exact ? habit.boost : 0, quick),
                                 score: match.score, tier: match.tier, row: row))
        }
        return ranked.sorted(by: Ranked.before).map(\.row)
    }

    /// "Quit" typed as a word or the start of one.
    static func wantsQuit(_ query: String) -> Bool {
        query.split(separator: " ").contains { t in t.count >= 2 && ("quit".hasPrefix(t) || t.hasPrefix("quit")) }
    }

    /// Mac facts only surface once the first word is 3+ letters of their title.
    static func answerAllowed(_ row: BarRow, _ query: String) -> Bool {
        guard row.source == .answers else { return true }
        let first = query.split(separator: " ").first.map(String.init) ?? ""
        return first.count >= 3 && Ranking.fold(row.title).hasPrefix(first)
    }

    static func capped(_ rows: [BarRow], _ query: String) -> [BarRow] {
        var counts: [BarSource: Int] = [:]
        var out: [BarRow] = []
        for row in rows where answerAllowed(row, query) {
            let n = counts[row.source] ?? 0
            if let cap = caps[row.source], n >= cap { continue }
            counts[row.source] = n + 1
            out.append(row)
            if out.count >= maxRows { break }
        }
        return out
    }

    static func unique(_ rows: [BarRow]) -> [BarRow] {
        var seen = Set<String>()
        return rows.filter { seen.insert($0.id).inserted }
    }

    /// The typed search across every source.
    func search(_ raw: String, _ pools: BarPools) -> BarResults {
        let query = Ranking.fold(raw)
        if raw.hasPrefix(":") {
            let emoji = rank(pools.emoji.filter(visible), Ranking.fold(String(raw.dropFirst())))
            return BarResults(rows: Array(emoji.prefix(Self.maxCategory)))
        }
        let pool = (pools.catalog + (Self.wantsQuit(query) ? pools.quit : []) + pools.files).filter(visible)
        let ranked = Self.capped(rank(pool, query), query)
        let lead = [pools.answer, pools.url, pools.script].compactMap { $0 }
        let preview = lead.first { $0.id == "answer.colorPreview" }
        var rows = Array(Self.unique(lead.filter { $0.id != preview?.id } + ranked).prefix(Self.maxRows))
        if let preview {
            // Second when a row already contains the typed text ("#1234").
            let typed = raw.trimmingCharacters(in: .whitespaces)
            let at = rows.contains { $0.title.contains(typed) } ? min(1, rows.count) : 0
            rows.insert(preview, at: at)
            rows = Array(rows.prefix(Self.maxRows))
        }
        return BarResults(rows: rows)
    }

    /// Pinned first in pin order, then by frecency, then as listed.
    func byUse(_ rows: [BarRow]) -> [BarRow] {
        struct Entry {
            var index: Int, pin: Int, use: Int
            var row: BarRow
        }
        var entries: [Entry] = []
        for (index, row) in rows.enumerated() {
            let use = row.counts ? Ranking.usageBoost(prefs.usage[row.id], now: now) : 0
            entries.append(Entry(index: index, pin: prefs.pins.firstIndex(of: row.stableKey) ?? Int.max, use: use, row: row))
        }
        entries.sort { a, b in
            if a.pin != b.pin { return a.pin < b.pin }
            if a.use != b.use { return a.use > b.use }
            return a.index < b.index
        }
        return entries.map(\.row)
    }

    /// A category: its own rows, ordered by use while browsing.
    func inCategory(_ raw: String, rows: [BarRow], label: String) -> BarResults {
        let shown = rows.filter(visible)
        let query = Ranking.fold(raw.hasPrefix(":") ? String(raw.dropFirst()) : raw)
        let list = query.isEmpty ? byUse(shown) : Array(rank(shown, query).prefix(Self.maxCategory))
        return BarResults(headings: [0: "\(label) · \(list.count)"], rows: list)
    }

    /// The empty bar: Quick access, most used, suggestions, then the catalog by group.
    func home(_ pools: BarPools) -> BarResults {
        var result = BarResults()
        let shown = pools.catalog.filter(visible)
        var byID: [String: BarRow] = [:]
        for row in shown where byID[row.id] == nil { byID[row.id] = row }
        func section(_ label: String, _ list: [BarRow]) {
            guard !list.isEmpty else { return }
            result.headings[result.rows.count] = label
            result.rows += list
        }
        // Pins come from every pool the bar has, so a pinned emoji shows too.
        var pinnable: [String: BarRow] = [:]
        for row in shown + pools.emoji.filter(visible) where pinnable[row.stableKey] == nil { pinnable[row.stableKey] = row }
        let pinned = prefs.pins.compactMap { pinnable[$0] }
        section(Self.quickAccess, pinned)

        var taken = Set(pinned.map(\.id))
        let used = shown.filter { $0.counts && prefs.usage[$0.id] != nil && !taken.contains($0.id) }
            .sorted { a, b in
                let ua = prefs.usage[a.id]!, ub = prefs.usage[b.id]!
                let ba = Ranking.usageBoost(ua, now: now), bb = Ranking.usageBoost(ub, now: now)
                return ba != bb ? ba > bb : ua.lastUsed > ub.lastUsed
            }
        var seenUsed = Set<String>()
        let mostUsed = Array(used.filter { seenUsed.insert($0.id).inserted }.prefix(Self.suggestions))
        section("Most used", mostUsed)
        taken.formUnion(mostUsed.map(\.id))
        // Until habits form, a few starting points fill the rest.
        let suggestions = Self.curated.compactMap { byID[$0] }.filter { !taken.contains($0.id) }
            .prefix(max(0, Self.suggestions - mostUsed.count))
        section("Suggestions", Array(suggestions))
        taken.formUnion(suggestions.map(\.id))

        var order: [String] = []
        var groups: [String: [BarRow]] = [:]
        for row in shown {
            guard let group = row.group, !taken.contains(row.id) else { continue }
            if groups[group] == nil { order.append(group) }
            if groups[group, default: []].count < Self.maxGroup { groups[group, default: []].append(row) }
        }
        for label in order { section(label, groups[label] ?? []) }
        return result
    }

    public func results(_ raw: String, category: (label: String, rows: [BarRow])?, pools: BarPools) -> BarResults {
        if let category { return inCategory(raw, rows: category.rows, label: category.label) }
        if raw.trimmingCharacters(in: .whitespaces).isEmpty { return home(pools) }
        return search(raw, pools)
    }

    /// "volume 40" → rank "volume", run with 40, when a number row matches.
    public static func splitNumber(_ query: String, rows: [BarRow]) -> (text: String, argument: Int?) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard let match = trimmed.firstMatch(of: /^(.*\S)\s+(\d{1,4})%?$/) else { return (query, nil) }
        let text = Ranking.fold(String(match.1))
        let numeric = rows.contains { $0.number != nil && Ranking.textMatch(text, Ranking.Candidate(title: $0.title, keywords: $0.keywords)) != nil }
        return numeric ? (String(match.1), Int(match.2)) : (query, nil)
    }
}
