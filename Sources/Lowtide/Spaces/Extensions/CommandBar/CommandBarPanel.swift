import AppKit
import LowtideKit
import SwiftUI

/// The command bar: a floating panel summoned by a global shortcut from any
/// app, like Spotlight. It's a non-activating `NSPanel`: it takes the
/// keyboard without bringing Lowtide forward, so the app you were in stays
/// active behind it, and it goes away when it loses focus.
///
/// One fixed size (only the compact empty bar is shorter), so typing never
/// resizes the window: the list fills it and the footer stays put.
@Observable
final class CommandBarPanel {
    static let shared = CommandBarPanel()

    static let width: CGFloat = 750
    static let height: CGFloat = 474
    /// The field alone (the compact bar, empty).
    static let compactHeight: CGFloat = 56
    static let radius: CGFloat = 16

    let model = CommandBarModel(host: .panel)
    private(set) var isOpen = false
    /// Why the shortcut isn't working, for the Command bar page.
    private(set) var hotkeyProblem: String?
    /// Spotlight's own ⌘Space, when it has been read.
    private(set) var spotlight: SpotlightHotkey.State?
    private(set) var changingSpotlight = false
    private(set) var spotlightNote: String?

    @ObservationIgnored private var panel: BarPanel?
    @ObservationIgnored private var backdrop: NSVisualEffectView?
    @ObservationIgnored private var hotkey: GlobalHotkey?
    @ObservationIgnored private var resignObserver: NSObjectProtocol?
    private var enabled = false
    /// Opened by `--bar` or `--ask` for a snapshot: stays up when the main
    /// window takes focus at launch.
    var pinned = false

    /// Snapshot and self-test copies of the app leave the person's shortcuts alone.
    static let quiet = ProcessInfo.processInfo.arguments.contains { $0 == "--page" || $0 == "--selftest" }
    static let tookSpotlightKey = "commandbar.tookSpotlight"

    private init() {
        model.onHide = { [weak self] in self?.hide() }
    }

    // MARK: Lifecycle

    /// The extension switched on: the shortcut works, ⌘Space comes back if it was ours.
    func start() {
        enabled = true
        if hotkey == nil { hotkey = GlobalHotkey { [weak self] in self?.toggle() } }
        applyHotkey()
        Task { await reconcileSpotlight() }
        Task {
            try? await Task.sleep(for: .seconds(2))
            self.model.data.refresh()
            // The apps, panes and facts land first, so the warm list is the real one.
            try? await Task.sleep(for: .seconds(1.5))
            self.prewarm()
        }
    }

    /// The panel, its views and the first list made and laid out off screen,
    /// with the data loaded, so even the first ⌘Space after launch opens at once.
    private func prewarm() {
        guard enabled, panel == nil else { return }
        let panel = makePanel()
        model.recompute()
        // Shown once, invisible and not key: the window server sets up its
        // backing and the backdrop now instead of on the first ⌘Space.
        place(panel, over: nil)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    /// The extension switched off: no shortcut, and ⌘Space goes back to Spotlight.
    func stop() {
        enabled = false
        hide()
        hotkey?.unregister()
        if UserDefaults.standard.bool(forKey: Self.tookSpotlightKey) {
            Task { try? await self.giveBackSpotlight(next: .defaultBar) }
        }
    }

    /// At quit ⌘Space always goes back to Spotlight, so it never goes dead
    /// while Lowtide isn't running; the next launch takes it again.
    func terminate() async {
        hotkey?.unregister()
        guard !Self.quiet, UserDefaults.standard.bool(forKey: Self.tookSpotlightKey) else { return }
        _ = try? await SpotlightHotkey().set(enabled: true)
    }

    // MARK: Showing

    func toggle() {
        if isOpen { hide() } else { show() }
    }

    /// Opens the bar on the screen under the pointer, or over `window`.
    /// `keeping` shows it again as it was (to show a failure).
    func show(keeping: Bool = false, ask: Bool = false, question: String? = nil, over window: NSWindow? = nil) {
        let panel = panel ?? makePanel()
        if !keeping { model.opened(ask: ask, question: question) }
        setHeight(compact: model.collapsed, panel: panel)
        place(panel, over: window)
        panel.orderFrontRegardless()
        panel.makeKey()
        isOpen = true
    }

    func hide() {
        guard isOpen else { return }
        isOpen = false
        panel?.orderOut(nil)
        model.reset()
    }

    /// Centred on the screen under the pointer, a fifth of the way down; or
    /// near the top of the window it was opened from.
    private func place(_ panel: NSPanel, over window: NSWindow?) {
        let height = panel.frame.height
        if let window, window.isVisible {
            let frame = window.frame
            panel.setFrameOrigin(NSPoint(x: frame.midX - Self.width / 2, y: frame.maxY - 70 - height))
            return
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.frame else { return }
        panel.setFrameOrigin(NSPoint(x: frame.midX - Self.width / 2, y: frame.maxY - frame.height * 0.2 - height))
    }

    /// The compact bar grows to full height once there's something to list,
    /// with its top edge fixed. On the next turn when it comes from a view
    /// update: resizing during SwiftUI's own layout pass is ignored.
    func compactChanged(_ compact: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel else { return }
            self.setHeight(compact: compact, panel: panel)
        }
    }

    private func setHeight(compact: Bool, panel: NSPanel) {
        let h = compact ? Self.compactHeight : Self.height
        guard abs(panel.frame.height - h) > 0.5 else { return }
        var frame = panel.frame
        frame.origin.y += frame.height - h
        frame.size.height = h
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    private func makePanel() -> BarPanel {
        let panel = BarPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        // Above normal and floating windows, like Spotlight.
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.title = "Command bar"

        // The frosted backdrop, rounded with a continuous corner (its mask
        // also shapes the window's shadow), and the content over it.
        let bounds = panel.contentRect(forFrameRect: panel.frame)
        let backdrop = NSVisualEffectView(frame: bounds)
        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.maskImage = Self.roundedMask(radius: Self.radius)
        backdrop.autoresizingMask = [.width, .height]
        let host = NSHostingView(rootView: PanelRoot(panel: self))
        host.sizingOptions = []
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        backdrop.addSubview(host)
        panel.contentView = backdrop
        self.backdrop = backdrop
        self.panel = panel
        applyGlass()

        // Hides when it loses focus, like Spotlight.
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.pinned else { return }
                self.hide()
            }
        }
        return panel
    }

