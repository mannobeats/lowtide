import Darwin
import Foundation

/// Moves an app's (or a plug-in's, or an add-on's) files to the Trash.
///
/// A batch works through each thing in turn (quit it, move what the person
/// owns), then moves everything owned by root in one go: through the
/// privileged helper when it's approved, else after one password prompt
/// for the whole batch. Nothing is deleted outright, so Undo (Put Back)
/// works for what the Trash holds.
public enum AppRemover {
    public struct Request: Sendable {
        public var name: String
        public var paths: [String]
        /// Quit this app first so it doesn't rewrite what we remove.
        public var quitBundleID: String?
        /// The Homebrew cask, so Homebrew forgets it too.
        public var brewToken: String?

        public init(name: String, paths: [String], quitBundleID: String? = nil, brewToken: String? = nil) {
            self.name = name
            self.paths = paths
            self.quitBundleID = quitBundleID
            self.brewToken = brewToken
        }
    }

    public struct Outcome: Sendable {
        public var name: String
        /// The paths that went, as they were asked for.
        public var removed: [String] = []
        public var failed: [Trash.Refusal] = []
    }

    /// Where a batch is: the request being worked on (nil once only the
    /// shared root-owned move is left), what's happening, how far (0…1).
    public struct Step: Sendable {
        public var request: Int?
        public var text: String
        public var fraction: Double
    }

    public struct Report: Sendable {
        public var outcomes: [Outcome]
        public var moved: [Trash.Moved]
    }

    /// Removes each request's paths. `progress` gets what is happening and
    /// how far along the batch is (0…1).
    public static func remove(
        _ requests: [Request],
        prompt: String = "Lowtide needs your password to move files an installer put on your Mac to the Trash.",
        progress: @escaping @Sendable (Step) -> Void = { _ in }
    ) async -> Report {
        var outcomes = requests.map { Outcome(name: $0.name) }
        var moved: [Trash.Moved] = []
        // Root-owned paths of every request, moved together at the end.
        var admin: [(request: Int, path: String, asked: String)] = []
        let uid = getuid()
        let total = Double(max(requests.count, 1))

        for (index, request) in requests.enumerated() {
            let share = Double(index) / total * 0.85
            let (targets, refused) = Footprint.targets(request.paths)
            outcomes[index].failed += refused
            if let id = request.quitBundleID, let safe = Paths.safeID(id), AppBundles.isRunning(safe) {
                progress(Step(request: index, text: "Quitting \(request.name)", fraction: share))
                await AppBundles.quit(safe, wait: .seconds(8))
            }
            progress(Step(request: index, text: requests.count > 1 ? "\(index + 1) of \(requests.count): \(request.name)" : "Moving \(request.name) to the Trash",
                          fraction: share))
            let present = targets.filter { Trash.exists($0.path) }
            let own = present.filter { !Trash.needsAdmin($0.path, uid: uid) }
            let root = present.filter { Trash.needsAdmin($0.path, uid: uid) }
            for agent in own where agent.path.contains("/LaunchAgents/") {
                _ = try? await Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)", agent.path], timeout: .seconds(20))
            }
            for target in own {
                let trashed = await Trash.move([target.path])
                moved += trashed.moved
                if trashed.moved.isEmpty {
                    outcomes[index].failed.append(Trash.Refusal(path: target.asked, reason: Trash.refusal(target.path)))
                } else {
                    outcomes[index].removed.append(target.asked)
                }
            }
            admin += root.map { (index, $0.path, $0.asked) }
            // Homebrew forgets the cask once its app is in the Trash (its own
            // uninstall would delete the app outright, past the Trash).
            if let token = request.brewToken, CaskCatalog.validToken(token),
               request.paths.contains(where: { $0.hasSuffix(".app") }) {
                progress(Step(request: index, text: "Homebrew forgets \(request.name)", fraction: share))
                try? await Brew.cask(["uninstall", "--cask", "--force"], token: token) { _ in }
            }
        }

        if !admin.isEmpty {
            progress(Step(request: nil, text: "Moving files macOS protects", fraction: 0.88))
            let trashed = await Trash.moveAsAdmin(admin.map(\.path), prompt: prompt)
            moved += trashed.moved
            let went = Set(trashed.removed)
            let why = Dictionary(trashed.refused.map { ($0.path, $0.reason) }, uniquingKeysWith: { a, _ in a })
            for entry in admin {
                if went.contains(entry.path) {
                    outcomes[entry.request].removed.append(entry.asked)
                } else if let reason = why[entry.path] {
                    outcomes[entry.request].failed.append(Trash.Refusal(path: entry.asked, reason: reason))
                }
            }
        }

        // Removing an app (not only resetting it) also drops its Privacy
        // grants once it's gone.
        for request in requests {
            guard let id = request.quitBundleID, let safe = Paths.safeID(id),
                  let app = request.paths.first(where: { $0.hasSuffix(".app") }), !CleanupFS.exists(app)
            else { continue }
            Task.detached(priority: .background) { await PrivacyGrants.forget(safe) }
        }
        progress(Step(request: nil, text: "Done", fraction: 1))
        return Report(outcomes: outcomes, moved: moved)
    }

    /// One request, as a footprint map removes it: progress as words and
    /// how far (0…1).
    public static func remove(_ request: Request, progress: @escaping @Sendable (String, Double) -> Void) async -> Footprint.RemoveResult {
        let report = await remove([request]) { progress($0.text, $0.fraction) }
        var result = Footprint.RemoveResult()
        result.removed = report.outcomes.first?.removed ?? []
        result.failed = report.outcomes.first?.failed ?? []
        result.undo = report.moved.filter { $0.trashed != nil }
        return result
    }
}

/// The Privacy & Security grants a deleted app leaves behind.
public enum PrivacyGrants {
    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    /// `tccutil` refuses a bundle id Launch Services can't find, which is
    /// every deleted app. So a stand-in bundle with that id is registered for
    /// a moment, reset, and removed again. The reset is keyed by the id, so it
    /// clears exactly the grants the deleted app left.
    public static func forget(_ bundleID: String) async {
        guard let id = Paths.safeID(bundleID) else { return }
        // Not under a temp folder: Launch Services ignores bundles there.
        let app = Paths.cache.appending(path: "stubs/\(id).app")
        let contents = app.appending(path: "Contents")
        do {
            try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
            let info: [String: Any] = [
                "CFBundleIdentifier": id, "CFBundleName": "Lowtide stand-in",
                "CFBundlePackageType": "APPL", "CFBundleExecutable": "stub",
            ]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appending(path: "Info.plist"))
            try Data("#!/bin/sh\n".utf8).write(to: contents.appending(path: "MacOS/stub"))
        } catch { return }
        _ = try? await Shell.run(lsregister, ["-f", "-R", app.path], timeout: .seconds(30))
        // Registration lands a moment later.
        for _ in 0..<8 {
            if (try? await Shell.run("/usr/bin/tccutil", ["reset", "All", id], timeout: .seconds(10)))?.ok == true { break }
            try? await Task.sleep(for: .milliseconds(400))
        }
        _ = try? await Shell.run(lsregister, ["-u", app.path], timeout: .seconds(30))
        // Our own stand-in, never the person's files.
        try? FileManager.default.removeItem(at: app)
    }
}
