import LowtideKit
import SwiftUI

/// Developer › Toolchain › Inventory: everything installed, from every
/// package manager. Picking a manager opens its own page (a manager's page
/// belongs to Inventory).
struct InventoryPage: View {
    private var model = ToolchainModel.shared

    var body: some View {
        Group {
            if let manager = model.inventoryManager, model.info(manager) != nil {
                SourcePage(sourceID: manager).id(manager)
            } else {
                AllInventory()
            }
        }
        .onAppear { model.start(); model.refreshIfStale() }
    }
}

/// The manager menu both Inventory views share.
struct ManagerPicker: View {
    private var model = ToolchainModel.shared

    var body: some View {
        let owners = Dictionary(model.items.map { ($0.ownerID, $0.ownerName) }, uniquingKeysWith: { a, _ in a })
            .sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
        Picker("Package manager", selection: Binding(get: { model.inventoryManager ?? "" },
                                                     set: { model.inventoryManager = $0.isEmpty ? nil : $0 })) {
            Text("All package managers").tag("")
            Divider()
            ForEach(owners, id: \.key) { id, name in Text(name).tag(id) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }
}

/// Column widths the header and rows share; they give way to the name
/// when the inspector narrows the list.
enum ToolColumns {
    static let nameMin: CGFloat = 120
    static let versionRange: ClosedRange<CGFloat> = 64...150
    static let latestRange: ClosedRange<CGFloat> = 88...170
    static let ownerRange: ClosedRange<CGFloat> = 80...150
}

/// Uninstall confirmation wording for one package or several.
enum UninstallCopy {
    static func request(_ items: [InventoryItem], run: @escaping () -> Void) -> ConfirmRequest {
        let manager = items.first?.ownerName ?? "its package manager"
        let note = "Anything that depends on \(items.count == 1 ? "it" : "them") may stop working."
        if items.count == 1, let item = items.first {
            return ConfirmRequest(title: "Uninstall \(item.package.name)?",
                                  message: "Remove \(item.package.name) \(item.package.currentVersion) with \(manager). \(note)",
                                  confirm: "Uninstall", action: run)
        }
        let shown = items.prefix(4).map(\.package.name).joined(separator: ", ")
        let more = items.count > 4 ? " and \(items.count - 4) more" : ""
        return ConfirmRequest(title: "Uninstall \(items.count) packages?", message: "Remove \(shown)\(more) with \(manager). \(note)",
                              confirm: "Uninstall \(items.count) Packages", action: run)
    }

    /// Asks first, then queues the removals.
    static func ask(_ items: [InventoryItem], confirm: inout ConfirmRequest?) {
        let removable = items.filter { PackageSources.source($0.sourceID)?.removalRefusal == nil && $0.ownerID != "homebrew-apps" }
        guard !removable.isEmpty else { return }
        confirm = request(removable) {
            ToolUpdateQueue.shared.enqueue(removable.map(ToolUpdateQueue.Target.init), action: .uninstall)
        }
    }
}

// MARK: - Everything

private struct AllInventory: View {
    @Environment(\.palette) private var palette
    private var model = ToolchainModel.shared
    @State private var query = ""
    @State private var filter: InventoryItem.ItemType?
    @State private var selection: InventoryItem.ID?
    @State private var confirm: ConfirmRequest?
    @FocusState private var searchFocused: Bool

    private var owned: [InventoryItem] {
        let all = model.items
        // A manager that's gone (uninstalled since) shows everything.
        guard let manager = model.inventoryManager, all.contains(where: { $0.ownerID == manager }) else { return all }
        return all.filter { $0.ownerID == manager }
    }

    private var visible: [InventoryItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return owned.filter { item in
            (filter == nil || item.itemType == filter)
                && (q.isEmpty || item.package.name.lowercased().contains(q) || item.ownerName.lowercased().contains(q))
        }
    }

    var body: some View {
        let owned = owned
        let visible = visible
        let managers = Set(model.items.map(\.ownerID)).count
        VStack(spacing: 0) {
            PageHeader("Inventory", description: model.isLoading ? nil
                : LowtideFormat.count(owned.count, "item") + (model.inventoryManager == nil ? " from \(LowtideFormat.count(managers, "manager"))" : "")) {
                EmptyView()
            } action: {
                if model.isScanning { ProgressView().controlSize(.small) }
                IconButton("arrow.clockwise", help: "Refresh the inventory") { model.refresh() }.disabled(model.isScanning)
            }
            PageToolbar {
                ManagerPicker()
                Segmented($filter, [(nil, "All"), (.app, "Apps"), (.cli, "CLIs"), (.package, "Packages")],
                          counts: [nil: owned.count, .app: owned.filter { $0.itemType == .app }.count,
                                   .cli: owned.filter { $0.itemType == .cli }.count,
                                   .package: owned.filter { $0.itemType == .package }.count])
                    .fixedSize()
            } trailing: {
                FilterField(text: $query, prompt: "Search installed tools")
                    .focused($searchFocused)
                    // ⌘F focuses the search.
                    .background { Button("") { searchFocused = true }.keyboardShortcut("f").opacity(0).accessibilityHidden(true) }
            }
            .padding(.horizontal, Space.page + 4)
            .padding(.bottom, Space.md)
            content(visible)
        }
        .inspector(isPresented: Binding(get: { selectedItem != nil }, set: { if !$0 { selection = nil } })) {
            if let item = selectedItem {
                PackageDetailsPanel(item: item, onUpdate: {
                    ToolUpdateQueue.shared.enqueue([ToolUpdateQueue.Target(item)])
                }, onUninstall: { UninstallCopy.ask([item], confirm: &confirm) }, onClose: { selection = nil })
                .inspectorColumnWidth(min: 320, ideal: 370, max: 520)
            }
        }
        .confirmation($confirm)
    }

    private var selectedItem: InventoryItem? { selection.flatMap { id in model.items.first { $0.id == id } } }

    @ViewBuilder
    private func content(_ visible: [InventoryItem]) -> some View {
        if model.isLoading && owned.isEmpty {
            ScanningState(title: "Reading every package manager", detail: model.sources.map(\.name).joined(separator: " · "))
        } else if visible.isEmpty {
            EmptyState(query.isEmpty ? "Nothing installed yet" : "No matches", symbol: query.isEmpty ? "shippingbox" : "magnifyingglass",
                       message: query.isEmpty ? "No package manager reported anything installed."
                           : "Nothing installed matches “\(query.trimmingCharacters(in: .whitespaces))”.")
        } else {
            VStack(spacing: 0) {
                HStack(spacing: Space.md) {
                    Text("Name").frame(minWidth: ToolColumns.nameMin, maxWidth: .infinity, alignment: .leading)
                    Text("Managed by").frame(minWidth: ToolColumns.ownerRange.lowerBound, maxWidth: ToolColumns.ownerRange.upperBound, alignment: .leading)
                    Text("Version").frame(minWidth: ToolColumns.versionRange.lowerBound, maxWidth: ToolColumns.versionRange.upperBound, alignment: .trailing)
                    Color.clear.frame(width: 12)
                }
                .font(.ui(.xs, .medium)).foregroundStyle(palette.ink3.color)
                // The List insets its rows 8 pt more than its own row insets.
                .padding(.horizontal, Space.xl + Space.xs)
                .frame(height: 30)
                Hairline()
                List(visible, selection: $selection) { item in
                    InventoryRow(item: item)
                        .listRowInsets(EdgeInsets(top: 0, leading: Space.sm, bottom: 0, trailing: Space.sm))
                        .listRowSeparator(.hidden)
                        .contextMenu { menu(item) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .alternatingRowBackgrounds(.disabled)
            }
            .clipShape(.rect(cornerRadius: Radius.lg))
            .card()
            .padding(.horizontal, Space.page + 4)
            .padding(.bottom, Space.lg)
        }
    }

    @ViewBuilder
    private func menu(_ item: InventoryItem) -> some View {
        Button("Details") { selection = item.id }
        if item.package.canUpdate, item.ownerID != "homebrew-apps" {
            Button("Update") { ToolUpdateQueue.shared.enqueue([ToolUpdateQueue.Target(item)]) }
        }
        Button("Copy Name") { ToolClipboard.copy(item.package.name, what: "Name") }
        if model.info(item.ownerID) != nil {
            Button("Open \(item.ownerName)") { model.inventoryManager = item.ownerID }
        } else if item.ownerID == "homebrew-apps" {
            Button("Show in Apps") { AppModel.shared.open(.appsInstalled) }
        }
    }
}

private struct InventoryRow: View {
    @Environment(\.palette) private var palette
    let item: InventoryItem

    var body: some View {
        HStack(spacing: Space.md) {
            HStack(spacing: Space.md) {
                SourceTile(mark: item.mark)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.package.name).font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color).lineLimit(1)
                    if let description = item.package.description, !description.isEmpty {
                        Text(description).font(.ui(.xs)).foregroundStyle(palette.ink3.color).lineLimit(1)
                    }
                }
            }
            .frame(minWidth: ToolColumns.nameMin, maxWidth: .infinity, alignment: .leading)
            Text(item.ownerName).font(.ui(.xs)).foregroundStyle(palette.ink2.color).lineLimit(1)
                .frame(minWidth: ToolColumns.ownerRange.lowerBound, maxWidth: ToolColumns.ownerRange.upperBound, alignment: .leading)
            Text(item.package.currentVersion.isEmpty ? "–" : item.package.currentVersion)
                .font(.mono(.xs)).monospacedDigit()
                .foregroundStyle((item.package.needsUpdate ? palette.warn : palette.ink2).color)
                .lineLimit(1).truncationMode(.middle)
                .frame(minWidth: ToolColumns.versionRange.lowerBound, maxWidth: ToolColumns.versionRange.upperBound, alignment: .trailing)
                .help(item.package.needsUpdate ? "\(item.package.latestVersion ?? "An update") is available" : item.package.currentVersion)
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(palette.ink4.color)
                .frame(width: 12)
        }
        .padding(.horizontal, Space.sm)
        .frame(minHeight: 44)
        .contentShape(.rect)
    }
}

// MARK: - One package manager

/// A package manager's page: its packages, what's behind, update or
/// remove one, several or all.
struct SourcePage: View {
    @Environment(\.palette) private var palette
    private var model = ToolchainModel.shared
    private var queue = ToolUpdateQueue.shared
    let sourceID: String
    @State private var query = ""
    @State private var outdatedOnly = false
    @State private var selection: Set<String> = []
    @State private var detailsClosed = false
    @State private var confirm: ConfirmRequest?
    @FocusState private var searchFocused: Bool

