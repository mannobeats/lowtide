import Foundation

/// Matching and ranking for the command bar.
///
/// Every query word must match the row somewhere (title or keywords): as a
/// whole word, a word start, anywhere, or, for words of three letters or
/// more, as letters in order or one typo away. Then learned habits and names
/// you gave a row come first, then how well the whole query matches the
/// title, then score plus how often you use the row.
public enum Ranking {
    /// Case-, accent- and width-insensitive form, whitespace collapsed.
    public static func fold(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.decomposedStringWithCompatibilityMapping.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: continue
            default: break
            }
            if Answers.isInvisible(scalar) { continue }
            scalars.append(scalar)
        }
        return String(scalars).lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public struct Candidate: Sendable {
        /// Folded keywords (alias included).
        public var keywords: String
        /// Folded title, and its words.
        public var title: String
        public var titleWords: [String]
        /// Title words then keyword words.
        public var words: [String]

        public init(title: String, keywords: [String]) {
            self.title = fold(title)
            self.keywords = fold(keywords.joined(separator: " "))
            titleWords = self.title.split(separator: " ").map(String.init)
            words = titleWords + self.keywords.split(separator: " ").map(String.init)
        }
    }

    static func isSubsequence(_ token: [Character], _ word: String) -> Bool {
        var i = 0
        for ch in word where ch == token[i] {
            i += 1
            if i == token.count { return true }
        }
        return false
    }

    /// One swap of neighbouring letters turns `a` into `b`.
    static func isTransposition(_ a: [Character], _ b: [Character]) -> Bool {
        guard a.count == b.count else { return false }
        var diff: [Int] = []
        for i in a.indices where a[i] != b[i] {
            diff.append(i)
            if diff.count > 2 { return false }
        }
        return diff.count == 2 && diff[1] == diff[0] + 1 && a[diff[0]] == b[diff[1]] && a[diff[1]] == b[diff[0]]
    }

    /// Within one substitution, insertion, deletion or neighbour swap.
    static func withinOneEdit(_ a: [Character], _ b: [Character]) -> Bool {
        guard abs(a.count - b.count) <= 1 else { return false }
        if a.count == b.count {
            let diffs = zip(a, b).count { $0 != $1 }
            return diffs <= 1 || isTransposition(a, b)
        }
        let (short, long) = a.count < b.count ? (a, b) : (b, a)
        var i = 0, j = 0, skipped = false
        while i < short.count, j < long.count {
            if short[i] == long[j] {
                i += 1
                j += 1
            } else if skipped {
                return false
            } else {
                skipped = true
                j += 1
            }
        }
        return true
    }

    static func fuzzyTokenScore(_ token: String, _ words: [String]) -> Int {
        guard token.count >= 3, !token.allSatisfy(\.isASCIIDigit) else { return 0 }
        let t = Array(token)
        if words.contains(where: { isSubsequence(t, $0) }) { return 24 }
        if words.contains(where: { isTransposition(t, Array($0)) }) { return 16 }
        if t.count >= 4, words.contains(where: { withinOneEdit(t, Array($0)) }) { return 16 }
        return 0
    }

    static func tokenScore(_ token: String, _ c: Candidate) -> Int {
        if c.words.contains(token) { return 140 }
        if c.words.contains(where: { $0.hasPrefix(token) }) { return 80 }
        if c.title.contains(token) || c.keywords.contains(token) { return 44 }
        return fuzzyTokenScore(token, c.words)
    }

    public struct TextMatch: Equatable, Sendable {
        public var score: Int
        /// 5 title equal · 4 title prefix · 3 title contains · 2 keywords · 1 words only
        public var tier: Int
    }

    /// How well a folded query matches; nil when some word doesn't match.
    public static func textMatch(_ query: String, _ c: Candidate) -> TextMatch? {
        guard !query.isEmpty else { return TextMatch(score: 0, tier: 0) }
        var score = 0
        for token in query.split(separator: " ") {
            let s = tokenScore(String(token), c)
            if s == 0 { return nil }
            score += s
        }
        if c.title == query { return TextMatch(score: score + 1200, tier: 5) }
        if c.title.hasPrefix(query) { return TextMatch(score: score + 900, tier: 4) }
        if c.title.contains(query) { return TextMatch(score: score + 700, tier: 3) }
        if c.keywords.contains(query) { return TextMatch(score: score + 350, tier: 2) }
        // A loose match: of two titles that match equally, the shorter one
        // is the more precise ("Packets" over "Capture packets").
        return TextMatch(score: score + max(0, 6 - c.titleWords.count), tier: 1)
    }

    /// Frecency: how often, weighted by how recently. At most 480.
    public static func usageBoost(_ use: BarUsage?, now: Date = .now) -> Int {
        guard let use else { return 0 }
        let age = now.timeIntervalSince(use.lastUsed)
        let hour = 3600.0
        let weight = age < 2 * hour ? 12 : age < 48 * hour ? 8 : age < 14 * 24 * hour ? 5 : 2
        return min(use.count, 40) * weight
    }

    /// 2400 when an alias word is the query, 1100 when it starts with it.
    public static func aliasHit(_ query: String, _ alias: String?) -> Int {
        guard let alias, !alias.isEmpty, !query.isEmpty else { return 0 }
        let joined = fold(alias)
        let words = joined.split(separator: " ").map(String.init)
        if words.contains(query) || joined == query { return 2400 }
        if words.contains(where: { $0.hasPrefix(query) }) || joined.hasPrefix(query) { return 1100 }
        return 0
    }

    /// Where the query matched the title literally, as character offsets,
    /// for bold highlighting.
    public static func highlights(_ title: String, _ query: String) -> [Range<Int>] {
        let folded = fold(query)
        let lower = Array(title.lowercased())
        guard !folded.isEmpty, lower.count == title.count else { return [] }
        var ranges: [Range<Int>] = []
        for token in folded.split(separator: " ").map(Array.init) where token.count <= lower.count {
            var first: Int?
            var wordStart: Int?
            for at in 0...(lower.count - token.count) where Array(lower[at..<at + token.count]) == token {
                if first == nil { first = at }
                if at == 0 || !(lower[at - 1].isLetter || lower[at - 1].isNumber) {
                    wordStart = at
                    break
                }
            }
            if let at = wordStart ?? first { ranges.append(at..<at + token.count) }
        }
        return ranges.sorted { $0.lowerBound < $1.lowerBound }
    }
}

