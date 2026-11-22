import LowtideKit
import SwiftUI

/// Every package update and removal the person starts, with its live
/// output. Each manager's batches run in order; different managers run
/// side by side (the engine's locks keep managers that share one apart).
/// Each batch is a job in the status bar.
@Observable
final class ToolUpdateQueue {
    static let shared = ToolUpdateQueue()

    enum Status: Equatable {
        case queued, running, updated, unchanged, removed, failed, skipped

        var active: Bool { self == .queued || self == .running }
    }

    /// One package of one source, as a page hands it over.
    struct Target {
        var sourceID: String
        var sourceName: String
        var packageID: String
        var name: String
        var currentVersion: String
        var latestVersion: String?

        init(_ item: InventoryItem) {
            sourceID = item.sourceID
            sourceName = item.ownerName
            packageID = item.package.id
            name = item.package.name
            currentVersion = item.package.currentVersion
            latestVersion = item.package.latestVersion
        }

        init(_ package: ToolPackage, source: PackageSourceInfo) {
            self.init(InventoryItem(package: package, source: source))
        }
    }

    @Observable
    final class Job: Identifiable {
        let target: Target
        let action: ToolAction
        var status: Status = .queued
        var command: String?
        var lines: [String] = []
        var error: String?
        /// Installed version once the rescan verified the run.
        var version: String?
        var duration: TimeInterval?

        var id: String { ToolUpdateQueue.key(target.sourceID, target.packageID) }

        init(target: Target, action: ToolAction) {
            self.target = target
            self.action = action
        }
    }

    private(set) var jobs: [Job] = []
    private var tails: [String: Task<Void, Never>] = [:]
    private var batches: [UUID: Jobs.Job] = [:]
    private static let maxLines = 600

    static func key(_ sourceID: String, _ packageID: String) -> String { "\(sourceID):\(packageID)" }

    var isActive: Bool { jobs.contains { $0.status.active } }

    func job(_ sourceID: String, _ packageID: String) -> Job? {
        let key = Self.key(sourceID, packageID)
        return jobs.first { $0.id == key }
    }

    func isBusy(_ sourceID: String, _ packageID: String) -> Bool { job(sourceID, packageID)?.status.active ?? false }

    func isBusy(source sourceID: String) -> Bool { jobs.contains { $0.target.sourceID == sourceID && $0.status.active } }

    /// Queues `targets`; a package already queued or running is left alone,
    /// a finished one is replaced.
    func enqueue(_ targets: [Target], action: ToolAction = .update) {
        let active = Set(jobs.filter { $0.status.active }.map(\.id))
        let fresh = targets.filter { !active.contains(Self.key($0.sourceID, $0.packageID)) }
        guard !fresh.isEmpty else { return }
        let new = fresh.map { Job(target: $0, action: action) }
        let keys = Set(new.map(\.id))
        withAnimation(Motion.base) { jobs = jobs.filter { !keys.contains($0.id) } + new }
        for (sourceID, batch) in Dictionary(grouping: new, by: { $0.target.sourceID }) {
            schedule(batch, source: sourceID, action: action)
        }
    }

    private func schedule(_ batch: [Job], source sourceID: String, action: ToolAction) {
        let previous = tails[sourceID]
        let (signal, done) = AsyncStream<Void>.makeStream()
        tails[sourceID] = Task { for await _ in signal {} }
        let name = batch.count == 1 ? batch[0].target.name : LowtideFormat.count(batch.count, "package")
        let title = action == .update ? "Updating \(name)" : "Removing \(name)"
        let id = UUID()
        let handle = Jobs.shared.start(title, page: action == .update ? .appsUpdates : .inventory) { job in
            defer { done.finish() }
            if previous != nil { job.detail = "Waiting for \(batch[0].target.sourceName)" }
            await previous?.value
            try await self.run(batch, source: sourceID, action: action, progress: job)
        }
        batches[id] = handle
        Task {
            await tails[sourceID]?.value
            batches[id] = nil
        }
    }

