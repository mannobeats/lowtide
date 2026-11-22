import SwiftUI

/// The Extensions space's actions: each extension's own.
enum ExtensionsActions {
    static var all: [AppAction] {
        WidgetsLifecycle.actions + DictationLifecycle.actions + MenuBarLifecycle.actions + CommandBarLifecycle.actions
    }
}
