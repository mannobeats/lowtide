import AppKit
import ApplicationServices
import Synchronization

/// One item in the menu bar, where it is now.
public struct MenuBarItem: Sendable, Hashable, Identifiable, Codable {
    /// Stable across launches and moves (`MenuBarNames.key`).
    public var key: String
    public var pid: Int32
    public var app: String
    public var bundleId: String
    public var appPath: String?
    /// What VoiceOver reads for it (`AXDescription`), when the app says.
    public var label: String
    /// Its text, when it shows some (`AXTitle`): changes, so never a key.
    public var title: String
    public var identifier: String
    /// Drawn by macOS itself (MenuBarAgent, Control Center, SystemUIServer).
    public var system: Bool
    /// Left edge, width and height, in points.
    public var x: Double
    public var width: Double
    public var centerY: Double
    public var height: Double

    public var id: String { key }
    public var center: Double { x + width / 2 }
    public var right: Double { x + width }
    public var name: String { MenuBarNames.name(self) }

    public init(key: String, pid: Int32 = 0, app: String = "", bundleId: String = "", appPath: String? = nil,
                label: String = "", title: String = "", identifier: String = "", system: Bool = false,
                x: Double, width: Double, centerY: Double = 19, height: Double = 24) {
        self.key = key
        self.pid = pid
        self.app = app
        self.bundleId = bundleId
        self.appPath = appPath
        self.label = label
        self.title = title
        self.identifier = identifier
        self.system = system
        self.x = x
        self.width = width
        self.centerY = centerY
        self.height = height
    }
}

/// Menu bar items as the Accessibility API sees them, from each app's
/// `AXExtrasMenuBar`. On macOS 26 every item window belongs to Control
/// Center, so the window list can't say whose an item is. On macOS 27
/// MenuBarAgent draws them all in one window, and wraps each system item in
/// an `AXGroup`/`AXHostingView` whose child holds its identifier
/// (`com.apple.menuextra.wifi`) and description; icons in macOS's overflow
/// are left out until the overflow is open.
public enum MenuBarAX {
    /// A hung app answers nothing; this keeps one from stalling the whole list.
    static let timeout: Float = 0.25
    /// macOS 27's own « button, `-expanded` while its icons show.
    public static let overflowPrefix = "menu-bar-overflow-indicator"

    public static var trusted: Bool { AXIsProcessTrusted() }

    struct Running: Sendable {
        let pid: Int32
        let name: String
        let bundleId: String
        let path: String?
    }

