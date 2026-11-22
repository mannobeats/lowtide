import LowtideKit
import SwiftUI

/// Where the main window is, and what floats over it. There is no router:
/// a page is a value, and each space remembers its last page.
@Observable
final class AppModel {
    static let shared = AppModel()

    var page: Page {
        didSet {
            guard page != oldValue else { return }
            lastPage[page.space] = page
            UserDefaults.standard.set(page.rawValue, forKey: "page")
            if !travelling {
                backStack.append(oldValue)
                if backStack.count > 50 { backStack.removeFirst() }
                forwardStack.removeAll()
            }
        }
    }
    private var lastPage: [SpaceID: Page] = [:]
    /// Pages visited, for Back (⌘[) and Forward (⌘]) as in Finder and Safari.
    private(set) var backStack: [Page] = []
    private(set) var forwardStack: [Page] = []
    @ObservationIgnored private var travelling = false
    var paletteOpen = false
    /// First-launch setup is showing over the window.
    var onboarding = false
    /// Hides addresses, hostnames and user names on screen (for screenshots and calls).
    var privacy: Bool = UserDefaults.standard.bool(forKey: "privacy") {
        didSet { UserDefaults.standard.set(privacy, forKey: "privacy") }
    }
    /// The source list is tucked away (View › Hide Sidebar, ⌃⌘S).
    var sidebarHidden: Bool = UserDefaults.standard.bool(forKey: "sidebarHidden") {
        didSet { UserDefaults.standard.set(sidebarHidden, forKey: "sidebarHidden") }
    }
    /// The main window is in full screen.
    var fullScreen = false
    /// Full screen on the terminal or the live map: only the work, edge to
    /// edge (no rail, sidebar or tabs row). Other pages keep their chrome.
    var immersive: Bool { fullScreen && (page == .sessions || page == .networkLive) }
    /// The current space has a source list to show or hide.
    var hasSidebar: Bool { page.space.navigation == .sidebar }

    init() {
        // `--page network/live` opens a page directly (snapshots, tests).
        let args = ProcessInfo.processInfo.arguments
        let launch = args.firstIndex(of: "--page").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        page = (launch ?? UserDefaults.standard.string(forKey: "page")).flatMap(Page.init(rawValue:)) ?? .home
    }

    func open(_ page: Page) {
        withAnimation(Motion.page) { self.page = page }
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(page)
        travel(to: previous)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(page)
        travel(to: next)
    }

    private func travel(to target: Page) {
        travelling = true
        defer { travelling = false }
        open(target)
    }

    func toggleSidebar() {
        withAnimation(Motion.base) { sidebarHidden.toggle() }
    }

    /// A space's last page, or its first.
    func open(_ space: SpaceID) {
        open(lastPage[space] ?? space.pages.first ?? .home)
    }

    /// Brings the main window forward on a page.
    func show(_ page: Page) {
        open(page)
        WindowRouter.showMain()
    }
}

/// Opens and finds the app's windows from anywhere (menus, status item,
/// panels, URLs).
enum WindowRouter {
    @MainActor static var openWindow: OpenWindowAction?

    static func showMain() {
        DockPresence.show()
        activate()
        if let window = NSApp.windows.first(where: isMain) {
            raise(window)
        } else if let openWindow {
            openWindow(id: "main")
        } else {
            // Asked before launch got as far as catching the action: once it has.
            catchOpenAction()
            DispatchQueue.main.async { if let openWindow { openWindow(id: "main") } }
        }
    }

    /// SwiftUI's open action, caught at launch by a view of our own in an
    /// invisible panel. The main window's view knows it too, but only once
    /// that window has appeared; when it never has this run, SwiftUI
    /// doesn't list it in the Window menu either, and nothing else could
    /// bring it up (the app sat in the menu bar with no way to its window).
    static func catchOpenAction() {
        guard openWindow == nil, catcher == nil else { return }
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: OpenActionCatcher())
        panel.orderFrontRegardless()
        catcher = panel
    }

    @MainActor private static var catcher: NSPanel?

    fileprivate static func caught(_ action: OpenWindowAction) {
        if openWindow == nil { openWindow = action }
        catcher?.orderOut(nil)
        catcher = nil
    }

    /// Key and in front. If macOS still keeps another app active, the
    /// window comes over it anyway, not behind it; the next click makes
    /// Lowtide active.
    static func raise(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        if !NSApp.isActive { window.orderFrontRegardless() }
    }

    /// Lowtide to the front. From the floating command bar the app isn't
    /// active (the bar is a non-activating panel), and macOS's cooperative
    /// activation can refuse a plain request: the forcing one is asked too.
    static func activate() {
        NSApp.activate()
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
    }

    static func isMain(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue == "main" || window.title == "Lowtide"
    }

    static func showSettings() {
        DockPresence.show()
        activate()
        openSettingsAction?()
    }

    @MainActor static var openSettingsAction: (() -> Void)?
}

private struct OpenActionCatcher: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View { Color.clear.onAppear { WindowRouter.caught(openWindow) } }
}

/// Lowtide lives in the menu bar. With its windows closed (the red button,
/// ⌘W) it leaves the Dock and the ⌘-Tab switcher and keeps running there;
/// opening a window brings its Dock icon back. Quit ends it.
enum DockPresence {
    static func start() {
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow else { return }
            // The window still counts as open while it closes: look once it's gone.
            DispatchQueue.main.async { MainActor.assumeIsolated { hideIfNoWindows(besides: window) } }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { if isAppWindow(window) { show() } }
        }
    }

    /// Back in the Dock, before the app activates so its menu bar comes too.
    static func show() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }

    /// The main window and Settings count; panels (the command bar, the
    /// dictation overlay, the Island, the menu bar shelf) don't.
    private static func isAppWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.styleMask.contains(.titled) && window.level == .normal
    }

    private static func hideIfNoWindows(besides closing: NSWindow) {
        let open = NSApp.windows.contains { $0 !== closing && isAppWindow($0) && ($0.isVisible || $0.isMiniaturized) }
        if !open, NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
    }
}
