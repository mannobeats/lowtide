import LowtideKit
import SwiftUI

/// Cleanup: space a developer can take back. Two views: caches and build
/// files (package and tool caches, Xcode, project build folders, Docker),
/// and Downloads and installers.
struct CleanupPage: View {
    enum Tab: String { case caches, downloads }
    @AppStorage("cleanup.tab") private var tab: Tab = .caches

    var body: some View {
        switch tab {
        case .caches: CachesView(tabs: tabs)
        case .downloads: DownloadsView(tabs: tabs)
        }
    }

    private var tabs: some View {
        Segmented($tab, [(.caches, "Caches and build files"), (.downloads, "Downloads & installers")])
    }
}

private struct CachesView<Tabs: View>: View {
    enum Scope: String, Hashable { case all, projects, caches, xcode, docker }
    enum Narrow: Hashable { case any, safe, stale, large }

    @Environment(\.palette) private var palette
    var store = CleanupStore.shared
    var settings = CleanupSettings.shared
    let tabs: Tabs
    @State private var scope: Scope = .all
    @State private var narrow: Narrow = .any
    @State private var search = ""
    @State private var confirm: ConfirmRequest?

    static var groups: [(group: Reclaimable.Group, chip: String, title: String, noun: String)] {
        [(.projects, "Projects", "Project build folders", "build folder"),
         (.caches, "Caches", "Package and tool caches", "cache"),
         (.xcode, "Xcode", "Xcode", "Xcode item")]
    }

    private func matches(_ item: Reclaimable) -> Bool {
        let inScope = scope == .all || scope.rawValue == item.group.rawValue
        let narrowed = switch narrow {
        case .any: true
        case .safe: item.safety == .safe
        case .stale: item.group != .projects || item.isStale()
        case .large: (item.bytes ?? 0) >= 1_000_000_000
        }
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        let found = needle.isEmpty || "\(item.name) \(item.project ?? "") \(item.path)".lowercased().contains(needle)
        return inScope && narrowed && found
    }

