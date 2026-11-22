import LowtideKit
import SwiftUI

/// What extends apps, browsers and macOS without being an app: browser
/// extensions, widgets, screen savers, settings panes and plug-ins. Audio
/// plug-ins are a view of their own.
struct AddonsPage: View {
    @Bindable private var model = AddonsModel.shared

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("Add-ons", description: description) {
                Segmented($model.view, [(.addons, "All add-ons"), (.plugins, "Audio plug-ins")])
            } action: {
                let scanning = model.view == .addons ? model.scanning : model.pluginsScanning
                IconButton("arrow.clockwise", help: scanning ? "Scanning…" : "Scan again") {
                    if model.view == .addons { model.scan() } else { model.scanPlugins() }
                }
                .disabled(scanning)
            }
            if model.view == .addons { AddonsView() } else { AudioPluginsView() }
        }
        .onAppear {
            if model.addons == nil { model.scan() }
            if !model.pluginsScanned { model.scanPlugins() }
        }
    }

    private var description: String {
        if model.view == .plugins {
            let all = model.plugins
            let vendors = Set(all.compactMap(\.vendor)).count
            let bundles = all.reduce(0) { $0 + $1.formats.count }
            return model.pluginsScanned ? "\(LowtideFormat.count(all.count, "plug-in")) from \(LowtideFormat.count(vendors, "vendor")) · \(bundles) format bundles"
                : "Looking through the plug-in folders"
        }
        guard let addons = model.addons else { return "Looking through your folders, browsers and Library" }
        let bytes = addons.compactMap(\.bytes).reduce(0, +) + model.plugins.compactMap(\.bytes).reduce(0, +)
        return "\(LowtideFormat.count(addons.count + model.plugins.count, "add-on")) · \(LowtideFormat.bytes(bytes))"
    }
}

/// One kind of add-on, as the list on the left names it.
struct AddonKind: Identifiable {
    var id: Addon.Kind
    var label: String
    var about: String
    var symbol: String

    static let all: [AddonKind] = [
        AddonKind(id: .browser, label: "Browser extensions",
                  about: "Extensions in Chrome, Brave, Edge, Arc, Dia, Vivaldi, Opera and Firefox, for every profile. Quit the browser before removing one.",
                  symbol: "globe"),
        AddonKind(id: .safari, label: "Safari extensions",
                  about: "Safari extensions ship inside their apps: switch them off in Safari’s settings, or remove the app to remove them.",
                  symbol: "safari"),
        AddonKind(id: .widget, label: "Widgets", about: "Widgets apps add to the desktop and Notification Center. They go with their app.",
                  symbol: "square.grid.2x2"),
        AddonKind(id: .screensaver, label: "Screen savers", about: "Screen savers installed for you or for every user.", symbol: "display"),
        AddonKind(id: .prefpane, label: "Settings panes", about: "Third-party panes at the bottom of System Settings.", symbol: "gearshape"),
        AddonKind(id: .internet, label: "Internet plug-ins",
                  about: "Browser plug-ins from the Flash and Java days. No current browser loads them.", symbol: "network"),
        AddonKind(id: .quicklook, label: "Quick Look plug-ins", about: "Previews Finder’s Quick Look shows for file types it can’t read.",
                  symbol: "eye"),
        AddonKind(id: .spotlight, label: "Spotlight importers", about: "Importers that let Spotlight search inside more kinds of file.",
                  symbol: "magnifyingglass"),
    ]
}

/// The kinds on the left, the chosen kind's add-ons on the right, grouped
/// by where each comes from.
private struct AddonsView: View {
    @Environment(\.palette) private var palette
    private var model = AddonsModel.shared
    @State private var query = ""
    @State private var kind: Addon.Kind = .browser
    /// Until the person picks a kind, the page opens on one that has something.
    @State private var picked = false

