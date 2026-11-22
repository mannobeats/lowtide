import Foundation
import Security

/// Lowtide's own updates, from its GitHub releases. A check is one request to
/// GitHub's API for the latest published release (drafts and pre-releases are
/// never offered); nothing about this Mac is sent. An update installs only
/// when the download is a notarized app signed by the same developer team as
/// the running copy: the old copy goes to the Trash and the new one takes its
/// place, so macOS keeps its permission grants.
public enum SelfUpdate {
    /// Where releases are published, from Info.plist's `LowtideUpdateFeed`.
    public static var feed: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "LowtideUpdateFeed") as? String).flatMap(URL.init(string:))
    }

    public static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// A published release Lowtide can install.
    public struct Release: Sendable, Equatable, Codable {
        public var version: String
        public var title: String
        public var notes: String
        /// The release's page on GitHub.
        public var page: URL
        /// The zipped app (`Lowtide-<version>.zip`), replaced in place.
        public var archive: URL?
        /// The disk image, for people who install by hand.
        public var diskImage: URL?
        public var published: Date?

        public init(version: String, title: String, notes: String, page: URL, archive: URL?, diskImage: URL?, published: Date?) {
            self.version = version
            self.title = title
            self.notes = notes
            self.page = page
            self.archive = archive
            self.diskImage = diskImage
            self.published = published
        }
    }

    /// GitHub's release JSON, the parts that matter here.
    struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            var name: String
            var browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        var tagName: String
        var name: String?
        var body: String?
        var htmlURL: URL
        var draft: Bool
        var prerelease: Bool
        var publishedAt: Date?
        var assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name", name, body, htmlURL = "html_url", draft, prerelease
            case publishedAt = "published_at", assets
        }
    }

    /// The release in GitHub's JSON, or nil for a draft, a pre-release, or one
    /// with nothing to install.
    public static func release(from json: Data) -> Release? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let raw = try? decoder.decode(GitHubRelease.self, from: json), !raw.draft, !raw.prerelease else { return nil }
        var version = raw.tagName
        if version.first == "v" || version.first == "V" { version.removeFirst() }
        let archive = raw.assets.first { $0.name.hasPrefix("Lowtide") && $0.name.hasSuffix(".zip") }?.browserDownloadURL
        let image = raw.assets.first { $0.name.hasPrefix("Lowtide") && $0.name.hasSuffix(".dmg") }?.browserDownloadURL
        guard archive != nil || image != nil else { return nil }
        let title = raw.name.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 } ?? "Lowtide \(version)"
        return Release(version: version, title: title, notes: raw.body ?? "", page: raw.htmlURL, archive: archive,
                       diskImage: image, published: raw.publishedAt)
    }

    /// The latest release when it's newer than `installed`, else nil.
    public static func check(feed: URL, installed: String) async throws -> Release? {
        let (data, response) = try await HTTP.session.data(from: feed)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // No release published yet: nothing newer.
        if status == 404 { return nil }
        guard (200..<300).contains(status) else { throw LowtideError.commandFailed("GitHub answered \(status)") }
        guard let release = release(from: data) else { return nil }
        return AppVersion.isNewer(release.version, than: installed) ? release : nil
    }

    // MARK: Installing

    /// The developer team that signed a bundle, when it's signed by Apple's
    /// chain with one (not ad hoc, not a local development signature).
    public static func team(of bundle: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// The running copy's team: updates install only over a signed copy.
    public static var runningTeam: String? { team(of: Bundle.main.bundleURL) }

    /// Whether this copy can update itself: signed with a Developer ID and
    /// somewhere it can be replaced.
    public static var canInstall: Bool {
        runningTeam != nil && FileManager.default.isWritableFile(atPath: Bundle.main.bundleURL.deletingLastPathComponent().path)
    }

    /// The bundle passes macOS's strict signature check, is signed by `team`
    /// with a Developer ID, and Gatekeeper accepts it (notarized).
    public static func verify(_ app: URL, team: String) async throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw LowtideError.invalid("The download isn't an app.")
        }
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
            + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else {
            throw LowtideError.invalid("The signing requirement couldn't be made.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw LowtideError.denied("The download isn't signed by Lowtide's developer, so it wasn't installed.")
        }
        let gatekeeper = try await Shell.run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path], timeout: .seconds(60))
        guard gatekeeper.ok else { throw LowtideError.denied("macOS didn't accept the download (not notarized), so it wasn't installed.") }
    }

    /// Downloads the release's archive, unpacks and verifies it, then moves
    /// `installed` to the Trash and puts the new app where it was. Returns the
    /// new app's location. `progress` gets 0…1 while downloading.
    public static func install(_ release: Release, over installed: URL, team: String,
                               progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        guard let archive = release.archive else { throw LowtideError.notFound("An app to download in this release") }
        let work = FileManager.default.temporaryDirectory.appending(path: "lowtide-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let zip = work.appending(path: "Lowtide.zip")
        try await download(archive, to: zip, progress: progress)
        let unpacked = work.appending(path: "unpacked")
        try await Shell.check("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path], timeout: .seconds(300))
        let apps = (try? FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)) ?? []
        guard let app = apps.first(where: { $0.pathExtension == "app" }) else { throw LowtideError.notFound("Lowtide.app in the download") }
        try await verify(app, team: team)

        // The new copy goes beside the old one first (same volume, so the
        // swap is a rename), then the old one to the Trash.
        let staged = installed.deletingLastPathComponent().appending(path: ".Lowtide-\(release.version).app")
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.copyItem(at: app, to: staged)
        do {
            try FileManager.default.trashItem(at: installed, resultingItemURL: nil)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw LowtideError.denied("The current copy couldn't be moved to the Trash: \(error.localizedDescription)")
        }
        try FileManager.default.moveItem(at: staged, to: installed)
        return installed
    }

    /// Streams the download to `destination`, reporting how much has arrived
    /// (the async download API never calls a delegate's progress).
    private static func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        // The app with its helpers is large: more time than a check gets.
        let config = HTTP.session.configuration
        config.timeoutIntervalForResource = 30 * 60
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LowtideError.commandFailed("GitHub answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw LowtideError.denied("The download couldn't be saved.")
        }
        let file = try FileHandle(forWritingTo: destination)
        defer { try? file.close() }
        let expected = Double(max(response.expectedContentLength, 0))
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var written = 0.0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try file.write(contentsOf: buffer)
                written += Double(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if expected > 0 { progress(min(written / expected, 1)) }
            }
        }
        try file.write(contentsOf: buffer)
        progress(1)
    }
}
