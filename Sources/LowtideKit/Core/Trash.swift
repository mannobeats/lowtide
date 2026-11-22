import Darwin
import Foundation

/// Every removal in Lowtide goes to the Trash, and remembers where each item
/// landed so Undo (Put Back) works from inside Lowtide.
public enum Trash {
    public struct Refusal: Sendable, Hashable {
        public var path: String
        public var reason: String

        public init(path: String, reason: String) {
            self.path = path
            self.reason = reason
        }
    }

    /// One item now in the Trash, and where it came from.
    public struct Moved: Codable, Sendable, Hashable {
        public var original: String
        /// Where it is in the Trash; nil when macOS's `trash` moved it
        /// without saying where (Finder's Put Back still knows).
        public var trashed: String?
        /// Owned by root: putting it back needs administrator rights.
        public var admin: Bool
        /// Its owner before it moved (`uid:gid`; it's handed to the person in the Trash).
        public var owner: String?

        public init(original: String, trashed: String?, admin: Bool = false, owner: String? = nil) {
            self.original = original
            self.trashed = trashed
            self.admin = admin
            self.owner = owner
        }
    }

    public struct Outcome: Sendable {
        public var moved: [Moved] = []
        public var refused: [Refusal] = []
        /// The paths that went.
        public var removed: [String] { moved.map(\.original) }
        /// Moves Undo can reverse.
        public var undoable: [Moved] { moved.filter { $0.trashed != nil } }

        public init() {}

        public mutating func add(_ other: Outcome) {
            moved += other.moved
            refused += other.refused
        }
    }

