import Foundation

/// Files an app left after it was deleted: data named after a bundle id
/// no app, helper or launch job on the Mac still has, and folders in
/// `~/Library/Application Support` named after a product nothing on the Mac
/// is called any more (most Electron apps name theirs so).
public struct Leftover: Sendable, Identifiable, Hashable {
    /// The bundle id the files are named after, or `~/Library/Application
    /// Support/<name>` for one found by name.
    public let id: String
    public let name: String
    public let paths: [String]
    public var bytes: Int64?
    /// Last change to any of the files.
    public let modified: Date?
    /// Found by its folder's name alone (no bundle id): weaker evidence.
    public let byName: Bool

    public init(id: String, name: String, paths: [String], bytes: Int64? = nil, modified: Date?, byName: Bool) {
        self.id = id
        self.name = name
        self.paths = paths
        self.bytes = bytes
        self.modified = modified
        self.byName = byName
    }
}

public enum LeftoverScanner {
    /// Where apps keep data named after their bundle id, with the footprint
    /// category it files under (the folders of `Footprint.userLocations`
    /// that hold bundle-id names; keep the two in step).
    static let places: [(String, Footprint.Category)] = [
        ("Library/Preferences", .preferences), ("Library/Containers", .containers),
        ("Library/Application Support", .support), ("Library/Application Scripts", .containers),
        ("Library/Caches", .caches), ("Library/HTTPStorages", .web), ("Library/WebKit", .web),
        ("Library/Cookies", .web), ("Library/Saved Application State", .state), ("Library/Logs", .logs),
    ]

    /// Libraries apps embed and command-line tools, which write under their
    /// own id: no app of that name ever existed.
    static let sdks = [
        "com.amplitude", "com.telemetrydeck", "dev.biomejs", "dev.reactnative", "main.kts", "org.cups", "org.graalvm",
        "org.python", "org.swift", "ort.pyke", "com.bugsnag", "com.crashlytics", "com.datadoghq", "com.electron",
        "com.firebase", "com.github.electron", "com.google.gmp", "com.hackemist", "com.juce", "com.mixpanel",
        "com.plausiblelabs", "com.qtproject", "com.revenuecat", "com.segment", "io.sentry", "org.sparkle-project",
    ]

    /// Last parts of a bundle id that say nothing about the product.
    public static let generic: Set<String> = [
        "app", "application", "agent", "beta", "canary", "client", "desktop", "dev", "helper", "launcher", "lite",
        "mac", "macos", "main", "nightly", "osx", "preview", "pro", "stable", "studio",
    ]

    /// Apple's own folders in Application Support that no framework or
    /// launch job is named after, and runtimes other apps embed.
    static let notProducts = [
        "addressbook", "animoji", "appexit", "appstore", "apple", "caches", "cef", "callhistorydb",
        "callhistorytransactions", "clouddocs", "crashreporter", "diskimages", "dock", "facetime", "fileprovider",
        "icloud", "instruments", "knowledge", "lifecycle", "mobilesync", "quicklook", "sesstorage", "summaryevents",
        "syncservices",
    ]

    /// Top-level id parts that name no product.
    static let tlds: Set<String> = ["com", "org", "net", "io", "dev", "app", "co", "ai", "me", "us", "uk", "de", "fr", "jp", "tv"]

    /// Where command-line tools live: a tool's own support folder (`ngrok`)
    /// isn't a leftover while the tool is installed.
    static let toolDirs = [
        "/opt/homebrew/bin", "/opt/homebrew/Cellar", "/opt/homebrew/Caskroom", "/opt/homebrew/lib/node_modules",
        "/usr/local/bin", "/usr/local/Cellar", "/usr/local/Caskroom", "/usr/local/lib/node_modules", "/usr/bin",
        "/usr/sbin", "/usr/libexec", "/System/Library/Frameworks", "/System/Library/PrivateFrameworks",
        "/System/Library/CoreServices", "/System/Library/LaunchAgents", "/System/Library/LaunchDaemons",
    ]
    static let homeToolDirs = [".local/bin", ".cargo/bin", "go/bin", ".bun/bin", ".deno/bin", "bin", ".npm-global/lib/node_modules"]