    /// The backdrop follows the theme's light or dark. How see-through it
    /// is (the Glass setting) is the theme tint the content lays over it.
    func applyGlass() {
        guard let panel else { return }
        panel.appearance = NSAppearance(named: ThemeStore.shared.palette.dark ? .darkAqua : .aqua)
        panel.invalidateShadow()
    }

    /// The theme's panel colour over the backdrop: 0 is frosted, 100 clear.
    static var tint: Double {
        let level = Double(min(max(BarSettings.shared.prefs.glass, 0), 100)) / 100
        return 0.92 - level * 0.62
    }

    /// A stretchable rounded rectangle with a continuous corner.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // MARK: The shortcut

    func applyHotkey() {
        guard let hotkey else { return }
        let prefs = BarSettings.shared.prefs
        guard enabled, prefs.hotkeyEnabled, !Self.quiet else {
            hotkey.unregister()
            hotkeyProblem = nil
            return
        }
        do {
            try hotkey.register(prefs.hotkey)
            hotkeyProblem = nil
        } catch {
            hotkeyProblem = error.localizedDescription
        }
    }

    func readSpotlight() async {
        spotlight = try? await SpotlightHotkey().state()
    }

    /// Frees ⌘Space from Spotlight, then gives it to the bar. If macOS still
    /// won't hand it over, Spotlight gets it back so ⌘Space never goes dead.
    func takeSpotlight() async throws {
        guard !Self.quiet else { return }
        changingSpotlight = true
        defer { changingSpotlight = false }
        let wasOn = (try? await SpotlightHotkey().state().enabled) ?? true
        var freed: SpotlightHotkey.State?
        if wasOn { freed = try await SpotlightHotkey().set(enabled: false) }
        do {
            hotkey?.unregister()
            try hotkey?.register(.commandSpace)
        } catch {
            if wasOn { _ = try? await SpotlightHotkey().set(enabled: true) }
            applyHotkey()
            await readSpotlight()
            throw error
        }
        UserDefaults.standard.set(true, forKey: Self.tookSpotlightKey)
        BarSettings.shared.prefs.hotkey = .commandSpace
        BarSettings.shared.prefs.hotkeyEnabled = true
        spotlightNote = freed?.needsLogout == true ? "Log out and back in to finish." : nil
        await readSpotlight()
    }

    /// The bar lets go of ⌘Space before Spotlight takes it again.
    func giveBackSpotlight(next: Hotkey) async throws {
        changingSpotlight = true
        defer { changingSpotlight = false }
        if BarSettings.shared.prefs.hotkey == .commandSpace { hotkey?.unregister() }
        if BarSettings.shared.prefs.hotkey == .commandSpace { BarSettings.shared.prefs.hotkey = next }
        let state = try await SpotlightHotkey().set(enabled: true)
        UserDefaults.standard.set(false, forKey: Self.tookSpotlightKey)
        spotlightNote = state.needsLogout ? "Log out and back in to finish." : nil
        applyHotkey()
        await readSpotlight()
    }

    /// At launch: take ⌘Space back if it was ours when Lowtide quit, or
    /// give it to Spotlight if the bar no longer wants it (a crash, a
    /// changed setting).
    private func reconcileSpotlight() async {
        guard !Self.quiet, UserDefaults.standard.bool(forKey: Self.tookSpotlightKey) else { return }
        let prefs = BarSettings.shared.prefs
        if enabled, prefs.hotkeyEnabled, prefs.hotkey == .commandSpace {
            try? await takeSpotlight()
        } else {
            try? await giveBackSpotlight(next: prefs.hotkey == .commandSpace ? .defaultBar : prefs.hotkey)
        }
    }
}

/// A panel that can take the keyboard while non-activating.
final class BarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The panel's SwiftUI content, in the app's theme.
private struct PanelRoot: View {
    let panel: CommandBarPanel
    private var themes = ThemeStore.shared

    init(panel: CommandBarPanel) { self.panel = panel }

    var body: some View {
        let palette = themes.palette
        let shape = RoundedRectangle(cornerRadius: CommandBarPanel.radius, style: .continuous)
        CommandBarContent(model: panel.model, chrome: .panel)
            .frame(width: CommandBarPanel.width)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(palette.panel.opacity(CommandBarPanel.tint).color)
            .clipShape(shape)
            // A hairline edge, lighter at the top, as macOS draws its own panels.
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(palette.dark ? 0.16 : 0.5), .white.opacity(palette.dark ? 0.05 : 0.2)],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .onChange(of: panel.model.collapsed) { _, compact in panel.compactChanged(compact) }
            .environment(\.palette, palette)
            .environment(\.privacy, AppModel.shared.privacy)
            .environment(\.spaceHue, SpaceID.extensions.hue)
            .preferredColorScheme(themes.colorScheme)
            .tint(themes.palette.brand.color)
            .onChange(of: themes.palette) { panel.applyGlass() }
    }
}
