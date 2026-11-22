import CoreGraphics
import Foundation
import Testing
@testable import LowtideKit

@Suite struct MenuBarLayoutTests {
    private func at(_ x: Double, _ width: Double, key: String = "", identifier: String = "") -> MenuBarItem {
        MenuBarItem(key: key, identifier: identifier, x: x, width: width)
    }

    @Test func sectionsFollowTheMarkersShownOrPushed() {
        // Everything hidden: both markers are pushed wide, icons left of them
        // sit far off screen.
        let collapsed = MenuBarEdges(always: (-19_100, -9_100), hidden: (-9_000, 1_000), chevron: (1_000, 1_020), bottom: 1_290)
        #expect(MenuBarLayout.section(of: at(-19_200, 24), edges: collapsed) == .always)
        #expect(MenuBarLayout.section(of: at(-9_060, 30), edges: collapsed) == .hidden)
        #expect(MenuBarLayout.section(of: at(1_030, 30), edges: collapsed) == .shown)
        // Everything shown: thin markers between the icons.
        let open = MenuBarEdges(always: (900, 909), hidden: (960, 969), chevron: (969, 989), bottom: 1_290)
        #expect(MenuBarLayout.section(of: at(870, 30), edges: open) == .always)
        #expect(MenuBarLayout.section(of: at(920, 40), edges: open) == .hidden)
        #expect(MenuBarLayout.section(of: at(995, 30), edges: open) == .shown)
        // Without the always-hidden section, everything left is hidden.
        var two = open
        two.always = nil
        #expect(MenuBarLayout.section(of: at(870, 30), edges: two) == .hidden)
    }

    @Test func listsIconsWithoutTheMarkers() {
        let items = [
            at(10, 20, key: "com.apple.controlcenter#com.apple.menuextra.wifi", identifier: "com.apple.menuextra.wifi"),
            at(40, 9, key: "dev.lowtide.app#lowtide.menubar.chevron", identifier: "lowtide.menubar.chevron"),
            at(60, 60, key: "com.apple.controlcenter#com.apple.menuextra.clock", identifier: "com.apple.menuextra.clock"),
        ]
        let entries = MenuBarLayout.entries(items, edges: nil)
        #expect(entries.map(\.key) == [items[0].key, items[2].key])
        #expect(entries[1].fixed && !entries[0].fixed)
    }

    @Test func findsTheFirstShownIconAndWhereADropGoes() {
        let chevron = MenuBarLayout.markerKey("chevron", owner: "dev.lowtide.app")
        let ordered = [at(-9_000, 20, key: "hidden1"), at(990, 20, key: chevron), at(1_020, 20, key: "wifi"),
                       at(1_050, 20, key: "battery"), at(1_080, 60, key: "clock")]
        #expect(MenuBarLayout.firstShown(ordered, after: chevron) == "wifi")
        #expect(MenuBarLayout.dropAnchor(ordered, chevron: chevron, key: "hidden1", x: 1_045) == "battery")
        #expect(MenuBarLayout.dropAnchor(ordered, chevron: chevron, key: "hidden1", x: 5_000) == "clock")
        #expect(MenuBarLayout.firstShown(ordered, after: "nope") == nil)
        #expect(MenuBarLayout.rival(among: ["com.apple.finder", "com.jordanbaird.Ice"]) == "Ice")
        #expect(MenuBarLayout.rival(among: ["com.apple.finder"]) == nil)
    }

    @Test func islandEarsMoveLeftWhenThereIsNoRoom() {
        let pins = [
            IslandPin(key: "a", app: "A", appPath: nil, label: "", side: .left),
            IslandPin(key: "b", app: "B", appPath: nil, label: "", side: .right),
            IslandPin(key: "c", app: "C", appPath: nil, label: "", side: .inside),
        ]
        let roomy = IslandLayout.ears(pins, room: 400)
        #expect(roomy.left.map(\.key) == ["a"] && roomy.right.map(\.key) == ["b"])
        let tight = IslandLayout.ears(pins, room: 20)
        #expect(tight.left.map(\.key) == ["a", "b"] && tight.right.isEmpty)
        #expect(IslandLayout.earWidth(0) == 0 && IslandLayout.earWidth(2) == 62)
    }

