import Darwin
import Foundation

/// One thing in Downloads (or an installer on the Desktop or in Documents),
/// read as a decision: what it is, where it came from, whether it's done.
public struct Download: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable, CaseIterable {
        case installer, archive, image, video, audio, document, code, folder, other

        public var label: String {
            switch self {
            case .installer: "Installers"
            case .archive: "Archives"
            case .image: "Images"
            case .video: "Video"
            case .audio: "Audio"
            case .document: "Documents"
            case .code: "Code"
            case .folder: "Folders"
            case .other: "Other"
            }
        }
    }

    public enum Hint: String, Sendable, CaseIterable {
        /// An installer for an app already in Applications.
        case installed
        /// An archive whose extracted folder sits next to it.
        case unpacked
        /// A "name (1)" copy of a file that's still there.
        case copy

        public var label: String {
            switch self {
            case .installed: "App installed"
            case .unpacked: "Already unpacked"
            case .copy: "Duplicate copy"
            }
        }
    }

    public var id: String { path }
    public let path: String
    public let name: String
    public let isDir: Bool
    /// Files at once; folders once measured.
    public var bytes: Int64?
    /// When it landed in Downloads (Spotlight), else when it was created.
    public let added: Date?
    public let kind: Kind
    /// The site it came from, when the browser recorded one (host only:
    /// download links often carry signed tokens).
    public let source: String?
    public let hints: [Hint]

    /// Untouched for three months.
    public func isOld(now: Date = Date()) -> Bool {
        added.map { now.timeIntervalSince($0) > 90 * 86_400 } ?? false
    }
}

