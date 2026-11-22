import Foundation
import Testing
@testable import LowtideKit

@Suite struct ToolchainEngineTests {
    @Test func oneManagerRunsAtATime() async {
        let locks = ToolLock()
        let order = LineTail()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<3 {
                group.addTask {
                    await locks.with("brew") {
                        order.append("start \(index)")
                        try? await Task.sleep(for: .milliseconds(20))
                        order.append("end \(index)")
                    }
                }
            }
        }
        let lines = order.text.split(separator: "\n").map(String.init)
        // Every start is followed by its own end: nothing overlapped.
        for pair in stride(from: 0, to: lines.count, by: 2) {
            #expect(lines[pair].dropFirst(6) == lines[pair + 1].dropFirst(4))
        }
        #expect(await locks.tryAcquire("brew"))
        #expect(await !locks.tryAcquire("brew"))
        #expect(await locks.tryAcquire("npm"))
        await locks.release("brew")
        #expect(await !locks.isHeld("brew"))
    }

    @Test func recordsActivityInTheVault() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "lowtide-activity-\(UUID()).db")
        let db = try SQLiteDatabase(url: url, migrations: Vault.migrations)
        try await PackageActivity.record(ActivityEntry(action: "update", itemName: "llhttp", sourceName: "Homebrew", succeeded: true,
                                                       createdAt: Date(timeIntervalSince1970: 100), previousVersion: "9.4.3",
                                                       resultingVersion: "9.4.4", duration: 12.345), in: db)
        try await PackageActivity.record(ActivityEntry(action: "uninstall", itemName: "left-pad", sourceName: "npm", succeeded: false,
                                                       detail: "npm ERR! code EACCES", createdAt: Date(timeIntervalSince1970: 200)), in: db)
        let entries = try await PackageActivity.list(in: db)
        #expect(entries.map(\.itemName) == ["left-pad", "llhttp"])
        #expect(entries[1].previousVersion == "9.4.3" && entries[1].resultingVersion == "9.4.4" && entries[1].succeeded)
        #expect(entries[1].duration == 12.345)
        #expect(!entries[0].succeeded && entries[0].duration == nil)
        try await PackageActivity.clear(in: db)
        #expect(try await PackageActivity.list(in: db).isEmpty)
    }

    func item(_ name: String, bump: VersionBump?, source: PackageSourceInfo = PackageSources.source("npm")!.info,
              kind: PackageKind = .package) -> InventoryItem {
        InventoryItem(package: ToolPackage(id: "\(source.id):\(name)", name: name, currentVersion: "1.0.0",
                                           latestVersion: "2.0.0", outdated: true, bump: bump, checked: true, kind: kind),
                      source: source)
    }

    @Test func ordersTheUpdatePlanSafestFirst() {
        let homebrew = PackageSources.source("homebrew")!.info
        let items = [
            item("vite", bump: .major), item("zod", bump: .patch), item("eslint", bump: .minor),
            item("ripgrep", bump: .other, source: homebrew), item("ghostty", bump: nil, source: homebrew, kind: .tool),
        ]
        let plan = UpdatePlan.order(items)
        #expect(plan.map(\.package.name) == ["eslint", "zod", "ghostty", "ripgrep", "vite"])
        #expect(UpdatePlan.risk(plan[0]) == .safe)
        #expect(UpdatePlan.risk(plan.last!) == .breaking)
        #expect(UpdatePlan.preselected(items).count == 4)
        #expect(!UpdatePlan.preselected(items).contains(items[0].id))
        #expect(UpdatePlan.reason(items[0]) == "Major version: may contain breaking changes")
        #expect(UpdatePlan.reason(items[4]) == "Version resolved during update")
    }

    @Test func typesInventoryItems() {
        let homebrew = PackageSources.source("homebrew")!.info
        let app = item("claude", bump: .patch, source: homebrew, kind: .app)
        #expect(app.itemType == .app && app.ownerName == "Homebrew Apps" && app.sourceID == "homebrew")
        #expect(UpdatePlan.risk(app) == .review)
        #expect(item("gcloud-cli", bump: nil, source: homebrew, kind: .tool).itemType == .cli)
        #expect(item("claude", bump: nil, source: PackageSources.source("standalone")!.info).itemType == .cli)
        #expect(item("vite", bump: nil).itemType == .package && item("vite", bump: nil).ownerName == "npm")
    }

    @Test func refusesAnUnknownSource() async {
        var outcomes: [ToolOutcome] = []
        for await event in ToolOperations.run(.update, source: "nope", packages: ["nope:x"]) {
            if case .finished(let report) = event { outcomes = report.outcomes.map(\.outcome) }
        }
        #expect(outcomes == [.failed])
    }

    @Test func refusesRemovalsThatCantBeDone() async {
        var report: ToolOperationReport?
        for await event in ToolOperations.run(.uninstall, source: "standalone", packages: ["standalone:claude"]) {
            if case .finished(let done) = event { report = done }
        }
        #expect(report?.outcomes.first?.outcome == .failed)
        #expect(report?.outcomes.first?.error == "Standalone tools are removed with their own installer")
    }
}
