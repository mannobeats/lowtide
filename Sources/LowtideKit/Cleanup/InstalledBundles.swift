import Foundation

/// Where apps and plug-ins live on the Mac, for Leftovers and Downloads
/// (`AppBundles` reads each bundle).
public enum InstalledBundles {
    /// The apps in `dir` and its folders, `depth` levels down: vendors keep
    /// theirs in subfolders (`/Applications/Native Instruments/Maschine 3/`).
    /// Never looks inside an app or follows a linked folder; a linked app is
    /// kept only with `links`.
    static func apps(under dir: String, depth: Int, links: Bool, into out: inout [String]) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        for name in names {
            let path = "\(dir)/\(name)"
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            let isDir = (info.st_mode & S_IFMT) == S_IFDIR
            if name.lowercased().hasSuffix(".app") {
                var target = stat()
                if isDir || (links && stat(path, &target) == 0 && (target.st_mode & S_IFMT) == S_IFDIR) {
                    out.append(path)
                }
            } else if depth > 0, isDir {
                apps(under: path, depth: depth - 1, links: links, into: &out)
            }
        }
    }

    /// Installed app bundles, sorted. Without `everywhere`: only
    /// `/Applications` and `~/Applications` as they sit there. With it: also
    /// `/System/Applications` and every app Spotlight knows on any volume,
    /// links resolved, each once: for anything that must not miss an app.
    public static func appPaths(everywhere: Bool, depth: Int = 2) async -> [String] {
        var paths: [String] = []
        var roots = ["/Applications", Paths.home.appending(path: "Applications").path]
        if everywhere { roots.append("/System/Applications") }
        for root in roots { apps(under: root, depth: depth, links: everywhere, into: &paths) }
        if everywhere {
            // Spotlight can be off for a volume: it adds to the walk.
            paths += await spotlightApps()
            paths = paths.map { CleanupFS.realPath($0) ?? $0 }
                .filter { $0.lowercased().hasSuffix(".app") }
        }
        return Array(Set(paths)).sorted()
    }

    private static func spotlightApps() async -> [String] {
        let out = try? await Shell.run("/usr/bin/mdfind", ["-0", "kMDItemContentType == 'com.apple.application-bundle'"],
                                       timeout: .seconds(60))
        return (out?.stdout ?? "").split(separator: "\0").map(String.init).filter { !$0.isEmpty }
    }

    /// Every installed audio plug-in bundle: (file name without extension,
    /// bundle id, vendor). A vendor's support folder (`u-he`) isn't a
    /// leftover while one of its plug-ins is here.
    public static func plugins() -> [(stem: String, bundleID: String?, vendor: String?)] {
        var found: [(String, String?, String?)] = []
        for library in [Paths.home.appending(path: "Library").path, "/Library"] {
            for (folder, _) in Footprint.pluginFolders {
                let dir = "\(library)/\(folder)"
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
                for name in names {
                    let path = "\(dir)/\(name)"
                    // Bundles carry an extension; plain folders group a
                    // vendor's bundles one level down.
                    var bundles: [String] = []
                    if !(name as NSString).pathExtension.isEmpty {
                        bundles = [path]
                    } else if !name.hasPrefix("."), let inner = try? FileManager.default.contentsOfDirectory(atPath: path) {
                        bundles = inner.filter { !($0 as NSString).pathExtension.isEmpty }.map { "\(path)/\($0)" }
                    }
                    for bundle in bundles {
                        let id = AppBundles.read(URL(fileURLWithPath: bundle))?.bundleID
                        let stem = ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
                        found.append((stem, id, vendor(of: bundle, bundleID: id)))
                    }
                }
            }
        }
        return found
    }

    /// `Arturia: ARP 2600 V3` in an Audio Unit's component list names the
    /// vendor exactly; else the bundle id's second part.
    static func vendor(of bundle: String, bundleID: String?) -> String? {
        if let components = AppBundles.infoDictionary(URL(fileURLWithPath: bundle))?["AudioComponents"] as? [[String: Any]],
           let name = components.first?["name"] as? String, let colon = name.firstIndex(of: ":") {
            return name[..<colon].trimmingCharacters(in: .whitespaces)
        }
        return bundleID.flatMap(vendor(fromID:))
    }

    /// `com.arturia.…` → Arturia, `jp.co.roland.…` → Roland.
    static func vendor(fromID id: String) -> String? {
        let parts = id.split(separator: ".").map(String.init)
        guard parts.count >= 3 else { return nil }
        let part = ["co", "com", "ac", "or", "ne", "org", "net"].contains(parts[1]) ? parts[2] : parts[1]
        guard let first = part.first else { return nil }
        return first.uppercased() + part.dropFirst()
    }
}
