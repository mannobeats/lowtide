import AppKit
import Foundation

/// What an app or plug-in bundle's Info.plist says about it.
public struct BundleInfo: Sendable, Equatable {
    public var bundleID: String?
    public var name: String?
    public var displayName: String?
    public var executable: String?
    /// `CFBundleShortVersionString`, else `CFBundleVersion`.
    public var version: String?
    public var build: String?
    public var feedURL: String?
}

/// App and plug-in bundles: their Info.plist, the apps installed on the
/// Mac, bundle-id vendors, and quitting a running app.
public enum AppBundles {
    /// A bundle's Info.plist as a loose dictionary: some apps repeat a key
    /// (Native Instruments' do `CFBundleIdentifier`), which macOS shrugs off.
    public static func infoDictionary(_ bundle: URL) -> [String: Any]? {
        for candidate in [bundle.appending(path: "Contents/Info.plist"), bundle.appending(path: "Info.plist")] {
            guard let data = try? Data(contentsOf: candidate),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { continue }
            return plist
        }
        return nil
    }

    /// A string value, trimmed; nil when missing or blank.
    public static func string(_ info: [String: Any], _ key: String) -> String? {
        guard let text = (info[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    public static func read(path: String) -> BundleInfo? { read(URL(fileURLWithPath: path)) }

    public static func read(_ bundle: URL) -> BundleInfo? {
        guard let info = infoDictionary(bundle) else { return nil }
        return parse(info)
    }

    public static func parse(_ info: [String: Any]) -> BundleInfo {
        let text = { (key: String) in string(info, key) }
        return BundleInfo(
            bundleID: text("CFBundleIdentifier"),
            name: text("CFBundleName"),
            displayName: text("CFBundleDisplayName"),
            executable: text("CFBundleExecutable"),
            version: text("CFBundleShortVersionString") ?? text("CFBundleVersion"),
            build: text("CFBundleVersion"),
            feedURL: text("SUFeedURL")
        )
    }

    /// Where installed apps sit, as the uninstaller offers them.
    public static var roots: [URL] {
        [URL(fileURLWithPath: "/Applications"), Paths.home.appending(path: "Applications")]
    }

    /// The apps in `/Applications` and `~/Applications` and their folders,
    /// `depth` levels down (vendors keep theirs in subfolders:
    /// `/Applications/Native Instruments/…`, Setapp). Never looks inside an
    /// app or follows a linked folder, so a copy on another disk or a system
    /// app is never offered for removal. Sorted.
    public static func appPaths(depth: Int = 2, roots: [URL]? = nil) -> [URL] {
        var out: [URL] = []
        for root in roots ?? Self.roots { appsUnder(root, depth: depth, into: &out) }
        var seen = Set<String>()
        return out.filter { seen.insert($0.path).inserted }.sorted { $0.path < $1.path }
    }

    static func appsUnder(_ dir: URL, depth: Int, into out: inout [URL]) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names {
            let url = dir.appending(path: name)
            var info = stat()
            // lstat: a link is neither an app here nor a folder to walk.
            let isDir = lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
            if name.hasSuffix(".app") {
                if isDir { out.append(url) }
            } else if depth > 0, isDir {
                appsUnder(url, depth: depth - 1, into: &out)
            }
        }
    }

    /// Folders that hold no helper apps of their own, or too many files to walk.
    static let notHelpers: Set<String> = ["Resources", "_CodeSignature", "node_modules", "jbr", "lib", "plugins", "Java", "SharedSupport"]

    /// The apps, login items and extensions inside an app, as (file name
    /// without extension, bundle id): `Docker Desktop.app` inside Docker,
    /// whose id names the caches Docker keeps. Frameworks are skipped: Sparkle
    /// and Electron ship the same ones in every app.
    public static func nestedBundles(_ bundle: URL) -> [(name: String, id: String?)] {
        var out: [(String, String?)] = []
        var seen = 0
        func walk(_ dir: URL, _ depth: Int) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
            for name in names {
                guard seen < 2000 else { return }
                let url = dir.appending(path: name)
                var info = stat()
                guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { continue }
                seen += 1
                if [".framework", ".bundle", ".lproj", ".dSYM"].contains(where: name.hasSuffix) || notHelpers.contains(name) { continue }
                if let ext = [".app", ".xpc", ".appex"].first(where: name.hasSuffix) {
                    let id = infoDictionary(url).flatMap { string($0, "CFBundleIdentifier") }
                    out.append((String(name.dropLast(ext.count)), id))
                }
                if depth > 0 { walk(url, depth - 1) }
            }
        }
        walk(bundle.appending(path: "Contents"), 6)
        return out
    }

    /// The vendor part of a bundle id, lowercase (`com.adobe` of
    /// `com.adobe.Photoshop`); nil for ids too short to have a product.
    public static func vendorPrefix(_ bundleID: String) -> String? {
        let parts = bundleID.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        return parts.prefix(2).joined(separator: ".").lowercased()
    }

    /// Letters and digits only, lowercase: `Pro-Q 3` gives `proq3`.
    public static func alnum(_ value: String) -> String {
        String(value.unicodeScalars.filter { $0.isASCII && CharacterSet.alphanumerics.contains($0) }.map(Character.init)).lowercased()
    }

    /// Installed from the Mac App Store.
    public static func fromAppStore(_ app: URL) -> Bool {
        FileManager.default.fileExists(atPath: app.appending(path: "Contents/_MASReceipt/receipt").path)
    }

    /// Apple's own apps and Lowtide itself can't be removed here.
    public static func isProtected(_ app: URL, bundleID: String?) -> Bool {
        let apple = bundleID?.hasPrefix("com.apple.") ?? false
        return app.path.hasPrefix("/System/") || (apple && !fromAppStore(app)) || bundleID == Paths.bundleID
    }

    public static func isRunning(_ bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { !$0.isTerminated }
    }

    /// Asks every running copy of the app to quit, as its Quit menu would (it
    /// may still ask to save), then waits up to `wait`. Returns whether it is
    /// no longer running.
    @discardableResult
    public static func quit(_ bundleID: String, wait: Duration = .zero) async -> Bool {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) { app.terminate() }
        let deadline = ContinuousClock.now + wait
        while isRunning(bundleID) {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return true
    }

    /// The Developer ID team that signed a bundle (`codesign -dv`).
    public static func teamID(_ bundle: URL) async -> String? {
        guard let out = try? await Shell.run("/usr/bin/codesign", ["-dv", bundle.path], timeout: .seconds(30)) else { return nil }
        return parseTeamID(out.stderr)
    }

    static func parseTeamID(_ text: String) -> String? {
        text.split(separator: "\n").lazy
            .compactMap { $0.hasPrefix("TeamIdentifier=") ? String($0.dropFirst("TeamIdentifier=".count)) : nil }
            .first { $0 != "not set" && !$0.isEmpty }
    }
}
