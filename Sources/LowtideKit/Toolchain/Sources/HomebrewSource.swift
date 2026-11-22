import Foundation
import os

/// Homebrew formulae, command-line casks, and app casks (the app casks are
/// listed for the inventory; their updates belong to Apps › Updates).
public struct HomebrewSource: PackageSource {
    public let info = PackageSourceInfo(
        id: "homebrew", name: "Homebrew", icon: "homebrew", tool: "brew",
        description: "Formulae and command-line casks installed via Homebrew")

    public init() {}

    /// `brew outdated` refreshes the core API data itself; third-party taps
    /// only move on `brew update`, a git fetch of every tap. That runs when
    /// the person asks to check again, not behind their back on every scan.
    private static let tapRefreshDue = OSAllocatedUnfairLock(initialState: false)

    static func refreshTapsOnNextScan() { tapRefreshDue.withLock { $0 = true } }

    public func scan() async throws -> [ToolPackage] {
        guard isAvailable() else { throw LowtideError.toolMissing("brew") }
        async let listed = ToolCommand.output("brew", ["list", "--formula", "--versions"])
        async let casks = ToolCommand.output("brew", ["info", "--json=v2", "--cask", "--installed"])
        async let pinned = Shell.run("brew", ["list", "--pinned"])
        async let outdated = Self.outdated()
        return try Self.merge(list: try await listed, casks: try await casks,
                              pinned: (try? await pinned)?.stdout ?? "", outdated: try await outdated)
    }

    private static func outdated() async throws -> Outdated {
        await refreshTapsIfDue()
        let out = try await Shell.run("brew", ["outdated", "--json=v2"])
        // Exit 1 only means "something is outdated"; trust the JSON, not the code.
        guard let parsed = parseOutdated(out.stdout) else {
            throw LowtideError.commandFailed("brew outdated: \(out.message)")
        }
        return parsed
    }

    private static func refreshTapsIfDue() async {
        guard tapRefreshDue.withLock({ due in defer { due = false }; return due }) else { return }
        // An upgrade holds Homebrew; `brew update` next to it can break both.
        guard await ToolLock.shared.tryAcquire("brew") else { return }
        _ = try? await Shell.run("brew", ["update", "--quiet"], timeout: .seconds(180))
        await ToolLock.shared.release("brew")
    }

    static func merge(list: String, casks: String, pinned: String, outdated: Outdated) throws -> [ToolPackage] {
        let pinnedNames = Set(pinned.split(whereSeparator: \.isWhitespace).map(String.init))
        var packages: [ToolPackage] = []
        for (name, version) in parseList(list) {
            let found = outdated.formulae[name]
            packages.append(ToolPackage(
                id: "formula:\(name)", name: name, currentVersion: version, latestVersion: found?.latest,
                outdated: found != nil, pinned: pinnedNames.contains(name) || found?.pinned == true,
                checked: true, kind: .package))
        }
        guard let installed = parseCasks(casks) else { throw LowtideError.commandFailed("brew info returned no casks") }
        for cask in installed {
            let found = outdated.casks[cask.token]
            packages.append(ToolPackage(
                id: "cask:\(cask.token)", name: cask.token, currentVersion: cask.installed ?? cask.version,
                latestVersion: found?.latest, outdated: found != nil, description: cask.description,
                checked: true, kind: cask.isApp ? .app : .tool))
        }
        return packages
    }