    private func run(_ batch: [Job], source sourceID: String, action: ToolAction, progress: Jobs.Job) async throws {
        let waiting = batch.filter { $0.status == .queued }
        guard !waiting.isEmpty else { return }
        let byPackage = Dictionary(waiting.map { ($0.target.packageID, $0) }, uniquingKeysWith: { a, _ in a })
        var finished = false
        progress.progress = 0
        for await event in ToolOperations.run(action, source: sourceID, packages: waiting.map(\.target.packageID)) {
            switch event {
            case .started(let packageID, let command):
                guard let job = byPackage[packageID] else { continue }
                job.status = .running
                job.command = command
                let index = waiting.firstIndex { $0 === job } ?? 0
                progress.progress = Double(index) / Double(waiting.count)
                progress.detail = waiting.count > 1 ? "\(index + 1) of \(waiting.count): \(job.target.name)" : command
            case .output(let packageID, let line):
                guard let job = byPackage[packageID] else { continue }
                job.lines.append(line)
                if job.lines.count > Self.maxLines { job.lines.removeFirst(job.lines.count - Self.maxLines) }
            case .finished(let report):
                finished = true
                settle(report, jobs: byPackage, source: sourceID)
            }
        }
        progress.progress = 1
        guard finished else {
            // Stopped: the running command was ended, the rest never started.
            for job in waiting {
                if job.status == .running { job.status = .failed; job.error = "Stopped" }
                if job.status == .queued { job.status = .skipped }
            }
            throw CancellationError()
        }
        announce(waiting)
    }

    private func settle(_ report: ToolOperationReport, jobs: [String: Job], source sourceID: String) {
        for outcome in report.outcomes {
            guard let job = jobs[outcome.packageID] else { continue }
            job.status = switch outcome.outcome {
            case .updated: .updated
            case .unchanged: .unchanged
            case .removed: .removed
            case .failed: .failed
            case .skipped: .skipped
            }
            job.error = outcome.error
            job.version = outcome.version
            job.duration = outcome.duration
            guard outcome.outcome != .skipped else { continue }
            let failed = outcome.outcome == .failed
            let detail = failed || outcome.outcome == .unchanged
                ? [outcome.error, outcome.log.isEmpty ? nil : outcome.log].compactMap { $0 }.joined(separator: "\n\n") : nil
            ToolchainModel.shared.record(ActivityEntry(
                action: job.action == .update ? "update" : "uninstall", itemName: job.target.name,
                sourceName: job.target.sourceName, succeeded: !failed, detail: detail,
                previousVersion: job.target.currentVersion,
                resultingVersion: job.action == .update ? (outcome.version ?? job.target.latestVersion) : nil,
                duration: outcome.duration))
        }
        if let packages = report.packages {
            ToolchainModel.shared.apply(packages, for: sourceID)
        } else {
            ToolchainModel.shared.rescan(sourceID)
        }
    }

    private func announce(_ batch: [Job]) {
        let failed = batch.filter { $0.status == .failed }
        let unchanged = batch.filter { $0.status == .unchanged }.count
        let done = batch.filter { $0.status == .updated || $0.status == .removed }
        if let first = failed.first {
            Toasts.shared.show(failed.count == 1 ? "\(first.target.name) didn't \(first.action == .update ? "update" : "uninstall")"
                                   : "\(failed.count) operations failed",
                               detail: failed.count == 1 ? first.error : nil, tone: .bad)
        }
        if unchanged > 0 {
            Toasts.shared.show("\(LowtideFormat.count(unchanged, "update")) finished without a new version",
                               detail: "The output is in the operations log", tone: .warn)
        }
        if let first = done.first {
            let verb = first.action == .update ? "Updated" : "Removed"
            Toasts.shared.show(done.count == 1 ? "\(verb) \(first.target.name)" : "\(verb) \(LowtideFormat.count(done.count, "package"))")
        }
    }

    /// Stops the running commands and skips everything still queued.
    func cancel() {
        for handle in batches.values { handle.cancel() }
        for job in jobs where job.status == .queued { job.status = .skipped }
    }

    func clearFinished() {
        withAnimation(Motion.base) { jobs.removeAll { !$0.status.active } }
    }
}