    @Test func islandSizesFollowItsTiles() {
        let empty = IslandLayout.size(notchWidth: 200, notchHeight: 32, left: 0, right: 0, tiles: 0, stats: false)
        #expect(empty.width == 380 + 16 && empty.height == 32 + 14 + 56 + 30)
        let full = IslandLayout.size(notchWidth: 200, notchHeight: 32, left: 1, right: 0, tiles: 8, stats: true)
        #expect(full.width == 6 * 68 + 28 + 16)
        #expect(full.height == 32 + 14 + 2 * 68 + 34 + 30)
        #expect(full.left == 36 && full.right == 0)
    }
}

@Suite struct MenuBarSystemTests {
    @Test func readsWindowsWithoutScreenRecording() {
        let window = MenuBarPointer.Window([
            kCGWindowLayer as String: 25, kCGWindowNumber as String: 42, kCGWindowOwnerPID as String: 7,
            kCGWindowBounds as String: ["X": 1000, "Y": 0, "Width": 30, "Height": 24] as NSDictionary,
        ])
        #expect(window == MenuBarPointer.Window(id: 42, pid: 7, layer: 25, bounds: CGRect(x: 1000, y: 0, width: 30, height: 24)))
        let list = [window!, MenuBarPointer.Window(id: 2, pid: 9, layer: 101, bounds: .zero),
                    MenuBarPointer.Window(id: 3, pid: 7, layer: 3, bounds: .zero)]
        #expect(MenuBarPointer.menuOpen(list))
        #expect(MenuBarPointer.hasPopup(7, list) && !MenuBarPointer.hasPopup(8, list))
        #expect(MenuBarPointer.iconWindow(at: 1_010, list)?.id == 42)
        #expect(MenuBarPointer.iconWindow(at: 1_031, list) == nil)
        #expect(MenuBarPointer.statusEdges(rightOf: 900, list) == [1000])
    }

    @Test func samplesStats() async throws {
        var sampler = IslandSampler()
        _ = sampler.sample()
        try await Task.sleep(for: .milliseconds(300))
        let stats = sampler.sample()
        #expect(stats.cpu.map { (0...1).contains($0) } ?? false)
        #expect(stats.memory.map { $0 > 0 && $0 <= 1 } ?? false)
        #expect(stats.rateIn >= 0 && stats.rateOut >= 0)
    }
}

/// macOS 27.2 as Accessibility reported it on a 14" MacBook Pro (notch from
/// 918 to 1138, the « button at 1169.5), recorded 17 Nov 2026: MenuBarAgent's
/// items are groups whose child holds the identifier and the description.
enum Recorded27 {
    static let agent = "com.apple.MenuBarAgent"
    static let owner = "dev.lowtide.app.test"
    static let divider = MenuBarLayout.markerKey("divider", owner: owner)

    static func system(_ identifier: String, _ label: String, x: Double, width: Double) -> MenuBarItem {
        MenuBarItem(key: MenuBarNames.key(owner: MenuBarNames.systemOwner, identifier: identifier, label: label, index: 0, taken: []),
                    app: "MenuBarAgent", bundleId: agent, label: label, identifier: identifier, system: true, x: x, width: width)
    }

    static func app(_ bundle: String, _ name: String, label: String = "", title: String = "", x: Double, width: Double) -> MenuBarItem {
        MenuBarItem(key: MenuBarNames.key(owner: bundle, identifier: "", label: label, index: 0, taken: []), app: name,
                    bundleId: bundle, label: label, title: title, x: x, width: width)
    }

    static func overflow(open: Bool, x: Double = 1169.5) -> MenuBarItem {
        let id = MenuBarAX.overflowPrefix + (open ? "-expanded" : "")
        return MenuBarItem(key: "\(MenuBarNames.systemOwner)#\(id)", bundleId: agent, identifier: id, system: true, x: x, width: 18)
    }

