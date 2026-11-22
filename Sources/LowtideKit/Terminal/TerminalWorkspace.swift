import Foundation

/// What a terminal session runs.
public struct TabCommand: Equatable, Sendable, Codable {
    public var program: String
    public var args: [String]
    public var cwd: String?

    public init(program: String, args: [String] = [], cwd: String? = nil) {
        self.program = program
        self.args = args
        self.cwd = cwd
    }
}

/// One session: a tab in the strip, or a pane split off one (`parent`).
public struct TerminalTab: Identifiable, Equatable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable { case local, ssh }

    public var id: String
    public var kind: Kind
    public var title: String
    public var command: TabCommand?
    public var hostID: String?
    public var identityID: String?
    /// Typed into the shell once it starts (a snippet run locally).
    public var initialInput: String?
    /// The command does one job (a snippet run, a key deployment). Such tabs
    /// are never duplicated, pinned or restored, which would silently re-run it.
    public var oneShot = false
    /// Set on a pane split off a tab: the tab (in the strip) it lives in.
    public var parent: String?
    public var pinned = false
    /// The process exited; the pane shows its last output until closed.
    public var closed = false

    public init(id: String = TerminalWorkspace.newID(), kind: Kind, title: String, command: TabCommand? = nil,
                hostID: String? = nil, identityID: String? = nil, initialInput: String? = nil,
                oneShot: Bool = false, parent: String? = nil, pinned: Bool = false) {
        self.id = id
        self.kind = kind
        self.title = title
        self.command = command
        self.hostID = hostID
        self.identityID = identityID
        self.initialInput = initialInput
        self.oneShot = oneShot
        self.parent = parent
        self.pinned = pinned
    }
}

/// Tabs, their split trees, the focused pane per tab and the zoomed one.
/// A value: the app keeps one and every change goes through these methods.
public struct TerminalWorkspace: Equatable, Sendable {
    public private(set) var tabs: [TerminalTab] = []
    public var activeID: String?
    /// Split trees, per tab (a tab without splits has none).
    public private(set) var layouts: [String: PaneLayout] = [:]
    /// The pane with keyboard focus, per tab.
    public private(set) var focus: [String: String] = [:]
    /// A pane filling its tab for now, per tab.
    public private(set) var zoomed: [String: String] = [:]

    public init() {}

