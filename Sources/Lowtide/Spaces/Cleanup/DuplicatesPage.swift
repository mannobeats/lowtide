import LowtideKit
import SwiftUI

/// A duplicate scan, kept outside the page so a long one survives
/// navigation (and shows in the status bar).
@Observable
final class DuplicatesStore {
    static let shared = DuplicatesStore()

    enum MinSize: Int64, CaseIterable, Hashable {
        case k100 = 100_000, m1 = 1_000_000, m10 = 10_000_000, m100 = 100_000_000
        var label: String {
            switch self {
            case .k100: "100 KB"
            case .m1: "1 MB"
            case .m10: "10 MB"
            case .m100: "100 MB"
            }
        }
    }

    var roots: Set<String> = []
    var minSize: MinSize = .m1
    var keep: DuplicateFinder.KeepRule = .oldest
    private(set) var groups: [DuplicateGroup] = []
    private(set) var progress: DuplicateProgress?
    private(set) var scanning = false
    private(set) var finished: Date?
    /// Paths marked for the Trash.
    var selected: Set<String> = []
    private var job: Jobs.Job?

    var wasted: Int64 { groups.reduce(0) { $0 + $1.wasted } }

    func start() {
        if roots.isEmpty { roots = Set(CleanupSettings.shared.tracked) }
    }