    private var visible: [Addon] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return (model.addons ?? []).filter { needle.isEmpty || "\($0.name) \($0.source) \($0.id)".lowercased().contains(needle) }
    }

    var body: some View {
        let visible = visible
        SplitList(query: $query, searchPrompt: "Search add-ons") {
            EmptyView()
        } list: {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(AddonKind.all) { item in
                        let items = visible.filter { $0.kind == item.id }
                        // An empty kind is noise; it comes back when something of it shows up.
                        if model.addons == nil || !items.isEmpty || item.id == kind {
                            KindRow(symbol: item.symbol, label: item.label, count: model.addons == nil ? nil : items.count,
                                    bytes: items.compactMap(\.bytes).reduce(0, +), selected: item.id == kind) {
                                kind = item.id
                                picked = true
                            }
                        }
                    }
                    KindRow(symbol: "waveform", label: "Audio plug-ins", count: model.pluginsScanned ? model.plugins.count : nil,
                            bytes: model.plugins.compactMap(\.bytes).reduce(0, +), selected: false) {
                        withAnimation(Motion.base) { model.view = .plugins }
                    }
                }
                .padding(Space.sm)
            }
        } detail: {
            if model.addons == nil {
                ScanningState(title: "Looking for add-ons")
            } else if let about = AddonKind.all.first(where: { $0.id == kind }) {
                KindList(kind: about, addons: visible.filter { $0.kind == kind }).id(kind)
            }
        }
        .task(id: model.addons?.count) { openOnSomething() }
    }

    private func openOnSomething() {
        guard !picked, let addons = model.addons, !addons.contains(where: { $0.kind == kind }) else { return }
        if let first = AddonKind.all.first(where: { kind in addons.contains { $0.kind == kind.id } }) { kind = first.id }
    }
}

private struct KindRow: View {
    @Environment(\.palette) private var palette
    @State private var hovering = false
    let symbol: String
    let label: String
    /// Nil while it's still being counted.
    let count: Int?
    let bytes: Int64
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.sm + 2) {
                Image(systemName: symbol).font(.system(size: 13))
                    .foregroundStyle(((count ?? 0) > 0 ? palette.ink2 : palette.ink4).color)
                    .frame(width: 30, height: 30)
                    .background(palette.fill.color, in: .rect(cornerRadius: Radius.md))
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color).lineLimit(1)
                    Text(count.map { LowtideFormat.count($0, "item") } ?? "Counting…").font(.ui(.xxs)).foregroundStyle(palette.ink3.color)
                }
                Spacer(minLength: Space.xs)
                if bytes > 0 { Text(LowtideFormat.bytes(bytes)).font(.mono(.xs)).monospacedDigit().foregroundStyle(palette.ink2.color) }
            }
            .padding(.horizontal, Space.sm)
            .padding(.vertical, 5)
            .background((selected ? palette.selectedBrand : hovering ? palette.hover : ColorValue(r: 0, g: 0, b: 0, a: 0)).color,
                        in: .rect(cornerRadius: Radius.md))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// One kind of add-on, grouped by where each comes from.
private struct KindList: View {
    @Environment(\.palette) private var palette
    private var model = AddonsModel.shared
    let kind: AddonKind
    let addons: [Addon]
    @State private var checks = Checks<String>()
    @State private var confirm: ConfirmRequest?

    init(kind: AddonKind, addons: [Addon]) {
        self.kind = kind
        self.addons = addons
    }

    private var groups: [(source: String, list: [Addon])] {
        Dictionary(grouping: addons, by: \.source)
            .map { ($0.key, $0.value.sorted { ($0.bytes ?? 0) != ($1.bytes ?? 0) ? ($0.bytes ?? 0) > ($1.bytes ?? 0) : $0.name < $1.name }) }
            .sorted {
                let (a, b) = ($0.list.compactMap(\.bytes).reduce(0, +), $1.list.compactMap(\.bytes).reduce(0, +))
                return a != b ? a > b : $0.source < $1.source
            }
    }

