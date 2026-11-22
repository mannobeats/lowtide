import SwiftUI

/// The menu bar: Go to any space (⌘1–⌘0), ⌘K, Privacy Mode, and each
/// space's own commands.
struct AppCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(after: .sidebar) {
            Button(AppModel.shared.sidebarHidden ? "Show Sidebar" : "Hide Sidebar") { AppModel.shared.toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(!AppModel.shared.hasSidebar)
            Button(AppModel.shared.privacy ? "Turn Off Privacy Mode" : "Turn On Privacy Mode") {
                AppModel.shared.privacy.toggle()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
        }
        CommandMenu("Go") {
            Button("Search Pages and Actions…") {
                WindowRouter.showMain()
                AppModel.shared.paletteOpen = true
            }
            .keyboardShortcut("k")
            Divider()
            Button("Back") { AppModel.shared.goBack() }
                .keyboardShortcut("[")
                .disabled(AppModel.shared.backStack.isEmpty)
            Button("Forward") { AppModel.shared.goForward() }
                .keyboardShortcut("]")
                .disabled(AppModel.shared.forwardStack.isEmpty)
            Divider()
            ForEach(Array(SpaceID.allCases.filter { SpaceState.isOn($0) }.enumerated()), id: \.element) { index, space in
                Button(space.title) { AppModel.shared.open(space); WindowRouter.showMain() }
                    .keyboardShortcut(KeyEquivalent(Character(String((index + 1) % 10))), modifiers: .command)
            }
        }
        UpdateCommands()
        AppsCommands()
        CleanupCommands()
        ProtectionCommands()
        NetworkCommands()
        SystemCommands()
        TerminalCommands()
        ServersCommands()
        ToolchainCommands()
        ExtensionsCommands()
    }
}
