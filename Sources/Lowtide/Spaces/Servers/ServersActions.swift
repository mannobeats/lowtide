import LowtideKit
import SwiftUI

/// The Servers space's actions for ⌘K, the command bar and menus.
enum ServersActions {
    static var all: [AppAction] {
        let remote = RemoteStore.shared
        var actions = [
            AppAction(id: "new-host", title: "New Host…", subtitle: "Save a server", symbol: "plus", glyph: "hosts",
                      keywords: "ssh server add", space: .developer) { newHost() },
            AppAction(id: "add-credential", title: "Add Credential…", subtitle: "An SSH key or a password", symbol: "key",
                      glyph: "credentials", keywords: "ssh key generate password", space: .developer) {
                AppModel.shared.show(.credentials)
            },
        ]
        for host in remote.snapshot.hosts {
            actions.append(AppAction(id: "connect:\(host.id)", title: "Connect to \(host.name)",
                                     subtitle: AppModel.shared.privacy ? "SSH" : "\(host.username)@\(host.hostname)",
                                     symbol: "terminal", glyph: "hosts",
                                     keywords: "ssh \(host.hostname) \(host.tags ?? "")", space: .developer) {
                remote.connect(host)
            })
        }
        for forward in remote.snapshot.forwards {
            let running = remote.isRunning(forward)
            actions.append(AppAction(id: "forward:\(forward.id)", title: "\(running ? "Stop" : "Start") \(forward.name)",
                                     subtitle: "Port forward \(forward.route)", symbol: running ? "stop.circle" : "play.circle",
                                     glyph: "forwards", keywords: "tunnel forward port", space: .developer) {
                running ? remote.stop(forward) : remote.start(forward)
            })
        }
        return actions
    }

    static func newHost() {
        UserDefaults.standard.set(HostsPage.Mode.hosts.rawValue, forKey: "hosts.view")
        DevSheetHost.present { close in HostEditor(draft: HostDraft(), close: close) }
    }
}
