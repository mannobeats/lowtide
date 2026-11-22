import LowtideKit
import SwiftUI

/// The System space's hooks into the app. Nothing runs at launch: the
/// monitor samples only while something asks (`SystemModel.retain`).
enum SystemLifecycle {
    static func launch() {}

    static func terminate() {
        KeepAwake.shared.stop()
        try? XDRBoost.shared.set(level: 0)
    }

    static var selfTests: [SelfTest.Step] {
        [
            SelfTest.Step("the system monitor reads this Mac") {
                let monitor = SystemMonitor()
                await monitor.prime()
                try await Task.sleep(for: .milliseconds(300))
                let sample = await monitor.step().sample
                return sample.memory.total > 0 && !sample.cores.isEmpty && (0...100).contains(sample.cpu)
            },
            SelfTest.Step("the process list includes this app") {
                let monitor = SystemMonitor()
                _ = await monitor.processList()
                return await monitor.processList().contains { $0.pid == getpid() }
            },
            SelfTest.Step("a process's detail reads") {
                await ProcessTable.detail(getpid())?.pid == getpid()
            },
            SelfTest.Step("the system model samples while retained") {
                SystemModel.shared.retain("selftest")
                defer { SystemModel.shared.release("selftest") }
                for _ in 0..<30 where SystemModel.shared.latest == nil { try await Task.sleep(for: .milliseconds(100)) }
                return SystemModel.shared.latest != nil && SystemModel.shared.isSampling
            },
            SelfTest.Step("the quick controls read their state") {
                let state = await Tools.state()
                return state.awake == KeepAwake.shared.state && state.outputs.filter(\.isCurrent).count <= 1
            },
        ]
    }
}

/// The System space's menu bar commands.
struct SystemCommands: Commands {
    var body: some Commands { CommandGroup(after: .newItem) {} }
}
