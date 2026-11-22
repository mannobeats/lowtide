import CoreGraphics
import Foundation

/// What a move needs from the menu bar: a read of the items, a drag, and a
/// clock. The real one reads Accessibility and posts events; tests play
/// recorded snapshots.
public struct MenuBarMoveIO: Sendable {
    /// The items left to right. `quick` may skip processes that had none.
    public var read: @Sendable (_ quick: Bool) async -> [MenuBarItem]
    /// Drags `item` and lets go at `toX`; false when macOS won't take events.
    public var drag: @Sendable (_ item: MenuBarItem, _ toX: Double) async -> Bool
    public var pause: @Sendable (Duration) async -> Void
    /// Where to let go to land just before `anchor`, coming from the left or
    /// the right.
    public var target: @Sendable (_ anchor: MenuBarItem, _ leftward: Bool) -> Double
    /// Before each try: puts every icon on screen again.
    public var prepare: @Sendable () async -> Void
    /// The icon is under its middle right now (Accessibility's hit test).
    public var verify: @Sendable (_ item: MenuBarItem) async -> Bool

    public init(read: @escaping @Sendable (Bool) async -> [MenuBarItem],
                drag: @escaping @Sendable (MenuBarItem, Double) async -> Bool,
                pause: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
                target: @escaping @Sendable (MenuBarItem, Bool) -> Double = MenuBarArranger.edgeTarget,
                prepare: @escaping @Sendable () async -> Void = {},
                verify: @escaping @Sendable (MenuBarItem) async -> Bool = { _ in true }) {
        self.read = read
        self.drag = drag
        self.pause = pause
        self.target = target
        self.prepare = prepare
        self.verify = verify
    }

    static let underPointer: @Sendable (MenuBarItem) async -> Bool = {
        MenuBarAX.isUnder($0, at: CGPoint(x: $0.center, y: $0.centerY))
    }

    /// macOS 27: a real ⌘-drag on screen (every icon is in one window), with
    /// the overflow open before each try: macOS closes it after a drop.
    public static let screen = MenuBarMoveIO(
        read: { MenuBarAX.items(quick: $0) },
        drag: { item, toX in await MenuBarPointer.drag(from: CGPoint(x: item.center, y: item.centerY), toX: toX) },
        prepare: { _ = await MenuBarArranger.setOverflow(true) },
        verify: underPointer)

    /// macOS 26: aimed at the icon's own window, so hidden icons and ones
    /// behind the notch move without showing anything. Dropped on another
    /// icon's left edge, one moving left lands just before it; moving right it
    /// lands past icons it crosses, so it's let go past the anchor and brought
    /// back left on the next try.
    public static let windows = MenuBarMoveIO(
        read: { MenuBarAX.items(quick: $0) },
        drag: { item, toX in
            let from = CGPoint(x: item.center, y: item.centerY)
            if let window = MenuBarPointer.iconWindow(at: item.center) {
                return await MenuBarPointer.move(window, from: from, toX: toX)
            }
            return await MenuBarPointer.drag(from: from, toX: toX)
        },
        // Hidden icons sit off screen here: there's nothing to hit-test, and
        // the drag is aimed at the icon's own window anyway.

        target: { anchor, leftward in
            let bounds = MenuBarPointer.iconWindow(at: anchor.center).map { ($0.bounds.minX, $0.bounds.width) }
                ?? (anchor.x, anchor.width)
            return leftward ? bounds.0 + 2 : bounds.0 + bounds.1 - 2
        })
}

/// Moves and opens menu bar icons. Every move is checked against what
/// Accessibility reports after it, retried when macOS ignores it, and
/// reported when it refuses; the user's own moves are never undone. All of
/// it runs off the main thread.
public enum MenuBarArranger {
    /// Waits before each retry: macOS sometimes ignores a drag that comes
    /// too soon after the last change (Icey retries the same way).
    public static let retries: [Duration] = [.milliseconds(300), .milliseconds(800), .milliseconds(1600)]
    /// How long a drop has to show up in Accessibility, and how often to look.
    public static let confirmWithin = 10
    public static let poll: Duration = .milliseconds(100)
    /// Polls for the icon to be under its own middle before a drag.
    static let settleTries = 10

    static func gone() -> LowtideError { .notFound("That icon") }

