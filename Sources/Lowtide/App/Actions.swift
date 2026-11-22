import LowtideKit
import SwiftUI

/// Something to do that isn't a page: New Terminal, Quick Connect, Empty
/// Caches. ⌘K, the command bar and the menus list the same actions.
struct AppAction: Identifiable {
    let id: String
    var title: String
    var subtitle: String?
    var symbol: String
    /// One of the app's own glyphs, drawn instead of the SF Symbol.
    var glyph: String? = nil
    var keywords: String = ""
    var space: SpaceID?
    /// Run from the floating bar, it brings Lowtide's window forward first.
    /// False for actions on the app you were in (dictation).
    var opensWindow = true
    let run: @MainActor () -> Void
}

/// Every action, from the app and each space. A space adds its actions in
/// `Spaces/<Space>/<Space>Actions.swift`.
enum ActionRegistry {
    static var all: [AppAction] {
        core + AppsActions.all + CleanupActions.all + ProtectionActions.all + NetworkActions.all
            + SystemActions.all + TerminalActions.all + ServersActions.all + ToolchainActions.all
            + ExtensionsActions.all
    }

    private static var core: [AppAction] {
        [
            AppAction(id: "settings", title: "Settings…", symbol: "gearshape", glyph: "settings", keywords: "preferences options") {
                WindowRouter.showSettings()
            },
            AppAction(id: "privacy", title: AppModel.shared.privacy ? "Turn Privacy Mode Off" : "Turn Privacy Mode On",
                      subtitle: "Hide addresses, hosts and names on screen", symbol: "eye.slash", glyph: "privacy",
                      keywords: "hide screenshot redact") {
                AppModel.shared.privacy.toggle()
            },
        ]
    }
}

/// One result in ⌘K or the command bar.
struct CommandItem: Identifiable {
    enum Kind { case page(Page), action(AppAction) }
    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let symbol: String
    var glyph: String?
    let score: Int

    @MainActor func perform() {
        switch kind {
        case .page(let page): AppModel.shared.show(page)
        case .action(let action): action.run()
        }
    }

    /// Pages and actions matching `query`, best first. With no query: the
    /// current space's pages, then the most useful actions.
    @MainActor static func search(_ query: String, limit: Int = 40) -> [CommandItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var items: [CommandItem] = []
        for page in Page.allCases {
            let score = q.isEmpty ? (page.space == AppModel.shared.page.space ? 50 : 0)
                : Fuzzy.best(q, title: "\(page.space.title) \(page.title)", keywords: page.keywords)
                    .map { max($0, Fuzzy.score(q, page.title) ?? 0) }
            guard let score else { continue }
            items.append(CommandItem(id: "page:\(page.id)", kind: .page(page), title: page.title,
                                     subtitle: page.space == .home ? "Page" : page.space.title, symbol: "doc",
                                     glyph: page.glyph, score: score + 5))
        }
        for action in ActionRegistry.all {
            let score = q.isEmpty ? 10 : Fuzzy.best(q, title: action.title, keywords: action.keywords)
            guard let score else { continue }
            items.append(CommandItem(id: "action:\(action.id)", kind: .action(action), title: action.title,
                                     subtitle: action.subtitle ?? "Action", symbol: action.symbol,
                                     glyph: action.glyph, score: score))
        }
        return Array(items.sorted { $0.score > $1.score }.prefix(limit))
    }
}
