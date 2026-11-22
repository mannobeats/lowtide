import LowtideKit
import SwiftUI

/// System → Processes: every process you can read, busiest first, with its
/// share of the power. Select one for its detail; quit or force quit
/// (yours only) after a confirmation.
struct ProcessesPage: View {
    @Environment(\.palette) private var palette
    var model = SystemModel.shared
    @State private var search = ""
    @State private var selection = Set<Int32>()
    @State private var sortOrder = [KeyPathComparator(\ProcessRow.cpu, order: .reverse)]
    @State private var confirm: ConfirmRequest?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("Processes", description: description, compact: true) {
                EmptyView()
            } action: {
                FilterField(text: $search, prompt: "Search processes")
                    .frame(width: 240)
            }
            content
        }
        .systemFeed("page.processes", .processes)
        .confirmation($confirm)
        .onChange(of: model.processes) { _, list in
            // A selected process that ended (or was ended) drops out.
            guard let list, !selection.isEmpty else { return }
            let live = Set(list.map(\.pid))
            if !selection.isSubset(of: live) { selection.formIntersection(live) }
        }
    }

    private var description: String? {
        guard model.processes != nil else { return nil }
        let watts = rows.reduce(0) { $0 + $1.watts }
        let cpuShared = model.latest?.power.cpuReported ?? true
        return "\(rows.count.formatted()) processes drawing \(SystemFormat.watts(watts)), shared out by \(cpuShared ? "CPU and GPU" : "GPU") time"
    }

    private var rows: [ProcessRow] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        let list = (model.processes ?? []).filter {
            needle.isEmpty || $0.name.lowercased().contains(needle) || String($0.pid) == needle
        }
        return list.sorted(using: sortOrder)
    }

    private var selected: ProcessRow? {
        guard selection.count == 1, let pid = selection.first else { return nil }
        return model.processes?.first { $0.pid == pid }
    }

    @ViewBuilder private var content: some View {
        if model.processes == nil {
            ScanningState(title: "Reading processes")
        } else {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if rows.isEmpty {
                        EmptyState("No process matches “\(search)”", symbol: "magnifyingglass",
                                   message: "Search by name or by process ID.") {
                            Button("Clear Search") { search = "" }.buttonStyle(.secondary)
                        }
                    } else {
                        table
                    }
                    if selection.count > 1 { selectionBar }
                }
                .frame(maxWidth: .infinity)
                if let selected {
                    ProcessDetailPanel(process: selected, history: model.processHistory[selected.pid] ?? [],
                                       onClose: { selection = [] },
                                       onSelect: select,
                                       onEnd: { ask($0, [selected]) })
                        .frame(width: 360)
                        .hairline(.leading)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(Motion.base, value: selected?.pid)
        }
    }

    private var table: some View {
        let rows = rows
        let loud = Loudness(rows)
        let compact = selected != nil
        return Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Process", value: \.name) { p in
                HStack(spacing: 10) {
                    ProcessIcon(app: p.app, size: 18)
                    Text(p.name).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle((p.userOwned ? palette.ink : palette.ink3).color)
                    if !compact {
                        Text(String(p.pid)).font(.mono(.xxs)).monospacedDigit().foregroundStyle(palette.ink4.color)
                    }
                }
                .help(p.path ?? p.name)
            }
            .width(min: 180, ideal: 280)
            TableColumn("CPU", value: \.cpu) { p in
                Cell(text: String(format: "%.1f%%", p.cpu), loud: loud.cpu(p))
            }
            .width(min: 56, ideal: 72)
            .alignment(.trailing)
            TableColumn("GPU", value: \.gpu) { p in
                Cell(text: p.gpu >= 0.1 ? String(format: "%.1f%%", p.gpu) : "–", loud: loud.gpu(p))
            }
            .width(min: 52, ideal: 64)
            .alignment(.trailing)
            TableColumn("Memory", value: \.memory) { p in
                Cell(text: SystemFormat.memory(p.memory), loud: loud.memory(p))
            }
            .width(min: 64, ideal: 88)
            .alignment(.trailing)
            TableColumn("Power", value: \.watts) { p in
                Cell(text: p.watts >= 0.01 ? SystemFormat.watts(p.watts) : "–", loud: loud.watts(p))
            }
            .width(min: 60, ideal: 76)
            .alignment(.trailing)
            // Disk steps aside while the detail panel is open.
            if !compact {
                TableColumn("Disk", value: \.diskRate) { p in
                    Cell(text: p.diskRate >= 1024 ? SystemFormat.rate(p.diskRate) : "–", loud: loud.disk(p))
                }
                .width(min: 64, ideal: 88)
                .alignment(.trailing)
            }
        }
        .tableStyle(.inset)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: Int32.self) { pids in
            menu(for: pids)
        }
        .onDeleteCommand { askForSelection(.quit) }
        .onKeyPress(.escape) {
            guard !selection.isEmpty else { return .ignored }
            selection = []
            return .handled
        }
    }

    @ViewBuilder private func menu(for pids: Set<Int32>) -> some View {
        let targets = (model.processes ?? []).filter { pids.contains($0.pid) }
        let own = targets.filter(\.userOwned)
        if targets.count == 1, let p = targets.first {
            if let path = p.app ?? p.path {
                Button("Show in Finder") { Files.reveal([path]) }
            }
            Button("Copy PID") { copy(String(p.pid)) }
            if let path = p.path { Button("Copy Path") { copy(path) } }
        }
        if !own.isEmpty {
            Divider()
            let many = own.count > 1 ? " \(own.count) Processes" : ""
            Button("Quit\(many)") { ask(.quit, own) }
            Button("Force Quit\(many)", role: .destructive) { ask(.forceQuit, own) }
        }
    }

    private var selectionBar: some View {
        let own = (model.processes ?? []).filter { selection.contains($0.pid) && $0.userOwned }
        return HStack(spacing: Space.sm) {
            Text("\(selection.count) processes selected").font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color)
            if own.count < selection.count {
                Text("· \(own.count) of them yours").font(.ui(.sm)).foregroundStyle(palette.ink3.color)
            }
            Spacer()
            Button("Clear") { selection = [] }.buttonStyle(.lowtide(.quiet, size: .small))
            Button("Quit") { ask(.quit, own) }.buttonStyle(.lowtide(.secondary, size: .small)).disabled(own.isEmpty)
            Button("Force Quit") { ask(.forceQuit, own) }.buttonStyle(.lowtide(.destructive, size: .small)).disabled(own.isEmpty)
        }
        .padding(.horizontal, Space.lg)
        .frame(height: 44)
        .background(palette.surface.color)
        .hairline(.top)
    }

    private func select(_ pid: Int32) {
        if !rows.contains(where: { $0.pid == pid }) { search = "" }
        selection = [pid]
    }

    private func copy(_ text: String) {
        Files.copy(text)
    }

    private func askForSelection(_ mode: ProcessControl.Mode) {
        let own = (model.processes ?? []).filter { selection.contains($0.pid) && $0.userOwned }
        if !own.isEmpty { ask(mode, own) }
    }

    private func ask(_ mode: ProcessControl.Mode, _ targets: [ProcessRow]) {
        guard !targets.isEmpty else { return }
        let name = targets.count == 1 ? targets[0].name : "\(targets.count) processes"
        let (confirm, title, message): (String, String, String) = switch mode {
        case .quit: ("Quit", "Quit \(name)?", "Asks \(name) to quit, as if you chose Quit in it.")
        case .forceQuit: ("Force Quit", "Force quit \(name)?", "Stops \(name) at once, without a chance to save work.")
        case .quitTree: ("Quit All", "Quit \(name) and its children?", "Asks \(name) and every process it started to quit.")
        }
        self.confirm = ConfirmRequest(title: title, message: message + " Anything it hasn't saved is lost.",
                                      confirm: confirm, destructive: mode != .quit) {
            Task { await end(targets, mode: mode, name: name) }
        }
    }

    private func end(_ targets: [ProcessRow], mode: ProcessControl.Mode, name: String) async {
        var failures: [(String, Error)] = []
        for p in targets {
            do { try await ProcessControl.end(p.pid, mode: mode) } catch { failures.append((p.name, error)) }
        }
        model.refreshProcesses()
        let done = targets.count - failures.count
        if done > 0 { Toasts.shared.show(done == 1 && targets.count == 1 ? "Ended \(name)" : "Ended \(LowtideFormat.count(done, "process", "processes"))") }
        if let (who, error) = failures.first {
            Toasts.shared.failure(failures.count == 1 ? "Couldn't end \(who)" : "Couldn't end \(failures.count) processes", error)
        }
    }
}