    var body: some View {
        let removable = addons.filter(\.removable)
        let order = removable.map(\.id)
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: Space.lg) {
                        Image(systemName: kind.symbol).font(.system(size: 20)).foregroundStyle(palette.ink2.color)
                            .frame(width: 44, height: 44).background(palette.fill.color, in: .rect(cornerRadius: Radius.lg))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(kind.label).font(.title(.lg)).foregroundStyle(palette.ink.color)
                            Text(kind.about).font(.ui(.xs)).foregroundStyle(palette.ink3.color).frame(maxWidth: 520, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(Space.page)
                    if addons.isEmpty {
                        EmptyState("No \(kind.label.lowercased())", symbol: kind.symbol, message: "Nothing of this kind is on this Mac.")
                            .frame(minHeight: 240)
                    } else {
                        if !removable.isEmpty {
                            HStack(spacing: Space.sm) {
                                Checkbox(checks.state(of: order), label: "Select all") { checks.set(order, on: checks.state(of: order) != .on) }
                                Text("\(removable.count) you can remove · \(LowtideFormat.bytes(removable.compactMap(\.bytes).reduce(0, +)))")
                                    .font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                            }
                            .padding(.horizontal, Space.lg).frame(height: 32).frame(maxWidth: .infinity, alignment: .leading)
                            .hairline(.top)
                        }
                        ForEach(groups, id: \.source) { group in
                            Section {
                                ForEach(group.list) { addon in row(addon, order: order) }
                            } header: {
                                HStack {
                                    Text(group.source).font(.ui(.xs, .semibold)).foregroundStyle(palette.ink2.color).lineLimit(1)
                                    Spacer()
                                    let bytes = group.list.compactMap(\.bytes).reduce(0, +)
                                    Text("\(group.list.count)\(bytes > 0 ? " · \(LowtideFormat.bytes(bytes))" : "")")
                                        .font(.mono(.xxs)).monospacedDigit().foregroundStyle(palette.ink3.color)
                                }
                                .padding(.horizontal, Space.lg).frame(height: 28)
                                .background(palette.bg.color)
                                .hairline(.top).hairline(.bottom)
                            }
                        }
                    }
                }
                .padding(.bottom, checks.isEmpty ? Space.lg : 64)
            }
            if !checks.isEmpty {
                let checked = addons.filter { checks.has($0.id) }
                SelectionBar(count: checks.count, noun: "item",
                             status: LowtideFormat.bytes(checked.compactMap(\.bytes).reduce(0, +)), working: !model.removing.isEmpty,
                             clear: { checks.clear() }) {
                    Button("Move to Trash") { ask(checked) }.buttonStyle(.lowtide(.destructive, size: .small)).disabled(!model.removing.isEmpty)
                }
                .padding(Space.sm)
            }
        }
        .animation(Motion.base, value: checks.isEmpty)
        .onChange(of: addons.map(\.id)) { _, ids in checks.keep(Set(ids)) }
        .confirmation($confirm)
    }

    private func row(_ addon: Addon, order: [String]) -> some View {
        HStack(spacing: Space.sm + 2) {
            if addon.removable {
                Checkbox(checks.has(addon.id), label: "Select \(addon.name)") { checks.toggle(addon.id, in: order) }
            } else {
                Color.clear.frame(width: 14, height: 14)
            }
            glyph(addon).frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(addon.name).font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color).lineLimit(1)
                    if let version = addon.version { Text(version).font(.mono(.xxs)).foregroundStyle(palette.ink4.color).lineLimit(1) }
                    if addon.needsAdmin {
                        Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(palette.ink4.color).help("Asks for your password, unless the helper is on")
                    }
                }
                Sensitive(text: Paths.tilde(addon.id), font: .mono(.xxs)).foregroundStyle(palette.ink3.color).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: Space.sm)
            Text(addon.bytes.map(LowtideFormat.bytes) ?? "–").font(.mono(.xs)).monospacedDigit().foregroundStyle(palette.ink2.color)
        }
        .padding(.horizontal, Space.lg)
        .frame(minHeight: 46)
        .opacity(model.removing.contains(addon.id) ? 0.5 : 1)
        .contextMenu {
            PathMenu(addon.id)
            if let app = addon.app {
                Button("Show the App in Finder") { Files.reveal([app]) }
            }
            if addon.removable {
                Divider()
                Button("Move to Trash…", role: .destructive) { ask(addons.filter { checks.targets(addon.id).contains($0.id) }) }
            }
        }
        .help(addon.removable ? "" : "Ships inside \(addon.app.map { ($0 as NSString).lastPathComponent } ?? "its app"); remove the app to remove it")
    }

    @ViewBuilder private func glyph(_ addon: Addon) -> some View {
        if let icon = addon.icon, let image = NSImage(contentsOfFile: icon) {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        } else if let app = addon.app {
            AppsIcon(path: app, size: 30)
        } else {
            Image(systemName: kind.symbol).font(.system(size: 13)).foregroundStyle(palette.ink3.color)
                .frame(width: 30, height: 30).background(palette.fill.color, in: .rect(cornerRadius: Radius.md))
        }
    }

    private func ask(_ items: [Addon]) {
        let items = items.filter(\.removable)
        guard !items.isEmpty else { return }
        confirm = ConfirmRequest(
            title: "Move \(LowtideFormat.count(items.count, "item")) to the Trash?",
            message: "\(items.count) \(kind.label.lowercased()), \(LowtideFormat.bytes(items.compactMap(\.bytes).reduce(0, +))). "
                + "They go to the Trash, so you can put them back until you empty it. System-wide ones ask for your password once.",
            confirm: "Move to Trash"
        ) {
            model.remove(items, label: kind.label)
            checks.clear()
        }
    }
}