    public func details(_ packageID: String) async throws -> PackageDetails {
        let (kind, name) = try PackageID.split(packageID)
        let cask = kind == "cask"
        let out = try await ToolCommand.output("brew", ["info", "--json=v2", cask ? "--cask" : "--formula", name])
        guard let root = JSONValue.object(out),
              let item = (root[cask ? "casks" : "formulae"] as? [[String: Any]])?.first else {
            throw LowtideError.commandFailed("Homebrew returned no details for \(name)")
        }
        var details = Self.details(item, cask: cask, name: name, packageID: packageID)
        if !cask, let prefix = try? await ToolCommand.output("brew", ["--prefix", name]) {
            details.installPath = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return details
    }

    static func details(_ item: [String: Any], cask: Bool, name: String, packageID: String) -> PackageDetails {
        var details = PackageDetails(source: "homebrew", packageID: packageID)
        details.packageType = cask ? "Homebrew Cask" : "Homebrew Formula"
        details.description = item["desc"] as? String
        details.homepage = item["homepage"] as? String
        details.license = JSONValue.display(item["license"])
        details.packageURL = "https://formulae.brew.sh/\(cask ? "cask" : "formula")/\(name)"
        details.dependencies = dependencies(item)
        details.availableVersions = versions(item, cask: cask)
        details.caveats = (item["caveats"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        if cask { details.installPath = caskInstallPath(item) }
        return details
    }

    public func updateCommand(_ packageID: String) async throws -> Invocation {
        let (kind, name) = try PackageID.split(packageID)
        return Invocation("brew", ["upgrade", kind == "cask" ? "--cask" : "--formula", name])
    }

    public func uninstallCommand(_ packageID: String) async throws -> Invocation? {
        let (kind, name) = try PackageID.split(packageID)
        return Invocation("brew", kind == "cask" ? ["uninstall", "--cask", name] : ["uninstall", name])
    }

    // MARK: Parsing

    struct Outdated: Sendable, Equatable {
        struct Item: Sendable, Equatable {
            var latest: String?
            var pinned: Bool
        }
        /// Keyed by short name: taps report `user/tap/name`, `brew list` says `name`.
        var formulae: [String: Item] = [:]
        var casks: [String: Item] = [:]
    }

    static func parseOutdated(_ json: String) -> Outdated? {
        guard let root = JSONValue.object(json) else { return nil }
        func items(_ key: String) -> [String: Outdated.Item] {
            var map: [String: Outdated.Item] = [:]
            for item in root[key] as? [[String: Any]] ?? [] {
                guard let name = item["name"] as? String else { continue }
                map[shortName(name)] = Outdated.Item(latest: item["current_version"] as? String,
                                                     pinned: item["pinned"] as? Bool ?? false)
            }
            return map
        }
        return Outdated(formulae: items("formulae"), casks: items("casks"))
    }

    /// `name version…` per installed formula. Several kegs can be installed
    /// at once (`openssl@3 3.3.1 3.3.2`); the newest one is linked.
    static func parseList(_ stdout: String) -> [(String, String)] {
        stdout.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let name = parts.first, let version = PackageVersion.newest(parts.dropFirst()) else { return nil }
            return (name, version)
        }
    }

    static func shortName(_ name: String) -> String {
        name.split(separator: "/").last.map(String.init) ?? name
    }

    struct Cask: Sendable, Equatable {
        var token: String
        var version: String
        /// The version on disk, without the cask's `,build` suffix.
        var installed: String?
        var isApp: Bool
        var description: String?
    }

    static func parseCasks(_ json: String) -> [Cask]? {
        guard let root = JSONValue.object(json) else { return nil }
        return (root["casks"] as? [[String: Any]] ?? []).compactMap { item in
            guard let token = item["token"] as? String else { return nil }
            let artifacts = item["artifacts"] as? [[String: Any]] ?? []
            let installed = JSONValue.display(item["installed"]).map {
                String($0.split(separator: ",", maxSplits: 1).first ?? Substring($0)).trimmingCharacters(in: .whitespaces)
            }
            return Cask(token: token, version: (item["version"] as? String) ?? "", installed: installed,
                        isApp: artifacts.contains { $0["app"] != nil }, description: item["desc"] as? String)
        }
    }

    static func dependencies(_ item: [String: Any]) -> [String] {
        var found: [String] = []
        for key in ["dependencies", "build_dependencies", "optional_dependencies", "recommended_dependencies"] {
            found += item[key] as? [String] ?? []
        }
        if let dependsOn = item["depends_on"] as? [String: Any] {
            for key in ["cask", "formula"] {
                found += (dependsOn[key] as? [Any] ?? []).compactMap(JSONValue.display)
            }
        }
        return Array(Set(found)).sorted()
    }

    static func versions(_ item: [String: Any], cask: Bool) -> [String] {
        var found: [String] = []
        if cask {
            if let version = item["version"] as? String { found.append(version) }
        } else if let versions = item["versions"] as? [String: Any] {
            for key in ["stable", "head", "bottle"] {
                if let version = versions[key] as? String { found.append(version) }
            }
        }
        return Array(Set(found)).sorted()
    }

    static func caskInstallPath(_ item: [String: Any]) -> String? {
        for artifact in item["artifacts"] as? [[String: Any]] ?? [] {
            if let app = (artifact["app"] as? [Any])?.first as? String { return "/Applications/\(app)" }
        }
        return nil
    }
}
