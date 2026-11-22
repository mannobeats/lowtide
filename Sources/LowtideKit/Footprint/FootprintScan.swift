import Darwin
import Foundation

extension Footprint {
    // MARK: - Scan

    static func item(_ path: String, _ category: Category, _ confidence: Confidence, _ reason: String) -> Item? {
        guard let info = CleanupFS.info(path) else { return nil }
        let name = CleanupFS.name(path)
        guard !name.isEmpty else { return nil }
        return Item(path: path, name: name, category: category, confidence: confidence, reason: reason, bytes: nil,
                    isDir: (info.st_mode & S_IFMT) == S_IFDIR, needsAdmin: info.st_uid != getuid(),
                    hidden: name.hasPrefix("."))
    }

    static func search(_ matcher: Matcher, _ dir: String, _ category: Category, into out: inout [Item]) {
        // The system's own logs live here (`wifi.log`): only a folder, or a
        // file named after the bundle id, can be the app's.
        let systemLog = dir == "/private/var/log"
        let inLogs = category == .logs && !systemLog
        for name in CleanupFS.names(dir) {
            guard let (confidence, reason) = matcher.classify(name, inLogs: inLogs) else { continue }
            let path = CleanupFS.join(dir, name)
            if systemLog, confidence != .exact, !CleanupFS.isFolder(path) { continue }
            // A vendor folder is shared; look inside it for the product's own.
            if confidence == .shared, CleanupFS.isFolder(path) {
                let before = out.count
                for child in CleanupFS.names(path) {
                    if let (inner, why) = matcher.classify(child, inLogs: inLogs), inner != .shared,
                       let found = item(CleanupFS.join(path, child), category, inner, "\(why), in the developer folder") {
                        out.append(found)
                    }
                }
                if out.count > before { continue }
            }
            if let found = item(path, category, confidence, reason) { out.append(found) }
        }
    }

    /// Commands linked into the app (`/usr/local/bin/docker`): they dangle
    /// once it is gone.
    static func scanCommands(_ subject: Subject, home: String, into out: inout [Item]) {
        let apps = subject.primary.filter { $0.category == .app }.flatMap { [$0.path, CleanupFS.realPath($0.path)].compactMap { $0 } }
        guard !apps.isEmpty else { return }
        for dir in commandDirs.map({ $0.hasPrefix("/") ? $0 : CleanupFS.join(home, $0) }) {
            for name in CleanupFS.names(dir) {
                let path = CleanupFS.join(dir, name)
                guard CleanupFS.isLink(path), let real = CleanupFS.realPath(path), apps.contains(where: { CleanupFS.isInside(real, $0) }),
                      let found = item(path, .helpers, .exact, "a command that runs from the app")
                else { continue }
                out.append(found)
            }
        }
    }

    /// The per-user temporary and cache folders (`/var/folders/…/C`).
    static func darwinFolder(_ name: Int32) -> String? {
        let length = confstr(name, nil, 0)
        guard length > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        guard confstr(name, &buffer, length) > 0 else { return nil }
        let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        // `/var/folders/…` is `/private/var/folders/…`, the spelling `removable` allows.
        return text.isEmpty ? nil : CleanupFS.realPath(text)
    }

    static func scanLocations(_ subject: Subject, home: String = Footprint.home) -> [Item] {
        let matcher = Matcher(subject)
        var out: [Item] = []
        for (relative, category) in userLocations { search(matcher, CleanupFS.join(home, relative), category, into: &out) }
        for (absolute, category) in systemLocations { search(matcher, absolute, category, into: &out) }
        // Hidden dot-folders straight in HOME (`~/.vscode`, `~/.docker`).
        for name in CleanupFS.names(home) where name.hasPrefix(".") {
            if let (confidence, reason) = matcher.classify(name, inLogs: false),
               let found = item(CleanupFS.join(home, name), .hidden, confidence, reason) {
                out.append(found)
            }
        }
        scanCommands(subject, home: home, into: &out)
        for (id, folders) in also where matcher.ids.contains(id) {
            for folder in folders {
                if let found = item(CleanupFS.join(home, folder), .support, .shared, "downloaded through the app; other tools may use it") {
                    out.append(found)
                }
            }
        }
        for key in [_CS_DARWIN_USER_CACHE_DIR, _CS_DARWIN_USER_TEMP_DIR] {
            if let dir = darwinFolder(key) { search(matcher, dir, .caches, into: &out) }
        }
        return out.map { cliShared($0, home: home) }
    }

    /// Dot-folders in HOME (and `~/.config`, `~/.local/share`, `~/.cache`)
    /// matched only by name are as often a command-line tool's as the app's:
    /// `~/.claude` is Claude Code's, not the Claude app's. They're offered,
    /// never preselected.
    static func cliShared(_ item: Item, home: String) -> Item {
        guard item.confidence == .likely else { return item }
        let parent = CleanupFS.parent(item.path)
        let cli = [home + "/.config", home + "/.local/share", home + "/.cache"].contains(parent)
            || (parent == home && item.name.hasPrefix("."))
        guard cli else { return item }
        var shared = item
        shared.confidence = .shared
        shared.reason = "named like the app; a command-line tool of the same name may use it"
        return shared
    }

