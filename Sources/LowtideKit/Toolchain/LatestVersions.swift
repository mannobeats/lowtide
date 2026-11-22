import Foundation

/// The public registries asked for latest versions, for managers with no
/// reliable `outdated` command of their own.
public enum PackageRegistry: String, Sendable {
    case npm, crates, pypi, goProxy
}

/// Latest-version lookups straight from each ecosystem's registry, cached
/// for 15 minutes. These are update checks: only package names leave the Mac.
public actor LatestVersions {
    public static let shared = LatestVersions()

    static let ttl: TimeInterval = 15 * 60
    static let timeout: TimeInterval = 8
    /// Registries rate-limit bursts; a handful in flight is plenty.
    static let parallel = 6

    private var cache: [String: (at: Date, version: String?)] = [:]

    public func invalidate() { cache.removeAll() }

    /// Latest stable version for each name; names that couldn't be checked
    /// (offline, unknown to the registry) are missing from the result.
    public nonisolated func resolve(_ registry: PackageRegistry, _ names: [String]) async -> [String: String] {
        await withTaskGroup(of: (String, String?).self) { group in
            var found: [String: String] = [:]
            var pending = names[...]
            func next() {
                guard let name = pending.popFirst() else { return }
                group.addTask { (name, await self.latest(registry, name)) }
            }
            for _ in 0..<Self.parallel { next() }
            while let (name, version) = await group.next() {
                if let version { found[name] = version }
                next()
            }
            return found
        }
    }

    public func latest(_ registry: PackageRegistry, _ name: String) async -> String? {
        let key = "\(registry.rawValue):\(name)"
        if let hit = cache[key], Date().timeIntervalSince(hit.at) < Self.ttl { return hit.version }
        do {
            let version = try await Self.fetch(registry, name)
            cache[key] = (Date(), version)
            return version
        } catch {
            // Not cached: a network blip must not hide updates for 15 min.
            return nil
        }
    }

    static func fetch(_ registry: PackageRegistry, _ name: String) async throws -> String? {
        switch registry {
        case .npm:
            let data = try await get("https://registry.npmjs.org/-/package/\(name.replacingOccurrences(of: "/", with: "%2F"))/dist-tags")
            return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["latest"] as? String
        case .crates:
            let data = try await get("https://index.crates.io/\(crateIndexPath(name))")
            return newestCrate(String(decoding: data, as: UTF8.self))
        case .pypi:
            let data = try await get("https://pypi.org/pypi/\(name)/json")
            let info = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["info"] as? [String: Any]
            return info?["version"] as? String
        case .goProxy:
            let data = try await get("https://proxy.golang.org/\(goModuleEscape(name))/@latest")
            let version = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["Version"] as? String
            return version.flatMap { PackageVersion.isPrerelease($0) ? nil : $0 }
        }
    }

    /// One GET with a short timeout, through the app's only HTTP client.
    static func get(_ address: String, timeout: TimeInterval = timeout) async throws -> Data {
        guard let url = URL(string: address) else { throw LowtideError.invalid("Bad address \(address)") }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        let (data, response) = try await HTTP.session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LowtideError.commandFailed("\(url.host() ?? "registry") answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return data
    }

    /// The sparse index layout: `1/a`, `2/ab`, `3/a/abc`, `ab/cd/abcd…`.
    static func crateIndexPath(_ name: String) -> String {
        let lower = name.lowercased()
        switch lower.count {
        case 1: return "1/\(lower)"
        case 2: return "2/\(lower)"
        case 3: return "3/\(lower.prefix(1))/\(lower)"
        default: return "\(lower.prefix(2))/\(lower.dropFirst(2).prefix(2))/\(lower)"
        }
    }

    /// The sparse index is the data Cargo itself resolves against: one JSON
    /// line per published version. Newest stable, not yanked.
    static func newestCrate(_ index: String) -> String? {
        let versions = index.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard let entry = JSONValue.object(String(line)), (entry["yanked"] as? Bool) != true,
                  let version = entry["vers"] as? String, !PackageVersion.isPrerelease(version) else { return nil }
            return version
        }
        return PackageVersion.newest(versions)
    }

    /// The module proxy spells uppercase letters as `!` + lowercase.
    static func goModuleEscape(_ module: String) -> String {
        module.map { $0.isUppercase ? "!\($0.lowercased())" : String($0) }.joined()
    }
}
