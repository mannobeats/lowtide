import LowtideKit
import SwiftUI

/// Launch, the menu bar icon, background work and URLs. The app stays in
/// the menu bar when its window closes, and leaves the Dock (`DockPresence`).
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        Shell.prepare()
        followSystemAppearance()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DockPresence.start()
        statusItem = StatusItemController()
        // Spaces give each other their data before any of them starts.
        Integration.wire()
        AppsLifecycle.launch()
        Updater.shared.launch()
        CleanupLifecycle.launch()
        ProtectionLifecycle.launch()
        NetworkLifecycle.launch()
        SystemLifecycle.launch()
        TerminalLifecycle.launch()
        ServersLifecycle.launch()
        ToolchainLifecycle.launch()
        ExtensionsLifecycle.launch()
        // The window opens on every launch, at login too. Its open action is
        // caught now, so a reopen or the menu bar can always bring it back.
        DispatchQueue.main.async { WindowRouter.catchOpenAction() }
        // First launch: onboarding (never over a page capture or a self-test).
        if !ProcessInfo.processInfo.arguments.contains("--page") { OnboardingWindow.showIfNeeded() }
        if ProcessInfo.processInfo.arguments.contains("--selftest") {
            Task { await SelfTest.run() }
        }
    }

    /// Teardown that awaits something (⌘Space handed back to Spotlight, runs
    /// stopped) happens while the app still runs, at most 4 s, instead of
    /// blocking the main thread in `applicationWillTerminate`.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        var replied = false
        func reply() {
            guard !replied else { return }
            replied = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        Task {
            async let protection: Void = ProtectionLifecycle.finish()
            async let extensions: Void = ExtensionsLifecycle.finish()
            _ = await (protection, extensions)
            reply()
        }
        // On the main queue, not Task.sleep: it quits even if Swift's
        // thread pool is stuck.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { reply() }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppsLifecycle.terminate()
        CleanupLifecycle.terminate()
        ProtectionLifecycle.terminate()
        NetworkLifecycle.terminate()
        SystemLifecycle.terminate()
        TerminalLifecycle.terminate()
        ServersLifecycle.terminate()
        ToolchainLifecycle.terminate()
        ExtensionsLifecycle.terminate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // The window always opens fresh on its page: restoring saved state after
    // a crash brought the app back with no main window at all.
    func applicationShouldSaveApplicationState(_ app: NSApplication) -> Bool { false }
    func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool { false }

    // Nonisolated, then onto the main queue: with no window yet, the
    // MainActor check AppKit's reopen call goes through crashed (a debug
    // build, every time).
    nonisolated func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { DispatchQueue.main.async { WindowRouter.showMain() } }
        return true
    }

    /// `lowtide://open/network/live`, `lowtide://action/<id>`.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { URLRouter.handle(url) }
    }

    /// "Automatic" follows the Mac's light or dark mode.
    private func followSystemAppearance() {
        let read = { UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" }
        ThemeStore.shared.systemDark = read()
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { _ in
            let dark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
            MainActor.assumeIsolated { ThemeStore.shared.systemDark = dark }
        }
    }
}

/// Every feature is reachable by URL: `lowtide://open/<page>` and
/// `lowtide://action/<action id>`.
enum URLRouter {
    static func handle(_ url: URL) {
        guard url.scheme == "lowtide" else { return }
        let path = ([url.host() ?? ""] + url.pathComponents.filter { $0 != "/" }).joined(separator: "/")
        if path.hasPrefix("open/"), let page = Page(rawValue: String(path.dropFirst(5))) {
            AppModel.shared.show(page)
        } else if path.hasPrefix("action/") {
            let id = String(path.dropFirst(7))
            ActionRegistry.all.first { $0.id == id }?.run()
        } else if path == "open" || path.isEmpty {
            WindowRouter.showMain()
        }
    }
}
