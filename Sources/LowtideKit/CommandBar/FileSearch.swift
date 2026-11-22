import Foundation

/// Files whose name holds every typed word, inside the folders the person
/// chose, through Spotlight (`mdfind`): no index of our own.
public enum FileSearch {
    public struct Hit: Equatable, Sendable {
        public var path: String
        public var name: String
        /// The parent folder, with `~`.
        public var parent: String
    }

    static let maxRaw = 1000
    static let maxHits = 200
    static let builtInIgnores: Set<String> = ["node_modules", ".git", "DerivedData", "Pods", ".build", "vendor"]
    static let packages: Set<String> = [
        "app", "appex", "bundle", "framework", "plugin", "kext", "photoslibrary", "musiclibrary", "tvlibrary",
        "photolibrary", "aplibrary", "fcpbundle", "logicx", "band", "xcodeproj", "xcworkspace", "xcarchive", "playground",
        "rtfd", "key", "pages", "numbers", "prefpane", "qlgenerator", "mdimporter", "sparsebundle",
    ]

    /// A Spotlight query asking for every word in the file name, in any
    /// order, ignoring case and diacritics. nil when there's nothing to look for.
    static func query(_ text: String) -> String? {
        guard text.trimmingCharacters(in: .whitespaces).count >= 2 else { return nil }
        return text.split(whereSeparator: \.isWhitespace).map { word in
            var escaped = ""
            for c in word {
                if "\\\"'*?".contains(c) { escaped.append("\\") }
                escaped.append(c)
            }
            return "kMDItemFSName == \"*\(escaped)*\"cd"
        }.joined(separator: " && ")
    }

    static func isPackage(_ component: String) -> Bool {
        guard let dot = component.lastIndex(of: "."), dot != component.startIndex else { return false }
        return packages.contains(component[component.index(after: dot)...].lowercased())
    }

    /// A component matches a pattern: a whole name, or an extension written `*.log` or `.log`.
    static func ignored(_ component: String, _ pattern: String) -> Bool {
        let pattern = pattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return false }
        let ext = pattern.hasPrefix("*.") ? String(pattern.dropFirst(2)) : pattern.hasPrefix(".") ? String(pattern.dropFirst()) : nil
        if let ext {
            let lower = component.lowercased(), suffix = "." + ext.lowercased()
            if lower.hasSuffix(suffix), lower.count > suffix.count { return true }
        }
        return component.caseInsensitiveCompare(pattern) == .orderedSame
    }

    /// A Spotlight hit under `scope` is shown: no hidden folder, nothing
    /// inside a package, nothing ignored.
    static func keep(_ path: String, scope: String, ignores: [String]) -> Bool {
        var root = scope
        while root.hasSuffix("/") { root.removeLast() }
        guard path.hasPrefix(root) else { return false }
        let components = path.dropFirst(root.count).split(separator: "/").map(String.init)
        guard !components.isEmpty, path.dropFirst(root.count).hasPrefix("/") else { return false }
        let parents = components.dropLast()
        return !components.contains { $0.hasPrefix(".") }
            && !parents.contains(where: isPackage)
            && !components.contains { component in
                builtInIgnores.contains(component) || ignores.contains { ignored(component, $0) }
            }
    }

    /// Search folders: `~` expanded, existing folders only, and the home
    /// folder itself replaced by its visible children other than Library.
    static func resolveScopes(_ scopes: [String], home: String = Paths.home.path) -> [String] {
        var out: [String] = []
        let fm = FileManager.default
        for scope in scopes {
            let path = (scope.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            guard path.hasPrefix("/"), fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
            let expanded: [String]
            if path == home {
                expanded = ((try? fm.contentsOfDirectory(atPath: path)) ?? []).sorted()
                    .filter { !$0.hasPrefix(".") && $0 != "Library" }
                    .map { "\(path)/\($0)" }
                    .filter { var d: ObjCBool = false; return fm.fileExists(atPath: $0, isDirectory: &d) && d.boolValue }
            } else {
                expanded = [path]
            }
            for p in expanded where !out.contains(p) { out.append(p) }
        }
        return out
    }

    /// Raw Spotlight paths into sorted, filtered, capped hits.
    static func hits(_ raw: [(scope: String, path: String)], ignores: [String]) -> [Hit] {
        var seen = Set<String>()
        let kept = raw.filter { keep($0.path, scope: $0.scope, ignores: ignores) && seen.insert($0.path).inserted }.prefix(maxHits)
        return kept.map { item in
            let url = URL(fileURLWithPath: item.path)
            return Hit(path: item.path, name: url.lastPathComponent, parent: Paths.tilde(url.deletingLastPathComponent().path))
        }
        .sorted { ($0.name.lowercased(), $0.path) < ($1.name.lowercased(), $1.path) }
    }

    /// Files named like `text` inside `scopes`.
    public static func search(_ text: String, scopes: [String], ignores: [String]) async -> [Hit] {
        guard let spotlight = query(text) else { return [] }
        let roots = resolveScopes(scopes)
        guard !roots.isEmpty else { return [] }
        let perScope = (maxRaw + roots.count - 1) / roots.count
        let raw = await withTaskGroup(of: [(scope: String, path: String)].self) { group in
            for root in roots {
                group.addTask {
                    await LineReader.lines("/usr/bin/mdfind", ["-onlyin", root, spotlight], limit: perScope, timeout: .seconds(3))
                        .lines.map { (scope: root, path: $0) }
                }
            }
            var all: [(scope: String, path: String)] = []
            for await found in group { all += found }
            return all
        }
        return hits(Array(raw.prefix(maxRaw)), ignores: ignores)
    }
}