    /// Just inside the anchor's left edge: measured on macOS 27.2, a drop
    /// there lands just before it from either side.
    @Sendable public static func edgeTarget(_ anchor: MenuBarItem, _ leftward: Bool) -> Double {
        anchor.x + min(4, anchor.width / 3)
    }

    /// Puts `key` just left of `anchor` and returns the menu bar as it was
    /// when that was seen. Each try waits up to a second for Accessibility to
    /// report the drop; a drop that landed elsewhere is tried again from
    /// where it landed, after a growing pause.
    @discardableResult
    public static func place(_ key: String, before anchor: String, io: MenuBarMoveIO) async throws -> [MenuBarItem] {
        await io.prepare()
        var items = await steady({ await io.read(false) }, pause: io.pause)
        for attempt in 0...retries.count {
            if attempt > 0 {
                await io.pause(retries[attempt - 1])
                await io.prepare()
                items = await steady({ await io.read(true) }, pause: io.pause)
            }
            guard let found = items.first(where: { $0.key == key }), let anchorItem = items.first(where: { $0.key == anchor }) else {
                // Out of sight for a moment (a closing overflow): only gone
                // if it's missing from the start.
                if attempt == 0 { throw gone() }
                continue
            }
            if MenuBarLayout.isBefore(items, key, anchor) { return items }
            // The bar may still be settling (the overflow opening, icons
            // sliding over): wait until the icon is where Accessibility says.
            var grab = found, aim = anchorItem, steady = await io.verify(found)
            for _ in 0..<settleTries where !steady {
                await io.pause(poll)
                items = await io.read(true)
                guard let now = items.first(where: { $0.key == key }), let anchorNow = items.first(where: { $0.key == anchor }) else { break }
                grab = now
                aim = anchorNow
                steady = await io.verify(now)
            }
            guard steady else { continue }
            let item = grab, target = aim
            let toX = io.target(target, item.center > target.center)
            guard await io.drag(item, toX) else {
                throw LowtideError.denied("macOS didn't let Lowtide move the icon. Allow Accessibility, then try again.")
            }
            var last = item.x
            var still = 0
            for _ in 0..<confirmWithin {
                await io.pause(poll)
                items = await io.read(true)
                if MenuBarLayout.isBefore(items, key, anchor) { return items }
                // Landed somewhere else and stayed there: try again sooner.
                guard let now = items.first(where: { $0.key == key }) else { continue }
                still = abs(now.x - last) < 0.5 && abs(now.x - item.x) > 1 ? still + 1 : 0
                last = now.x
                if still >= 2 { break }
            }
        }
        throw LowtideError.commandFailed("macOS didn't take the move. Try again, or ⌘-drag the icon in the menu bar.")
    }

    /// Reads until two reads in a row agree on every icon and its place
    /// (up to about 1.5 s). macOS 27 says its overflow is open at once, then
    /// slides the icons in: a read in between has icons overlapping or missing.
    public static func steady(_ read: @Sendable () async -> [MenuBarItem],
                              pause: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) async -> [MenuBarItem] {
        var last = await read()
        for _ in 0..<12 {
            await pause(.milliseconds(120))
            let now = await read()
            if same(now, last) { return now }
            last = now
        }
        return last
    }

