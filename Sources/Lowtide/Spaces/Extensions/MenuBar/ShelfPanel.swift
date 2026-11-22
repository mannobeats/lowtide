import AppKit
import LowtideKit
import SwiftUI

/// The bar under the chevron, like Bartender's (macOS 26), or under macOS's
/// own « (27, from Show Hidden): a strip of the hidden icons, always-hidden
/// ones included, just below the menu bar; clicking one opens its menu,
/// dragging one up shows it in the menu bar, along the bar reorders.
/// A non-activating panel, so the app you were in stays active; it goes
/// away when you click elsewhere or press Esc.
final class ShelfPanel: NSObject, NSWindowDelegate {
    static let shared = ShelfPanel()
    static let height: CGFloat = 44
    /// Below the menu bar, and in from the screen's edge.
    static let drop: CGFloat = 6
    static let margin: CGFloat = 8
    static let radius: CGFloat = 12

    let model = ShelfModel()
    private var panel: ShelfWindow?
    private var host: NSView?
    /// When the bar last went away: the click on the chevron that took its
    /// focus arrives after, and must close rather than reopen it.
    private var hiddenAt = Date.distantPast
    private var watch: Task<Void, Never>?
    private var wanted = false

    var isVisible: Bool { panel?.isVisible ?? false }

    func configure(_ on: Bool) {
        wanted = on
        if !on { hide(); panel = nil }
    }

    /// Made on first show: SwiftUI doesn't present the main window at launch
    /// when the app already has one, even a hidden panel.
    private func makePanel() -> ShelfWindow {
        if let panel { return panel }
        let panel = ShelfWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: Self.height),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        // Dark like the menu bar's own menus over a dark bar.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.hide() }
        let glass = NSVisualEffectView()
        glass.material = .menu
        glass.state = .active
        glass.blendingMode = .behindWindow
        glass.wantsLayer = true
        glass.layer?.cornerRadius = Self.radius
        glass.layer?.masksToBounds = true
        let host = HUDHostingView(rootView: ShelfView(model: model))
        // The bar sizes the window itself, under the chevron.
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(host)
        self.host = host
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: glass.leadingAnchor), host.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            host.topAnchor.constraint(equalTo: glass.topAnchor), host.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])
        panel.contentView = glass
        self.panel = panel
        return panel
    }

    /// The chevron's click: drops the bar, or puts it away.
    func toggle() {
        if isVisible { hide() } else if Date().timeIntervalSince(hiddenAt) > 0.3 { show() }
    }

    func show() {
        guard wanted else { return }
        let panel = makePanel()
        model.error = nil
        // Its content's own width, measured now: the bar may hold other
        // icons than when it was last down.
        host?.layoutSubtreeIfNeeded()
        let width = host?.fittingSize.width ?? 0
        place(width: width > 0 ? width : model.width)
        panel.orderFrontRegardless()
        panel.makeKey()
        watch?.cancel()
        watch = Task { await MenuBarManager.shared.watch() }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        hiddenAt = Date()
        watch?.cancel()
        watch = nil
        panel.orderOut(nil)
    }

    /// The bar's width follows what it holds.
    func resize(_ width: CGFloat) {
        guard isVisible else { return }
        place(width: width)
    }

    /// Right-aligned under the chevron (macOS 26) or « (27), kept on its
    /// screen. Before « was seen, under the right end of the menu bar's
    /// left half, where « sits.
    private func place(width: CGFloat) {
        guard let panel else { return }
        let manager = MenuBarManager.shared
        let frame = manager.markers.chevronFrame
        let main = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
        guard let right = manager.chevronSpan.map({ CGFloat($0.x + $0.width) }) ?? frame?.maxX
                ?? main.map({ $0.auxiliaryTopRightArea?.minX ?? $0.frame.midX }) else { return }
        let width = max(width, 120)
        let screen = NSScreen.screens.first { right > $0.frame.minX && right <= $0.frame.maxX } ?? NSScreen.main
        var x = right - width
        // Just under the menu bar of the chevron's screen.
        var top = frame?.minY ?? (screen?.visibleFrame.maxY ?? 0)
        if let screen {
            let low = screen.frame.minX + Self.margin, high = screen.frame.maxX - Self.margin - width
            x = min(max(x, low), max(high, low))
            let bar = screen.frame.maxY - screen.visibleFrame.maxY
            top = screen.frame.maxY - (bar > 0 ? bar : 24)
        }
        panel.setFrame(CGRect(x: x, y: top - Self.drop - Self.height, width: width, height: Self.height), display: true)
    }

    func windowDidResignKey(_ notification: Notification) { hide() }
}

/// The bar's window: it takes the keyboard (for Esc) without activating the app.
final class ShelfWindow: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

@Observable
final class ShelfModel {
    var error: String?
    var busy = false
    var width: CGFloat = 320
}