    init(sourceID: String) { self.sourceID = sourceID }

    private var source: PackageSourceInfo? { model.info(sourceID) }
    private var packages: [ToolPackage]? { model.packages(sourceID) }

    private func items(_ packages: [ToolPackage]) -> [InventoryItem] {
        guard let source else { return [] }
        return packages.map { InventoryItem(package: $0, source: source) }
    }

    private var visible: [InventoryItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return items(packages ?? []).filter { item in
            (!outdatedOnly || item.package.outdated) && (q.isEmpty || item.package.name.lowercased().contains(q))
        }
    }

    var body: some View {
        if let source {
            page(source)
        } else {
            EmptyState("Package manager not found", symbol: "shippingbox",
                       message: "Lowtide can't find this package manager on your Mac any more.") {
                Button("Show Everything") { model.inventoryManager = nil }.buttonStyle(.secondary)
            }
        }
    }

    private func page(_ source: PackageSourceInfo) -> some View {
        let all = packages ?? []
        let outdated = all.filter(\.outdated).count
        let updatable = all.filter(\.needsUpdate)
        let busy = queue.isBusy(source: sourceID)
        let scan = model.scans[sourceID]
        let visible = visible
        let chosen = visible.filter { selection.contains($0.id) }
        return VStack(spacing: 0) {
            PageHeader(source.name, description: packages.map { "\(LowtideFormat.count($0.count, "package")) · \(outdated > 0 ? "\(outdated) out of date" : "all up to date")" }
                ?? source.description) {
                EmptyView()
            } action: {
                if scan?.loading == true { ProgressView().controlSize(.small) }
                IconButton("arrow.clockwise", help: "Check \(source.name) again") { model.refresh() }
                    .disabled(scan?.loading == true)
                Button(busy ? "Updating…" : "Update All") {
                    queue.enqueue(updatable.map { ToolUpdateQueue.Target($0, source: source) })
                }
                .buttonStyle(.primary)
                .disabled(updatable.isEmpty || busy)
            }
            PageToolbar {
                ManagerPicker()
                Segmented($outdatedOnly, [(false, "All"), (true, "Outdated")], counts: [false: all.count, true: outdated])
                    .fixedSize()
            } trailing: {
                FilterField(text: $query, prompt: "Filter packages")
                    .focused($searchFocused)
                    // ⌘F focuses the filter.
                    .background { Button("") { searchFocused = true }.keyboardShortcut("f").opacity(0).accessibilityHidden(true) }
            }
            .padding(.horizontal, Space.page + 4)
            .padding(.bottom, Space.md)
            OperationsPane(sourceID: sourceID)
                .padding(.horizontal, Space.page + 4)
                .padding(.bottom, queue.jobs.contains { $0.target.sourceID == sourceID } ? Space.md : 0)
            content(scan: scan, visible: visible)
        }
        .overlay(alignment: .bottom) {
            ToolSelectionBar(count: chosen.count > 1 ? chosen.count : 0, noun: ("package", "packages"), clear: { selection = [] }) {
                let updatable = chosen.filter(\.package.canUpdate)
                if !updatable.isEmpty {
                    Button("Update \(updatable.count)", systemImage: "arrow.up") {
                        queue.enqueue(updatable.map(ToolUpdateQueue.Target.init))
                        selection = []
                    }
                    .buttonStyle(.lowtide(.secondary, size: .small))
                }
                if PackageSources.source(sourceID)?.removalRefusal == nil {
                    Button("Uninstall", systemImage: "trash") { UninstallCopy.ask(chosen, confirm: &confirm) }
                        .buttonStyle(.lowtide(.destructive, size: .small))
                }
            }
            .animation(Motion.spring, value: chosen.count > 1)
        }
        .inspector(isPresented: Binding(get: { detailItem != nil }, set: { if !$0 { detailsClosed = true } })) {
            if let item = detailItem {
                PackageDetailsPanel(item: item, onUpdate: {
                    queue.enqueue([ToolUpdateQueue.Target(item)])
                }, onUninstall: { UninstallCopy.ask([item], confirm: &confirm) }, onClose: { detailsClosed = true })
                .inspectorColumnWidth(min: 320, ideal: 370, max: 520)
            }
        }
        .onChange(of: selection) { detailsClosed = false }
        .confirmation($confirm)
    }

