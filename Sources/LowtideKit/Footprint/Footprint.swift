import Darwin
import Foundation

/// Finds everything an app, a plug-in or a deleted app left on the Mac
/// (Apps → Installed and Add-ons, Cleanup → Leftovers).
///
/// Evidence, strongest first:
/// 1. Installer receipts: `pkgutil` knows every file a `.pkg` installed,
///    wherever it went (`/Library/Arturia/…`, sample libraries, helpers).
/// 2. Bundle identifiers, the app's own and its helpers': preferences,
///    containers, caches, saved state and launch agents are named after
///    them; commands linked into the app are found by where they point.
/// 3. Names: support folders, logs, crash reports and hidden dot-folders in
///    HOME are named after the product, with or without a version.
/// 4. Vendor: folders and group containers shared by a developer's products
///    are reported as shared and never preselected.
public enum Footprint {
    public enum Confidence: Int, Codable, Sendable, Comparable {
        /// The thing itself: the app bundle, the plug-in bundles.
        case primary
        /// Installed by the same installer package (receipt).
        case installer
        /// Named after the bundle identifier.
        case exact
        /// Named after the product.
        case likely
        /// Belongs to the vendor; other products may use it.
        case shared

        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

        /// The word the map shows next to an item.
        public var label: String? {
            switch self {
            case .primary: nil
            case .installer: "Installer"
            case .exact: "Bundle id"
            case .likely: "Name match"
            case .shared: "Shared"
            }
        }
    }

    public enum Category: String, Codable, Sendable, CaseIterable {
        case app, caches, containers, helpers, hidden, launch, logs, plugins, preferences, presets, receipts, state, support, web

        public var label: String {
            switch self {
            case .app: "Application"
            case .caches: "Caches"
            case .containers: "Containers & sandbox"
            case .helpers: "Helpers & system tools"
            case .hidden: "Hidden files"
            case .launch: "Launch agents & daemons"
            case .logs: "Logs & crash reports"
            case .plugins: "Plug-in formats"
            case .preferences: "Preferences"
            case .presets: "Presets & content"
            case .receipts: "Installer receipts"
            case .state: "Saved state"
            case .support: "Support files"
            case .web: "Web data & cookies"
            }
        }
    }

    public struct Item: Codable, Sendable, Identifiable, Hashable {
        public var id: String { path }
        public var path: String
        public var name: String
        public var category: Category
        public var confidence: Confidence
        public var reason: String
        public var bytes: Int64?
        public var isDir: Bool
        /// Owned by another user (root): removing it needs the helper or a password.
        public var needsAdmin: Bool
        /// Hidden (dot-file), so Finder would never show it.
        public var hidden: Bool

        /// Selected by default: everything but vendor data other products share.
        public var preselected: Bool { confidence != .shared }

        public init(path: String, name: String, category: Category, confidence: Confidence, reason: String,
                    bytes: Int64? = nil, isDir: Bool, needsAdmin: Bool, hidden: Bool) {
            self.path = path
            self.name = name
            self.category = category
            self.confidence = confidence
            self.reason = reason
            self.bytes = bytes
            self.isDir = isDir
            self.needsAdmin = needsAdmin
            self.hidden = hidden
        }
    }

    /// One level inside a footprint folder.
    public struct Child: Sendable, Identifiable, Hashable {
        public var id: String { path }
        public var path: String
        public var name: String
        public var isDir: Bool
        public var bytes: Int64?
    }

    /// What we know about the thing being removed.
    public struct Subject: Sendable {
        public var bundleIDs: [String] = []
        /// Bundle ids of the app's own helpers and extensions. Files named
        /// after one are the app's, but unlike `bundleIDs` it never widens to
        /// the developer (`com.electron` is every Electron app's).
        public var helperIDs: [String] = []
        public var names: [String] = []
        public var vendor: String?
        public var teamID: String?
        /// The thing itself, with its category.
        public var primary: [(path: String, category: Category)] = []
        /// Bundle-id prefixes (`com.adobe`) other installed apps also use.
        public var sharedPrefixes: Set<String> = []
        /// Receipts known to install the subject (`pkgutil --file-info`).
        public var packages: [String] = []

        public init(bundleIDs: [String] = [], helperIDs: [String] = [], names: [String] = [], vendor: String? = nil,
                    teamID: String? = nil, primary: [(path: String, category: Category)] = [],
                    sharedPrefixes: Set<String> = [], packages: [String] = []) {
            self.bundleIDs = bundleIDs
            self.helperIDs = helperIDs
            self.names = names
            self.vendor = vendor
            self.teamID = teamID
            self.primary = primary
            self.sharedPrefixes = sharedPrefixes
            self.packages = packages
        }
    }

