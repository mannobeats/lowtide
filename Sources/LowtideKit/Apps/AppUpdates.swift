import Foundation
import os

/// A newer version of an app on the Mac.
public struct AppUpdate: Codable, Sendable, Identifiable, Hashable {
    /// How the new version gets onto the Mac.
    public enum Method: String, Codable, Sendable {
        /// Opened in the App Store, which installs it.
        case appStore = "appstore"
        /// `brew upgrade` for apps Homebrew installed.
        case homebrew
        /// The developer's Sparkle feed; the download replaces the app.
        case sparkle
        /// The developer's electron-builder feed; the download replaces the app.
        case electron
        /// Only Homebrew's catalog knows; Homebrew installs over the app.
        case cask
        /// The developer announces it (or a package installs it): the app or
        /// the developer's page does the updating.
        case vendor

        public var label: String {
            switch self {
            case .appStore: "App Store"
            case .cask: "Homebrew catalog"
            case .electron, .sparkle: "Developer’s feed"
            case .homebrew: "Homebrew"
            case .vendor: "Developer’s website"
            }
        }
    }

    /// The bundle path.
    public var id: String
    public var name: String
    public var bundleID: String?
    public var installed: String
    public var available: String
    public var method: Method
    public var notes: String?
    public var notesURL: String?
    public var size: Int64?
    public var released: String?
    public var download: String?
    public var sha512: String?
    /// The Homebrew cask (Homebrew and catalog matches).
    public var cask: String?
    public var storeID: Int?
    public var homepage: String?

    /// How the update gets installed, in a sentence.
    public func howItUpdates(homebrew: Bool) -> String {
        switch method {
        case .appStore: "Opens in the App Store, which installs it."
        case .homebrew: "Homebrew installed this app and upgrades it."
        case .cask:
            homebrew
                ? "Homebrew installs the new version over this copy and keeps it updated from then on."
                : "Get it from the developer’s website, or install Homebrew to update it from here."
        case .vendor: "The developer lists this version on its website. Download it there, or open the app: it can update itself."
        case .sparkle, .electron:
            "Downloaded from the developer’s own update feed. It installs only if macOS confirms it’s signed by the same developer; the old version goes to the Trash."
        }
    }

    /// Installs from here (not a website or the app itself).
    public func installsHere(homebrew: Bool) -> Bool {
        !(method == .vendor || (method == .cask && !homebrew))
    }
}

public struct UpdateScan: Codable, Sendable {
    public var updates: [AppUpdate]
    /// Apps on the Mac that were looked at.
    public var apps: Int
    /// Apps with a known place to check.
    public var checked: Int
    public var checkedAt: Date
    public var homebrew: Bool
}

/// Updates for every app on the Mac, wherever it came from. Each app is
/// checked where its own updater looks: the App Store, the developer's
/// Sparkle or Electron feed, a developer page that announces the version,
/// else Homebrew's catalog. Results are kept on disk, so the Updates page
/// opens at once and checks at most every few hours.
public enum AppUpdates {
    /// Fresh results are reused instead of checking every feed again.
    public static let fresh: TimeInterval = 4 * 3600

    static var cacheFile: URL { Paths.cache.appending(path: "app-updates.json") }

    public static func load() -> UpdateScan? {
        guard let data = try? Data(contentsOf: cacheFile) else { return nil }
        return try? JSONStore.decoder.decode(UpdateScan.self, from: data)
    }

    static func save(_ scan: UpdateScan) { JSONStore.write(scan, to: cacheFile) }

    /// Drops an app from the saved results once it's up to date (or gone).
    public static func forget(_ id: String) {
        guard var scan = load() else { return }
        scan.updates.removeAll { $0.id == id }
        save(scan)
    }

    /// Apps with a newer version. Reuses the last check while it's fresh,
    /// unless `force`.
    public static func check(force: Bool) async -> UpdateScan {
        await Checker.shared.check(force: force)
    }

    /// One check at a time: a second caller waits and gets the same result.
    actor Checker {
        static let shared = Checker()
        private var running: Task<UpdateScan, Never>?

        func check(force: Bool) async -> UpdateScan {
            if !force, let scan = load(), Date.now.timeIntervalSince(scan.checkedAt) < fresh { return scan }
            if let running { return await running.value }
            let task = Task { await AppUpdates.scan() }
            running = task
            let scan = await task.value
            running = nil
            save(scan)
            return scan
        }
    }

    // MARK: - One app

    struct Local: Sendable {
        var path: String
        var name: String
        var bundleID: String?
        var version: String
        var build: String
        var feed: String?
        var fromStore: Bool
        var brewToken: String?
    }

