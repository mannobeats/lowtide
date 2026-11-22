import AppKit

/// Whether the main window can be seen (not hidden, minimised or covered).
/// Animations that draw every frame (the radar, the live map) pause when
/// it can't, so Lowtide costs nothing while you work elsewhere.
@Observable
final class WindowVisibility {
    static let shared = WindowVisibility()
    private(set) var mainVisible = true

    private init() {
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSApplication.didHideNotification,
                     NSApplication.didUnhideNotification, NSWindow.willCloseNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { WindowVisibility.shared.update() }
            }
        }
    }

    private func update() {
        let main = NSApp.windows.first { $0.identifier?.rawValue == "main" || $0.title == "Lowtide" }
        let visible = !NSApp.isHidden && (main.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false)
        if visible != mainVisible { mainVisible = visible }
    }
}
