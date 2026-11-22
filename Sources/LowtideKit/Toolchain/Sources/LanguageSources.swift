import Foundation

/// Ruby gems in the gem environment the person controls.
public struct GemSource: PackageSource {
    public let info = PackageSourceInfo(id: "gem", name: "RubyGems", icon: "ruby", tool: "gem",
                                        description: "Ruby gems installed in the current gem environment")
    public init() {}

    /// Not the macOS system Ruby: it needs sudo to change and Apple replaces it.
    public func isAvailable() -> Bool { Shell.resolve("gem").map { !$0.hasPrefix("/usr/bin") } ?? false }

    public func scan() async throws -> [ToolPackage] {
        async let listed = Shell.run("gem", ["list", "--local"])
        async let outdated = Shell.run("gem", ["outdated"])
        let list = try await listed
        guard list.ok else { throw LowtideError.commandFailed(list.message) }
        // A failed check (offline) leaves every gem unchecked, not current.
        let check = try? await outdated
        let latest = check.flatMap { $0.ok ? Self.parseOutdated($0.stdout) : nil }
        return Self.parseList(list.stdout).map { name, version in
            ToolPackage(id: "gem:\(name)", name: name, currentVersion: version,
                        latestVersion: latest?[name], checked: latest != nil)
        }
    }

    /// `rake (13.2.1, default: 13.0.6)`: several versions can be installed
    /// side by side; the newest one is what runs. Platform suffixes
    /// (`1.16.0 arm64-darwin`) aren't part of the version.
    static func parseList(_ stdout: String) -> [(String, String)] {
        stdout.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("*"), let open = line.firstIndex(of: "(") else { return nil }
            let name = line[..<open].trimmingCharacters(in: .whitespaces)
            let versions = line[line.index(after: open)...].trimmingCharacters(in: CharacterSet(charactersIn: ") "))
                .split(separator: ",").map { piece in
                    let trimmed = piece.trimmingCharacters(in: .whitespaces)
                    let bare = trimmed.hasPrefix("default:") ? trimmed.dropFirst(8).trimmingCharacters(in: .whitespaces) : trimmed
                    return String(bare.split(separator: " ").first ?? "")
                }
            guard !name.isEmpty else { return nil }
            return (name, PackageVersion.newest(versions) ?? "")
        }
    }

    /// `rdoc (7.0.4 < 8.0.0)`.
    static func parseOutdated(_ stdout: String) -> [String: String] {
        var latest: [String: String] = [:]
        for raw in stdout.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let space = line.firstIndex(of: " "), let less = line.firstIndex(of: "<") else { continue }
            let version = line[line.index(after: less)...].trimmingCharacters(in: CharacterSet(charactersIn: ") "))
            if !version.isEmpty { latest[String(line[..<space])] = version }
        }
        return latest
    }

    public func updateCommand(_ packageID: String) async throws -> Invocation {
        Invocation("gem", ["update", try PackageID.strip(packageID, prefix: "gem"), "--no-document"])
    }

    public func uninstallCommand(_ packageID: String) async throws -> Invocation? {
        Invocation("gem", ["uninstall", "-x", "-a", try PackageID.strip(packageID, prefix: "gem")])
    }
}

/// Isolated Python applications managed by pipx.
public struct PipxSource: PackageSource {
    public let info = PackageSourceInfo(id: "pipx", name: "pipx", icon: "python", tool: "pipx",
                                        description: "Isolated Python applications managed by pipx")
    public init() {}

    struct Venv: Sendable, Equatable {
        /// The venv, named after the app.
        var name: String
        /// What PyPI knows it as.
        var distribution: String
        var version: String
        /// A path, URL or `git+…` install, which PyPI knows nothing about.
        var local: Bool
    }

    static func parseList(_ json: String) -> [Venv]? {
        guard let root = JSONValue.object(json) else { return nil }
        let venvs = root["venvs"] as? [String: Any] ?? [:]
        return venvs.keys.sorted().map { name in
            let main = ((venvs[name] as? [String: Any])?["metadata"] as? [String: Any])?["main_package"] as? [String: Any] ?? [:]
            let spec = main["package_or_url"] as? String ?? ""
            return Venv(name: name, distribution: main["package"] as? String ?? name,
                        version: main["package_version"] as? String ?? "",
                        local: spec.contains("/") || spec.contains(":") || spec.hasPrefix("."))
        }
    }

    public func scan() async throws -> [ToolPackage] {
        let out = try await Shell.run("pipx", ["list", "--json"])
        guard out.ok, let venvs = Self.parseList(out.stdout) else { throw LowtideError.commandFailed(out.message) }
        // With a private index set, any name could be private: PyPI isn't
        // asked about any of them.
        let environment = ProcessInfo.processInfo.environment
        let config = ToolConfig.home([".config/pip/pip.conf", ".pip/pip.conf", "Library/Application Support/pip/pip.conf"])
        let privateIndex = environment["PIP_INDEX_URL"] != nil || environment["PIP_EXTRA_INDEX_URL"] != nil
            || ToolConfig.customRegistry(config, keys: ["index-url", "extra-index-url"], public: "pypi.org")
        let asked = privateIndex ? [] : venvs.filter { !$0.local }.map(\.distribution)
        let latest = await LatestVersions.shared.resolve(.pypi, asked)
        return venvs.map { venv in
            ToolPackage(id: "pipx:\(venv.name)", name: venv.name, currentVersion: venv.version)
                .withLatest(latest[venv.distribution])
        }
    }