/// A number in a column: the busiest few stand out.
private struct Cell: View {
    @Environment(\.palette) private var palette
    let text: String
    let loud: Bool
    var body: some View {
        Text(text).font(.mono(.xs)).monospacedDigit()
            .foregroundStyle((loud ? palette.ink : palette.ink3).color)
    }
}

/// The value of the third busiest per column: anything at or above is loud.
private struct Loudness {
    private let thresholds: [Double]

    init(_ rows: [ProcessRow]) {
        func third(_ values: [Double]) -> Double {
            let top = values.sorted(by: >)
            return top.count > 2 ? top[2] : .infinity
        }
        thresholds = [third(rows.map(\.cpu)), third(rows.map(\.gpu)), third(rows.map { Double($0.memory) }),
                      third(rows.map(\.watts)), third(rows.map(\.diskRate))]
    }

    private func loud(_ value: Double, _ i: Int) -> Bool { value > 0 && value >= thresholds[i] }
    func cpu(_ p: ProcessRow) -> Bool { loud(p.cpu, 0) }
    func gpu(_ p: ProcessRow) -> Bool { loud(p.gpu, 1) }
    func memory(_ p: ProcessRow) -> Bool { loud(Double(p.memory), 2) }
    func watts(_ p: ProcessRow) -> Bool { loud(p.watts, 3) }
    func disk(_ p: ProcessRow) -> Bool { loud(p.diskRate, 4) }
}
