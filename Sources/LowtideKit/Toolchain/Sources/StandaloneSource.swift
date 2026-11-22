import Foundation

/// Self-updating developer tools installed with their own installer
/// (Claude Code, Codex, Bun, Deno, uv…), updated through their own updater.
public struct StandaloneSource: PackageSource {
    public let info = PackageSourceInfo(id: "standalone", name: "Standalone CLIs", icon: "terminal", tool: "standalone",
                                        description: "Self-updating developer tools installed outside a package manager")
    public init() {}

    struct CLI: Sendable {
        var id: String
        var command: String
        var name: String
        var description: String
        var homepage: String
        var updateArguments: [String]
        /// Where the vendor publishes releases, so "latest" is the version
        /// the tool's own updater fetches.
        var registry: PackageRegistry
        var package: String
    }

    static let clis: [CLI] = [
        CLI(id: "claude", command: "claude", name: "Claude Code", description: "Anthropic coding agent",
            homepage: "https://docs.anthropic.com/en/docs/claude-code", updateArguments: ["update"],
            registry: .npm, package: "@anthropic-ai/claude-code"),
        CLI(id: "codex", command: "codex", name: "Codex CLI", description: "OpenAI coding agent",
            homepage: "https://developers.openai.com/codex/cli", updateArguments: ["update"],
            registry: .npm, package: "@openai/codex"),
        CLI(id: "opencode", command: "opencode", name: "OpenCode", description: "Open-source coding agent",
            homepage: "https://opencode.ai", updateArguments: ["upgrade"], registry: .npm, package: "opencode-ai"),
        CLI(id: "bun", command: "bun", name: "Bun", description: "JavaScript runtime and package manager",
            homepage: "https://bun.sh", updateArguments: ["upgrade"], registry: .npm, package: "bun"),
        CLI(id: "deno", command: "deno", name: "Deno", description: "JavaScript and TypeScript runtime",
            homepage: "https://deno.com", updateArguments: ["upgrade"], registry: .npm, package: "deno"),
        CLI(id: "uv", command: "uv", name: "uv", description: "Python package and project manager",
            homepage: "https://docs.astral.sh/uv", updateArguments: ["self", "update"], registry: .pypi, package: "uv"),
    ]

    /// Installed through its own installer. A copy Homebrew or a JavaScript
    /// package manager put there is updated by that manager, and running
    /// its self-updater would fight it.
    static func selfManagedPath(_ cli: CLI) -> String? {
        guard let path = Shell.resolve(cli.command) else { return nil }
        return isSelfManaged(real: URL(fileURLWithPath: path).resolvingSymlinksInPath().path) ? path : nil
    }

    static func isSelfManaged(real: String) -> Bool {
        let ownedElsewhere = ["/opt/homebrew/", "/usr/local/Cellar/", "/usr/local/Caskroom/", "/node_modules/"]
            .contains { real.contains($0) } || real.hasPrefix("/usr/bin")
        return !ownedElsewhere
    }

    static var installed: [CLI] { clis.filter { selfManagedPath($0) != nil } }

    public func isAvailable() -> Bool { !Self.installed.isEmpty }

    public func scan() async throws -> [ToolPackage] {
        await withTaskGroup(of: (Int, ToolPackage?).self) { group in
            for (index, cli) in Self.installed.enumerated() {
                group.addTask {
                    async let latest = LatestVersions.shared.latest(cli.registry, cli.package)
                    guard let out = try? await Shell.run(cli.command, ["--version"], timeout: .seconds(20)) else { return (index, nil) }
                    let package = ToolPackage(id: "standalone:\(cli.id)", name: cli.name,
                                              currentVersion: Self.parseVersion(out.stdout, out.stderr),
                                              description: cli.description, kind: .tool)
                    return (index, package.withLatest(await latest))
                }
            }
            var found: [(Int, ToolPackage)] = []
            for await (index, package) in group { if let package { found.append((index, package)) } }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// The first token that looks like a version: `codex-cli 0.145.0`,
    /// `2.1.228 (Claude Code)`, `deno 2.9.7 (stable, …)`, `uv 0.9.1 (abc 2026-…)`.
    static func parseVersion(_ stdout: String, _ stderr: String) -> String {
        let tokens = (stdout + " " + stderr).split(whereSeparator: \.isWhitespace)
        for token in tokens {
            let bare = token.hasPrefix("v") ? token.dropFirst() : token[...]
            if bare.split(separator: ".").count >= 2, bare.first?.isNumber == true { return String(bare) }
        }
        return "unknown"
    }

    static func cli(_ packageID: String) throws -> CLI {
        guard packageID.hasPrefix("standalone:"), let cli = clis.first(where: { $0.id == packageID.dropFirst(11) }) else {
            throw LowtideError.invalid("Unknown standalone tool \(packageID)")
        }
        return cli
    }

    public func details(_ packageID: String) async throws -> PackageDetails {
        let cli = try Self.cli(packageID)
        var details = PackageDetails(source: "standalone", packageID: packageID)
        await PackageMetadata.enrich(source: cli.registry == .pypi ? "pipx" : "npm", name: cli.package, into: &details)
        details.description = cli.description
        details.homepage = cli.homepage
        details.packageType = "Self-updating command-line tool"
        details.installPath = Self.selfManagedPath(cli)
        details.caveats = "Updates run through the tool's own updater: \(cli.command) \(cli.updateArguments.joined(separator: " "))"
        return details
    }

    public func updateCommand(_ packageID: String) async throws -> Invocation {
        let cli = try Self.cli(packageID)
        // Each tool updates only itself; they can run side by side.
        return Invocation(cli.command, cli.updateArguments, lock: "standalone:\(cli.id)")
    }

    public var removalRefusal: String? { "Standalone tools are removed with their own installer" }

    public func uninstallCommand(_ packageID: String) async throws -> Invocation? {
        throw LowtideError.denied(removalRefusal ?? "")
    }
}
