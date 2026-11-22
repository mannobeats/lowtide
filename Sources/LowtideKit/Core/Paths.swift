import Foundation

/// Where Lowtide keeps its files. `LOWTIDE_HOME` moves everything (data,
/// caches, logs) under one folder so tests and snapshots never touch real data.
public enum Paths {
    public static let bundleID = "dev.lowtide.app"
    public static let appName = "Lowtide"

    /// `$HOME`, only when it is an absolute path: a relative one would make
    /// every path built on it relative to the working directory.
    public static var home: URL {
        if let home = ProcessInfo.processInfo.environment["HOME"], home.hasPrefix("/") {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private static var override: URL? {
        ProcessInfo.processInfo.environment["LOWTIDE_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// `~/Library/Application Support/dev.lowtide.app`.
    public static var data: URL {
        folder(override?.appending(path: "data")
            ?? home.appending(path: "Library/Application Support/\(bundleID)"))
    }

    /// Rebuildable things (icons, update feeds). Safe to delete.
    public static var cache: URL {
        folder(override?.appending(path: "cache") ?? home.appending(path: "Library/Caches/\(bundleID)"))
    }

    public static var logs: URL {
        folder(override?.appending(path: "logs") ?? home.appending(path: "Library/Logs/Lowtide"))
    }

    @discardableResult
    static func folder(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `~/x` for display.
    public static func tilde(_ path: String) -> String {
        let h = home.path
        return path == h ? "~" : path.hasPrefix(h + "/") ? "~" + path.dropFirst(h.count) : path
    }

    /// A launchd label or bundle id safe to put in a command: letters, digits, `.`, `-`, `_`.
    public static func safeID(_ id: String) -> String? {
        let ok = !id.isEmpty && id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)
        }
        return ok ? id : nil
    }
}