    /// Words in folder names that say nothing about whose folder it is.
    static let filler: Set<String> = ["app", "apps", "audio", "data", "desktop", "electron", "fx", "helper", "mac",
                                      "plugin", "plugins", "pro", "shared", "studio", "the"]

    /// Untouched this long before a folder counts as left behind: whatever
    /// still writes to it is in use, named or not.
    static let idle: TimeInterval = 7 * 86_400

    // MARK: Rules

    /// `com.foo.Bar` from a file or folder name, if it's a third-party id.
    static func bundleID(_ name: String) -> String? {
        var id = name
        for suffix in [".plist", ".savedState", ".binarycookies"] where name.hasSuffix(suffix) {
            id = String(name.dropLast(suffix.count))
            break
        }
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, let tld = parts.first, (2...4).contains(tld.count),
              tld.allSatisfy({ $0.isASCII && $0.isLowercase }),
              parts.allSatisfy({ part in !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") } }),
              !id.lowercased().hasPrefix("com.apple") else { return nil }
        return id
    }

    /// Still belongs to something installed: the same id, a part of one
    /// (`com.foo.app.helper`), the root of one, anything of a vendor that
    /// still has something installed, or an embedded library's own id.
    /// Whole vendors count as installed, so a deleted app whose developer
    /// has another installed isn't listed.
    static func covered(_ id: String, installed: Set<String>, prefixes: Set<String>) -> Bool {
        let id = id.lowercased()
        let parts = id.split(separator: ".").map(String.init)
        let vendor = parts.prefix(2).joined(separator: ".")
        return installed.contains(id) || prefixes.contains(id) || prefixes.contains(vendor) || installed.contains(vendor)
            || (2..<max(2, parts.count)).contains { installed.contains(parts[..<$0].joined(separator: ".")) }
            || sdks.contains { id == $0 || id.hasPrefix($0 + ".") }
    }

    /// A readable name: the product part of the id, unless it's generic.
    static func name(of id: String) -> String {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let part = parts.reversed().first { !generic.contains($0.lowercased()) && !$0.allSatisfy(\.isNumber) } ?? parts.last ?? id
        guard let first = part.first else { return "" }
        return first.uppercased() + part.dropFirst()
    }

    /// The words of a name, lowercased: split at anything not a letter or
    /// digit and where camel case turns, without the ones that tell nothing.
    static func words(_ name: String) -> [String] {
        var out: [String] = []
        var word = ""
        var previousLower = false
        for c in name {
            let alnum = c.isASCII && (c.isLetter || c.isNumber)
            let boundary = !alnum || (previousLower && c.isUppercase)
            if boundary, !word.isEmpty {
                out.append(word)
                word = ""
            }
            if alnum { word.append(Character(c.lowercased())) }
            previousLower = c.isASCII && (c.isLowercase || c.isNumber)
        }
        out.append(word)
        return out.filter { $0.count >= 3 && !filler.contains($0) }
    }

    /// Names still claimed on the Mac, folded with `alnum`.
    struct Claims {
        /// Apps, plug-ins and their vendors, running programs.
        var products: Set<String>
        /// Their words: a folder word that starts one claims the folder.
        var productWords: Set<String>
        /// Parts of installed ids, tools, Apple's frameworks and jobs.
        var names: Set<String>
    }

    /// Something on the Mac answers to this folder name: the same name; one
    /// starts with the other (`pismo-windows` and Pismo); it ends with a
    /// product (`RME TotalMix FX`); one of its words is a product
    /// (`ssa_vsx_plugin`); or it starts with an embedded library's name.
    static func isClaimed(_ name: String, flat: String, _ claims: Claims) -> Bool {
        let prefixed = claims.products.union(claims.names).contains { claim in
            let (short, long) = claim.count < flat.count ? (claim, flat) : (flat, claim)
            return claim == flat || (short.count >= 4 && long.hasPrefix(short))
        }
        if prefixed { return true }
        if claims.products.contains(where: { $0.count >= 5 && !filler.contains($0) && flat.hasSuffix($0) }) { return true }
        return words(name).contains { word in
            claims.products.contains(word) || (word.count >= 5 && claims.productWords.contains { $0.hasPrefix(word) })
        }
    }

    // MARK: What's on the Mac

    /// What's still installed, lowercased: every app's id (helpers inside
    /// included), every plug-in and launch job; and every app's names.
    static func installed(home: String) async -> (ids: Set<String>, names: Set<String>) {
        var ids = Set(InstalledBundles.plugins().compactMap { $0.bundleID?.lowercased() })
        var names: Set<String> = []
        // As broad as possible: an app missed here makes its data look orphaned.
        for bundle in await InstalledBundles.appPaths(everywhere: true) {
            names.insert(((bundle as NSString).lastPathComponent as NSString).deletingPathExtension)
            if let info = AppBundles.read(path: bundle) {
                names.formUnion([info.name, info.displayName, info.executable].compactMap { $0 })
                if let id = info.bundleID { ids.insert(id.lowercased()) }
            }
            // Login items and helpers carry ids of their own.
            for nested in ["Contents/Library/LoginItems", "Contents/Helpers", "Contents/PlugIns"] {
                for name in CleanupFS.names(CleanupFS.join(bundle, nested)) {
                    if let id = AppBundles.read(path: CleanupFS.join(CleanupFS.join(bundle, nested), name))?.bundleID {
                        ids.insert(id.lowercased())
                    }
                }
            }
        }
        // App extensions macOS has registered, wherever they sit inside an
        // app (an FSKit module deep in pCloud Drive's Resources owns its
        // container, so it is not a leftover).
        for (id, path) in registeredExtensions(await pluginkit()) where CleanupFS.exists(path) {
            ids.insert(id.lowercased())
        }
        for dir in [CleanupFS.join(home, "Library/LaunchAgents"), "/Library/LaunchAgents", "/Library/LaunchDaemons",
                    "/Library/PrivilegedHelperTools"] {
            for name in CleanupFS.names(dir) {
                ids.insert((name.hasSuffix(".plist") ? String(name.dropLast(6)) : name).lowercased())
            }
        }
        return (ids, names)
    }

    static func claims(ids: Set<String>, appNames: Set<String>, home: String) async -> Claims {
        var products: Set<String> = []
        var productWords: Set<String> = []
        let plugins = InstalledBundles.plugins()
        for name in appNames.union(plugins.flatMap { [$0.stem] + ($0.vendor.map { [$0] } ?? []) }) {
            products.insert(AppBundles.alnum(name))
            productWords.formUnion(words(name))
        }
        // Whatever runs now (a tool inside another app, a CLI) owns its folder.
        for command in await runningCommands() {
            products.insert(AppBundles.alnum(CleanupFS.name(command)))
        }
        products = products.filter { $0.count >= 3 }
        var names: Set<String> = []
        // What installers registered (`com.native-instruments.Session
        // Guitarist - Electric Vintage.plist` for a library with no app).
        for dir in [CleanupFS.join(home, "Library/Preferences"), "/Library/Preferences"] {
            for name in CleanupFS.names(dir) where !name.hasPrefix("com.apple.") {
                let parts = (name.hasSuffix(".plist") ? String(name.dropLast(6)) : name).split(separator: ".", omittingEmptySubsequences: false)
                if parts.count >= 3 { names.insert(AppBundles.alnum(parts[2...].joined(separator: "."))) }
            }
        }
        for id in ids {
            for part in id.split(separator: ".").map(String.init) where !tlds.contains(part) {
                // `u-he` whole and in pieces.
                names.insert(AppBundles.alnum(part))
                names.formUnion(part.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { AppBundles.alnum(String($0)) })
            }
            names.insert(AppBundles.alnum(id))
        }
        for dir in toolDirs + homeToolDirs.map({ CleanupFS.join(home, $0) }) {
            for entry in CleanupFS.names(dir) {
                let first = entry.split(separator: ".").first { !tlds.contains(String($0)) }.map(String.init) ?? entry
                names.insert(AppBundles.alnum(first))
                // `com.apple.familycircled.plist`: the job's own name.
                if entry.hasSuffix(".plist"), let last = entry.dropLast(6).split(separator: ".").last {
                    names.insert(AppBundles.alnum(String(last)))
                }
            }
        }
        names.formUnion(notProducts)
        names.formUnion(sdks.compactMap { $0.split(separator: ".").dropFirst().first.map { AppBundles.alnum(String($0)) } })
        return Claims(products: products, productWords: productWords, names: names.filter { $0.count >= 2 })
    }

    /// `pluginkit -mAv` lines: `+    com.x.ext(1.0)\t<uuid>\t<date>\t/path/X.appex`.
    static func registeredExtensions(_ text: String) -> [(id: String, path: String)] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t")
            guard fields.count >= 2, let path = fields.last?.trimmingCharacters(in: .whitespaces), path.hasPrefix("/") else { return nil }
            let head = fields[0].trimmingCharacters(in: CharacterSet(charactersIn: "+-!= ").union(.whitespaces))
            let id = head.split(separator: "(").first.map(String.init) ?? head
            return id.isEmpty ? nil : (id, path)
        }
    }

