import LowtideKit
import SwiftUI

/// Docker's disk data as objects to filter, select and delete, through the
/// docker CLI. Docker keeps no trash, so every delete is confirmed.
struct DockerPanel: View {
    @Environment(\.palette) private var palette
    var store = DockerStore.shared
    let search: String

    var body: some View {
        Group {
            switch store.inventory?.state {
            case nil:
                if store.loading {
                    Pane("Docker") {
                        HStack(spacing: Space.sm) {
                            ProgressView().controlSize(.small)
                            Text("Asking Docker what it stores…").font(.ui(.sm)).foregroundStyle(palette.ink3.color)
                        }
                        .padding(.horizontal, Space.lg).padding(.bottom, Space.lg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            case .missing:
                EmptyView()
            case .stopped:
                Pane("Docker") {
                    HStack(spacing: Space.md) {
                        Clean.Tile(symbol: "shippingbox")
                        Text("Docker isn't running, so its images and volumes can't be listed.")
                            .font(.ui(.sm)).foregroundStyle(palette.ink2.color)
                        Spacer()
                        Button { store.startDocker() } label: { Label("Start Docker", systemImage: "play.fill") }
                            .buttonStyle(.lowtide(.secondary, size: .small))
                    }
                    .padding(.horizontal, Space.lg).padding(.bottom, Space.lg)
                }
            case .running:
                if let inventory = store.inventory { DockerManager(inventory: inventory, store: store, search: search) }
            }
        }
        .task { store.start() }
    }
}

private struct DockerManager: View {
    enum Tab: Hashable { case images, containers, volumes, cache }
    enum Filter: Hashable { case all, unused, dangling, used, stopped, running, anonymous }

    /// One row of any Docker table, normalised for selection and sizing.
    struct Row: Identifiable {
        let id: String
        let title: String
        var dimTitle = false
        let subtitle: String
        let status: String
        var statusTone: Tone = .neutral
        let bytes: Int64
        /// Why it can't be deleted, or nil.
        let blocked: String?
        let search: String
    }

    @Environment(\.palette) private var palette
    let inventory: DockerInventory
    @Bindable var store: DockerStore
    let search: String
    @State private var tab: Tab = .images
    @State private var filter: Filter = .unused
    @State private var localSearch = ""
    @State private var confirm: ConfirmRequest?

    var body: some View {
        let rows = self.rows
        let removable = rows.filter { $0.blocked == nil }.map(\.id)
        let chosen = rows.filter { store.checks.has($0.id) }
        Pane("Docker") {
            HStack(spacing: Space.sm) {
                Text("\(LowtideFormat.bytes(inventory.unusedImageBytes)) in unused images · version \(Text(inventory.version ?? "?").font(.mono(.xxs)))")
                    .font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                if store.loading { ProgressView().controlSize(.mini) }
                IconButton("arrow.clockwise", help: "Refresh Docker") { store.refresh() }
            }
        } content: {
            VStack(spacing: 0) {
                HStack {
                    Segmented($tab, [(.images, "Images"), (.containers, "Containers"), (.volumes, "Volumes"), (.cache, "Build cache")],
                              counts: [.images: inventory.images.count, .containers: inventory.containers.count, .volumes: inventory.volumes.count])
                    Spacer()
                }
                .padding(.horizontal, Space.lg).padding(.vertical, Space.sm)
                .hairline(.top)
                Hairline()
                if tab == .cache {
                    BuildCache(inventory: inventory, store: store)
                } else {
                    HStack(spacing: Space.sm) {
                        Segmented($filter, filters.map { ($0, label($0)) })
                        Spacer()
                        FilterField(text: $localSearch, prompt: "Filter by name or id")
                    }
                    .padding(.horizontal, Space.lg).padding(.vertical, Space.sm)
                    Hairline()
                    Clean.SelectAll(state: store.checks.state(of: removable),
                                    text: "\(rows.count) shown, \(removable.count) can be deleted",
                                    onChange: { store.checks.set(removable, on: $0) }) {
                        Text("Size").font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                    }
                    if rows.isEmpty {
                        EmptyState("Nothing matches", symbol: "line.3.horizontal.decrease.circle", message: "Try another filter or search.")
                            .frame(height: 160)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(rows) { row in
                                    rowView(row, order: removable)
                                    Hairline(inset: 42)
                                }
                            }
                        }
                        .frame(maxHeight: 384)
                    }
                    if !chosen.isEmpty {
                        let bytes = chosen.reduce(Int64(0)) { $0 + $1.bytes }
                        HStack(spacing: Space.md) {
                            Text("\(LowtideFormat.count(chosen.count, kind.rawValue)) selected · \(LowtideFormat.bytes(bytes))")
                                .font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color)
                            Spacer()
                            Button("Clear") { store.checks.clear() }.buttonStyle(.lowtide(.quiet, size: .small))
                            Button("Delete \(LowtideFormat.count(chosen.count, kind.rawValue))") {
                                confirm = request(chosen.map(\.id), bytes: bytes)
                            }
                            .buttonStyle(.lowtide(.destructive, size: .small))
                        }
                        .padding(.horizontal, Space.lg)
                        .frame(height: 44)
                        .hairline(.top)
                    }
                }
            }
        }
        .confirmation($confirm)
        .onChange(of: tab) {
            filter = tab == .containers ? .stopped : .unused
            store.checks.clear()
        }
        .onChange(of: filter) { store.checks.clear() }
    }

