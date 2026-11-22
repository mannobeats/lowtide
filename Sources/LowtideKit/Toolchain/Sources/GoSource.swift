import Foundation

/// Binaries installed with `go install`, read from the build info Go stamps
/// into each one.
public struct GoSource: PackageSource {
    public let info = PackageSourceInfo(id: "go", name: "Go", icon: "go", tool: "go",
                                        description: "Binaries installed with go install")
    public init() {}

    struct Binary: Sendable, Equatable {
        var name: String
        /// The package path `go install` needs (`…/cmd/golangci-lint`),
        /// which isn't the module path for binaries built from sub-packages.
        var package: String = ""
        var module: String = ""
        var version: String = ""

        /// Built from a release, not a checkout (`(devel)`).
        var isReleased: Bool { !module.isEmpty && version.hasPrefix("v") }
    }

    /// `go env GOBIN GOPATH`: GOBIN when set, else `$GOPATH/bin`.
    static func binDirectory() async -> URL? {
        guard let out = try? await Shell.run("go", ["env", "GOBIN", "GOPATH"]), out.ok else { return nil }
        let lines = out.stdout.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if let gobin = lines.first, !gobin.isEmpty { return URL(fileURLWithPath: gobin) }
        guard lines.count > 1, let gopath = lines[1].split(separator: ":").first, !gopath.isEmpty else { return nil }
        return URL(fileURLWithPath: String(gopath)).appending(path: "bin")
    }

    /// `go version -m <dir-or-file>`: a `<file>: <go version>` header per
    /// binary, then tab-indented `path`, `mod`, `dep` and `build` lines.
    static func parseBuildInfo(_ stdout: String) -> [Binary] {
        var binaries: [Binary] = []
        for line in stdout.split(separator: "\n") {
            if !line.hasPrefix("\t") {
                if let colon = line.range(of: ": ", options: .backwards) {
                    let file = line[..<colon.lowerBound]
                    binaries.append(Binary(name: String(file.split(separator: "/").last ?? file)))
                }
                continue
            }
            guard !binaries.isEmpty else { continue }
            let columns = line.trimmingCharacters(in: .whitespaces).split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            switch columns.first {
            case "path" where columns.count > 1:
                binaries[binaries.count - 1].package = columns[1]
            case "mod" where columns.count > 2:
                binaries[binaries.count - 1].module = columns[1]
                binaries[binaries.count - 1].version = columns[2]
            default: break
            }
        }
        return binaries.filter { !$0.package.isEmpty }
    }

    /// The `GONOPROXY` patterns (Go defaults them to `GOPRIVATE`), or nil
    /// when `GOPROXY` doesn't use proxy.golang.org at all: then nothing is
    /// asked there, as Go itself wouldn't.
    static func proxyExclusions() async -> [String]? {
        guard let out = try? await Shell.run("go", ["env", "GOPROXY", "GONOPROXY"]), out.ok else { return nil }
        return parseProxyExclusions(out.stdout)
    }

    static func parseProxyExclusions(_ stdout: String) -> [String]? {
        let lines = stdout.split(separator: "\n", omittingEmptySubsequences: false)
        guard let proxy = lines.first, proxy.contains("proxy.golang.org") else { return nil }
        guard lines.count > 1 else { return [] }
        return lines[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Go's prefix rule: a pattern matches a module whose leading path
    /// elements match it element by element (`github.com/acme/*`).
    static func excluded(_ patterns: [String], module: String) -> Bool {
        let parts = module.split(separator: "/", omittingEmptySubsequences: false)
        return patterns.contains { pattern in
            let elements = pattern.split(separator: "/", omittingEmptySubsequences: false)
            return parts.count >= elements.count && zip(elements, parts).allSatisfy { glob(Array($0.utf8), Array($1.utf8)) }
        }
    }

    /// `*` and `?` within one path element. `[…]` classes count as a match,
    /// so such a pattern errs on the private side.
    static func glob(_ pattern: [UInt8], _ text: [UInt8]) -> Bool {
        guard let p = pattern.first else { return text.isEmpty }
        if p == UInt8(ascii: "[") { return true }
        if p == UInt8(ascii: "*") {
            return glob(Array(pattern.dropFirst()), text) || (!text.isEmpty && glob(pattern, Array(text.dropFirst())))
        }
        guard let t = text.first else { return false }
        if p == UInt8(ascii: "?") || p == t { return glob(Array(pattern.dropFirst()), Array(text.dropFirst())) }
        return false
    }

    public func scan() async throws -> [ToolPackage] {
        guard let directory = await Self.binDirectory(),
              FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let out = try await Shell.run("go", ["version", "-m", directory.path])
        let binaries = Self.parseBuildInfo(out.stdout)
        // Private modules (`GOPRIVATE`) never reach the public proxy.
        let exclusions = await Self.proxyExclusions()
        let modules = binaries.filter { binary in
            binary.isReleased && exclusions.map { !Self.excluded($0, module: binary.module) } == true
        }.map(\.module)
        let latest = await LatestVersions.shared.resolve(.goProxy, Array(Set(modules)))
        return binaries.map { binary in
            ToolPackage(id: "go:\(binary.name)", name: binary.name, currentVersion: binary.version,
                        description: binary.module.isEmpty ? binary.package : binary.module)
                .withLatest(binary.isReleased ? latest[binary.module] : nil)
        }
    }

    static func binaryName(_ packageID: String) throws -> String {
        let name = try PackageID.strip(packageID, prefix: "go")
        guard !name.contains("/"), name != ".", name != ".." else { throw LowtideError.invalid("Invalid Go binary \(name)") }
        return name
    }

    static func binary(_ name: String) async throws -> (URL, Binary) {
        guard let directory = await binDirectory() else { throw LowtideError.commandFailed("Couldn't find GOBIN") }
        let file = directory.appending(path: name)
        let out = try await Shell.run("go", ["version", "-m", file.path])
        guard let binary = parseBuildInfo(out.stdout).first else { throw LowtideError.commandFailed("\(name) isn't a Go binary") }
        return (file, binary)
    }

    /// Ids are binary names; registry metadata is keyed by module path.
    public func details(_ packageID: String) async throws -> PackageDetails {
        let (file, binary) = try await Self.binary(try Self.binaryName(packageID))
        var details = PackageDetails(source: "go", packageID: "go:\(binary.module)")
        details.installPath = file.path
        if let patterns = await Self.proxyExclusions(), !Self.excluded(patterns, module: binary.module), binary.isReleased {
            await PackageMetadata.enrich(source: "go", name: binary.module, into: &details)
        }
        return details
    }

    public func updateCommand(_ packageID: String) async throws -> Invocation {
        let (_, binary) = try await Self.binary(try Self.binaryName(packageID))
        return Invocation("go", ["install", "\(binary.package)@latest"])
    }

    public func uninstallCommand(_ packageID: String) async throws -> Invocation? { nil }

    /// Go has no uninstall: the binary goes to the Trash (Put Back works),
    /// after confirming it really is a Go binary.
    public func uninstall(_ packageID: String, onLine: @escaping @Sendable (String) -> Void) async throws {
        let (file, _) = try await Self.binary(try Self.binaryName(packageID))
        onLine("Moving \(Paths.tilde(file.path)) to the Trash")
        if let refusal = await Trash.move([file.path]).refused.first { throw LowtideError.denied(refusal.reason) }
    }
}
