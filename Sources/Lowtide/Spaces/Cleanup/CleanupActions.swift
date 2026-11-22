import LowtideKit
import SwiftUI

/// The Cleanup space's actions for ⌘K, the command bar and menus.
enum CleanupActions {
    static var all: [AppAction] {
        [
            AppAction(id: "cleanup.review", title: "Review Caches and Build Folders",
                      subtitle: "Package caches, Xcode data, node_modules and target folders", symbol: "sparkles",
                      glyph: "cleanup-caches", keywords: "free space clean caches derived data node_modules", space: .cleanup) {
                UserDefaults.standard.set("caches", forKey: "cleanup.tab")
                AppModel.shared.show(.cleanup)
                CleanupStore.shared.start()
            },
            AppAction(id: "cleanup.downloads", title: "Clear Downloads and Installers",
                      subtitle: "Installers of installed apps, unpacked archives, copies", symbol: "arrow.down.circle",
                      glyph: "downloads", keywords: "dmg pkg installers downloads", space: .cleanup) {
                UserDefaults.standard.set("downloads", forKey: "cleanup.tab")
                AppModel.shared.show(.cleanup)
            },
            AppAction(id: "cleanup.lens-home", title: "Show Space Lens of Home", subtitle: "What takes the space in your home folder",
                      symbol: "square.grid.3x3", glyph: "space-lens", keywords: "disk usage big folders", space: .cleanup) {
                LensStore.shared.show(Paths.home.path)
            },
            AppAction(id: "cleanup.lens-choose", title: "Show Space Lens of a Folder…", symbol: "folder",
                      glyph: "space-lens", keywords: "disk usage choose folder", space: .cleanup) {
                if let path = CleanupSettings.chooseFolder(prompt: "Open") { LensStore.shared.show(path) }
            },
            AppAction(id: "cleanup.duplicates", title: "Find Duplicate Files", subtitle: "Identical files in your tracked folders",
                      symbol: "doc.on.doc", glyph: "duplicates", keywords: "same copies identical", space: .cleanup) {
                AppModel.shared.show(.duplicates)
                DuplicatesStore.shared.start()
                if !DuplicatesStore.shared.scanning { DuplicatesStore.shared.scan() }
            },
            AppAction(id: "cleanup.leftovers", title: "Scan for Leftovers", subtitle: "Files and permissions of deleted apps",
                      symbol: "trash.slash", glyph: "leftovers", keywords: "uninstalled remnants orphans", space: .cleanup) {
                AppModel.shared.show(.leftovers)
                LeftoversStore.shared.refresh(quiet: false)
            },
        ]
    }
}
