import LowtideKit
import SwiftUI

/// The Toolchain space's hooks into the app: background work started once at
/// launch and stopped at quit, its self-test steps, and its menu commands.
enum ToolchainLifecycle {
    /// The scan starts a few seconds after launch, once the login shell's
    /// PATH is read, so Home and the Apps badge have a count to show.
    private static var launchTask: Task<Void, Never>?

    static func launch() {
        launchTask = Task {
            await Shell.ready()
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            ToolchainModel.shared.start()
        }
    }

    static func terminate() {
        launchTask?.cancel()
        ToolUpdateQueue.shared.cancel()
    }

    static var selfTests: [SelfTest.Step] {
        [
            SelfTest.Step("every package manager has its mark") {
                PackageSources.all.allSatisfy { FileManager.default.fileExists(atPath: AppResources.url("sources/\($0.info.icon).svg").path) }
            },
            SelfTest.Step("package managers are found on the login PATH") {
                await Shell.ready()
                return await Task.detached { PackageSources.all.contains { $0.isAvailable() } || !Shell.isAvailable("brew") }.value
            },
            SelfTest.Step("the activity log reads and writes") {
                let entry = ActivityEntry(action: "selftest", itemName: "selftest", sourceName: "Lowtide", succeeded: true)
                try await PackageActivity.record(entry)
                let found = try await PackageActivity.list(limit: 5).contains { $0.id == entry.id }
                _ = try await Vault.shared?.execute("DELETE FROM activity_log WHERE id = ?", [entry.id])
                return found
            },
            SelfTest.Step("the doctor runs a PATH check") {
                let check = await Doctor.run("path-entries")
                return check.status != .skip && !check.summary.isEmpty
            },
            SelfTest.Step("runtimes are read") {
                await Shell.ready()
                let runtimes = await Runtimes.all()
                return !Shell.isAvailable("node") || runtimes.contains { $0.id == "node" }
            },
            SelfTest.Step("a recipe script is safe to run twice") {
                let recipe = MacRecipe(machine: .init(name: "Test", os: "macOS", arch: "aarch64"),
                                       sections: [RecipeSection(id: "brew", label: "Homebrew formulae", items: [RecipeItem(id: "brew:jq", name: "jq")])])
                return recipe.script().contains(#"brew list --formula "$p" >/dev/null 2>&1 || brew install "$p""#)
            },
        ]
    }
}

/// The Toolchain space's menu bar commands.
struct ToolchainCommands: Commands {
    var body: some Commands { CommandGroup(after: .newItem) {} }
}
