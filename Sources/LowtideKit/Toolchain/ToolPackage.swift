import Foundation

/// What an installed thing is, for the inventory's filters and for keeping
/// GUI apps out of the command-line tools' updates.
public enum PackageKind: String, Codable, Sendable, Hashable {
    /// A library or tool installed by a package manager.
    case package
    /// A command-line tool installed as a whole program (a CLI cask, a
    /// self-updating CLI).
    case tool
    /// A graphical app (an app cask, an App Store app). Its updates belong
    /// to Apps › Updates.
    case app
}

/// One installed package as a package manager reports it.
public struct ToolPackage: Codable, Sendable, Hashable, Identifiable {
    /// `<kind>:<name>`, unique within its source (`formula:git`, `npm:pnpm`).
    public var id: String
    public var name: String
    public var currentVersion: String
    public var latestVersion: String?
    public var outdated: Bool
    public var pinned: Bool
    public var description: String?
    /// Size of the step to `latestVersion`, filled in by `finalize`.
    public var bump: VersionBump?
    /// Whether a latest version could be determined at all. `false` means
    /// "unknown", which must never read as "up to date".
    public var checked: Bool
    public var kind: PackageKind

    public init(id: String, name: String, currentVersion: String, latestVersion: String? = nil,
                outdated: Bool = false, pinned: Bool = false, description: String? = nil,
                bump: VersionBump? = nil, checked: Bool = false, kind: PackageKind = .package) {
        self.id = id
        self.name = name
        self.currentVersion = currentVersion
        self.latestVersion = latestVersion
        self.outdated = outdated
        self.pinned = pinned
        self.description = description
        self.bump = bump
        self.checked = checked
        self.kind = kind
    }

    /// Records a registry answer; nil leaves the package unchecked.
    public func withLatest(_ latest: String?) -> ToolPackage {
        guard let latest else { return self }
        var copy = self
        copy.checked = true
        copy.latestVersion = latest
        return copy
    }

    /// Can be updated: behind, or nobody could tell. Pinned packages stay.
    public var canUpdate: Bool { !pinned && (outdated || !checked) }

    /// Waiting for an update the person should act on.
    public var needsUpdate: Bool { outdated && !pinned }