    static func marker(x: Double, width: Double) -> MenuBarItem {
        MenuBarItem(key: divider, app: "Lowtide", bundleId: owner, identifier: MenuBarLayout.markerPrefix + "divider", x: x, width: width)
    }

    /// The overflow open: hidden icons left of the notch, the rest right of it.
    static let open: [MenuBarItem] = [
        app("me.damir.dropover-mac", "Dropover", x: 645, width: 24),
        app("com.uaudio.ua-connect", "UA Connect", x: 675, width: 40),
        app("net.blip.macos", "Blip", x: 721, width: 24),
        app("com.roli.hub", "ROLI Connect", x: 789, width: 34),
        overflow(open: true),
        app("com.unifyroom.app", "UnifyRoom", title: "99+", x: 1193, width: 67),
        marker(x: 1266, width: 11),
        app("com.copycaddy.app", "CopyCaddy", label: "CopyCaddy", x: 1283, width: 24),
        system("com.apple.menuextra.audiovideo", "Audio and Video Controls", x: 1346, width: 16),
        app("com.pcloud.pcloud.macos", "pCloud Drive", x: 1375, width: 42),
        system("com.apple.menuextra.focusmode", "Focus", x: 1500, width: 22),
        system("com.apple.menuextra.wifi", "Wi‑Fi, connected, 3 bars", x: 1602, width: 22),
        system("com.apple.menuextra.battery", "Battery", x: 1640, width: 26),
        app("io.tailscale.ipn.macsys", "Tailscale", x: 1828, width: 24),
        system("com.apple.menuextra.controlcenter", "Control Center", x: 1867, width: 26),
        system("com.apple.menuextra.clock", "Clock", x: 1906, width: 126),
    ]

    /// The same bar closed: what's in the overflow isn't reported.
    static var closed: [MenuBarItem] {
        open.filter { $0.x > 1100 }.map { $0.identifier.hasPrefix(MenuBarAX.overflowPrefix) ? overflow(open: false) : $0 }
    }

    static var running: Set<String> { Set(open.map(\.bundleId)) }
}

