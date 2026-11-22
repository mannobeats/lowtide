import Foundation

/// One cask from Homebrew's catalog, reduced to what Lowtide reads.
public struct Cask: Sendable, Hashable {
    public var token: String
    public var name: String
    public var desc: String?
    public var homepage: String
    /// The version people read (`1.2.3` of `1.2.3,456`).
    public var version: String
    public var autoUpdates: Bool
    /// App file names it installs (`Firefox.app`).
    public var appNames: [String]
    /// The cask's uninstall and zap stanzas, lowercase: they name the bundle
    /// ids of the app it installs.
    public var mentions: String
    /// Installed by a `.pkg`: there is no app for Homebrew to replace.
    public var pkg: Bool
    public var disabled: Bool
    /// `latest`: no version to compare.
    public var unversioned: Bool
}

/// Homebrew's cask catalog (formulae.brew.sh), for update checks and for
/// knowing which apps Homebrew could adopt. Kept for an hour on disk.
public struct CaskCatalog: Sendable {
    public var all: [Cask] = []
    /// By app file name, lowercase. One name can belong to several casks
    /// (`1password`, `1password@beta`).
    public var byName: [String: [Cask]] = [:]

    public init(_ casks: [Cask] = []) {
        all = casks
        for cask in casks {
            for name in cask.appNames { byName[name.lowercased(), default: []].append(cask) }
        }
    }

    static let url = URL(string: "https://formulae.brew.sh/api/cask.json")!
    static let ttl: TimeInterval = 3600

    /// The catalog, from the cache while it's under an hour old, else
    /// downloaded; the stale copy when the network fails.
    public static func load() async throws -> CaskCatalog {
        let file = Paths.cache.appending(path: "cask.json")
        let age = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            .map { Date.now.timeIntervalSince($0) } ?? .infinity
        if age < ttl, let data = try? Data(contentsOf: file), let catalog = try? parse(data) { return catalog }
        do {
            let data = try await HTTP.data(url)
            let catalog = try parse(data)
            try? data.write(to: file, options: .atomic)
            return catalog
        } catch {
            if let data = try? Data(contentsOf: file), let catalog = try? parse(data) { return catalog }
            throw error
        }
    }

    public static func parse(_ data: Data) throws -> CaskCatalog {
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw LowtideError.invalid("Homebrew's catalog couldn't be read")
        }
        return CaskCatalog(list.compactMap(cask))
    }

    static func cask(_ json: [String: Any]) -> Cask? {
        guard let token = json["token"] as? String else { return nil }
        let artifacts = json["artifacts"] as? [Any] ?? []
        let rawVersion = json["version"] as? String ?? ""
        let names = appNames(artifacts)
        let stanzas = artifacts.compactMap { $0 as? [String: Any] }
        let mentions = stanzas.filter { $0["uninstall"] != nil || $0["zap"] != nil }
            .compactMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .withoutEscapingSlashes]) }
            .map { String(decoding: $0, as: UTF8.self).lowercased() }
            .joined()
        return Cask(
            token: token,
            name: (json["name"] as? [String])?.first ?? token,
            desc: json["desc"] as? String,
            homepage: json["homepage"] as? String ?? "",
            version: AppVersion.display(rawVersion),
            autoUpdates: json["auto_updates"] as? Bool ?? false,
            appNames: names,
            mentions: mentions,
            pkg: names.isEmpty && stanzas.contains { $0["pkg"] != nil },
            disabled: json["disabled"] as? Bool ?? false,
            unversioned: rawVersion == "latest"
        )
    }

    /// App file names a cask installs. A renamed app counts under its target
    /// name only (`{"app": ["Thorium.app", {"target": "Thorium Browser.app"}]}`
    /// installs `Thorium Browser.app`).
    public static func appNames(_ artifacts: [Any]) -> [String] {
        var names = Set<String>()
        for case let artifact as [String: Any] in artifacts {
            guard let entries = artifact["app"] as? [Any] else { continue }
            var pending: String?
            for entry in entries {
                if let text = entry as? String {
                    if let previous = pending, let name = safeAppName(previous) { names.insert(name) }
                    pending = text
                } else if let target = (entry as? [String: Any])?["target"] as? String {
                    if let name = safeAppName(target) { names.insert(name) }
                    pending = nil
                }
            }
            if let last = pending {
                // The new API also names the target beside the list.
                let target = (artifact["target"] as? String).flatMap(safeAppName)
                if let name = target ?? safeAppName(last) { names.insert(name) }
            }
        }
        return names.sorted()
    }

    static func safeAppName(_ value: String) -> String? {
        let name = (value as NSString).lastPathComponent
        return name.hasSuffix(".app") && !name.contains("/") ? name : nil
    }

    /// A cask token that is safe to hand to `brew`.
    public static func validToken(_ token: String) -> Bool {
        !token.isEmpty && !token.hasPrefix("-")
            && token.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.+@".unicodeScalars.contains($0)) }
    }
}