    public func updateCommand(_ packageID: String) async throws -> Invocation {
        Invocation("pipx", ["upgrade", try PackageID.strip(packageID, prefix: "pipx")])
    }

    public func uninstallCommand(_ packageID: String) async throws -> Invocation? {
        Invocation("pipx", ["uninstall", try PackageID.strip(packageID, prefix: "pipx")])
    }
}

/// Globally installed PHP Composer packages.
public struct ComposerSource: PackageSource {
    public let info = PackageSourceInfo(id: "composer", name: "Composer", icon: "php", tool: "composer",
                                        description: "Globally installed PHP Composer packages")
    public init() {}

    struct Entry: Sendable, Equatable {
        var name: String
        var version: String
        var description: String?
        var latest: String?
    }

    static func parseShow(_ json: String) -> [Entry]? {
        guard let root = JSONValue.object(json) else { return nil }
        return (root["installed"] as? [[String: Any]] ?? []).compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            return Entry(name: name, version: item["version"] as? String ?? "",
                         description: item["description"] as? String, latest: item["latest"] as? String)
        }
    }

    /// No global composer.json yet: nothing installed, not an error.
    static func isEmptyGlobal(_ text: String) -> Bool {
        text.contains("could not find a composer.json") || text.contains("No composer.json") || text.contains("No packages")
    }

    public func scan() async throws -> [ToolPackage] {
        async let listed = Shell.run("composer", ["global", "show", "--format=json"])
        async let outdated = Shell.run("composer", ["global", "outdated", "--direct", "--format=json"])
        let list = try await listed
        guard list.ok else {
            if Self.isEmptyGlobal(list.stdout + list.stderr) { return [] }
            throw LowtideError.commandFailed(list.message)
        }
        guard let entries = Self.parseShow(list.stdout) else { throw LowtideError.commandFailed("composer show returned nothing readable") }
        let check = try? await outdated
        let latest: [String: String]? = check.flatMap { $0.ok ? Self.parseShow($0.stdout) : nil }.map { entries in
            Dictionary(entries.compactMap { entry in entry.latest.map { (entry.name, $0) } }, uniquingKeysWith: { a, _ in a })
        }
        return entries.map { entry in
            ToolPackage(id: "composer:\(entry.name)", name: entry.name, currentVersion: entry.version,
                        latestVersion: latest?[entry.name], description: entry.description, checked: latest != nil)
        }
    }

    /// `global update` only moves within the constraint in the global
    /// composer.json; `require name:*` would rewrite it.
    public func updateCommand(_ packageID: String) async throws -> Invocation {
        Invocation("composer", ["global", "update", try PackageID.strip(packageID, prefix: "composer"), "--with-dependencies"])
    }

    public func uninstallCommand(_ packageID: String) async throws -> Invocation? {
        Invocation("composer", ["global", "remove", try PackageID.strip(packageID, prefix: "composer")])
    }
}

/// Apps installed with the Mac App Store's command-line tool.
public struct MacAppStoreSource: PackageSource {
    public let info = PackageSourceInfo(id: "mas", name: "Mac App Store", icon: "appstore", tool: "mas",
                                        description: "Apps installed via the Mac App Store CLI")
    public init() {}

    public var removalRefusal: String? { "Mac App Store apps are removed from the App Store or Launchpad" }

    public func scan() async throws -> [ToolPackage] {
        async let listed = Shell.run("mas", ["list"])
        async let outdated = Shell.run("mas", ["outdated"])
        let list = try await listed
        guard list.ok else { throw LowtideError.commandFailed(list.message) }
        let check = try? await outdated
        let latest = check.flatMap { $0.ok ? Self.parseOutdated($0.stdout) : nil }
        return Self.parseList(list.stdout).map { app in
            ToolPackage(id: "mas:\(app.id)", name: app.name, currentVersion: app.version,
                        latestVersion: latest?[app.id], checked: latest != nil, kind: .app)
        }
    }

    struct App: Sendable, Equatable {
        var id: String
        var name: String
        var version: String
    }

    /// `497799835  Xcode  (16.2)`: an id, a name with spaces, a version in
    /// parentheses (the last pair, since names can hold their own).
    static func parseList(_ stdout: String) -> [App] {
        stdout.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let space = line.firstIndex(where: \.isWhitespace) else { return nil }
            let id = String(line[..<space])
            let rest = line[space...].trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, !rest.isEmpty else { return nil }
            if let open = rest.lastIndex(of: "(") {
                return App(id: id, name: rest[..<open].trimmingCharacters(in: .whitespaces),
                           version: rest[rest.index(after: open)...].trimmingCharacters(in: CharacterSet(charactersIn: "() ")))
            }
            return App(id: id, name: rest, version: "")
        }
    }

    /// `497799835 Xcode (16.1 -> 16.2)`.
    static func parseOutdated(_ stdout: String) -> [String: String] {
        var latest: [String: String] = [:]
        for raw in stdout.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let space = line.firstIndex(where: \.isWhitespace), let arrow = line.range(of: "->") else { continue }
            latest[String(line[..<space])] = line[arrow.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "() "))
        }
        return latest
    }

    public func updateCommand(_ packageID: String) async throws -> Invocation {
        let id = try PackageID.strip(packageID, prefix: "mas")
        guard id.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw LowtideError.invalid("Invalid App Store id \(id)") }
        return Invocation("mas", ["upgrade", id])
    }

    public func uninstallCommand(_ packageID: String) async throws -> Invocation? {
        throw LowtideError.denied(removalRefusal ?? "")
    }
}