@Suite struct MenuBar27Tests {
    @Test func namesIconsFromTheirOwnAttributesNotTheirOwner() {
        let names = Recorded27.open.filter { MenuBarLayout.listed($0) }.map(\.name)
        #expect(names == ["Dropover", "UA Connect", "Blip", "ROLI Connect", "UnifyRoom", "CopyCaddy", "Audio and Video",
                          "pCloud Drive", "Focus", "Wi‑Fi", "Battery", "Tailscale", "Control Center", "Clock"])
        #expect(!names.contains("macOS") && !names.contains("MenuBarAgent"))
        // Identifiers macOS 27 spells differently still map, longest match first.
        #expect(MenuBarNames.name(identifier: "com.apple.menuextra.now-playing", label: "", app: "MenuBarAgent", system: true) == "Now Playing")
        #expect(MenuBarNames.name(identifier: "com.apple.menuextra.keyboardbrightness", label: "", app: "", system: true) == "Keyboard Brightness")
        #expect(MenuBarNames.name(identifier: "com.apple.menuextra.Bluetooth", label: "", app: "", system: true) == "Bluetooth")
        // Unknown system icons say what they are, or at least that they're macOS's.
        #expect(MenuBarNames.name(identifier: "com.apple.menuextra.newthing", label: "New Thing, on", app: "MenuBarAgent", system: true) == "New Thing")
        #expect(MenuBarNames.name(identifier: "com.apple.menuextra.newthing", label: "", app: "MenuBarAgent", system: true) == "Newthing")
        #expect(MenuBarNames.name(identifier: "", label: "", app: "MenuBarAgent", system: true) == "System icon")
        // Other apps: what the item says, else the app's own name, never its tooltip.
        #expect(MenuBarNames.name(identifier: "", label: "", app: "pCloud Drive", system: false) == "pCloud Drive")
        #expect(MenuBarNames.symbol(identifier: "com.apple.menuextra.wifi", system: true) == "wifi")
        #expect(MenuBarNames.symbol(identifier: "", system: false) == nil)
        #expect(MenuBarNames.symbol(identifier: "com.apple.menuextra.newthing", system: true) == MenuBarNames.fallbackSymbol)
        let pin = IslandPin(key: "com.apple.controlcenter#com.apple.menuextra.battery", app: "MenuBarAgent", appPath: nil,
                            label: "", side: .left)
        #expect(pin.name == "Battery")
    }

    @Test func keysStayTheSameAcrossOwnersMovesAndTitles() {
        // macOS 26 files system icons under Control Center, 27 under
        // MenuBarAgent: both get the same key, so pins and pictures carry over.
        let wifi = MenuBarNames.key(owner: MenuBarNames.systemOwner, identifier: "com.apple.menuextra.wifi", label: "Wi‑Fi, off", index: 3, taken: [])
        #expect(wifi == "com.apple.controlcenter#com.apple.menuextra.wifi")
        // No identifier: the description's first clause, not the changing title.
        #expect(MenuBarNames.key(owner: "dev.lowtide.app", identifier: "", label: "Menu bar widgets", index: 1, taken: [])
            == "dev.lowtide.app#Menu bar widgets")
        #expect(MenuBarNames.key(owner: "com.unifyroom.app", identifier: "", label: "", index: 0, taken: []) == "com.unifyroom.app#0")
        // Two items saying the same thing keep apart by place.
        let first = MenuBarNames.key(owner: "x", identifier: "", label: "Sync", index: 0, taken: [])
        #expect(MenuBarNames.key(owner: "x", identifier: "", label: "Sync", index: 1, taken: [first]) == "x#Sync#1")
        #expect(MenuBarNames.identifier(inKey: wifi) == "com.apple.menuextra.wifi")
        // Moving changes the place, not the key.
        var moved = Recorded27.open[7]
        moved.x = 1500
        #expect(moved.key == Recorded27.open[7].key)
    }

    @Test func theOpenOverflowIsTheWholeTruth() {
        let entries = MenuBarLayout.reconcile(Recorded27.open, divider: Recorded27.divider, remembered: [], running: Recorded27.running)
        let hidden = entries.filter { $0.section == .hidden }.map(\.name)
        let shown = entries.filter { $0.section == .shown }.map(\.name)
        #expect(hidden == ["Dropover", "UA Connect", "Blip", "ROLI Connect", "UnifyRoom"])
        #expect(shown.first == "CopyCaddy" && shown.last == "Clock")
        #expect(entries.filter(\.fixed).map(\.name) == ["Control Center", "Clock"])
        // Neither the « button nor any copy's markers are listed.
        #expect(!entries.contains { $0.item.identifier.hasPrefix(MenuBarAX.overflowPrefix) || MenuBarLayout.isMarker($0.item) })
    }

    @Test func aClosedOverflowKeepsWhatItHidesFromTheLastWholeRead() {
        let whole = MenuBarLayout.reconcile(Recorded27.open, divider: Recorded27.divider, remembered: [], running: Recorded27.running)
        let closed = MenuBarLayout.reconcile(Recorded27.closed, divider: Recorded27.divider, remembered: whole, running: Recorded27.running)
        #expect(closed.filter { $0.section == .hidden }.map(\.name) == ["Dropover", "UA Connect", "Blip", "ROLI Connect", "UnifyRoom"])
        #expect(closed.filter { $0.section == .shown }.map(\.key) == whole.filter { $0.section == .shown }.map(\.key))
        // An app that quit takes its icon with it.
        var running = Recorded27.running
        running.remove("net.blip.macos")
        let quit = MenuBarLayout.reconcile(Recorded27.closed, divider: Recorded27.divider, remembered: whole, running: running)
        #expect(!quit.map(\.name).contains("Blip"))
        // A tool without a bundle is known by its name.
        let tool = MenuBarEntry(item: MenuBarItem(key: "sketchybar#0", app: "sketchybar", x: 100, width: 20), section: .hidden, fixed: false)
        let kept = MenuBarLayout.reconcile(Recorded27.closed, divider: Recorded27.divider, remembered: [tool] + whole,
                                           running: Recorded27.running.union(["sketchybar"]))
        #expect(kept.first?.key == "sketchybar#0" && kept.first?.section == .hidden)
    }

    @Test func theMenuBarsOrderWinsOverWhatWasRemembered() {
        let whole = MenuBarLayout.reconcile(Recorded27.open, divider: Recorded27.divider, remembered: [], running: Recorded27.running)
        // The person ⌘-dragged Tailscale left of the divider and CopyCaddy
        // right of Wi‑Fi in the menu bar: that's where they are now.
        var bar = Recorded27.closed
        bar.removeAll { $0.bundleId == "io.tailscale.ipn.macsys" }
        if let at = bar.firstIndex(where: { $0.bundleId == "com.copycaddy.app" }) { bar[at].x = 1630 }
        let after = MenuBarLayout.reconcile(bar, divider: Recorded27.divider, remembered: whole, running: Recorded27.running)
        #expect(after.first { $0.name == "Tailscale" }?.section == .hidden)
        let shown = after.filter { $0.section == .shown }.map(\.name)
        #expect(shown.firstIndex(of: "CopyCaddy")! > shown.firstIndex(of: "Wi‑Fi")!)
    }

    @Test func withoutTheDividerTheOverflowIsTheHiddenSection() {
        let noDivider = Recorded27.open.filter { $0.key != Recorded27.divider }
        let entries = MenuBarLayout.reconcile(noDivider, divider: Recorded27.divider, remembered: [], running: Recorded27.running)
        #expect(entries.filter { $0.section == .hidden }.map(\.name) == ["Dropover", "UA Connect", "Blip", "ROLI Connect"])
    }

    @Test func checksPlacementIgnoringTheOverflowButton() {
        let bar = Recorded27.open
        #expect(MenuBarLayout.isBefore(bar, bar[3].key, bar[5].key)) // ROLI, «, UnifyRoom
        #expect(MenuBarLayout.isBefore(bar, bar[5].key, Recorded27.divider))
        #expect(!MenuBarLayout.isBefore(bar, bar[0].key, bar[2].key))
        #expect(!MenuBarLayout.isBefore(bar, "gone", bar[2].key))
        #expect(MenuBarLayout.firstShown(bar, after: Recorded27.divider) == bar[7].key)
    }
}