/// Runs a tool, reading at most `limit` lines or `cap` bytes and stopping it
/// after `timeout`: Spotlight queries and the person's own scripts, where
/// the first answers matter and a slow one must not hold the bar.
enum LineReader {
    struct Result: Sendable {
        var lines: [String]
        var stderr: String
        var status: Int32?
        var timedOut: Bool
        var truncated: Bool
    }

    static func lines(_ program: String, _ args: [String], directory: URL? = nil, limit: Int = .max,
                      cap: Int = 1 << 20, timeout: Duration) async -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = args
        if let directory { process.currentDirectoryURL = directory }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let box = ProcessBox(process)
        let read = Mutex((lines: [String](), truncated: false, stderr: Data()))
        let status: Int32
        do {
            status = try await box.launch(program, timeout: timeout) {
                box.read {
                    let found = collect(out.fileHandleForReading, limit: limit, cap: cap)
                    read.withLock { $0.lines = found.lines; $0.truncated = found.truncated }
                    // Enough read: the rest of the answers don't matter.
                    if found.truncated { box.terminate() }
                }
                box.read {
                    let data = err.fileHandleForReading.readDataToEndOfFile()
                    read.withLock { $0.stderr = data.prefix(64 * 1024) }
                }
            }
        } catch {
            return Result(lines: [], stderr: error.localizedDescription, status: nil, timedOut: false, truncated: false)
        }
        await box.drained()
        let result = read.withLock { $0 }
        return Result(lines: result.lines, stderr: String(decoding: result.stderr, as: UTF8.self), status: status,
                      timedOut: box.timedOut, truncated: result.truncated)
    }

    private static func collect(_ handle: FileHandle, limit: Int, cap: Int) -> (lines: [String], truncated: Bool) {
        var lines: [String] = []
        var buffer = Data()
        var total = 0
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            total += chunk.count
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                if !line.isEmpty { lines.append(line) }
                if lines.count >= limit { return (lines, true) }
            }
            if total >= cap { return (lines, true) }
        }
        if !buffer.isEmpty { lines.append(String(decoding: buffer, as: UTF8.self)) }
        return (lines, false)
    }
}

import Synchronization