/// What Homebrew's catalog says about the apps here: which ones it could
/// adopt (matched by bundle name, as Homebrew does) and which records lost
/// their app.
public struct BrewRecords: Sendable {
    /// App file name (lowercase) → the cask that would adopt it.
    public var adoptable: [String: Cask] = [:]
    /// Casks Homebrew lists as installed whose app is gone from Applications.
    public var broken: [Cask] = []
    public var homebrew: Bool = false

    public init(adoptable: [String: Cask] = [:], broken: [Cask] = [], homebrew: Bool = false) {
        self.adoptable = adoptable
        self.broken = broken
        self.homebrew = homebrew
    }

    public func adoptable(_ app: InstalledApp) -> Cask? {
        guard app.source == .direct else { return nil }
        return adoptable[(app.path as NSString).lastPathComponent.lowercased()]
    }

    /// From the catalog, Homebrew's installed casks (`token → version`) and
    /// the apps on disk (lowercase file name → from the App Store).
    public static func make(catalog: CaskCatalog, installed: [String: String], apps: [String: Bool], homebrew: Bool) -> BrewRecords {
        var records = BrewRecords(homebrew: homebrew)
        for cask in catalog.all where !cask.appNames.isEmpty && !cask.disabled {
            let present = cask.appNames.contains { apps[$0.lowercased()] != nil }
            if installed[cask.token] != nil {
                if !present { records.broken.append(cask) }
            } else if homebrew {
                for name in cask.appNames {
                    let key = name.lowercased()
                    // An App Store copy updates itself; a Homebrew copy is
                    // already managed (by another cask for the same name).
                    if apps[key] == false, records.adoptable[key] == nil { records.adoptable[key] = cask }
                }
            }
        }
        records.broken.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return records
    }

    /// `brew list --cask --versions`: `token version`.
    public static func parseInstalled(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            out[String(parts[0])] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    /// Reads the catalog, Homebrew and Applications together.
    public static func load(apps: [InstalledApp]) async -> BrewRecords {
        let homebrew = Shell.isAvailable("brew")
        guard homebrew, let catalog = try? await CaskCatalog.load() else { return BrewRecords(homebrew: homebrew) }
        let installed = (try? await Shell.run("brew", ["list", "--cask", "--versions"], timeout: .seconds(60)))
            .flatMap { $0.ok ? parseInstalled($0.stdout) : nil } ?? [:]
        var onDisk: [String: Bool] = [:]
        for app in apps {
            let key = (app.path as NSString).lastPathComponent.lowercased()
            // Homebrew's own copies aren't up for adoption.
            onDisk[key] = app.source == .direct ? false : true
        }
        return make(catalog: catalog, installed: installed, apps: onDisk, homebrew: homebrew)
    }
}

/// `brew` for casks. Homebrew holds one lock, so its runs never overlap.
public enum Brew {
    public enum Action: String, Sendable {
        case adopt, repair, uninstall, upgrade

        public var progress: String {
            switch self {
            case .adopt: "Adopting…"
            case .repair: "Repairing…"
            case .uninstall: "Removing…"
            case .upgrade: "Updating…"
            }
        }
    }

    public static func arguments(_ action: Action) -> [String] {
        switch action {
        case .adopt: ["install", "--cask", "--adopt"]
        // One reinstall step: if it fails the app is still installed, unlike
        // an uninstall followed by a failed install.
        case .repair: ["reinstall", "--cask"]
        case .uninstall: ["uninstall", "--cask"]
        case .upgrade: ["upgrade", "--cask"]
        }
    }

    public static func run(_ action: Action, token: String) async throws {
        try await cask(arguments(action), token: token) { _ in }
    }

    /// Runs `brew <verb> <token>` under Homebrew's lock, line by line.
    public static func cask(_ verb: [String], token: String, onLine: @escaping @Sendable (String) -> Void) async throws {
        guard CaskCatalog.validToken(token) else { throw LowtideError.invalid("That isn't a Homebrew cask name") }
        guard Shell.isAvailable("brew") else { throw LowtideError.toolMissing("Homebrew") }
        try await ToolLock.shared.with("brew") {
            let out = try await Shell.stream("brew", verb + [token], onLine: onLine)
            guard out.ok else { throw LowtideError.commandFailed(failure(out.stdout)) }
        }
    }

    /// The line that says why: the last `Error:` line, else the last line.
    static func failure(_ output: String) -> String {
        let lines = output.split(separator: "\n").map(String.init)
        let line = lines.last { $0.contains("Error") } ?? lines.last ?? "brew failed"
        return line.replacingOccurrences(of: "Error: ", with: "")
    }
}