/// The markers' widths against what macOS 27.2 did with test status items on
/// a 14" MacBook Pro (notch 918 to 1138, Zeeli's icon first shown at 1486,
/// the open overflow holding icons from 131 to 891), measured 21 Nov 2026:
/// a divider 150 wide was drawn (a gap), 400 went into the overflow with
/// everything left of it and « sat at 1462, beside the first shown icon;
/// 700 left the leftmost hidden icons out of the open overflow; 1 000 was
/// dropped. An always-hidden marker of 600 or 760 kept the icons left of it
/// out of the open overflow; 880 and wider was dropped.
@Suite struct MenuBarFitTests {
    let room = MenuBarFit.Room(areaLeft: 1138, overflowLeft: 131, overflowRight: 891)
    /// Eight hidden icons, as on that Mac.
    let hidden = MenuBarFit.hiddenWidth([34, 22, 24, 40, 24, 24, 24, 24])

    @Test func goesIntoTheOverflowSoThereIsNoGap() {
        let plan = MenuBarFit.plan(firstShown: 1486, room: room, hidden: hidden)
        #expect(plan.mode == .overflow)
        // Just past the room (1486 - 1138 = 348): drawn at 150, overflowed at 400.
        #expect(plan.width > 348 && plan.width < 400)
        #expect(hidden + plan.width <= room.capacity)
    }

