import AppKit
import LowtideKit
import SwiftUI

/// The widgets in the menu bar: one extra status item showing one image,
/// redrawn every second while on. A template in Mono, otherwise drawn for
/// the menu bar's current appearance. A click opens the stats popover; a
/// right-click shows a short menu.
final class WidgetsStatusItem: NSObject {
    static let shared = WidgetsStatusItem()

    private var item: NSStatusItem?
    private var loop: Task<Void, Never>?
    private var last: WidgetBitmap?

    var isRunning: Bool { item != nil }

    func start() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "dev.lowtide.widgets"
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseUp])
            // So the menu bar manager's lists name it.
            button.setAccessibilityLabel("Menu bar widgets")
            button.imagePosition = .imageOnly
        }
        self.item = item
        SystemModel.shared.retain("widgets")
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.redraw()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        StatsPopover.shared.hide()
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        last = nil
        SystemModel.shared.release("widgets")
    }

    /// Whether the menu bar behind the widgets is dark, as AppKit resolved it
    /// for the button: the system setting and, on a clear menu bar, the
    /// wallpaper under it. Asked every tick, since no setting reports that.
    private var menuBarDark: Bool {
        guard let button = item?.button else { return true }
        return button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// Draws the strip now; unchanged pixels skip the status item.
    func redraw() {
        guard let item, let button = item.button else { return }
        let store = WidgetsStore.shared
        let scale = Double(button.window?.backingScaleFactor ?? 2)
        let bitmap = WidgetDrawing.strip(store.resolved(), readings: WidgetDrawing.readings, dark: menuBarDark, scale: scale)
        guard bitmap != last else { return }
        last = bitmap
        guard let bitmap else {
            // Nothing this Mac can show (an empty list, a battery widget on a
            // desktop): a small placeholder keeps the popover reachable.
            item.length = NSStatusItem.variableLength
            button.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "Menu bar widgets")
            button.image?.isTemplate = true
            return
        }
        let image = NSImage(cgImage: bitmap.image, size: bitmap.size)
        image.isTemplate = bitmap.template
        button.image = image
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            StatsPopover.shared.toggle(below: sender)
        }
    }

    private func showMenu() {
        guard let item else { return }
        StatsPopover.shared.hide()
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Lowtide", action: #selector(openMain), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Widget Settings…", action: #selector(openSettings), keyEquivalent: "").target = self
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func openMain() { AppModel.shared.show(.systemOverview) }
    @objc private func openSettings() { AppModel.shared.show(.widgets) }
}

/// The panel under the widgets: non-activating, so opening it leaves the
/// app you were in active, and hides when it loses focus.
final class StatsPopover: NSObject, NSWindowDelegate {
    static let shared = StatsPopover()

    private var panel: StatsPanel?
    /// A click on the widgets takes focus from the panel before the click
    /// arrives: that click closes, it doesn't reopen.
    private var hiddenAt = Date.distantPast

    var isOpen: Bool { panel?.isVisible ?? false }

    func toggle(below button: NSStatusBarButton) {
        if isOpen {
            hide()
        } else if Date.now.timeIntervalSince(hiddenAt) > 0.3 {
            show(below: button)
        }
    }

    private func makePanel() -> StatsPanel {
        let panel = StatsPanel(contentRect: NSRect(x: 0, y: 0, width: StatsPopoverView.width, height: 420),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        let host = NSHostingController(rootView: StatsPopoverRoot())
        host.sizingOptions = [.preferredContentSize]
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = .clear
        panel.contentViewController = host
        return panel
    }

    private func show(below button: NSStatusBarButton) {
        let panel = panel ?? makePanel()
        self.panel = panel
        guard let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? anchor
        let width = StatsPopoverView.width
        let margin = Space.sm
        // Centred under the widgets, kept on their screen.
        let x = min(max(anchor.midX - width / 2, visible.minX + margin), visible.maxX - width - margin)
        panel.anchorTop = anchor.minY - 5
        panel.setFrame(NSRect(x: x, y: anchor.minY - 5 - panel.frame.height, width: width, height: panel.frame.height), display: false)
        SystemModel.shared.retain("widgets.popover", [.metrics, .processes])
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        hiddenAt = .now
        panel.orderOut(nil)
        SystemModel.shared.release("widgets.popover")
    }

    func windowDidResignKey(_ notification: Notification) { hide() }
}

/// A panel that can take focus (so it hides when it loses it) and keeps its
/// top edge under the menu bar while its content grows or shrinks.
final class StatsPanel: NSPanel {
    var anchorTop: CGFloat?

    override var canBecomeKey: Bool { true }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var frame = frameRect
        if let anchorTop { frame.origin.y = anchorTop - frame.height }
        super.setFrame(frame, display: flag)
    }

    override func cancelOperation(_ sender: Any?) { StatsPopover.shared.hide() }
}

/// The popover in the app's theme.
private struct StatsPopoverRoot: View {
    private var themes = ThemeStore.shared
    var body: some View {
        StatsPopoverView()
            .environment(\.palette, themes.palette)
            .environment(\.privacy, AppModel.shared.privacy)
            .preferredColorScheme(themes.colorScheme)
            .tint(themes.palette.brand.color)
    }
}
