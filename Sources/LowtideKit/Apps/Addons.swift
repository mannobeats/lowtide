import AppKit
import Darwin
import Foundation

/// What extends apps, browsers and macOS without being an app.
public struct Addon: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable, CaseIterable {
        case browser, safari, widget, screensaver, prefpane, internet, quicklook, spotlight
    }

    /// Its path, which is unique.
    public var id: String
    public var kind: Kind
    public var name: String
    /// Where it comes from: the browser and profile, the folder, the app it ships in.
    public var source: String
    public var version: String?
    public var bytes: Int64?
    public var modified: Date?
    /// The extension's own icon file (browser extensions).
    public var icon: String?
    /// The app it ships inside (widgets, Safari extensions).
    public var app: String?
    /// False when it ships inside an app and goes when the app does.
    public var removable: Bool
    public var needsAdmin: Bool
    /// The browser (bundle id, name) to close before removing it.
    public var browser: Browser?

    public struct Browser: Sendable, Hashable {
        public var bundleIDs: [String]
        public var name: String
    }
}

/// Browser extensions, screen savers, System Settings panes, internet
/// plug-ins, Quick Look and Spotlight plug-ins, and the widgets and Safari
/// extensions apps ship inside them.
public enum Addons {
    /// Bundles in a Library folder, user and system.
    static let bundleFolders: [(Addon.Kind, String, [String])] = [
        (.screensaver, "Screen Savers", ["saver", "qtz"]),
        (.prefpane, "PreferencePanes", ["prefpane"]),
        (.internet, "Internet Plug-Ins", ["plugin", "webplugin"]),
        (.quicklook, "QuickLook", ["qlgenerator"]),
        (.spotlight, "Spotlight", ["mdimporter"]),
    ]

    /// Chromium browsers: name, folder in Application Support, bundle ids.
    static let chromium: [(String, String, [String])] = [
        ("Google Chrome", "Google/Chrome", ["com.google.Chrome"]),
        ("Chrome Beta", "Google/Chrome Beta", ["com.google.Chrome.beta"]),
        ("Chrome Canary", "Google/Chrome Canary", ["com.google.Chrome.canary"]),
        ("Brave", "BraveSoftware/Brave-Browser", ["com.brave.Browser"]),
        ("Microsoft Edge", "Microsoft Edge", ["com.microsoft.edgemac"]),
        ("Arc", "Arc/User Data", ["company.thebrowser.Browser"]),
        ("Vivaldi", "Vivaldi", ["com.vivaldi.Vivaldi"]),
        ("Opera", "com.operasoftware.Opera", ["com.operasoftware.Opera"]),
        ("Chromium", "Chromium", ["org.chromium.Chromium"]),
        ("Dia", "Dia/User Data", ["company.thebrowser.dia"]),
    ]

