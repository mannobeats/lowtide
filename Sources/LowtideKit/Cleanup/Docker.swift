import Foundation

/// Docker's disk data as objects: every image, container, volume and the
/// build cache, with what uses what, so unused ones can be removed.
public struct DockerInventory: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        /// No `docker` command.
        case missing
        /// The daemon isn't answering.
        case stopped
        case running
    }

    public struct Image: Sendable, Identifiable, Hashable {
        public var id: String { reference }
        public let imageID: String
        /// What to remove by: `repository:tag`, or the id when untagged.
        /// Tags of one image share its id, and `docker image rm <id>`
        /// refuses an id several tags point to.
        public let reference: String
        public let repository: String
        public let tag: String
        public let bytes: Int64
        /// Bytes only this image holds (layers not shared).
        public let uniqueBytes: Int64?
        public let created: String
        /// Containers (running or stopped) built from it.
        public let containers: Int
        public let dangling: Bool
    }

    public struct Container: Sendable, Identifiable, Hashable {
        public let id: String
        public let name: String
        public let image: String
        public let state: String
        public let status: String
        public let bytes: Int64
        public let created: String
        public var running: Bool { state == "running" }
    }

    public struct Volume: Sendable, Identifiable, Hashable {
        public var id: String { name }
        public let name: String
        public let driver: String
        public let bytes: Int64?
        /// Containers mounting it; `nil` when Docker didn't say.
        public let links: Int?
        public let anonymous: Bool
    }

    public var state: State
    public var version: String?
    public var images: [Image] = []
    public var containers: [Container] = []
    public var volumes: [Volume] = []
    public var buildCacheBytes: Int64 = 0
    public var buildCacheReclaimable: Int64 = 0

    public init(state: State) { self.state = state }

    /// Bytes in images no container uses.
    public var unusedImageBytes: Int64 {
        images.filter { $0.containers == 0 }.reduce(0) { $0 + ($1.uniqueBytes ?? $1.bytes) }
    }
}

public enum Docker {
    public enum Kind: String, Sendable { case image, container, volume }

    /// `1.5GB`, `512MB`, `12.5kB`, `0B` (decimal, as Docker prints them).
    public static func parseSize(_ text: String) -> Int64? {
        guard let word = text.split(separator: " ").first,
              let split = word.firstIndex(where: { $0.isLetter }),
              let number = Double(word[..<split]) else { return nil }
        let scale: Double
        switch word[split...].uppercased() {
        case "B": scale = 1
        case "KB": scale = 1e3
        case "MB": scale = 1e6
        case "GB": scale = 1e9
        case "TB": scale = 1e12
        default: return nil
        }
        return Int64(number * scale)
    }

    private static func text(_ value: [String: Any], _ key: String) -> String {
        switch value[key] {
        case let text as String: text
        case let number as NSNumber: number.stringValue
        default: ""
        }
    }

    private static func number(_ value: [String: Any], _ key: String) -> Int? {
        switch value[key] {
        case let number as NSNumber: number.intValue
        case let text as String: Int(text)
        default: nil
        }
    }

    /// Reads `docker system df -v --format '{{json .}}'`.
    public static func parseInventory(_ json: Data) -> DockerInventory {
        var inventory = DockerInventory(state: .running)
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return inventory }
        func list(_ key: String) -> [[String: Any]] { root[key] as? [[String: Any]] ?? [] }
        inventory.images = list("Images").map { image in
            let repository = text(image, "Repository"), tag = text(image, "Tag"), id = text(image, "ID")
            return .init(imageID: id, reference: repository == "<none>" || tag == "<none>" ? id : "\(repository):\(tag)",
                         repository: repository, tag: tag, bytes: parseSize(text(image, "Size")) ?? 0,
                         uniqueBytes: parseSize(text(image, "UniqueSize")), created: text(image, "CreatedSince"),
                         containers: number(image, "Containers") ?? 0, dangling: repository == "<none>" && tag == "<none>")
        }
        inventory.containers = list("Containers").map { container in
            .init(id: text(container, "ID"), name: text(container, "Names"), image: text(container, "Image"),
                  state: text(container, "State"), status: text(container, "Status"),
                  bytes: parseSize(text(container, "Size")) ?? 0, created: text(container, "RunningFor"))
        }
        inventory.volumes = list("Volumes").map { volume in
            let name = text(volume, "Name")
            // Anonymous volumes are named by a 64-character hash.
            return .init(name: name, driver: text(volume, "Driver"), bytes: parseSize(text(volume, "Size")),
                         links: number(volume, "Links"), anonymous: name.count == 64 && name.allSatisfy(\.isHexDigit))
        }
        let cache = list("BuildCache")
        inventory.buildCacheBytes = cache.compactMap { parseSize(text($0, "Size")) }.reduce(0, +)
        inventory.buildCacheReclaimable = cache.filter { text($0, "InUse") != "true" }
            .compactMap { parseSize(text($0, "Size")) }.reduce(0, +)
        return inventory
    }

    /// A stopped or wedged daemon makes the CLI hang instead of failing,
    /// so every call is bounded.
    private static func docker(_ args: [String], timeout: Duration) async -> String? {
        guard let out = try? await Shell.run("docker", args, timeout: timeout), out.ok else { return nil }
        return out.stdout
    }

    public static func inventory() async -> DockerInventory {
        await Shell.ready()
        guard Shell.isAvailable("docker") else { return DockerInventory(state: .missing) }
        guard let version = await docker(["version", "--format", "{{.Server.Version}}"], timeout: .seconds(5)) else {
            return DockerInventory(state: .stopped)
        }
        guard let output = await docker(["system", "df", "-v", "--format", "{{json .}}"], timeout: .seconds(60)) else {
            return DockerInventory(state: .stopped)
        }
        var inventory = parseInventory(Data(output.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
        inventory.version = version.trimmingCharacters(in: .whitespacesAndNewlines)
        return inventory
    }

    /// An id or reference safe to pass as an argument (never a flag).
    public static func validReference(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("-") && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_.:/@-".contains($0)) }
    }

    /// Removes objects one by one so each failure (in use, has dependents)
    /// is reported against the object that caused it. Docker keeps no
    /// trash for these.
    public static func remove(_ kind: Kind, _ ids: [String]) async -> (removed: [String], failed: [(String, String)]) {
        await ToolLock.shared.with("docker") { () -> ([String], [(String, String)]) in
            var removed: [String] = []
            var failed: [(String, String)] = []
            for id in ids {
                guard validReference(id) else {
                    failed.append((id, "Not a valid id"))
                    continue
                }
                do {
                    let out = try await Shell.run("docker", [kind.rawValue, "rm", id], timeout: .seconds(120))
                    if out.ok {
                        removed.append(id)
                    } else {
                        failed.append((id, out.message.replacingOccurrences(of: "Error response from daemon: ", with: "")))
                    }
                } catch {
                    failed.append((id, error.localizedDescription))
                }
            }
            return (removed, failed)
        }
    }

    /// Clears the build cache: unused records, or everything with `all`.
    public static func pruneBuildCache(all: Bool) async throws {
        try await ToolLock.shared.with("docker") {
            _ = try await Shell.check("docker", ["builder", "prune", "--force"] + (all ? ["--all"] : []), timeout: .seconds(600))
        }
    }

    /// Starts Docker Desktop (or OrbStack) when the daemon is down.
    public static func start() async throws {
        for app in ["Docker", "OrbStack"] {
            if let out = try? await Shell.run("/usr/bin/open", ["-g", "-a", app], timeout: .seconds(20)), out.ok { return }
        }
        throw LowtideError.notFound("A Docker app to start")
    }
}
