import LowtideKit
import SwiftUI

/// Downloads read as a list of decisions: installers for apps already
/// installed, archives already unpacked, copies of copies, here, on the
/// Desktop and in Documents.
struct DownloadsView<Tabs: View>: View {
    enum Show: Hashable { case all, suggested, old, large }
    enum Sort: Hashable { case newest, oldest, largest, name }

    @Environment(\.palette) private var palette
    var store = DownloadsStore.shared
    let tabs: Tabs
    @State private var show: Show = .all
    @State private var sort: Sort = .newest
    @State private var kind: Download.Kind?
    @State private var search = ""
    @State private var confirm: ConfirmRequest?

    private static var large: Int64 { 100_000_000 }

    private func matches(_ item: Download, _ show: Show) -> Bool {
        switch show {
        case .all: true
        case .suggested: !item.hints.isEmpty
        case .old: item.isOld()
        case .large: (item.bytes ?? 0) >= Self.large
        }
    }

    private var visible: [Download] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return store.items
            .filter { matches($0, show) && (kind == nil || $0.kind == kind) }
            .filter { needle.isEmpty || "\($0.name) \($0.source ?? "")".lowercased().contains(needle) }
            .sorted { a, b in
                switch sort {
                case .newest: (a.added ?? .distantPast) > (b.added ?? .distantPast)
                case .oldest: (a.added ?? .distantPast) < (b.added ?? .distantPast)
                case .largest: (a.bytes ?? 0) > (b.bytes ?? 0)
                case .name: a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            }
    }

    var body: some View {
        let items = store.items
        let visible = self.visible
        let order = visible.map(\.path)
        let suggested = items.filter { !$0.hints.isEmpty }
        let chosen = visible.filter { store.checks.has($0.path) }
        let (title, detail) = copy(items: items, suggested: suggested)
        PageScaffold {
            PageHero(title, detail: detail, art: "cleanup") {
                if !suggested.isEmpty {
                    Button("Select \(LowtideFormat.count(suggested.count, "item")) to clear") {
                        show = .suggested
                        kind = nil
                        store.checks.only(suggested.map(\.path))
                    }
                    .buttonStyle(.lowtide(.primary, size: .large))
                }
                Button { store.refresh() } label: { Label("Scan again", systemImage: "arrow.clockwise") }
                    .buttonStyle(.lowtide(.quiet, size: .large))
                    .disabled(store.loading)
            }
        } content: {
            PageToolbar {
                tabs
            } trailing: {
                if !items.isEmpty { FilterField(text: $search, prompt: "Search downloads") }
            }
            if store.loading, !store.loaded {
                ScanningState(title: "Reading Downloads and where each file came from").frame(minHeight: 240)
            } else if let error = store.error {
                ErrorState(message: error) { store.refresh() }.frame(minHeight: 240)
            } else if !items.isEmpty {
                KindBar(items: items, kind: $kind)
                if kind == .installer {
                    Text("Disk images and packages in Downloads and its folders, on the Desktop and in Documents. Once the app is installed, its installer only takes space.")
                        .font(.ui(.sm)).foregroundStyle(palette.ink3.color)
                }
                HStack(spacing: Space.sm) {
                    Segmented($show, [(.all, "All"), (.suggested, "Safe to clear"), (.old, "Older than 3 months"), (.large, "Over 100 MB")],
                              counts: [.all: items.count, .suggested: suggested.count,
                                       .old: items.filter { matches($0, .old) }.count, .large: items.filter { matches($0, .large) }.count])
                    Segmented($sort, [(.newest, "Newest"), (.oldest, "Oldest"), (.largest, "Largest"), (.name, "Name")])
                    Spacer(minLength: 0)
                }
                VStack(spacing: 0) {
                    Clean.SelectAll(state: store.checks.state(of: order),
                                    text: "\(visible.count) shown · \(LowtideFormat.bytes(visible.map(\.bytes).reduce(Int64(0)) { $0 + ($1 ?? 0) }))",
                                    onChange: { store.checks.set(order, on: $0) }) {
                        if store.measuring { ProgressView().controlSize(.mini) }
                    }
                    if visible.isEmpty {
                        EmptyState("Nothing matches", symbol: "line.3.horizontal.decrease.circle", message: "Try another filter, kind or search.")
                            .frame(height: 200)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(visible) { item in
                                row(item, order: order)
                                Hairline(inset: 42)
                            }
                        }
                    }
                }
                .card()
            }
        }
        .safeAreaInset(edge: .bottom) {
            SelectionBar(count: chosen.count, noun: "item", status: LowtideFormat.bytes(chosen.map(\.bytes).reduce(Int64(0)) { $0 + ($1 ?? 0) }),
                         clear: { store.checks.clear() }) {
                Button("Move to Trash") { confirm = trash(chosen) }.buttonStyle(.lowtide(.destructive, size: .small))
            }
            .frame(maxWidth: 560).padding(.bottom, Space.lg)
                .animation(Motion.spring, value: chosen.isEmpty)
        }
        .confirmation($confirm)
        .onDeleteCommand { if !chosen.isEmpty { confirm = trash(chosen) } }
        .task { store.start() }
    }

    private func row(_ item: Download, order: [String]) -> some View {
        let folder = CleanupFS.parent(item.path)
        let elsewhere = Clean.tilde(folder) == "~/Downloads" ? nil : Clean.tilde(folder)
        let line = [elsewhere, item.source, item.added.map { Clean.relative($0, "added") }].compactMap { $0 }.joined(separator: " · ")
        return Clean.CheckRow(checked: store.checks.has(item.path), label: "Select \(item.name)", onCheck: {
            store.checks.toggle(item.path, in: order)
        }) {
            FileIcon(path: item.path, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Space.sm) {
                    Text(item.name).font(.ui(.sm)).foregroundStyle(palette.ink.color).lineLimit(1).truncationMode(.middle)
                    ForEach(item.hints, id: \.self) { Badge($0.label) }
                }
                if !line.isEmpty {
                    Text(line).font(.ui(.xs)).foregroundStyle(palette.ink3.color).lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(.vertical, 5)
            Spacer(minLength: Space.sm)
            Clean.SizeLabel(bytes: item.bytes, strong: (item.bytes ?? 0) >= Self.large, measuring: item.bytes == nil && store.measuring)
                .frame(width: 80, alignment: .trailing)
        } menu: {
            let targets = store.checks.targets(item.path, in: order)
            PathMenu(item.path, count: targets.count, onTrash: {
                confirm = trash(store.items.filter { targets.contains($0.path) })
            }) {
                if item.isDir {
                    Button("Open in Space Lens") { LensStore.shared.show(item.path) }
                }
            }
        }
    }

    private func trash(_ items: [Download]) -> ConfirmRequest {
        let list = items.map { Clean.Removal.Item(path: $0.path, name: $0.name, bytes: $0.bytes) }
        return Clean.Removal.request(list) {
            Clean.Removal.run(list, mover: { await FolderScan.trash($0) }, done: { store.forget($0) }, restored: { store.refresh() })
        }
    }

    private func copy(items: [Download], suggested: [Download]) -> (String, String) {
        if store.loading, !store.loaded {
            return ("Reading Downloads…", "Installers you already used, archives you already unpacked and copies of copies, here, on the Desktop and in Documents.")
        }
        if store.error != nil { return ("Downloads couldn't be read", "macOS keeps Downloads private until Lowtide is allowed in.") }
        if items.isEmpty { return ("Downloads is clear", "Nothing in Downloads, and no installers on the Desktop or in Documents.") }
        let total = items.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
        let old = items.filter { $0.isOld() }.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
        let title = suggested.isEmpty ? "\(LowtideFormat.bytes(total)) in Downloads"
            : "\(LowtideFormat.bytes(suggested.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) })) of downloads you can clear"
        let untouched = old > 0 ? " \(LowtideFormat.bytes(old)) hasn't been touched in three months." : ""
        return (title, "\(LowtideFormat.count(items.count, "item")), \(LowtideFormat.bytes(total)) in all.\(untouched)")
    }
}