    /// The same icons in the same places, to half a point.
    public static func same(_ a: [MenuBarItem], _ b: [MenuBarItem]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && abs($0.x - $1.x) < 0.5 && abs($0.width - $1.width) < 0.5 }
    }

    /// Opens or closes macOS 27's overflow and waits (up to a second) until
    /// Accessibility says it did. False when there's no overflow (every icon
    /// fits) or it didn't change.
    @discardableResult
    public static func setOverflow(_ open: Bool) async -> Bool {
        func state() -> (exists: Bool, open: Bool) {
            let items = MenuBarAX.items(of: ["com.apple.MenuBarAgent"])
            return (MenuBarAX.overflow(in: items) != nil, MenuBarAX.overflowOpen(in: items))
        }
        let now = state()
        guard now.exists else { return false }
        if now.open == open { return true }
        guard MenuBarAX.toggleOverflow() else { return false }
        for _ in 0..<16 {
            try? await Task.sleep(for: .milliseconds(60))
            if state().open == open { return true }
        }
        return false
    }

    /// Opens an icon's menu. On macOS 26 a hidden one is first moved just
    /// right of the chevron, on screen and clear of the notch, and put back
    /// where it was once its menu or popover closes (then `returned` runs),
    /// the way Bartender and Ice do it. On macOS 27 the caller opens the
    /// overflow first (`relocate` nil).
    public static func open(_ key: String, relocateAfter chevron: String?,
                            returned: @escaping @Sendable () -> Void = {}) async throws {
        let all = MenuBarAX.items()
        guard let at = all.firstIndex(where: { $0.key == key }) else { throw gone() }
        let found = all[at]
        var home: String?
        if let chevron, !MenuBarPointer.onScreen(x: found.x, width: found.width, y: found.centerY),
           at + 1 < all.count, let shown = MenuBarLayout.firstShown(all, after: chevron) {
            try await place(key, before: shown, io: .windows)
            home = all[at + 1].key
            // The menu bar lays the icons out again before they can be clicked.
            try? await Task.sleep(for: .milliseconds(150))
        }
        var opened = MenuBarAX.press(key)
        if !opened { opened = await poppedUp(found.pid) }
        if !opened, let now = MenuBarAX.find(key) {
            // Some apps' icons don't take the Accessibility click: a real one does.
            opened = await MenuBarPointer.click(CGPoint(x: now.center, y: now.centerY))
        }
        if let home {
            let pid = found.pid
            Task.detached {
                await waitUntilClosed(pid)
                _ = try? await place(key, before: home, io: .windows)
                returned()
            }
        }
        if !opened { throw LowtideError.denied("macOS didn't let Lowtide click that icon.") }
    }

    /// A menu or popover came up after all. An app showing a menu answers the
    /// Accessibility click only once the menu closes, so the click reads as
    /// failed while the menu is open; clicking again would close it.
    static func poppedUp(_ pid: Int32) async -> Bool {
        for _ in 0..<8 {
            try? await Task.sleep(for: .milliseconds(50))
            let list = MenuBarPointer.windows()
            if MenuBarPointer.menuOpen(list) || MenuBarPointer.hasPopup(pid, list) { return true }
        }
        return false
    }

    /// Waits for the menu or popover an icon opened to close (at most five
    /// minutes, in case it opened a window that stays).
    public static func waitUntilClosed(_ pid: Int32) async {
        let start = Date()
        try? await Task.sleep(for: .milliseconds(600))
        var quiet = 0
        while Date().timeIntervalSince(start) < 300 && quiet < 2 {
            let list = MenuBarPointer.windows()
            quiet = MenuBarPointer.menuOpen(list) || MenuBarPointer.hasPopup(pid, list) ? 0 : quiet + 1
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    /// macOS 26: moves an icon into `section`, just left of `before` when
    /// given: first in the shown icons, last in the hidden ones.
    public static func move(_ key: String, to section: MenuBarSection, before: String?, owner: String,
                            alwaysOn: Bool) async throws -> [MenuBarItem] {
        guard MenuBarAX.trusted else { throw LowtideError.denied("Arranging icons needs Accessibility.") }
        let anchor: String
        if let before {
            anchor = before
        } else {
            switch section {
            case .shown:
                guard let first = MenuBarLayout.firstShown(MenuBarAX.items(), after: MenuBarLayout.markerKey("chevron", owner: owner)) else {
                    throw LowtideError.notFound("The chevron")
                }
                anchor = first
            case .hidden:
                anchor = MenuBarLayout.markerKey("hidden", owner: owner)
            case .always:
                guard alwaysOn else { throw LowtideError.invalid("The always-hidden section is off.") }
                anchor = MenuBarLayout.markerKey("always", owner: owner)
            }
        }
        return try await place(key, before: anchor, io: .windows)
    }

    /// macOS 26: an icon dragged out of the bar under the chevron and let go
    /// over the menu bar at `x` (points): it goes there, among the shown icons.
    public static func drop(_ key: String, at x: Double, owner: String) async throws {
        let chevron = MenuBarLayout.markerKey("chevron", owner: owner)
        guard let anchor = MenuBarLayout.dropAnchor(MenuBarAX.items(), chevron: chevron, key: key, x: x) else {
            throw LowtideError.invalid("There's nowhere to put it.")
        }
        try await place(key, before: anchor, io: .windows)
    }
}
