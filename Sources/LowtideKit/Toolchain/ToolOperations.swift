import Foundation

/// What the engine does to a package.
public enum ToolAction: String, Sendable, Codable {
    case update, uninstall
}

/// How one package's run ended.
public enum ToolOutcome: String, Sendable, Codable {
    /// Exited cleanly and the rescan shows the new version.
    case updated
    /// Exited cleanly but the version didn't move.
    case unchanged
    /// Removed.
    case removed
    case failed
    /// Not started: the run was stopped first.
    case skipped
}

public struct ToolOperationOutcome: Sendable {
    public var packageID: String
    public var outcome: ToolOutcome
    /// Installed version after the run, when the rescan could read it.
    public var version: String?
    public var error: String?
    /// The last lines printed, for the activity log.
    public var log: String
    public var duration: TimeInterval
}

public struct ToolOperationReport: Sendable {
    public var outcomes: [ToolOperationOutcome]
    /// The source's packages after the run, so the caller needs no extra scan.
    public var packages: [ToolPackage]?
}

public enum ToolOperationEvent: Sendable {
    case started(packageID: String, command: String)
    case output(packageID: String, line: String)
    case finished(ToolOperationReport)
}

/// The engine every package update and removal runs through: one lock per
/// package manager, live output, and a rescan afterwards that proves which
/// versions actually changed.
public enum ToolOperations {
    /// Runs `action` on packages of one source in order. Cancelling the
    /// consuming task stops the running command and skips the rest.
    public static func run(_ action: ToolAction, source sourceID: String, packages: [String]) -> AsyncStream<ToolOperationEvent> {
        AsyncStream { continuation in
            let task = Task {
                let report = await perform(action, sourceID: sourceID, packageIDs: packages) { continuation.yield($0) }
                continuation.yield(.finished(report))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct Step {
        var packageID: String
        var outcome: ToolOutcome
        var error: String?
        var log: String
        var duration: TimeInterval
    }

    static func perform(_ action: ToolAction, sourceID: String, packageIDs: [String],
                        emit: @escaping @Sendable (ToolOperationEvent) -> Void) async -> ToolOperationReport {
        await Shell.ready()
        guard let source = PackageSources.source(sourceID) else {
            let outcomes = packageIDs.map {
                ToolOperationOutcome(packageID: $0, outcome: .failed, error: "Unknown package manager \(sourceID)", log: "", duration: 0)
            }
            return ToolOperationReport(outcomes: outcomes, packages: nil)
        }
        var steps: [Step] = []
        for packageID in packageIDs {
            if Task.isCancelled {
                steps.append(Step(packageID: packageID, outcome: .skipped, log: "", duration: 0))
                continue
            }
            steps.append(await runOne(action, source: source, packageID: packageID, emit: emit))
        }

        let after = Task.isCancelled ? nil : try? await PackageSources.scan(sourceID)
        let outcomes = steps.map { step -> ToolOperationOutcome in
            let found = after?.first { $0.id == step.packageID }
            var outcome = step.outcome
            var error = step.error
            if outcome == .updated, found?.outdated == true {
                outcome = .unchanged
                error = "The command succeeded but the installed version didn't change"
            }
            if outcome == .removed, found != nil, after != nil {
                outcome = .failed
                error = "The command succeeded but it's still installed"
            }
            return ToolOperationOutcome(packageID: step.packageID, outcome: outcome, version: found?.currentVersion,
                                        error: error, log: step.log, duration: step.duration)
        }
        return ToolOperationReport(outcomes: outcomes, packages: after)
    }

    private static func runOne(_ action: ToolAction, source: any PackageSource, packageID: String,
                               emit: @escaping @Sendable (ToolOperationEvent) -> Void) async -> Step {
        let started = Date()
        let elapsed = { Date().timeIntervalSince(started) }
        let invocation: Invocation?
        do {
            invocation = switch action {
            case .update: try await source.updateCommand(packageID)
            case .uninstall: try await source.uninstallCommand(packageID)
            }
        } catch {
            return Step(packageID: packageID, outcome: .failed, error: error.localizedDescription, log: "", duration: elapsed())
        }
        let lock = invocation?.lock ?? source.lock
        let tail = LineTail()
        let onLine: @Sendable (String) -> Void = { line in
            tail.append(line)
            emit(.output(packageID: packageID, line: line))
        }
        do {
            try await ToolLock.shared.with(lock) {
                try Task.checkCancellation()
                emit(.started(packageID: packageID, command: invocation?.commandLine ?? "Move \(PackageID.name(packageID)) to the Trash"))
                if action == .uninstall {
                    try await source.uninstall(packageID, onLine: onLine)
                } else if let invocation {
                    _ = try await ToolCommand.stream(invocation, onLine: onLine)
                }
            }
            return Step(packageID: packageID, outcome: action == .update ? .updated : .removed, log: tail.text, duration: elapsed())
        } catch is CancellationError {
            return Step(packageID: packageID, outcome: .failed, error: "Stopped", log: tail.text, duration: elapsed())
        } catch {
            let message = Task.isCancelled ? "Stopped" : error.localizedDescription
            return Step(packageID: packageID, outcome: .failed, error: message, log: tail.text, duration: elapsed())
        }
    }
}

/// The last 40 lines a command printed, shared with its reader thread.
final class LineTail: @unchecked Sendable {
    // Safe: every access to `lines` holds `lock`.
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.withLock {
            lines.append(line)
            if lines.count > 40 { lines.removeFirst(lines.count - 40) }
        }
    }

    var text: String { lock.withLock { lines.joined(separator: "\n") } }
}