    static func readLocal(_ url: URL, brew: [String: String]) -> Local? {
        guard let info = AppBundles.read(url),
              // `12.4.6 (2026-09-10_0de5c8fa9a)`: the build stamp isn't the version.
              let version = info.version?.split(separator: " ").first.map(String.init)
        else { return nil }
        let file = url.lastPathComponent
        return Local(
            path: url.path, name: String(file.dropLast(".app".count)), bundleID: info.bundleID, version: version,
            build: info.build ?? version,
            feed: info.feedURL.flatMap { $0.hasPrefix("https://") || $0.hasPrefix("http://") ? $0 : nil },
            fromStore: AppBundles.fromAppStore(url), brewToken: brew[file]
        )
    }

    struct Found: Sendable {
        var method: AppUpdate.Method
        var release: FeedRelease
        var newer: Bool
        var storeID: Int?
        var homepage: String?
        var cask: String?
    }

    static let osVersion: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }()

    /// The App Store region, from the Mac's region setting.
    static let storeCountry: String = {
        let region = Locale.current.region?.identifier.lowercased() ?? "us"
        return region.count == 2 ? region : "us"
    }()

    /// Old feeds still say `http://`; nearly every host answers on HTTPS, and
    /// a feed that doesn't is skipped rather than read in the clear.
    static func fetch(_ address: String) async -> Data? {
        let secure = address.hasPrefix("http://") ? "https://" + address.dropFirst(7) : address
        guard let url = URL(string: secure), url.scheme == "https" else { return nil }
        return try? await HTTP.data(url)
    }

    static func fromStore(_ app: Local) async -> Found? {
        guard let id = app.bundleID?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let data = await fetch("https://itunes.apple.com/lookup?bundleId=\(id)&country=\(storeCountry)"),
              let (release, storeID) = UpdateFeeds.storeRelease(data)
        else { return nil }
        return Found(method: .appStore, release: release, newer: AppVersion.isNewer(release.version, than: app.version), storeID: storeID)
    }

    static func fromSparkle(_ app: Local) async -> Found? {
        guard let feed = app.feed, let data = await fetch(feed), let release = UpdateFeeds.appcast(data, os: osVersion) else { return nil }
        return Found(method: .sparkle, release: release, newer: AppVersion.isNewer(release.build, than: app.build))
    }

    static func fromElectron(_ app: Local) async -> Found? {
        let config = URL(fileURLWithPath: app.path).appending(path: "Contents/Resources/app-update.yml")
        guard let text = try? String(contentsOf: config, encoding: .utf8), let feed = UpdateFeeds.electronFeed(text),
              let data = await fetch(feed),
              let release = UpdateFeeds.electronRelease(String(decoding: data, as: UTF8.self), feedURL: feed)
        else { return nil }
        return Found(method: .electron, release: release, newer: AppVersion.isNewer(release.version, than: app.version))
    }

    static func fromVendor(_ app: Local) async -> Found? {
        guard let id = app.bundleID, let vendor = UpdateVendor.forID(id),
              let data = try? await HTTP.data(vendor.url), let latest = vendor.read(data)
        else { return nil }
        return Found(method: .vendor, release: FeedRelease(build: latest, version: latest),
                     newer: AppVersion.isNewer(latest, than: app.version), homepage: vendor.page)
    }

    static func fromCask(_ app: Local, _ cask: Cask, _ method: AppUpdate.Method) -> Found? {
        guard AppVersion.comparable(cask.version, app.version), sameApp(cask, bundleID: app.bundleID) else { return nil }
        return Found(
            method: method, release: FeedRelease(build: cask.version, version: cask.version),
            newer: !AppVersion.onlyAddsBuild(cask.version, to: app.version) && AppVersion.isNewer(cask.version, than: app.version),
            homepage: cask.homepage, cask: cask.token
        )
    }

    /// Whether a cask matched by file name installs this very app: when its
    /// uninstall steps name bundle ids, one must share the app's vendor.
    static func sameApp(_ cask: Cask, bundleID: String?) -> Bool {
        let namesIDs = ["\"quit\"", "launchctl", "/preferences/"].contains { cask.mentions.contains($0) }
        guard namesIDs, let bundleID else { return true }
        let vendor = bundleID.split(separator: ".", omittingEmptySubsequences: false).prefix(2).joined(separator: ".").lowercased()
        return cask.mentions.contains(vendor)
    }

    /// Casks name an uninstaller's bundle id among the files they remove; it isn't the app.
    static func isUninstaller(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("uninstall") || lower.hasPrefix("remove ")
    }

    static func words(_ text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber }.map { $0.lowercased() }
    }

    /// How many words of a cask's token name the app (`fl-studio` for
    /// `FL Studio 2026`): a cask found by bundle id must share at least one,
    /// or it only mentions the app (a converter that quits Chrome).
    static func sharedWords(_ cask: Cask, _ appWords: [String]) -> Int {
        let token = cask.token.split(separator: "@", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return words(token).filter { $0.count >= 3 && appWords.contains($0) }.count
    }

    /// Whether the cask's uninstall or zap steps name this bundle id.
    static func namesID(_ cask: Cask, _ id: String) -> Bool {
        let text = cask.mentions
        func isIDChar(_ c: Character) -> Bool { (c.isASCII && (c.isLetter || c.isNumber)) || "-_.".contains(c) }
        var search = text.startIndex..<text.endIndex
        while let range = text.range(of: id, range: search) {
            let before = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : nil
            let after = range.upperBound < text.endIndex ? text[range.upperBound] : nil
            if !(before.map(isIDChar) ?? false) && !(after.map { isIDChar($0) && $0 != "." } ?? false) { return true }
            search = text.index(after: range.lowerBound)..<text.endIndex
        }
        return false
    }

    /// The cask that updates this app. One named like its file
    /// (`Firefox.app`), else, for apps a package installs or whose file a
    /// cask names differently (`FL Studio 2026.app`), the ones naming its
    /// bundle id. Several can fit (`firefox`, `firefox@esr`): the one sharing
    /// the most words with the app, then the one on the same major version,
    /// then a stable one.
    static func caskOf(_ app: Local, _ catalog: CaskCatalog) -> Cask? {
        let appWords = words(app.name)
        var found = catalog.byName["\(app.name.lowercased()).app"] ?? []
        if found.isEmpty {
            guard let id = app.bundleID?.lowercased(), id.filter({ $0 == "." }).count >= 2, !isUninstaller(app.name) else { return nil }
            found = catalog.all.filter { namesID($0, id) && sharedWords($0, appWords) > 0 }
        }
        guard let best = found.map({ sharedWords($0, appWords) }).max() else { return nil }
        found = found.filter { sharedWords($0, appWords) == best }
        let same = found.filter { AppVersion.major($0.version) == AppVersion.major(app.version) }
        if !same.isEmpty { found = same }
        let stable = found.filter { !$0.token.contains("@") }
        if !stable.isEmpty { found = stable }
        return found.count == 1 ? found[0] : nil
    }

    /// Asks the place this app updates from. Nil when nothing knows it.
    static func check(_ app: Local, _ catalog: CaskCatalog) async -> Found? {
        if app.fromStore { return await fromStore(app) }
        // The cask Homebrew installed, not another one for the same app name.
        if let token = app.brewToken,
           let cask = catalog.byName["\(app.name.lowercased()).app"]?.first(where: { $0.token == token }) {
            return fromCask(app, cask, .homebrew)
        }
        if let found = await fromSparkle(app) { return found }
        if let found = await fromElectron(app) { return found }
        if let found = await fromVendor(app) { return found }
        // An app Homebrew installed isn't matched to another cask.
        if app.brewToken != nil { return nil }
        guard let cask = caskOf(app, catalog) else { return nil }
        return fromCask(app, cask, cask.pkg ? .vendor : .cask)
    }

    static func update(_ app: Local, _ found: Found) -> AppUpdate {
        AppUpdate(
            id: app.path, name: app.name, bundleID: app.bundleID, installed: app.version, available: found.release.version,
            method: found.method, notes: found.release.notes, notesURL: found.release.notesURL, size: found.release.size,
            released: found.release.released, download: found.release.url, sha512: found.release.sha512,
            cask: found.cask, storeID: found.storeID, homepage: found.homepage
        )
    }

    static func scan() async -> UpdateScan {
        async let brew = InstalledApps.brewApps()
        async let catalog = try? CaskCatalog.load()
        let bundles = AppBundles.appPaths(depth: 2)
        let casks = await catalog ?? CaskCatalog()
        let brewApps = await brew
        let locals = bundles
            // Setapp updates its own apps.
            .filter { !$0.path.hasPrefix("/Applications/Setapp/") }
            .compactMap { readLocal($0, brew: brewApps) }
            .filter { !AppBundles.isProtected(URL(fileURLWithPath: $0.path), bundleID: $0.bundleID) }
        // Children file their own result instead of returning a tuple through
        // the group (such tuples came out uninitialized in optimized builds;
        // see ToolchainModel).
        let results = OSAllocatedUnfairLock(initialState: (checked: 0, updates: [AppUpdate]()))
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func add() {
                guard next < locals.count else { return }
                let app = locals[next]
                next += 1
                group.addTask {
                    guard let found = await check(app, casks) else { return }
                    let newer = found.newer ? update(app, found) : nil
                    results.withLock {
                        $0.checked += 1
                        if let newer { $0.updates.append(newer) }
                    }
                }
            }
            for _ in 0..<10 { add() }
            while await group.next() != nil { add() }
        }
        let (checked, unsorted) = results.withLock { $0 }
        var updates = unsorted
        updates.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return UpdateScan(updates: updates, apps: bundles.count, checked: checked, checkedAt: .now, homebrew: Shell.isAvailable("brew"))
    }

    // MARK: - Skipped versions

    /// App id → the version the person chose to skip.
    public static func skipped() -> [String: String] { JSONStore.load("skipped-updates.json", default: [:]) }

    public static func saveSkipped(_ skipped: [String: String]) { JSONStore.save(skipped, to: "skipped-updates.json") }
}
