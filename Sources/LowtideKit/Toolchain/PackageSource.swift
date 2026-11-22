import Foundation

/// One package manager Lowtide reads and drives. Each lives in its own
/// file under `Toolchain/Sources`; `PackageSources.all` lists them.
public protocol PackageSource: Sendable {
    var info: PackageSourceInfo { get }

    /// The tool is installed (and, for some, is one the person controls).
    func isAvailable() -> Bool

    /// Everything installed, with latest versions where they could be found.
    /// Not finalized: `PackageSources.scan` derives `outdated` and `bump`.
    func scan() async throws -> [ToolPackage]

    func details(_ packageID: String) async throws -> PackageDetails

    /// The command that updates one package to its latest version.
    func updateCommand(_ packageID: String) async throws -> Invocation

    /// The command that removes one package; nil when removal isn't a
    /// command (a Go binary goes to the Trash).
    func uninstallCommand(_ packageID: String) async throws -> Invocation?

    /// Removes one package, streaming what the manager prints.
    func uninstall(_ packageID: String, onLine: @escaping @Sendable (String) -> Void) async throws

    /// Why packages here can't be removed from Lowtide, if they can't.
    var removalRefusal: String? { get }

    /// The lock key uninstalls share with updates.
    var lock: String { get }
}

extension PackageSource {
    public func isAvailable() -> Bool { Shell.isAvailable(info.tool) }

    public func details(_ packageID: String) async throws -> PackageDetails {
        var details = PackageDetails(source: info.id, packageID: packageID)
        await PackageMetadata.enrich(source: info.id, name: PackageID.name(packageID), into: &details)
        return details
    }

    public var removalRefusal: String? { nil }

    public func uninstall(_ packageID: String, onLine: @escaping @Sendable (String) -> Void) async throws {
        guard let invocation = try await uninstallCommand(packageID) else { return }
        _ = try await ToolCommand.stream(invocation, onLine: onLine)
    }

    public var lock: String { info.tool }
}

/// The registry of package managers, in the order they are listed.
public enum PackageSources {
    public static let all: [any PackageSource] = [
        HomebrewSource(), MacAppStoreSource(), StandaloneSource(), NPMSource(), PNPMSource(), BunSource(),
        CargoSource(), GoSource(), PipxSource(), GemSource(), ComposerSource(),
    ]

    public static func source(_ id: String) -> (any PackageSource)? { all.first { $0.info.id == id } }

    /// Scans one source and derives what changed.
    public static func scan(_ id: String) async throws -> [ToolPackage] {
        guard let source = source(id) else { throw LowtideError.notFound("Package manager \(id)") }
        await Shell.ready()
        return ToolPackage.finalize(try await source.scan())
    }

    /// Forgets cached registry answers and asks Homebrew to refresh its
    /// taps on the next scan, so a person's "check again" really does.
    public static func forceRefresh() async {
        await LatestVersions.shared.invalidate()
        HomebrewSource.refreshTapsOnNextScan()
    }
}

/// Runs a package manager's command to the end, line by line.
enum ToolCommand {
    /// Streams `invocation`; a non-zero exit throws the line that explains it.
    static func stream(_ invocation: Invocation, onLine: @escaping @Sendable (String) -> Void) async throws -> CommandOutput {
        let out = try await Shell.stream(invocation.program, invocation.arguments, onLine: onLine)
        guard out.ok else {
            throw LowtideError.commandFailed(failureLine(out.stdout) ?? "\(invocation.program) exited with \(out.status)")
        }
        return out
    }

    /// stdout of a command that must succeed.
    @discardableResult
    static func output(_ program: String, _ arguments: [String]) async throws -> String {
        let out = try await Shell.run(program, arguments)
        guard out.ok else { throw LowtideError.commandFailed(out.message.isEmpty ? "\(program) failed" : out.message) }
        return out.stdout
    }

    /// The line that explains a failure: the last one that says so, else the
    /// last line printed.
    static func failureLine(_ log: String) -> String? {
        let lines = log.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let line = lines.last { line in
            let lower = line.lowercased()
            return lower.hasPrefix("error") || lower.contains("err!") || lower.contains("failed")
        } ?? lines.last
        guard let line else { return nil }
        return line.hasPrefix("Error: ") ? String(line.dropFirst(7)) : line
    }
}
