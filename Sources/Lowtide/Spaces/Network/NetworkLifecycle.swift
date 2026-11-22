import LowtideKit
import SwiftUI

/// The Network space's hooks into the app: background work started once at
/// launch and stopped at quit, its self-test steps, and its menu commands.
enum NetworkLifecycle {
    /// The monitor always runs: Home, the overnight report and the threat
    /// score depend on it.
    static func launch() {
        NetworkModel.shared.start()
        StatusMenu.providers.append {
            let model = NetworkModel.shared
            guard model.overview.ready else { return [] }
            let s = model.summary
            var lines = [StatusMenu.Line("↓ \(NetFormat.rate(s.rateIn))  ↑ \(NetFormat.rate(s.rateOut)) · \(LowtideFormat.count(s.appsOnline, "app")) online",
                                         symbol: "network") { AppModel.shared.show(.networkLive) }]
            for app in model.flaggedApps.prefix(3) {
                lines.append(StatusMenu.Line("Review \(app.name) (risk \(app.score))", symbol: "exclamationmark.triangle") {
                    model.pendingTarget = .app(app.name)
                    AppModel.shared.show(.networkLive)
                })
            }
            if model.overview.capture.running {
                lines.append(StatusMenu.Line("Capturing on \(model.overview.capture.interface ?? "")", symbol: "record.circle") {
                    AppModel.shared.show(.packets)
                })
            }
            if let report = model.unseenBriefing {
                lines.append(StatusMenu.Line(report.headline, symbol: "moon.stars") { AppModel.shared.show(.overnight) })
            }
            return lines
        }
    }

    /// Kills a running nettop, stops capture, saves the memory of normal.
    static func terminate() {
        NetworkModel.shared.stop()
    }

    static var selfTests: [SelfTest.Step] {
        [
            SelfTest.Step("the bundled geo databases answer") {
                GeoIP.shared.lookup("8.8.8.8")?.country == "US"
            },
            SelfTest.Step("the world map and cities load") {
                WorldData.shared.landCells.count > 5_000 && City.all.count > 400
            },
            SelfTest.Step("nettop gives a parseable snapshot") {
                let out = try await Shell.run("/usr/bin/nettop", Nettop.arguments, timeout: .seconds(20))
                return !Nettop.parse(out.stdout).isEmpty
            },
            SelfTest.Step("the network monitor takes snapshots") {
                for _ in 0..<40 where !NetworkModel.shared.overview.ready {
                    try await Task.sleep(for: .milliseconds(500))
                }
                return NetworkModel.shared.overview.ready
            },
            SelfTest.Step("localhost lists listening services") {
                let services = await Task.detached { Localhost.services() }.value
                return services.allSatisfy { $0.port > 0 }
            },
            SelfTest.Step("the overnight report briefs the last hour") {
                NightShift.shared.brief(minutes: 60).kind == "brief"
            },
        ]
    }
}

/// The Network space's menu bar commands.
struct NetworkCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button("Start or Stop Packet Capture") {
                Task { await NetworkModel.shared.toggleCapture() }
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
        }
    }
}
