import AppKit
import SwiftUI

/// The mark in the menu bar: the app is always one click away, even with
/// its window closed. Spaces add lines to its menu through `StatusMenu`.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    override init() {
        super.init()
        item.button?.image = Logo.menuBar
        item.autosaveName = "dev.lowtide.main"
        item.isVisible = UserDefaults.standard.object(forKey: "showStatusItem") as? Bool ?? true
        menu.delegate = self
        item.menu = menu
    }

    func setVisible(_ visible: Bool) { item.isVisible = visible }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for line in StatusMenu.lines() {
            let entry = NSMenuItem(title: line.title, action: line.action == nil ? nil : #selector(runLine(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = line
            if let symbol = line.symbol { entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            menu.addItem(entry)
        }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        add("Open Lowtide", key: "o") { WindowRouter.showMain() }
        add("Search…", key: "k") {
            WindowRouter.showMain()
            AppModel.shared.paletteOpen = true
        }
        menu.addItem(.separator())
        add("Settings…", key: ",") { WindowRouter.showSettings() }
        add("Quit Lowtide", key: "q") { NSApp.terminate(nil) }
    }

    private var actions: [Int: () -> Void] = [:]

    private func add(_ title: String, key: String, _ action: @escaping () -> Void) {
        let entry = NSMenuItem(title: title, action: #selector(runAction(_:)), keyEquivalent: key)
        entry.target = self
        entry.tag = menu.numberOfItems
        actions[entry.tag] = action
        menu.addItem(entry)
    }

    @objc private func runAction(_ sender: NSMenuItem) { actions[sender.tag]?() }

    @objc private func runLine(_ sender: NSMenuItem) {
        (sender.representedObject as? StatusMenu.Line)?.action?()
    }
}

/// Lines at the top of the menu bar icon's menu ("3 updates waiting").
enum StatusMenu {
    final class Line {
        let title: String
        let symbol: String?
        let action: (() -> Void)?
        init(_ title: String, symbol: String? = nil, action: (() -> Void)? = nil) {
            self.title = title
            self.symbol = symbol
            self.action = action
        }
    }

    /// Providers the spaces register at launch.
    static var providers: [() -> [Line]] = []

    static func lines() -> [Line] { providers.flatMap { $0() } }
}
