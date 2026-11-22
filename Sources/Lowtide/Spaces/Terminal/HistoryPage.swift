import LowtideKit
import SwiftUI

/// Developer › History: receipts of the commands run in Lowtide's
/// terminals (Commands), and the record of package installs, updates and
/// cleanups (Packages).
struct HistoryPage: View {
    enum Tab: String, Hashable { case commands, packages }
    @AppStorage("history.tab") private var tab = Tab.commands

    var body: some View {
        Group {
            switch tab {
            case .commands: CommandHistory(tabs: tabs)
            case .packages: PackageHistory(tabs: tabs)
            }
        }
        // A receipt opens its run on Commands.
        .onAppear { if RunsStore.shared.focus != nil { tab = .commands } }
    }

    private var tabs: AnyView {
        AnyView(Segmented($tab, [(.commands, "Commands"), (.packages, "Packages")]))
    }
}

private struct CommandHistory: View {
    private var store = RunsStore.shared
    @State private var confirm: ConfirmRequest?
    let tabs: AnyView

    init(tabs: AnyView) { self.tabs = tabs }

    var body: some View {
        let list = store.runs
        let flagged = list.filter { $0.verdict != .info }.count
        VStack(spacing: 0) {
            PageHeader("History",
                       description: list.isEmpty ? nil
                        : LowtideFormat.count(list.count, "command") + (flagged > 0 ? " · \(flagged) worth a look" : "")) {
                tabs
            } action: {
                if !list.isEmpty {
                    Button("Clear…") {
                        confirm = ConfirmRequest(title: "Clear all runs?",
                                                 message: "Delete \(LowtideFormat.count(list.count, "run")) and their receipts from this Mac.",
                                                 confirm: "Delete Runs") { Task { await store.clear() } }
                    }
                    .buttonStyle(.lowtide(.quiet, size: .small))
                }
            }
            RunsBrowser(runs: list, active: store.following.filter { $0.source == .terminal },
                        emptyTitle: "No runs yet",
                        emptyMessage: "Run something in a terminal of Lowtide. When it ends, you get a receipt: the hosts it reached, the files it changed and anything it left running.") {
                EmptyView()
            }
        }
        .confirmation($confirm)
    }
}

/// Installs, updates, removals and cleanups, from the vault's activity log.
private struct PackageHistory: View {
    enum Filter: Hashable { case all, failed }
    @Environment(\.palette) private var palette
    @State private var entries: [ActivityEntry]?
    @State private var error: String?
    @State private var filter = Filter.all
    @State private var query = ""
    @State private var confirm: ConfirmRequest?
    let tabs: AnyView

    var body: some View {
        let all = entries ?? []
        let failed = all.filter { !$0.succeeded }.count
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let visible = all.filter { entry in
            (filter == .all || !entry.succeeded) && (needle.isEmpty || [entry.itemName, entry.sourceName, entry.action]
                .contains { $0.lowercased().contains(needle) })
        }
        VStack(spacing: 0) {
            PageHeader("History",
                       description: all.isEmpty ? nil
                        : LowtideFormat.count(all.count, "operation") + (failed > 0 ? " · \(failed) failed" : "")) {
                tabs
            } action: {
                if !all.isEmpty {
                    Button("Clear…") {
                        confirm = ConfirmRequest(
                            title: "Clear package history?",
                            message: "Delete the record of installs, updates and cleanups on this Mac. The packages themselves stay as they are.",
                            confirm: "Clear History") { clear() }
                    }
                    .buttonStyle(.lowtide(.quiet, size: .small))
                }
            }
            if !all.isEmpty {
                PageToolbar {
                    Segmented($filter, [(.all, "All"), (.failed, "Failed")], counts: [.all: all.count, .failed: failed])
                } trailing: {
                    FilterField(text: $query, prompt: "Search activity")
                }
                .padding(.horizontal, Space.page + 4)
                .padding(.bottom, Space.md)
            }
            ScrollView {
                content(all: all, visible: visible, needle: needle)
                    .padding(.horizontal, Space.page + 4)
                    .padding(.vertical, Space.lg)
            }
            .overlay(alignment: .top) { Hairline() }
        }
        .task { await load() }
        .confirmation($confirm)
    }

    @ViewBuilder
    private func content(all: [ActivityEntry], visible: [ActivityEntry], needle: String) -> some View {
        if let error {
            ErrorState(message: error) { Task { await load() } }.frame(minHeight: 300)
        } else if entries == nil {
            ScanningState(title: "Reading package history…").frame(minHeight: 300)
        } else if all.isEmpty {
            EmptyState("No package history yet", symbol: "shippingbox",
                       message: "Installs, updates, removals and cleanups show up here.").frame(minHeight: 300)
        } else if visible.isEmpty {
            EmptyState("No matches", symbol: "line.3.horizontal.decrease",
                       message: needle.isEmpty ? "Nothing has failed." : "Nothing matches “\(query.trimmingCharacters(in: .whitespaces))”.")
                .frame(minHeight: 300)
        } else {
            RowStack(items: visible) { ActivityRow(entry: $0) }.card()
        }
    }

    private func load() async {
        do {
            entries = try await PackageActivity.list(limit: 2000)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func clear() {
        Task {
            do {
                try await PackageActivity.clear()
                entries = []
                Toasts.shared.show("Package history cleared")
            } catch {
                Toasts.shared.failure("Couldn't clear history", error)
            }
        }
    }
}

private struct ActivityRow: View {
    @Environment(\.palette) private var palette
    let entry: ActivityEntry

    var body: some View {
        HStack(spacing: Space.md) {
            Image(systemName: entry.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle((entry.succeeded ? palette.ok : palette.bad).color)
                .accessibilityLabel(entry.succeeded ? "Done" : "Failed")
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    Text(entry.action.capitalized).font(.ui(.sm)).foregroundStyle(palette.ink2.color)
                    Text(entry.itemName).font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color).lineLimit(1)
                    if let previous = entry.previousVersion {
                        Text(previous + (entry.resultingVersion.map { " → \($0)" } ?? ""))
                            .font(.mono(.xxs)).monospacedDigit().foregroundStyle(palette.ink3.color).textSelection(.enabled)
                    }
                }
                if let detail = entry.detail, !detail.isEmpty {
                    Text(detail).font(.ui(.xs)).foregroundStyle((entry.succeeded ? palette.ink3 : palette.bad).color).lineLimit(1)
                        .help(detail)
                }
            }
            Spacer(minLength: Space.sm)
            Text(entry.sourceName).font(.ui(.xs)).foregroundStyle(palette.ink3.color)
            if let seconds = entry.duration, case let ms = Int(seconds * 1000) {
                Text(ms < 1000 ? "\(ms) ms" : String(format: ms < 10_000 ? "%.1f s" : "%.0f s", Double(ms) / 1000))
                    .font(.ui(.xs)).monospacedDigit().foregroundStyle(palette.ink4.color).frame(width: 52, alignment: .trailing)
            }
            Text(LowtideFormat.ago(entry.createdAt)).font(.ui(.xs)).monospacedDigit().foregroundStyle(palette.ink3.color)
                .frame(width: 76, alignment: .trailing)
                .help(entry.createdAt.formatted(date: .abbreviated, time: .standard))
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
        .frame(minHeight: 48)
        .contextMenu {
            Button("Copy Name") { FileActions.copy(entry.itemName, what: "Name") }
            if let detail = entry.detail { Button("Copy Detail") { FileActions.copy(detail, what: "Detail") } }
        }
    }
}
