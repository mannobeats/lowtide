import Darwin
import Foundation

/// One thing in a folder the Space lens shows.
public struct FolderEntry: Sendable, Identifiable, Hashable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let isDir: Bool
    /// A folder Finder shows as one item (an app, a library).
    public let package: Bool
    /// Another disk mounted here (a cloud drive, a share): never measured.
    public let mount: Bool
    public let hidden: Bool
    /// Files at once; folders once measured.
    public var bytes: Int64?
    public let modified: Date?

    /// A folder the lens opens rather than selects.
    public var opens: Bool { isDir && !package && !mount }
}

/// The Space lens: a folder listed at once, its folders measured as each
/// finishes, and the rule for what can go to the Trash from it.
public enum FolderScan {
    /// Folders Finder shows as one file.
    static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "component", "vst", "vst3", "clap", "aaxplugin", "kext",
        "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle", "logicx", "band", "xcodeproj",
        "xcworkspace", "sparsebundle", "rtfd", "pages", "numbers", "key", "dsym",
    ]

    public static func isPackage(_ path: String) -> Bool {
        packageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Everything in `path`, files sized (allocated, like the folders),
    /// folders not yet.
    public static func list(_ path: String) throws -> [FolderEntry] {
        guard path.hasPrefix("/"), !path.split(separator: "/").contains(".."), let me = CleanupFS.info(path) else {
            throw LowtideError.notFound(Paths.tilde(path))
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            throw LowtideError.denied("macOS didn't let Lowtide read this folder. Full Disk Access opens it.")
        }
        var device = me.st_dev
        var followed = stat()
        if stat(path, &followed) == 0 { device = followed.st_dev }
        return names.compactMap { name in
            let child = CleanupFS.join(path, name)
            guard let info = CleanupFS.info(child) else { return nil }
            let isDir = (info.st_mode & S_IFMT) == S_IFDIR
            return FolderEntry(path: child, name: name, isDir: isDir, package: isDir && isPackage(child),
                               mount: isDir && info.st_dev != device, hidden: name.hasPrefix("."),
                               bytes: isDir ? nil : Int64(info.st_blocks) * 512,
                               modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)))
        }
    }

    /// Measures the entries' folders on 8 walkers, reporting each as it
    /// finishes. Stops when `stop` says so (leaving a folder stops its walk).
    public static func measure(_ entries: [FolderEntry], stop: @escaping @Sendable () -> Bool,
                               onMeasured: @escaping @Sendable (String, Int64) -> Void) async {
        let folders = entries.filter { $0.isDir && !$0.mount }.map(\.path)
        await DiskSize.measureEach(folders, threads: 8, stop: stop) { index, bytes in onMeasured(folders[index], bytes) }
    }

    // MARK: Trash

    /// Files a person picked by hand may go: anything they own at least two
    /// levels into HOME (never `~/Documents` itself, never `~/Library/X`) or
    /// inside a folder on an external volume.
    public static func trashable(_ path: String, home: String = Paths.home.path) -> Bool {
        guard path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
              // The parent resolved, so `/Volumes/Macintosh HD/…` can't sneak past.
              let parent = CleanupFS.realPath(CleanupFS.parent(path)),
              // HOME resolved too, or a linked HOME would take `~/Documents`
              // down the external-volume branch.
              let realHome = CleanupFS.realPath(home) else { return false }
        let resolved = CleanupFS.join(parent, CleanupFS.name(path))
        return allowedPlace(resolved, home: realHome) && CleanupFS.info(resolved)?.st_uid == CleanupFS.uid
    }

    /// The place rule of `trashable`, on resolved paths. HOME first: a HOME
    /// on another volume is still HOME.
    static func allowedPlace(_ path: String, home: String) -> Bool {
        func depth(_ root: String) -> Int {
            CleanupFS.isInside(path, root) ? path.dropFirst(root.count).split(separator: "/").count : 0
        }
        let library = CleanupFS.join(home, "Library")
        if CleanupFS.isInside(path, library) { return depth(library) >= 2 }
        if CleanupFS.isInside(path, home) { return depth(home) >= 2 }
        return CleanupFS.isInside(path, "/Volumes") && depth("/Volumes") >= 2
    }

    /// Moves what the rule allows to the Trash; the rest is refused, each
    /// with its reason.
    public static func trash(_ paths: [String]) async -> Trash.Outcome {
        let allowed = paths.filter { trashable($0) }
        var outcome = await Trash.move(allowed)
        outcome.refused += paths.filter { !allowed.contains($0) }
            .map { Trash.Refusal(path: $0, reason: "Not something you can move to the Trash from here") }
        return outcome
    }
}
