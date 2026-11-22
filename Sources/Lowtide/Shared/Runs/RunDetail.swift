import LowtideKit
import SwiftUI

/// A run written up: what it reached, spawned, changed and left behind.
/// The tiles open each in full; the summary keeps what needs a decision.
struct RunDetail: View {
    @Environment(\.palette) private var palette
    @State private var view = RunView.summary
    let run: Run
    let runs: [Run]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            header
            RunStats(run: run, view: $view)
            switch view {
            case .summary:
                RunSummary(run: run, runs: runs) { look in withAnimation(Motion.base) { view = look } }
            case .hosts, .processes, .files:
                VStack(alignment: .leading, spacing: Space.md) {
                    switch view {
                    case .hosts: RunHosts(run: run)
                    case .processes: RunProcesses(run: run)
                    default: RunFiles(run: run)
                    }
                    Button("Back to Summary") { withAnimation(Motion.base) { view = .summary } }
                        .buttonStyle(.lowtide(.quiet, size: .small))
                }
                .transition(.opacity)
            }
            QuietNote("Processes are sampled four times a second and connections read from their sockets, so something that starts and ends in between can slip by. Files are the ones that changed while it ran, which can include another app writing at the same moment.", small: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                VerdictDot(severity: run.verdict)
                Text(RunWords.verdictLabel(run)).font(.ui(.xs, .medium))
                    .foregroundStyle((run.verdict == .info ? palette.ink2 : run.verdict.tone.color(palette)).color)
                if let ecosystem = run.ecosystem {
                    Text("\(ecosystem.label) install").font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                }
            }
            Text(run.command)
                .font(.mono(.base))
                .foregroundStyle(palette.ink.color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.xs) {
                Text("\(run.startedAt.timeOfDay) · \(run.source == .terminal ? "in a terminal of Lowtide" : "started outside Lowtide")")
                    .fixedSize()
                if let cwd = run.cwd {
                    Text("· \(cwd)").font(.mono(.xxs)).lineLimit(1).truncationMode(.middle).help(cwd)
                }
            }
            .font(.ui(.xs))
            .foregroundStyle(palette.ink3.color)
        }
        .contextMenu {
            Button("Copy Command") { FileActions.copy(run.command, what: "Command") }
            if let cwd = run.cwd {
                Button("Show Folder in Finder") { FileActions.reveal(cwd) }
            }
        }
    }
}

/// The four numbers under a run's command; three of them open a section.
private struct RunStats: View {
    @Environment(\.palette) private var palette
    let run: Run
    @Binding var view: RunView

    var body: some View {
        let odd = run.ecosystem == nil ? 0 : run.net.dests.filter { !$0.expected }.count
        let scripts = run.procs.tree.filter { $0.script != nil }.count
        let added = run.files.places.flatMap(\.groups).reduce(0) { $0 + $1.added }
        let places = Set(run.files.places.map(\.place))
        let risky: String? = places.contains(.sensitive) ? "credentials changed"
            : places.contains(.persistence) ? "start-up changed" : nil
        let took = StatCell(label: "Took", value: RunWords.duration(run.took), note: "ended \(run.endedAt.timeOfDay)")
        let hosts = StatCell(label: "Hosts", value: "\(run.net.dests.count)",
                             note: odd > 0 ? "\(odd) unexpected" : run.net.bytesOut > 0 ? "↑ \(LowtideFormat.bytes(run.net.bytesOut))" : nil,
                             warn: odd > 0, picked: view == .hosts) { pick(.hosts) }
        let processes = StatCell(label: "Processes", value: "\(run.procs.count)",
                                 note: scripts > 0 ? LowtideFormat.count(scripts, "install script")
                                    : run.procs.notable.isEmpty ? nil : "\(run.procs.notable.count) worth a look",
                                 warn: run.procs.notable.contains { $0.severity == .alert }, picked: view == .processes) {
            pick(.processes)
        }
        let files = StatCell(label: "Files", value: run.files.total.formatted(), note: risky ?? (added > 0 ? "\(added) new" : nil),
                             warn: risky != nil, picked: view == .files) { pick(.files) }
        // Four across when there is room, else two by two.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 2) { took; hosts; processes; files }.frame(minWidth: 520)
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                GridRow { took; hosts }
                GridRow { processes; files }
            }
        }
        .padding(2)
        .card()
    }

    private func pick(_ next: RunView) {
        withAnimation(Motion.base) { view = view == next ? .summary : next }
    }
}

