import Foundation

/// The newest release a feed offers.
public struct FeedRelease: Sendable, Equatable {
    /// Compared with the installed app (Sparkle: the build number).
    public var build: String
    /// Shown to people.
    public var version: String
    public var notes: String?
    public var notesURL: String?
    public var size: Int64?
    public var released: String?
    public var url: String?
    public var sha512: String?

    public init(build: String, version: String, notes: String? = nil, notesURL: String? = nil, size: Int64? = nil,
                released: String? = nil, url: String? = nil, sha512: String? = nil) {
        self.build = build
        self.version = version
        self.notes = notes
        self.notesURL = notesURL
        self.size = size
        self.released = released
        self.url = url
        self.sha512 = sha512
    }
}

/// Where each kind of app announces its next version, and how to read it:
/// Sparkle appcasts, electron-builder's `latest-mac.yml`, and the App Store.
public enum UpdateFeeds {
    static let sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"

    /// The newest item of a Sparkle appcast this macOS can run, skipping
    /// beta channels and informational-only entries, as Sparkle itself does.
    public static func appcast(_ data: Data, os: String) -> FeedRelease? {
        guard let doc = try? XMLDocument(data: data, options: []), let root = doc.rootElement() else { return nil }
        var best: FeedRelease?
        for item in elements(named: "item", in: root) {
            let children = item.children?.compactMap { $0 as? XMLElement } ?? []
            func sparkleText(_ name: String) -> String? {
                children.first { $0.localName == name && $0.uri == sparkle }?
                    .stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            }
            func plain(_ name: String) -> XMLElement? {
                children.first { $0.localName == name && ($0.uri ?? "").isEmpty }
            }
            if sparkleText("channel") != nil || children.contains(where: { $0.localName == "informationalUpdate" }) { continue }
            if let minimum = sparkleText("minimumSystemVersion"), AppVersion.compare(minimum, os) == .orderedDescending { continue }
            let enclosure = plain("enclosure")
            func attribute(_ name: String) -> String? {
                enclosure?.attribute(forLocalName: name, uri: sparkle)?.stringValue?.trimmingCharacters(in: .whitespaces).nonEmpty
            }
            guard let build = sparkleText("version") ?? attribute("version") else { continue }
            if let best, AppVersion.compare(build, best.build) != .orderedDescending { continue }
            best = FeedRelease(
                build: build,
                version: sparkleText("shortVersionString") ?? attribute("shortVersionString") ?? build,
                notes: plain("description")?.stringValue.map(htmlToText)?.nonEmpty,
                notesURL: sparkleText("releaseNotesLink"),
                size: enclosure?.attribute(forName: "length")?.stringValue.flatMap { Int64($0) }.flatMap { $0 > 0 ? $0 : nil },
                released: plain("pubDate")?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
                url: enclosure?.attribute(forName: "url")?.stringValue
            )
        }
        return best
    }

    static func elements(named name: String, in element: XMLElement) -> [XMLElement] {
        var out: [XMLElement] = []
        for child in element.children ?? [] {
            guard let child = child as? XMLElement else { continue }
            if child.localName == name { out.append(child) }
            out += elements(named: name, in: child)
        }
        return out
    }

