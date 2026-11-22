import AppKit
import SwiftUI

/// An empty stretch of the window's top edge that behaves like a Mac
/// titlebar: drag to move the window (with the system's snapping and
/// tiling), double-click to do what System Settings › Desktop & Dock says.
/// SwiftUI's WindowDragGesture moves the window but ignores double-clicks.
struct TitlebarArea: NSViewRepresentable {
    enum DoubleClick {
        /// Fill, zoom, minimize or nothing, as the Mac is set up.
        case titlebar
        /// Nothing (the rail's empty middle: native sidebars don't zoom).
        case none
        /// Something of its own (the terminal's tab bar opens a tab).
        case run(@MainActor () -> Void)
    }

    var doubleClick: DoubleClick = .titlebar

    func makeNSView(context: Context) -> AreaView {
        let view = AreaView()
        view.doubleClick = doubleClick
        return view
    }

    func updateNSView(_ view: AreaView, context: Context) { view.doubleClick = doubleClick }

    final class AreaView: NSView {
        var doubleClick: DoubleClick = .titlebar

        // The titlebar of an inactive window drags on the first click.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            guard event.clickCount == 2 else {
                if event.clickCount == 1 { window.performDrag(with: event) }
                return
            }
            switch doubleClick {
            case .titlebar: window.titlebarDoubleClicked()
            case .none: break
            case .run(let action): action()
            }
        }
    }
}

extension NSWindow {
    /// What a double-click on a titlebar does, from System Settings ›
    /// Desktop & Dock ("Double-click a window's title bar to").
    func titlebarDoubleClicked() {
        let defaults = UserDefaults.standard
        switch defaults.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize":
            miniaturize(nil)
        case "None":
            break
        case "Fill":
            // The system's own Fill (it toggles back on the next double-click);
            // zoom where it doesn't exist.
            let fill = NSSelectorFromString("_zoomFill:")
            if responds(to: fill) { perform(fill, with: nil) } else { zoom(nil) }
        case "Maximize":
            zoom(nil)
        default:
            if defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick") { miniaturize(nil) } else { zoom(nil) }
        }
    }
}
