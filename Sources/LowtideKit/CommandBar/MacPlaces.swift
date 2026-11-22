import Foundation

/// The person's own scripts ("Your shortcuts"), run directly: no shell, the
/// typed text as the only argument, at most 5 s and 64 KB of output.
public enum UserScript {
    public struct Result: Equatable, Sendable {
        public var ok: Bool
        public var output: String
    }

    public static func run(_ path: String, argument: String?) async -> Result {
        let file = (path.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        guard file.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: file),
              (try? FileManager.default.attributesOfItem(atPath: file)[.type] as? FileAttributeType) == .typeRegular else {
            return Result(ok: false, output: "Not an executable file")
        }
        let result = await LineReader.lines(file, argument.map { [$0] } ?? [], directory: Paths.home, cap: 64 * 1024,
                                            timeout: .seconds(5))
        if result.timedOut { return Result(ok: false, output: "Timed out") }
        guard let status = result.status else { return Result(ok: false, output: "Couldn't run this file") }
        let ok = status == 0
        var output = result.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !ok, output.isEmpty { output = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines) }
        return Result(ok: ok, output: output)
    }
}

/// One System Settings pane; opens with `x-apple.systempreferences:<id>`.
public struct SettingsPane: Equatable, Sendable {
    public var id: String
    public var name: String
    public var keywords: [String]
}

/// Every System Settings pane that opens by URL, read from the system's
/// settings extensions once per launch.
public enum SettingsPanes {
    static let extensions = "/System/Library/ExtensionKit/Extensions"
    static let legacyPanes = "/System/Library/PreferencePanes"
    static let maxTerms = 160
    static let maxTermLength = 40

    private static let cache = OSAllocatedLock<[SettingsPane]?>(initialState: nil)

    public static func all() -> [SettingsPane] {
        if let hit = cache.withLock({ $0 }) { return hit }
        let panes = scan()
        cache.withLock { $0 = panes }
        return panes
    }

    static func scan() -> [SettingsPane] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: extensions)) ?? []
        var seen = Set<String>()
        return names.filter { $0.hasSuffix(".appex") }
            .compactMap { read(URL(fileURLWithPath: extensions).appending(path: $0)) }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    static func plist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    static func text(_ dict: [String: Any]?, _ key: String) -> String? {
        (dict?[key] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    }

    /// Search words from a parsed `.searchTerms` plist: each section's titles
    /// plus their comma-separated index words, deduplicated ignoring case.
    static func searchTerms(_ root: [String: Any]) -> [String] {
        var seen = Set<String>()
        var words: [String] = []
        // Sorted, so the same file always gives the same words.
        for key in root.keys.sorted() {
            guard let entries = (root[key] as? [String: Any])?["localizableStrings"] as? [[String: Any]] else { continue }
            for entry in entries {
                let candidates = [text(entry, "title")].compactMap { $0 }
                    + (text(entry, "index")?.split(separator: ",").map(String.init) ?? [])
                for raw in candidates {
                    let word = raw.trimmingCharacters(in: .whitespaces)
                    guard !word.isEmpty, word.count <= maxTermLength, seen.insert(word.lowercased()).inserted else { continue }
                    words.append(word)
                    if words.count == maxTerms { return words }
                }
            }
        }
        return words
    }

    /// The English `.searchTerms` file in a bundle's resources: the named
    /// one, else the first one found.
    static func termsFile(_ resources: URL, named name: String?) -> URL? {
        let english = resources.appending(path: "en.lproj")
        if let name {
            let named = english.appending(path: "\(name).searchTerms")
            if FileManager.default.fileExists(atPath: named.path) { return named }
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: english.path)) ?? []
        return files.sorted().first { $0.hasSuffix(".searchTerms") }.map { english.appending(path: $0) }
    }

    static func read(_ bundle: URL) -> SettingsPane? {
        guard let info = plist(bundle.appending(path: "Contents/Info.plist")),
              let attrs = (info["EXAppExtensionAttributes"] as? [String: Any])?["SettingsExtensionAttributes"] as? [String: Any],
              attrs["allowsXAppleSystemPreferencesURLScheme"] as? Bool == true,
              let id = text(info, "CFBundleIdentifier") else { return nil }
        let resources = bundle.appending(path: "Contents/Resources")
        // Two panes ship only their internal name.
        let known: String? = switch id {
        case "com.apple.HeadphoneSettings": "Headphones"
        case "com.apple.Battery-Settings.extension": "Battery"
        default: nil
        }
        let english = (plist(resources.appending(path: "InfoPlist.loctable"))?["en"] as? [String: Any])
        guard let raw = known ?? text(english, "CFBundleDisplayName") ?? text(english, "CFBundleName")
            ?? text(info, "CFBundleDisplayName") ?? text(info, "CFBundleName")
            ?? Optional(bundle.deletingPathExtension().lastPathComponent) else { return nil }
        // Apple writes "Wi‑Fi" and "Apple Pay" with non-breaking characters; people type the plain ones.
        let name = raw.replacingOccurrences(of: "\u{2011}", with: "-").replacingOccurrences(of: "\u{a0}", with: " ")
        var file = termsFile(resources, named: text(attrs, "searchTermsFileName"))
        if file == nil, let legacy = text(attrs, "legacyPrefPaneBundleName") {
            file = termsFile(URL(fileURLWithPath: legacyPanes).appending(path: legacy).appending(path: "Contents/Resources"), named: nil)
        }
        let keywords = file.flatMap(plist).map(searchTerms) ?? []
        return SettingsPane(id: id, name: name, keywords: keywords)
    }
}

/// The standard folders that exist on this Mac.
public enum StandardFolders {
    public struct Folder: Equatable, Sendable {
        public var name: String
        public var path: String
    }

    public static func all(home: URL = Paths.home) -> [Folder] {
        let names = ["Downloads", "Desktop", "Documents", "Movies", "Music", "Pictures"]
        let candidates = names.map { Folder(name: $0, path: home.appending(path: $0).path) }
            + [Folder(name: "Home", path: home.path), Folder(name: "Applications", path: "/Applications")]
        return candidates.filter {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue
        }
    }
}
