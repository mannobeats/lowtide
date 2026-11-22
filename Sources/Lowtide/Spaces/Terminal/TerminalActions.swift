import LowtideKit
import SwiftUI

/// The Terminal space's actions for ⌘K, the command bar and menus.
enum TerminalActions {
    static var all: [AppAction] {
        var actions = [
            AppAction(id: "new-terminal", title: "New Terminal", subtitle: "A shell on this Mac (⌘T)", symbol: "terminal",
                      glyph: "new-terminal", keywords: "shell tab local zsh", space: .developer) { newTerminal() },
            AppAction(id: "quick-connect", title: "Quick Connect…", subtitle: "SSH to a host that isn't saved (⇧⌘K)",
                      symbol: "bolt.horizontal", glyph: "quick-connect", keywords: "ssh connect server", space: .developer) {
                QuickConnect.present()
            },
        ]
        if !SessionStore.shared.workspace.tabs.isEmpty {
            actions += [
                AppAction(id: "terminal-split-right", title: "Split Terminal Right", subtitle: "⌘D", symbol: "rectangle.split.2x1",
                          keywords: "pane", space: .developer) { onSessions { SessionStore.shared.split(axis: .row) } },
                AppAction(id: "terminal-split-down", title: "Split Terminal Down", subtitle: "⇧⌘D", symbol: "rectangle.split.1x2",
                          keywords: "pane", space: .developer) { onSessions { SessionStore.shared.split(axis: .column) } },
            ]
        }
        for snippet in RemoteStore.shared.snapshot.snippets {
            actions.append(AppAction(id: "snippet:\(snippet.id)", title: "Run \(snippet.name)…",
                                     subtitle: snippet.content.split(separator: "\n").first.map(String.init),
                                     symbol: "play", glyph: "snippets", keywords: "snippet \(snippet.tags ?? "")", space: .developer) {
                SnippetRun.present(snippet)
            })
        }
        return actions
    }

    /// Opens a local shell from anywhere and brings the terminal forward.
    static func newTerminal() {
        SessionStore.shared.openLocal()
        AppModel.shared.show(.sessions)
    }

    /// Runs a terminal action on the Sessions page.
    static func onSessions(_ action: @escaping () -> Void) {
        AppModel.shared.show(.sessions)
        action()
    }
}
