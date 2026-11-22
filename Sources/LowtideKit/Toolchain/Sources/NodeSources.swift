import Foundation

/// Globally installed npm packages.
public struct NPMSource: PackageSource {
    public let info = PackageSourceInfo(id: "npm", name: "npm", icon: "npm", tool: "npm",
                                        description: "Globally installed npm packages")
    public init() {}

    public func scan() async throws -> [ToolPackage] {
        async let installed = Shell.run("npm", ["ls", "-g", "--depth=0", "--json"])
        async let outdated = Shell.run("npm", ["outdated", "-g", "--json"])
        let list = try await installed
        guard let packages = Self.parseList(list.stdout) else {
            throw LowtideError.commandFailed(list.message.isEmpty ? "npm ls returned nothing readable" : list.message)
        }
        return NodeOutdated.apply(prefix: "npm", packages, outdated: (try? await outdated)?.stdout)
    }

    /// `npm ls -g --json`: `{"dependencies": {"name": {"version": "1.2.3"}}}`.
    static func parseList(_ json: String) -> [(String, String)]? {
        guard let root = JSONValue.object(json) else { return nil }
        let dependencies = root["dependencies"] as? [String: Any] ?? [:]
        return dependencies.keys.sorted().map { name in
            (name, ((dependencies[name] as? [String: Any])?["version"] as? String) ?? "")
        }
    }

    public func updateCommand(_ packageID: String) async throws -> Invocation {
        Invocation("npm", ["install", "-g", try PackageID.strip(packageID, prefix: "npm") + "@latest"])
    }

    public func uninstallCommand(_ packageID: String) async throws -> Invocation? {
        Invocation("npm", ["uninstall", "-g", try PackageID.strip(packageID, prefix: "npm")])
    }
}

/// Globally installed pnpm packages.
public struct PNPMSource: PackageSource {
    public let info = PackageSourceInfo(id: "pnpm", name: "pnpm", icon: "pnpm", tool: "pnpm",
                                        description: "Globally installed pnpm packages")
    public init() {}

    public func scan() async throws -> [ToolPackage] {
        async let installed = Shell.run("pnpm", ["ls", "-g", "--depth=0", "--json"])
        async let outdated = Shell.run("pnpm", ["outdated", "-g", "--format", "json"])
        let list = try await installed
        // pnpm reports setup problems (its bin dir missing from PATH) as
        // plain text; show them instead of an empty list.
        guard let packages = Self.parseList(list.stdout) else {
            let message = [list.stdout, list.stderr].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.joined(separator: "\n")
            throw LowtideError.commandFailed(message.isEmpty ? "pnpm ls returned nothing readable" : message)
        }
        return NodeOutdated.apply(prefix: "pnpm", packages, outdated: (try? await outdated)?.stdout)
    }

    /// `pnpm ls -g --json`: a list of projects, each with `dependencies`.
    static func parseList(_ json: String) -> [(String, String)]? {
        guard let entries = JSONValue.any(json) as? [[String: Any]] else { return nil }
        var found: [(String, String)] = []
        for entry in entries {
            let dependencies = entry["dependencies"] as? [String: Any] ?? [:]
            for name in dependencies.keys.sorted() {
                found.append((name, ((dependencies[name] as? [String: Any])?["version"] as? String) ?? ""))
            }
        }
        return found
    }

    public func updateCommand(_ packageID: String) async throws -> Invocation {
        Invocation("pnpm", ["add", "-g", try PackageID.strip(packageID, prefix: "pnpm") + "@latest"])
    }

    public func uninstallCommand(_ packageID: String) async throws -> Invocation? {
        Invocation("pnpm", ["remove", "-g", try PackageID.strip(packageID, prefix: "pnpm")])
    }
}

