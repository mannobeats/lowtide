import AppKit
import LowtideKit

/// Lowtide's markers in the menu bar.
///
/// macOS 26, three, from left to right:
///
/// `always` | always-hidden icons | `hidden` | hidden icons | `chevron` | shown icons
///
/// The always-hidden section is optional: new icons appear at the far left,
/// so with it on they land always hidden. A marker hides everything to its
/// left by growing so wide that those icons no longer fit and macOS drops
/// them; it shrinks back to a thin line to show them.
///
/// macOS 27, two, from left to right:
///
/// `vault` | always-hidden icons | `divider` | hidden icons… shown icons
///
/// The `divider` is just too wide for the menu bar (`MenuBarFit`), so macOS
/// moves it, and everything left of it, into its own overflow behind «, and
/// « sits right beside the first shown icon. The optional `vault` is nearly
/// as wide as the open overflow, so the icons left of it never fit there.
/// No chevron: « is the way to them, and a second one would only repeat it.
///
/// Nothing is captured, moved or redrawn, so hiding needs no permission. The
/// markers keep their place across launches through their autosave names.
final class MenuBarMarkers: NSObject {
    /// Wider than any menu bar: everything to the left is pushed off.
    static let push: CGFloat = 10_000
    /// A shown marker: a hairline with room to grab it.
    static let line: CGFloat = 9
    private static let seededKey = "menubar.seeded"

    private var always: NSStatusItem?
    private var hidden: NSStatusItem?
    private var chevron: NSStatusItem?
    private var divider: NSStatusItem?
    private var vault: NSStatusItem?
    /// The chevron was clicked: (secondary, option).
    var onClick: ((Bool, Bool) -> Void)?

    var installed: Bool { chevron != nil || divider != nil }

    private static func positionKey(_ name: String) -> String {
        "NSStatusItem Preferred Position \(MenuBarLayout.markerPrefix)\(name)"
    }

    /// Where the markers first appear. A new status item lands left of every
    /// other icon, which on a full menu bar is under the notch, out of sight.
    /// So the chevron and the hidden marker start at the right end
    /// (positions count from the right), and every other icon starts hidden,
    /// as in Ice, one click from the bar under the chevron. After that, macOS
    /// remembers wherever they're dragged.
    private func seed() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.seededKey) else { return }
        defaults.set(0.0, forKey: Self.positionKey("chevron"))
        defaults.set(1.0, forKey: Self.positionKey("hidden"))
        defaults.set(true, forKey: Self.seededKey)
    }

    private func marker(_ name: String, label: String) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: Self.line)
        item.autosaveName = "\(MenuBarLayout.markerPrefix)\(name)"
        item.button?.setAccessibilityIdentifier("\(MenuBarLayout.markerPrefix)\(name)")
        item.button?.setAccessibilityLabel(label)
        return item
    }

    func install() {
        guard chevron == nil else { return }
        seed()
        let chevron = marker("chevron", label: "Show hidden menu bar icons")
        chevron.length = NSStatusItem.variableLength
        chevron.button?.target = self
        chevron.button?.action = #selector(click(_:))
        // Left and right mouse down, like any menu bar item.
        chevron.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        self.chevron = chevron
        hidden = marker("hidden", label: "Hidden icons start here")
    }

    /// macOS 27's divider. A new name, so a marker left from macOS 26 (or
    /// from before this worked on 27) doesn't come back somewhere that would
    /// suddenly hide icons people can see now.
    func installDivider() {
        guard divider == nil else { return }
        let item = marker("divider", label: "Icons left of this are hidden behind «")
        item.button?.image = nil
        divider = item
    }

    /// The divider's width, in points.
    var dividerWidth: Double { Double(divider?.length ?? MenuBarMarkers.line) }

    func setDivider(_ width: Double) {
        guard let divider, abs(Double(divider.length) - width) >= 0.5 else { return }
        divider.length = CGFloat(width)
    }

    /// macOS 27's always-hidden marker: added where a new status item lands,
    /// left of every icon, so turning it on hides nothing yet.
    func setVault(_ on: Bool) {
        if on, vault == nil {
            let item = marker("vault", label: "Always-hidden icons are left of this")
            item.button?.image = nil
            vault = item
        } else if !on, let item = vault {
            NSStatusBar.system.removeStatusItem(item)
            vault = nil
        }
    }

    var hasVault: Bool { vault != nil }
    var vaultWidth: Double { Double(vault?.length ?? MenuBarMarkers.line) }

    func setVault(width: Double) {
        guard let vault, abs(Double(vault.length) - width) >= 0.5 else { return }
        vault.length = CGFloat(width)
    }

    func remove() {
        for item in [always, hidden, chevron, divider, vault].compactMap({ $0 }) { NSStatusBar.system.removeStatusItem(item) }
        always = nil
        hidden = nil
        chevron = nil
        divider = nil
        vault = nil
    }

    /// Adds or takes away the always-hidden marker. A new one lands at the
    /// far left, past every icon, so turning the section on hides nothing yet.
    func setAlways(_ on: Bool, reveal: MenuBarReveal) {
        guard chevron != nil else { return }
        if on, always == nil {
            UserDefaults.standard.removeObject(forKey: Self.positionKey("always"))
            let item = marker("always", label: "Always-hidden icons start here")
            show(item, reveal == .all)
            always = item
        } else if !on, let item = always {
            NSStatusBar.system.removeStatusItem(item)
            always = nil
        }
    }

    @objc private func click(_ sender: Any?) {
        let event = NSApp.currentEvent
        let flags = event?.modifierFlags ?? []
        let secondary = event?.type == .rightMouseDown || flags.contains(.control)
        onClick?(secondary, flags.contains(.option))
    }

    private func show(_ item: NSStatusItem, _ shown: Bool, push: CGFloat = MenuBarMarkers.push) {
        item.length = shown ? Self.line : push
        item.button?.image = shown ? Self.hairline : nil
    }

    /// macOS 26: shows or hides the sections.
    func set(_ reveal: MenuBarReveal) {
        if let hidden { show(hidden, reveal != .none) }
        if let always { show(always, reveal == .all) }
        let (symbol, label) = reveal == .none
            ? ("chevron.left", "Show hidden menu bar icons") : ("chevron.right", "Hide menu bar icons")
        chevron?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        chevron?.button?.toolTip = reveal == .none ? "Show hidden icons (⌥-click for all)" : "Hide icons"
    }

    /// The thin rule a shown marker draws, tinted by macOS like any icon.
    private static let hairline: NSImage = {
        let image = NSImage(size: NSSize(width: 5, height: 16), flipped: false) { rect in
            NSColor.black.set()
            NSRect(x: (rect.width - 1) / 2, y: 3, width: 1, height: rect.height - 6).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()

    /// The markers' edges as the menu bar has them now.
    func edges() -> MenuBarEdges? {
        func edge(_ item: NSStatusItem?) -> (Double, Double)? {
            guard let frame = item?.button?.window?.frame else { return nil }
            return (frame.minX, frame.maxX)
        }
        guard let chevronEdge = edge(chevron), let hiddenEdge = edge(hidden),
              let bottom = chevron?.button?.window?.frame.minY else { return nil }
        return MenuBarEdges(always: edge(always), hidden: hiddenEdge, chevron: chevronEdge, bottom: bottom)
    }

    /// The chevron's frame on screen (AppKit coordinates).
    var chevronFrame: CGRect? { chevron?.button?.window?.frame }
}