    // MARK: - Where to look

    /// Relative to HOME. `LeftoverScanner.places` lists the ones holding
    /// bundle-id names; keep the two in step.
    static let userLocations: [(String, Category)] = [
        ("Library/Application Support", .support),
        // `Name_<uuid>.plist`: what the crash reporter remembers about the app.
        ("Library/Application Support/CrashReporter", .logs),
        ("Library/Caches", .caches),
        ("Library/Preferences", .preferences),
        ("Library/Preferences/ByHost", .preferences),
        ("Library/Containers", .containers),
        ("Library/Group Containers", .containers),
        ("Library/Application Scripts", .containers),
        ("Library/Saved Application State", .state),
        ("Library/Autosave Information", .state),
        ("Library/Logs", .logs),
        ("Library/Logs/DiagnosticReports", .logs),
        ("Library/HTTPStorages", .web),
        ("Library/WebKit", .web),
        ("Library/Cookies", .web),
        ("Library/LaunchAgents", .launch),
        ("Library/Internet Plug-Ins", .plugins),
        ("Library/Services", .plugins),
        ("Library/Audio/Presets", .presets),
        ("Library/Audio/Plug-Ins/Support", .support),
        (".config", .hidden),
        (".local/share", .hidden),
        (".cache", .caches),
    ]

    static let systemLocations: [(String, Category)] = [
        ("/Library/Application Support", .support),
        ("/Library/Caches", .caches),
        ("/Library/Preferences", .preferences),
        ("/Library/LaunchAgents", .launch),
        ("/Library/LaunchDaemons", .launch),
        ("/Library/PrivilegedHelperTools", .helpers),
        ("/Library/Logs", .logs),
        ("/Library/Logs/DiagnosticReports", .logs),
        ("/private/var/log", .logs),
        ("/usr/local/share", .support),
        ("/usr/local/etc", .support),
        ("/Library/Internet Plug-Ins", .plugins),
        ("/Library/Input Methods", .plugins),
        ("/Library/PreferencePanes", .plugins),
        ("/Library/QuickLook", .plugins),
        ("/Library/Screen Savers", .plugins),
        ("/Library/Audio/Presets", .presets),
        ("/Library/Audio/MIDI Drivers", .plugins),
        ("/Users/Shared", .support),
    ]

    /// Where an app's command-line tools are linked from, relative to HOME or absolute.
    static let commandDirs = ["/usr/local/bin", "/usr/local/sbin", ".local/bin", "bin"]

    /// Folders an app fills that carry nothing of its name, by bundle id
    /// (lowercase), relative to HOME. Offered as shared: other tools use them
    /// too, so nothing here is selected until the person says so.
    static let also: [String: [String]] = ["com.google.android.studio": ["Library/Android", ".android", ".gradle"]]

    /// Plug-in format folders, relative to a Library folder.
    public static let pluginFolders: [(folder: String, format: String)] = [
        ("Audio/Plug-Ins/Components", "AU"),
        ("Audio/Plug-Ins/VST", "VST"),
        ("Audio/Plug-Ins/VST3", "VST3"),
        ("Audio/Plug-Ins/CLAP", "CLAP"),
        ("Audio/Plug-Ins/LV2", "LV2"),
        ("Audio/Plug-Ins/MAS", "MAS"),
        ("Audio/Plug-Ins/HAL", "Driver"),
        ("Application Support/Avid/Audio/Plug-Ins", "AAX"),
    ]

    /// Names too generic to identify anything.
    static let genericNames: Set<String> = [
        "app", "application", "electron", "main", "launcher", "helper", "java", "python", "node", "run", "setup",
        "installer", "update", "updater", "plugin", "plugins", "audio", "support", "common", "shared", "data",
        "tools", "core", "cache", "caches", "logs", "config", "settings", "default", "library", "resources",
    ]

    /// A bundle id's last part that says nothing about the product.
    public static let genericProducts: Set<String> = [
        "app", "application", "agent", "beta", "canary", "client", "desktop", "dev", "helper", "launcher", "lite",
        "mac", "macos", "main", "nightly", "osx", "preview", "pro", "stable", "studio",
    ]

