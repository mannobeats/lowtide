import LowtideKit
import SwiftUI

/// Extensions › Menu bar manager: how hidden icons show, the icons in their
/// sections (drag them between rows), and the Island.
struct MenuBarManagerPage: View {
    @Environment(\.palette) private var palette
    @Bindable private var manager = MenuBarManager.shared
    @State private var tick = 0
    @State private var drag = MenuBarDrag()
    @State private var error: String?

    static let about = "Hide the menu bar icons you rarely need, open them when you want them, and drag them into the order you want. An optional Island under the notch holds favourites and live stats."
    /// macOS 27 hides icons in its own overflow, and putting them there is a
    /// ⌘-drag Lowtide makes for you: that needs Accessibility too.
    static let facts = MenuBarManager.overflowing
        ? ["Accessibility to hide and arrange icons", "Screen Recording for their pictures"]
        : ["Accessibility to arrange icons", "Hiding needs nothing"]
    private var overflowing: Bool { MenuBarManager.overflowing }

    var body: some View {
        PageScaffold(maxWidth: 820) {
            hero
        } content: {
            if manager.enabled {
                VStack(alignment: .leading, spacing: Space.xl) { settings }
                    .coordinateSpace(.named(MenuBarDrag.space))
                    .overlay(alignment: .topLeading) { preview }
            } else {
                PrefsAbout(about: Self.about, facts: Self.facts)
            }
        }
        .task(id: manager.enabled) {
            guard manager.enabled else { return }
            // One whole read as the page opens (macOS 27 hides what's in its
            // overflow from Accessibility until it's open), then cheap ones.
            await manager.readAll()
            await manager.watch()
        }
        .onAppActivate { tick += 1 }
    }

