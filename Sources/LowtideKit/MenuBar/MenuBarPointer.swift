import CoreGraphics
import Foundation

/// The pointer and the screens, in Quartz coordinates (points, origin at the
/// top left of the main display), and the clicks and drags the menu bar
/// manager makes for you. Posting events is covered by Accessibility; window
/// layers and bounds need no Screen Recording.
public enum MenuBarPointer {
    /// The menu bar is at most this tall, notch included.
    static let menuBar = 44.0
    /// `kCGPopUpMenuWindowLevel`: open menus.
    static let menuLevel = 101
    /// `kCGStatusWindowLevel`: menu bar icons.
    static let statusLevel = 25

    public static func cursor() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    static func display(at point: CGPoint) -> CGDirectDisplayID? {
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        CGGetDisplaysWithPoint(point, 1, &display, &count)
        return count > 0 ? display : nil
    }

    /// The pointer is in a menu bar.
    public static func inMenuBar() -> Bool {
        let at = cursor()
        guard let display = display(at: at) else { return false }
        return at.y - CGDisplayBounds(display).origin.y < menuBar
    }

    /// Both ends of a span at height `y` are on a screen.
    public static func onScreen(x: Double, width: Double, y: Double) -> Bool {
        display(at: CGPoint(x: x + 1, y: y)) != nil && display(at: CGPoint(x: x + width - 1, y: y)) != nil
    }

    /// One window as the window server lists it.
    public struct Window: Sendable, Equatable {
        public var id: Int
        public var pid: Int
        public var layer: Int
        public var bounds: CGRect

        public init(id: Int, pid: Int, layer: Int, bounds: CGRect) {
            self.id = id
            self.pid = pid
            self.layer = layer
            self.bounds = bounds
        }