/// What you pick after typing what, in memory only (never written to disk):
/// "te" then Return on Terminal teaches the bar to put Terminal first.
public struct BarHabits: Sendable {
    struct Habit: Sendable {
        var id: String
        var count: Int
        var lastUsed: Date
    }

    private var byPrefix: [String: [Habit]] = [:]
    static let maxPrefixes = 320
    static let idsPerPrefix = 4
    static let longestPrefix = 24

    public init() {}

    /// Learns that `query` led to `id`.
    public mutating func learn(_ query: String, id: String, now: Date = .now) {
        let folded = Array(Ranking.fold(query.hasPrefix(":") ? String(query.dropFirst()) : query))
        guard !folded.isEmpty else { return }
        for n in 1...min(folded.count, Self.longestPrefix) {
            let prefix = String(folded[..<n])
            var list = byPrefix[prefix] ?? []
            if let at = list.firstIndex(where: { $0.id == id }) {
                list[at].count += 1
                list[at].lastUsed = now
            } else {
                list.append(Habit(id: id, count: 1, lastUsed: now))
            }
            list.sort { ($0.count, $0.lastUsed) > ($1.count, $1.lastUsed) }
            byPrefix[prefix] = Array(list.prefix(Self.idsPerPrefix))
        }
        if byPrefix.count > Self.maxPrefixes {
            let stalest = byPrefix.sorted { a, b in
                (a.value.map(\.lastUsed).max() ?? .distantPast) < (b.value.map(\.lastUsed).max() ?? .distantPast)
            }
            for (key, _) in stalest.prefix(byPrefix.count - Self.maxPrefixes) { byPrefix[key] = nil }
        }
    }

    /// The learned boost for a row under this folded query (at most 720).
    /// `exact` when it was picked after typing this very query: only then
    /// does the habit outrank a better text match.
    public func boost(_ query: String, id: String, now: Date = .now) -> (boost: Int, exact: Bool) {
        let chars = Array(query)
        let longest = min(chars.count, Self.longestPrefix)
        guard longest > 0 else { return (0, false) }
        for n in stride(from: longest, through: 1, by: -1) {
            if let hit = byPrefix[String(chars[..<n])]?.first(where: { $0.id == id }) {
                let use = BarUsage(count: hit.count, lastUsed: hit.lastUsed)
                return (min(Ranking.usageBoost(use, now: now) * 5 + n * 6, 720), n == longest)
            }
        }
        return (0, false)
    }

    public mutating func forget() { byPrefix.removeAll() }
}
