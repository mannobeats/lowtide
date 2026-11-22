import Foundation

/// An app the bar launches.
public struct LaunchableApp: Equatable, Sendable {
    public var name: String
    public var path: String
    public var bundleID: String
    /// The file name without `.app`, when it differs from the name.
    public var fileName: String
}

/// Every app on the Mac a person would open (not helpers inside other apps,
/// build outputs or the Trash). Answers from memory unless an app folder
/// changed since (an app installed or removed) or the list is five minutes old.
public actor AppIndex {
    public static let shared = AppIndex()

    private var apps: [LaunchableApp] = []
    private var scannedAt: Date = .distantPast
    private var foldersStamp: Date = .distantPast

    static let stale: TimeInterval = 5 * 60
    /// After an app folder changes, how long every opening scans again: a
    /// copy still in progress has no readable Info.plist yet.
    static let settling: TimeInterval = 60

    public func list() async -> [LaunchableApp] {
        let stamp = Self.foldersChanged()
        let now = Date()
        let isStale = now.timeIntervalSince(scannedAt) > Self.stale || stamp != foldersStamp
            || now.timeIntervalSince(stamp) < Self.settling
        if apps.isEmpty || isStale {
            apps = await Self.scan()
            scannedAt = now
            foldersStamp = stamp
        }
        return apps
    }

    static var roots: [URL] {
        [URL(fileURLWithPath: "/Applications"), Paths.home.appending(path: "Applications"), URL(fileURLWithPath: "/System/Applications")]
    }

    /// When the app folders last changed: the Applications folders and the
    /// folders one level in (Utilities, a vendor's folder). A few dozen stats.
    static func foldersChanged() -> Date {
        let fm = FileManager.default
        var latest = Date.distantPast
        func modified(_ path: String) -> Date? { (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date }
        for root in roots {
            latest = max(latest, modified(root.path) ?? .distantPast)
            for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where !name.contains(".") {
                latest = max(latest, modified(root.appending(path: name).path) ?? .distantPast)
            }
        }
        return latest
    }

    /// Not something to launch: a helper inside another app, a build output,
    /// a copy in the Trash or in a cache.
    static func launchable(_ path: String) -> Bool {
        let skip = ["/.Trash/", "/target/", "/DerivedData/", "/node_modules/", "/build/", "/Caches/", "/.build/",
                    "/Library/Application Support/"]
        let inner = path.dropLast(4)
        return !inner.contains(".app/") && !skip.contains { path.contains($0) }
    }

    /// Which of two copies to offer: the one in an Applications folder, else
    /// the shorter path (an installer image or a backup is usually deeper).
    static func better(_ a: LaunchableApp, than b: LaunchableApp) -> Bool {
        let home = { (app: LaunchableApp) in app.path.contains("/Applications/") }
        switch (home(a), home(b)) {
        case (true, false): return true
        case (false, true): return false
        default: return a.path.count < b.path.count
        }
    }

    static func appPaths() async -> [String] {
        var paths: [String] = []
        let fm = FileManager.default
        func walk(_ dir: URL, depth: Int) {
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !name.hasPrefix(".") {
                let url = dir.appending(path: name)
                if name.hasSuffix(".app") {
                    paths.append(url.path)
                } else if depth > 0 {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { walk(url, depth: depth - 1) }
                }
            }
        }
        for root in roots { walk(root, depth: 2) }
        // Spotlight can be off for a volume, so it adds to the walk rather than replacing it.
        if let out = try? await Shell.run("/usr/bin/mdfind", ["-0", "kMDItemContentType == 'com.apple.application-bundle'"],
                                          timeout: .seconds(60)) {
            paths += out.stdout.split(separator: "\0").map(String.init)
        }
        return Set(paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }.filter { $0.hasSuffix(".app") }).sorted()
    }

    static func read(_ path: String) -> LaunchableApp? {
        let url = URL(fileURLWithPath: path)
        let fileName = url.deletingPathExtension().lastPathComponent
        let info = AppBundles.read(url)
        // Finder's name (localised: "System Settings", not "System Preferences").
        let display = FileManager.default.displayName(atPath: path)
        let name = display.hasSuffix(".app") ? String(display.dropLast(4)) : display
        return LaunchableApp(name: name.isEmpty ? info?.displayName ?? info?.name ?? fileName : name,
                             path: path, bundleID: info?.bundleID ?? path, fileName: fileName)
    }

    static func scan() async -> [LaunchableApp] {
        var byID: [String: LaunchableApp] = [:]
        for path in await appPaths() where launchable(path) {
            guard let app = read(path) else { continue }
            if let kept = byID[app.bundleID], !better(app, than: kept) { continue }
            byID[app.bundleID] = app
        }
        return byID.values.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
}
