import Foundation
import os

/// One entry of a folder, for path completion.
public struct CompletionEntry: Equatable, Sendable {
    public let name: String
    public let isDirectory: Bool
    public init(name: String, isDirectory: Bool) {
        self.name = name
        self.isDirectory = isDirectory
    }
}

/// What autocomplete knows about the folder a shell is in: files, git
/// state, project tasks (package scripts, make, just, compose) and SSH hosts.
/// Everything is read locally and cheaply on each `cd`.
public struct CompletionContext: Sendable {
    public enum Runner: String, Sendable { case pnpm, bun, yarn, npm }

    public var cwd: String
    public var entries: [CompletionEntry] = []
    public var executables: [String] = []
    public var gitBranches: [String] = []
    public var gitRemotes: [String] = []
    /// Paths `git status` reports as changed or untracked.
    public var gitChanged: [String] = []
    public var packageScripts: [String] = []
    /// Which runner the lockfile asks for.
    public var packageRunner: Runner?
    public var makeTargets: [String] = []
    public var justRecipes: [String] = []
    public var composeServices: [String] = []
    public var sshHosts: [String] = []
    public var platform = "macos"

    public init(cwd: String) { self.cwd = cwd }

    static let maxEntries = 500

    /// Reads the context for a folder (falls back to home when it's gone).
    public static func load(cwd: String?) async -> CompletionContext {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let dir = resolve(cwd ?? "", base: nil).flatMap {
            fm.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue ? $0 : nil
        } ?? Paths.home
        var context = CompletionContext(cwd: dir.path)
        context.entries = entries(of: dir)
        context.executables = await executables()
        context.sshHosts = sshHosts()
        let git = await gitState(dir)
        context.gitBranches = git.branches
        context.gitRemotes = git.remotes
        context.gitChanged = git.changed
        context.packageScripts = packageScripts(dir)
        context.packageRunner = packageRunner(dir)
        context.makeTargets = ["Makefile", "makefile", "GNUmakefile"].lazy
            .compactMap { try? String(contentsOf: dir.appending(path: $0), encoding: .utf8) }.first.map(parseMakeTargets) ?? []
        context.justRecipes = ["justfile", "Justfile", ".justfile"].lazy
            .compactMap { try? String(contentsOf: dir.appending(path: $0), encoding: .utf8) }.first.map(parseJustRecipes) ?? []
        context.composeServices = ["compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml"].lazy
            .compactMap { try? String(contentsOf: dir.appending(path: $0), encoding: .utf8) }.first.map(parseComposeServices) ?? []
        return context
    }

    /// Entries of a folder named relative to the shell's cwd (`src/`, `../api/`, `~/Downloads/`).
    public static func listDirectory(cwd: String, _ typed: String) -> [CompletionEntry] {
        guard let url = resolve(typed, base: resolve(cwd, base: nil)) else { return [] }
        return entries(of: url)
    }

    /// Resolves what a person typed (`~`, `~/x`, `/abs`, `rel/`) against `base`.
    static func resolve(_ typed: String, base: URL?) -> URL? {
        if typed.isEmpty { return base }
        if typed == "~" { return Paths.home }
        if typed.hasPrefix("~/") { return Paths.home.appending(path: String(typed.dropFirst(2))) }
        if typed.hasPrefix("/") { return URL(fileURLWithPath: typed) }
        return base.map { $0.appending(path: typed) } ?? URL(fileURLWithPath: typed)
    }

    static func entries(of directory: URL) -> [CompletionEntry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var result: [CompletionEntry] = []
        result.reserveCapacity(min(names.count, maxEntries))
        for name in names where !name.isEmpty {
            var isDir: ObjCBool = false
            // Follows symlinks, so a linked folder completes as one.
            _ = fm.fileExists(atPath: directory.appending(path: name).path, isDirectory: &isDir)
            result.append(CompletionEntry(name: name, isDirectory: isDir.boolValue))
        }
        result.sort {
            $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.lowercased() < $1.name.lowercased()
        }
        return Array(result.prefix(maxEntries))
    }

    // MARK: Cached lists

    private struct Cached {
        var at: Date
        var list: [String]
    }

    private static let cache = OSAllocatedUnfairLock<[String: Cached]>(initialState: [:])

    /// Scanning every PATH folder costs tens of milliseconds and runs on
    /// every `cd`, so the list is cached; new installs appear within a minute.
    private static func cached(_ key: String, _ load: () -> [String]) -> [String] {
        if let hit = cache.withLock({ $0[key] }), Date().timeIntervalSince(hit.at) < 60 { return hit.list }
        let list = load()
        cache.withLock { $0[key] = Cached(at: Date(), list: list) }
        return list
    }

    static func executables() async -> [String] {
        await Shell.ready()
        let path = Shell.loginPath ?? Shell.path
        return cached("executables") {
            let fm = FileManager.default
            var seen = Set<String>()
            var names: [String] = []
            for dir in path.split(separator: ":") {
                guard let items = try? fm.contentsOfDirectory(atPath: String(dir)) else { continue }
                for name in items where !name.hasPrefix(".") && !seen.contains(name) {
                    let full = "\(dir)/\(name)"
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue,
                          fm.isExecutableFile(atPath: full) else { continue }
                    seen.insert(name)
                    names.append(name)
                }
            }
            return names.sorted()
        }
    }

