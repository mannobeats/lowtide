import Foundation

/// Where an icon lives. On macOS 26: always in the menu bar, behind the
/// chevron, or only with ⌥-click on it. On macOS 27: in the menu bar, behind
/// macOS's own «, or always hidden: in the overflow, but left of a marker so
/// wide that « never has room to show them (Lowtide's bar and Show All do).
public enum MenuBarSection: String, Codable, CaseIterable, Sendable {
    case shown, hidden, always

    public var title: String {
        switch self {
        case .shown: "Shown"
        case .hidden: "Hidden"
        case .always: "Always hidden"
        }
    }

    public func hint(overflowing: Bool) -> String {
        switch self {
        case .shown: "Always in the menu bar"
        case .hidden: overflowing ? "Behind « in the menu bar" : "In the bar under the chevron"
        case .always: overflowing ? "Not even behind «: in Lowtide's bar, or with Show All" : "Only with ⌥-click on the chevron"
        }
    }

    /// The action that moves an icon here.
    public var moveTitle: String {
        switch self {
        case .shown: "Show in the Menu Bar"
        case .hidden: "Hide"
        case .always: "Always Hide"
        }
    }
}

/// How much of the menu bar is showing.
public enum MenuBarReveal: String, Codable, Sendable {
    /// Hidden and always-hidden icons are out of sight.
    case none
    case hidden
    /// Everything, always-hidden icons included.
    case all
}

/// Left and right edges of the three markers, in points, and where the menu
/// bar ends below the chevron (AppKit's y, upwards). macOS 26 only.
public struct MenuBarEdges: Sendable, Equatable {
    public var always: (Double, Double)?
    public var hidden: (Double, Double)
    public var chevron: (Double, Double)
    public var bottom: Double

    public init(always: (Double, Double)?, hidden: (Double, Double), chevron: (Double, Double), bottom: Double) {
        self.always = always
        self.hidden = hidden
        self.chevron = chevron
        self.bottom = bottom
    }

    public static func == (a: MenuBarEdges, b: MenuBarEdges) -> Bool {
        a.always?.0 == b.always?.0 && a.always?.1 == b.always?.1 && a.hidden == b.hidden && a.chevron == b.chevron
            && a.bottom == b.bottom
    }
}

/// One icon as the page, the bar and the Island list it.
public struct MenuBarEntry: Sendable, Hashable, Identifiable, Codable {
    public var item: MenuBarItem
    public var section: MenuBarSection
    /// The clock and Control Center: macOS keeps them where they are.
    public var fixed: Bool

    public var id: String { item.key }
    public var key: String { item.key }
    public var name: String { item.name }

    public init(item: MenuBarItem, section: MenuBarSection, fixed: Bool) {
        self.item = item
        self.section = section
        self.fixed = fixed
    }
}

/// The menu bar manager's rules, apart from the menu bar itself.
public enum MenuBarLayout {
    /// The accessibility ids of Lowtide's own markers start with this.
    public static let markerPrefix = "lowtide.menubar."
    public static let fixed: Set<String> = ["com.apple.menuextra.clock", "com.apple.menuextra.controlcenter"]
    /// Icons macOS 27 keeps in the bar whatever room is left: the « button
    /// and the privacy indicator for the camera and microphone.
    public static let pinned: Set<String> = ["com.apple.menuextra.audiovideo"]

    /// The key a marker has in the item list (`owner#identifier`).
    public static func markerKey(_ name: String, owner: String) -> String { "\(owner)#\(markerPrefix)\(name)" }

    /// Any copy's marker: another copy of Lowtide has its own.
    public static func isMarker(_ item: MenuBarItem) -> Bool { item.identifier.hasPrefix(markerPrefix) }

    public static func isSystemOverflow(_ item: MenuBarItem) -> Bool { item.identifier.hasPrefix(MenuBarAX.overflowPrefix) }

    /// Not an icon to list: a marker, or macOS 27's « button.
    public static func listed(_ item: MenuBarItem) -> Bool { !isMarker(item) && !isSystemOverflow(item) }

    static func isFixed(_ item: MenuBarItem, among listed: [MenuBarItem]) -> Bool {
        if fixed.contains(item.identifier) { return true }
        // macOS 26 before Accessibility named it: the clock is always last.
        return item.system && item.identifier.isEmpty && item.key == listed.max(by: { $0.x < $1.x })?.key
    }

