import LowtideKit
import SwiftUI

@main
struct LowtideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Lowtide", id: "main") {
            MainWindow()
        }
        .defaultSize(width: 1280, height: 820)
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { AppCommands() }

        Settings {
            SettingsWindow()
        }
    }
}