    /// Strips extensions that tell nothing about ownership.
    static func stem(_ name: String) -> String {
        for suffix in [".plist", ".savedState", ".binarycookies", ".log", ".ips", ".crash", ".diag", ".app", ".bundle", ".json"]
        where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    /// `needle` appears in `haystack` as a whole dotted component run.
    static func containsID(_ haystack: String, _ needle: String) -> Bool {
        guard !needle.isEmpty else { return false }
        var search = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, range: search) {
            let before = range.lowerBound > haystack.startIndex ? haystack[haystack.index(before: range.lowerBound)] : nil
            let after = range.upperBound < haystack.endIndex ? haystack[range.upperBound] : nil
            let okBefore = before.map { ".-_".contains($0) } ?? true
            let okAfter = after.map { ".-_ ".contains($0) } ?? true
            if okBefore && okAfter { return true }
            search = haystack.index(after: range.lowerBound)..<haystack.endIndex
        }
        return false
    }

    // MARK: - Matching names

    struct Matcher {
        var ids: [String]
        var helperIDs: [String]
        var names: [String]
        var vendor: String?
        var team: String?
        var prefixes: [String]
        var sharedPrefixes: Set<String>

        init(_ subject: Subject) {
            ids = subject.bundleIDs.map { $0.lowercased() }.filter { $0.split(separator: ".", omittingEmptySubsequences: false).count >= 2 }
            names = Array(Set(subject.names.map(AppBundles.alnum).filter { $0.count >= 3 && !genericNames.contains($0) })).sorted()
            prefixes = ids.compactMap(AppBundles.vendorPrefix)
            helperIDs = subject.helperIDs.map { $0.lowercased() }.filter { $0.split(separator: ".", omittingEmptySubsequences: false).count >= 3 }
            vendor = subject.vendor.map(AppBundles.alnum).flatMap { $0.count >= 3 && !genericNames.contains($0) ? $0 : nil }
            team = subject.teamID?.lowercased()
            sharedPrefixes = subject.sharedPrefixes
        }

        func classify(_ name: String, inLogs: Bool) -> (Confidence, String)? {
            let lower = name.lowercased()
            let flat = AppBundles.alnum(stem(String(name.drop { $0 == "." })))
            if let id = (ids + helperIDs).first(where: { containsID(lower, $0) }) {
                return (.exact, "named after \(id)")
            }
            if names.contains(flat) { return (.likely, "named after the product") }
            // `AndroidStudio2025.3`: the product's folder for one version.
            if names.contains(where: { flat.hasPrefix($0) && flat.count > $0.count && flat.dropFirst($0.count).allSatisfy(\.isNumber) }) {
                return (.likely, "a version of the product")
            }
            if inLogs, names.contains(where: flat.hasPrefix) {
                return (.likely, "log or crash report of the product")
            }
            // A group container is the developer's with `group.` in front.
            let bare = lower.hasPrefix("group.") ? String(lower.dropFirst(6)) : lower
            if let prefix = prefixes.first(where: { bare == $0 || bare.hasPrefix($0 + ".") }) {
                return sharedPrefixes.contains(prefix)
                    ? (.shared, "\(prefix) is shared with other installed apps")
                    : (.likely, "same developer (\(prefix))")
            }
            if let team, lower.hasPrefix(team + ".") { return (.shared, "developer group container") }
            if let vendor, flat == vendor { return (.shared, "developer folder, may hold other products") }
            return nil
        }
    }

    // MARK: - Installer receipts

    /// Receipt ids that belong to the subject: containing a bundle id, or the
    /// product name alongside the vendor (`com.Arturia.ARP2600V3.vst3`).
    static func matchingPackages(_ packages: [String], _ subject: Subject) -> [String] {
        let ids = subject.bundleIDs.map { $0.lowercased() }
        let names = subject.names.map(AppBundles.alnum).filter { $0.count >= 4 && !genericNames.contains($0) }
        let vendor = subject.vendor.map(AppBundles.alnum)
        return packages.filter { pkg in
            guard !pkg.hasPrefix("com.apple.") else { return false }
            let lower = pkg.lowercased()
            if ids.contains(where: { lower == $0 || lower.hasPrefix($0 + ".") }) { return true }
            let flat = AppBundles.alnum(pkg)
            // The name must be a whole segment run, not a substring of
            // another product ("Pro" in "ProQ3").
            let segments = pkg.split(omittingEmptySubsequences: false) { ".-_".contains($0) }.map { AppBundles.alnum(String($0)) }
            return names.contains { name in
                let run = (0..<segments.count).contains { start in
                    (start + 1...segments.count).contains { end in segments[start..<end].joined() == name }
                }
                return run && (vendor.map { flat.contains($0) } ?? true)
            }
        }
    }