private struct StatCell: View {
    @Environment(\.palette) private var palette
    @State private var hovering = false
    let label: String
    let value: String
    var note: String?
    var warn = false
    var picked = false
    var onPick: (() -> Void)?

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.ui(.xs)).foregroundStyle(palette.ink3.color)
            Text(value).font(.title(.lg)).monospacedDigit().foregroundStyle(palette.ink.color).lineLimit(1)
                .contentTransition(.numericText())
            Text(note ?? " ").font(.ui(.xxs)).monospacedDigit().foregroundStyle((warn ? palette.warn : palette.ink4).color)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        if let onPick {
            Button(action: onPick) {
                content
                    .background((picked ? palette.selected : hovering ? palette.hover : ColorValue(r: 0, g: 0, b: 0, a: 0)).color,
                                in: .rect(cornerRadius: Radius.lg - 2))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(picked ? "Back to the summary" : "Open \(label)")
            .accessibilityAddTraits(picked ? .isSelected : [])
        } else {
            content
        }
    }
}

/// Findings, what it left running, its packages, and how it compares with
/// the last run of the same command.
private struct RunSummary: View {
    @Environment(\.palette) private var palette
    let run: Run
    let runs: [Run]
    let onLook: (RunView) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            RunFindings(findings: run.findings, onLook: onLook)
            LeftRunning(run: run)
            RunPackages(run: run)
            SinceLastTime(run: run, runs: runs)
            if run.findings.isEmpty, run.procs.leftRunning.isEmpty, run.packages.isEmpty {
                QuietNote("Nothing unusual. Pick Hosts, Processes or Files above for the full record.")
            }
        }
    }
}

/// The same command's last run in this folder, side by side with this one:
/// a new host or package for the same install is the change worth noticing.
private struct SinceLastTime: View {
    @Environment(\.palette) private var palette
    @Environment(\.privacy) private var privacy
    let run: Run
    let runs: [Run]

    var body: some View {
        if let before = RunWords.previousRun(run, in: runs) {
            let then = Set(before.net.dests.map(\.name))
            let fresh = run.net.dests.filter { !then.contains($0.name) }
            let versions = Dictionary(before.packages.map { ($0.name, $0.version) }, uniquingKeysWith: { a, _ in a })
            // Only when the last run listed packages: older receipts have none.
            let compared = !before.packages.isEmpty
            let added = run.packages.filter { compared && !$0.removed && versions[$0.name] == nil }
            let updated = run.packages.filter { pkg in
                guard let was = versions[pkg.name], let now = pkg.version else { return false }
                return was != now
            }
            Pane("Since the last run here", subtitle: LowtideFormat.ago(before.startedAt)) {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Grid(alignment: .leading, horizontalSpacing: Space.xxl, verticalSpacing: 2) {
                        GridRow {
                            RunFactRow("Took", "\(RunWords.duration(before.took)) → \(RunWords.duration(run.took))")
                            RunFactRow("Hosts", pair(before.net.dests.count, run.net.dests.count),
                                    tone: fresh.contains { !$0.expected } ? .warn : nil)
                        }
                        GridRow {
                            RunFactRow("Processes", pair(before.procs.count, run.procs.count))
                            RunFactRow("Files", pair(before.files.total, run.files.total))
                        }
                    }
                    Group {
                        if fresh.isEmpty {
                            Text("Same hosts as last time.")
                        } else {
                            Text("New hosts this time: \(hostList(fresh))")
                        }
                        if !added.isEmpty {
                            Text("New packages: \(Text(some(added.map(\.name))).font(.mono(.xxs)).foregroundStyle(palette.ink2.color))")
                        }
                        if !updated.isEmpty {
                            let names = some(updated.map { "\($0.name) \(versions[$0.name].flatMap { $0 } ?? "?") → \($0.version ?? "")" })
                            Text("Updated: \(Text(names).font(.mono(.xxs)).foregroundStyle(palette.ink2.color))")
                        }
                    }
                    .font(.ui(.xs))
                    .foregroundStyle(palette.ink3.color)
                }
                .padding(.horizontal, Space.lg)
                .padding(.bottom, Space.md)
            }
        }
    }

    /// New hosts in mono, the unexpected ones in amber.
    private func hostList(_ dests: [RunDest]) -> Text {
        var line = AttributedString()
        for (index, dest) in dests.enumerated() {
            if index > 0 { line += AttributedString(", ") }
            var name = AttributedString(dest.host ?? (privacy ? "•••" : dest.ip))
            name.font = .mono(.xxs)
            name.foregroundColor = (dest.expected ? palette.ink2 : palette.warn).color
            line += name
        }
        return Text(line)
    }

    private func pair(_ was: Int, _ now: Int) -> String {
        was == now ? now.formatted() : "\(was.formatted()) → \(now.formatted())"
    }

    /// Up to eight names, then how many more.
    private func some(_ names: [String]) -> String {
        names.prefix(8).joined(separator: ", ") + (names.count > 8 ? " +\(names.count - 8)" : "")
    }
}
