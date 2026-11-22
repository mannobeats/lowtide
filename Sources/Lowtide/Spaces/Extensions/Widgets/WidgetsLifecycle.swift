import LowtideKit
import SwiftUI

/// The Widgets extension's hooks: the menu-bar strip runs while the
/// extension is on (`extension.widgets`), following the Extensions gallery's
/// switch.
enum WidgetsLifecycle {
    /// Today's traffic and the busiest apps for the popover's Network
    /// section; the network space sets it when its monitor runs.
    static var networkFacts: (@MainActor () -> NetworkFacts?)?

    private static var observer: NSObjectProtocol?

    static func launch() {
        observer = NotificationCenter.default.addObserver(forName: WidgetsStore.changedNotification, object: nil,
                                                          queue: .main) { _ in
            MainActor.assumeIsolated { sync() }
        }
        sync()
    }

    static func terminate() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        WidgetsStatusItem.shared.stop()
    }

    /// Starts or stops the strip to match the switch.
    private static func sync() {
        let store = WidgetsStore.shared
        store.reloadEnabled()
        if store.enabled {
            WidgetsStatusItem.shared.start()
        } else {
            WidgetsStatusItem.shared.stop()
        }
    }

    static var actions: [AppAction] {
        let on = WidgetsStore.shared.enabled
        return [
            AppAction(id: "widgets.toggle", title: on ? "Turn Menu Bar Widgets Off" : "Turn Menu Bar Widgets On",
                      subtitle: "CPU, memory, network and more beside the menu bar icon", symbol: "menubar.rectangle",
                      glyph: "widgets", keywords: "stats menu bar cpu memory network widgets", space: .extensions) {
                WidgetsStore.shared.setEnabled(!on)
            },
        ]
    }

    static var selfTests: [SelfTest.Step] {
        [
            SelfTest.Step("the widget strip draws every default widget") {
                let readings = WidgetDrawing.readings
                return WidgetSpec.defaults.allSatisfy { WidgetDrawing.bitmap($0, color: .mono, readings: readings, dark: true) != nil }
            },
            SelfTest.Step("the widgets status item follows the switch") {
                let was = WidgetsStore.shared.enabled
                defer { WidgetsStore.shared.setEnabled(was) }
                WidgetsStore.shared.setEnabled(true)
                let started = WidgetsStatusItem.shared.isRunning
                WidgetsStore.shared.setEnabled(false)
                return started && !WidgetsStatusItem.shared.isRunning
            },
        ]
    }
}

struct WidgetsCommands: Commands {
    var body: some Commands { CommandGroup(after: .newItem) {} }
}
