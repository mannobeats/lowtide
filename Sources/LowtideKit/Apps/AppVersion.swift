import Foundation

/// Lenient version ordering for apps and their feeds: plain releases
/// (`1.2.3`), prereleases (`2.0.0-rc.2`, `7.1.0.beta1`), cask builds
/// (`4.5,123`), Homebrew revisions (`1.2.3_1`) and date versions.
public enum AppVersion {
    enum Part: Comparable, Sendable {
        case number(UInt64)
        case text(String)

        static func < (a: Part, b: Part) -> Bool {
            switch (a, b) {
            case let (.number(x), .number(y)): x < y
            case let (.text(x), .text(y)): x < y
            // As Rust orders its enum: a number sorts before text.
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
        var version = Substring(raw.trimmingCharacters(in: .whitespaces))
        if version.first == "v" || version.first == "V" { version = version.dropFirst() }
        // Build metadata never orders versions; a cask's `,build` does, so it
        // stays in the tail.
        version = version.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).first ?? version
        let main: Substring
        let pre: Substring?
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
        for piece in main.split(omittingEmptySubsequences: false, whereSeparator: { ".,_".contains($0) }) {
            if !inRelease {
                parsed.tail += splitAlnum(piece)
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
            parsed.tail += splitAlnum(rest)
        }
        parsed.prerelease = marked || (pre.map { !$0.isEmpty } ?? false)
        if let pre {
            for piece in pre.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "." || $0 == "-" }) {
                parsed.tail += splitAlnum(piece)
            }
        }
        return parsed
    }

    /// `rc1`, `beta`, `dev3`, `a1`/`b2`. A bare letter (`1.1.1a`) is a later
    /// patch, not a prerelease.
    static func isPrereleaseMarker(_ text: Substring) -> Bool {
        let lower = text.lowercased()
        if ["alpha", "beta", "rc", "pre", "dev", "preview"].contains(where: lower.hasPrefix) { return true }
        let chars = Array(lower)
        return chars.count >= 2 && "abc".contains(chars[0]) && chars[1].isASCII && chars[1].isNumber
    }

    /// `rc12` becomes `[text(rc), number(12)]`, so `rc2 < rc12`.
    static func splitAlnum(_ piece: Substring) -> [Part] {
        var parts: [Part] = []
        var current = ""
        var digits = false
        func push() {
            guard !current.isEmpty else { return }
            if digits, let n = UInt64(current) { parts.append(.number(n)) } else { parts.append(.text(current.lowercased())) }
            current = ""
        }
        for c in piece {
            let isDigit = c.isASCII && c.isNumber
            if !current.isEmpty && isDigit != digits { push() }
            digits = isDigit
            current.append(c)
        }
        push()
        return parts
    }

    /// Orders two versions.
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let (x, y) = (parse(a), parse(b))
        for i in 0..<max(x.release.count, y.release.count) {
            let l = i < x.release.count ? x.release[i] : 0
            let r = i < y.release.count ? y.release[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        // Same release: a prerelease sorts before the final version.
        if x.prerelease != y.prerelease { return x.prerelease ? .orderedAscending : .orderedDescending }
        if x.tail == y.tail { return .orderedSame }
        return x.tail.lexicographicallyPrecedes(y.tail) ? .orderedAscending : .orderedDescending
    }

    /// Whether `latest` is newer than `installed`.
    public static func isNewer(_ latest: String, than installed: String) -> Bool {
        compare(latest, installed) == .orderedDescending
    }

    /// Year-based and plain schemes can't be compared (`2024.3` vs `9.1`);
    /// such a pair is left alone rather than reported wrongly.
    public static func comparable(_ a: String, _ b: String) -> Bool {
        func first(_ v: String) -> UInt64? { v.split(separator: ".", omittingEmptySubsequences: false).first.flatMap { UInt64($0) } }
        guard let x = first(a), let y = first(b) else { return false }
        return (x >= 1000) == (y >= 1000)
    }

    /// A cask may end in a build number the app keeps apart: `7.2.2.88465`
    /// is `7.2.2` (build 88465), not a newer release. A short last part
    /// (`1.0.1`) is a release.
    public static func onlyAddsBuild(_ latest: String, to installed: String) -> Bool {
        guard latest.hasPrefix(installed) else { return false }
        let rest = latest.dropFirst(installed.count)
        guard rest.first == "." else { return false }
        let build = rest.dropFirst()
        return build.count >= 4 && build.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// The first number of a version: `157` of `157.0.1`, `158` of `158.0b5`.
    public static func major(_ version: String) -> Substring {
        version.prefix { $0.isASCII && $0.isNumber }
    }

    /// A cask's version as people read it: `1.2.3` of `1.2.3,456`.
    public static func display(_ caskVersion: String) -> String {
        String(caskVersion.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first ?? Substring(caskVersion))
            .trimmingCharacters(in: .whitespaces)
    }
}