    var body: some View {
        let all = store.all
        let visible = all.filter(matches)
        // Only what's on screen gets cleaned: a filter hides, it doesn't select.
        let targets = visible.filter { store.checks.has($0.id) }
        let selectedBytes = targets.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
        let (title, detail) = heroCopy(selectedBytes: selectedBytes)
        PageScaffold {
            PageHero(title, detail: detail, art: "cleanup") {
                if store.cleaning || store.freed == 0 || !targets.isEmpty {
                    Button {
                        confirm = request(targets, bytes: selectedBytes)
                    } label: {
                        HStack(spacing: 6) {
                            if store.cleaning { ProgressView().controlSize(.small) }
                            Text(store.cleaning ? "Cleaning…" : "Review and clean")
                        }
                    }
                    .buttonStyle(.lowtide(.primary, size: .large))
                    .disabled(targets.isEmpty || store.cleaning)
                }
                Button {
                    store.rescan()
                } label: {
                    Label("Scan again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.lowtide(.quiet, size: .large))
                .disabled(store.scanning || store.cleaning)
            }
        } content: {
            Clean.DiskBar(disk: store.disk, reclaim: selectedBytes)
            PageToolbar {
                tabs
            } trailing: {
                FilterField(text: $search, prompt: "Filter by name or path")
            }
            HStack(spacing: Space.sm) {
                Segmented($scope, [(.all, "Everything")] + Self.groups.map { (Scope(rawValue: $0.group.rawValue)!, $0.chip) } + [(.docker, "Docker")],
                          counts: Dictionary(uniqueKeysWithValues: Self.groups.map { group in
                              (Scope(rawValue: group.group.rawValue)!, all.filter { $0.group == group.group }.count)
                          }))
                Segmented($narrow, [(.any, "Any"), (.safe, "Safe only"), (.stale, "Unused projects"), (.large, "Over 1 GB")])
                Spacer(minLength: 0)
            }
            groups(all: all, visible: visible)
            if scope == .all || scope == .docker {
                DockerPanel(search: search)
            }
        }
        .safeAreaInset(edge: .bottom) {
            SelectionBar(count: targets.count, noun: "place", status: LowtideFormat.bytes(selectedBytes),
                         clear: { store.checks.set(targets.map(\.id), on: false) }) {
                Button { confirm = request(targets, bytes: selectedBytes) } label: {
                    HStack(spacing: 5) {
                        if store.cleaning { ProgressView().controlSize(.mini) }
                        Text("Clean \(LowtideFormat.bytes(selectedBytes))")
                    }
                }
                .buttonStyle(.lowtide(.primary, size: .small))
                .disabled(store.cleaning)
            }
            .frame(maxWidth: 560).padding(.bottom, Space.lg)
                .animation(Motion.spring, value: targets.isEmpty)
        }
        .confirmation($confirm)
        .task {
            store.start()
            while !Task.isCancelled {
                await store.refreshDisk()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    @ViewBuilder
    private func groups(all: [Reclaimable], visible: [Reclaimable]) -> some View {
        if all.isEmpty, store.scanning {
            ScanningState(title: "Looking through caches and projects").frame(minHeight: 220)
        } else if visible.isEmpty, !all.isEmpty, scope != .docker {
            EmptyState("Nothing matches", symbol: "line.3.horizontal.decrease.circle", message: "Try another filter or search.")
                .frame(minHeight: 200)
        } else {
            ForEach(Self.groups.filter { scope == .all || scope.rawValue == $0.group.rawValue }, id: \.group) { group in
                let items = visible.filter { $0.group == group.group }
                let scanning = group.group == .projects ? store.scanningProjects : store.scanningCaches
                if group.group == .projects {
                    VStack(alignment: .leading, spacing: Space.md) {
                        RootsEditor(store: store, settings: settings)
                        if items.isEmpty {
                            Text(scanning ? "Looking for node_modules, target, .next and other build folders…"
                                 : (settings.roots ?? []).isEmpty ? "Add a folder where your projects live."
                                 : "No build folders in these folders.")
                                .font(.ui(.sm)).foregroundStyle(palette.ink3.color)
                        } else {
                            GroupPane(title: group.title, items: items, scanning: scanning, store: store)
                        }
                    }
                } else if !items.isEmpty {
                    GroupPane(title: group.title, items: items, scanning: scanning, store: store)
                }
            }
        }
    }

    private func request(_ targets: [Reclaimable], bytes: Int64) -> ConfirmRequest {
        let counts = Self.groups.compactMap { group -> String? in
            let n = targets.filter { $0.group == group.group }.count
            return n > 0 ? LowtideFormat.count(n, group.noun) : nil
        }
        let review = targets.contains { $0.safety == .review }
        return ConfirmRequest(
            title: "Clean \(LowtideFormat.count(targets.count, "place"))?",
            message: "\(counts.formatted(.list(type: .and))), \(LowtideFormat.bytes(bytes)). Build folders and Xcode data move to the Trash; Homebrew, npm, pnpm, Go, uv and simulators are cleaned by their own tools. Projects reinstall their dependencies on the next install or build."
                + (review ? " Some are marked Review first: check them." : ""),
            confirm: "Clean \(LowtideFormat.bytes(bytes))", destructive: false) {
                store.clean(targets.map(\.id))
            }
    }

    /// The hero's sentence and detail, from what the scans and cleans did.
    private func heroCopy(selectedBytes: Int64) -> (String, String) {
        let waiting = store.waiting
        let found = waiting.count
        let total = waiting.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
        let freed = store.freed
        if store.cleaning {
            return ("Cleaning… \(LowtideFormat.bytes(freed)) freed so far", "One place at a time. You can keep working.")
        }
        if freed > 0, selectedBytes == 0 {
            return ("\(LowtideFormat.bytes(freed)) freed", "Build folders went to the Trash; caches were cleared by their own tools.")
        }
        if found == 0 {
            return store.scanning || !store.scannedCaches
                ? ("Looking for space you can free", "Checking caches, build folders, Xcode and Docker.")
                : ("Nothing to clean right now", "No caches or build folders worth removing were found.")
        }
        // Sizes arrive after the places do: never headline "0 B" mid-scan.
        if store.safeBytes == 0 {
            return store.scanning
                ? ("Measuring what you can free", "\(LowtideFormat.count(found, "place")) found so far. Sizes come in as each one is measured.")
                : ("Nothing safe to remove on its own", "\(LowtideFormat.count(found, "place")) found; each needs a look before it goes.")
        }
        return ("\(LowtideFormat.bytes(store.safeBytes)) you can safely remove",
                "\(LowtideFormat.bytes(total)) found in \(LowtideFormat.count(found, "place"))\(store.scanning ? ", still measuring" : ""). Everything here comes back when a tool needs it.")
    }
}

extension Clean {
/// The disk, with what the selection would give back on it.
struct DiskBar: View {
    @Environment(\.palette) private var palette
    let disk: (available: Int64, total: Int64)?
    let reclaim: Int64

    var body: some View {
        if let disk, disk.total > 0 {
            let used = disk.total - disk.available
            let back = min(reclaim, used)
            let low = Double(disk.available) / Double(disk.total) < 0.1
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(Text("\(LowtideFormat.bytes(disk.available)) free").foregroundStyle((low ? palette.warn : palette.ink).color))\(Text(" of \(LowtideFormat.bytes(disk.total))").foregroundStyle(palette.ink3.color))")
                        .font(.ui(.sm))
                    Spacer()
                    if back > 0 {
                        Text("\(LowtideFormat.bytes(disk.available + back)) free after cleaning")
                            .font(.ui(.sm)).foregroundStyle(palette.ink2.color)
                            .contentTransition(.numericText())
                    }
                }
                .monospacedDigit()
                GeometryReader { geo in
                    let width = geo.size.width
                    let usedWidth = width * CGFloat(Double(used - back) / Double(disk.total))
                    ZStack(alignment: .leading) {
                        Capsule().fill(palette.fill.color)
                        Rectangle().fill(palette.ink4.color).frame(width: usedWidth)
                        Rectangle().fill(palette.brand.color)
                            .frame(width: width * CGFloat(Double(back) / Double(disk.total)))
                            .offset(x: usedWidth)
                    }
                    .clipShape(Capsule())
                    .animation(Motion.slow, value: back)
                }
                .frame(height: 8)
                .accessibilityElement()
                .accessibilityLabel("Disk usage")
                .accessibilityValue("\(LowtideFormat.bytes(disk.available)) free of \(LowtideFormat.bytes(disk.total))")
            }
        } else {
            Color.clear.frame(height: 34)
        }
    }
}

}

/// One group of places: a select-all line, then its rows.
private struct GroupPane: View {
    @Environment(\.palette) private var palette
    let title: String
    let items: [Reclaimable]
    let scanning: Bool
    @Bindable var store: CleanupStore

    var body: some View {
        let ids = items.filter { $0.bytes != 0 }.map(\.id)
        let on = ids.filter(store.checks.has).count
        Pane(title) {
            HStack(spacing: 6) {
                if scanning { ProgressView().controlSize(.mini) }
                Text(LowtideFormat.bytes(items.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }))
                    .font(.mono(.xs)).foregroundStyle(palette.ink3.color).contentTransition(.numericText())
            }
        } content: {
            VStack(spacing: 0) {
                if !ids.isEmpty {
                    Clean.SelectAll(state: store.checks.state(of: ids),
                                    text: on > 0 ? "\(on) of \(LowtideFormat.count(ids.count, "place")) selected" : "Select all \(LowtideFormat.count(ids.count, "place"))",
                                    onChange: { store.checks.set(ids, on: $0) })
                        .hairline(.top)
                }
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    PlaceRow(item: item, state: store.state(item.id), checked: store.checks.has(item.id)) {
                        store.checks.toggle(item.id, in: ids)
                    }
                    if index < items.count - 1 { Hairline(inset: 42) }
                }
            }
        }
    }
}

private struct PlaceRow: View {
    @Environment(\.palette) private var palette
    let item: Reclaimable
    let state: CleanupStore.ItemState
    let checked: Bool
    let onCheck: () -> Void

