import LowtideKit
import os
import SwiftUI

/// The folder the Space lens shows, kept across navigation: finished
/// listings are remembered (going back up is instant) and leaving a folder
/// stops its walk.
@Observable
final class LensStore {
    static let shared = LensStore()

    private(set) var path: String = Paths.home.path
    private(set) var entries: [FolderEntry]?
    private(set) var error: String?
    private(set) var measuring = false
    var checks = Checks<String>()
    private var cache: [String: [FolderEntry]] = [:]
    private var recent: [String] = []
    private var stop = OSAllocatedUnfairLock(initialState: false)
    private var task: Task<Void, Never>?

    /// Opens a folder in the lens from anywhere.
    func show(_ path: String) {
        open(path)
        AppModel.shared.show(.spaceLens)
    }

    func start() {
        if entries == nil, task == nil { load() }
    }

    func open(_ next: String) {
        guard next != path || entries == nil else { return }
        path = next
        checks.clear()
        load()
    }

    func rescan() {
        cache[path] = nil
        load()
    }

    func forget(_ removed: [String]) {
        let gone = Set(removed)
        entries?.removeAll { gone.contains($0.path) }
        checks.ids.subtract(gone)
        // Every folder above changed size.
        cache = cache.filter { key, _ in !removed.contains { CleanupFS.isInside($0, key) } }
    }

    private func remember(_ path: String, _ list: [FolderEntry]) {
        cache[path] = list
        recent.removeAll { $0 == path }
        recent.append(path)
        if recent.count > 40 { cache[recent.removeFirst()] = nil }
    }

    private func load() {
        stop.withLock { $0 = true }
        task?.cancel()
        let flag = OSAllocatedUnfairLock(initialState: false)
        stop = flag
        error = nil
        if let cached = cache[path] {
            entries = cached
            measuring = false
            task = nil
            return
        }
        entries = nil
        measuring = true
        let path = self.path
        task = Task { [self] in
            do {
                let listed = try await Task.detached(priority: .userInitiated) { try FolderScan.list(path) }.value
                guard !Task.isCancelled else { return }
                entries = listed
                let stream = AsyncStream<(String, Int64)> { continuation in
                    let walk = Task.detached(priority: .userInitiated) {
                        await FolderScan.measure(listed, stop: { flag.withLock { $0 } }) { continuation.yield(($0, $1)) }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in walk.cancel() }
                }
                // Sizes arrive one folder at a time; the list redraws at
                // most every 120 ms.
                var pending: [String: Int64] = [:]
                var flushed = ContinuousClock.now
                for await (folder, bytes) in stream {
                    pending[folder] = bytes
                    if ContinuousClock.now - flushed > .milliseconds(120) {
                        apply(&pending)
                        flushed = .now
                    }
                }
                apply(&pending)
                if !flag.withLock({ $0 }), let done = entries { remember(path, done) }
            } catch {
                self.error = error.localizedDescription
            }
            if self.path == path { measuring = false }
        }
    }

    private func apply(_ sizes: inout [String: Int64]) {
        guard !sizes.isEmpty, var list = entries else { return }
        for index in list.indices { if let bytes = sizes[list[index].path] { list[index].bytes = bytes } }
        entries = list
        sizes = [:]
    }
}

/// Space lens: one folder as a map of what takes the space, with drill-in,
/// breadcrumbs, Finder, Quick Look and the Trash.
struct SpaceLensPage: View {
    enum Sort: Hashable { case size, modified, name }

    @Environment(\.palette) private var palette
    var store = LensStore.shared
    var settings = CleanupSettings.shared
    @State private var sort: Sort = .size
    @State private var showHidden = false
    @State private var limit = 300
    @State private var touched: String?
    @State private var confirm: ConfirmRequest?

    private var home: String { Paths.home.path }