    /// Plain `key: value` pairs of a flat YAML file (quotes removed).
    static func yamlKeys(_ text: String) -> [String: String] {
        var keys: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let first = line.first, ![" ", "-", "#", "\t"].contains(first), let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            if keys[key] == nil { keys[key] = unquote(line[line.index(after: colon)...]) }
        }
        return keys
    }

    static func unquote<S: StringProtocol>(_ value: S) -> String {
        value.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
    }

    /// Where an electron-builder app looks for updates, from its `app-update.yml`.
    public static func electronFeed(_ config: String) -> String? {
        let keys = yamlKeys(config)
        func get(_ key: String) -> String? { keys[key].flatMap { $0.isEmpty || $0 == "null" ? nil : $0 } }
        let base: String
        switch get("provider") {
        case "github":
            guard let owner = get("owner"), let repo = get("repo") else { return nil }
            base = "https://github.com/\(owner)/\(repo)/releases/latest/download/"
        case "generic":
            guard let url = get("url") else { return nil }
            base = url
        case "s3":
            guard let bucket = get("bucket") else { return nil }
            let root = get("endpoint").map { "\($0.trimmingSuffix("/"))/\(bucket)" } ?? "https://\(bucket).s3.amazonaws.com"
            base = get("path").map { "\(root)/\($0.trimmingCharacters(in: CharacterSet(charactersIn: "/")))" } ?? root
        case "spaces":
            guard let name = get("name"), let region = get("region") else { return nil }
            base = "https://\(name).\(region).digitaloceanspaces.com"
        default:
            return nil
        }
        return "\(base.trimmingSuffix("/"))/\(get("channel") ?? "latest")-mac.yml"
    }

    /// The release in a `latest-mac.yml`, picking the download for this
    /// Mac's architecture (a zip over a disk image).
    public static func electronRelease(_ text: String, feedURL: String, arch: String = currentArch) -> FeedRelease? {
        let keys = yamlKeys(text)
        guard let version = keys["version"]?.nonEmpty else { return nil }
        var files: [(url: String, sha: String?, size: Int64?)] = []
        for raw in text.split(separator: "\n") {
            let line = raw.drop { $0 == " " || $0 == "\t" }
            if line.hasPrefix("- url:") {
                files.append((unquote(line.dropFirst(6)), nil, nil))
            } else if !files.isEmpty {
                if line.hasPrefix("sha512:") { files[files.count - 1].sha = unquote(line.dropFirst(7)) }
                else if line.hasPrefix("size:") { files[files.count - 1].size = Int64(unquote(line.dropFirst(5))) }
            }
        }
        let other = arch == "arm64" ? "x64" : "arm64"
        func rank(_ url: String) -> Int {
            let lower = url.lowercased()
            let fits = lower.contains(arch) ? 0 : (lower.contains(other) || lower.contains("x86_64")) ? 9 : 1
            return fits * 2 + (lower.hasSuffix(".zip") ? 0 : 1)
        }
        let file = files.filter { $0.url.lowercased().hasSuffix(".zip") || $0.url.lowercased().hasSuffix(".dmg") }
            .min { rank($0.url) < rank($1.url) }
            .flatMap { rank($0.url) < 18 ? $0 : nil }
        let base = feedURL.range(of: "/", options: .backwards).map { String(feedURL[..<$0.upperBound]) } ?? ""
        let notes = keys["releaseNotes"].map(htmlToText).flatMap { $0.isEmpty || $0 == "|" || $0 == ">" ? nil : $0 }
        return FeedRelease(
            build: version, version: version, notes: notes, released: keys["releaseDate"],
            url: file.map { $0.url.hasPrefix("https://") ? $0.url : base + $0.url }
        ).with(size: file?.size, sha512: file?.sha)
    }

    public static var currentArch: String {
        #if arch(arm64)
        "arm64"
        #else
        "x64"
        #endif
    }

    /// The App Store's current release, and the app's store id.
    public static func storeRelease(_ data: Data) -> (FeedRelease, Int)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let app = (json["results"] as? [[String: Any]])?.first,
              let version = app["version"] as? String,
              let id = (app["trackId"] as? NSNumber)?.intValue
        else { return nil }
        return (FeedRelease(
            build: version, version: version,
            notes: (app["releaseNotes"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            size: (app["fileSizeBytes"] as? String).flatMap { Int64($0) },
            released: app["currentVersionReleaseDate"] as? String
        ), id)
    }

    /// Release notes as readable text: paragraphs and list items kept, tags
    /// and the common entities removed.
    public static func htmlToText(_ html: String) -> String {
        var out = ""
        var rest = Substring(html)
        while let start = rest.firstIndex(of: "<") {
            out += rest[..<start]
            guard let end = rest[start...].firstIndex(of: ">") else {
                rest = ""
                break
            }
            let tag = rest[rest.index(after: start)..<end].trimmingCharacters(in: .whitespaces).lowercased()
            let name = tag.drop { $0 == "/" }.split(whereSeparator: { $0 == " " || $0 == "/" }).first.map(String.init) ?? ""
            if name == "li", !tag.hasPrefix("/") {
                out += "\n• "
            } else if ["br", "p", "div", "ul", "ol", "h1", "h2", "h3", "h4", "tr"].contains(name) {
                out += "\n"
            }
            rest = rest[rest.index(after: end)...]
        }
        out += rest
        let decoded = out
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&rsquo;", with: "’")
            .replacingOccurrences(of: "&amp;", with: "&")
        var text = ""
        var blank = 0
        for raw in decoded.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                blank += 1
                continue
            }
            if !text.isEmpty { text += blank > 0 && !line.hasPrefix("•") ? "\n\n" : "\n" }
            text += line
            blank = 0
        }
        return text
    }
}

extension FeedRelease {
    func with(size: Int64?, sha512: String?) -> FeedRelease {
        var copy = self
        copy.size = size
        copy.sha512 = sha512
        return copy
    }
}

// File-private: other areas share this module and may name theirs alike.
fileprivate extension String {
    var nonEmpty: String? { isEmpty ? nil : self }

    func trimmingSuffix(_ suffix: Character) -> String {
        var copy = self
        while copy.last == suffix { copy.removeLast() }
        return copy
    }
}
