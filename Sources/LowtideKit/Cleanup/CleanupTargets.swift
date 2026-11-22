import Darwin
import Foundation

/// A place on the Mac holding space a developer can take back.
public struct Reclaimable: Sendable, Identifiable, Hashable {
    public enum Group: String, Sendable, CaseIterable { case projects, caches, xcode }
    public enum Safety: String, Sendable { case safe, review }

    public let id: String
    public let group: Group
    public let name: String
    public let description: String
    public let path: String
    /// `nil` until measured, or when it couldn't be.
    public var bytes: Int64?
    public let safety: Safety
    /// What cleaning does: the command, or "Move to Trash".
    public let action: String
    /// Build folders: the project folder's name.
    public let project: String?
    /// Build folders: when the project was last worked on.
    public let lastActive: Date?

    public init(id: String, group: Group, name: String, description: String, path: String, bytes: Int64? = nil,
                safety: Safety, action: String, project: String? = nil, lastActive: Date? = nil) {
        self.id = id
        self.group = group
        self.name = name
        self.description = description
        self.path = path
        self.bytes = bytes
        self.safety = safety
        self.action = action
        self.project = project
        self.lastActive = lastActive
    }

    /// Untouched this long, a project's build folders are safe bets.
    public static let stale: TimeInterval = 30 * 86_400

    public func isStale(now: Date = Date()) -> Bool {
        lastActive.map { now.timeIntervalSince($0) > Self.stale } ?? false
    }

    /// Selected when found: safe caches, and build folders of stale projects.
    public func preselected(now: Date = Date()) -> Bool {
        guard safety == .safe else { return false }
        return group != .projects || isStale(now: now)
    }
}

/// What cleaning one place did.
public struct CleanupResult: Sendable {
    public var freed: Int64
    /// Moved to the Trash (Undo puts these back); empty when a tool cleaned.
    public var undo: [Trash.Moved] = []
    public var toTrash: Bool
}

/// Package-manager and tool caches, Xcode leftovers, and build folders
/// inside projects. Each place is moved to the Trash or cleaned by its own
/// tool, and measured before and after so the space reported is what was
/// really freed.
public enum CleanupTargets {
    enum Method: Sendable, Equatable {
        /// Moves the folder's contents to the Trash.
        case trashContents
        /// Lets the owning tool clean its own cache (it knows what's in use).
        case tool(String, [String])
        /// `pnpm store prune` on the store folder its own version uses;
        /// folders other pnpm versions left go to the Trash.
        case pnpmPrune

        var label: String {
            switch self {
            case .trashContents: "Move to Trash"
            case .tool(let program, let args): ([program] + args).joined(separator: " ")
            case .pnpmPrune: "pnpm store prune"
            }
        }

        var program: String? {
            switch self {
            case .trashContents: nil
            case .tool(let program, _): program
            case .pnpmPrune: "pnpm"
            }
        }
    }

    struct Cache: Sendable {
        let id: String
        let group: Reclaimable.Group
        let name: String
        let description: String
        /// Relative to HOME.
        let path: String
        let safety: Reclaimable.Safety
        let method: Method
    }

