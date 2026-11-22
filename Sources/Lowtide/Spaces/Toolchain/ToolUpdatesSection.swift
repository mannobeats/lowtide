import LowtideKit
import SwiftUI

/// Command-line tools with updates waiting (Homebrew formulae, npm, pnpm,
/// Cargo, pipx…), shown under Apps › Updates. Owned by the Toolchain space;
/// it stands alone: its own model, every state, the update plan, progress
/// through `Jobs`. Place it in a scrolling page; it doesn't scroll itself.
struct ToolUpdatesSection: View {
    @Environment(\.palette) private var palette
    private var model = ToolchainModel.shared
    private var queue = ToolUpdateQueue.shared
    @State private var planOpen = false

    var body: some View {
        let updates = model.toolUpdates
        VStack(alignment: .leading, spacing: Space.md) {
            header(updates)
            OperationsPane()
            content(updates)
        }
        .onAppear { model.start(); model.refreshIfStale() }
        .sheet(isPresented: $planOpen) {
            UpdatePlanSheet(items: updates) { chosen in queue.enqueue(chosen.map(ToolUpdateQueue.Target.init)) }
        }
    }

    private func header(_ updates: [InventoryItem]) -> some View {
        let managers = Set(updates.map(\.ownerID)).count
        let unchecked = model.uncheckedCount
        let description = updates.isEmpty ? nil : ([
            "\(LowtideFormat.count(updates.count, "update")) across \(LowtideFormat.count(managers, "manager"))",
            unchecked > 0 ? "\(unchecked) couldn't be checked" : nil,
        ].compactMap { $0 }.joined(separator: " · "))
        return HStack(alignment: .center, spacing: Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.sm) {
                    Text("Command-line tools").font(.ui(.lg, .semibold)).foregroundStyle(palette.ink.color)
                    CountCapsule(value: updates.count, warning: true)
                }
                if let description { Text(description).font(.ui(.xs)).foregroundStyle(palette.ink3.color) }
            }
            Spacer(minLength: Space.md)
            if model.isScanning { ProgressView().controlSize(.small) }
            IconButton("arrow.clockwise", help: "Check every registry again") { model.refresh() }
                .disabled(model.isScanning)
            Button {
                planOpen = true
            } label: {
                Text(updates.isEmpty ? "Review updates" : "Review \(LowtideFormat.count(updates.count, "update"))")
            }
            .buttonStyle(.primary)
            .disabled(updates.isEmpty)
        }
    }

    @ViewBuilder
    private func content(_ updates: [InventoryItem]) -> some View {
        let failures = model.sources.compactMap { source in model.scans[source.id]?.error.map { (source, $0) } }
        if model.isLoading && updates.isEmpty {
            ScanningState(title: "Asking every package manager and registry", detail: model.sources.map(\.name).joined(separator: " · "))
                .frame(height: 180)
                .card()
        } else if updates.isEmpty, !failures.isEmpty, failures.count == model.sources.count {
            ErrorState(message: failures.map { "\($0.0.name): \($0.1)" }.joined(separator: "\n")) { model.refresh() }
                .frame(height: 240)
                .card()
        } else if updates.isEmpty {
            EmptyState("Everything is up to date", symbol: "checkmark.seal",
                       message: model.sources.isEmpty ? "No package managers were found on this Mac."
                           : "Every package and command-line tool is on its latest version.")
                .frame(height: 200)
                .card()
        } else {
            let groups = Dictionary(grouping: updates, by: \.ownerName)
            VStack(spacing: Space.lg) {
                ForEach(groups.keys.sorted(), id: \.self) { owner in
                    let items = groups[owner] ?? []
                    Pane(owner, subtitle: items.count.formatted()) {
                        VStack(spacing: 0) {
                            ForEach(items) { item in
                                Hairline()
                                ToolUpdateRow(item: item) { queue.enqueue([ToolUpdateQueue.Target(item)]) }
                            }
                        }
                    }
                }
            }
        }
        // Partial results: say which managers couldn't be read.
        let partial = !updates.isEmpty || failures.count < model.sources.count
        ForEach(partial ? failures : [], id: \.0.id) { source, error in
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(palette.warn.color)
                Text("Couldn't check \(source.name): \(error)").font(.ui(.xs)).foregroundStyle(palette.ink3.color).lineLimit(2)
                    .textSelection(.enabled)
            }
        }
    }
}

/// One waiting update: name, what's happening to it, the step size, the
/// versions, and Update (Retry after a failure) on hover.
struct ToolUpdateRow: View {
    @Environment(\.palette) private var palette
    private var queue = ToolUpdateQueue.shared
    let item: InventoryItem
    let update: () -> Void
    @State private var hovering = false

    init(item: InventoryItem, update: @escaping () -> Void) {
        self.item = item
        self.update = update
    }

    var body: some View {
        let job = queue.job(item.sourceID, item.package.id)
        let busy = job?.status.active ?? false
        let risk = UpdatePlan.risk(item)
        HStack(spacing: Space.md) {
            Text(item.package.name).font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let job { JobStateLabel(job: job) }
            Text(item.package.bump.flatMap { $0 == .other ? nil : $0.rawValue.capitalized } ?? "")
                .font(.ui(.xs)).foregroundStyle((risk == .breaking ? palette.warn : palette.ink3).color)
                .frame(width: 48, alignment: .trailing)
                .help(UpdatePlan.reason(item))
            HStack(spacing: Space.sm) {
                Text(item.package.currentVersion).foregroundStyle(palette.ink3.color).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 84, alignment: .trailing)
                Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(palette.ink4.color)
                Text(item.package.latestVersion ?? "latest").foregroundStyle((risk == .breaking ? palette.warn : palette.ink).color)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 84, alignment: .leading)
            }
            .font(.mono(.xs))
            .monospacedDigit()
            .frame(width: 196, alignment: .trailing)
            Button(job?.status == .failed ? "Retry" : "Update", action: update)
                .buttonStyle(.lowtide(.secondary, size: .small))
                .disabled(busy)
                .opacity(hovering || busy || job?.status == .failed ? 1 : 0)
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, Space.lg)
        .frame(minHeight: 44)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .toolRowHover()
        .contextMenu {
            Button(job?.status == .failed ? "Retry Update" : "Update", action: update).disabled(busy)
            Button("Show in Inventory") {
                ToolchainModel.shared.inventoryManager = item.ownerID == "homebrew-apps" ? "homebrew" : item.sourceID
                AppModel.shared.open(.inventory)
            }
            Divider()
            Button("Copy Name") { ToolClipboard.copy(item.package.name, what: "Name") }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Update", update)
    }
}

/// What an operation is doing to one package, in a word.
struct JobStateLabel: View {
    @Environment(\.palette) private var palette
    let job: ToolUpdateQueue.Job

    var body: some View {
        HStack(spacing: 5) {
            if job.status == .running { ProgressView().controlSize(.mini) }
            Text(text).font(.ui(.xs)).foregroundStyle(job.status.tone.color(palette).color).lineLimit(1)
        }
        .help(job.error ?? "")
    }

    private var text: String {
        switch job.status {
        case .running: job.action == .update ? "Updating…" : "Removing…"
        case .updated: "Updated to \(job.version ?? job.target.latestVersion ?? "latest")"
        default: job.status.label
        }
    }
}
