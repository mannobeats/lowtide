import Foundation
import os

/// Collects this Mac's recipe, one section at a time, so the page shows
/// each as it lands.
public enum RecipeCollector {
    public enum Event: Sendable {
        /// The sections that will be collected, sent first.
        case planned([(id: String, label: String)])
        case done(RecipeSection)
        case failed(id: String, error: String)
        case finished(MacRecipe)
    }

    /// `(id, label, tool)`, in recipe order.
    static let sections: [(id: String, label: String, tool: String)] = [
        ("brew-taps", "Homebrew taps", "brew"), ("brew", "Homebrew formulae", "brew"), ("casks", "Homebrew casks", "brew"),
        ("mas", "Mac App Store", "mas"), ("npm", "npm globals", "npm"), ("pnpm", "pnpm globals", "pnpm"),
        ("bun", "Bun globals", "bun"), ("pipx", "pipx apps", "pipx"), ("uv", "uv tools", "uv"),
        ("cargo", "Cargo binaries", "cargo"), ("gem", "Ruby gems", "gem"), ("go", "Go binaries", "go"),
        ("code", "VS Code extensions", "code"), ("cursor", "Cursor extensions", "cursor"), ("runtimes", "Runtimes", ""),
    ]

    /// A wedged tool (a hidden prompt, a lock) must not hold the recipe back.
    static let sectionTimeout: Duration = .seconds(45)

    static func available(_ id: String, tool: String) -> Bool {
        switch id {
        case "runtimes": true
        // Only a Ruby the person controls; the system one ships with macOS.
        case "gem": Shell.resolve("gem").map { !$0.hasPrefix("/usr/bin") } ?? false
        // `cursor` on the PATH can be Cursor's agent shim, which fails
        // without the editor: only offer it when the app is there.
        case "cursor": Shell.isAvailable(tool) && appInstalled("Cursor.app")
        default: Shell.isAvailable(tool)
        }
    }

    static func appInstalled(_ bundle: String) -> Bool {
        FileManager.default.fileExists(atPath: "/Applications/\(bundle)")
            || FileManager.default.fileExists(atPath: Paths.home.appending(path: "Applications/\(bundle)").path)
    }

