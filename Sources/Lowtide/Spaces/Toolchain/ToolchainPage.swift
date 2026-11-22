import LowtideKit
import SwiftUI

/// Developer › Toolchain › Overview: what needs you across every package
/// manager, each manager's share that's behind, and the recent operations.
struct ToolchainPage: View {
    @Environment(\.palette) private var palette
    private var model = ToolchainModel.shared

    struct ManagerRow: Identifiable {
        var id: String
        var name: String
        var icon: String
        var total: Int
        var outdated: Int
        var loading: Bool
        var error: String?
    }

    private var managers: [ManagerRow] {
        model.sources
            // Every GUI app update, the App Store's included, is Apps › Updates'.
            .filter { $0.id != "mas" }
            .map { source in
                let scan = model.scans[source.id]
                let packages = model.packages(source.id) ?? []
                return ManagerRow(id: source.id, name: source.name, icon: source.icon, total: packages.count,
                                  outdated: packages.filter(\.needsUpdate).count,
                                  loading: scan?.loading ?? true, error: scan?.error)
            }
            .filter { $0.loading || $0.total > 0 || $0.error != nil }
            .sorted { $0.outdated > $1.outdated }
    }

    var body: some View {
        let managers = managers
        let total = model.toolUpdateCount
        PageScaffold {
            PageHero(headline(managers, total: total), detail: detail(managers), art: "developer") {
                if total > 0 {
                    Button("Review updates") { AppModel.shared.open(.appsUpdates) }
                        .buttonStyle(.primary)
                }
                Button {
                    model.refresh()
                } label: {
                    Label(model.isScanning ? "Checking…" : "Rescan", systemImage: "arrow.clockwise")
                }
                .buttonStyle(total > 0 ? .quiet : .secondary)
                .disabled(model.isScanning)
                .help("Check every package manager and registry again")
            }
        } content: {
            OperationsPane()
            Pane("Package managers", subtitle: managers.isEmpty ? nil : managers.count.formatted()) {
                VStack(spacing: 0) {
                    if managers.isEmpty {
                        Text(model.isScanning ? "Looking for package managers…" : "No package managers found on this Mac.")
                            .font(.ui(.sm)).foregroundStyle(palette.ink3.color)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Space.lg).padding(.bottom, Space.md)
                    }
                    ForEach(managers) { row in
                        Hairline()
                        ManagerRowView(row: row) {
                            model.inventoryManager = row.id
                            AppModel.shared.open(.inventory)
                        }
                    }
                }
            }
            Pane("Recent activity") {
                Button("Show all") { model.historyOpen = true }
                    .buttonStyle(.lowtide(.quiet, size: .small))
                    .disabled(model.activity.isEmpty)
            } content: {
                RecentToolActivity(entries: model.activity, loaded: model.activityLoaded, status: status)
                    .padding(.horizontal, Space.lg).padding(.bottom, Space.sm)
            }
        }
        .onAppear { model.start(); model.refreshIfStale() }
        .sheet(isPresented: Bindable(model).historyOpen) { PackageHistorySheet() }
    }

    private var status: String {
        if model.isScanning { return "Checking package managers…" }
        return model.lastScan.map { "Checked \(LowtideFormat.ago($0))" } ?? "Not checked yet"
    }

    /// The answer to "what needs me?", in one sentence.
    private func headline(_ managers: [ManagerRow], total: Int) -> String {
        if model.isLoading { return "Checking your toolchain for updates" }
        if total == 0 {
            let failed = managers.filter { $0.error != nil && $0.total == 0 }.map(\.name)
            return failed.isEmpty ? "Your toolchain is up to date" : "\(Self.list(failed)) couldn't be checked"
        }
        return "\(LowtideFormat.count(total, "update")) waiting in \(Self.list(managers.filter { $0.outdated > 0 }.map(\.name)))"
    }

    private func detail(_ managers: [ManagerRow]) -> String? {
        let installed = managers.reduce(0) { $0 + $1.total }
        guard installed > 0 else { return nil }
        return "\(LowtideFormat.count(installed, "package")) across \(LowtideFormat.count(managers.count, "manager"))"
    }

    static func list(_ names: [String], limit: Int = 2) -> String {
        if names.count <= limit { return names.count < 2 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names.last! }
        return "\(names.prefix(limit).joined(separator: ", ")) and \(LowtideFormat.count(names.count - limit, "other"))"
    }
}

/// A package manager and how much of it is behind.
private struct ManagerRowView: View {
    @Environment(\.palette) private var palette
    let row: ToolchainPage.ManagerRow
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: Space.md) {
                SourceTile(mark: row.icon)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name).font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color)
                    Text(meta).font(.ui(.xs)).foregroundStyle((row.error != nil && row.total == 0 ? palette.bad : palette.ink3).color)
                        .lineLimit(1)
                }
                Spacer(minLength: Space.md)
                if row.outdated > 0 {
                    // The share of this manager that's behind, at a glance.
                    Meter(value: max(0.06, Double(row.outdated) / Double(max(row.total, 1))), tone: .warn)
                        .frame(width: 96)
                        .accessibilityHidden(true)
                    Text(row.outdated.formatted()).font(.ui(.sm, .medium)).foregroundStyle(palette.warn.color)
                        .monospacedDigit().frame(width: 32, alignment: .trailing)
                }
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle((hovering ? palette.ink3 : palette.ink4).color)
            }
            .padding(.horizontal, Space.lg)
            .frame(minHeight: 48)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .toolRowHover()
        .help(row.error ?? "Open \(row.name)")
        .contextMenu { Button("Open \(row.name)", action: open) }
    }

    private var meta: String {
        if row.loading && row.total == 0 { return "Checking…" }
        if let error = row.error, row.total == 0 { return "Couldn't read: \(error)" }
        if row.outdated > 0 { return "\(row.outdated) of \(row.total) out of date" }
        return "\(LowtideFormat.count(row.total, "package")), all up to date"
    }
}

