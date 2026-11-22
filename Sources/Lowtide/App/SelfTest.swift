import LowtideKit
import SwiftUI

/// `--selftest`: runs the functions the UI calls against a store in /tmp
/// (set `LOWTIDE_HOME`), prints PASS or FAIL per step, and quits with 0 or 1.
enum SelfTest {
    struct Step {
        let name: String
        let run: @MainActor () async throws -> Bool
        init(_ name: String, _ run: @escaping @MainActor () async throws -> Bool) {
            self.name = name
            self.run = run
        }
    }

    static var steps: [Step] {
        [
            Step("every page has a view and a unique route") { Set(Page.allCases.map(\.rawValue)).count == Page.allCases.count },
            Step("every page and space glyph exists") {
                (Page.allCases.map(\.glyph) + SpaceID.allCases.map(\.glyph)).allSatisfy(Glyphs.exists)
            },
            Step("every action's SF Symbol exists") {
                ActionRegistry.all.allSatisfy { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) != nil }
            },
            Step("themes load") { ThemeStore.shared.themes.count >= 7 },
            Step("the login shell PATH is read") {
                await Shell.ready()
                return Shell.path.contains("/usr/bin")
            },
            Step("a command runs") { try await Shell.run("/bin/echo", ["ok"]).stdout == "ok\n" },
            Step("⌘K finds a page") { CommandItem.search("pkts").first.map { if case .page(.packets) = $0.kind { true } else { false } } ?? false },
        ] + SelfTestSteps.all
    }

    @MainActor
    static func run() async {
        var failed = 0
        for step in steps {
            let ok = (try? await step.run()) ?? false
            if !ok { failed += 1 }
            print("\(ok ? "PASS" : "FAIL")  \(step.name)")
        }
        print(failed == 0 ? "ALL PASS (\(steps.count))" : "\(failed) FAILED")
        fflush(stdout)
        exit(failed == 0 ? 0 : 1)
    }
}

/// Self-test steps the spaces add (in each `<Space>Lifecycle`).
enum SelfTestSteps {
    static var all: [SelfTest.Step] {
        AppsLifecycle.selfTests + CleanupLifecycle.selfTests + ProtectionLifecycle.selfTests
            + NetworkLifecycle.selfTests + SystemLifecycle.selfTests + TerminalLifecycle.selfTests
            + ServersLifecycle.selfTests + ToolchainLifecycle.selfTests + ExtensionsLifecycle.selfTests
            + Integration.selfTests
    }
}
