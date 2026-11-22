import Foundation

/// Rust binaries installed with `cargo install`.
public struct CargoSource: PackageSource {
    public let info = PackageSourceInfo(id: "cargo", name: "Cargo", icon: "rust", tool: "cargo",
                                        description: "Rust binaries installed with cargo install")
    public init() {}

    struct Install: Sendable, Equatable {
        var name: String
        var version: String
        /// Installed from crates.io, so the registry knows its latest version.
        var registry: Bool
        var features: [String]
        var allFeatures: Bool
        var noDefaultFeatures: Bool
        var binaries: [String]
    }

    static var cargoHome: URL {
        ProcessInfo.processInfo.environment["CARGO_HOME"].map { URL(fileURLWithPath: $0) } ?? Paths.home.appending(path: ".cargo")
    }

    /// `~/.cargo/.crates2.json`: Cargo's own record of every `cargo install`,
    /// keyed `ripgrep 14.1.0 (registry+https://github.com/rust-lang/crates.io-index)`,
    /// with the features each was built with.
    static func parseInstalls(_ json: String) -> [Install] {
        guard let installs = JSONValue.object(json)?["installs"] as? [String: Any] else { return [] }
        return installs.keys.sorted().compactMap { key in
            let parts = key.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count >= 2 else { return nil }
            let source = parts.count > 2 ? parts[2] : ""
            let info = installs[key] as? [String: Any] ?? [:]
            return Install(
                name: parts[0], version: parts[1],
                registry: source.contains("crates.io-index") || source.contains("index.crates.io"),
                features: info["features"] as? [String] ?? [], allFeatures: info["all_features"] as? Bool ?? false,
                noDefaultFeatures: info["no_default_features"] as? Bool ?? false, binaries: info["bins"] as? [String] ?? [])
        }
    }

    static func installed() throws -> [Install] {
        let url = cargoHome.appending(path: ".crates2.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return parseInstalls(try String(contentsOf: url, encoding: .utf8))
    }

    public func scan() async throws -> [ToolPackage] {
        let installs = try Self.installed()
        let latest = await LatestVersions.shared.resolve(.crates, installs.filter(\.registry).map(\.name))
        return installs.map { install in
            ToolPackage(id: "cargo:\(install.name)", name: install.name, currentVersion: install.version,
                        description: install.registry ? nil : "Installed from git or a local path")
                .withLatest(latest[install.name])
        }
    }

    /// Reinstalls with the features the crate was built with; a plain
    /// `cargo install` would silently drop them.
    static func reinstallArguments(_ install: Install) throws -> [String] {
        guard install.registry else {
            throw LowtideError.commandFailed("\(install.name) was installed from git or a path; reinstall it from its source")
        }
        var arguments = ["install", install.name]
        if install.allFeatures {
            arguments.append("--all-features")
        } else if !install.features.isEmpty {
            arguments += ["--features", install.features.joined(separator: ",")]
        }
        if install.noDefaultFeatures { arguments.append("--no-default-features") }
        return arguments
    }

    public func updateCommand(_ packageID: String) async throws -> Invocation {
        let name = try PackageID.strip(packageID, prefix: "cargo")
        guard let install = try Self.installed().first(where: { $0.name == name }) else {
            throw LowtideError.commandFailed("\(name) is not installed")
        }
        return Invocation("cargo", try Self.reinstallArguments(install))
    }

    public func uninstallCommand(_ packageID: String) async throws -> Invocation? {
        Invocation("cargo", ["uninstall", try PackageID.strip(packageID, prefix: "cargo")])
    }
}
