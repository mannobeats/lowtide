import CoreServices
import Foundation

/// One application on the Mac, wherever it came from.
public struct InstalledApp: Codable, Sendable, Identifiable, Hashable {
    public enum Source: String, Codable, Sendable, CaseIterable {
        case appStore = "appstore", homebrew, setapp, direct

        public var label: String {
            switch self {
            case .appStore: "App Store"
            case .homebrew: "Homebrew"
            case .setapp: "Setapp"
            case .direct: "Download"
            }
        }
    }

    /// The bundle path; unique.
    public var id: String { path }
    public var name: String
    public var bundleID: String?
    public var version: String?
    public var path: String
    public var source: Source
    public var brewToken: String?
    public var bytes: Int64?
    /// When it was last opened, from its Spotlight metadata.
    public var lastUsed: Date?
    /// Apple's own apps and Lowtide itself can't be removed here.
    public var protected: Bool

    public init(name: String, bundleID: String?, version: String?, path: String, source: Source,
                brewToken: String?, bytes: Int64? = nil, lastUsed: Date? = nil, protected: Bool) {
        self.name = name
        self.bundleID = bundleID
        self.version = version
        self.path = path
        self.source = source
        self.brewToken = brewToken
        self.bytes = bytes
        self.lastUsed = lastUsed
        self.protected = protected
    }

    /// Not opened for three months (or never, as far as Spotlight knows).
    public func unused(now: Date = .now) -> Bool {
        guard let lastUsed else { return true }
        return now.timeIntervalSince(lastUsed) > 90 * 86_400
    }
}

/// Lists the apps in Applications at once, then measures size and last use.
public enum InstalledApps {
    /// Every app, without sizes (a directory walk and their Info.plists).
    public static func list(brew: [String: String]) -> [InstalledApp] {
        AppBundles.appPaths(depth: 2).map { describe($0, brew: brew) }
    }

    public static func describe(_ url: URL, brew: [String: String]) -> InstalledApp {
        let info = AppBundles.read(url)
        let file = url.lastPathComponent
        let token = brew[file]
        let source: InstalledApp.Source =
            AppBundles.fromAppStore(url) ? .appStore
            : token != nil ? .homebrew
            : url.path.hasPrefix("/Applications/Setapp/") ? .setapp
            : .direct
        return InstalledApp(
            name: String(file.dropLast(".app".count)),
            bundleID: info?.bundleID,
            version: info?.version,
            path: url.path,
            source: source,
            brewToken: token,
            protected: AppBundles.isProtected(url, bundleID: info?.bundleID)
        )
    }

    /// When the app was last opened. Spotlight's metadata store, read in
    /// process (no `mdls` per app).
    public static func lastUsed(_ path: String) -> Date? {
        guard let item = MDItemCreate(nil, path as CFString),
              let value = MDItemCopyAttribute(item, kMDItemLastUsedDate)
        else { return nil }
        return value as? Date
    }

    /// App file name → cask token, for apps Homebrew installed.
    public static func brewApps() async -> [String: String] {
        guard Shell.isAvailable("brew"),
              let out = try? await Shell.run("brew", ["info", "--json=v2", "--cask", "--installed"], timeout: .seconds(120)),
              out.ok
        else { return [:] }
        return parseBrewApps(Data(out.stdout.utf8))
    }

    static func parseBrewApps(_ data: Data) -> [String: String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = json["casks"] as? [[String: Any]]
        else { return [:] }
        var map: [String: String] = [:]
        for cask in casks {
            guard let token = cask["token"] as? String else { continue }
            for name in CaskCatalog.appNames(cask["artifacts"] as? [Any] ?? []) { map[name] = token }
        }
        return map
    }
}