    static func make(_ kind: Addon.Kind, _ path: String, _ name: String, _ source: String) -> Addon {
        var info = stat()
        let ok = lstat(path, &info) == 0
        return Addon(
            id: path, kind: kind, name: name, source: source,
            modified: ok ? Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)) : nil,
            removable: true, needsAdmin: ok && info.st_uid != getuid()
        )
    }

    static func hasExtension(_ path: String, _ extensions: [String]) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return extensions.contains(ext)
    }

    static func json(_ path: String) -> [String: Any]? {
        (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    static func entries(_ dir: String) -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] }

    static func bundles(home: String, into out: inout [Addon]) {
        for (library, source) in [(home + "/Library", "For you"), ("/Library", "For all users")] {
            for (kind, folder, extensions) in bundleFolders {
                let dir = library + "/" + folder
                for name in entries(dir) {
                    let path = dir + "/" + name
                    guard hasExtension(path, extensions) else { continue }
                    let info = AppBundles.read(URL(fileURLWithPath: path))
                    var found = make(kind, path, info?.displayName ?? info?.name ?? (name as NSString).deletingPathExtension, source)
                    found.version = info?.version
                    out.append(found)
                }
            }
        }
    }

    /// `__MSG_appName__` from the extension's default locale.
    static func localized(_ name: String, version: String, manifest: [String: Any]) -> String {
        guard name.hasPrefix("__MSG_"), name.hasSuffix("__"), name.count > 8 else { return name }
        let key = String(name.dropFirst(6).dropLast(2))
        let locale = manifest["default_locale"] as? String ?? "en"
        guard let messages = json("\(version)/_locales/\(locale)/messages.json") else { return name }
        for (k, value) in messages where k.caseInsensitiveCompare(key) == .orderedSame {
            if let message = (value as? [String: Any])?["message"] as? String { return message }
        }
        return name
    }

    /// The largest icon the manifest lists.
    static func manifestIcon(version: String, manifest: [String: Any]) -> String? {
        guard let icons = manifest["icons"] as? [String: Any] else { return nil }
        let best = icons.compactMap { size, file -> (Int, String)? in
            guard let size = Int(size), let file = file as? String else { return nil }
            return (size, file)
        }.max { $0.0 < $1.0 }
        guard let file = best?.1 else { return nil }
        let path = version + "/" + file.drop { $0 == "/" }
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    static func chromium(home: String, into out: inout [Addon]) {
        let support = home + "/Library/Application Support"
        for (browser, folder, ids) in chromium {
            let root = support + "/" + folder
            let state = json(root + "/Local State")
            let profiles = entries(root).filter { CleanupFS.isFolder("\(root)/\($0)/Extensions") }.sorted()
            for dir in profiles {
                let infoCache = ((state?["profile"] as? [String: Any])?["info_cache"] as? [String: Any])?[dir] as? [String: Any]
                let person = infoCache?["name"] as? String ?? dir
                let source = profiles.count > 1 ? "\(browser) · \(person)" : browser
                let extensions = "\(root)/\(dir)/Extensions"
                for ext in entries(extensions) {
                    let path = extensions + "/" + ext
                    let version = entries(path).map { path + "/" + $0 }
                        .filter { FileManager.default.fileExists(atPath: $0 + "/manifest.json") }
                        .max { modified($0) < modified($1) }
                    guard let version, let manifest = json(version + "/manifest.json") else { continue }
                    var found = make(.browser, path, localized(manifest["name"] as? String ?? "Extension", version: version, manifest: manifest), source)
                    found.version = manifest["version"] as? String
                    found.icon = manifestIcon(version: version, manifest: manifest)
                    found.browser = Addon.Browser(bundleIDs: ids, name: browser)
                    out.append(found)
                }
            }
        }
    }

    static func modified(_ path: String) -> Date {
        var info = stat()
        return lstat(path, &info) == 0 ? Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)) : .distantPast
    }

    static func firefox(home: String, into out: inout [Addon]) {
        let profiles = home + "/Library/Application Support/Firefox/Profiles"
        for dir in entries(profiles) {
            guard let list = json("\(profiles)/\(dir)/extensions.json"), let addons = list["addons"] as? [[String: Any]] else { continue }
            // `x1y2z3.default-release`: the part after the random prefix.
            let person = dir.split(separator: ".", maxSplits: 1).dropFirst().first.map(String.init) ?? dir
            for entry in addons {
                // signedState 3+ is Mozilla's own (New Tab updates itself this
                // way); removing it breaks Firefox rather than an add-on.
                guard entry["location"] as? String == "app-profile",
                      ((entry["signedState"] as? NSNumber)?.intValue ?? 0) < 3,
                      let path = entry["path"] as? String, CleanupFS.exists(path)
                else { continue }
                let name = (entry["defaultLocale"] as? [String: Any])?["name"] as? String ?? "Add-on"
                var found = make(.browser, path, name, "Firefox · \(person)")
                found.version = entry["version"] as? String
                found.browser = Addon.Browser(bundleIDs: ["org.mozilla.firefox"], name: "Firefox")
                out.append(found)
            }
        }
    }

    /// `pluginkit -mAv` lines: the extension's path is the last tab field.
    static func registeredPaths(_ output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            guard let path = line.split(separator: "\t").last?.trimmingCharacters(in: .whitespaces),
                  path.hasPrefix("/"), !path.hasPrefix("/System") else { return nil }
            return path
        }
    }

    /// Extensions an app registers with macOS, one entry per app.
    static func registered(_ kind: Addon.Kind, points: [String], home: String, into out: inout [Addon]) async {
        var seen = Set<String>()
        for point in points {
            guard let result = try? await Shell.run("/usr/bin/pluginkit", ["-m", "-A", "-v", "-p", point], timeout: .seconds(30)) else { continue }
            for path in registeredPaths(result.stdout) {
                guard let end = path.range(of: ".app/") else { continue }
                let app = String(path[..<end.lowerBound]) + ".app"
                guard seen.insert(app).inserted else { continue }
                var found = make(kind, path, ((app as NSString).lastPathComponent as NSString).deletingPathExtension, Paths.tilde(app))
                found.removable = false
                found.app = app
                out.append(found)
            }
        }
    }

    /// Every add-on on the Mac, measured.
    public static func scan() async -> [Addon] {
        let home = Footprint.home
        var found = await Footprint.offMain { () -> [Addon] in
            var out: [Addon] = []
            chromium(home: home, into: &out)
            firefox(home: home, into: &out)
            bundles(home: home, into: &out)
            return out
        }
        await registered(.safari, points: ["com.apple.Safari.extension", "com.apple.Safari.web-extension"], home: home, into: &found)
        await registered(.widget, points: ["com.apple.widgetkit-extension"], home: home, into: &found)
        let measurable = found.indices.filter { found[$0].removable }
        let sizes = await DiskSize.measure(measurable.map { found[$0].id })
        for (index, size) in zip(measurable, sizes) { found[index].bytes = size }
        return found
    }

    /// Moves add-ons to the Trash: browser extensions only once their browser
    /// is closed (it would write them back), system-wide ones with one
    /// password prompt for all of them.
    public static func remove(_ addons: [Addon]) async -> (removed: [String], failed: [Trash.Refusal], moved: [Trash.Moved]) {
        var failed: [Trash.Refusal] = []
        var paths: [String] = []
        for addon in addons {
            if !addon.removable {
                failed.append(.init(path: addon.id, reason: "Ships inside its app; remove the app"))
            } else if let browser = addon.browser, browser.bundleIDs.contains(where: AppBundles.isRunning) {
                failed.append(.init(path: addon.id, reason: "Quit \(browser.name) first"))
            } else {
                paths.append(addon.id)
            }
        }
        guard !paths.isEmpty else { return ([], failed, []) }
        let report = await AppRemover.remove([AppRemover.Request(name: "add-ons", paths: paths)])
        let outcome = report.outcomes.first
        return (outcome?.removed ?? [], failed + (outcome?.failed ?? []), report.moved)
    }
}