    /// The icon being dragged, under the pointer.
    @ViewBuilder private var preview: some View {
        if let entry = drag.entry {
            MenuBarChipFace(entry: entry)
                .overlaySurface()
                .fixedSize()
                .position(x: drag.location.x, y: drag.location.y)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var hidden: Int { manager.entries.filter { $0.section != .shown }.count }

    private var hero: some View {
        _ = tick
        let (title, detail, action) = heroState
        return PageHero(title, detail: detail, art: "menubar") {
            if let action { Button(action.0, action: action.1).buttonStyle(.primary) }
            if manager.enabled {
                Button("Turn Off") { manager.setEnabled(false) }
                    .buttonStyle(.quiet)
                    .help("Every icon comes back. Your sections and the Island stay for next time.")
            }
        }
    }

    private var heroState: (String, String, (String, () -> Void)?) {
        guard manager.enabled else {
            return ("A tidy menu bar, like Bartender", overflowing
                    ? "Hidden icons go behind macOS's own «. Hiding and arranging ask for Accessibility once."
                    : "Hiding needs no permission; arranging asks for Accessibility once.",
                    ("Turn On", { manager.setEnabled(true) }))
        }
        if let rival = manager.rival {
            return ("\(rival) is running", "Quit it before using this: two menu bar managers push the same icons around.", nil)
        }
        if !manager.trusted {
            return (overflowing ? "Allow Accessibility to hide icons" : "Allow Accessibility to arrange icons", overflowing
                    ? "On macOS 27 hiding, naming and arranging icons and the Island all need it."
                    : "Hiding works without it. The bar under the chevron, arranging and the Island need it.",
                    ("Allow Accessibility", { Permission.accessibility.request() }))
        }
        let shown = manager.reveal != .none
        let title = !manager.loaded ? "Reading the menu bar…"
            : hidden == 0 ? "Nothing hidden yet"
            : overflowing ? "\(LowtideFormat.count(hidden, "icon")) behind «" : "\(LowtideFormat.count(hidden, "icon")) behind the chevron"
        let detail: String
        if overflowing {
            detail = manager.crowded
                ? "The shown icons fill the menu bar, so macOS keeps some of them behind « too."
                : hidden == 0 ? "Drag icons into Hidden below, or ⌘-drag them into « in the menu bar."
                : manager.mode == .bar
                ? "So many are hidden that « couldn't show them all, so the menu bar keeps a little room beside it."
                : manager.prefs.bar ? "Click « in the menu bar, or Show Hidden for Lowtide's bar under it."
                : "Click « in the menu bar to see them, or drag them back into Shown."
        } else {
            detail = hidden == 0
                ? "Drag icons into Hidden below, or ⌘-drag them left of the chevron's line."
                : "Click the chevron for the bar under it; ⌥-click shows every icon in place."
        }
        if overflowing {
            let all = manager.prefs.always
            // Lowtide's bar when it's the choice; else « itself, all of it
            // with an always-hidden section.
            let bar = manager.prefs.bar && !shown
            return (title, detail, hidden == 0 ? nil : (shown ? "Hide Icons" : bar ? "Show Hidden" : all ? "Show All" : "Show Hidden", {
                if bar { manager.showHidden() } else { manager.setReveal(shown ? .none : all ? .all : .hidden) }
            }))
        }
        return (title, detail, (shown ? "Hide Icons" : "Show All", { manager.setReveal(shown ? .none : .all) }))
    }

    @ViewBuilder private var settings: some View {
        PrefsGroup {
            PrefsRow("Accessibility", hint: manager.trusted
                     ? "Icons are named, opened and arranged here"
                     : overflowing ? "Hiding, naming and arranging icons and the Island need it"
                     : "Hiding works without it. The bar under the chevron, arranging and the Island need it") {
                if manager.trusted {
                    PrefsAllowed()
                } else {
                    Button("Allow") { Permission.accessibility.request() }.buttonStyle(.lowtide(.secondary, size: .small))
                }
            }
            PrefsRow("Icon pictures", hint: Permission.screenRecording.state == .granted
                     ? "Each icon looks here just as it does in the menu bar"
                     : "Screen Recording lets this page show each icon as it really looks, not its app's icon") {
                if Permission.screenRecording.state == .granted {
                    PrefsAllowed()
                } else {
                    Button("Allow") { Permission.screenRecording.request() }.buttonStyle(.lowtide(.secondary, size: .small))
                }
            }
        }
        PrefsGroup("Behaviour") {
            PrefsRow(overflowing ? "Show Hidden opens" : "The chevron shows hidden icons", hint: manager.prefs.bar
                     ? (overflowing ? "Lowtide's bar under «, like Bartender's; « still opens macOS's own"
                        : "A bar drops under the chevron, like Bartender's")
                     : (overflowing ? "macOS's « in the menu bar" : "They appear in the menu bar itself")) {
                Segmented(Binding(get: { manager.prefs.bar }, set: { manager.prefs.bar = $0 }),
                          [(true, "Below"), (false, "In place")])
            }
            PrefsRow("Always-hidden section", hint: overflowing
                     ? "Icons you never need, kept out of « too. Show All or Lowtide's bar shows them"
                     : "Icons you never need, out of the bar too. ⌥-click the chevron to see them") {
                PrefsSwitch("Always-hidden section", isOn: $manager.prefs.always)
            }
            PrefsRow("Hide icons shown in place again", hint: overflowing ? "After Show Hidden opens « for you" : nil) {
                Picker("Hide icons shown in place again", selection: $manager.prefs.autoHide) {
                    Text("Never").tag(0)
                    Text("After 5 seconds").tag(5)
                    Text("After 10 seconds").tag(10)
                    Text("After 30 seconds").tag(30)
                    Text("After a minute").tag(60)
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        PrefsGroup("Icons") {
            if manager.moving != nil || manager.busy { ProgressView().controlSize(.small) }
        } content: {
            VStack(alignment: .leading, spacing: Space.sm) {
                if manager.trusted {
                    let entries = drag.frozen ?? manager.entries
                    ForEach(manager.sections, id: \.self) { section in
                        MenuBarLane(id: .section(section), title: section.title, hint: section.hint(overflowing: overflowing),
                                    entries: entries.filter { $0.section == section }, drag: drag, dropped: drop)
                    }
                    if let error {
                        Text(error).font(.ui(.xs)).foregroundStyle(palette.bad.color).textSelection(.enabled)
                    } else {
                        Text("Drag icons between rows, or between two icons to put them there. Right-click one for more.")
                            .font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                    }
                } else {
                    Text(overflowing
                         ? "⌘-drag icons into « in the menu bar to hide them; macOS shows them when you click it."
                         : "Icons left of the thin line next to the chevron are hidden. ⌘-drag icons across it in the menu bar to choose which.")
                        .font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                }
            }
            .padding(.vertical, Space.md)
        }
        PrefsGroup("Island") {
            PrefsRow("Notch Island", hint: manager.loaded && !manager.notch
                     ? "Point at the top middle of the screen (no notch here) for the icons and stats you choose"
                     : "Point at the notch for the icons and stats you choose") {
                PrefsSwitch("Notch Island", isOn: $manager.prefs.island)
            }
            if manager.prefs.island {
                PrefsRow("Live stats in the Island", hint: "CPU, memory, network and battery, read only while it's open") {
                    PrefsSwitch("Live stats in the Island", isOn: $manager.prefs.stats)
                }
                PrefsRow("In the Island", block: true) {
                    MenuBarLane(id: .island, title: "Icons", hint: "Drop icons here, or right-click one to pin it beside the notch",
                                entries: manager.prefs.pins.map { pin in
                                    manager.entry(pin.key) ?? MenuBarEntry(
                                        item: MenuBarItem(key: pin.key, app: pin.app, appPath: pin.appPath, label: pin.label,
                                                          system: pin.key.hasPrefix(MenuBarNames.systemOwner + "#"), x: 0, width: 0),
                                        section: .hidden, fixed: true)
                                }, drag: drag, dropped: drop)
                }
            }
        }
    }

    /// A drop in a section row is a real move in the menu bar, shown here
    /// once it's done; in the Island's row it pins the icon.
    private func drop(_ key: String, _ target: MenuBarDrag.Target, _ entries: [MenuBarEntry]) {
        switch target.lane {
        case .island:
            if let entry = manager.entry(key) { manager.pin(entry, .inside) }
        case .section(let section):
            move(key, to: section, before: target.before, entries: entries)
        }
    }

    /// Dropping an icon where it already is does nothing.
    private func move(_ key: String, to section: MenuBarSection, before: String?, entries: [MenuBarEntry]) {
        guard key != before, let from = entries.firstIndex(where: { $0.key == key }) else { return }
        let lane = entries.filter { $0.section == section }
        if entries[from].section == section {
            let next = lane.firstIndex { $0.key == key }.map { $0 + 1 < lane.count ? lane[$0 + 1].key : nil }
            if next == before { return }
        }
        // The end of the shown row is just left of the clock and Control
        // Center, which macOS keeps last.
        let anchor = before ?? (section == .shown ? lane.first { $0.fixed }?.key : nil)
        error = nil
        manager.move(key, to: section, before: anchor) { error = $0 }
    }
}

/// A drag on the page, made by hand rather than with drag and drop: the
/// preview follows the pointer every frame, the row and the place it would
/// land light up, and the rows hold still while the menu bar is re-read.
@Observable
final class MenuBarDrag {
    struct Target: Equatable {
        var lane: MenuBarLane.ID
        var before: String?
    }

    var entry: MenuBarEntry?
    /// The pointer, in the page's `space`.
    var location: CGPoint = .zero
    var target: Target?
    /// The rows as they were when the drag began.
    var frozen: [MenuBarEntry]?
    nonisolated static let space = "menubar.icons"

    @ObservationIgnored var lanes: [MenuBarLane.ID: CGRect] = [:]
    @ObservationIgnored var chips: [MenuBarLane.ID: [(key: String, frame: CGRect)]] = [:]

    func begin(_ entry: MenuBarEntry, frozen: [MenuBarEntry]) {
        self.entry = entry
        self.frozen = frozen
    }

    func moved(to point: CGPoint) {
        location = point
        let next = hit(point)
        if next != target { target = next }
    }

    func end() -> Target? {
        defer {
            entry = nil
            target = nil
            frozen = nil
        }
        return target
    }

    /// The row under the pointer, and the icon it would go before: the first
    /// one on a lower line, or on the same line with its middle right of the
    /// pointer. Past the last one, the end of the row.
    private func hit(_ point: CGPoint) -> Target? {
        guard let lane = lanes.first(where: { $0.value.insetBy(dx: -4, dy: -4).contains(point) })?.key else { return nil }
        let ordered = (chips[lane] ?? []).sorted { abs($0.frame.minY - $1.frame.minY) > 4 ? $0.frame.minY < $1.frame.minY : $0.frame.minX < $1.frame.minX }
        let before = ordered.first { chip in
            point.y < chip.frame.minY - 3 || (abs(point.y - chip.frame.midY) <= chip.frame.height / 2 + 3 && point.x < chip.frame.midX)
        }?.key
        return Target(lane: lane, before: before)
    }
}

/// One row of icons: a section, or the Island.
struct MenuBarLane: View {
    enum ID: Hashable {
        case section(MenuBarSection), island
    }

    @Environment(\.palette) private var palette
    let id: ID
    let title: String
    let hint: String
    let entries: [MenuBarEntry]
    let drag: MenuBarDrag
    /// The page's: an icon let go over a row (any row), with the rows as
    /// they were when the drag began.
    let dropped: (String, MenuBarDrag.Target, [MenuBarEntry]) -> Void
    private var manager = MenuBarManager.shared

    init(id: ID, title: String, hint: String, entries: [MenuBarEntry], drag: MenuBarDrag,
         dropped: @escaping (String, MenuBarDrag.Target, [MenuBarEntry]) -> Void) {
        self.id = id
        self.title = title
        self.hint = hint
        self.entries = entries
        self.drag = drag
        self.dropped = dropped
    }

    private var targeted: Bool { drag.target?.lane == id && drag.entry != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Text(title).font(.ui(.xs, .medium)).foregroundStyle(palette.ink.color)
                Text(hint).font(.ui(.xxs)).foregroundStyle(palette.ink3.color)
            }
            FlowLayout(spacing: 6) {
                if entries.isEmpty {
                    Text(targeted ? " " : "Drop icons here").font(.ui(.xs)).foregroundStyle(palette.ink4.color).frame(height: 30)
                }
                ForEach(entries) { entry in
                    MenuBarChip(entry: entry, lane: id, drag: drag, pinned: manager.prefs.pins.contains { $0.key == entry.key },
                                caret: targeted && drag.target?.before == entry.key) { target, rows in
                        if let target { dropped(entry.key, target, rows) }
                    }
                }
                if targeted && drag.target?.before == nil { Caret() }
            }
            .frame(minHeight: 30, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((targeted ? palette.brandSoft : ColorValue(r: 0, g: 0, b: 0, a: 0)).color, in: .rect(cornerRadius: Radius.lg))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg).strokeBorder((targeted ? palette.brand : palette.lineStrong).color,
                                                                         style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(MenuBarDrag.space)) } action: { drag.lanes[id] = $0 }
        .animation(Motion.fast, value: targeted)
        .animation(Motion.spring, value: entries.map(\.key))
    }
}

/// Where a dragged icon would go.
private struct Caret: View {
    @Environment(\.palette) private var palette
    var body: some View {
        Capsule().fill(palette.brand.color).frame(width: 2, height: 30)
    }
}

/// One icon on the page: its picture and short name, dragged by hand.
private struct MenuBarChip: View {
    @Environment(\.palette) private var palette
    let entry: MenuBarEntry
    let lane: MenuBarLane.ID
    let drag: MenuBarDrag
    let pinned: Bool
    let caret: Bool
    let ended: (MenuBarDrag.Target?, [MenuBarEntry]) -> Void
    @State private var hovering = false
    private var manager = MenuBarManager.shared

    init(entry: MenuBarEntry, lane: MenuBarLane.ID, drag: MenuBarDrag, pinned: Bool, caret: Bool,
         ended: @escaping (MenuBarDrag.Target?, [MenuBarEntry]) -> Void) {
        self.entry = entry
        self.lane = lane
        self.drag = drag
        self.pinned = pinned
        self.caret = caret
        self.ended = ended
    }

    private var inFlight: Bool { manager.moving == entry.key }
    private var lifted: Bool { drag.entry?.key == entry.key }
    /// The clock and Control Center stay where macOS keeps them; nothing
    /// else starts while an icon is moving.
    private var draggable: Bool { !entry.fixed && manager.moving == nil && !manager.busy }

    var body: some View {
        HStack(spacing: 0) {
            if caret { Caret().padding(.trailing, 4) }
            MenuBarChipFace(entry: entry, pinned: pinned, hovering: hovering, working: inFlight)
                .opacity(lifted ? 0.35 : inFlight ? 0.7 : 1)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(MenuBarDrag.space)) } action: { frame in
                    var list = drag.chips[lane]?.filter { $0.key != entry.key } ?? []
                    list.append((entry.key, frame))
                    drag.chips[lane] = list
                }
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onDisappear { drag.chips[lane]?.removeAll { $0.key == entry.key } }
        .help(inFlight ? "Moving in the menu bar…" : MenuBarChipFace.help(entry))
        .contextMenu { MenuBarItemMenu(entry: entry) }
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .named(MenuBarDrag.space))
                .onChanged { value in
                    guard draggable else { return }
                    if drag.entry == nil { drag.begin(entry, frozen: manager.entries) }
                    drag.moved(to: value.location)
                }
                .onEnded { _ in
                    guard drag.entry?.key == entry.key else { return }
                    let rows = drag.frozen ?? manager.entries
                    ended(drag.end(), rows)
                },
            including: draggable ? .all : .subviews
        )
        .animation(Motion.fast, value: caret)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Open") { manager.open(entry.key) }
    }
}