    public static func collect() -> AsyncStream<Event> {
        AsyncStream { continuation in
            let task = Task {
                await Shell.ready()
                let planned = sections.enumerated().filter { available($0.element.id, tool: $0.element.tool) }
                continuation.yield(.planned(planned.map { ($0.element.id, $0.element.label) }))
                async let machine = machine()
                async let hosts = hosts()
                let collected = OSAllocatedUnfairLock(initialState: [(Int, RecipeSection)]())
                // Each section reports itself rather than passing a tuple with
                // a Result through the group: in optimized builds such a tuple
                // arrived uninitialized (AddressSanitizer caught it).
                await withTaskGroup(of: Void.self) { group in
                    for (index, section) in planned {
                        group.addTask {
                            do {
                                let items = try await withTimeout(sectionTimeout) { try await items(section.id) }
                                let done = RecipeSection(id: section.id, label: section.label, items: items.sorted {
                                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                                })
                                collected.withLock { $0.append((index, done)) }
                                continuation.yield(.done(done))
                            } catch {
                                continuation.yield(.failed(id: section.id, error: error.localizedDescription))
                            }
                        }
                    }
                }
                let recipe = MacRecipe(machine: await machine, sections: collected.withLock { $0 }.sorted { $0.0 < $1.0 }.map(\.1),
                                       hosts: await hosts)
                continuation.yield(.finished(recipe))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func withTimeout<T: Sendable>(_ limit: Duration, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw LowtideError.commandFailed("Timed out")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw LowtideError.cancelled }
            return first
        }
    }

    static func machine() async -> MacRecipe.Machine {
        async let name = Shell.run("/usr/sbin/scutil", ["--get", "ComputerName"], timeout: .seconds(10))
        async let os = Shell.run("/usr/bin/sw_vers", ["-productVersion"], timeout: .seconds(10))
        func text(_ out: CommandOutput?) -> String? {
            guard let out, out.ok else { return nil }
            let text = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        #if arch(arm64)
        let arch = "aarch64"
        #else
        let arch = "x86_64"
        #endif
        return MacRecipe.Machine(name: text(try? await name) ?? "This Mac",
                                 os: text(try? await os).map { "macOS \($0)" } ?? "macOS", arch: arch)
    }

    /// The vault's SSH hosts, without identities or secrets.
    static func hosts() async -> [RecipeHost]? {
        guard let vault = Vault.shared,
              let rows = try? await vault.query("""
                SELECT h.name, h.hostname, h.port, h.username, g.name AS group_name
                FROM hosts h LEFT JOIN groups g ON g.id = h.group_id ORDER BY h.name COLLATE NOCASE
                """) else { return nil }
        let hosts = rows.compactMap { row -> RecipeHost? in
            guard let name = row.string("name"), let hostname = row.string("hostname") else { return nil }
            return RecipeHost(group: row.string("group_name"), hostname: hostname, name: name,
                              port: row.int("port") ?? 22, user: row.string("username") ?? "")
        }
        return hosts.isEmpty ? nil : hosts
    }

    static func output(_ program: String, _ arguments: [String]) async throws -> String {
        try await ToolCommand.output(program, arguments)
    }

    static func items(_ id: String) async throws -> [RecipeItem] {
        switch id {
        case "brew-taps":
            return try await output("brew", ["tap"]).split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                .map { RecipeItem(kind: "tap", key: $0, name: $0, version: nil) }
        case "brew":
            async let leaves = output("brew", ["leaves", "--installed-on-request"])
            async let versions = output("brew", ["list", "--formula", "--versions"])
            return formulae(leaves: try await leaves, versions: (try? await versions) ?? "")
        case "casks":
            return parseNameVersions(try await output("brew", ["list", "--cask", "--versions"])).map {
                RecipeItem(kind: "cask", key: $0.0, name: $0.0, version: $0.1)
            }
        case "uv": return parseUVTools(try await output("uv", ["tool", "list"]))
        case "gem": return parseGems(try await output("gem", ["list", "--local"]))
        case "code", "cursor": return parseExtensions(kind: id, try await output(id, ["--list-extensions", "--show-versions"]))
        case "runtimes":
            var items = await Runtimes.all().map { RecipeItem(kind: "runtime", key: $0.id, name: $0.name, version: $0.version) }
            if let shell = ProcessInfo.processInfo.environment["SHELL"] {
                items.append(RecipeItem(kind: "runtime", key: "shell", name: "Login shell", version: shell))
            }
            return items
        case "npm":
            // They ship with Node itself.
            return try await fromSource(id).filter { $0.id != "npm:npm" && $0.id != "npm:corepack" }
        default:
            return try await fromSource(id)
        }
    }

    /// The package managers' own scans already list globals with versions
    /// and ids shaped `<source>:<name>`.
    static func fromSource(_ id: String) async throws -> [RecipeItem] {
        guard let source = PackageSources.source(id) else { throw LowtideError.notFound("Package manager \(id)") }
        return try await source.scan().map { RecipeItem(id: $0.id, name: $0.name, version: $0.currentVersion.isEmpty ? nil : $0.currentVersion) }
    }

    /// Formulae the person asked for, not their dependencies.
    static func formulae(leaves: String, versions: String) -> [RecipeItem] {
        let known = Dictionary(parseNameVersions(versions).map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        return leaves.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { name in
            let short = String(name.split(separator: "/").last ?? Substring(name))
            return RecipeItem(kind: "brew", key: name, name: name, version: known[short] ?? nil)
        }
    }

    /// `name 1.2.3` lines (`brew list --versions`); the last version wins.
    static func parseNameVersions(_ stdout: String) -> [(String, String?)] {
        stdout.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let name = parts.first else { return nil }
            return (name, parts.count > 1 ? parts.last : nil)
        }
    }

    /// `uv tool list`: `ruff v0.5.0` headers, each followed by `- <binary>` lines.
    static func parseUVTools(_ stdout: String) -> [RecipeItem] {
        stdout.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-") && !$0.hasPrefix("warning") }.compactMap { line in
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let name = parts.first else { return nil }
            let version = parts.count > 1 ? String(parts[1].drop { $0 == "v" }) : nil
            return RecipeItem(kind: "uv", key: name, name: name, version: version)
        }
    }

    /// `gem list --local`: `name (2.0.1, 1.9.0, default: 1.2.0)`. Gems that
    /// only exist as Ruby's own defaults aren't the person's.
    static func parseGems(_ stdout: String) -> [RecipeItem] {
        stdout.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let open = line.range(of: " (") else { return nil }
            let name = String(line[..<open.lowerBound])
            let versions = line[open.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: ")")).components(separatedBy: ", ")
            guard let version = versions.first(where: { !$0.hasPrefix("default:") })?.split(separator: " ").first else { return nil }
            return RecipeItem(kind: "gem", key: name, name: name, version: String(version))
        }
    }

    /// `--list-extensions --show-versions`: `publisher.name@1.2.3`.
    static func parseExtensions(kind: String, _ stdout: String) -> [RecipeItem] {
        stdout.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.contains(".") }.map { line in
            let at = line.lastIndex(of: "@")
            let id = (at.map { String(line[..<$0]) } ?? line).lowercased()
            return RecipeItem(kind: kind, key: id, name: id, version: at.map { String(line[line.index(after: $0)...]) })
        }
    }
}
