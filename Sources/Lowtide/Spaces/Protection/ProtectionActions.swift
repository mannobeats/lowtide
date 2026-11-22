import SwiftUI

/// The Protection space's actions for ⌘K, the command bar and menus.
enum ProtectionActions {
    static var all: [AppAction] {
        let model = ProtectionModel.shared
        let planted = (model.decoys?.planted ?? 0) > 0
        var actions = [
            AppAction(id: "protection.scan-secrets", title: model.scanning ? "Scanning for Secrets…" : "Scan for Exposed Secrets",
                      subtitle: "Keys in .env files, tool configs and shell history", symbol: "key.viewfinder",
                      glyph: "secrets", keywords: "tokens leaks env credentials", space: .protection) {
                model.secretsView = .exposed
                AppModel.shared.show(.secrets)
                model.scanSecrets()
            },
            AppAction(id: "protection.decoys", title: "Show Decoy Keys", subtitle: "Fake keys that alarm when read",
                      symbol: "key", glyph: "decoys", keywords: "canary tripwire stealer", space: .protection) {
                model.openSecrets(.decoys)
            },
            AppAction(id: "protection.rescan-permissions", title: "Rescan Permissions",
                      subtitle: "Privacy grants, login items and launch agents", symbol: "arrow.clockwise",
                      glyph: "permissions", keywords: "tcc login items launch agents", space: .protection) {
                AppModel.shared.show(.permissions)
                Task { await model.loadPermissions(force: true) }
            },
        ]
        if !planted {
            actions.append(AppAction(id: "protection.plant-decoys", title: "Plant Decoy Keys",
                                     subtitle: "Catch credential stealers", symbol: "key.horizontal", glyph: "decoys",
                                     keywords: "canary", space: .protection) {
                model.openSecrets(.decoys)
                Task { await model.plantDecoys() }
            })
        }
        return actions
    }
}