public enum Downloads {
    /// Disk images and installer packages.
    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "xip", "iso"]
    /// Searched for installers below their top level too.
    static let installerFolders = ["Downloads", "Desktop", "Documents"]
    /// Deep enough for `Downloads/Steinberg/OSX/Cubase 15/…`.
    static let installerDepth = 6

    static func ext(_ path: String) -> String { (path as NSString).pathExtension.lowercased() }

    static func isInstaller(_ path: String) -> Bool { installerExtensions.contains(ext(path)) }

    /// Installer files under `dir`, `depth` folders down. Hidden folders,
    /// `node_modules` and packages are skipped; a folder with a dot in its
    /// name (`Cubase 15.0.30 - Application`) is searched.
    static func installers(under dir: String, depth: Int, into out: inout [String]) {
        for name in CleanupFS.names(dir) where !name.hasPrefix(".") {
            let path = CleanupFS.join(dir, name)
            // A .pkg can be a folder: check before treating it as one.
            if isInstaller(path) {
                out.append(path)
            } else if depth > 0, name != "node_modules", !FolderScan.isPackage(path), CleanupFS.isDir(path) {
                installers(under: path, depth: depth - 1, into: &out)
            }
        }
    }

    static func kind(of path: String, isDir: Bool) -> Download.Kind {
        let ext = ext(path)
        if ext == "app" || installerExtensions.contains(ext) { return .installer }
        switch ext {
        case "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst": return .archive
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "svg", "tif", "tiff", "bmp", "psd", "raw", "cr2", "nef": return .image
        case "mp4", "mov", "mkv", "avi", "webm", "m4v": return .video
        case "wav", "mp3", "aif", "aiff", "flac", "m4a", "ogg", "mid", "midi": return .audio
        case "pdf", "doc", "docx", "pages", "key", "numbers", "xls", "xlsx", "csv", "txt", "md", "rtf", "ppt", "pptx", "epub":
            return .document
        case "json", "js", "ts", "py", "rs", "sh", "html", "css", "xml", "yml", "yaml", "sql", "ipynb", "swift", "go":
            return .code
        default: return isDir ? .folder : .other
        }
    }

    /// Host of the first URL in `mdls`'s `("url", "url")` list.
    static func firstHost(_ text: String) -> String? {
        guard let open = text.firstIndex(of: "\"") else { return nil }
        let rest = text[text.index(after: open)...]
        guard let close = rest.firstIndex(of: "\"") else { return nil }
        let url = rest[..<close]
        guard let scheme = url.range(of: "://") else { return nil }
        let afterScheme = url[scheme.upperBound...]
        let authority = afterScheme.prefix { !"/?#".contains($0) }
        var host = String(authority.split(separator: "@").last ?? "")
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host.isEmpty ? nil : host
    }

    private static let spotlightDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f
    }()

    /// `2026-04-11 22:09:07 +0000`, as `mdls -raw` prints a date.
    static func parseSpotlightDate(_ text: String) -> Date? {
        spotlightDate.date(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Date added and origin for many files, one `mdls` per 200. `mdls -raw`
    /// prints the attributes alphabetically, NUL-separated.
    static func spotlight(_ paths: [String]) async -> [String: (Date?, String?)] {
        var out: [String: (Date?, String?)] = [:]
        var start = 0
        while start < paths.count {
            let chunk = Array(paths[start..<min(start + 200, paths.count)])
            start += 200
            guard let result = try? await Shell.run("/usr/bin/mdls", ["-raw", "-name", "kMDItemDateAdded", "-name", "kMDItemWhereFroms"] + chunk,
                                                    timeout: .seconds(60)) else { continue }
            let fields = result.stdout.components(separatedBy: "\0")
            guard fields.count >= chunk.count * 2 else { continue }
            for (index, path) in chunk.enumerated() {
                out[path] = (parseSpotlightDate(fields[index * 2]), firstHost(fields[index * 2 + 1]))
            }
        }
        return out
    }

    /// Lowercase letters only: `Figma-124.5.dmg` and `Figma.app` give `figma`.
    static func letters(_ name: String) -> String {
        String(name.filter { $0.isASCII && $0.isLetter }).lowercased()
    }

    static func installedAppKeys() async -> Set<String> {
        Set(await InstalledBundles.appPaths(everywhere: false)
            .map { letters((CleanupFS.name($0) as NSString).deletingPathExtension) }
            .filter { $0.count >= 3 })
    }

    static func stem(_ name: String) -> String {
        let lower = name.lowercased()
        for suffix in [".tar.gz", ".tar.xz", ".tar.bz2"] where lower.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        guard let dot = name.lastIndex(of: ".") else { return name }
        return String(name[..<dot])
    }

    /// `report (1).pdf` gives `report.pdf`.
    static func original(of name: String) -> String? {
        let dot = name.lastIndex(of: ".")
        let base = dot.map { String(name[..<$0]) } ?? name
        let ext = dot.map { String(name[name.index(after: $0)...]) }
        guard let open = base.range(of: " (", options: .backwards), base.hasSuffix(")") else { return nil }
        let number = base[open.upperBound..<base.index(before: base.endIndex)]
        guard !number.isEmpty, number.allSatisfy(\.isNumber) else { return nil }
        let original = String(base[..<open.lowerBound])
        return ext.map { "\(original).\($0)" } ?? original
    }

    /// Siblings by name: whether each is a folder, and its size (files).
    typealias Siblings = [String: (isDir: Bool, bytes: Int64?)]

    static func hints(name: String, kind: Download.Kind, bytes: Int64?, siblings: Siblings, apps: Set<String>) -> [Download.Hint] {
        var hints: [Download.Hint] = []
        if kind == .installer {
            let key = letters(stem(name))
            if !key.isEmpty, apps.contains(key) || apps.contains(where: { $0.count >= 5 && key.hasPrefix($0) }) {
                hints.append(.installed)
            }
        }
        if kind == .archive, siblings[stem(name)]?.isDir == true { hints.append(.unpacked) }
        if let original = original(of: name), let other = siblings[original], !other.isDir, other.bytes == bytes {
            hints.append(.copy)
        }
        return hints
    }

    /// Everything at the top of Downloads, plus installers deeper in
    /// Downloads, on the Desktop and in Documents. Folders aren't measured
    /// yet (`bytes` is nil): measure them and fill in as they land.
    public static func list(home: String = Paths.home.path) async throws -> [Download] {
        let downloads = CleanupFS.join(home, "Downloads")
        guard CleanupFS.isFolder(downloads) else { return [] }
        guard FileManager.default.isReadableFile(atPath: downloads) else {
            throw LowtideError.denied("macOS didn't let Lowtide read Downloads. Allow it in Privacy & Security, then try again.")
        }
        let (paths, apps) = await Task.detached(priority: .userInitiated) { () -> ([String], Set<String>) in
            let top = CleanupFS.names(downloads).filter { !$0.hasPrefix(".") }.map { CleanupFS.join(downloads, $0) }
            var nested: [String] = []
            for folder in installerFolders { installers(under: CleanupFS.join(home, folder), depth: installerDepth, into: &nested) }
            let topSet = Set(top)
            return ((top + nested.filter { !topSet.contains($0) }).sorted(), await installedAppKeys())
        }.value
        let meta = paths.compactMap { path in CleanupFS.info(path).map { (path, $0) } }
        let found = await spotlight(meta.map(\.0))
        func isFolder(_ info: stat) -> Bool { (info.st_mode & S_IFMT) == S_IFDIR }
        // Items in one folder, by name: a copy or an unpacked archive sits
        // next to its original.
        var siblings: [String: Siblings] = [:]
        for (path, info) in meta {
            siblings[CleanupFS.parent(path), default: [:]][CleanupFS.name(path)] =
                (isFolder(info), isFolder(info) ? nil : Int64(info.st_size))
        }
        return meta.map { path, info in
            let name = CleanupFS.name(path)
            let kind = kind(of: path, isDir: isFolder(info))
            let bytes: Int64? = isFolder(info) ? nil : Int64(info.st_size)
            let (added, source) = found[path] ?? (nil, nil)
            let created = Date(timeIntervalSince1970: TimeInterval(info.st_birthtimespec.tv_sec))
            return Download(path: path, name: name, isDir: isFolder(info) && ext(path) != "app", bytes: bytes,
                            added: added ?? created, kind: kind, source: source,
                            hints: hints(name: name, kind: kind, bytes: bytes, siblings: siblings[CleanupFS.parent(path)] ?? [:], apps: apps))
        }
    }

    /// Folders Downloads lists that still need a size (apps included).
    public static func unmeasured(_ items: [Download]) -> [String] {
        items.filter { $0.bytes == nil }.map(\.path)
    }
}
