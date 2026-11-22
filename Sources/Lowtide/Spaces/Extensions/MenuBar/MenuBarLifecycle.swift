import LowtideKit
import SwiftUI

/// The menu bar manager's hooks: the markers, the bar and the Island while
/// the extension is on (`extension.menubar`), removed at quit so every icon
/// comes back; actions, menu commands and self-tests.
enum MenuBarLifecycle {
    @MainActor private static var observer: NSObjectProtocol?

    static func launch() {
        observer = NotificationCenter.default.addObserver(forName: Dictation.extensionsChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if UserDefaults.standard.bool(forKey: MenuBarManager.enabledKey) != MenuBarManager.shared.enabled {
                    MenuBarManager.shared.sync()
                }
            }
        }
        MenuBarManager.shared.sync()
    }

    static func terminate() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        MenuBarManager.shared.stop()
    }

    static var actions: [AppAction] {
        let manager = MenuBarManager.shared
        let showHidden = [
            AppAction(id: "menubar.show-hidden", title: "Show Hidden Menu Bar Icons",
                      subtitle: !manager.enabled ? "Turn on the menu bar manager first"
                          : manager.prefs.bar ? (MenuBarManager.overflowing ? "In the bar under «" : "In the bar under the chevron")
                          : MenuBarManager.overflowing ? "Opens « in the menu bar" : "In the menu bar",
                      symbol: "chevron.left", glyph: "menubar", keywords: "bartender ice chevron hidden icons", space: .extensions) {
                manager.showHidden()
            },
        ]
        return showHidden + [
            AppAction(id: "menubar.show-all", title: manager.reveal == .none ? "Show Every Menu Bar Icon" : "Hide Menu Bar Icons",
                      subtitle: "Always-hidden icons too", symbol: "menubar.rectangle", keywords: "reveal all icons", space: .extensions) {
                guard manager.enabled else { manager.showHidden(); return }
                manager.setReveal(manager.reveal == .none ? .all : .none)
            },
        ]
    }

    static var selfTests: [SelfTest.Step] {
        [
            SelfTest.Step("every system icon's glyph exists") {
                (MenuBarNames.system.map(\.symbol) + [MenuBarNames.fallbackSymbol])
                    .allSatisfy { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }
            },
            SelfTest.Step("the Island finds a notch or the top middle") {
                guard let geometry = IslandGeometry.current() else { return NSScreen.screens.isEmpty }
                return geometry.frame.width > 0 && geometry.frame.height > 0
            },
            SelfTest.Step("menu bar items read and are named by their own attributes") {
                let items = await Task.detached { MenuBarAX.items() }.value
                // Every macOS icon on screen has its own name, never its owner's.
                return !MenuBarAX.trusted || (!items.isEmpty && items.filter(\.system).allSatisfy {
                    MenuBarLayout.isSystemOverflow($0) || ($0.name != "MenuBarAgent" && $0.name != "System icon")
                })
            },
        ]
    }
}

struct MenuBarCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .sidebar) {
            let manager = MenuBarManager.shared
            Button("Show Hidden Menu Bar Icons") { manager.showHidden() }
                .disabled(!manager.enabled)
        }
    }
}
