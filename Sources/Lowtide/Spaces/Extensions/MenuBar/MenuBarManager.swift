import AppKit
import LowtideKit
import SwiftUI

/// The menu bar manager, like Bartender: hides menu bar icons you rarely
/// need, arranges them, and optionally keeps chosen ones and live stats in
/// the Island under the notch (`IslandPanel`).
///
/// macOS 26: three markers hide icons behind a chevron, and the chevron drops
/// a bar of them under it (`ShelfPanel`).
///
/// macOS 27: MenuBarAgent draws every icon in one window and moves the ones
/// that don't fit into its own overflow behind «; no app can move icons off
/// screen any more. So Lowtide works with it, as IceMelt, Icey and Thaw do
/// (publicspace.net/blog/macos-27-menu-bar, github.com/pnikolaidis/icemelt):
/// one invisible divider left of the shown icons, just too wide for the
/// menu bar, so macOS puts it and everything left of it in its overflow and
/// « sits beside the shown icons (`MenuBarFit`). An optional second marker
/// keeps always-hidden icons out of « too. Showing them is opening that
/// overflow, or Lowtide's bar under it; moving one is a real ⌘-drag across
/// the divider, checked against Accessibility. The menu bar's own order is
/// the truth: nothing is ever put back where Lowtide thinks it belongs.
///
/// Hiding needs no permission. Naming, opening and arranging icons use
/// Accessibility; Screen Recording adds each icon's real picture.
@Observable
final class MenuBarManager {
    static let shared = MenuBarManager()
    static let enabledKey = "extension.menubar"
    private static let prefsKey = "menubar.prefs"
    private static let askedKey = "menubar.askedAccessibility"
    /// The menu bar as last seen whole, for icons macOS 27's overflow hides
    /// from Accessibility. (v2: keys from each item's own attributes.)
    private static let rememberedKey = "menubar.remembered.v2"
    /// macOS 27's divider was put in place once, left of the icons on screen.
    private static let placedKey = "menubar.divider.placed"
    /// macOS 27 draws every icon in one window and moves the ones that don't
    /// fit into its own overflow, where Accessibility can't see them.
    nonisolated static let overflowing = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27