    private static func pluginkit() async -> String {
        (try? await Shell.run("/usr/bin/pluginkit", ["-mAv"], timeout: .seconds(60)))?.stdout ?? ""
    }

    private static func runningCommands() async -> [String] {
        let out = (try? await Shell.run("/bin/ps", ["-axo", "comm="], timeout: .seconds(30)))?.stdout ?? ""
        return out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The newest change inside `path`, a few levels down: a folder's own
    /// time only moves when its top level does. 200 entries a level, so a
    /// huge cache is sampled.
    static func newest(_ path: String, depth: Int) -> Date? {
        var best = CleanupFS.modified(path)
        guard depth > 0 else { return best }
        for name in CleanupFS.names(path).prefix(200) {
            let child = CleanupFS.join(path, name)
            let inner = CleanupFS.isDir(child) ? newest(child, depth: depth - 1) : CleanupFS.modified(child)
            if let inner, best.map({ inner > $0 }) ?? true { best = inner }
        }
        return best
    }

    /// Folders in Application Support named after a product nothing on the
    /// Mac is called any more, untouched for a week.
    static func unclaimedFolders(_ claims: Claims, home: String, now: Date = Date()) -> [Leftover] {
        let dir = CleanupFS.join(home, "Library/Application Support")
        var found: [Leftover] = []
        for name in CleanupFS.names(dir) {
            let flat = AppBundles.alnum(name)
            let hashed = flat.count >= 16 && flat.allSatisfy(\.isHexDigit)
            let path = CleanupFS.join(dir, name)
            if name.hasPrefix(".") || name.lowercased().hasPrefix("com.apple") || bundleID(name) != nil || flat.count < 3
                || hashed || !CleanupFS.isDir(path) || isClaimed(name, flat: flat, claims) { continue }
            let changed = newest(path, depth: 3)
            if let changed, changed.addingTimeInterval(idle) > now { continue }
            found.append(Leftover(id: "~/Library/Application Support/\(name)", name: name, paths: [path],
                                  modified: changed, byName: true))
        }
        return found
    }

    /// Groups the orphaned names by id, folding `com.foo.app` into
    /// `com.foo` when both are there. Returns the groups and each path's
    /// footprint category.
    static func scanIDs(installed: Set<String>, home: String) -> ([Leftover], [String: Footprint.Category]) {
        let prefixes = Set(installed.flatMap { id -> [String] in
            let parts = id.split(separator: ".")
            return parts.count > 2 ? (2..<parts.count).map { parts[..<$0].joined(separator: ".") } : []
        })
        var found: [String: (id: String, paths: [String])] = [:]
        var categories: [String: Footprint.Category] = [:]
        for (place, category) in places {
            let dir = CleanupFS.join(home, place)
            for name in CleanupFS.names(dir) {
                guard let id = bundleID(name), !covered(id, installed: installed, prefixes: prefixes) else { continue }
                let path = CleanupFS.join(dir, name)
                categories[path] = category
                found[id.lowercased(), default: (id, [])].paths.append(path)
            }
        }
        var groups: [String: (id: String, paths: [String])] = [:]
        for key in found.keys.sorted() {
            let parts = key.split(separator: ".")
            let root = (2..<max(2, parts.count)).map { parts[..<$0].joined(separator: ".") }.first { found[$0] != nil } ?? key
            let entry = found[key]!
            groups[root, default: (found[root]?.id ?? entry.id, [])].paths += entry.paths
        }
        let leftovers = groups.keys.sorted().map { key -> Leftover in
            let group = groups[key]!
            return Leftover(id: group.id, name: name(of: group.id), paths: group.paths,
                            modified: group.paths.compactMap(CleanupFS.modified).max(), byName: false)
        }
        return (leftovers, categories)
    }

    // MARK: Scanning

    /// What a scan knew, for opening one leftover in the footprint map.
    public struct Context: Sendable {
        public var leftovers: [Leftover] = []
        var categories: [String: Footprint.Category] = [:]
        /// Vendor prefixes (`com.adobe`) installed apps still use.
        var vendors: Set<String> = []

        public init() {}

        init(leftovers: [Leftover], categories: [String: Footprint.Category], vendors: Set<String>) {
            self.leftovers = leftovers
            self.categories = categories
            self.vendors = vendors
        }
    }

    /// Every group of files left by deleted apps, not measured yet.
    public static func scan() async -> Context {
        await Task.detached(priority: .utility) {
            let home = CleanupFS.home
            let (ids, names) = await installed(home: home)
            var (leftovers, categories) = scanIDs(installed: ids, home: home)
            leftovers += unclaimedFolders(await claims(ids: ids, appNames: names, home: home), home: home)
            for leftover in leftovers where leftover.byName {
                for path in leftover.paths { categories[path] = .support }
            }
            return Context(leftovers: leftovers, categories: categories,
                           vendors: Set(ids.compactMap(AppBundles.vendorPrefix)))
        }.value
    }

    /// The paths of a leftover that can be measured at launch. Reading
    /// inside another app's container makes macOS ask "would like to access
    /// data from other apps" on every launch, so containers are listed by
    /// name and measured only when the person opens the leftover.
    public static func measurable(_ leftover: Leftover) -> [String] {
        let containers = CleanupFS.join(CleanupFS.home, "Library/Containers")
        return leftover.paths.filter { !CleanupFS.isInside($0, containers) }
    }

    /// Everything one deleted app left: the files found by id, plus what the
    /// footprint search finds by id and name across the Mac.
    public static func subject(for leftover: Leftover, in context: Context) -> Footprint.Subject {
        let product = leftover.name.lowercased()
        return Footprint.Subject(
            bundleIDs: leftover.byName ? [] : [leftover.id],
            // A short name would match too much by accident.
            names: product.count >= 4 && !generic.contains(product) ? [leftover.name] : [],
            primary: leftover.paths.map { ($0, context.categories[$0] ?? .support) },
            sharedPrefixes: context.vendors)
    }
}