        init?(_ info: [String: Any]) {
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  let raw = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: raw) else { return nil }
            self.init(id: info[kCGWindowNumber as String] as? Int ?? 0, pid: info[kCGWindowOwnerPID as String] as? Int ?? 0,
                      layer: layer, bounds: bounds)
        }
    }

    /// On-screen windows, or every window (hidden status items included).
    public static func windows(all: Bool = false) -> [Window] {
        let options: CGWindowListOption = all ? .optionAll : [.optionOnScreenOnly, .excludeDesktopElements]
        let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap(Window.init)
    }

    /// A menu is open somewhere.
    public static func menuOpen(_ list: [Window] = windows()) -> Bool {
        list.contains { $0.layer == menuLevel }
    }

    /// An app has a popover or panel open: an on-screen window of its own
    /// above normal windows that isn't one of its menu bar icons (23 to 25
    /// are the menu bar's own levels; Control Center always has one there).
    public static func hasPopup(_ pid: Int32, _ list: [Window] = windows()) -> Bool {
        list.contains { $0.pid == Int(pid) && $0.layer > 0 && !(23...statusLevel).contains($0.layer) }
    }

    /// Left edges of the menu bar's icons on screen right of `x`, nearest first.
    public static func statusEdges(rightOf x: Double, _ list: [Window] = windows()) -> [Double] {
        list.filter { $0.layer == statusLevel && $0.bounds.minX >= x && $0.bounds.minY < menuBar }
            .map { $0.bounds.minX }.sorted()
    }

    /// The window drawing the icon whose middle is at `x`. (A little wider
    /// than the icon Accessibility reports.) Other apps' panels can sit at
    /// the same level: an icon's window is a strip at the top of the screen.
    public static func iconWindow(at x: Double, _ list: [Window] = windows(all: true)) -> Window? {
        list.first {
            $0.layer == statusLevel && abs($0.bounds.minY) < 1 && $0.bounds.height <= menuBar
                && x >= $0.bounds.minX && x < $0.bounds.maxX
        }
    }

    /// Lets the menu bar catch up between events without holding a thread.
    private static func pause(_ ms: Int) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }

    /// Runs `body`, then puts the pointer back where the person left it with
    /// a real move. A warp (`CGWarpMouseCursorPosition`) sends no events, so
    /// the icon the pointer was left on never hears it leave: its app shows
    /// its tooltip a second later where the pointer is now, and once that
    /// icon moves into the overflow nothing takes the tooltip down (the
    /// "UA Connect" and "Avid Link" labels stuck on screen). Moving off the
    /// menu bar first, then back, closes every tooltip an icon started.
    private static func keepingPointer(_ body: () async -> Void) async -> Bool {
        guard CGPreflightPostEventAccess() else { return false }
        let at = cursor()
        await body()
        await pause(60)
        restore(at)
        return true
    }

    /// Leaves the menu bar with real moves and lands at `point`.
    static func restore(_ point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        func move(_ to: CGPoint) {
            let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: to, mouseButton: .left)
            event?.flags = []
            event?.post(tap: .cghidEventTap)
        }
        let here = cursor()
        // Straight down out of the menu bar, then to where the person was.
        move(CGPoint(x: here.x, y: here.y + menuBar + 20))
        move(point)
        CGWarpMouseCursorPosition(point)
    }

    private static func post(_ type: CGEventType, _ at: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: at, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    /// A real click, for icons that don't take the Accessibility one.
    @discardableResult
    public static func click(_ at: CGPoint) async -> Bool {
        await keepingPointer {
            post(.mouseMoved, at)
            await pause(20)
            post(.leftMouseDown, at)
            await pause(30)
            post(.leftMouseUp, at)
        }
    }

    /// A real ⌘-drag on screen, as a person makes one: ⌘ goes down, the
    /// button goes down and is held, the pointer travels in steps a frame
    /// apart, rests, and lets go. macOS 27 draws every icon in one window, so
    /// this is the only way to move one (measured on 27.2: a drop at an
    /// icon's left edge lands just before it, from either side). Both ends
    /// must be on screen.
    @discardableResult
    public static func drag(from: CGPoint, toX: Double) async -> Bool {
        await keepingPointer {
            let source = CGEventSource(stateID: .hidSystemState)
            func post(_ type: CGEventType, _ at: CGPoint) {
                let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: at, mouseButton: .left)
                event?.flags = .maskCommand
                event?.post(tap: .cghidEventTap)
            }
            func command(_ down: Bool) {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: down)
                event?.flags = down ? .maskCommand : []
                event?.post(tap: .cghidEventTap)
            }
            command(true)
            await pause(30)
            post(.mouseMoved, from)
            await pause(40)
            post(.leftMouseDown, from)
            await pause(150)
            let steps = 20
            for step in 1...steps {
                let x = from.x + (toX - from.x) * Double(step) / Double(steps)
                post(.leftMouseDragged, CGPoint(x: x, y: from.y))
                await pause(16)
            }
            await pause(120)
            post(.leftMouseUp, CGPoint(x: toX, y: from.y))
            await pause(60)
            command(false)
        }
    }

    /// Event fields that aim a mouse event at one window and its process, so
    /// it lands even when the window is off screen: the target process (40),
    /// the window (51), and the window under and handling the pointer (91, 92).
    private static let targetPID: UInt32 = 40
    private static let targetWindows: [UInt32] = [51, 91, 92]

    private static func post(_ type: CGEventType, _ at: CGPoint, to window: Window) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: at, mouseButton: .left) else {
            return
        }
        event.flags = .maskCommand
        if let field = CGEventField(rawValue: targetPID) { event.setIntegerValueField(field, value: Int64(window.pid)) }
        for raw in targetWindows {
            if let field = CGEventField(rawValue: raw) { event.setIntegerValueField(field, value: Int64(window.id)) }
        }
        event.post(tap: .cgSessionEventTap)
    }

    /// Drops a menu bar icon at `toX` the way a ⌘-drag would, but aimed at
    /// its window: icons hidden off screen or behind the notch move too, and
    /// the pointer stays put. Where it lands depends on the direction (see
    /// `MenuBarArranger.place`).
    @discardableResult
    public static func move(_ window: Window, from: CGPoint, toX: Double) async -> Bool {
        await keepingPointer {
            post(.leftMouseDown, from, to: window)
            await pause(50)
            post(.leftMouseUp, CGPoint(x: toX, y: from.y), to: window)
            await pause(150)
        }
    }
}