    @Test func staysInTheMenuBarWhenTheHiddenIconsWouldNotFitInTheOverflow() {
        let many = MenuBarFit.hiddenWidth(Array(repeating: 30, count: 16))
        let plan = MenuBarFit.plan(firstShown: 1486, room: room, hidden: many)
        #expect(plan.mode == .bar)
        // The room beside «: 1486 - 6 - (1138 + 18 + 12).
        #expect(plan.width == 312)
        // No room beside « at all: a thin line.
        let crowd = MenuBarFit.hiddenWidth(Array(repeating: 30, count: 25))
        #expect(MenuBarFit.plan(firstShown: 1140, room: room, hidden: crowd) == (MenuBarFit.line, .bar))
    }

    @Test func correctsItselfFromWhatTheMenuBarDid() {
        // Still drawn in the bar: grows by the room it still had.
        let grown = MenuBarFit.next(width: 300, mode: .overflow, drawn: true, dividerX: 1180, room: room)
        #expect(grown == 300 + 1180 - 1138 + MenuBarFit.margin)
        // Gone from the closed bar: in the overflow, done.
        #expect(MenuBarFit.next(width: 360, mode: .overflow, drawn: false, dividerX: nil, room: room) == nil)
        // Never past the open overflow's room, where macOS drops it.
        #expect(MenuBarFit.next(width: 750, mode: .overflow, drawn: true, dividerX: 1300, room: room) == nil)
        // In the bar it must be drawn: narrows until it is.
        #expect(MenuBarFit.next(width: 312, mode: .bar, drawn: false, dividerX: nil, room: room) == 312 - 2 * MenuBarFit.margin)
        #expect(MenuBarFit.next(width: 312, mode: .bar, drawn: true, dividerX: 1170, room: room) == nil)
        #expect(MenuBarFit.next(width: MenuBarFit.line, mode: .bar, drawn: false, dividerX: nil, room: room) == nil)
    }

    @Test func theAlwaysHiddenMarkerFillsTheOpenOverflowButIsKept() {
        let width = MenuBarFit.alwaysWidth(room)
        #expect(width >= 600 && width <= 760)
        #expect(MenuBarFit.alwaysWidth(MenuBarFit.Room(areaLeft: 0, overflowLeft: 500, overflowRight: 400)) == MenuBarFit.line)
    }

    @Test func findsTheFirstShownIconBesideTheDividerOrTheOverflowButton() {
        // The divider in the overflow: right of «, past the camera indicator.
        let bar = Recorded27.closed.filter { $0.key != Recorded27.divider }
        let mic = Recorded27.system("com.apple.menuextra.audiovideo", "Audio and Video Controls", x: 1190, width: 16)
        let first = MenuBarFit.firstShown(bar + [mic], divider: Recorded27.divider)
        #expect(first?.name == "UnifyRoom")
        // The divider drawn: right of it.
        #expect(MenuBarFit.firstShown(Recorded27.closed, divider: Recorded27.divider)?.name == "CopyCaddy")
    }
}

@Suite struct MenuBarVaultTests {
    static let vault = MenuBarLayout.markerKey("vault", owner: Recorded27.owner)

    /// The open overflow with the always-hidden marker thin, right of
    /// Dropover and UA Connect.
    static var shown: [MenuBarItem] {
        var bar = Recorded27.open
        bar.append(MenuBarItem(key: vault, app: "Lowtide", bundleId: Recorded27.owner,
                               identifier: MenuBarLayout.markerPrefix + "vault", x: 717, width: 11))
        return bar
    }

    @Test func iconsLeftOfTheVaultAreAlwaysHidden() {
        let entries = MenuBarLayout.reconcile(Self.shown, divider: Recorded27.divider, always: Self.vault,
                                              remembered: [], running: Recorded27.running)
        #expect(entries.filter { $0.section == .always }.map(\.name) == ["Dropover", "UA Connect"])
        #expect(entries.filter { $0.section == .hidden }.map(\.name) == ["Blip", "ROLI Connect", "UnifyRoom"])
        #expect(!entries.contains { MenuBarLayout.isMarker($0.item) })
    }