/// The bar's content: the hidden icons in a row, then a way to the settings.
struct ShelfView: View {
    let model: ShelfModel
    private var manager = MenuBarManager.shared
    @State private var dragging: String?
    @State private var lifting = false
    @State private var frames: [String: CGRect] = [:]

    init(model: ShelfModel) { self.model = model }

    var body: some View {
        let hidden = manager.entries.filter { $0.section != .shown }
        HStack(spacing: 0) {
            if !manager.trusted {
                Text("Allow Accessibility to see hidden icons here.").padding(.horizontal, 6)
                Button("Allow") { Permission.accessibility.request() }
                    .buttonStyle(ShelfButtonStyle(filled: true))
            } else if model.error != nil || hidden.isEmpty {
                Text(model.error ?? (manager.loaded ? "Nothing hidden. Drag icons here in Extensions." : "Reading the menu bar…"))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 384, alignment: .leading)
                    .padding(.horizontal, 6)
                    .help(model.error ?? "")
                settings
            } else {
                ForEach(hidden) { entry in icon(entry) }
                Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 20).padding(.horizontal, 4)
                settings
            }
        }
        .font(.ui(.xs))
        .foregroundStyle(.white.opacity(0.75))
        .padding(.horizontal, Space.sm)
        .frame(height: ShelfPanel.height)
        .fixedSize()
        .coordinateSpace(.named("shelf"))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            model.width = width
            ShelfPanel.shared.resize(width)
        }
        .overlay {
            if lifting {
                Text("Let go to show it in the menu bar")
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black.opacity(0.7), in: .rect(cornerRadius: ShelfPanel.radius))
            }
        }
        .opacity(model.busy ? 0.6 : 1)
        .allowsHitTesting(!model.busy)
        .environment(\.colorScheme, .dark)
    }

    private var settings: some View {
        Button { manager.showSettings() } label: {
            Image(systemName: "gearshape").font(.ui(.sm))
        }
        .buttonStyle(ShelfButtonStyle())
        .help("Menu bar settings")
        .accessibilityLabel("Menu bar settings")
    }

    private func icon(_ entry: MenuBarEntry) -> some View {
        let name = entry.name
        return Button {
            // A drag that just ended isn't a click.
            if dragging == nil { manager.open(entry.key) { model.error = $0 } }
        } label: {
            MenuBarItemIcon(key: entry.key, appPath: entry.item.appPath, size: 18, onDark: true)
                .frame(minWidth: 34, minHeight: 32)
                .padding(.horizontal, 2)
                .contentShape(.rect)
                .background(ShelfHover())
        }
        .buttonStyle(.plain)
        .opacity(dragging == entry.key ? 0.4 : 1)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("shelf")) } action: { frames[entry.key] = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .named("shelf"))
                .onChanged { drag in
                    dragging = entry.key
                    lifting = drag.location.y < 0
                }
                .onEnded { drag in
                    lifting = false
                    run(drop: entry.key, at: drag.location)
                    // Cleared after the button's own release has passed.
                    DispatchQueue.main.async { dragging = nil }
                }
        )
        .contextMenu { MenuBarItemMenu(entry: entry) { model.error = $0 } }
        .help(name)
        .accessibilityLabel(name)
    }

    /// Let go above the bar: over the menu bar, among the shown icons. Along
    /// the bar: before the first icon whose middle is right of it.
    private func run(drop key: String, at point: CGPoint) {
        let fail: (String) -> Void = { model.error = $0 }
        if point.y < 0 {
            manager.drop(key, at: NSEvent.mouseLocation.x, failed: fail)
        } else {
            let before = manager.entries.filter { $0.section != .shown && $0.key != key }
                .first { (frames[$0.key]?.midX ?? .infinity) > point.x }?.key
            manager.move(key, to: .hidden, before: before, failed: fail)
        }
    }
}

/// A hover highlight for the bar's icons.
private struct ShelfHover: View {
    @State private var hovering = false
    var body: some View {
        RoundedRectangle(cornerRadius: Radius.md)
            .fill(.white.opacity(hovering ? 0.12 : 0))
            .onHover { hovering = $0 }
            .animation(Motion.fast, value: hovering)
    }
}

/// The bar's own buttons: quiet white on the dark menu glass.
struct ShelfButtonStyle: ButtonStyle {
    var filled = false
    func makeBody(configuration: Configuration) -> some View {
        ShelfButtonBody(configuration: configuration, filled: filled)
    }
}

private struct ShelfButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let filled: Bool
    @State private var hovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(.white.opacity(hovering || filled ? 1 : 0.6))
            .padding(.horizontal, filled ? 10 : 0)
            .frame(minWidth: 28, minHeight: 28)
            .background(.white.opacity(filled ? (hovering ? 0.25 : 0.15) : (hovering ? 0.1 : 0)), in: .rect(cornerRadius: Radius.md))
            .contentShape(.rect)
            .onHover { hovering = $0 }
    }
}
