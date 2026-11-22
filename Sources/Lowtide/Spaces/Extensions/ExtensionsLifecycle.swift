import SwiftUI

/// The Extensions space: each extension's hooks, in `Extensions/<Name>/`.
enum ExtensionsLifecycle {
    static func launch() {
        WidgetsLifecycle.launch()
        DictationLifecycle.launch()
        MenuBarLifecycle.launch()
        CommandBarLifecycle.launch()
    }

    static func terminate() {
        WidgetsLifecycle.terminate()
        DictationLifecycle.terminate()
        MenuBarLifecycle.terminate()
    }

    /// Quit-time work that has to finish before the app exits.
    static func finish() async {
        await CommandBarLifecycle.terminate()
    }

    static var selfTests: [SelfTest.Step] {
        WidgetsLifecycle.selfTests + DictationLifecycle.selfTests + MenuBarLifecycle.selfTests + CommandBarLifecycle.selfTests
    }
}

struct ExtensionsCommands: Commands {
    var body: some Commands {
        WidgetsCommands()
        DictationCommands()
        MenuBarCommands()
        CommandBarCommands()
    }
}