    @Test func aWideVaultKeepsItsIconsOutOfTheOpenOverflowAndTheyAreRemembered() {
        let whole = MenuBarLayout.reconcile(Self.shown, divider: Recorded27.divider, always: Self.vault,
                                            remembered: [], running: Recorded27.running)
        // « open, the vault wide: it and the icons left of it aren't reported.
        let open = Recorded27.open.filter { $0.x > 720 }
        let now = MenuBarLayout.reconcile(open, divider: Recorded27.divider, always: Self.vault,
                                          remembered: whole, running: Recorded27.running)
        #expect(now.filter { $0.section == .always }.map(\.name) == ["Dropover", "UA Connect"])
        #expect(now.filter { $0.section == .hidden }.map(\.name) == ["Blip", "ROLI Connect", "UnifyRoom"])
        // Closed, with the divider drawn, they stay always hidden.
        let closed = MenuBarLayout.reconcile(Recorded27.closed, divider: Recorded27.divider, always: Self.vault,
                                             remembered: whole, running: Recorded27.running)
        #expect(closed.filter { $0.section == .always }.map(\.name) == ["Dropover", "UA Connect"])
        // No vault: the open overflow is the whole truth, as before.
        let plain = MenuBarLayout.reconcile(open, divider: Recorded27.divider, remembered: whole, running: Recorded27.running)
        #expect(!plain.contains { $0.section == .always })
    }
}

/// The move loop against a pretend menu bar: macOS ignoring a drag, landing
/// one past where it was aimed, or refusing every time.
@Suite struct MenuBarMoveTests {
    /// A menu bar that puts a dropped icon before the first icon whose
    /// middle is right of where it was let go, the way macOS 27 does, and
    /// can be told to ignore drags or land one icon further right.
    actor Bar {
        var items: [MenuBarItem]
        var ignore: Int
        var overshoot: Int
        /// Checks that find something else under the icon (it's still sliding).
        var unsteady: Int
        var drags = 0
        var checks = 0
        var pauses: [Duration] = []

        init(_ keys: [String], ignore: Int = 0, overshoot: Int = 0, unsteady: Int = 0) {
            items = keys.enumerated().map { MenuBarItem(key: $1, x: Double($0) * 30, width: 24) }
            self.ignore = ignore
            self.overshoot = overshoot
            self.unsteady = unsteady
        }

        func verify() -> Bool {
            checks += 1
            guard unsteady > 0 else { return true }
            unsteady -= 1
            return false
        }

        func read() -> [MenuBarItem] { items }
        func pause(_ duration: Duration) { pauses.append(duration) }

        func drag(_ item: MenuBarItem, _ toX: Double) -> Bool {
            drags += 1
            if ignore > 0 {
                ignore -= 1
                return true
            }
            var keys = items.map(\.key)
            keys.removeAll { $0 == item.key }
            var at = keys.firstIndex { key in items.first { $0.key == key }!.center > toX } ?? keys.count
            if overshoot > 0 && at < keys.count {
                overshoot -= 1
                at += 1
            }
            keys.insert(item.key, at: at)
            items = keys.enumerated().map { index, key in
                var moved = items.first { $0.key == key }!
                moved.x = Double(index) * 30
                return moved
            }
            return true
        }

        var order: [String] { items.map(\.key) }
    }

    private func io(_ bar: Bar, posts: Bool = true) -> MenuBarMoveIO {
        MenuBarMoveIO(read: { _ in await bar.read() },
                      drag: { item, x in posts ? await bar.drag(item, x) : false },
                      pause: { await bar.pause($0) },
                      verify: { _ in await bar.verify() })
    }

    @Test func movesAndConfirmsAtOnce() async throws {
        let bar = Bar(["a", "b", "divider", "c", "d"])
        let seen = try await MenuBarArranger.place("d", before: "divider", io: io(bar))
        #expect(await bar.order == ["a", "b", "d", "divider", "c"])
        #expect(MenuBarLayout.isBefore(seen, "d", "divider"))
        #expect(await bar.drags == 1)
        // Moving right lands just before the anchor too.
        _ = try await MenuBarArranger.place("a", before: "c", io: io(bar))
        #expect(await bar.order == ["b", "d", "divider", "a", "c"])
    }