    private var kind: Docker.Kind {
        switch tab {
        case .containers: .container
        case .volumes: .volume
        default: .image
        }
    }

    private var filters: [Filter] {
        switch tab {
        case .images: [.all, .unused, .dangling, .used]
        case .containers: [.all, .stopped, .running]
        case .volumes: [.all, .unused, .anonymous, .used]
        case .cache: []
        }
    }

    private func label(_ filter: Filter) -> String {
        switch filter {
        case .all: "All"
        case .unused: "No containers"
        case .dangling: "Dangling"
        case .used: "In use"
        case .stopped: "Stopped"
        case .running: "Running"
        case .anonymous: "Anonymous"
        }
    }

    private func short(_ id: String) -> String { String(id.replacingOccurrences(of: "sha256:", with: "").prefix(12)) }

    private var rows: [Row] {
        var list: [Row] = []
        switch tab {
        case .images:
            list = inventory.images.filter { image in
                switch filter {
                case .unused: image.containers == 0
                case .dangling: image.dangling
                case .used: image.containers > 0
                default: true
                }
            }.map { image in
                Row(id: image.reference, title: image.dangling ? "Untagged" : "\(image.repository):\(image.tag)", dimTitle: image.dangling,
                    subtitle: "\(short(image.imageID)) · \(image.created)",
                    status: image.containers > 0 ? LowtideFormat.count(image.containers, "container") : "Unused",
                    bytes: image.uniqueBytes ?? image.bytes,
                    blocked: image.containers > 0 ? "In use by \(LowtideFormat.count(image.containers, "container"))" : nil,
                    search: "\(image.repository):\(image.tag) \(image.imageID)".lowercased())
            }
        case .containers:
            list = inventory.containers.filter { container in
                switch filter {
                case .running: container.running
                case .stopped: !container.running
                default: true
                }
            }.map { container in
                Row(id: container.id, title: container.name, subtitle: "\(container.image) · \(container.created)",
                    status: container.status, statusTone: container.running ? .ok : .neutral, bytes: container.bytes,
                    blocked: container.running ? "Running. Stop it to delete it" : nil,
                    search: "\(container.name) \(container.image) \(container.id)".lowercased())
            }
        case .volumes:
            list = inventory.volumes.filter { volume in
                let used = (volume.links ?? 0) > 0
                switch filter {
                case .unused: return !used
                case .used: return used
                case .anonymous: return volume.anonymous
                default: return true
                }
            }.map { volume in
                let links = volume.links ?? 0
                return Row(id: volume.name, title: volume.anonymous ? String(volume.name.prefix(12)) : volume.name, dimTitle: volume.anonymous,
                           subtitle: (volume.anonymous ? "Anonymous · " : "") + volume.driver,
                           status: links > 0 ? LowtideFormat.count(links, "container") : "Unused", bytes: volume.bytes ?? 0,
                           blocked: links > 0 ? "Mounted by \(LowtideFormat.count(links, "container"))" : nil,
                           search: volume.name.lowercased())
            }
        case .cache:
            return []
        }
        let words = "\(search) \(localSearch)".lowercased().split(separator: " ")
        return list.filter { row in words.allSatisfy { row.search.contains($0) } }.sorted { $0.bytes > $1.bytes }
    }