    /// Moves the person's own paths to the Trash one by one (a single item
    /// that can't move must not fail the batch). What stayed comes back with a
    /// reason worded for the person.
    @discardableResult
    public static func move(_ paths: [String]) async -> Outcome {
        var outcome = Outcome()
        for path in paths where exists(path) {
            let landed: String?? = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    var landed: NSURL?
                    let moved = (try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &landed)) != nil
                    continuation.resume(returning: moved ? .some(landed?.path) : .none)
                }
            }
            // macOS's own `trash` (15+) reaches some places the file manager
            // is refused (another app's container).
            if landed == nil, FileManager.default.isExecutableFile(atPath: "/usr/bin/trash") {
                _ = try? await Shell.run("/usr/bin/trash", [path], timeout: .seconds(60))
            }
            if exists(path) {
                outcome.refused.append(Refusal(path: path, reason: refusal(path)))
            } else {
                outcome.moved.append(Moved(original: path, trashed: landed ?? nil))
            }
        }
        return outcome
    }

    /// Paths the person can move themselves, and paths owned by root (or in
    /// a folder only root can change). `/Applications` is admin-group
    /// writable: an admin moves apps there without a password unless the
    /// app itself is root's.
    public static func needsAdmin(_ path: String, uid: uid_t = getuid()) -> Bool {
        var info = stat(), parent = stat()
        let mine = lstat(path, &info) == 0 && info.st_uid == uid
        let parentOK = stat((path as NSString).deletingLastPathComponent, &parent) == 0
            && (parent.st_uid == uid || parent.st_mode & 0o020 != 0)
        return !(mine && parentOK)
    }

    /// Moves any paths: the person's own in-process (their launch agents
    /// stopped first), the rest with `moveAsAdmin`.
    public static func remove(_ paths: [String], prompt: String) async -> Outcome {
        let present = paths.filter(exists)
        let uid = getuid()
        let own = present.filter { !needsAdmin($0, uid: uid) }
        for agent in own where agent.contains("/LaunchAgents/") {
            _ = try? await Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)", agent], timeout: .seconds(20))
        }
        var outcome = await move(own)
        outcome.add(await moveAsAdmin(present.filter { needsAdmin($0, uid: uid) }, prompt: prompt))
        return outcome
    }

    /// Moves root-owned paths to the person's Trash: through the privileged
    /// helper when it's approved, else after one password prompt for the
    /// whole batch (`prompt` is the line macOS shows over the field).
    public static func moveAsAdmin(_ paths: [String], prompt: String) async -> Outcome {
        var outcome = Outcome()
        guard !paths.isEmpty else { return outcome }
        var owners: [String: String] = [:]
        for path in paths {
            var info = stat()
            if lstat(path, &info) == 0 { owners[path] = "\(info.st_uid):\(info.st_gid)" }
        }
        var left = paths
        if let results = await PrivilegedHelper.trash(paths) {
            left = []
            for (path, result) in zip(paths, results) {
                if result.ok {
                    outcome.moved.append(Moved(original: path, trashed: result.trashed, admin: true, owner: owners[path]))
                } else if exists(path) {
                    Log.apps.info("helper left a file: \(result.error ?? "", privacy: .public)")
                    left.append(path)
                }
            }
        }
        guard !left.isEmpty else { return outcome }
        let plan = adminScript(left, uid: getuid(), gid: getgid())
        let refused = await Admin.run(plan.script, prompt: prompt)
        for (path, destination) in zip(left, plan.destinations) {
            if exists(path) {
                let reason: String = switch refused {
                case .failure(let why): why.message
                case .success: "Still there"
                }
                outcome.refused.append(Refusal(path: path, reason: reason))
            } else {
                outcome.moved.append(Moved(original: path, trashed: exists(destination) ? destination : nil, admin: true,
                                           owner: owners[path]))
            }
        }
        return outcome
    }

    /// The shell script that moves root-owned paths into the person's Trash
    /// in one go. Launch jobs are stopped first so they don't hold their
    /// files open; two items with one name get two destinations (`mv -f`
    /// would overwrite the first); each is handed to the person so emptying
    /// the Trash (or putting it back) needs no password.
    static func adminScript(_ paths: [String], uid: uid_t, gid: gid_t) -> (script: String, destinations: [String]) {
        var taken = Set<String>()
        var lines: [String] = []
        var destinations: [String] = []
        for path in paths {
            let destination = destination(for: path, taken: taken)
            taken.insert(destination)
            destinations.append(destination)
            let domain = path.contains("/LaunchDaemons/") ? "system" : path.contains("/LaunchAgents/") ? "gui/\(uid)" : nil
            let stop = domain.map { "/bin/launchctl bootout \($0) \(Admin.quote(path)) 2>/dev/null; " } ?? ""
            lines.append("\(stop)/bin/mv -f \(Admin.quote(path)) \(Admin.quote(destination)) && /usr/sbin/chown -R \(uid):\(gid) \(Admin.quote(destination))")
        }
        return (lines.joined(separator: "; "), destinations)
    }

    /// Puts moved items back where they were. What needs root goes back after
    /// one password prompt. Returns how many went back and what couldn't.
    public static func putBack(_ moved: [Moved]) async -> (restored: Int, failed: [Refusal]) {
        let (restored, failed, needsRoot) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: putBackOwn(moved))
            }
        }
        guard !needsRoot.isEmpty else { return (restored, failed) }
        var count = restored, failures = failed
        let script = needsRoot.map { "/bin/mv \(Admin.quote($0.from)) \(Admin.quote($0.to)) && /usr/sbin/chown -R \($0.owner) \(Admin.quote($0.to))" }
            .joined(separator: "; ")
        let result = await Admin.run(script, prompt: "Lowtide needs your password to put back files that belong to the system.")
        for entry in needsRoot {
            if exists(entry.to) { count += 1 } else {
                let reason: String = if case .failure(let why) = result { why.message } else { "Couldn't put it back" }
                failures.append(Refusal(path: entry.to, reason: reason))
            }
        }
        return (count, failures)
    }

    /// The moves that need no password, in-process; returns the root-owned rest.
    private static func putBackOwn(_ moved: [Moved]) -> (Int, [Refusal], [(from: String, to: String, owner: String)]) {
        var restored = 0
        var failed: [Refusal] = []
        var needsRoot: [(from: String, to: String, owner: String)] = []
        let you = "\(getuid()):\(getgid())"
        // Shallow paths first, so a folder exists before anything inside it.
        for item in moved.sorted(by: { $0.original.split(separator: "/").count < $1.original.split(separator: "/").count }) {
            guard let trashed = item.trashed, exists(trashed) else {
                failed.append(Refusal(path: item.original, reason: "No longer in the Trash; put it back from Finder"))
                continue
            }
            if exists(item.original) {
                failed.append(Refusal(path: item.original, reason: "Something new is in its place"))
                continue
            }
            if !item.admin {
                try? FileManager.default.createDirectory(atPath: (item.original as NSString).deletingLastPathComponent,
                                                         withIntermediateDirectories: true)
                if (try? FileManager.default.moveItem(atPath: trashed, toPath: item.original)) != nil {
                    restored += 1
                    continue
                }
            }
            needsRoot.append((trashed, item.original, item.owner ?? (item.admin ? "root:wheel" : you)))
        }
        return (restored, failed, needsRoot)
    }

    static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    /// Why a path couldn't go to the Trash, in words that say what to do.
    public static func refusal(_ path: String) -> String {
        if path.contains("/Library/Containers/") || path.contains("/Library/Group Containers/") {
            return "macOS guards this app's data. Allow Lowtide Full Disk Access, then try again."
        }
        if !FileManager.default.isWritableFile(atPath: (path as NSString).deletingLastPathComponent) {
            return "Owned by the system. Removing it needs your password."
        }
        return "Couldn't move to the Trash"
    }

    /// A free name in `~/.Trash` for a plain rename (a root-owned file moved
    /// with administrator rights, which Finder can't do). `taken` holds names
    /// already handed out in the same batch.
    public static func destination(for path: String, taken: Set<String> = []) -> String {
        let trash = Paths.home.appending(path: ".Trash").path
        let name = (path as NSString).lastPathComponent.isEmpty ? "item" : (path as NSString).lastPathComponent
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        var candidate = "\(trash)/\(name)"
        var attempt = 0
        while exists(candidate) || taken.contains(candidate) {
            attempt += 1
            candidate = attempt == 1 ? "\(trash)/\(name) \(stamp)" : "\(trash)/\(name) \(stamp) \(attempt)"
        }
        return candidate
    }
}