    static let caches: [Cache] = [
        Cache(id: "homebrew", group: .caches, name: "Homebrew", description: "Downloaded bottles, old versions and logs",
              path: "Library/Caches/Homebrew", safety: .safe, method: .tool("brew", ["cleanup", "--prune=all", "-s"])),
        Cache(id: "npm", group: .caches, name: "npm", description: "Cached package tarballs and metadata",
              path: ".npm/_cacache", safety: .safe, method: .tool("npm", ["cache", "clean", "--force"])),
        Cache(id: "pnpm", group: .caches, name: "pnpm store",
              description: "Only packages no project uses are removed; the rest is shared with node_modules, so less is freed than the store's size",
              path: "Library/pnpm/store", safety: .safe, method: .pnpmPrune),
        Cache(id: "yarn", group: .caches, name: "Yarn", description: "Cached package archives",
              path: "Library/Caches/Yarn", safety: .safe, method: .trashContents),
        Cache(id: "bun", group: .caches, name: "Bun", description: "Cached package downloads",
              path: ".bun/install/cache", safety: .safe, method: .trashContents),
        Cache(id: "cargo-registry", group: .caches, name: "Cargo registry", description: "Downloaded and unpacked crate sources",
              path: ".cargo/registry", safety: .safe, method: .trashContents),
        Cache(id: "cargo-git", group: .caches, name: "Cargo git checkouts", description: "Git dependencies checked out by Cargo",
              path: ".cargo/git", safety: .safe, method: .trashContents),
        Cache(id: "go-build", group: .caches, name: "Go build cache", description: "Compiled packages; rebuilt on demand",
              path: "Library/Caches/go-build", safety: .safe, method: .tool("go", ["clean", "-cache"])),
        Cache(id: "go-mod", group: .caches, name: "Go module cache",
              description: "Downloaded modules; re-downloaded when builds need them",
              path: "go/pkg/mod", safety: .review, method: .tool("go", ["clean", "-modcache"])),
        Cache(id: "pip", group: .caches, name: "pip", description: "Downloaded wheels and HTTP cache",
              path: "Library/Caches/pip", safety: .safe, method: .trashContents),
        Cache(id: "uv", group: .caches, name: "uv",
              description: "Python packages cached by uv. Virtualenvs share its files, so less may be freed than its size",
              path: ".cache/uv", safety: .safe, method: .tool("uv", ["cache", "clean"])),
        Cache(id: "gradle", group: .caches, name: "Gradle", description: "Dependency and build caches",
              path: ".gradle/caches", safety: .review, method: .trashContents),
        Cache(id: "maven", group: .caches, name: "Maven repository", description: "Downloaded Java dependencies",
              path: ".m2/repository", safety: .review, method: .trashContents),
        Cache(id: "cocoapods", group: .caches, name: "CocoaPods", description: "Downloaded pod sources",
              path: "Library/Caches/CocoaPods", safety: .safe, method: .trashContents),
        Cache(id: "node-gyp", group: .caches, name: "node-gyp headers", description: "Node headers for native modules",
              path: "Library/Caches/node-gyp", safety: .safe, method: .trashContents),
        Cache(id: "typescript", group: .caches, name: "TypeScript", description: "Type acquisition cache",
              path: "Library/Caches/typescript", safety: .safe, method: .trashContents),
        Cache(id: "electron", group: .caches, name: "Electron", description: "Downloaded Electron binaries",
              path: "Library/Caches/electron", safety: .safe, method: .trashContents),
        Cache(id: "deno", group: .caches, name: "Deno", description: "Remote modules and compiled code",
              path: "Library/Caches/deno", safety: .safe, method: .trashContents),
        Cache(id: "playwright", group: .caches, name: "Playwright browsers",
              description: "Test browsers; reinstall with `playwright install`",
              path: "Library/Caches/ms-playwright", safety: .review, method: .trashContents),
        Cache(id: "puppeteer", group: .caches, name: "Puppeteer browsers", description: "Downloaded Chrome builds",
              path: ".cache/puppeteer", safety: .review, method: .trashContents),
        Cache(id: "jetbrains", group: .caches, name: "JetBrains IDEs",
              description: "Indexes and caches; rebuilt when a project opens",
              path: "Library/Caches/JetBrains", safety: .safe, method: .trashContents),
        Cache(id: "xcode-derived", group: .xcode, name: "Derived Data", description: "Build products and indexes Xcode regenerates",
              path: "Library/Developer/Xcode/DerivedData", safety: .safe, method: .trashContents),
        Cache(id: "xcode-archives", group: .xcode, name: "Archives",
              description: "Archived app builds, including ones you may need to symbolicate",
              path: "Library/Developer/Xcode/Archives", safety: .review, method: .trashContents),
        Cache(id: "xcode-device-support", group: .xcode, name: "Device support",
              description: "Debug symbols per iOS version; re-copied when a device connects",
              path: "Library/Developer/Xcode/iOS DeviceSupport", safety: .review, method: .trashContents),
        Cache(id: "simulator-caches", group: .xcode, name: "Simulator caches", description: "Dyld and runtime caches for simulators",
              path: "Library/Developer/CoreSimulator/Caches", safety: .safe, method: .trashContents),
        Cache(id: "simulators-unavailable", group: .xcode, name: "Unavailable simulators",
              description: "Simulators for runtimes that are no longer installed",
              path: "Library/Developer/CoreSimulator/Devices", safety: .safe,
              method: .tool("xcrun", ["simctl", "delete", "unavailable"])),
    ]

