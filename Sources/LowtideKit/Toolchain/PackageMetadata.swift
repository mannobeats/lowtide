import Foundation

/// Fills a package's details from its public registry (description,
/// links, license, latest release). Failures leave the details as they are:
/// the panel says the registry publishes nothing more.
enum PackageMetadata {
    static func enrich(source: String, name: String, into details: inout PackageDetails) async {
        let address: String
        switch source {
        case "npm", "pnpm", "bun": address = "https://registry.npmjs.org/\(name.replacingOccurrences(of: "/", with: "%2F"))/latest"
        case "cargo": address = "https://crates.io/api/v1/crates/\(name)"
        case "pipx": address = "https://pypi.org/pypi/\(name)/json"
        case "gem": address = "https://rubygems.org/api/v1/gems/\(name).json"
        case "go": address = "https://proxy.golang.org/\(LatestVersions.goModuleEscape(name))/@latest"
        case "mas":
            guard name.allSatisfy(\.isNumber) else { return }
            address = "https://itunes.apple.com/lookup?id=\(name)"
        default: return
        }
        guard let data = try? await LatestVersions.get(address, timeout: 6),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        apply(source: source, json: json, to: &details)
    }

    /// Reads one registry's answer. Separate from the fetch so it's tested
    /// with real responses.
    static func apply(source: String, json: [String: Any], to details: inout PackageDetails) {
        func string(_ object: [String: Any]?, _ key: String) -> String? {
            (object?[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        switch source {
        case "npm", "pnpm", "bun":
            details.description = string(json, "description")
            details.homepage = string(json, "homepage")
            details.license = (json["license"] as? String) ?? ((json["license"] as? [String: Any])?["type"] as? String)
            details.repository = ((json["repository"] as? [String: Any])?["url"] as? String).map(cleanGitURL)
                ?? (json["repository"] as? String).map(cleanGitURL)
            details.dependencies = ((json["dependencies"] as? [String: Any])?.keys).map { $0.sorted() } ?? []
            details.addVersion(string(json, "version"))
        case "cargo":
            let krate = json["crate"] as? [String: Any]
            details.description = string(krate, "description")
            details.homepage = string(krate, "homepage")
            details.repository = string(krate, "repository")
            details.documentation = string(krate, "documentation")
            details.license = string(krate, "license")
            let latest = string(krate, "max_version") ?? string(krate, "newest_version")
            details.addVersion(latest)
            if let latest, let versions = json["versions"] as? [[String: Any]],
               let version = versions.first(where: { $0["num"] as? String == latest }) {
                details.latestReleaseDate = string(version, "created_at")
                details.license = details.license ?? string(version, "license")
            }
        case "pipx":
            let info = json["info"] as? [String: Any]
            details.description = string(info, "summary")
            details.homepage = string(info, "home_page")
            details.license = string(info, "license_expression") ?? string(info, "license").flatMap { $0.count > 80 ? nil : $0 }
            let urls = info?["project_urls"] as? [String: Any] ?? [:]
            func projectURL(_ label: String) -> String? {
                urls.first { $0.key.caseInsensitiveCompare(label) == .orderedSame }?.value as? String
            }
            details.repository = projectURL("Source") ?? projectURL("Repository") ?? projectURL("Code")
            details.documentation = projectURL("Documentation")
            details.homepage = details.homepage ?? projectURL("Homepage")
            let latest = string(info, "version")
            details.addVersion(latest)
            if let latest, let release = ((json["releases"] as? [String: Any])?[latest] as? [[String: Any]])?.first {
                details.latestReleaseDate = string(release, "upload_time_iso_8601")
            }
        case "gem":
            details.description = string(json, "info")
            details.homepage = string(json, "homepage_uri")
            details.repository = string(json, "source_code_uri")
            details.documentation = string(json, "documentation_uri")
            let licenses = (json["licenses"] as? [String]) ?? []
            details.license = licenses.isEmpty ? nil : licenses.joined(separator: ", ")
            details.latestReleaseDate = string(json, "version_created_at")
            details.addVersion(string(json, "version"))
        case "go":
            details.addVersion(string(json, "Version"))
            details.latestReleaseDate = string(json, "Time")
            details.repository = ((json["Origin"] as? [String: Any])?["URL"] as? String).map(cleanGitURL)
        case "mas":
            guard let app = (json["results"] as? [[String: Any]])?.first else { return }
            details.description = string(app, "description")
            details.homepage = string(app, "sellerUrl")
            details.license = string(app, "contentAdvisoryRating")
            details.latestReleaseDate = string(app, "currentVersionReleaseDate")
            details.releaseNotes = string(app, "releaseNotes")
            details.addVersion(string(app, "version"))
        default: break
        }
    }

    /// `git+https://github.com/x/y.git` → `https://github.com/x/y`.
    static func cleanGitURL(_ url: String) -> String {
        var url = url
        if url.hasPrefix("git+") { url.removeFirst(4) }
        if url.hasPrefix("git://") { url = "https://" + url.dropFirst(6) }
        if url.hasSuffix(".git") { url.removeLast(4) }
        return url
    }
}