    func scan() {
        job?.cancel()
        groups = []
        selected = []
        progress = nil
        finished = nil
        scanning = true
        let roots = Array(self.roots), minBytes = minSize.rawValue
        job = Jobs.shared.start("Finding duplicates", page: .duplicates) { [self] job in
            defer { scanning = false }
            // Groups can arrive by the hundred a second: the page takes
            // them in batches.
            let events = AsyncStream<Event> { continuation in
                let task = Task.detached(priority: .utility) {
                    _ = await DuplicateFinder.scan(roots, minBytes: minBytes, progress: { continuation.yield(.progress($0)) },
                                                   onGroup: { continuation.yield(.group($0)) })
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
            var pending: [DuplicateGroup] = []
            var flushed = ContinuousClock.now
            for await event in events {
                switch event {
                case .progress(let next):
                    progress = next
                    if case .hashing(let done, let total) = next, total > 0 {
                        job.progress = Double(done) / Double(total)
                        job.detail = "Comparing \(LowtideFormat.bytes(done)) of \(LowtideFormat.bytes(total))"
                    } else if case .walking(let files) = next {
                        job.detail = "\(files.formatted()) files listed"
                    }
                case .group(let group):
                    pending.append(group)
                }
                if ContinuousClock.now - flushed > .milliseconds(150), !pending.isEmpty {
                    groups += pending
                    pending = []
                    flushed = .now
                }
            }
            groups += pending
            if !Task.isCancelled { finished = Date() }
        }
    }

    private enum Event: Sendable {
        case progress(DuplicateProgress)
        case group(DuplicateGroup)
    }

    func cancel() {
        job?.cancel()
        scanning = false
    }

    func autoSelect(_ rule: DuplicateFinder.KeepRule) {
        keep = rule
        selected = DuplicateFinder.extras(groups, rule: rule)
    }

    /// The last unselected copy of a group can't be selected: one stays.
    func toggle(_ path: String, in group: DuplicateGroup) {
        if selected.contains(path) {
            selected.remove(path)
        } else if group.files.filter({ !selected.contains($0.path) }).count > 1 {
            selected.insert(path)
        }
    }

    /// Drops trashed files; a group left with one file is no longer a dupe.
    func prune(_ removed: [String]) {
        let gone = Set(removed)
        selected.subtract(gone)
        groups = groups.compactMap { group in
            var group = group
            group.files.removeAll { gone.contains($0.path) }
            return group.files.count > 1 ? group : nil
        }
    }
}

/// Identical files anywhere in the tracked folders: compared by size, then
/// byte for byte, a rule keeps one copy of each and selects the rest.
struct DuplicatesPage: View {
    @Environment(\.palette) private var palette
    @Bindable var store = DuplicatesStore.shared
    var settings = CleanupSettings.shared
    @State private var limit = 60
    @State private var confirm: ConfirmRequest?

    var body: some View {
        let sorted = store.groups.sorted { $0.wasted > $1.wasted }
        let chosen = store.groups.flatMap { group in
            group.files.filter { store.selected.contains($0.path) }.map { Clean.Removal.Item(path: $0.path, name: $0.name, bytes: group.bytes) }
        }
        VStack(spacing: 0) {
            PageHeader("Duplicates", description: store.groups.isEmpty ? "Identical files anywhere in your tracked folders."
                       : "\(LowtideFormat.count(store.groups.count, "group")) of identical files, \(LowtideFormat.bytes(store.wasted)) in extra copies") {
                EmptyView()
            } action: {
                if store.scanning {
                    Button { store.cancel() } label: { Label("Stop", systemImage: "stop.fill") }
                        .buttonStyle(.secondary)
                } else {
                    Button { store.scan() } label: {
                        Label(store.finished == nil ? "Find duplicates" : "Scan again", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.primary)
                    .disabled(store.roots.isEmpty)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    controls
                    if store.scanning { status }
                    results(sorted)
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
            SelectionBar(count: chosen.count, noun: "extra copy", plural: "extra copies", status: LowtideFormat.bytes(chosen.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }),
                         clear: { store.selected = [] }) {
                Button("Move to Trash") { confirm = trash(chosen) }.buttonStyle(.lowtide(.destructive, size: .small))
            }
            .frame(maxWidth: 560).padding(.bottom, Space.lg)
                .animation(Motion.spring, value: chosen.isEmpty)
        }
        .modifier(Clean.Keys(space: nil, delete: { if !chosen.isEmpty { confirm = trash(chosen) } }))
        .confirmation($confirm)
        .task { store.start() }
    }

    private var controls: some View {
        FlowLayout(spacing: 6) {
            Text("Look in").font(.ui(.sm)).foregroundStyle(palette.ink3.color).padding(.trailing, 2).frame(height: 26)
            ForEach(Array(Set(settings.tracked).union(store.roots)).sorted(), id: \.self) { folder in
                let on = store.roots.contains(folder)
                Button(CleanupFS.name(folder)) {
                    if on { store.roots.remove(folder) } else { store.roots.insert(folder) }
                }
                .buttonStyle(.plain)
                .font(.ui(.xs))
                .foregroundStyle((on ? palette.ink : palette.ink3).color)
                .padding(.horizontal, 10).frame(height: 26)
                .background((on ? palette.brandSoft : palette.fill).color, in: .rect(cornerRadius: Radius.md))
                .help(folder)
                .accessibilityAddTraits(on ? .isSelected : [])
                .disabled(store.scanning)
            }
            Button {
                if let path = CleanupSettings.chooseFolder(prompt: "Look Here") {
                    settings.track(path)
                    store.roots.insert(path)
                }
            } label: {
                Label("Add folder", systemImage: "plus").font(.ui(.xs)).padding(.horizontal, 10).frame(height: 26)
                    .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(palette.line.color, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            }
            .buttonStyle(.plain).foregroundStyle(palette.ink3.color)
            .disabled(store.scanning)
            HStack(spacing: 6) {
                Text("Files over").font(.ui(.sm)).foregroundStyle(palette.ink3.color)
                Segmented($store.minSize, DuplicatesStore.MinSize.allCases.map { ($0, $0.label) })
            }
            .frame(height: 26)
        }
    }

    private var status: some View {
        let fraction: Double? = if case .hashing(let done, let total) = store.progress, total > 0 { Double(done) / Double(total) } else { nil }
        let text: String = switch store.progress {
        case .hashing(let done, let total): "Comparing contents, \(LowtideFormat.bytes(done)) of \(LowtideFormat.bytes(total))"
        case .walking(let files): "Listing files, \(files.formatted()) so far"
        case nil: "Listing files"
        }
        return VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                ProgressView().controlSize(.small)
                Text(text).font(.ui(.sm)).foregroundStyle(palette.ink2.color)
                Spacer()
                Text("\(LowtideFormat.count(store.groups.count, "group")) · \(LowtideFormat.bytes(store.wasted)) in copies")
                    .font(.ui(.xs)).foregroundStyle(palette.ink3.color)
            }
            .monospacedDigit()
            if let fraction {
                Meter(value: fraction, height: 6)
            } else {
                ProgressView().progressViewStyle(.linear).tint(palette.brand.color)
            }
        }
    }

    @ViewBuilder
    private func results(_ sorted: [DuplicateGroup]) -> some View {
        if !sorted.isEmpty {
            HStack(spacing: Space.sm) {
                Text("Keep the").font(.ui(.sm)).foregroundStyle(palette.ink3.color)
                Segmented(Binding(get: { store.keep }, set: { store.autoSelect($0) }),
                          DuplicateFinder.KeepRule.allCases.map { ($0, $0.label) })
                Text("copy in each group, select the rest").font(.ui(.sm)).foregroundStyle(palette.ink3.color)
                Spacer()
            }
            LazyVStack(spacing: Space.md) {
                ForEach(sorted.prefix(limit)) { group in
                    GroupCard(group: group, store: store) { file in
                        confirm = trash([Clean.Removal.Item(path: file.path, name: file.name, bytes: group.bytes)])
                    }
                }
            }
            if sorted.count > limit {
                Button("Show \(min(100, sorted.count - limit)) more of \(sorted.count - limit)") { limit += 100 }
                    .buttonStyle(.lowtide(.quiet)).frame(maxWidth: .infinity)
            }
        } else if store.finished != nil {
            EmptyState("No duplicates", symbol: "checkmark.circle", message: "No two files in these folders are identical.")
                .frame(minHeight: 300)
        } else if !store.scanning {
            VStack(spacing: Space.md) {
                HeroArt("cleanup", size: 80)
                Text("Find identical files").font(.ui(.base, .semibold)).foregroundStyle(palette.ink.color)
                Text("Files are compared by size, then byte for byte. Hidden files, app bundles and node_modules are skipped.")
                    .font(.ui(.sm)).foregroundStyle(palette.ink3.color).multilineTextAlignment(.center).frame(maxWidth: 380)
            }
            .frame(maxWidth: .infinity, minHeight: 320)
        }
    }

    private func trash(_ items: [Clean.Removal.Item]) -> ConfirmRequest {
        Clean.Removal.request(items) {
            Clean.Removal.run(items, mover: { await FolderScan.trash($0) }, done: { store.prune($0) }, restored: {
                Toasts.shared.show("Scan again to see them as duplicates", tone: .neutral)
            })
        }
    }
}

private struct GroupCard: View {
    @Environment(\.palette) private var palette
    let group: DuplicateGroup
    let store: DuplicatesStore
    let onTrash: (DuplicateFile) -> Void

    var body: some View {
        let first = group.files[0]
        let marked = group.files.filter { store.selected.contains($0.path) }.count
        VStack(spacing: 0) {
            HStack(spacing: Space.md) {
                FileIcon(path: first.path, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(first.name).font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color).lineLimit(1)
                    Text("\(group.files.count) copies of \(LowtideFormat.bytes(group.bytes)) each")
                        .font(.ui(.xs)).foregroundStyle(palette.ink3.color).monospacedDigit()
                }
                Spacer()
                IconButton("eye", help: "Quick Look") { Files.quickLook([first.path]) }
                Text(LowtideFormat.bytes(group.wasted)).font(.mono(.sm)).foregroundStyle(palette.ink.color)
                    .frame(width: 80, alignment: .trailing)
                    .help("Space the extra copies take")
            }
            .padding(.horizontal, Space.lg)
            .frame(height: 54)
            Hairline()
            ForEach(group.files) { file in
                let on = store.selected.contains(file.path)
                // The last unselected copy can't be selected: one always stays.
                let last = !on && marked == group.files.count - 1
                Clean.CheckRow(checked: on, disabled: last, label: "Remove \(file.path)",
                               help: last ? "One copy always stays" : nil, onCheck: { store.toggle(file.path, in: group) }) {
                    // Copies differ by folder: long paths lose their start, not their end.
                    Text("\(Text(Clean.tilde(CleanupFS.parent(file.path)) + "/").foregroundStyle(palette.ink3.color))\(Text(file.name).foregroundStyle(palette.ink.color))")
                        .font(.mono(.xs)).lineLimit(1).truncationMode(.head)
                        .help(file.path)
                    Spacer(minLength: Space.sm)
                    Text(Clean.relative(file.modified, "Changed")).font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                    Badge(on ? "Remove" : "Keep", tone: on ? .bad : .ok).frame(width: 64, alignment: .trailing)
                } menu: {
                    PathMenu(file.path, onTrash: last ? nil : { onTrash(file) }) {
                        Button(on ? "Keep This Copy" : "Remove This Copy") { store.toggle(file.path, in: group) }.disabled(last)
                    }
                }
                .frame(minHeight: 38)
                if file.id != group.files.last?.id { Hairline(inset: 42) }
            }
        }
        .card()
    }
}