    /// Category of a path found through a receipt.
    static func category(of path: String) -> Category {
        if path.hasSuffix(".app") { return .app }
        if pluginFolders.contains(where: { path.contains($0.folder) }) { return .plugins }
        let rules: [(String, Category)] = [
            ("/LaunchAgents/", .launch), ("/LaunchDaemons/", .launch), ("/PrivilegedHelperTools/", .helpers),
            ("/Preferences/", .preferences), ("/Caches/", .caches), ("/Presets/", .presets), ("/Logs/", .logs),
            ("/Application Support/", .support), ("/usr/local/", .helpers),
        ]
        return rules.first { path.contains($0.0) }?.1 ?? .support
    }

    /// Keeps the strongest evidence per path and drops paths inside another.
    static func dedupe(_ items: [Item]) -> [Item] {
        let sorted = items.filter { removable($0.path) }
            .sorted { $0.path == $1.path ? $0.confidence < $1.confidence : $0.path < $1.path }
        var unique: [Item] = []
        for item in sorted where unique.last?.path != item.path { unique.append(item) }
        let paths = unique.map(\.path)
        return unique.filter { item in !paths.contains { $0 != item.path && CleanupFS.isInside(item.path, $0) } }
    }

    /// Every file the subject left, not measured yet: the map measures each
    /// and shows sizes as they land.
    public static func locate(_ subject: Subject) async -> [Item] {
        let packages = await PackageList.shared.all()
        var receipts = matchingPackages(packages, subject)
        // Packages ship as families (`….vst3`, `….au`, `….resources`): a
        // known receipt brings its siblings.
        for known in subject.packages { receipts += receiptSiblings(packages, known: known) }
        receipts = Array(Set(receipts)).sorted()

        var items = subject.primary.compactMap { item($0.path, $0.category, .primary, "the item itself") }

        // All of a product's packages together: its folder is only fully
        // "owned" when every package that filled it is counted.
        var allPaths: [String] = []
        var owner: [String: String] = [:]
        for pkg in receipts {
            for path in await packagePaths(pkg) {
                if owner[path] == nil { owner[path] = pkg }
                allPaths.append(path)
            }
        }
        let names = subject.names, packaged = allPaths
        let roots = await offMain { packageRoots(packaged, names: names) }
        for root in roots {
            if let found = item(root, category(of: root), .installer, "installed by \(owner[root] ?? "a package")") { items.append(found) }
        }
        for pkg in receipts {
            for ext in ["bom", "plist"] {
                if let found = item("/private/var/db/receipts/\(pkg).\(ext)", .receipts, .installer, "receipt of \(pkg)") { items.append(found) }
            }
        }
        items += await offMain { scanLocations(subject) }
        return dedupe(items)
    }

    /// `locate`, measured: for removals that report what they freed.
    public static func scan(_ subject: Subject) async -> [Item] {
        var items = await locate(subject)
        let sizes = await DiskSize.measure(items.map(\.path))
        for index in items.indices { items[index].bytes = sizes[index] }
        return items
    }

    /// Blocking file work, off the caller's executor.
    static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }

    // MARK: - Browsing inside an item

    /// One level of a folder in the map, measured, largest first.
    public static func children(_ path: String) async throws -> [Child] {
        guard let path = onDisk(path), removable(path), CleanupFS.isDir(path) else {
            throw LowtideError.invalid("That isn't a folder in this footprint")
        }
        let names = Array(CleanupFS.names(path).prefix(400))
        let paths = names.map { CleanupFS.join(path, $0) }
        let sizes = await DiskSize.measure(paths)
        return zip(names, paths).enumerated()
            .map { Child(path: $1.1, name: $1.0, isDir: CleanupFS.isDir($1.1), bytes: sizes[$0]) }
            .sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
    }

    // MARK: - Removal

    public struct RemoveResult: Sendable {
        /// The paths that went, as they were asked for.
        public var removed: [String] = []
        public var failed: [Trash.Refusal] = []
        /// What Undo can put back.
        public var undo: [Trash.Moved] = []

        public init() {}
    }

    /// The paths a removal may touch, as the disk spells them, with how each
    /// was asked for; the rest refused (protected places).
    static func targets(_ paths: [String]) -> (targets: [(path: String, asked: String)], refused: [Trash.Refusal]) {
        var targets: [(path: String, asked: String)] = []
        var refused: [Trash.Refusal] = []
        for raw in paths {
            guard let path = onDisk(raw) else { continue }
            if removable(path) { targets.append((path, raw)) } else { refused.append(Trash.Refusal(path: raw, reason: "A protected location")) }
        }
        return (targets, refused)
    }

    /// Moves paths to the Trash: yours in-process, the rest through the
    /// privileged helper or one password prompt for the whole batch (Undo
    /// works for both). `prompt` is the line macOS shows over the field.
    public static func remove(_ paths: [String], prompt: String) async -> RemoveResult {
        let (targets, refused) = targets(paths)
        let asked = Dictionary(targets.map { ($0.path, $0.asked) }, uniquingKeysWith: { a, _ in a })
        func label(_ path: String) -> String { asked[path] ?? path }
        let outcome = await Trash.remove(targets.map(\.path), prompt: prompt)
        var result = RemoveResult()
        result.removed = outcome.removed.map(label)
        result.undo = outcome.undoable
        result.failed = refused + outcome.refused.map { Trash.Refusal(path: label($0.path), reason: $0.reason) }
        return result
    }
}