    /// The details follow a single selected package until closed.
    private var detailItem: InventoryItem? {
        guard !detailsClosed, selection.count == 1, let id = selection.first else { return nil }
        return items(packages ?? []).first { $0.id == id }
    }

    @ViewBuilder
    private func content(scan: ToolchainModel.Scan?, visible: [InventoryItem]) -> some View {
        if packages == nil, scan?.error == nil {
            ScanningState(title: "Reading \(source?.name ?? "the package manager")")
        } else if packages == nil, let error = scan?.error {
            EmptyState("Couldn't read this package manager", symbol: "exclamationmark.triangle", message: error) {
                Button("Try Again") { model.rescan(sourceID) }.buttonStyle(.secondary)
            }
        } else if visible.isEmpty {
            EmptyState(query.isEmpty ? (outdatedOnly ? "Everything is up to date" : "Nothing installed") : "No matches",
                       symbol: query.isEmpty ? (outdatedOnly ? "checkmark.seal" : "shippingbox") : "magnifyingglass",
                       message: query.isEmpty ? (outdatedOnly ? "Every package here is on its latest version."
                                                 : "This package manager has nothing installed yet.")
                           : "No package matches “\(query.trimmingCharacters(in: .whitespaces))”.")
        } else {
            VStack(spacing: 0) {
                if let error = scan?.error {
                    HStack(spacing: Space.sm) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(palette.warn.color)
                        Text("Showing the last results. \(error)").font(.ui(.xs)).foregroundStyle(palette.ink2.color).lineLimit(2)
                        Spacer()
                    }
                    .padding(.horizontal, Space.lg).padding(.vertical, Space.sm)
                    .background(palette.warnSoft.color)
                }
                HStack(spacing: Space.md) {
                    Text("Name").frame(minWidth: ToolColumns.nameMin, maxWidth: .infinity, alignment: .leading)
                    Text("Installed").frame(minWidth: ToolColumns.versionRange.lowerBound, maxWidth: ToolColumns.versionRange.upperBound, alignment: .trailing)
                    Color.clear.frame(width: 14, height: 1)
                    Text("Available").frame(minWidth: ToolColumns.latestRange.lowerBound, maxWidth: ToolColumns.latestRange.upperBound, alignment: .leading)
                    Color.clear.frame(width: 56, height: 1)
                }
                .font(.ui(.xs, .medium)).foregroundStyle(palette.ink3.color)
                // The List insets its rows 8 pt more than its own row insets.
                .padding(.horizontal, Space.xl + Space.xs)
                .frame(height: 30)
                Hairline()
                List(visible, selection: $selection) { item in
                    ToolPackageRow(item: item, selectionCount: selection.contains(item.id) ? selection.count : 1,
                                   update: { update(item) }, uninstall: { uninstall(item) })
                        .listRowInsets(EdgeInsets(top: 0, leading: Space.sm, bottom: 0, trailing: Space.sm))
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: String.self) { ids in
                    menu(ids)
                } primaryAction: { ids in
                    selection = ids
                    detailsClosed = false
                }
                .onDeleteCommand { uninstall(nil) }
                .onKeyPress(.return) {
                    detailsClosed = false
                    return .handled
                }
                .onKeyPress(.space) {
                    detailsClosed.toggle()
                    return .handled
                }
            }
            .clipShape(.rect(cornerRadius: Radius.lg))
            .card()
            .padding(.horizontal, Space.page + 4)
            .padding(.bottom, Space.lg)
        }
    }