    /// Every cache and Xcode place on this Mac whose cleaner is available,
    /// not measured yet.
    public static func cachePlaces(home: String = Paths.home.path) async -> [Reclaimable] {
        await Shell.ready()
        return caches.compactMap { cache in
            let path = CleanupFS.join(home, cache.path)
            guard CleanupFS.isFolder(path), cache.method.program.map(Shell.isAvailable) ?? true else { return nil }
            return Reclaimable(id: "cache:\(cache.id)", group: cache.group, name: cache.name,
                               description: describe(cache, path: path), path: path, safety: cache.safety,
                               action: cache.method.label)
        }
    }

    /// The pnpm store's size counts every version folder, so say what
    /// happens to the ones pnpm can't prune. The note leads: rows truncate.
    static func describe(_ cache: Cache, path: String) -> String {
        guard cache.method == .pnpmPrune else { return cache.description }
        let versions = storeVersions(path)
        guard versions.count >= 2 else { return cache.description }
        let names = versions.map(CleanupFS.name).joined(separator: ", ")
        return "Holds \(names): pnpm prunes the folder of its own version and moves those other pnpm versions left to the Trash. \(cache.description)"
    }

    // MARK: Project build folders

    struct ArtifactRule: Sendable {
        let folder: String
        /// A file next to the folder that proves what it is.
        let markers: [String]
        let name: String
        let description: String
        let safety: Reclaimable.Safety
    }

    static let artifacts: [ArtifactRule] = [
        ArtifactRule(folder: "node_modules", markers: ["package.json"], name: "node_modules",
                     description: "Installed JavaScript dependencies", safety: .safe),
        ArtifactRule(folder: "target", markers: ["Cargo.toml"], name: "Rust target", description: "Compiled Rust build output", safety: .safe),
        ArtifactRule(folder: ".next", markers: ["package.json"], name: "Next.js build", description: "Next.js build output and cache", safety: .safe),
        ArtifactRule(folder: ".nuxt", markers: ["package.json"], name: "Nuxt build", description: "Nuxt build output", safety: .safe),
        ArtifactRule(folder: ".svelte-kit", markers: ["package.json"], name: "SvelteKit build", description: "SvelteKit generated files", safety: .safe),
        ArtifactRule(folder: ".turbo", markers: ["package.json", "turbo.json"], name: "Turborepo cache", description: "Cached task outputs", safety: .safe),
        ArtifactRule(folder: ".parcel-cache", markers: ["package.json"], name: "Parcel cache", description: "Bundler cache", safety: .safe),
        ArtifactRule(folder: ".angular", markers: ["angular.json"], name: "Angular cache", description: "Angular CLI build cache", safety: .safe),
        ArtifactRule(folder: ".build", markers: ["Package.swift"], name: "SwiftPM build", description: "Swift package build output", safety: .safe),
        ArtifactRule(folder: "build", markers: ["build.gradle", "build.gradle.kts"], name: "Gradle build", description: "Gradle build output", safety: .safe),
        ArtifactRule(folder: ".gradle", markers: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"],
                     name: "Gradle project cache", description: "Per-project Gradle state", safety: .safe),
        ArtifactRule(folder: "Pods", markers: ["Podfile"], name: "CocoaPods", description: "Installed pods; restore with pod install", safety: .review),
        ArtifactRule(folder: ".venv", markers: ["pyproject.toml", "requirements.txt", "setup.py", "uv.lock"], name: "Python virtualenv",
                     description: "Installed Python packages for this project", safety: .review),
        ArtifactRule(folder: "venv", markers: ["pyproject.toml", "requirements.txt", "setup.py"], name: "Python virtualenv",
                     description: "Installed Python packages for this project", safety: .review),
    ]

    /// Folders never worth descending into while looking for projects.
    static let skip: Set<String> = [".git", "Library", "Applications", ".Trash", "Pictures", "Music", "Movies"]
    static let maxDepth = 6

    static func artifactRule(_ path: String) -> ArtifactRule? {
        let name = CleanupFS.name(path), parent = CleanupFS.parent(path)
        return artifacts.first { rule in
            rule.folder == name && rule.markers.contains { CleanupFS.exists(CleanupFS.join(parent, $0)) }
        }
    }