    var body: some View {
        let all = store.entries ?? []
        let visible = sorted(all.filter { showHidden || !$0.hidden }, by: sort)
        let bySize = sort == .size ? visible : sorted(visible, by: .size)
        let order = visible.map(\.path)
        let chosen = visible.filter { store.checks.has($0.path) }
        let total = all.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
        VStack(spacing: 0) {
            PageHeader(title, description: store.entries.map { "\(LowtideFormat.bytes(total))\(store.measuring ? " so far" : "") in \(LowtideFormat.count($0.count, "item"))" }
                       ?? "Measuring…") {
                VStack(alignment: .leading, spacing: Space.sm) {
                    if store.path != root { breadcrumbs }
                    places
                }
            } action: {
                actions
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    content(all: all, visible: visible, bySize: bySize, order: order)
                }
                .padding(.horizontal, Space.page + 4)
                .padding(.top, Space.xs)
                .padding(.bottom, Space.page * 2)
                .frame(maxWidth: 1180, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
        }
        .safeAreaInset(edge: .bottom) {
            SelectionBar(count: chosen.count, noun: "item", status: LowtideFormat.bytes(chosen.map(\.bytes).reduce(Int64(0)) { $0 + ($1 ?? 0) }),
                         clear: { store.checks.clear() }) {
                Button("Move to Trash") { confirm = trash(chosen) }.buttonStyle(.lowtide(.destructive, size: .small))
            }
            .frame(maxWidth: 560).padding(.bottom, Space.lg)
                .animation(Motion.spring, value: chosen.isEmpty)
        }
        .modifier(Clean.Keys(space: {
            let targets = chosen.isEmpty ? [touched].compactMap { $0 } : chosen.map(\.path)
            Files.quickLook(targets)
        }, delete: { if !chosen.isEmpty { confirm = trash(chosen) } }))
        .confirmation($confirm)
        .onChange(of: store.path) { limit = 300; touched = nil }
        .task { store.start() }
    }

    private var title: String {
        Clean.tilde(store.path) == "~" ? "Space lens" : CleanupFS.name(store.path)
    }

    /// Breadcrumbs start at ~ inside HOME, else at the tracked folder, else
    /// at the disk.
    private var root: String {
        if CleanupFS.isInside(store.path, home) { return home }
        return settings.tracked.filter { CleanupFS.isInside(store.path, $0) }.min { $0.count < $1.count } ?? "/"
    }

    private func label(ofRoot path: String) -> String {
        path == "/" ? "Macintosh HD" : Clean.tilde(path) == "~" ? "Home" : CleanupFS.name(path)
    }

    private var breadcrumbs: some View {
        let base = root
        let rest = store.path.dropFirst(base == "/" ? 0 : base.count).split(separator: "/").map(String.init)
        let crumbs = [(label(ofRoot: base), base)] + rest.indices.map { index in
            (rest[index], (base == "/" ? "" : base) + "/" + rest[...index].joined(separator: "/"))
        }
        return HStack(spacing: 2) {
            ForEach(Array(crumbs.enumerated()), id: \.element.1) { index, crumb in
                if index > 0 { Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(palette.ink4.color) }
                Button(crumb.0) { store.open(crumb.1) }
                    .buttonStyle(.lowtide(.quiet, size: .small))
                    .fontWeight(index == crumbs.count - 1 ? .medium : .regular)
                    .disabled(index == crumbs.count - 1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Folder path")
    }

    /// Home, the disk and the tracked folders, one click away.
    private var places: some View {
        HStack(spacing: 6) {
            ForEach([home] + settings.tracked + ["/"], id: \.self) { place in
                let on = store.path == place
                Button(place == "/" ? "Macintosh HD" : place == home ? "Home" : CleanupFS.name(place)) { store.open(place) }
                    .buttonStyle(.plain)
                    .font(.ui(.xs, on ? .medium : .regular))
                    .foregroundStyle((on ? palette.ink : palette.ink3).color)
                    .padding(.horizontal, 9).frame(height: 22)
                    .background((on ? palette.brandSoft : palette.fill).color, in: .rect(cornerRadius: Radius.sm))
                    .help(place)
            }
        }
    }

    private var actions: some View {
        let tracked = settings.tracked.contains(store.path)
        return HStack(spacing: 6) {
            if store.path != home, store.path != "/" {
                Button {
                    tracked ? settings.untrack(store.path) : settings.track(store.path)
                } label: {
                    Label(tracked ? "Untrack" : "Track", systemImage: tracked ? "pin.slash" : "pin")
                }
                .buttonStyle(.lowtide(.quiet, size: .small))
                .help(tracked ? "Stop tracking this folder" : "Keep this folder one click away, here and in Duplicates")
            }
            Button("Choose Folder…") {
                if let path = CleanupSettings.chooseFolder(prompt: "Open") { store.open(path) }
            }
            .buttonStyle(.lowtide(.secondary, size: .small))
            IconButton("folder", help: "Show in Finder") { Files.reveal([store.path]) }
            IconButton("arrow.clockwise", help: "Measure again") { store.rescan() }
                .disabled(store.measuring)
        }
    }

    @ViewBuilder
    private func content(all: [FolderEntry], visible: [FolderEntry], bySize: [FolderEntry], order: [String]) -> some View {
        if let error = store.error {
            ErrorState(message: error) { store.rescan() }.frame(minHeight: 320)
        } else if store.entries == nil {
            ScanningState(title: "Reading \(CleanupFS.name(store.path).isEmpty ? "the disk" : CleanupFS.name(store.path))").frame(minHeight: 320)
        } else if all.isEmpty {
            EmptyState("Empty folder", symbol: "folder", message: "Nothing in here.").frame(minHeight: 320)
        } else {
            map(bySize)
            legend.padding(.top, 10)
            HStack(spacing: Space.sm) {
                Segmented($sort, [(.size, "Largest"), (.modified, "Recently changed"), (.name, "Name")])
                let hidden = all.filter(\.hidden).count
                if hidden > 0 {
                    Button("\(showHidden ? "Hide" : "Show") \(hidden) hidden") { showHidden.toggle() }
                        .buttonStyle(.lowtide(showHidden ? .secondary : .quiet, size: .small))
                }
                Spacer()
            }
            .padding(.top, Space.xl).padding(.bottom, Space.md)
            list(visible: visible, max: bySize.first?.bytes ?? 0, order: order)
            if visible.count > limit {
                Button("Show \(min(300, visible.count - limit)) more of \(visible.count - limit)") { limit += 300 }
                    .buttonStyle(.lowtide(.quiet))
                    .frame(maxWidth: .infinity)
                    .padding(.top, Space.md)
            }
        }
    }

    /// Squarified, area ∝ size: the big things in a folder at a glance.
    /// The 60 biggest get a tile; the rest share one.
    private func map(_ bySize: [FolderEntry]) -> some View {
        let sized = bySize.filter { ($0.bytes ?? 0) > 0 }
        let shown = sized.prefix(60)
        let rest = sized.dropFirst(60).reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
        var cells = shown.map { entry in
            FileMap.Cell(id: entry.path, name: entry.name, bytes: entry.bytes, weight: Double(entry.bytes ?? 0), path: entry.path,
                         style: store.checks.has(entry.path) ? .selected : entry.opens ? .folder : .file,
                         detail: entry.opens ? "Click to open" : "Click to select")
        }
        if rest > 0 {
            cells.append(FileMap.Cell(id: "more", name: "\(sized.count - 60) more", bytes: rest, weight: Double(rest), style: .more))
        }
        return FileMap(groups: [FileMap.Group(id: "lens", cells: cells)], height: 260, onTap: { cell in
            guard let entry = bySize.first(where: { $0.path == cell.id }) else { return }
            touched = entry.path
            if entry.opens { store.open(entry.path) } else { store.checks.toggle(entry.path, in: bySize.map(\.path), shift: false) }
        }, onTrash: { cell in
            if let entry = bySize.first(where: { $0.path == cell.id }) { confirm = trash([entry]) }
        })
        .padding(4)
        .card()
        .animation(Motion.base, value: store.entries?.count)
    }

    private var legend: some View {
        HStack(spacing: Space.lg) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(palette.brand.opacity(0.5).color).frame(width: 10, height: 10)
                Text("Folder, click to open")
            }
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(palette.ink4.color).frame(width: 10, height: 10)
                Text("File, click to select")
            }
            Spacer()
            Text("Bigger means more space. Right-click for Finder and Quick Look; Space previews.")
                .foregroundStyle(palette.ink4.color)
        }
        .font(.ui(.xs))
        .foregroundStyle(palette.ink3.color)
    }

    private func list(visible: [FolderEntry], max: Int64, order: [String]) -> some View {
        VStack(spacing: 0) {
            Clean.SelectAll(state: store.checks.state(of: order),
                            text: "\(visible.count) shown · \(LowtideFormat.bytes(visible.map(\.bytes).reduce(Int64(0)) { $0 + ($1 ?? 0) }))",
                            onChange: { store.checks.set(order, on: $0) }) {
                if store.measuring { ProgressView().controlSize(.mini) }
            }
            LazyVStack(spacing: 0) {
                ForEach(visible.prefix(limit)) { entry in
                    row(entry, max: max, order: order)
                    Hairline(inset: 42)
                }
            }
        }
        .card()
    }

    private func row(_ entry: FolderEntry, max: Int64, order: [String]) -> some View {
        Clean.CheckRow(checked: store.checks.has(entry.path), label: "Select \(entry.name)",
                       onCheck: {
                           touched = entry.path
                           store.checks.toggle(entry.path, in: order)
                       },
                       onSelect: entry.opens ? { store.open(entry.path) } : nil) {
            FileIcon(path: entry.path, size: 24)
            HStack(spacing: 6) {
                Text(entry.name).font(.ui(.sm)).foregroundStyle(palette.ink.color).lineLimit(1).truncationMode(.middle)
                if entry.hidden {
                    Image(systemName: "eye.slash").font(.system(size: 10)).foregroundStyle(palette.ink4.color).accessibilityLabel("Hidden")
                }
                if entry.mount { Badge("Another disk") }
            }
            Spacer(minLength: Space.sm)
            Text(entry.modified.map { Clean.relative($0) } ?? "").font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                .frame(width: 128, alignment: .trailing)
            GeometryReader { geo in
                Capsule().fill((entry.opens ? palette.brand.opacity(0.6) : palette.ink4).color)
                    .frame(width: max > 0 ? Swift.max(2, geo.size.width * CGFloat(Double(entry.bytes ?? 0) / Double(max))) : 0, height: 4)
                    .frame(maxHeight: .infinity)
                    .animation(Motion.base, value: entry.bytes)
            }
            .frame(width: 112, height: 12)
            .accessibilityHidden(true)
            Clean.SizeLabel(bytes: entry.bytes, measuring: entry.bytes == nil && store.measuring && !entry.mount)
                .frame(width: 80, alignment: .trailing)
        } menu: {
            let targets = store.checks.targets(entry.path, in: order)
            PathMenu(entry.path, count: targets.count, onTrash: {
                confirm = trash((store.entries ?? []).filter { targets.contains($0.path) })
            }) {
                if entry.opens { Button("Open in Space Lens") { store.open(entry.path) } }
            }
        }
        .onHover { if $0 { touched = entry.path } }
    }

    private func sorted(_ entries: [FolderEntry], by sort: Sort) -> [FolderEntry] {
        entries.sorted { a, b in
            switch sort {
            case .name: a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .modified: (a.modified ?? .distantPast) > (b.modified ?? .distantPast)
            case .size: (a.bytes ?? -1) > (b.bytes ?? -1)
            }
        }
    }

    private func trash(_ entries: [FolderEntry]) -> ConfirmRequest {
        let list = entries.map { Clean.Removal.Item(path: $0.path, name: $0.name, bytes: $0.bytes) }
        return Clean.Removal.request(list) {
            Clean.Removal.run(list, mover: { await FolderScan.trash($0) }, done: { store.forget($0) }, restored: { store.rescan() })
        }
    }
}