    struct Prefs: Codable, Equatable {
        /// The always-hidden section exists.
        var always = false
        /// Seconds before icons shown in place hide again; 0 never.
        var autoHide = 10
        /// The chevron (macOS 26) or Show Hidden (27) drops the bar of hidden
        /// icons under it, like Bartender's; off, it shows them in the menu
        /// bar itself.
        var bar = true
        /// The Island: pointing at the notch opens it.
        var island = false
        /// Live CPU, memory, network and battery in the Island.
        var stats = true
        var pins: [IslandPin] = []

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Prefs()
            always = try c.decodeIfPresent(Bool.self, forKey: .always) ?? d.always
            autoHide = try c.decodeIfPresent(Int.self, forKey: .autoHide) ?? d.autoHide
            bar = try c.decodeIfPresent(Bool.self, forKey: .bar) ?? d.bar
            island = try c.decodeIfPresent(Bool.self, forKey: .island) ?? d.island
            stats = try c.decodeIfPresent(Bool.self, forKey: .stats) ?? d.stats
            pins = try c.decodeIfPresent([IslandPin].self, forKey: .pins) ?? d.pins
        }
    }

    private(set) var enabled = ExtensionState.isOn(.menubar)
    var prefs: Prefs {
        didSet {
            guard prefs != oldValue else { return }
            if let data = try? JSONEncoder().encode(prefs) { UserDefaults.standard.set(data, forKey: Self.prefsKey) }
            apply(oldValue)
        }
    }
    private(set) var reveal: MenuBarReveal = .none
    private(set) var entries: [MenuBarEntry] = []
    private(set) var trusted = MenuBarAX.trusted
    /// Another menu bar manager that's running.
    private(set) var rival: String?
    /// This Mac's screen has a notch (else the Island hangs from the top middle).
    private(set) var notch = false
    /// The icon being moved: reads wait, and the page shows it working.
    private(set) var moving: String?
    /// A whole read or a move holds the menu bar (the overflow open, the
    /// divider thin): other work waits.
    private(set) var busy = false
    private(set) var loaded = false
    /// macOS 27: the shown icons don't all fit, so macOS keeps some of them
    /// behind « as well.
    private(set) var crowded = false
    /// Hidden icons as last seen (macOS 27 hides them from Accessibility).
    private var remembered: [MenuBarEntry] = []
    /// The last cheap read, to tell icons at rest from ones still moving.
    @ObservationIgnored private var lastRead: [MenuBarItem] = []
    private var observers: [NSObjectProtocol] = []
    /// The chevron (macOS 26) or « (27) where Accessibility last saw it: the
    /// bar of hidden icons hangs under it.
    private(set) var chevronSpan: (x: Double, width: Double)?

    let markers = MenuBarMarkers()
    /// Bumped by every show and hide: a pending auto-hide that sees a newer
    /// one lets it be.
    private var turn = 0
    /// Views and panels that want the icons kept current.
    private var watchers = 0
    /// macOS 27: keeps the divider fitted while the manager is on.
    private var keeper: Task<Void, Never>?
    private var fitting = false
    /// The divider as last fitted: a check refits only when the menu bar changed.
    private var settled: Glance?
    /// How the divider was last fitted (the page says when it's in the bar).
    private(set) var mode: MenuBarFit.Mode = .overflow

    /// The key the markers have in the item list.
    var owner: String { Bundle.main.bundleIdentifier ?? Paths.bundleID }
    var chevronKey: String { MenuBarLayout.markerKey("chevron", owner: owner) }
    var dividerKey: String { MenuBarLayout.markerKey("divider", owner: owner) }
    var vaultKey: String { MenuBarLayout.markerKey("vault", owner: owner) }
    /// Sections people can put icons in here.
    var sections: [MenuBarSection] { MenuBarSection.allCases.filter { $0 != .always || prefs.always } }

    private init() {
        prefs = UserDefaults.standard.data(forKey: Self.prefsKey).flatMap { try? JSONDecoder().decode(Prefs.self, from: $0) } ?? Prefs()
        markers.onClick = { [weak self] secondary, option in self?.clicked(secondary: secondary, option: option) }
        remembered = UserDefaults.standard.data(forKey: Self.rememberedKey)
            .flatMap { try? JSONDecoder().decode([MenuBarEntry].self, from: $0) } ?? []
    }

    // MARK: On and off

    /// Follows `extension.menubar`.
    func sync() {
        enabled = ExtensionState.isOn(.menubar)
        if enabled {
            if Self.overflowing {
                markers.installDivider()
                markers.setVault(prefs.always)
                keep()
            } else {
                markers.install()
                markers.setAlways(prefs.always, reveal: reveal)
                markers.set(reveal)
            }
            askForAccessibilityOnce()
            Task { await refresh() }
        } else {
            turn += 1
            reveal = .none
            stopKeeping()
            markers.remove()
            entries = []
        }
        ShelfPanel.shared.configure(enabled && prefs.bar)
        IslandPanel.shared.configure(enabled && prefs.island)
    }

    func setEnabled(_ on: Bool) {
        ExtensionState.set(.menubar, on)
        NotificationCenter.default.post(name: Dictation.extensionsChanged, object: nil)
    }

    func stop() {
        turn += 1
        stopKeeping()
        markers.remove()
        ShelfPanel.shared.configure(false)
        IslandPanel.shared.configure(false)
    }

    /// Accessibility is asked for once, the first time the manager is on:
    /// naming, arranging and the Island need it.
    private func askForAccessibilityOnce() {
        guard !MenuBarAX.trusted, !UserDefaults.standard.bool(forKey: Self.askedKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.askedKey)
        Permission.accessibility.request()
    }

    private func apply(_ before: Prefs) {
        guard enabled else { return }
        if prefs.always != before.always {
            if Self.overflowing {
                markers.setVault(prefs.always)
                settled = nil
                Task { await fitDivider() }
            } else {
                markers.setAlways(prefs.always, reveal: reveal)
            }
        }
        if prefs.bar != before.bar { ShelfPanel.shared.configure(prefs.bar) }
        if prefs.island != before.island { IslandPanel.shared.configure(prefs.island) }
        if prefs.pins != before.pins || prefs.stats != before.stats { IslandPanel.shared.layoutChanged() }
        if prefs.always != before.always { Task { await refresh() } }
    }

    // MARK: macOS 27's divider

    /// Fits the divider now, when another app comes forward (its menus can
    /// take the room) or the screens change, and checks it every few seconds.
    private func keep() {
        guard keeper == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        let poke: @Sendable (Notification) -> Void = { _ in Task { @MainActor in await MenuBarManager.shared.checkDivider() } }
        observers = [
            center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main, using: poke),
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                                   queue: .main, using: poke),
        ]
        keeper = Task {
            // The status item appears a moment after it's made.
            try? await Task.sleep(for: .milliseconds(600))
            await placeDividerOnce()
            await fitDivider()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                await checkDivider()
            }
        }
    }

    private func stopKeeping() {
        keeper?.cancel()
        keeper = nil
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        settled = nil
    }

    /// A cheap look at the menu bar (MenuBarAgent's items and our own), off
    /// the main thread: the « button, whether the divider is drawn, where the
    /// first shown icon starts, and the room the overflow has.
    private struct Glance: Sendable, Equatable {
        var drawn: Bool
        var open: Bool
        var dividerX: Double?
        /// The first shown icon's left edge, when « or the divider says.
        var anchor: Double?
        var overflow: MenuBarFit.Room
        var button: (x: Double, width: Double)?

        static func == (a: Glance, b: Glance) -> Bool {
            a.drawn == b.drawn && a.open == b.open && abs((a.anchor ?? -1) - (b.anchor ?? -1)) < 2
                && abs(a.overflow.areaLeft - b.overflow.areaLeft) < 2 && abs(a.overflow.capacity - b.overflow.capacity) < 2
        }
    }

    private func glance() async -> Glance? {
        guard MenuBarAX.trusted else { return nil }
        let owners: Set<String> = ["com.apple.MenuBarAgent", owner]
        let key = dividerKey
        let screen = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
        // Icons start right of the notch, or right of the front app's menus;
        // open, the overflow fills the room left of the notch (or of «).
        let notchRight = screen?.auxiliaryTopRightArea.map { Double($0.minX) }
        let notchLeft = screen?.auxiliaryTopLeftArea.map { Double($0.maxX) }
        let right = Double(screen?.frame.maxX ?? 0)
        return await Task.detached(priority: .userInitiated) {
            let items = MenuBarAX.items(of: owners)
            let divider = items.first { $0.key == key }
            let menus = MenuBarAX.menus()
            let areaLeft = max(notchRight ?? 0, menus.right ?? 0)
            // In the bar means right of the notch (or the menus) and on
            // screen: left of them it's in the open overflow, and far too
            // wide macOS drops it, keeping a stale frame past the edge.
            let drawn = divider.map { $0.x >= areaLeft - 1 && $0.right <= right + 1 } ?? false
            let button = MenuBarAX.overflow(in: items)
            // The first shown icon starts just right of the drawn divider or
            // of «, past the camera and microphone indicator macOS keeps.
            var anchor = drawn ? divider.map { $0.right + MenuBarFit.gap } : button.map { $0.right + MenuBarFit.gap }
            if var at = anchor {
                while let kept = items.first(where: { MenuBarLayout.pinned.contains($0.identifier) && abs($0.x - at) < 3 }) {
                    at = kept.right + MenuBarFit.gap
                }
                anchor = at
            }
            let overflowRight = (notchLeft ?? button?.x ?? areaLeft) - 27
            let overflowLeft = (menus.nameRight ?? 130) + 30
            return Glance(drawn: drawn, open: MenuBarAX.overflowOpen(in: items), dividerX: drawn ? divider?.x : nil,
                          anchor: anchor, overflow: MenuBarFit.Room(areaLeft: areaLeft, overflowLeft: overflowLeft,
                                                                    overflowRight: overflowRight),
                          button: button.map { ($0.x, $0.width) })
        }.value
    }

    /// Fits the divider in one or two steps: just too wide for the menu bar
    /// when the hidden icons still fit in the open overflow (no gap), else
    /// as wide as the room beside « (`MenuBarFit.plan`). The always-hidden
    /// marker follows the overflow's room.
    func fitDivider() async {
        guard Self.overflowing, enabled, !fitting, !busy, moving == nil, reveal != .all else { return }
        fitting = true
        defer { fitting = false }
        guard var look = await glance(), !look.open else { return }
        if markers.hasVault { markers.setVault(width: MenuBarFit.alwaysWidth(look.overflow)) }
        // Where the first shown icon starts: the glance says when « or the
        // divider is drawn; otherwise (everything fits) a whole read does.
        var first = look.anchor
        if first == nil {
            let key = dividerKey
            first = await Task.detached(priority: .userInitiated) {
                MenuBarFit.firstShown(MenuBarAX.items(quick: true), divider: key)?.x
            }.value
        }
        guard let first else { return }
        let hidden = MenuBarFit.hiddenWidth(entries.filter { $0.section == .hidden }.map(\.item.width))
        let plan = MenuBarFit.plan(firstShown: first, room: look.overflow, hidden: hidden)
        var width = plan.width
        mode = plan.mode
        markers.setDivider(width)
        for _ in 0..<4 {
            try? await Task.sleep(for: .milliseconds(220))
            guard let fresh = await glance() else { return }
            look = fresh
            guard !look.open, let next = MenuBarFit.next(width: width, mode: plan.mode, drawn: look.drawn,
                                                         dividerX: look.dividerX, room: look.overflow),
                  abs(next - width) >= 1 else { break }
            width = next
            markers.setDivider(width)
        }
        settled = look
        Log.menubar.debug("divider \(width, privacy: .public) \(plan.mode.rawValue, privacy: .public) drawn \(look.drawn, privacy: .public)")
    }

    /// Refits only when something changed since the last fit: the divider
    /// drawn or not, the first shown icon moved (a ⌘-drag, an app quit),
    /// another front app's menus. Puts the always-hidden marker back once «
    /// closes after Show All.
    func checkDivider() async {
        guard Self.overflowing, enabled, !fitting, !busy, moving == nil, let look = await glance() else { return }
        if look.open { return }
        if reveal != .none {
            reveal = .none
            if markers.hasVault { markers.setVault(width: MenuBarFit.alwaysWidth(look.overflow)) }
        }
        chevronSpan = look.button
        if let settled, settled == look { return }
        await fitDivider()
    }

    /// A new status item lands at the far left, in macOS's overflow. The
    /// first time, the divider is moved just left of the icons on screen,
    /// so turning the manager on hides nothing that shows now.
    private func placeDividerOnce() async {
        guard !UserDefaults.standard.bool(forKey: Self.placedKey), let look = await glance() else { return }
        if look.drawn {
            UserDefaults.standard.set(true, forKey: Self.placedKey)
            return
        }
        busy = true
        defer { busy = false }
        let key = dividerKey
        do {
            try await whole {
                try await Task.detached(priority: .userInitiated) {
                    _ = await MenuBarArranger.setOverflow(true)
                    let items = MenuBarAX.items()
                    let overflow = MenuBarAX.overflow(in: items)?.x ?? -.infinity
                    guard let first = items.first(where: {
                        $0.x > overflow && MenuBarLayout.listed($0) && !MenuBarLayout.pinned.contains($0.identifier)
                    }) else { throw LowtideError.notFound("An icon in the menu bar") }
                    return try await MenuBarArranger.place(key, before: first.key, io: .screen)
                }.value
            }
            UserDefaults.standard.set(true, forKey: Self.placedKey)
        } catch {
            Log.menubar.error("divider not placed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: macOS 27's overflow

    private func overflowOpen() async -> Bool {
        await Task.detached(priority: .userInitiated) { MenuBarAX.overflowOpen(in: MenuBarAX.items(of: ["com.apple.MenuBarAgent"])) }.value
    }

    @discardableResult
    private func setOverflow(_ open: Bool) async -> Bool {
        return await Task.detached(priority: .userInitiated) { await MenuBarArranger.setOverflow(open) }.value
    }

    /// Runs `body` (which may open macOS's overflow, and macOS closes it
    /// after a drop), then reads the whole menu bar with the overflow open,
    /// takes it as the truth with every icon's picture, and leaves the
    /// overflow as it was.
    private func whole(_ body: () async throws -> [MenuBarItem]) async throws {
        let wasOpen = await overflowOpen()
        // The always-hidden icons are only reported with their marker thin.
        let vault = markers.hasVault ? markers.vaultWidth : nil
        if vault != nil { markers.setVault(width: MenuBarFit.line) }
        defer { if let vault, reveal != .all { markers.setVault(width: vault) } }
        do {
            _ = try await body()
        } catch {
            if !wasOpen { await setOverflow(false) }
            throw error
        }
        await setOverflow(true)
        let items = await Task.detached(priority: .userInitiated) { await MenuBarArranger.steady { MenuBarAX.items() } }.value
        take(items)
        await MenuBarPictures.shared.capture(items)
        if !wasOpen { await setOverflow(false) }
    }

    // MARK: Showing and hiding

    func setReveal(_ to: MenuBarReveal, autoHide: Bool = true) {
        guard markers.installed else { return }
        turn += 1
        let mine = turn
        if Self.overflowing {
            Task {
                // Show All: the always-hidden marker goes thin first, so
                // there's room in « for its icons too.
                if to == .all && markers.hasVault { markers.setVault(width: MenuBarFit.line) }
                guard await setOverflow(to != .none) || to == .none else {
                    Toasts.shared.show("Nothing is hidden right now", tone: .neutral)
                    return
                }
                reveal = to
                if to == .none {
                    settled = nil
                    await fitDivider()
                }
                await refresh()
            }
        } else {
            reveal = to
            markers.set(to)
            Task { await refresh() }
        }
        let delay = prefs.autoHide
        guard to != .none, delay > 0, autoHide else { return }
        // Hides again after the delay, but not under the pointer or an open
        // menu: then it waits until both have gone.
        Task {
            try? await Task.sleep(for: .seconds(delay))
            while self.turn == mine {
                if !MenuBarPointer.inMenuBar() && !MenuBarPointer.menuOpen() {
                    self.setReveal(.none)
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Hidden icons on or off.
    func toggleHidden() { setReveal(reveal == .none ? .hidden : .none) }

    /// The chevron was clicked (macOS 26).
    func clicked(secondary: Bool, option: Bool) {
        if secondary {
            AppModel.shared.show(.menuBarManager)
            return
        }
        // Shown in place already: the click puts them away, whatever the mode.
        if prefs.bar && MenuBarAX.trusted && !option && reveal == .none {
            ShelfPanel.shared.toggle()
        } else if option {
            setReveal(reveal == .all ? .none : .all)
        } else {
            toggleHidden()
        }
    }

    /// "Show hidden menu bar icons": the bar under the chevron (26) or under
    /// « (27), or in place: macOS's own overflow on 27.
    func showHidden() {
        guard enabled else {
            Toasts.shared.show("Turn on the menu bar manager first", tone: .warn)
            AppModel.shared.show(.menuBarManager)
            return
        }
        if prefs.bar && MenuBarAX.trusted { ShelfPanel.shared.show() } else { setReveal(.hidden) }
    }

    // MARK: The icons

    /// Re-reads the menu bar off the main thread. On macOS 27 what's in the
    /// closed overflow comes from the last whole read (`readAll`).
    func refresh() async {
        trusted = MenuBarAX.trusted
        rival = MenuBarLayout.rival(among: NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        notch = IslandGeometry.current()?.real ?? false
        guard enabled, moving == nil, !busy else { loaded = loaded || !trusted; return }
        let items = await Task.detached(priority: .userInitiated) { MenuBarAX.items() }.value
        guard moving == nil, !busy else { return }
        if Self.overflowing {
            let open = MenuBarAX.overflowOpen(in: items)
            if !open && reveal != .none {
                // « closed (a click, or another menu opening): the
                // always-hidden marker goes wide again.
                reveal = .none
                Task { await checkDivider() }
            } else if open && reveal == .none {
                reveal = .hidden
            }
            if let button = MenuBarAX.overflow(in: items) { chevronSpan = (button.x, button.width) }
            take(items)
        } else {
            let edges = markers.edges()
            if let chevron = items.first(where: { $0.key == chevronKey }) { chevronSpan = (chevron.x, chevron.width) }
            let fresh = MenuBarLayout.entries(items, edges: edges)
            if fresh != entries { entries = fresh }
        }
        loaded = true
        // Only icons that held still since the last read: one sliding in
        // (the overflow opening) would be cut out of the wrong place.
        let still = items.filter { item in lastRead.contains { $0.key == item.key && abs($0.x - item.x) < 0.5 } }
        lastRead = items
        if watchers > 0 { await MenuBarPictures.shared.capture(still) }
    }

    /// macOS 27: the menu bar as Accessibility reports it now, with what the
    /// closed overflow hides kept from before.
    private func take(_ items: [MenuBarItem]) {
        let running = Set(NSWorkspace.shared.runningApplications.map { $0.bundleIdentifier ?? $0.localizedName ?? "" })
        let fresh = MenuBarLayout.reconcile(items, divider: dividerKey, always: markers.hasVault ? vaultKey : nil,
                                            remembered: remembered, running: running)
        if fresh != entries { entries = fresh }
        // Shown icons macOS isn't drawing: the menu bar is full.
        if !MenuBarAX.overflowOpen(in: items) {
            let live = Set(items.map(\.key))
            crowded = fresh.contains { $0.section == .shown && !$0.fixed && !live.contains($0.key) }
        }
        if fresh != remembered {
            remembered = fresh
            if let data = try? JSONEncoder().encode(fresh) { UserDefaults.standard.set(data, forKey: Self.rememberedKey) }
        }
    }

    /// macOS 27: one whole read, with the overflow open for a moment so
    /// every icon is reported and its picture taken. When the page opens.
    func readAll() async {
        guard Self.overflowing, enabled, MenuBarAX.trusted, !busy, moving == nil else { return await refresh() }
        busy = true
        try? await whole { [] }
        busy = false
        loaded = true
        await refresh()
    }

    /// Keeps the icons current every `every` while the caller waits (a page
    /// in view, the bar down, the Island open).
    func watch(every: Duration = .milliseconds(1500)) async {
        watchers += 1
        defer { watchers -= 1 }
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: every)
        }
    }

    func entry(_ key: String) -> MenuBarEntry? { entries.first { $0.key == key } }

    /// Moves an icon between sections or within one, just left of `before`
    /// when given. The page shows it moving, and its new place only once
    /// the menu bar reports it there.
    func move(_ key: String, to section: MenuBarSection, before: String?, failed: ((String) -> Void)? = nil) {
        guard moving == nil, !busy else { return }
        moving = key
        if Self.overflowing {
            moveInBar(key, to: section, before: before, failed: failed)
            return
        }
        let owner = owner, always = prefs.always
        Task {
            do {
                _ = try await MenuBarArranger.move(key, to: section, before: before, owner: owner, alwaysOn: always)
            } catch {
                report(error, failed)
            }
            moving = nil
            await refresh()
        }
    }

    /// macOS 27: the divider goes thin and the overflow opens, so the icon
    /// and where it goes are both on screen; a real ⌘-drag puts it there,
    /// checked and retried (`MenuBarArranger.place`); then the overflow
    /// closes and the divider grows back to hide what's left of it.
    private func moveInBar(_ key: String, to section: MenuBarSection, before: String?, failed: ((String) -> Void)?) {
        let divider = dividerKey, vault = vaultKey
        Task {
            busy = true
            markers.setDivider(MenuBarFit.line)
            if markers.hasVault { markers.setVault(width: MenuBarFit.line) }
            try? await Task.sleep(for: .milliseconds(250))
            do {
                try await whole {
                    try await Task.detached(priority: .userInitiated) {
                        _ = await MenuBarArranger.setOverflow(true)
                        let now = MenuBarAX.items()
                        let anchor: String
                        if let before {
                            anchor = before
                        } else if section == .shown {
                            guard let first = MenuBarLayout.firstShown(now, after: divider) else {
                                throw LowtideError.notFound("Lowtide's divider in the menu bar")
                            }
                            anchor = first
                        } else if section == .always {
                            guard now.contains(where: { $0.key == vault }) else {
                                throw LowtideError.notFound("Lowtide's always-hidden marker in the menu bar")
                            }
                            anchor = vault
                        } else {
                            anchor = divider
                        }
                        return try await MenuBarArranger.place(key, before: anchor, io: .screen)
                    }.value
                }
            } catch {
                report(error, failed)
            }
            busy = false
            moving = nil
            settled = nil
            await fitDivider()
            await refresh()
        }
    }

    /// An icon from the bar let go over the menu bar at `x`: it goes there,
    /// among the shown icons.
    func drop(_ key: String, at x: Double, failed: ((String) -> Void)? = nil) {
        guard moving == nil else { return }
        if Self.overflowing {
            // AppKit's x is Quartz's on the main screen, where the menu bar is.
            let shown = entries.filter { $0.section == .shown && $0.key != key }
            let before = (shown.first { $0.item.center > x && !$0.fixed } ?? shown.first { $0.fixed })?.key
            move(key, to: .shown, before: before, failed: failed)
            return
        }
        moving = key
        let owner = owner
        Task {
            do {
                try await MenuBarArranger.drop(key, at: x, owner: owner)
            } catch {
                report(error, failed)
            }
            moving = nil
            await refresh()
        }
    }

    /// Opens an icon's menu, from the page, the bar or the Island. On macOS
    /// 27 one in the overflow is opened there, and the overflow closes again
    /// with its menu.
    func open(_ key: String, failed: ((String) -> Void)? = nil) {
        IslandPanel.shared.close()
        ShelfPanel.shared.hide()
        let chevron = chevronKey
        Task {
            do {
                if Self.overflowing {
                    let visible = await Task.detached {
                        MenuBarAX.find(key).map { MenuBarPointer.onScreen(x: $0.x, width: $0.width, y: $0.centerY) } ?? false
                    }.value
                    if visible {
                        try await MenuBarArranger.open(key, relocateAfter: nil)
                    } else {
                        // An always-hidden icon: its marker goes thin so «
                        // has room for it, and wide again once « closes.
                        if markers.hasVault && entry(key)?.section == .always {
                            markers.setVault(width: MenuBarFit.line)
                            reveal = .all
                        }
                        let wasOpen = await overflowOpen()
                        await setOverflow(true)
                        do {
                            try await MenuBarArranger.open(key, relocateAfter: nil)
                            if let pid = await Task.detached(operation: { MenuBarAX.find(key)?.pid }).value {
                                await MenuBarArranger.waitUntilClosed(pid)
                            }
                        } catch {
                            if !wasOpen { await setOverflow(false) }
                            throw error
                        }
                        if !wasOpen { await setOverflow(false) }
                        if reveal == .all { await checkDivider() }
                    }
                } else {
                    try await MenuBarArranger.open(key, relocateAfter: chevron) {
                        Task { @MainActor in await MenuBarManager.shared.refresh() }
                    }
                }
            } catch {
                report(error, failed)
            }
        }
    }

    private func report(_ error: Error, _ failed: ((String) -> Void)?) {
        if let failed { failed(error.localizedDescription) } else { Toasts.shared.failure("The icon didn't move", error) }
    }

    // MARK: The Island

    func pin(_ entry: MenuBarEntry, _ side: IslandPin.Side) {
        var pins = prefs.pins.filter { $0.key != entry.key }
        pins.append(IslandPin(key: entry.key, app: entry.item.app, appPath: entry.item.appPath,
                              label: entry.item.label, side: side))
        prefs.pins = pins
    }

    func unpin(_ key: String) { prefs.pins.removeAll { $0.key == key } }

    func showSettings() {
        IslandPanel.shared.close()
        ShelfPanel.shared.hide()
        AppModel.shared.show(.menuBarManager)
    }
}

/// What can be done to an icon, in groups: open it, move it between
/// sections, put it in the Island. Used by context menus everywhere.
struct MenuBarItemMenu: View {
    let entry: MenuBarEntry
    var failed: ((String) -> Void)?
    private var manager = MenuBarManager.shared

    init(entry: MenuBarEntry, failed: ((String) -> Void)? = nil) {
        self.entry = entry
        self.failed = failed
    }

    var body: some View {
        Button("Open") { manager.open(entry.key, failed: failed) }
        if !entry.fixed {
            Divider()
            ForEach(manager.sections.filter { $0 != entry.section }, id: \.self) { section in
                Button(section.moveTitle) { manager.move(entry.key, to: section, before: nil, failed: failed) }
                    .disabled(manager.moving != nil || manager.busy)
            }
        }
        if manager.prefs.island {
            Divider()
            if manager.prefs.pins.contains(where: { $0.key == entry.key }) {
                Button("Remove from the Island") { manager.unpin(entry.key) }
            } else {
                Button("Add to the Island") { manager.pin(entry, .inside) }
                Button("Pin Left of the Notch") { manager.pin(entry, .left) }
                Button("Pin Right of the Notch") { manager.pin(entry, .right) }
            }
        }
    }
}