/// Where the folder's space goes, by kind; a segment filters the list.
private struct KindBar: View {
    @Environment(\.palette) private var palette
    let items: [Download]
    @Binding var kind: Download.Kind?

    /// One brand ramp for the kinds that matter most, neutrals for the
    /// rest: the bar reads as one object, not a legend of state colours.
    private func tone(_ kind: Download.Kind) -> ColorValue {
        switch kind {
        case .installer: palette.brand
        case .archive: palette.brand.opacity(0.7)
        case .video: palette.brand.opacity(0.55)
        case .image: palette.brand.opacity(0.4)
        case .audio: palette.brand.opacity(0.3)
        case .folder: palette.ink3
        case .document: palette.ink4
        case .code, .other: palette.lineStrong
        }
    }

    var body: some View {
        let totals = Dictionary(grouping: items, by: \.kind)
            .map { (kind: $0.key, bytes: $0.value.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }, count: $0.value.count) }
            .sorted { $0.bytes > $1.bytes }
        let sum = max(totals.reduce(Int64(0)) { $0 + $1.bytes }, 1)
        VStack(alignment: .leading, spacing: Space.md) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(totals, id: \.kind) { entry in
                        Button { toggle(entry.kind) } label: {
                            Rectangle().fill(tone(entry.kind).color)
                                .opacity(kind == nil || kind == entry.kind ? 1 : 0.25)
                        }
                        .buttonStyle(.plain)
                        .frame(width: max(4, (geo.size.width - CGFloat(totals.count * 2)) * CGFloat(Double(entry.bytes) / Double(sum))))
                        .help("\(entry.kind.label) · \(LowtideFormat.bytes(entry.bytes)) · \(entry.count)")
                        .accessibilityLabel("\(entry.kind.label): \(LowtideFormat.bytes(entry.bytes))")
                    }
                }
            }
            .frame(height: 12)
            .background(palette.fill.color)
            .clipShape(Capsule())
            .animation(Motion.base, value: kind)
            FlowLayout(spacing: Space.lg) {
                ForEach(totals, id: \.kind) { entry in
                    Button { toggle(entry.kind) } label: {
                        HStack(spacing: 6) {
                            Circle().fill(tone(entry.kind).color).frame(width: 8, height: 8)
                            Text(entry.kind.label).foregroundStyle((kind == entry.kind ? palette.ink : palette.ink3).color)
                            Text(LowtideFormat.bytes(entry.bytes)).foregroundStyle(palette.ink4.color)
                        }
                        .font(.ui(.xs)).monospacedDigit()
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func toggle(_ next: Download.Kind) { kind = kind == next ? nil : next }
}