    /// By middles, not edges: an icon's frame can overlap a marker's window
    /// by a point.
    public static func section(of item: MenuBarItem, edges: MenuBarEdges) -> MenuBarSection {
        if let always = edges.always, item.center < (always.0 + always.1) / 2 { return .always }
        if item.center < (edges.hidden.0 + edges.hidden.1) / 2 { return .hidden }
        return .shown
    }

    /// macOS 26: the icons to list, markers left out, each in its section.
    public static func entries(_ items: [MenuBarItem], edges: MenuBarEdges?) -> [MenuBarEntry] {
        let listed = items.filter(listed)
        return listed.map { item in
            MenuBarEntry(item: item, section: edges.map { section(of: item, edges: $0) } ?? .shown,
                         fixed: isFixed(item, among: listed))
        }
    }

    /// macOS 27: what the menu bar holds, from what Accessibility reports
    /// now. Left of the always-hidden marker is always hidden, left of the
    /// divider hidden, right of it shown. With macOS's overflow open (and the
    /// always-hidden marker thin) every icon is reported and this is the
    /// whole truth. Closed, the icons in it aren't reported: they're kept
    /// from `remembered` (the last whole read) while their apps run, hidden
    /// when the divider is in the bar (everything left of it is in the
    /// overflow), else in the section they had. Open with the always-hidden
    /// marker wide, its icons are left out of the overflow: they're kept too.
    /// `running` holds each running app's `owner`. Nothing is ever put back
    /// where it was: the menu bar's order wins.
    public static func reconcile(_ live: [MenuBarItem], divider: String, always: String? = nil, remembered: [MenuBarEntry],
                                 running: Set<String>) -> [MenuBarEntry] {
        let ordered = live.sorted { $0.center < $1.center }
        let expanded = MenuBarAX.overflowOpen(in: ordered)
        let marker = ordered.first { $0.key == divider }
        let alwaysMarker = always.flatMap { key in ordered.first { $0.key == key } }
        let overflow = MenuBarAX.overflow(in: ordered)
        let icons = ordered.filter(listed)
        let fresh = icons.map { item -> MenuBarEntry in
            let section: MenuBarSection
            if let alwaysMarker, item.center < alwaysMarker.center {
                section = .always
            } else if let marker {
                section = item.center < marker.center ? .hidden : .shown
            } else if expanded, let overflow {
                // The divider is in the overflow itself: what's in it is hidden.
                section = item.center < overflow.center ? .hidden : .shown
            } else {
                section = .shown
            }
            return MenuBarEntry(item: item, section: section, fixed: isFixed(item, among: icons))
        }
        if expanded && (always == nil || alwaysMarker != nil) { return fresh }
        let seen = Set(fresh.map(\.key))
        let missing = remembered.filter { entry in
            !seen.contains(entry.key) && (entry.item.system || running.contains(owner(entry.item)))
                && (!expanded || entry.section == .always)
        }.map { entry -> MenuBarEntry in
            var entry = entry
            if marker != nil && entry.section != .always { entry.section = .hidden }
            return entry
        }
        return missing + fresh
    }

    /// Who an icon belongs to among running apps: its bundle id, or its
    /// app's name for a tool without a bundle.
    public static func owner(_ item: MenuBarItem) -> String { item.bundleId.isEmpty ? item.app : item.bundleId }

    /// Other menu bar managers fight over the same space.
    public static let rivals: [(String, String)] = [
        ("com.surteesstudios.Bartender", "Bartender"),
        ("com.jordanbaird.Ice", "Ice"),
        ("com.dwarvesv.minimalbar", "Hidden Bar"),
        ("net.matthewpalmer.Vanilla", "Vanilla"),
        ("com.mortennn.Dozer", "Dozer"),
    ]

    public static func rival(among bundleIDs: [String]) -> String? {
        for id in bundleIDs { if let match = rivals.first(where: { id.hasPrefix($0.0) }) { return match.1 } }
        return nil
    }

    /// The first icon right of `marker`: whatever goes just left of it is
    /// the first shown icon.
    public static func firstShown(_ ordered: [MenuBarItem], after marker: String) -> String? {
        guard let at = ordered.first(where: { $0.key == marker }) else { return nil }
        return ordered.first { $0.center > at.center && listed($0) }?.key
    }