/// `npm outdated` and `pnpm outdated` share a shape: `{"name": {"latest": "2.0.0", …}}`.
enum NodeOutdated {
    /// Latest versions by name, or nil when the check failed. The command
    /// exits 1 when anything is outdated; when the registry is unreachable
    /// it prints an error object instead: then nothing is known, which is
    /// different from "everything is current".
    static func parse(_ json: String?) -> [String: String]? {
        guard let json, let root = JSONValue.object(json) else { return nil }
        if root["error"] != nil { return nil }
        var latest: [String: String] = [:]
        for (name, value) in root {
            if let entry = value as? [String: Any], let version = entry["latest"] as? String { latest[name] = version }
        }
        return latest
    }

    static func apply(prefix: String, _ packages: [(String, String)], outdated: String?) -> [ToolPackage] {
        let latest = parse(outdated)
        return packages.map { name, version in
            ToolPackage(id: "\(prefix):\(name)", name: name, currentVersion: version,
                        latestVersion: latest?[name], checked: latest != nil)
        }
    }
}

/// Globally installed Bun packages, read from Bun's global manifest; the
/// latest versions come from public npm.
public struct BunSource: PackageSource {
    public let info = PackageSourceInfo(id: "bun", name: "Bun", icon: "bun", tool: "bun",
                                        description: "Globally installed Bun packages")
    public init() {}

    static func globalDirectory() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let install = environment["BUN_INSTALL"].map { URL(fileURLWithPath: $0) } ?? Paths.home.appending(path: ".bun")
        return [install.appending(path: "install/global"), Paths.home.appending(path: ".local/share/bun/install/global")]
            .first { FileManager.default.fileExists(atPath: $0.appending(path: "package.json").path) }
    }

    struct Manifest: Decodable {
        var dependencies: [String: String]?
        var version: String?
    }

    static func manifest(_ url: URL) -> Manifest? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
    }

    public func scan() async throws -> [ToolPackage] {
        guard let directory = Self.globalDirectory() else { return [] }
        guard let manifest = Self.manifest(directory.appending(path: "package.json")) else {
            throw LowtideError.commandFailed("Bun's global package.json can't be read")
        }
        let dependencies = manifest.dependencies ?? [:]
        let config = ToolConfig.home([".npmrc", ".bunfig.toml", ".config/.bunfig.toml"])
        let latest = await LatestVersions.shared.resolve(.npm, Self.publicNames(dependencies, config: config))
        return dependencies.keys.sorted().map { name in
            // The manifest holds the requested range; the installed version
            // lives in the package's own package.json.
            let installed = Self.manifest(directory.appending(path: "node_modules/\(name)/package.json"))?.version
                ?? String(dependencies[name, default: ""].drop { "^~=".contains($0) })
            return ToolPackage(id: "bun:\(name)", name: name, currentVersion: installed).withLatest(latest[name])
        }
    }

    /// What public npm may be asked about: nothing when the person set
    /// another default registry; otherwise everything except scopes routed
    /// to their own registry and packages not from a registry at all
    /// (`github:`, `file:`…).
    static func publicNames(_ dependencies: [String: String], config: String) -> [String] {
        if ToolConfig.customRegistry(config, keys: ["registry"], public: "registry.npmjs.org") { return [] }
        return dependencies.keys.sorted().filter { name in
            let range = dependencies[name] ?? ""
            guard !range.contains(":"), !range.contains("/") else { return false }
            guard let slash = name.firstIndex(of: "/") else { return true }
            let scope = String(name[..<slash])
            let bare = scope.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            return !config.contains(scope) && !config.contains("\"\(bare)\"") && !config.contains("\(bare) =")
        }
    }

    public func updateCommand(_ packageID: String) async throws -> Invocation {
        Invocation("bun", ["add", "-g", try PackageID.strip(packageID, prefix: "bun") + "@latest"])
    }

    public func uninstallCommand(_ packageID: String) async throws -> Invocation? {
        Invocation("bun", ["remove", "-g", try PackageID.strip(packageID, prefix: "bun")])
    }
}