    /// Acts on the selection when the row is part of it.
    private func targets(_ item: InventoryItem?) -> [InventoryItem] {
        let all = items(packages ?? [])
        if let item, !selection.contains(item.id) { return [item] }
        return all.filter { selection.contains($0.id) }
    }

    private func update(_ item: InventoryItem?) {
        queue.enqueue(targets(item).filter(\.package.canUpdate).map(ToolUpdateQueue.Target.init))
    }

    private func uninstall(_ item: InventoryItem?) {
        UninstallCopy.ask(targets(item), confirm: &confirm)
    }

    @ViewBuilder
    private func menu(_ ids: Set<String>) -> some View {
        let chosen = items(packages ?? []).filter { ids.contains($0.id) }
        let many = chosen.count > 1 ? " \(chosen.count) Packages" : ""
        if chosen.contains(where: \.package.canUpdate) {
            Button("Update\(many)") { queue.enqueue(chosen.filter(\.package.canUpdate).map(ToolUpdateQueue.Target.init)) }
        }
        if chosen.count == 1, let item = chosen.first {
            Button("Details") {
                selection = [item.id]
                detailsClosed = false
            }
            Button("Copy Name") { ToolClipboard.copy(item.package.name, what: "Name") }
        }
        if PackageSources.source(sourceID)?.removalRefusal == nil, !chosen.isEmpty {
            Divider()
            Button("Uninstall\(many)…", role: .destructive) { UninstallCopy.ask(chosen, confirm: &confirm) }
        }
    }
}

