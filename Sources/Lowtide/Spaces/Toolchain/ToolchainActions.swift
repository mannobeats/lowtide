import LowtideKit
import SwiftUI

/// The Toolchain space's actions for ⌘K, the command bar and menus.
enum ToolchainActions {
    static var all: [AppAction] {
        let model = ToolchainModel.shared
        let updates = model.toolUpdateCount
        var actions = [
            AppAction(id: "toolchain.check", title: "Check for Tool Updates",
                      subtitle: "Ask every package manager and registry again", symbol: "arrow.clockwise", glyph: "refresh",
                      keywords: "rescan outdated brew npm cargo refresh", space: .developer) {
                model.refresh()
                AppModel.shared.show(.toolchain)
            },
            AppAction(id: "toolchain.review", title: updates > 0 ? "Review \(LowtideFormat.count(updates, "Tool Update"))" : "Review Tool Updates",
                      subtitle: "The update plan, safest first", symbol: "arrow.up.circle", glyph: "updates",
                      keywords: "upgrade command-line cli plan", space: .developer) {
                AppModel.shared.show(.appsUpdates)
            },
            AppAction(id: "toolchain.doctor", title: "Run the Doctor", subtitle: "PATH, shell, Git, SSH and Homebrew checks",
                      symbol: "stethoscope", glyph: "doctor", keywords: "diagnose health path broken", space: .developer) {
                DoctorModel.shared.run()
                AppModel.shared.show(.doctor)
            },
            AppAction(id: "toolchain.recipe.export", title: "Export Mac Recipe…", subtitle: "Everything this Mac runs, as a file",
                      symbol: "square.and.arrow.up", glyph: "recipe", keywords: "brewfile backup new mac setup", space: .developer) {
                AppModel.shared.show(.recipe)
                if RecipeModel.shared.recipe != nil { RecipeModel.shared.export() }
            },
            AppAction(id: "toolchain.history", title: "Show Package History", subtitle: "Installs, updates and removals",
                      symbol: "clock.arrow.circlepath", glyph: "history", keywords: "activity log operations", space: .developer) {
                AppModel.shared.show(.toolchain)
                model.historyOpen = true
            },
        ]
        // Each package manager's own page.
        for source in model.sources where source.id != "mas" {
            actions.append(AppAction(id: "toolchain.manager.\(source.id)", title: "Open \(source.name) Packages",
                                     subtitle: source.description, symbol: "shippingbox", glyph: "inventory",
                                     keywords: "\(source.tool) inventory packages", space: .developer) {
                model.inventoryManager = source.id
                AppModel.shared.show(.inventory)
            })
        }
        return actions
    }
}
