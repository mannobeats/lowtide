import Darwin
import Foundation

/// Small file-system reads the cleanup tools share. All by path, all
/// `lstat` (a link is the link, never its target) unless named otherwise.
public enum CleanupFS {
    /// The path as the disk spells it, links resolved (`/var` → `/private/var`).
    public static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public static func info(_ path: String) -> stat? {
        var info = stat()
        return lstat(path, &info) == 0 ? info : nil
    }

    public static func exists(_ path: String) -> Bool { info(path) != nil }

    public static func isDir(_ path: String) -> Bool {
        info(path).map { ($0.st_mode & S_IFMT) == S_IFDIR } ?? false
    }

    public static func isLink(_ path: String) -> Bool {
        info(path).map { ($0.st_mode & S_IFMT) == S_IFLNK } ?? false
    }

    /// A folder, following a link to one.
    public static func isFolder(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// When the path itself last changed.
    public static func modified(_ path: String) -> Date? {
        info(path).map { Date(timeIntervalSince1970: TimeInterval($0.st_mtimespec.tv_sec)) }
    }

    /// Names in a folder (hidden ones too); empty when unreadable.
    public static func names(_ dir: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    }

    public static var uid: uid_t { getuid() }

    /// `parent/name`, without doubling the slash at `/`.
    public static func join(_ parent: String, _ name: String) -> String {
        parent.hasSuffix("/") ? parent + name : parent + "/" + name
    }

    public static func parent(_ path: String) -> String { (path as NSString).deletingLastPathComponent }
    public static func name(_ path: String) -> String { (path as NSString).lastPathComponent }

    /// `path` is `root` or inside it (whole components only).
    public static func isInside(_ path: String, _ root: String) -> Bool {
        if root == "/" { return path.hasPrefix("/") }
        return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// HOME as the disk spells it, so a linked HOME compares equal to
    /// resolved paths.
    public static var home: String { realPath(Paths.home.path) ?? Paths.home.path }
}