/// Name, installed, arrow, latest (or what's happening to it), and the
/// row's actions on hover.
struct ToolPackageRow: View {
    @Environment(\.palette) private var palette
    private var queue = ToolUpdateQueue.shared
    let item: InventoryItem
    /// How many packages the actions act on: the selection when this row is in it.
    let selectionCount: Int
    let update: () -> Void
    let uninstall: () -> Void
    @State private var hovering = false

    init(item: InventoryItem, selectionCount: Int, update: @escaping () -> Void, uninstall: @escaping () -> Void) {
        self.item = item
        self.selectionCount = selectionCount
        self.update = update
        self.uninstall = uninstall
    }

    var body: some View {
        let package = item.package
        let job = queue.job(item.sourceID, package.id)
        let busy = job?.status.active ?? false
        HStack(spacing: Space.md) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(package.name).font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color).lineLimit(1)
                    if package.pinned {
                        Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(palette.ink3.color)
                            .help("Pinned: Homebrew won't upgrade it").accessibilityLabel("Pinned")
                    }
                }
                if let description = package.description, !description.isEmpty {
                    Text(description).font(.ui(.xs)).foregroundStyle(palette.ink3.color).lineLimit(1)
                }
            }
            .frame(minWidth: ToolColumns.nameMin, maxWidth: .infinity, alignment: .leading)
            Text(package.currentVersion.isEmpty ? "—" : package.currentVersion)
                .font(.mono(.xs)).monospacedDigit().foregroundStyle(palette.ink2.color)
                .lineLimit(1).truncationMode(.middle).help(package.currentVersion.isEmpty ? "Unknown version" : package.currentVersion)
                .frame(minWidth: ToolColumns.versionRange.lowerBound, maxWidth: ToolColumns.versionRange.upperBound, alignment: .trailing)
            Image(systemName: "arrow.right").font(.system(size: 10, weight: .medium))
                .foregroundStyle(palette.warn.color).opacity(package.outdated ? 1 : 0).frame(width: 14)
            latest(job).frame(minWidth: ToolColumns.latestRange.lowerBound, maxWidth: ToolColumns.latestRange.upperBound, alignment: .leading)
            HStack(spacing: 2) {
                if package.canUpdate {
                    IconButton("arrow.up", help: package.latestVersion.map { "Update to \($0)" } ?? "Update", action: update)
                        .disabled(busy)
                }
                if PackageSources.source(item.sourceID)?.removalRefusal == nil {
                    IconButton("trash", help: selectionCount > 1 ? "Uninstall \(selectionCount) packages" : "Uninstall", action: uninstall)
                        .disabled(busy)
                }
            }
            .opacity(hovering ? 1 : 0)
            .frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, Space.sm)
        .frame(minHeight: 44)
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private func latest(_ job: ToolUpdateQueue.Job?) -> some View {
        let package = item.package
        if let job, job.status != .skipped {
            JobStateLabel(job: job)
        } else if package.outdated, let latest = package.latestVersion {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Text(latest).font(.mono(.xs)).monospacedDigit().foregroundStyle(palette.warn.color)
                    .lineLimit(1).truncationMode(.middle).help(latest)
                if let bump = package.bump, bump != .other {
                    Text(bump.rawValue.capitalized).font(.ui(.xs))
                        .foregroundStyle((bump == .major ? palette.warn : palette.ink3).color)
                }
            }
        } else if !package.checked {
            Text("Unknown").font(.ui(.xs)).foregroundStyle(palette.ink4.color)
                .help("The registry couldn't be reached; the latest version is unknown")
        } else {
            Text("Up to date").font(.ui(.xs)).foregroundStyle(palette.ink4.color)
        }
    }
}