    public static func newID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)).lowercased()
    }

    // MARK: Reading

    /// Tabs in the strip, in order.
    public var roots: [TerminalTab] { tabs.filter { $0.parent == nil } }

    public func tab(_ id: String) -> TerminalTab? { tabs.first { $0.id == id } }

    /// The tab (in the strip) a pane belongs to.
    public func root(of id: String) -> String { tab(id)?.parent ?? id }

    public func layout(of root: String) -> PaneLayout { layouts[root] ?? .leaf(root) }

    /// The panes of a tab, in layout order.
    public func panes(of root: String) -> [String] { layouts[root]?.leaves ?? [root] }

    /// The pane that has the keyboard in the active tab.
    public var focusedPane: String? { activeID.map { focus[$0] ?? $0 } }

    public func zoomedPane(in root: String) -> String? { zoomed[root] }

    // MARK: Tabs

    /// Adds a tab and makes it active. Pinned tabs go after the last pinned
    /// one so unpinned tabs stay on the right.
    @discardableResult
    public mutating func add(_ tab: TerminalTab) -> String {
        var tab = tab
        tab.parent = nil
        if tab.pinned {
            let lastPinned = tabs.lastIndex { $0.pinned && $0.parent == nil } ?? -1
            tabs.insert(tab, at: lastPinned + 1)
        } else {
            tabs.append(tab)
        }
        activeID = tab.id
        return tab.id
    }

    /// Closes a tab and every pane split off it. Returns the closed ids.
    @discardableResult
    public mutating func close(_ id: String) -> [String] {
        let root = root(of: id)
        let roots = self.roots
        guard let index = roots.firstIndex(where: { $0.id == root }) else { return [] }
        let gone = tabs.filter { $0.id == root || $0.parent == root }.map(\.id)
        tabs.removeAll { gone.contains($0.id) }
        if activeID == root {
            let rest = roots.filter { $0.id != root }
            activeID = rest.indices.contains(index) ? rest[index].id : rest.last?.id
        }
        prune()
        return gone
    }

    /// Closes every tab but this one and the pinned ones. Returns the closed ids.
    @discardableResult
    public mutating func closeOthers(_ id: String) -> [String] {
        let root = root(of: id)
        let kept = Set(tabs.filter { $0.id == root || ($0.pinned && $0.parent == nil) }.map(\.id))
        let gone = tabs.filter { !kept.contains($0.id) && !kept.contains($0.parent ?? "") }.map(\.id)
        tabs.removeAll { gone.contains($0.id) }
        activeID = root
        prune()
        return gone
    }

    /// Closes one pane; the last pane of a tab closes the tab. When the tab's
    /// own pane closes, the first remaining pane carries the tab from now on.
    /// Returns the closed ids.
    @discardableResult
    public mutating func closePane(_ id: String) -> [String] {
        let root = root(of: id)
        guard let tree = layouts[root], let rest = tree.removing(id) else { return close(root) }
        let remaining = rest.leaves
        let key = id == root ? remaining[0] : root
        let previousFocus = focus[root]
        if key != root {
            // The promoted pane takes the tab's place and pin in the strip.
            let pinned = tab(root)?.pinned ?? false
            guard let promotedIndex = tabs.firstIndex(where: { $0.id == key }),
                  let rootIndex = tabs.firstIndex(where: { $0.id == root }) else { return [] }
            var promoted = tabs[promotedIndex]
            promoted.parent = nil
            promoted.pinned = pinned
            tabs[rootIndex] = promoted
            tabs.remove(at: promotedIndex)
            for index in tabs.indices where tabs[index].parent == root { tabs[index].parent = key }
            layouts[root] = nil
            focus[root] = nil
            zoomed[root] = nil
            if activeID == root { activeID = key }
        } else {
            tabs.removeAll { $0.id == id }
        }
        layouts[key] = remaining.count == 1 ? nil : rest
        if let previousFocus, previousFocus != id, remaining.contains(previousFocus) {
            focus[key] = previousFocus
        } else {
            focus[key] = remaining[0]
        }
        zoomed[key] = nil
        return [id]
    }

    public mutating func cycle(_ delta: Int) {
        let roots = self.roots
        guard !roots.isEmpty else { return }
        let index = roots.firstIndex { $0.id == activeID } ?? 0
        activeID = roots[((index + delta) % roots.count + roots.count) % roots.count].id
    }

    /// Moves a tab in the strip to `target`'s place, the way a dragged tab
    /// slides past its neighbours. Pinned tabs only trade places with pinned
    /// ones, so the pinned group stays on the left.
    public mutating func moveTab(_ id: String, to target: String) {
        guard id != target, let moving = tab(id), moving.parent == nil,
              let goal = tab(target), goal.parent == nil, moving.pinned == goal.pinned,
              let from = tabs.firstIndex(where: { $0.id == id }),
              let to = tabs.firstIndex(where: { $0.id == target }) else { return }
        tabs.remove(at: from)
        guard let index = tabs.firstIndex(where: { $0.id == target }) else { return }
        tabs.insert(moving, at: from < to ? index + 1 : index)
    }

    public mutating func select(index: Int) {
        let roots = self.roots
        if roots.indices.contains(index) { activeID = roots[index].id }
    }

    /// A fresh session like this tab's, right after it. Nil for one-shot tabs.
    @discardableResult
    public mutating func duplicate(_ id: String) -> String? {
        guard let source = tab(root(of: id)), !source.oneShot,
              let index = tabs.firstIndex(where: { $0.id == source.id }) else { return nil }
        let copy = TerminalTab(kind: source.kind, title: source.title, command: source.command,
                               hostID: source.hostID, identityID: source.identityID)
        tabs.insert(copy, at: index + 1)
        activeID = copy.id
        return copy.id
    }

    public mutating func rename(_ id: String, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].title = trimmed
    }

    public mutating func togglePin(_ id: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }), !tabs[index].oneShot, tabs[index].parent == nil else { return }
        tabs[index].pinned.toggle()
        // Pinned first (keeping their order), then the rest.
        tabs = tabs.filter(\.pinned) + tabs.filter { !$0.pinned }
    }

    public mutating func markExited(_ id: String, _ exited: Bool = true) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].closed = exited
    }

    // MARK: Panes

    /// Opens a new session beside `id`. Nil when `id` closed in the meantime.
    @discardableResult
    public mutating func split(_ id: String, axis: PaneLayout.Axis, with pane: TerminalTab) -> String? {
        guard tab(id) != nil else { return nil }
        let root = root(of: id)
        var pane = pane
        pane.parent = root
        pane.pinned = false
        layouts[root] = layout(of: root).splitting(id, axis: axis, with: pane.id)
        tabs.append(pane)
        activeID = root
        focus[root] = pane.id
        zoomed[root] = nil
        return pane.id
    }

    public mutating func setFocus(_ id: String) {
        let root = root(of: id)
        if focus[root] != id { focus[root] = id }
    }

    public mutating func focus(_ direction: PaneLayout.Direction) {
        guard let root = activeID, let tree = layouts[root],
              let to = tree.neighbor(of: focus[root] ?? root, direction) else { return }
        focus[root] = to
    }

    /// Swaps the focused pane with its neighbour.
    public mutating func move(_ direction: PaneLayout.Direction) {
        guard let root = activeID, let tree = layouts[root] else { return }
        let from = focus[root] ?? root
        guard let to = tree.neighbor(of: from, direction) else { return }
        layouts[root] = tree.swapping(from, to)
    }

    public mutating func resize(_ direction: PaneLayout.Direction) {
        guard let root = activeID, let tree = layouts[root] else { return }
        layouts[root] = tree.nudging(focus[root] ?? root, direction, by: 0.05)
    }

    public mutating func swapPanes(_ a: String, _ b: String) {
        let root = root(of: a)
        guard root == self.root(of: b), let tree = layouts[root] else { return }
        layouts[root] = tree.swapping(a, b)
    }

    public mutating func setRatio(_ root: String, path: String, ratio: Double) {
        guard let tree = layouts[root] else { return }
        layouts[root] = tree.settingRatio(at: path, to: ratio)
    }

    public mutating func equalize(_ root: String) {
        guard let tree = layouts[root] else { return }
        layouts[root] = tree.equalized()
    }

    public mutating func toggleZoom(_ root: String) {
        guard layouts[root] != nil else { return }
        zoomed[root] = zoomed[root] == nil ? (focus[root] ?? root) : nil
    }

    // MARK: Persistence

    /// Pinned tabs, the only ones kept across launches. Splits aren't kept:
    /// each comes back as one pane with a fresh shell.
    public var pinnedForRestore: [TerminalTab] {
        roots.filter { $0.pinned && !$0.oneShot }.map {
            TerminalTab(id: $0.id, kind: $0.kind, title: $0.title, command: $0.command,
                        hostID: $0.hostID, identityID: $0.identityID, pinned: true)
        }
    }

    public mutating func restore(_ pinned: [TerminalTab]) {
        tabs = pinned.filter { !$0.oneShot }.map {
            var tab = $0
            tab.parent = nil
            tab.pinned = true
            tab.closed = false
            tab.initialInput = nil
            return tab
        }
        layouts = [:]
        focus = [:]
        zoomed = [:]
        activeID = tabs.first?.id
    }

    private mutating func prune() {
        let keep = Set(tabs.map(\.id))
        layouts = layouts.filter { keep.contains($0.key) }
        focus = focus.filter { keep.contains($0.key) }
        zoomed = zoomed.filter { keep.contains($0.key) }
    }
}