    /// When a project was last worked on: newest of the folder, its git
    /// index (touched by every commit, checkout and add) and its manifests.
    static func lastActive(_ project: String) -> Date? {
        [project, ".git/index", "package.json", "Cargo.toml", "Cargo.lock", "pnpm-lock.yaml", "package-lock.json"]
            .map { $0 == project ? project : CleanupFS.join(project, $0) }
            .compactMap { path -> Date? in
                var info = stat()
                return stat(path, &info) == 0 ? Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)) : nil
            }
            .max()
    }

    /// Walks the project folders and hands each build folder to `found` as
    /// soon as it's seen. Never follows links: a linked folder is cleaned
    /// where it lives.
    public static func findArtifacts(in roots: [String], stop: @Sendable () -> Bool = { false },
                                     found: (Reclaimable) -> Void) {
        var visited: Set<String> = []
        var stack = roots.map { ($0, 0) }
        while let (dir, depth) = stack.popLast() {
            if stop() { return }
            guard let real = CleanupFS.realPath(dir), visited.insert(real).inserted else { continue }
            for name in CleanupFS.names(dir) {
                let path = CleanupFS.join(dir, name)
                guard CleanupFS.isDir(path) else { continue }
                if let rule = artifactRule(path) {
                    let project = CleanupFS.parent(path)
                    found(Reclaimable(id: "artifact:\(path)", group: .projects, name: rule.name, description: rule.description,
                                      path: path, safety: rule.safety, action: "Move to Trash",
                                      project: CleanupFS.name(project), lastActive: lastActive(project)))
                    continue
                }
                if depth < maxDepth, !skip.contains(name), !(name.hasPrefix(".") && name.count > 1) {
                    stack.append((path, depth + 1))
                }
            }
        }
    }

    /// Where projects probably live: the usual folder names in HOME, plus
    /// the parent of every git repository the terminal has been used in.
    public static func defaultRoots(recentDirs: [String], home: String = Paths.home.path) -> [String] {
        var roots = ["Developer", "Projects", "projects", "Code", "code", "dev", "Dev", "src", "repos", "workspace",
                     "Workspace", "GitHub", "Documents/GitHub", "Sites"]
            .map { spelled(CleanupFS.join(home, $0)) }
            .filter(CleanupFS.isFolder)
        for dir in recentDirs where dir.hasPrefix("/") {
            var candidate = dir
            while candidate != "/", !candidate.isEmpty, !CleanupFS.exists(CleanupFS.join(candidate, ".git")) {
                candidate = CleanupFS.parent(candidate)
            }
            guard candidate != "/", !candidate.isEmpty else { continue }
            let parent = CleanupFS.parent(candidate)
            if parent != home, parent != "/" { roots.append(parent) }
        }
        roots.sort()
        // Case-insensitive volumes list `~/Workspace` and `~/workspace` as
        // two paths to one folder; the inode tells them apart.
        var identities: Set<String> = []
        roots = roots.filter { root in
            var info = stat()
            return stat(root, &info) == 0 && identities.insert("\(info.st_dev):\(info.st_ino)").inserted
        }
        // Drop roots inside another root; the walk covers them.
        return roots.filter { root in !roots.contains { $0 != root && CleanupFS.isInside(root, $0) } }
    }

    /// A path as the disk spells its last part: on a case-insensitive
    /// volume `~/Code` finds `~/code`, and the chip should say `code`.
    static func spelled(_ path: String) -> String {
        let name = CleanupFS.name(path), parent = CleanupFS.parent(path)
        let names = CleanupFS.names(parent)
        if names.contains(name) { return path }
        return names.first { $0.caseInsensitiveCompare(name) == .orderedSame }.map { CleanupFS.join(parent, $0) } ?? path
    }

    // MARK: Cleaning

    /// pnpm's store format folders (`v3`, `v10`…), oldest first. Each pnpm
    /// reads and prunes only its own.
    static func storeVersions(_ store: String) -> [String] {
        CleanupFS.names(store)
            .compactMap { name -> (Int, String)? in
                let path = CleanupFS.join(store, name)
                guard name.hasPrefix("v"), let number = Int(name.dropFirst()), CleanupFS.isDir(path) else { return nil }
                return (number, path)
            }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
    }

    /// Cleans one place. Sizes before and after, so `freed` is real.
    public static func clean(_ item: Reclaimable, home: String = Paths.home.path) async throws -> CleanupResult {
        if item.id.hasPrefix("artifact:") { return try await cleanArtifact(String(item.id.dropFirst(9)), home: home) }
        guard item.id.hasPrefix("cache:"), let cache = caches.first(where: { "cache:\($0.id)" == item.id }) else {
            throw LowtideError.invalid("Unknown cleanup place")
        }
        let path = CleanupFS.join(home, cache.path)
        let before = await DiskSize.measure(path) ?? 0
        var result = CleanupResult(freed: 0, toTrash: false)
        switch cache.method {
        case .tool(let program, let args):
            try await ToolLock.shared.with(program == "xcrun" ? "simctl" : program) {
                _ = try await Shell.check(program, args)
            }
        case .trashContents:
            guard !CleanupFS.isLink(path) else { throw LowtideError.denied("Refusing to clean a linked folder") }
            let outcome = await Trash.move(CleanupFS.names(path).map { CleanupFS.join(path, $0) })
            result.undo = outcome.undoable
            result.toTrash = true
            if let first = outcome.refused.first { throw LowtideError.commandFailed("\(CleanupFS.name(first.path)): \(first.reason)") }
        case .pnpmPrune:
            let moved = try await cleanPnpm(store: path)
            result.undo = moved.undoable
            result.toTrash = !moved.moved.isEmpty
        }
        let after = await DiskSize.measure(path) ?? 0
        result.freed = max(0, before - after)
        return result
    }

    /// Runs pnpm on `store` and only there. Without `--store-dir` pnpm picks
    /// a store from the folder it runs in: from `/`, where Finder starts
    /// apps, it fails writing a probe file to the read-only system volume
    /// (EROFS), and from another volume it uses that volume's store. `--dir`
    /// keeps a project's `packageManager` from switching pnpm versions.
    static func pnpmArguments(store: String, _ command: [String]) -> [String] {
        ["--dir", store] + command + ["--store-dir", store]
    }

    static func pnpm(store: String, _ command: [String]) async throws -> String {
        let out = try await Shell.run("pnpm", pnpmArguments(store: store, command), directory: URL(fileURLWithPath: store))
        guard out.ok else {
            let text = out.message.isEmpty ? "no output" : out.message
            throw LowtideError.commandFailed("`pnpm \(command.joined(separator: " "))` exited with code \(out.status): \(text)")
        }
        return out.stdout
    }

    /// The store folder pnpm reported, when it is one of `store`'s own.
    static func activeStore(reported: String, store: String) -> String? {
        let line = reported.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
        guard let line else { return nil }
        let trimmed = line.hasSuffix("/") ? String(line.dropLast()) : line
        let normalizedStore = store.hasSuffix("/") ? String(store.dropLast()) : store
        return CleanupFS.parent(trimmed) == normalizedStore ? trimmed : nil
    }

    /// Prunes the store folder the installed pnpm uses, then moves the
    /// folders other pnpm versions left to the Trash: this pnpm can't read
    /// them, and node_modules keep their hard-linked files either way.
    static func cleanPnpm(store: String) async throws -> Trash.Outcome {
        try await ToolLock.shared.with("pnpm") {
            let reported = try await pnpm(store: store, ["store", "path"])
            guard let active = activeStore(reported: reported, store: store) else {
                throw LowtideError.commandFailed("pnpm didn't report a store folder inside \(Paths.tilde(store))")
            }
            _ = try await pnpm(store: store, ["store", "prune"])
            let others = storeVersions(store).filter { $0 != active }
            guard !others.isEmpty else { return Trash.Outcome() }
            return await Trash.move(others)
        }
    }

    /// Re-checks the rule at removal time: only a real, unlinked build folder
    /// you own, inside a project in HOME, next to its marker file. (A linked
    /// HOME is fine: the rule compares the resolved spellings.)
    static func validArtifact(_ path: String, home: String) -> String? {
        guard path.hasPrefix("/"), let info = CleanupFS.info(path), (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == CleanupFS.uid,
              let real = CleanupFS.realPath(path), let realParent = CleanupFS.realPath(CleanupFS.parent(path)),
              real == CleanupFS.join(realParent, CleanupFS.name(path)),
              let realHome = CleanupFS.realPath(home), CleanupFS.isInside(real, realHome),
              real.dropFirst(realHome.count).split(separator: "/").count >= 2,
              artifactRule(path) != nil else { return nil }
        return real
    }

    static func cleanArtifact(_ path: String, home: String) async throws -> CleanupResult {
        guard let real = validArtifact(path, home: home) else {
            throw LowtideError.denied("\(Paths.tilde(path)) isn't a build folder Lowtide can clean")
        }
        let before = await DiskSize.measure(real) ?? 0
        let outcome = await Trash.move([real])
        if let refused = outcome.refused.first { throw LowtideError.commandFailed(refused.reason) }
        return CleanupResult(freed: before, undo: outcome.undoable, toTrash: true)
    }
}