    private func rowView(_ row: Row, order: [String]) -> some View {
        Clean.CheckRow(checked: store.checks.has(row.id), disabled: row.blocked != nil, label: "Select \(row.id)", help: row.blocked,
                       onCheck: { store.checks.toggle(row.id, in: order) }) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).font(row.dimTitle ? .ui(.xs) : .mono(.xs))
                    .foregroundStyle((row.dimTitle ? palette.ink3 : palette.ink).color).lineLimit(1)
                Text(row.subtitle).font(.mono(.xxs)).foregroundStyle(palette.ink3.color).lineLimit(1)
            }
            Spacer(minLength: Space.sm)
            Text(row.status).font(.ui(.xs)).foregroundStyle((row.statusTone == .ok ? palette.ok : row.blocked == nil ? palette.ink2 : palette.ink3).color)
                .lineLimit(1).frame(width: 140, alignment: .trailing)
            Clean.SizeLabel(bytes: row.bytes).frame(width: 80, alignment: .trailing)
        } menu: {
            if let blocked = row.blocked {
                Text(blocked)
            } else {
                Button(store.checks.has(row.id) ? "Deselect" : "Select") { store.checks.toggle(row.id, in: order, shift: false) }
                Button("Delete…", role: .destructive) { confirm = request(store.checks.targets(row.id, in: order), bytes: row.bytes) }
            }
            Divider()
            Button("Copy ID") { Files.copy(row.id) }
        }
        .opacity(row.blocked == nil ? 1 : 0.55)
    }

    private func request(_ ids: [String], bytes: Int64) -> ConfirmRequest {
        let kind = self.kind
        return ConfirmRequest(
            title: "Delete \(LowtideFormat.count(ids.count, "Docker \(kind.rawValue)"))?",
            message: "Permanently delete \(LowtideFormat.count(ids.count, "Docker \(kind.rawValue)")) (\(LowtideFormat.bytes(bytes))). Docker has no trash for these. "
                + (kind == .volume ? "Volumes hold data such as databases. Deleted volumes cannot be recovered." : "Images can be pulled or built again."),
            confirm: "Delete \(LowtideFormat.count(ids.count, kind.rawValue))") {
                store.remove(kind, ids, bytes: bytes)
            }
    }
}

private struct BuildCache: View {
    @Environment(\.palette) private var palette
    let inventory: DockerInventory
    let store: DockerStore
    @State private var confirm: ConfirmRequest?

    var body: some View {
        HStack(spacing: Space.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Text("\(LowtideFormat.bytes(inventory.buildCacheBytes)) of build layers").foregroundStyle(palette.ink.color))\(Text(", \(LowtideFormat.bytes(inventory.buildCacheReclaimable)) not used by any build in progress").foregroundStyle(palette.ink3.color))")
                    .font(.ui(.sm)).monospacedDigit()
                Text("The next build of each image runs slower once, then caches again.")
                    .font(.ui(.xs)).foregroundStyle(palette.ink3.color)
            }
            Spacer()
            Button {
                store.prune(all: false)
            } label: {
                HStack(spacing: 5) {
                    if store.pruning == false { ProgressView().controlSize(.mini) }
                    Text("Clear unused")
                }
            }
            .buttonStyle(.lowtide(.secondary, size: .small))
            .disabled(store.pruning != nil || inventory.buildCacheReclaimable == 0)
            Button {
                confirm = ConfirmRequest(
                    title: "Clear the whole build cache?",
                    message: "Delete all \(LowtideFormat.bytes(inventory.buildCacheBytes)) of Docker build layers, including ones a build may still use. The next build of each image starts from scratch. Docker has no trash for these.",
                    confirm: "Delete build cache") { store.prune(all: true) }
            } label: {
                HStack(spacing: 5) {
                    if store.pruning == true { ProgressView().controlSize(.mini) }
                    Text("Clear all")
                }
            }
            .buttonStyle(.lowtide(.destructive, size: .small))
            .disabled(store.pruning != nil || inventory.buildCacheBytes == 0)
        }
        .padding(Space.lg)
        .confirmation($confirm)
    }
}
