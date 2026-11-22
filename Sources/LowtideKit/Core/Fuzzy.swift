import Foundation

/// Ranks a candidate against what was typed: every typed character must
/// appear in order. Word starts, consecutive runs and a prefix score higher.
/// `nil` when it doesn't match.
public enum Fuzzy {
    public static func score(_ query: String, _ candidate: String) -> Int? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !q.isEmpty else { return 0 }
        let c = Array(candidate.lowercased())
        var score = 0, qi = 0, run = 0
        var previous: Character = " "
        for (index, ch) in c.enumerated() {
            guard qi < q.count else { break }
            if ch == q[qi] {
                let wordStart = index == 0 || previous == " " || previous == "/" || previous == "-" || previous == "."
                score += 1 + (wordStart ? 8 : 0) + run * 4 + (index == qi ? 6 : 0)
                run += 1
                qi += 1
            } else {
                run = 0
            }
            previous = ch
        }
        guard qi == q.count else { return nil }
        return score * 100 / max(c.count, 1) + score
    }

    /// The best score over a title and extra keywords (keywords count less).
    public static func best(_ query: String, title: String, keywords: String = "") -> Int? {
        let main = score(query, title)
        let words = keywords.isEmpty ? nil : keywords.split(separator: " ").compactMap { score(query, String($0)) }.max().map { $0 / 2 }
        switch (main, words) {
        case (nil, nil): return nil
        case let (a?, b?): return max(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        }
    }
}