    /// Where an icon let go over the menu bar at `x` goes: before the first
    /// shown icon whose middle is right of it, or the last one.
    public static func dropAnchor(_ ordered: [MenuBarItem], chevron: String, key: String, x: Double) -> String? {
        guard let index = ordered.firstIndex(where: { $0.key == chevron }) else { return nil }
        let shown = ordered[(index + 1)...]
        return (shown.first { $0.center > x && $0.key != key } ?? shown.last)?.key
    }

    /// `key` sits just left of `anchor` in the menu bar (the « button and
    /// empty slots don't count).
    public static func isBefore(_ items: [MenuBarItem], _ key: String, _ anchor: String) -> Bool {
        let order = items.filter { !isSystemOverflow($0) && $0.width >= 1 }.sorted { $0.center < $1.center }.map(\.key)
        guard let at = order.firstIndex(of: key) else { return false }
        return at + 1 < order.count && order[at + 1] == anchor
    }
}

/// The width of macOS 27's markers, from how MenuBarAgent lays out the menu
/// bar (measured on 27.2 with test status items, 21 Nov 2026):
///
/// - Every item that doesn't fit right of the notch (or of the front app's
///   menus) goes into the overflow behind «, leftmost first. So a divider
///   too wide to fit goes into the overflow with everything left of it, and
///   « sits right beside the first shown icon: no gap in the menu bar.
/// - Open, the overflow lays its icons out right to left, from just left of
///   the notch to just past the front app's name, and leaves out whatever
///   doesn't fit, leftmost first. The divider takes its width there as a
///   blank, so when the hidden icons and that blank can't both fit, the
///   divider stays in the menu bar instead and fills the room beside «
///   (the old way: a gap, but every hidden icon reachable).
/// - A marker wider than the open overflow's room (about 1 000 points on a
///   14-inch screen) is dropped by macOS and hides nothing.
/// - The always-hidden marker, left of the hidden icons, is nearly as wide as
///   the open overflow: the icons left of it never fit there, so « never
///   shows them. Thin, it lets them all show.
public enum MenuBarFit {
    /// A marker with nothing to hide.
    public static let line = 9.0
    /// Room too small for any icon.
    public static let tolerance = 10.0
    /// Between two icons in the menu bar.
    public static let gap = 6.0
    /// Between two icons in the open overflow.
    public static let spacing = 7.0
    /// Past the room by this much, the divider can't be drawn.
    public static let margin = 12.0
    /// macOS 27's « button.
    public static let button = 18.0

    /// Where the menu bar's icons start, and where the open overflow can put
    /// them (left of the notch, past the front app's name), in points.
    public struct Room: Sendable, Equatable {
        public var areaLeft: Double
        public var overflowLeft: Double
        public var overflowRight: Double

        public init(areaLeft: Double, overflowLeft: Double, overflowRight: Double) {
            self.areaLeft = areaLeft
            self.overflowLeft = overflowLeft
            self.overflowRight = overflowRight
        }

        public var capacity: Double { max(0, overflowRight - overflowLeft) }
    }

    /// Where the divider goes: into the overflow (no gap) or into the menu bar.
    public enum Mode: String, Sendable { case overflow, bar }

    /// The first icon in the menu bar right of the hidden ones: right of the
    /// divider when it's drawn, else right of « (or the first icon at all).
    /// The camera and microphone indicator doesn't count: macOS keeps it.
    public static func firstShown(_ items: [MenuBarItem], divider: String) -> MenuBarItem? {
        let ordered = items.sorted { $0.center < $1.center }
        let after = ordered.first { $0.key == divider }?.right ?? MenuBarAX.overflow(in: ordered)?.right ?? -.infinity
        return ordered.first {
            $0.x >= after - 1 && MenuBarLayout.listed($0) && !MenuBarLayout.pinned.contains($0.identifier)
        }
    }

    /// How much room the hidden icons take in the open overflow.
    public static func hiddenWidth(_ widths: [Double]) -> Double {
        widths.reduce(0) { $0 + $1 + spacing }
    }

