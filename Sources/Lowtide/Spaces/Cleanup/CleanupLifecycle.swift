import LowtideKit
import SwiftUI

/// The Cleanup space's hooks into the app: background work started once at
/// launch and stopped at quit, its self-test steps, and its menu commands.
enum CleanupLifecycle {
    private static var launchTask: Task<Void, Never>?

    /// The Leftovers count in the sidebar: one quiet scan a few seconds
    /// after launch, so it doesn't compete with the first window.
    static func launch() {
        launchTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            LeftoversStore.shared.refresh()
        }
    }

    static func terminate() {
        launchTask?.cancel()
        DuplicatesStore.shared.cancel()
    }

    static var selfTests: [SelfTest.Step] {
        [
            SelfTest.Step("cleanup measures a folder like du") {
                let dir = FileManager.default.temporaryDirectory.appending(path: "lowtide-selftest-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: dir.appending(path: "a/b"), withIntermediateDirectories: true)
                try Data(repeating: 1, count: 20_000).write(to: dir.appending(path: "a/b/file"))
                defer { try? FileManager.default.removeItem(at: dir) }
                let bytes = await DiskSize.measure(dir.path)
                return (bytes ?? 0) >= 20_000
            },
            SelfTest.Step("cleanup lists cache places") {
                _ = await CleanupTargets.cachePlaces()
                return true
            },
            SelfTest.Step("leftovers scan finishes") {
                let context = await LeftoverScanner.scan()
                return context.leftovers.allSatisfy { !$0.paths.isEmpty }
            },
            SelfTest.Step("space lens lists HOME") {
                try !FolderScan.list(Paths.home.path).isEmpty
            },
            SelfTest.Step("docker inventory answers") {
                _ = await Docker.inventory()
                return true
            },
        ]
    }
}

/// The Cleanup space's menu bar commands.
struct CleanupCommands: Commands {
    var body: some Commands { CommandGroup(after: .newItem) {} }
}