/// Every recorded install, update and removal, searchable, with failures
/// one click away.
struct PackageHistorySheet: View {
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    private var model = ToolchainModel.shared
    @State private var filter = Filter.all
    @State private var query = ""
    @State private var confirm: ConfirmRequest?

    enum Filter: Hashable { case all, failed }

    private var visible: [ActivityEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return model.activity.filter { entry in
            (filter == .all || !entry.succeeded)
                && (q.isEmpty || entry.itemName.lowercased().contains(q) || entry.sourceName.lowercased().contains(q)
                    || entry.action.lowercased().contains(q))
        }
    }

    var body: some View {
        let entries = model.activity
        let failed = entries.filter { !$0.succeeded }.count
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("History").font(.ui(.lg, .semibold)).foregroundStyle(palette.ink.color)
                    if !entries.isEmpty {
                        Text(LowtideFormat.count(entries.count, "operation") + (failed > 0 ? " · \(failed) failed" : ""))
                            .font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                    }
                }
                Spacer()
                if !entries.isEmpty {
                    Button("Clear…", systemImage: "trash") {
                        confirm = ConfirmRequest(
                            title: "Clear package history?",
                            message: "Delete the record of installs, updates and removals on this Mac. The packages themselves stay as they are.",
                            confirm: "Clear History") {
                                Task {
                                    do {
                                        try await model.clearActivity()
                                        Toasts.shared.show("Package history cleared")
                                    } catch { Toasts.shared.failure("Couldn't clear the history", error) }
                                }
                            }
                    }
                    .buttonStyle(.lowtide(.quiet, size: .small))
                }
                Button("Done") { dismiss() }.buttonStyle(.secondary).keyboardShortcut(.cancelAction)
            }
            .padding(Space.xl)
            if !entries.isEmpty {
                PageToolbar {
                    Segmented($filter, [(.all, "All"), (.failed, "Failed")], counts: [.all: entries.count, .failed: failed])
                } trailing: {
                    FilterField(text: $query, prompt: "Search history")
                }
                .padding(.horizontal, Space.xl).padding(.bottom, Space.md)
            }
            Group {
                if !model.activityLoaded {
                    ScanningState(title: "Reading the history")
                } else if entries.isEmpty {
                    EmptyState("No package history yet", symbol: "clock.arrow.circlepath",
                               message: "Installs, updates and removals show up here.")
                } else if visible.isEmpty {
                    EmptyState("No matches", symbol: "magnifyingglass",
                               message: query.isEmpty ? "Nothing has failed." : "Nothing matches “\(query.trimmingCharacters(in: .whitespaces))”.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(visible) { entry in
                                HistoryRow(entry: entry)
                                Hairline()
                            }
                        }
                        .clipShape(.rect(cornerRadius: Radius.lg))
                        .card()
                        .padding(.horizontal, Space.xl).padding(.bottom, Space.xl)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 760, height: 560)
        .background(palette.overlay.color)
        .confirmation($confirm)
        .task { await model.loadActivity() }
    }
}

private struct HistoryRow: View {
    @Environment(\.palette) private var palette
    let entry: ActivityEntry

    var body: some View {
        HStack(spacing: Space.md) {
            Image(systemName: entry.succeeded ? "checkmark.circle" : "xmark.circle")
                .font(.system(size: 14)).foregroundStyle((entry.succeeded ? palette.ok : palette.bad).color)
                .accessibilityLabel(entry.succeeded ? "Done" : "Failed")
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    Text(entry.action.capitalized).font(.ui(.sm)).foregroundStyle(palette.ink2.color)
                    Text(entry.itemName).font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color).lineLimit(1)
                    if let previous = entry.previousVersion {
                        Text(previous + (entry.resultingVersion.map { " → \($0)" } ?? ""))
                            .font(.mono(.xs)).foregroundStyle(palette.ink3.color).lineLimit(1)
                    }
                }
                if let detail = entry.detail {
                    Text(detail).font(.ui(.xs)).foregroundStyle((entry.succeeded ? palette.ink3 : palette.bad).color)
                        .lineLimit(1).help(detail)
                }
            }
            Spacer(minLength: Space.sm)
            Text(entry.sourceName).font(.ui(.xs)).foregroundStyle(palette.ink3.color)
            if let duration = entry.duration {
                Text(LowtideFormat.duration(duration)).font(.ui(.xs)).foregroundStyle(palette.ink4.color).monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }
            Text(LowtideFormat.ago(entry.createdAt)).font(.ui(.xs)).foregroundStyle(palette.ink3.color).monospacedDigit()
                .frame(width: 80, alignment: .trailing)
                .help(entry.createdAt.formatted(date: .abbreviated, time: .standard))
        }
        .padding(.horizontal, Space.lg)
        .frame(minHeight: 48)
        .textSelection(.enabled)
        .contextMenu {
            if let detail = entry.detail { Button("Copy Output") { ToolClipboard.copy(detail, what: "Output") } }
            Button("Copy Name") { ToolClipboard.copy(entry.itemName, what: "Name") }
        }
    }
}
