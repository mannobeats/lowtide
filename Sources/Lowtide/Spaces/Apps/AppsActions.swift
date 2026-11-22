import LowtideKit
import SwiftUI

/// The Apps space's actions for ⌘K, the command bar and menus.
enum AppsActions {
    static var all: [AppAction] {
        var actions = [
            AppAction(id: "apps.check-updates", title: "Check for App Updates", subtitle: "Every app, with the App Store, its developer and Homebrew",
                      symbol: "arrow.down.circle", glyph: "updates", keywords: "upgrade outdated new version sparkle", space: .apps) {
                AppsLifecycle.checkNow()
            },
            AppAction(id: "apps.uninstall", title: "Uninstall an App…", subtitle: "With every file it put on this Mac",
                      symbol: "trash", glyph: "installed", keywords: "remove delete app cleaner leftovers", space: .apps) {
                AppModel.shared.show(.appsInstalled)
            },
            AppAction(id: "apps.addons", title: "Browser Extensions and Plug-ins", subtitle: "Add-ons, audio plug-ins, widgets, screen savers",
                      symbol: "puzzlepiece.extension", glyph: "addons", keywords: "chrome firefox vst au safari", space: .apps) {
                AddonsModel.shared.view = .addons
                AppModel.shared.show(.appsAddons)
            },
        ]
        let updates = AppUpdatesModel.shared
        let installable = updates.pending.filter { $0.installsHere(homebrew: updates.homebrew) }
        if !installable.isEmpty {
            actions.insert(AppAction(id: "apps.update-all", title: "Update All Apps", subtitle: LowtideFormat.count(installable.count, "update") + " waiting",
                                     symbol: "arrow.down.app", glyph: "updates", keywords: "install upgrade everything", space: .apps) {
                AppModel.shared.show(.appsUpdates)
                updates.install(installable)
            }, at: 0)
        }
        if let last = AppsReport.last {
            actions.insert(AppAction(id: "apps.put-back", title: "Put Back Last Removal", subtitle: last.title,
                                     symbol: "arrow.uturn.backward", keywords: "undo restore trash", space: .apps) {
                AppsReport.putBackLast()
            }, at: 0)
        }
        switch PrivilegedHelper.state {
        case .off, .approval:
            actions.append(AppAction(id: "apps.helper", title: "Remove Apps Without a Password", subtitle: "Approve Lowtide’ helper once in Login Items",
                                     symbol: "lock.open", keywords: "privileged helper admin root password", space: .apps) {
                _ = try? PrivilegedHelper.enable()
            })
        default: break
        }
        return actions
    }
}