    /// Last segments of receipt ids that name a format or a resource bundle.
    static let formatWords = ["vst3", "vst2", "vst", "aax", "au", "clap", "component", "resources", "images", "samples", "nks", "pkg"]

    /// The product a receipt belongs to, format words removed, lowercase:
    /// `com.Arturia.ARP2600V3.vst3` and `com.synchroarts.RePitchVST3` give
    /// `com.arturia.arp2600v3` and `com.synchroarts.repitch`. Nil when the
    /// id names no format, or only a vendor prefix would be left.
    static func receiptFamily(_ pkg: String) -> String? {
        var segments = pkg.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let full = segments.count
        while let last = segments.last, formatWords.contains(last.lowercased()) { segments.removeLast() }
        if segments.count == full {
            // The format glued to the name (`RePitchVST3`, `Kontakt_AU`). It
            // must start a word, so `Plateau` keeps its `au`.
            guard let last = segments.popLast() else { return nil }
            var found: String?
            for word in formatWords where last.count > word.count || last.count == word.count {
                let stemPart = String(last.dropLast(word.count))
                let suffix = String(last.suffix(word.count))
                let startsWord = suffix.first?.isUppercase == true || stemPart.last.map { "_- ".contains($0) } == true
                if suffix.lowercased() == word && startsWord {
                    found = String(stemPart.reversed().drop { "_- ".contains($0) }.reversed())
                    break
                }
            }
            guard let stemPart = found, !stemPart.isEmpty else { return nil }
            segments.append(stemPart)
        }
        return segments.count >= 3 ? segments.joined(separator: ".").lowercased() : nil
    }

    /// A known receipt and the other receipts of the same product (`….vst3`,
    /// `….au`, `….resources`), never everything under the vendor's prefix.
    static func receiptSiblings(_ packages: [String], known: String) -> [String] {
        let family = receiptFamily(known)
        return packages.filter { pkg in
            pkg == known || family.map { receiptFamily(pkg) == $0 || pkg.lowercased().hasPrefix($0 + ".") } == true
        }
    }

    /// Every receipt on the Mac, read once every five minutes.
    actor PackageList {
        static let shared = PackageList()
        private var cached: (Date, [String])?
        func all() async -> [String] {
            if let (at, list) = cached, Date.now.timeIntervalSince(at) < 300 { return list }
            let list = (try? await Shell.run("/usr/sbin/pkgutil", ["--pkgs"], timeout: .seconds(60)))?
                .stdout.split(separator: "\n").map(String.init) ?? []
            cached = (.now, list)
            return list
        }
    }

    static func packagePaths(_ pkg: String) async -> [String] {
        async let info = try? Shell.run("/usr/sbin/pkgutil", ["--pkg-info", pkg], timeout: .seconds(60))
        async let files = try? Shell.run("/usr/sbin/pkgutil", ["--files", pkg], timeout: .seconds(120))
        let infoText = await info?.stdout ?? ""
        func field(_ key: String) -> String? {
            infoText.split(separator: "\n").lazy.compactMap { $0.hasPrefix(key) ? $0.dropFirst(key.count).trimmingCharacters(in: .whitespaces) : nil }.first
        }
        let volume = field("volume:") ?? "/"
        let base = (volume as NSString).appendingPathComponent(field("location:") ?? "")
        return await files?.stdout.split(separator: "\n").map { (base as NSString).appendingPathComponent(String($0)) } ?? []
    }

    /// The receipts that installed a file (`pkgutil --file-info`), Apple's left out.
    public static func packages(of path: String) async -> [String] {
        guard let out = try? await Shell.run("/usr/sbin/pkgutil", ["--file-info", path], timeout: .seconds(30)) else { return [] }
        return out.stdout.split(separator: "\n")
            .compactMap { $0.hasPrefix("pkgid:") ? $0.dropFirst(6).trimmingCharacters(in: .whitespaces) : nil }
            .filter { !$0.hasPrefix("com.apple.") }
    }