    static func running() -> [Running] {
        NSWorkspace.shared.runningApplications.map {
            Running(pid: $0.processIdentifier, name: $0.localizedName ?? "", bundleId: $0.bundleIdentifier ?? "",
                    path: $0.bundleURL?.path)
        }
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &out) == .success else { return nil }
        return out
    }

    private static func text(_ element: AXUIElement, _ attribute: String) -> String {
        value(element, attribute) as? String ?? ""
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let rawPoint = value(element, kAXPositionAttribute), CFGetTypeID(rawPoint) == AXValueGetTypeID(),
              let rawSize = value(element, kAXSizeAttribute), CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(rawPoint as! AXValue, .cgPoint, &point),
              AXValueGetValue(rawSize as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    /// The element that is the item: itself, or on macOS 27 the
    /// `AXMenuBarItem` inside MenuBarAgent's hosting group.
    private static func itemElement(_ child: AXUIElement) -> AXUIElement {
        guard text(child, kAXRoleAttribute) == kAXGroupRole else { return child }
        let inner = value(child, kAXChildrenAttribute) as? [AXUIElement] ?? []
        for element in inner {
            AXUIElementSetMessagingTimeout(element, timeout)
            if text(element, kAXRoleAttribute) == "AXMenuBarItem" { return element }
        }
        return child
    }

    private static func extras(_ app: Running) -> [(MenuBarItem, AXUIElement)] {
        let root = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(root, timeout)
        guard let raw = value(root, "AXExtrasMenuBar"), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return [] }
        let bar = raw as! AXUIElement
        AXUIElementSetMessagingTimeout(bar, timeout)
        let children = value(bar, kAXChildrenAttribute) as? [AXUIElement] ?? []
        let system = MenuBarNames.isSystem(bundleId: app.bundleId)
        let owner = system ? MenuBarNames.systemOwner : (app.bundleId.isEmpty ? app.name : app.bundleId)
        var taken = Set<String>()
        var found: [(MenuBarItem, AXUIElement)] = []
        for (index, child) in children.enumerated() {
            AXUIElementSetMessagingTimeout(child, timeout)
            // Control Center keeps a slot for every module it could show.
            guard let outer = frame(child), outer.width >= 1 else { continue }
            let element = itemElement(child)
            let identifier = text(element, kAXIdentifierAttribute)
            let label = text(element, kAXDescriptionAttribute)
            let key = MenuBarNames.key(owner: owner, identifier: identifier, label: label, index: index, taken: taken)
            taken.insert(key)
            // The group spans the bar's height; the item inside is the icon.
            let inner = element == child ? outer : (frame(element) ?? outer)
            found.append((MenuBarItem(key: key, pid: app.pid, app: app.name, bundleId: app.bundleId, appPath: app.path,
                                      label: label, title: text(element, kAXTitleAttribute), identifier: identifier,
                                      system: system, x: outer.minX, width: outer.width, centerY: inner.midY,
                                      height: min(inner.height, outer.height)), element))
        }
        return found
    }

    /// Lets many slow apps be asked at once: one that's busy costs its own
    /// timeout, not everyone's. Each slot is written by one operation only.
    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var slots: [[(MenuBarItem, AXUIElement)]]
        init(_ count: Int) { slots = Array(repeating: [], count: count) }
        func set(_ index: Int, _ value: [(MenuBarItem, AXUIElement)]) { lock.withLock { slots[index] = value } }
        var all: [(MenuBarItem, AXUIElement)] { lock.withLock { slots.flatMap { $0 } } }
    }

    /// Owners known to have no menu bar items, by pid: asking costs a round
    /// trip each, and most processes never have one. Rechecked now and then.
    private static let quiet = Mutex<(pids: Set<Int32>, since: Date)>(([], .distantPast))

    /// The calling thread takes part (`concurrentPerform`), so a read always
    /// finishes. Waiting on an OperationQueue from Swift's cooperative pool
    /// deadlocked: a few overlapping reads held every pool thread while
    /// their operations waited for one, and every `Task.sleep` in the app
    /// stopped waking (a stuck dictation pill, Quit doing nothing).
    private static func read(_ apps: [Running]) -> [(MenuBarItem, AXUIElement)] {
        let results = Results(apps.count)
        DispatchQueue.concurrentPerform(iterations: apps.count) { index in
            results.set(index, extras(apps[index]))
        }
        return results.all
    }

    /// Every item in the menu bar, left to right, macOS 27's « included.
    /// Empty without Accessibility. `quick` skips processes that had none a
    /// moment ago (for polling while an icon moves).
    public static func items(quick: Bool = false) -> [MenuBarItem] {
        guard trusted else { return [] }
        let apps = running()
        let skip: Set<Int32> = quick ? quiet.withLock { Date().timeIntervalSince($0.since) < 30 ? $0.pids : [] } : []
        let found = read(apps.filter { !skip.contains($0.pid) }).map(\.0)
        if !quick {
            let busy = Set(found.map(\.pid))
            quiet.withLock { $0 = (Set(apps.map(\.pid)).subtracting(busy), Date()) }
        }
        return found.sorted { $0.center < $1.center }
    }

    /// The item with `key`, read fresh.
    public static func find(_ key: String) -> MenuBarItem? {
        withItem(key) { item, _ in item }
    }

    private static func withItem<T>(_ key: String, _ body: (MenuBarItem, AXUIElement) -> T) -> T? {
        guard trusted, let owner = key.split(separator: "#", maxSplits: 1).first.map(String.init) else { return nil }
        let apps = running().filter {
            owner == MenuBarNames.systemOwner ? MenuBarNames.isSystem(bundleId: $0.bundleId)
                : $0.bundleId == owner || ($0.bundleId.isEmpty && $0.name == owner)
        }
        for app in apps {
            if let hit = extras(app).first(where: { $0.0.key == key }) { return body(hit.0, hit.1) }
        }
        return nil
    }

    /// macOS 27's « button in a list of items.
    public static func overflow(in items: [MenuBarItem]) -> MenuBarItem? {
        items.first { $0.identifier.hasPrefix(overflowPrefix) }
    }

    /// macOS 27's overflow is open: its icons show left of the others.
    public static func overflowOpen(in items: [MenuBarItem]) -> Bool {
        overflow(in: items)?.identifier.hasSuffix("-expanded") ?? false
    }

    /// Only these apps' items, left to right: MenuBarAgent's (the « button
    /// and the system icons) and our own are cheap enough to check every
    /// few seconds.
    public static func items(of bundleIDs: Set<String>) -> [MenuBarItem] {
        guard trusted else { return [] }
        return read(running().filter { bundleIDs.contains($0.bundleId) }).map(\.0).sorted { $0.center < $1.center }
    }

    /// Opens or closes macOS 27's overflow, as clicking « does.
    @discardableResult
    public static func toggleOverflow() -> Bool {
        guard trusted, let agent = running().first(where: { $0.bundleId == "com.apple.MenuBarAgent" }) else { return false }
        guard let hit = extras(agent).first(where: { $0.0.identifier.hasPrefix(overflowPrefix) }) else { return false }
        return AXUIElementPerformAction(hit.1, kAXPressAction as CFString) == .success
    }

    /// The front app's menus' right edges, left to right, in points (the
    /// Apple menu first, then the app's name).
    private static func menuEdges() -> [Double] {
        guard trusted, let front = NSWorkspace.shared.frontmostApplication else { return [] }
        let root = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(root, timeout)
        guard let raw = value(root, kAXMenuBarAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return [] }
        let menus = value(raw as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] ?? []
        return menus.compactMap { menu -> Double? in frame(menu).map { Double($0.maxX) } }.sorted()
    }

    /// Where the front app's menus end, in points from the left.
    public static func menusRight() -> Double? { menuEdges().last }

    /// Where the front app's name ends (macOS 27's open overflow puts icons
    /// from a little past it, measured on 27.2: about 30 points) and where its
    /// last menu ends.
    public static func menus() -> (nameRight: Double?, right: Double?) {
        let edges = menuEdges()
        return (edges.count > 1 ? edges[1] : edges.first, edges.last)
    }

    /// The item under a point is `item`, by its owner and its own identifier
    /// or description: a drag starts only on the icon it means to move, never
    /// on a neighbour that slid under the pointer while the bar was moving.
    public static func isUnder(_ item: MenuBarItem, at point: CGPoint) -> Bool {
        guard trusted else { return false }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, timeout)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let hit else { return false }
        AXUIElementSetMessagingTimeout(hit, timeout)
        let element = itemElement(hit)
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid == item.pid else { return false }
        let identifier = text(element, kAXIdentifierAttribute)
        return item.identifier.isEmpty ? identifier.isEmpty && text(element, kAXDescriptionAttribute) == item.label
            : identifier == item.identifier
    }

    /// Clicks the item the way VoiceOver does: its menu or popover opens.
    public static func press(_ key: String) -> Bool {
        withItem(key) { _, element in AXUIElementPerformAction(element, kAXPressAction as CFString) == .success } ?? false
    }
}
