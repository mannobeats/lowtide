import AppKit
import LowtideKit
import SwiftUI

/// The Servers space's hooks into the app: background work started once at
/// launch and stopped at quit, its self-test steps, and its menu commands.
enum ServersLifecycle {
    static func launch() {
        let remote = RemoteStore.shared
        // ssh asks the app for saved passwords; prompts no saved secret
        // answers (a one-time code) come up as a dialog.
        do { try AskpassServer.shared.start() } catch {
            Log.terminal.error("askpass unavailable: \(error.localizedDescription, privacy: .public)")
        }
        AskpassServer.shared.setPrompter { request in await AskpassDialog.ask(request) }
        Tunnels.shared.observe { id, status in
            Task { @MainActor in RemoteStore.shared.tunnelChanged(id, status) }
        }
        Task {
            await remote.load()
            await remote.autoStart()
            await FleetMonitor.shared.start()
            remote.startFleetPolling()
        }
        StatusMenu.providers.append {
            let running = RemoteStore.shared.forwardStatus.values.filter { if case .running = $0 { true } else { false } }.count
            let down = RemoteStore.shared.fleet.filter { $0.state == .unreachable || $0.state == .needsKey }
            var lines: [StatusMenu.Line] = []
            if running > 0 {
                lines.append(StatusMenu.Line("\(LowtideKitFormat.count(running, "port forward")) running", symbol: "arrow.left.arrow.right") {
                    AppModel.shared.show(.forwards)
                })
            }
            if !down.isEmpty {
                lines.append(StatusMenu.Line(down.count == 1 ? "\(down[0].name) needs a look" : "\(down.count) servers need a look",
                                             symbol: "exclamationmark.triangle") { AppModel.shared.show(.hosts) })
            }
            return lines
        }
    }

    static func terminate() {
        Tunnels.shared.stopAll()
        RemoteStore.shared.stopFleetPolling()
        Task { await FleetMonitor.shared.stop() }
        AskpassServer.shared.stop()
    }

    static var selfTests: [SelfTest.Step] {
        [
            SelfTest.Step("the vault opens with the remote tables") {
                guard let vault = RemoteVault.shared else { return false }
                _ = try await vault.load()
                return true
            },
            SelfTest.Step("the askpass socket answers") {
                try AskpassServer.shared.start()
                return FileManager.default.fileExists(atPath: AskpassServer.shared.socketPath)
            },
            SelfTest.Step("an unreachable host is reported, not hung") {
                let server = await FleetMonitor.shared.probe(Fleet.Target(id: "selftest", name: "Nowhere",
                                                                          endpoint: SSHEndpoint(host: "127.0.0.1", port: 1, user: "nobody")))
                return server?.state == .unreachable
            },
        ]
    }
}

/// A question from ssh that no saved secret answers, asked in the app.
enum AskpassDialog {
    static func ask(_ request: AskpassRequest) async -> String? {
        await MainActor.run {
            let alert = NSAlert()
            alert.messageText = request.retry ? "The saved password didn't work" : "\(request.label) is asking"
            alert.informativeText = request.prompt
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            alert.accessoryView = field
            alert.addButton(withTitle: "Send")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            NSApp.activate()
            let answer = alert.runModal()
            return answer == .alertFirstButtonReturn ? field.stringValue : nil
        }
    }
}

/// The Servers space's menu bar commands.
struct ServersCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Host…") { ServersActions.newHost() }
        }
    }
}