/// A chip's look, shared by the row and the drag preview.
struct MenuBarChipFace: View {
    @Environment(\.palette) private var palette
    let entry: MenuBarEntry
    var pinned = false
    var hovering = false
    var working = false

    static func help(_ entry: MenuBarEntry) -> String {
        let said = entry.item.label.isEmpty ? entry.item.title : entry.item.label
        return said.isEmpty || said == entry.name ? entry.name : "\(entry.name): \(said)"
    }

    var body: some View {
        HStack(spacing: 6) {
            MenuBarItemIcon(key: entry.key, appPath: entry.item.appPath, size: 16)
            Text(entry.name).font(.ui(.xs)).foregroundStyle((hovering ? palette.ink : palette.ink2).color).lineLimit(1)
                .frame(maxWidth: 160, alignment: .leading)
            if working {
                ProgressView().controlSize(.mini).accessibilityLabel("Moving")
            } else if pinned {
                Image(systemName: "pin.fill").font(.ui(.xxs)).foregroundStyle(palette.brand.color)
                    .accessibilityLabel("In the Island")
            }
        }
        .padding(.horizontal, Space.sm)
        .frame(height: 30)
        .background(palette.surface.color, in: .rect(cornerRadius: Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder((hovering ? palette.lineStrong : palette.line).color))
    }
}
