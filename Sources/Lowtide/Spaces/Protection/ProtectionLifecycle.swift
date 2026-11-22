import LowtideKit
import SwiftUI

/// The Protection space's hooks into the app: background work started once at
/// launch and stopped at quit, its self-test steps, and its menu commands.
///
/// Always on, cheap when idle: the run engine samples the process table
/// twice a second (four times while it follows something) and watches
/// files only while a run is going; the decoy poll runs every three
/// seconds and only while decoys are planted; reported secrets are
/// re-read through FSEvents when their folders change.
enum ProtectionLifecycle {
    private static var background: Task<Void, Never>?

    static func launch() {
        let model = ProtectionModel.shared
        Task {
            await RunsStore.shared.reload()
            await model.reloadDecoys()
            await model.reloadExposure()
            await model.watchExposure()
            model.updateBadges()
        }
        Task {
            await RunEngine.shared.start(
                sources: ProtectionHooks.runSources,
                finished: { run in
                    Task { @MainActor in
                        RunsStore.shared.add(run)
                        ProtectionModel.shared.updateBadges()
                    }
                },
                alert: { alert in Task { @MainActor in ProtectionModel.shared.raise(alert) } })
            await PermissionActions.shared.setPrivilegedLaunchd(ProtectionHooks.privilegedLaunchd)
        }
        Task {
            await DecoyWatch.shared.start(
                read: { read in
                    let lead = read.lead.map { "; \($0) started around then" } ?? ""
                    let alert = ProtectionAlert(kind: .decoy, severity: .alert, subject: read.path,
                                                text: "Something read the decoy \(read.imitates) (\(read.path))\(lead)")
                    Task { @MainActor in ProtectionModel.shared.raise(alert) }
                },
                change: { status in Task { @MainActor in ProtectionModel.shared.apply(status) } })
        }
        // The map (without asking System Events) for Home and the badges,
        // once the launch has settled; network threats once a minute.
        background = Task {
            try? await Task.sleep(for: .seconds(20))
            await model.loadPermissions(full: false)
            while !Task.isCancelled {
                await model.reloadNetwork()
                try? await Task.sleep(for: .seconds(60))
                await model.loadPermissions(full: false)
            }
        }
        StatusMenu.providers.append {
            let headline = ProtectionModel.shared.headline
            guard headline.tone != .ok else { return [] }
            return [StatusMenu.Line(headline.text, symbol: "exclamationmark.shield") {
                AppModel.shared.show(.protectionOverview)
            }]
        }
    }

    static func terminate() {
        background?.cancel()
        background = nil
        Exposure.shared.cancel()
        ProtectionModel.shared.stopWatchingExposure()
    }

    /// Quit-time work that has to finish before the app exits.
    static func finish() async {
        await RunEngine.shared.stop()
        await DecoyWatch.shared.stop()
    }

    /// A scratch folder for a self-test step, removed afterwards.
    private static func scratch<T>(_ body: (String) async throws -> T) async rethrows -> T {
        let dir = FileManager.default.temporaryDirectory.appending(path: "lowtide-selftest-\(UUID())").resolvingSymlinksInPath().path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        return try await body(dir)
    }

    static var selfTests: [SelfTest.Step] {
        [
            SelfTest.Step("protection reads its own process from the kernel") {
                guard let info = RunProcessTable.info(getpid()) else { return false }
                return info.uid == getuid() && ProcTable.cwd(getpid()) != nil && ProcTable.arguments(getpid()) != nil
            },
            SelfTest.Step("the run engine answers") {
                _ = await RunEngine.shared.list()
                _ = await RunEngine.shared.following()
                return true
            },
            SelfTest.Step("decoys plant and arm in a scratch home") {
                await scratch { home in
                    let watch = DecoyWatch(home: home, file: URL(fileURLWithPath: home + "/canaries.json"))
                    let status = await watch.plant()
                    return status.planted == 6 && status.decoys.allSatisfy { $0.state == .arming }
                }
            },
            SelfTest.Step("the secrets scan finds a key in a scratch home") {
                await scratch { home in
                    let token = "ghp_" + String(String(repeating: "aB3x9Kq", count: 6).prefix(36))
                    try? FileManager.default.createDirectory(atPath: home + "/app", withIntermediateDirectories: true)
                    FileManager.default.createFile(atPath: home + "/app/.env", contents: Data("GH=\(token)\n".utf8))
                    let store = Exposure(home: home, file: URL(fileURLWithPath: home + "/exposure.json"))
                    let found = await store.scan { _ in }?.report.findings ?? []
                    return found.count == 1 && found[0].kind == "github-token" && !found[0].preview.contains(token)
                }
            },
            SelfTest.Step("the permission map reads start-up items") {
                let map = await PermissionMap.scan(loginItems: false)
                return !map.apps.isEmpty
            },
            SelfTest.Step("the package activity log reads") {
                (try? await PackageActivity.list(limit: 1)) != nil
            },
        ]
    }
}

/// The Protection space's menu bar commands.
struct ProtectionCommands: Commands {
    var body: some Commands { CommandGroup(after: .newItem) {} }
}