    /// The fewest paths that cover what a package installed: a folder counts
    /// as the package's own only when nothing else lives in it.
    static func packageRoots(_ paths: [String], names: [String], home: String = Footprint.home) -> [String] {
        let set = Set(paths)
        let product = Set(names.map(AppBundles.alnum).filter { $0.count >= 4 && !genericNames.contains($0) })
        let protectedSet = protectedPaths(home: home)
        var memo: [String: Bool] = [:]
        // A folder named after the product is the product's, including files
        // it created later (logs, user presets).
        func named(_ dir: String) -> Bool { product.contains(AppBundles.alnum((dir as NSString).lastPathComponent)) }
        func owned(_ dir: String) -> Bool {
            if let known = memo[dir] { return known }
            var result = set.contains(dir) && !protectedSet.contains(dir)
            if result, !named(dir) {
                if let names = try? FileManager.default.contentsOfDirectory(atPath: dir) {
                    result = names.allSatisfy { name in
                        let child = dir + "/" + name
                        return set.contains(child) && (!CleanupFS.isDir(child) || owned(child))
                    }
                } else {
                    result = false
                }
            }
            memo[dir] = result
            return result
        }
        var roots: [String] = []
        for path in paths.sorted(by: { components($0) < components($1) }) {
            if roots.contains(where: { CleanupFS.isInside(path, $0) }) || !CleanupFS.exists(path) { continue }
            let parent = CleanupFS.parent(path)
            if parent != path, owned(parent) { continue }
            if !CleanupFS.isFolder(path) || owned(path) { roots.append(path) }
        }
        return roots
    }

    // MARK: - Safety

    /// HOME as the disk spells it.
    public static var home: String { CleanupFS.home }

    /// Folders that must never be removed themselves: system roots, every
    /// location searched, and the plug-in format folders.
    static func protectedPaths(home: String) -> Set<String> {
        var set: Set<String> = [
            "/", "/Applications", "/Library", "/System", "/Users", "/usr", "/usr/local", "/usr/local/bin", "/usr/local/lib",
            "/private", "/private/var", "/private/var/db", "/private/var/db/receipts", "/opt", "/opt/homebrew", "/Volumes",
            "/Library/Audio", "/Library/Audio/Plug-Ins", "/Library/Frameworks", "/Library/Extensions", "/Library/Fonts",
            "/Library/Keychains", "/Library/Security", "/Library/Apple", "/Library/Developer",
            "/Library/Application Support/Avid", "/Library/Application Support/Avid/Audio",
        ]
        set.insert(home)
        for dir in ["Library", "Applications", "Documents", "Desktop", "Downloads", "Library/Audio", "Library/Audio/Plug-Ins"] {
            set.insert(CleanupFS.join(home, dir))
        }
        for (relative, _) in userLocations { set.insert(CleanupFS.join(home, relative)) }
        for (absolute, _) in systemLocations { set.insert(absolute) }
        for dir in commandDirs { set.insert(dir.hasPrefix("/") ? dir : CleanupFS.join(home, dir)) }
        for (folder, _) in pluginFolders {
            set.insert(CleanupFS.join(home, "Library/" + folder))
            set.insert("/Library/" + folder)
        }
        return set
    }

    /// Only paths below these can be removed, and never a protected folder.
    public static func removable(_ path: String, home: String = Footprint.home) -> Bool {
        guard path.hasPrefix("/"), !protectedPaths(home: home).contains(path),
              !path.split(separator: "/").contains("..")
        else { return false }
        if ["/System", "/Library/Apple", "/usr/bin"].contains(where: { CleanupFS.isInside(path, $0) }) { return false }
        if CleanupFS.parent(path) == home, CleanupFS.name(path).hasPrefix(".") { return true }
        let roots = [
            "Library", "Applications", ".config", ".local/share", ".cache", ".local/bin", "bin",
        ].map { CleanupFS.join(home, $0) } + [
            "/Applications", "/Library", "/private/var/db/receipts", "/private/var/log", "/usr/local", "/Users/Shared",
            "/private/var/folders",
        ]
        return roots.contains { CleanupFS.isInside(path, $0) && path != $0 }
    }

    /// The path as the disk spells it, so the guards compare what will really
    /// be touched: APFS matches `/library/application support` to
    /// `/Library/Application Support`. A link itself is kept, not followed.
    public static func onDisk(_ path: String) -> String? {
        guard path.hasPrefix("/"), CleanupFS.exists(path) else { return nil }
        if !CleanupFS.isLink(path) { return CleanupFS.realPath(path) }
        return CleanupFS.realPath(CleanupFS.parent(path)).map { CleanupFS.join($0, CleanupFS.name(path)) }
    }

    static func components(_ path: String) -> Int { path.split(separator: "/").count }
}