    var body: some View {
        let busy = state == .cleaning || { if case .cleaned = state { true } else { false } }()
        Clean.CheckRow(checked: checked, disabled: busy || item.bytes == 0, label: "Select \(item.project ?? item.name)",
                       help: item.action, onCheck: onCheck) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.sm) {
                    Group {
                        if let project = item.project {
                            Text("\(Text(project).foregroundStyle(palette.ink.color))\(Text(" · \(item.name)").foregroundStyle(palette.ink3.color))")
                        } else {
                            Text(item.name).foregroundStyle(palette.ink.color)
                        }
                    }
                    .font(.ui(.sm, .medium)).lineLimit(1)
                    if item.safety == .review { Badge("Review first", tone: .warn) }
                }
                if item.project != nil {
                    Text(Clean.tilde(item.path)).font(.mono(.xxs)).foregroundStyle(palette.ink3.color)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                } else {
                    Text(item.description).font(.ui(.xs)).foregroundStyle(palette.ink3.color).lineLimit(1)
                }
                if case .failed(let error) = state {
                    Text(error).font(.ui(.xs)).foregroundStyle(palette.bad.color).lineLimit(2).textSelection(.enabled)
                }
            }
            .padding(.vertical, 6)
            Spacer(minLength: Space.sm)
            if let last = item.lastActive {
                Text(Clean.relative(last, "Used")).font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                    .frame(width: 128, alignment: .trailing)
            }
            size.frame(width: 112, alignment: .trailing)
        } menu: {
            PathMenu(item.path)
        }
        .opacity({ if case .cleaned = state { 0.6 } else { 1 } }())
    }

    @ViewBuilder private var size: some View {
        switch state {
        case .cleaning:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Cleaning").font(.ui(.xs)).foregroundStyle(palette.ink2.color)
            }
        case .cleaned(let bytes):
            Text("Freed \(Text(LowtideFormat.bytes(bytes)).font(.mono(.xs)))").font(.ui(.xs)).foregroundStyle(palette.ok.color)
        case .failed(let error):
            Text("Failed").font(.ui(.xs)).foregroundStyle(palette.bad.color).help(error)
        case .idle:
            Clean.SizeLabel(bytes: item.bytes, strong: true, measuring: item.bytes == nil)
        }
    }
}