    /// Derives `outdated` and `bump` from the versions, keeping a manager's
    /// own "outdated" verdict when versions alone can't show it (a rebuilt
    /// bottle), and sorts outdated packages first, then by name.
    public static func finalize(_ packages: [ToolPackage]) -> [ToolPackage] {
        packages.map { package in
            var package = package
            let bump = package.latestVersion.flatMap { PackageVersion.bump(from: package.currentVersion, to: $0) }
            package.outdated = package.outdated || bump != nil
            package.bump = bump ?? (package.outdated ? .other : nil)
            return package
        }
        .sorted {
            if $0.outdated != $1.outdated { return $0.outdated }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

/// A package manager: what it is called, the tool it needs, its mark.
public struct PackageSourceInfo: Sendable, Hashable, Identifiable, Codable {
    public let id: String
    public let name: String
    /// A mark in `Resources/sources/<icon>.svg`.
    public let icon: String
    public let tool: String
    public let description: String

    public init(id: String, name: String, icon: String, tool: String, description: String) {
        self.id = id
        self.name = name
        self.icon = icon
        self.tool = tool
        self.description = description
    }
}

/// A process the update engine runs, streaming its output.
public struct Invocation: Sendable, Hashable {
    public var program: String
    public var arguments: [String]
    /// Processes sharing this key never run at the same time (package
    /// managers hold global locks, e.g. every `brew` call).
    public var lock: String

    public init(_ program: String, _ arguments: [String], lock: String? = nil) {
        self.program = program
        self.arguments = arguments
        self.lock = lock ?? program
    }

    /// `brew upgrade --formula git`, for the operations log.
    public var commandLine: String { ([program] + arguments).joined(separator: " ") }
}

/// What the details panel shows about one package.
public struct PackageDetails: Sendable, Hashable, Codable {
    public var description: String?
    public var homepage: String?
    public var packageURL: String?
    public var repository: String?
    public var documentation: String?
    public var license: String?
    public var packageType: String
    public var installPath: String?
    public var dependencies: [String] = []
    public var availableVersions: [String] = []
    public var latestReleaseDate: String?
    public var releaseNotes: String?
    public var caveats: String?

    /// The registry page and type a source's packages share.
    public init(source: String, packageID: String) {
        let name = PackageID.name(packageID)
        packageURL = switch source {
        case "npm", "pnpm", "bun": "https://www.npmjs.com/package/\(name)"
        case "cargo": "https://crates.io/crates/\(name)"
        case "go": "https://pkg.go.dev/\(name)"
        case "pipx": "https://pypi.org/project/\(name)"
        case "gem": "https://rubygems.org/gems/\(name)"
        case "composer": "https://packagist.org/packages/\(name)"
        case "mas": "https://apps.apple.com/app/id\(name)"
        default: nil
        }
        packageType = switch source {
        case "npm", "pnpm", "bun": "JavaScript package"
        case "cargo": "Rust crate"
        case "go": "Go module"
        case "pipx": "Python application"
        case "gem": "Ruby gem"
        case "composer": "Composer package"
        case "mas": "Mac App Store app"
        default: source
        }
    }

    mutating func addVersion(_ version: String?) {
        if let version, !availableVersions.contains(version) { availableVersions.append(version) }
    }
}

/// Package ids are `<prefix>:<name>`; names reach command lines, so they
/// are checked before use.
public enum PackageID {
    /// The part after the first `:`.
    public static func name(_ id: String) -> String {
        id.firstIndex(of: ":").map { String(id[id.index(after: $0)...]) } ?? id
    }

    /// The name of `<prefix>:<name>`, or a parse error.
    public static func strip(_ id: String, prefix: String) throws -> String {
        guard id.hasPrefix(prefix + ":"), let name = validName(String(id.dropFirst(prefix.count + 1))) else {
            throw LowtideError.invalid("Invalid package id \(id)")
        }
        return name
    }

    /// `(kind, name)` of `kind:name`.
    public static func split(_ id: String) throws -> (String, String) {
        guard let colon = id.firstIndex(of: ":"),
              let name = validName(String(id[id.index(after: colon)...])) else {
            throw LowtideError.invalid("Invalid package id \(id)")
        }
        return (String(id[..<colon]), name)
    }

    /// A package name may never look like a flag: `--greedy` passed as a
    /// name would change what the package manager does.
    public static func validName(_ name: String) -> String? {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        return name
    }
}

/// The person's own config files, read to see where a tool fetches from
/// before asking a public registry about what's installed.
enum ToolConfig {
    /// The files under HOME, joined (missing ones skipped).
    static func home(_ files: [String]) -> String {
        files.compactMap { try? String(contentsOf: Paths.home.appending(path: $0), encoding: .utf8) }
            .joined(separator: "\n")
    }

    /// Whether a config sets a default registry or index other than `public`.
    static func customRegistry(_ config: String, keys: [String], public host: String) -> Bool {
        config.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.contains { line in
            keys.contains { line.hasPrefix($0) } && !line.contains(host)
        }
    }
}

/// JSON helpers for the loosely-typed output package managers print.
enum JSONValue {
    static func object(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func any(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// A value as a person reads it: strings as they are, lists joined,
    /// objects as `key: value`.
    static func display(_ value: Any?) -> String? {
        switch value {
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        case let list as [Any]:
            let labels = list.compactMap(display)
            return labels.isEmpty ? nil : labels.joined(separator: ", ")
        case let object as [String: Any]:
            let labels = object.keys.sorted().map { key in display(object[key]).map { "\(key): \($0)" } ?? key }
            return labels.isEmpty ? nil : labels.joined(separator: ", ")
        default: return nil
        }
    }
}