    @Test func retriesWithGrowingPausesWhenMacOSIgnoresTheDrag() async throws {
        let bar = Bar(["a", "divider", "b"], ignore: 2)
        _ = try await MenuBarArranger.place("b", before: "divider", io: io(bar))
        #expect(await bar.order == ["a", "b", "divider"])
        #expect(await bar.drags == 3)
        let pauses = await bar.pauses
        // Up to a second of polls after each ignored drag, then the retry waits.
        #expect(pauses.filter { $0 == MenuBarArranger.poll }.count >= 20)
        // (120 ms pauses are the steady reads before each try.)
        #expect(pauses.filter { $0 != MenuBarArranger.poll && $0 != .milliseconds(120) } == Array(MenuBarArranger.retries.prefix(2)))
    }

    @Test func fixesADropThatLandedOnePastTheAnchor() async throws {
        let bar = Bar(["a", "b", "c", "divider", "d"], overshoot: 1)
        _ = try await MenuBarArranger.place("a", before: "divider", io: io(bar))
        #expect(await bar.order == ["b", "c", "a", "divider", "d"])
        #expect(await bar.drags == 2)
        // It stopped waiting once the icon sat still somewhere else.
        #expect(await bar.pauses.filter { $0 == MenuBarArranger.poll }.count < MenuBarArranger.confirmWithin + 4)
    }

    @Test func saysSoWhenMacOSRefuses() async {
        let refusing = Bar(["a", "divider", "b"], ignore: 100)
        await #expect(throws: LowtideError.self) { try await MenuBarArranger.place("b", before: "divider", io: io(refusing)) }
        #expect(await refusing.drags == MenuBarArranger.retries.count + 1)
        #expect(await refusing.order == ["a", "divider", "b"])
        let blocked = Bar(["a", "divider", "b"])
        await #expect(throws: LowtideError.self) { try await MenuBarArranger.place("b", before: "divider", io: io(blocked, posts: false)) }
        let gone = Bar(["a", "divider"])
        await #expect(throws: LowtideError.self) { try await MenuBarArranger.place("zz", before: "divider", io: io(gone)) }
    }

    @Test func dragsOnlyOnceTheIconIsUnderThePointer() async throws {
        // The overflow is still opening: two hit tests find a neighbour.
        let settling = Bar(["a", "b", "divider", "c"], unsteady: 2)
        _ = try await MenuBarArranger.place("c", before: "divider", io: io(settling))
        #expect(await settling.order == ["a", "b", "c", "divider"])
        #expect(await settling.drags == 1)
        #expect(await settling.checks == 3)
        // Never steady: nothing is dragged at all, so no neighbour is moved.
        let sliding = Bar(["a", "b", "divider", "c"], unsteady: 1_000)
        await #expect(throws: LowtideError.self) { try await MenuBarArranger.place("c", before: "divider", io: io(sliding)) }
        #expect(await sliding.drags == 0)
        #expect(await sliding.order == ["a", "b", "divider", "c"])
    }

    @Test func waitsForTheBarToHoldStill() async {
        actor Sliding {
            var reads = 0
            func read() -> [MenuBarItem] {
                reads += 1
                // Slides 10 points a read for three reads, then rests.
                return [MenuBarItem(key: "a", x: 500 + Double(min(reads, 4)) * 10, width: 24)]
            }
        }
        let bar = Sliding()
        let items = await MenuBarArranger.steady({ await bar.read() }, pause: { _ in })
        #expect(items.first?.x == 540)
        #expect(await bar.reads == 5)
    }

    @Test func doesNothingWhenItIsAlreadyThere() async throws {
        let bar = Bar(["a", "divider", "b"])
        _ = try await MenuBarArranger.place("a", before: "divider", io: io(bar))
        #expect(await bar.drags == 0)
    }
}