    /// The width to give the divider so the first shown icon stays first:
    /// just too wide for the menu bar when the hidden icons and its blank fit
    /// in the open overflow, else as wide as the room beside « (never past
    /// the overflow's room, where macOS would drop it).
    public static func plan(firstShown: Double, room: Room, hidden: Double) -> (width: Double, mode: Mode) {
        let need = (firstShown - room.areaLeft + margin).rounded(.up)
        if need > line, hidden + need + spacing <= room.capacity { return (need, .overflow) }
        let beside = (firstShown - gap - (room.areaLeft + button + 2 * gap)).rounded(.down)
        return (max(line, min(beside, room.capacity - spacing)), .bar)
    }

    /// The next width after reading the menu bar at `width`, or nil when it's
    /// where it should be. In the overflow the divider isn't reported; still
    /// drawn, it wasn't wide enough (`dividerX` is where it starts). In the
    /// menu bar it must be drawn; dropped, it narrows.
    public static func next(width: Double, mode: Mode, drawn: Bool, dividerX: Double?, room: Room) -> Double? {
        switch mode {
        case .overflow:
            guard drawn else { return nil }
            let grown = (width + max(margin, (dividerX ?? room.areaLeft) - room.areaLeft + margin)).rounded(.up)
            return grown < room.capacity ? grown : nil
        case .bar:
            guard !drawn, width > line else { return nil }
            return max(line, width - 2 * margin)
        }
    }

    /// The always-hidden marker: wide enough that nothing left of it fits in
    /// the open overflow, narrow enough that macOS keeps it.
    public static func alwaysWidth(_ room: Room) -> Double {
        max(line, (room.capacity * 0.9).rounded(.down))
    }
}

/// An icon put in the Island: beside the notch or inside it, with what's
/// needed to draw it while its app isn't running.
public struct IslandPin: Codable, Hashable, Sendable, Identifiable {
    public enum Side: String, Codable, Sendable { case left, right, inside }

    public var key: String
    public var app: String
    public var appPath: String?
    public var label: String
    public var side: Side
    public var id: String { key }

    public init(key: String, app: String, appPath: String?, label: String, side: Side) {
        self.key = key
        self.app = app
        self.appPath = appPath
        self.label = label
        self.side = side
    }
}

extension IslandPin {
    /// Its short name, from what was kept of it (its app may not be running).
    public var name: String {
        MenuBarNames.name(identifier: MenuBarNames.identifier(inKey: key), label: label, app: app,
                          system: key.hasPrefix(MenuBarNames.systemOwner + "#"))
    }
}

/// The Island's sizes, in points.
public enum IslandLayout {
    /// An ear's icon slot, and the ear's padding against the notch and edge.
    public static let slot = 26.0
    public static let earPad = 10.0
    /// An icon's tile in the open Island.
    public static let tile = 68.0
    public static let maxColumns = 6
    public static let pad = 14.0
    public static let stats = 34.0
    public static let footer = 30.0
    public static let hint = 56.0
    public static let minWidth = 380.0
    /// The open shape's concave shoulders sit inside the window, either side.
    public static let shoulder = 8.0

    public static func earWidth(_ count: Int) -> Double { count > 0 ? Double(count) * slot + earPad : 0 }

    /// Pins on each side of the notch; right ones move left when the menu
    /// bar's icons leave no room for them.
    public static func ears(_ pins: [IslandPin], room: Double) -> (left: [IslandPin], right: [IslandPin]) {
        let left = pins.filter { $0.side == .left }, right = pins.filter { $0.side == .right }
        return earWidth(right.count) <= room ? (left, right) : (left + right, [])
    }

    public struct Size: Equatable, Sendable {
        public var width: Double
        public var height: Double
        public var left: Double
        public var right: Double
    }

    /// The open Island's size and the closed ears' widths.
    public static func size(notchWidth: Double, notchHeight: Double, left: Int, right: Int, tiles: Int, stats: Bool) -> Size {
        let columns = max(1, min(tiles, maxColumns))
        let rows = Int((Double(tiles) / Double(maxColumns)).rounded(.up))
        let body = tiles > 0 ? Double(rows) * tile : 0
        let hintHeight = tiles == 0 && !stats ? hint : 0
        let closed = notchWidth + 2 * max(earWidth(left), earWidth(right))
        return Size(
            width: max(minWidth, Double(columns) * tile + 2 * pad, closed + 40) + 2 * shoulder,
            height: notchHeight + pad + body + hintHeight + (stats ? self.stats : 0) + footer,
            left: earWidth(left), right: earWidth(right))
    }
}
