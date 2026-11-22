import LowtideKit
import SwiftUI

/// The Terminal space's hooks into the app: background work started once at
/// launch and stopped at quit, its self-test steps, and its menu commands.
enum TerminalLifecycle {
    static func launch() {
        let store = SessionStore.shared
        store.installKeyMonitor()
        store.followAppearance()
        TerminalReceiptFeed.shared.start()
    }

    static func terminate() {
        SessionStore.shared.removeKeyMonitor()
        SessionStore.shared.terminateAll()
    }

    static var selfTests: [SelfTest.Step] {
        [
            SelfTest.Step("a terminal opens, runs a command and closes") {
                let store = SessionStore.shared
                let id = store.openLocal(title: "Self-test")
                defer { store.close(id) }
                guard let session = store.session(id) else { return false }
                session.view.frame = CGRect(x: 0, y: 0, width: 640, height: 400)
                session.start()
                session.type("echo lowtide-$((40+2))", run: true)
                for _ in 0..<60 {
                    try await Task.sleep(for: .milliseconds(100))
                    let text = String(decoding: session.view.getBufferAsData(), as: UTF8.self)
                    if text.contains("lowtide-42") { return true }
                }
                return false
            },
            SelfTest.Step("the terminal follows the theme's palette") {
                TerminalColors.current.ansi.count == 16
            },
            SelfTest.Step("completion specs load") { CompletionSpecs.all["git"] != nil },
        ]
    }
}

/// The Terminal space's menu bar commands.
struct TerminalCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Terminal") { TerminalActions.newTerminal() }
                .keyboardShortcut("t")
            Button("Quick Connect…") { QuickConnect.present() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
        }
        CommandMenu("Shell") {
            Button("Split Right") { TerminalActions.onSessions { SessionStore.shared.split(axis: .row) } }
            Button("Split Down") { TerminalActions.onSessions { SessionStore.shared.split(axis: .column) } }
            Button("Zoom Pane") { TerminalActions.onSessions { SessionStore.shared.toggleZoom() } }
            Button("Even Out Panes") { TerminalActions.onSessions { SessionStore.shared.equalize() } }
            Divider()
            Button("Next Tab") { TerminalActions.onSessions { SessionStore.shared.cycle(1) } }
            Button("Previous Tab") { TerminalActions.onSessions { SessionStore.shared.cycle(-1) } }
            Divider()
            Button("Find in Scrollback") { TerminalActions.onSessions { SessionStore.shared.findOpen = true } }
            Button("Use a Saved Password") {
                TerminalActions.onSessions { SessionStore.shared.focusedSession?.credentialPickerOpen = true }
            }
            Divider()
            Button("Bigger Text") { TerminalSettings.shared.bigger() }
                .keyboardShortcut("+")
            Button("Smaller Text") { TerminalSettings.shared.smaller() }
                .keyboardShortcut("-")
            Button("Actual Size") { TerminalSettings.shared.actualSize() }
        }
    }
}