    static func sshHosts() -> [String] {
        cached("ssh-hosts") {
            (try? String(contentsOf: Paths.home.appending(path: ".ssh/config"), encoding: .utf8)).map(parseSSHHosts) ?? []
        }
    }

    // MARK: Git

    struct GitState {
        var branches: [String] = []
        var remotes: [String] = []
        var changed: [String] = []
    }

    private static func git(_ dir: URL, _ args: [String]) async -> String? {
        // Runs in every folder the shell enters, trusted or not: a repo's own
        // config must not get to run a command (`core.fsmonitor`).
        let full = ["-C", dir.path, "-c", "core.quotepath=off", "-c", "core.fsmonitor=false"] + args
        guard let out = try? await Shell.run("git", full, timeout: .seconds(5), environment: ["GIT_OPTIONAL_LOCKS": "0"]),
              out.ok else { return nil }
        return out.stdout
    }

    static func gitState(_ dir: URL) async -> GitState {
        // Not a repository: skip the other calls entirely.
        guard let branches = await git(dir, ["branch", "--all", "--format=%(refname:short)", "--sort=-committerdate"]) else {
            return GitState()
        }
        async let remotes = git(dir, ["remote"])
        async let status = git(dir, ["status", "--porcelain=v1", "-uall"])
        return GitState(branches: parseBranches(branches),
                        remotes: Array(lines(await remotes ?? "").prefix(20)),
                        changed: parsePorcelain(await status ?? ""))
    }

    static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// `origin/feature` also completes as `feature` (git switch DWIM).
    static func parseBranches(_ text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for line in lines(text) {
            let name = line.hasPrefix("origin/") ? String(line.dropFirst(7)) : line
            guard !name.isEmpty, name != "HEAD", name != "origin", seen.insert(name).inserted else { continue }
            result.append(name)
            if result.count == 300 { break }
        }
        return result
    }

    /// `XY path` or `XY old -> new` per line; the path is what `git add` takes.
    static func parsePorcelain(_ status: String) -> [String] {
        status.split(separator: "\n").compactMap { line -> String? in
            guard line.count > 3 else { return nil }
            let path = String(line.dropFirst(3))
            let target = path.components(separatedBy: " -> ").last ?? path
            return target.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        .prefix(200).map { $0 }
    }

    // MARK: Projects

    static func packageScripts(_ dir: URL) -> [String] {
        guard let data = try? Data(contentsOf: dir.appending(path: "package.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = json["scripts"] as? [String: Any] else { return [] }
        return scripts.keys.sorted()
    }

    /// The lockfile decides the runner; walks up for workspaces.
    static func packageRunner(_ dir: URL) -> Runner? {
        let locks: [(String, Runner)] = [("pnpm-lock.yaml", .pnpm), ("bun.lock", .bun), ("bun.lockb", .bun),
                                         ("yarn.lock", .yarn), ("package-lock.json", .npm)]
        var current = dir
        for _ in 0..<6 {
            for (file, runner) in locks where FileManager.default.fileExists(atPath: current.appending(path: file).path) {
                return runner
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return nil
    }

    static func parseMakeTargets(_ makefile: String) -> [String] {
        var targets: [String] = []
        for line in makefile.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let first = line.first, ![" ", "\t", "#", "."].contains(first),
                  let colon = line.firstIndex(of: ":") else { continue }
            let head = line[..<colon], rest = line[line.index(after: colon)...]
            // `VAR := x` and `VAR ::= x` are assignments, not rules.
            if rest.hasPrefix("=") || head.contains("=") || head.contains("$") || head.contains("%") { continue }
            for target in head.split(separator: " ") where !targets.contains(String(target)) {
                targets.append(String(target))
            }
        }
        return targets
    }

    static func parseJustRecipes(_ justfile: String) -> [String] {
        let reserved: Set<String> = ["set", "alias", "export", "import", "mod"]
        return justfile.split(separator: "\n").compactMap { line -> String? in
            guard let first = line.first, ![" ", "\t", "#", "["].contains(first), !line.contains(":="),
                  let colon = line.firstIndex(of: ":"),
                  let word = line[..<colon].split(separator: " ").first else { return nil }
            let name = String(word.drop { $0 == "@" })
            let valid = !name.isEmpty && !reserved.contains(name)
                && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
            return valid ? name : nil
        }
    }

    /// Keys one level under the top-level `services:` block.
    static func parseComposeServices(_ compose: String) -> [String] {
        var services: [String] = []
        var inside = false
        var indent: Int?
        for line in compose.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let depth = line.prefix { $0 == " " || $0 == "\t" }.count
            if depth == 0 {
                inside = line.trimmingCharacters(in: .whitespaces) == "services:"
                continue
            }
            guard inside else { continue }
            let level = indent ?? depth
            indent = level
            if depth == level, trimmed.hasSuffix(":") {
                services.append(String(trimmed.dropLast()).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")))
            }
        }
        return services
    }

    static func parseSSHHosts(_ config: String) -> [String] {
        var hosts: [String] = []
        for raw in config.split(separator: "\n") {
            let words = raw.trimmingCharacters(in: .whitespaces).split(whereSeparator: \.isWhitespace)
            guard let keyword = words.first, keyword.lowercased() == "host" else { continue }
            for host in words.dropFirst() where !host.contains(where: { "*?!".contains($0) }) && !hosts.contains(String(host)) {
                hosts.append(String(host))
            }
        }
        return hosts
    }
}
