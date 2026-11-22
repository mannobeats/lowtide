import Foundation

/// How big the step to a newer version is.
public enum VersionBump: String, Codable, Sendable, Hashable {
    case major, minor, patch
    /// Newer, but not by a numbered release segment (revision, build, date).
    case other
}

/// Lenient version comparison that works across every ecosystem we scan:
/// semver (`1.2.3-beta.1`), Go (`v0.21.0`, pseudo-versions), Homebrew
/// revisions (`1.2.3_1`), cask builds (`1.2,345`) and date versions.
public enum PackageVersion {
    enum Part: Comparable {
        case number(UInt64)
        case text(String)

        static func < (a: Part, b: Part) -> Bool {
            switch (a, b) {
            case let (.number(x), .number(y)): x < y
            case let (.text(x), .text(y)): x < y
            // A number sorts before text.
            case (.number, .text): true
            case (.text, .number): false
            }
        }
    }

    struct Parsed {
        var release: [UInt64] = []
        /// Everything after the numbered release, compared part by part.
        var tail: [Part] = []
        var prerelease = false
    }

    static func parse(_ raw: String) -> Parsed {
        var version = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        if version.hasPrefix("v") || version.hasPrefix("V") { version = version.dropFirst() }
        // Build metadata never orders versions; cask `,build` suffixes do, so
        // they become part of the tail instead of being dropped.
        version = version.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).first ?? version
        let main: Substring, pre: Substring?
        if let dash = version.firstIndex(of: "-") {
            main = version[..<dash]
            pre = version[version.index(after: dash)...]
        } else {
            main = version
            pre = nil
        }

        var parsed = Parsed()
        var inRelease = true
        var marked = false
        for piece in main.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "." || $0 == "_" || $0 == "," }) {
            if !inRelease {
                parsed.tail += splitAlphanumeric(piece)
                continue
            }
            if let number = UInt64(piece) {
                parsed.release.append(number)
                continue
            }
            // `0rc1`, `beta1`: the leading number still counts as release.
            inRelease = false
            let digits = piece.prefix { $0.isASCII && $0.isNumber }
            if let number = UInt64(digits) { parsed.release.append(number) }
            let rest = piece.dropFirst(digits.count)
            marked = isPrereleaseMarker(rest)
            parsed.tail += splitAlphanumeric(rest)
        }
        parsed.prerelease = marked || (pre.map { !$0.isEmpty } ?? false)
        if let pre {
            for piece in pre.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "." || $0 == "-" }) {
                parsed.tail += splitAlphanumeric(piece)
            }
        }
        return parsed
    }

    /// `rc1`, `beta`, `dev3`, PEP 440 `a1`/`b2`. A bare letter (`1.1.1a`) is
    /// a later patch, not a prerelease.
    static func isPrereleaseMarker(_ text: Substring) -> Bool {
        let lower = text.lowercased()
        if ["alpha", "beta", "rc", "pre", "dev", "preview"].contains(where: { lower.hasPrefix($0) }) { return true }
        let chars = Array(lower.utf8)
        guard chars.count >= 2 else { return false }
        return [UInt8(ascii: "a"), UInt8(ascii: "b"), UInt8(ascii: "c")].contains(chars[0])
            && (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(chars[1])
    }

    /// `rc12` becomes `[text("rc"), number(12)]`, so `rc2 < rc12`.
    static func splitAlphanumeric(_ piece: Substring) -> [Part] {
        var parts: [Part] = []
        var current = ""
        var digits = false
        func flush() {
            guard !current.isEmpty else { return }
            if digits, let number = UInt64(current) {
                parts.append(.number(number))
            } else {
                parts.append(.text(current.lowercased()))
            }
            current = ""
        }
        for character in piece {
            let isDigit = character.isASCII && character.isNumber
            if !current.isEmpty, isDigit != digits { flush() }
            digits = isDigit
            current.append(character)
        }
        flush()
        return parts
    }

    /// Orders two versions: `.orderedAscending` when `a` is older.
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let (left, right) = (parse(a), parse(b))
        for index in 0..<max(left.release.count, right.release.count) {
            let x = index < left.release.count ? left.release[index] : 0
            let y = index < right.release.count ? right.release[index] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        // Same release: a prerelease sorts before the final version.
        if left.prerelease != right.prerelease { return left.prerelease ? .orderedAscending : .orderedDescending }
        if left.tail == right.tail { return .orderedSame }
        return left.tail.lexicographicallyPrecedes(right.tail) ? .orderedAscending : .orderedDescending
    }

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }

    /// The newest of several versions.
    public static func newest<S: Sequence>(_ versions: S) -> String? where S.Element == String {
        versions.max { compare($0, $1) == .orderedAscending }
    }

    /// How big the step from `current` to `latest` is, or nil when `latest`
    /// is not newer.
    public static func bump(from current: String, to latest: String) -> VersionBump? {
        guard !current.trimmingCharacters(in: .whitespaces).isEmpty, isNewer(latest, than: current) else { return nil }
        let (now, next) = (parse(current), parse(latest))
        func at(_ p: Parsed, _ i: Int) -> UInt64 { i < p.release.count ? p.release[i] : 0 }
        // Below 1.0 the minor number carries breaking changes (semver §4).
        let first = at(now, 0) == 0 && at(next, 0) == 0 ? 1 : 0
        if at(next, first) != at(now, first) { return .major }
        if at(next, first + 1) != at(now, first + 1) { return first == 0 ? .minor : .patch }
        if first == 0, at(next, 2) != at(now, 2) { return .patch }
        return .other
    }

    /// Whether a version is a prerelease, so "latest" lookups can skip it.
    public static func isPrerelease(_ version: String) -> Bool { parse(version).prerelease }
}