/// The folders searched for build output, as removable chips.
private struct RootsEditor: View {
    @Environment(\.palette) private var palette
    let store: CleanupStore
    let settings: CleanupSettings
    @State private var draft = ""

    var body: some View {
        FlowLayout(spacing: 6) {
            Text("Looking in").font(.ui(.xs)).foregroundStyle(palette.ink3.color).padding(.trailing, 2)
            ForEach(settings.roots ?? [], id: \.self) { root in
                HStack(spacing: 2) {
                    Text(Clean.tilde(root)).font(.mono(.xxs)).foregroundStyle(palette.ink2.color)
                    Button { store.removeRoot(root) } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 16, height: 16).contentShape(.rect)
                    }
                    .buttonStyle(.plain).foregroundStyle(palette.ink4.color)
                    .help("Stop looking in \(Clean.tilde(root))")
                }
                .padding(.leading, 8).padding(.trailing, 2)
                .frame(height: 22)
                .background(palette.fill.color, in: .rect(cornerRadius: Radius.sm))
            }
            HStack(spacing: 4) {
                Button {
                    if let path = CleanupSettings.chooseFolder(prompt: "Look Here") { store.addRoot(path) }
                } label: {
                    Image(systemName: "folder.badge.plus").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(palette.ink3.color)
                .help("Choose a folder to look in")
                TextField("Add a folder path", text: $draft)
                    .textFieldStyle(.plain).font(.mono(.xxs)).frame(width: 180)
                    .onSubmit {
                        store.addRoot((draft as NSString).expandingTildeInPath)
                        draft = ""
                    }
            }
            .padding(.horizontal, 6)
            .frame(height: 22)
            .overlay(RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(palette.line.color, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        }
    }
}
