import LowtideKit
import SwiftUI

// MARK: Hosts

/// Every destination a run reached, each opening to its details.
struct RunHosts: View {
    @Environment(\.palette) private var palette
    @Environment(\.privacy) private var privacy
    let run: Run

    var body: some View {
        let dests = run.net.dests
        if dests.isEmpty {
            QuietNote("No connections were seen while it ran.")
        } else {
            let install = run.ecosystem?.label
            let odd = dests.filter { !$0.expected }.count
            let title = install != nil && odd > 0 ? "\(LowtideFormat.count(dests.count, "host")), \(odd) unexpected"
                : LowtideFormat.count(dests.count, "host")
            Pane(title, subtitle: "\(LowtideFormat.bytes(run.net.bytesIn)) in, \(LowtideFormat.bytes(run.net.bytesOut)) out") {
                RowStack(items: dests.enumerated().map { Indexed(index: $0.offset, value: $0.element) }) { item in
                    let dest = item.value
                    ExpandRow {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(dest.host ?? (privacy ? "•••••••" : dest.ip))
                                .font(.mono(.xs)).foregroundStyle(palette.ink.color).lineLimit(1)
                            Text([dest.org, dest.country, dest.apps.joined(separator: ", ")].compactMap { $0 }.filter { !$0.isEmpty }
                                .joined(separator: " · "))
                                .font(.ui(.xs)).foregroundStyle(palette.ink3.color).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if install != nil, !dest.expected { Badge("Unexpected", tone: .warn) }
                        Text(dest.bytesIn + dest.bytesOut > 0
                             ? "↓ \(LowtideFormat.bytes(dest.bytesIn)) ↑ \(LowtideFormat.bytes(dest.bytesOut))" : "Seen")
                            .font(.ui(.xs)).monospacedDigit().foregroundStyle(palette.ink3.color)
                            .frame(width: 130, alignment: .trailing)
                    } detail: {
                        HostFacts(dest: dest, install: install)
                    }
                }
            }
        }
    }
}

/// One destination in full: address, ports, processes, and why it was or
/// wasn't expected.
private struct HostFacts: View {
    @Environment(\.palette) private var palette
    @Environment(\.privacy) private var privacy
    let dest: RunDest
    let install: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            RunFactRow("Address", privacy ? "•••••••" : dest.ip, mono: true)
            if !dest.ports.isEmpty {
                RunFactRow(dest.ports.count > 1 ? "Ports" : "Port", dest.ports.map(String.init).joined(separator: ", "), mono: true)
            }
            RunFactRow("Processes", dest.apps.isEmpty ? "Unknown" : dest.apps.joined(separator: ", "))
            if let org = dest.org { RunFactRow("Network", org) }
            if let country = dest.country {
                RunFactRow("Country", Locale.current.localizedString(forRegionCode: country) ?? country)
            }
            RunFactRow("Received", counted(dest.bytesIn))
            RunFactRow("Sent", counted(dest.bytesOut), tone: !dest.expected && dest.bytesOut > 50_000 ? .warn : nil)
        }
        .frame(maxWidth: 440, alignment: .leading)
        if let install {
            Text(dest.expected
                 ? "One of the hosts \(install) installs normally use, or a registry you set up."
                 : "Not one of \(install)'s usual hosts. Packages can download from their own servers; sending a lot to an unknown host is the part to question.")
                .foregroundStyle(palette.ink3.color).frame(maxWidth: 520, alignment: .leading)
        }
        if dest.bytesIn + dest.bytesOut == 0 {
            Text("Seen on a process's own socket, so no byte count.")
                .foregroundStyle(palette.ink3.color).frame(maxWidth: 520, alignment: .leading)
        }
    }

    private func counted(_ bytes: UInt64) -> String { bytes > 0 ? LowtideFormat.bytes(bytes) : "Not counted" }
}

// MARK: Files

/// Every place a run changed files, each folder opening to its files.
struct RunFiles: View {
    @Environment(\.palette) private var palette
    let run: Run

    var body: some View {
        if run.files.total == 0 {
            QuietNote("No files changed outside caches nobody needs to see.")
        } else {
            VStack(alignment: .leading, spacing: Space.md) {
                ForEach(run.files.places, id: \.place) { summary in
                    let added = summary.groups.reduce(0) { $0 + $1.added }
                    let removed = summary.groups.reduce(0) { $0 + $1.removed }
                    let detail = changes(added: added, removed: removed)
                    Pane(summary.place.label, subtitle: (detail.isEmpty ? "" : detail + " · ") + summary.count.formatted()) {
                        if summary.place.risky, !summary.paths.isEmpty {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(summary.paths, id: \.self) { PathLine(path: $0) }
                            }
                            .padding(.horizontal, Space.lg)
                            .padding(.bottom, Space.sm)
                        } else {
                            RowStack(items: summary.groups.enumerated().map { Indexed(index: $0.offset, value: $0.element) }) {
                                GroupRow(group: $0.value)
                            }
                        }
                    }
                }
                QuietNote("Right-click a path for Open, Quick Look and Copy Path.", small: true)
            }
        }
    }
}

/// `12 new · 3 removed`, when the receipt knows.
private func changes(added: Int, removed: Int) -> String {
    [added > 0 ? "\(added) new" : nil, removed > 0 ? "\(removed) removed" : nil].compactMap { $0 }.joined(separator: " · ")
}

private struct GroupRow: View {
    @Environment(\.palette) private var palette
    let group: FileGroup

    var body: some View {
        let detail = changes(added: group.added, removed: group.removed)
        let rest = group.count - group.samples.count
        // Older receipts kept only the folder name and its count.
        if group.samples.isEmpty {
            HStack {
                Text(group.name).font(.mono(.xs)).foregroundStyle(palette.ink2.color).lineLimit(1)
                Spacer()
                Text(group.count.formatted()).font(.ui(.xs)).monospacedDigit().foregroundStyle(palette.ink3.color)
            }
            .padding(.horizontal, Space.lg)
            .frame(minHeight: 36)
        } else {
            ExpandRow {
                Text(group.name).font(.mono(.xs)).foregroundStyle(palette.ink2.color).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !detail.isEmpty {
                    Text(detail).font(.ui(.xs)).monospacedDigit().foregroundStyle(palette.ink4.color)
                }
                Text(group.count.formatted()).font(.ui(.xs)).monospacedDigit().foregroundStyle(palette.ink3.color)
                    .frame(width: 48, alignment: .trailing)
            } detail: {
                if !group.path.isEmpty { PathLine(path: group.path) }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(group.samples.filter { $0 != group.path }, id: \.self) { path in
                        PathLine(path: path, label: group.path.isEmpty ? nil : String(path.dropFirst(group.path.count + 1)))
                    }
                }
                .padding(.leading, Space.md)
                .overlay(alignment: .leading) { Rectangle().fill(palette.line.color).frame(width: 1) }
                if rest > 0 {
                    Text("and \(LowtideFormat.count(rest, "more file")); the receipt keeps a few of each folder.")
                        .foregroundStyle(palette.ink4.color)
                }
            }
        }
    }
}

// MARK: Packages

/// The packages an install wrote, the ones that ran install scripts first:
/// those are the code that ran on this Mac, not just files on disk.
struct RunPackages: View {
    @Environment(\.palette) private var palette
    @State private var all = false
    let run: Run

    static let first = 12

    /// `esbuild` from `esbuild@0.21.5` and `@types/node@22.1.0`.
    static func name(of id: String) -> String {
        guard let at = id.lastIndex(of: "@"), at != id.startIndex else { return id }
        return String(id[..<at])
    }

    var body: some View {
        let packages = run.packages
        if !packages.isEmpty {
            let scripts = Dictionary(grouping: run.procs.tree.filter { $0.script != nil && $0.package != nil }) {
                Self.name(of: $0.package!)
            }.mapValues { $0.compactMap(\.script) }
            let ranked = packages.enumerated().sorted {
                (scripts[$0.element.name] == nil ? 1 : 0, $0.offset) < (scripts[$1.element.name] == nil ? 1 : 0, $1.offset)
            }.map(\.element)
            let shown = all ? ranked : Array(ranked.prefix(Self.first))
            let removed = packages.filter(\.removed).count
            let scripted = packages.filter { scripts[$0.name] != nil }.count
            let meta = [scripted > 0 ? "\(scripted) ran install scripts" : nil, removed > 0 ? "\(removed) removed" : nil]
                .compactMap { $0 }.joined(separator: " · ")
            Pane(LowtideFormat.count(packages.count, "package"), subtitle: meta.isEmpty ? nil : meta) {
                RowStack(items: shown.enumerated().map { Indexed(index: $0.offset, value: $0.element) }) { item in
                    PackageRow(package: item.value, scripts: scripts[item.value.name] ?? [])
                }
                if packages.count > Self.first {
                    Button(all ? "Show Fewer" : "Show All \(packages.count)") { withAnimation(Motion.base) { all.toggle() } }
                        .buttonStyle(.lowtide(.quiet, size: .small))
                        .padding(.horizontal, Space.md)
                        .padding(.bottom, Space.sm)
                }
            }
        }
    }
}

private struct PackageRow: View {
    @Environment(\.palette) private var palette
    let package: RunPackage
    let scripts: [String]

    var body: some View {
        ExpandRow {
            Text("\(Text(package.name).foregroundStyle(palette.ink.color))\(Text(package.version.map { " \($0)" } ?? "").foregroundStyle(palette.ink3.color))")
                .font(.mono(.xs)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(scripts, id: \.self) { Badge($0, tone: .warn) }
            if package.removed { Badge("Removed") }
            Text(LowtideFormat.count(package.files, "file")).font(.ui(.xs)).monospacedDigit().foregroundStyle(palette.ink3.color)
                .frame(width: 64, alignment: .trailing)
        } detail: {
            PathLine(path: package.path)
            Text(about).foregroundStyle(palette.ink3.color).frame(maxWidth: 560, alignment: .leading)
        }
    }

    private var about: String {
        if !scripts.isEmpty {
            return "Ran its \(scripts.joined(separator: " and ")) script while installing: code from this package ran on your Mac. Processes shows exactly what it started."
        }
        return package.removed ? "Every file it had here is gone: the install removed it."
            : "Written to disk. No install script of its own was seen running."
    }
}

// MARK: Processes

/// What a run left running, with Stop: shown on the summary.
struct LeftRunning: View {
    @Environment(\.palette) private var palette
    @State private var confirm: ConfirmRequest?
    let run: Run

    var body: some View {
        if !run.procs.leftRunning.isEmpty {
            Pane("Left running", subtitle: "\(run.procs.leftRunning.count)") {
                RowStack(items: run.procs.leftRunning.enumerated().map { Indexed(index: $0.offset, value: $0.element) }) { item in
                    ChildRow(child: item.value) {
                        let child = item.value
                        confirm = ConfirmRequest(
                            title: "Stop this process?",
                            message: "Sends \(child.name) (\(child.pid)) a request to quit. Unsaved work in that process may be lost.",
                            confirm: "Stop It") { Task { await RunsStore.shared.stop(child) } }
                    }
                }
            }
            .confirmation($confirm)
        }
    }
}

private struct ChildRow: View {
    @Environment(\.palette) private var palette
    let child: RunChild
    var onStop: (() -> Void)?

    var body: some View {
        HStack(spacing: Space.md) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    Text(child.name).font(.mono(.xs)).foregroundStyle(palette.ink.color)
                    Text(String(child.pid)).font(.ui(.xs)).monospacedDigit().foregroundStyle(palette.ink4.color)
                    if let reason = child.reason {
                        Text(reason).font(.ui(.xs)).foregroundStyle((child.severity ?? .info).reasonTone(palette).color)
                    }
                }
                Text(child.command).font(.mono(.xxs)).foregroundStyle(palette.ink4.color).lineLimit(1).truncationMode(.middle)
                    .help(child.command)
            }
            Spacer(minLength: Space.sm)
            if let onStop { Button("Stop", action: onStop).buttonStyle(.lowtide(.quiet, size: .small)) }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
        .contextMenu {
            Button("Copy Command") { FileActions.copy(child.command, what: "Command") }
            if let onStop { Button("Stop…", action: onStop) }
        }
    }
}

extension Severity {
    func reasonTone(_ p: Palette) -> ColorValue { self == .alert ? p.bad : self == .notice ? p.warn : p.ink3 }
}

/// The whole process tree: what ran, for how long, which scripts and why
/// any of it is worth a look.
struct RunProcesses: View {
    enum Show: Hashable { case all, scripts, notable }
    @Environment(\.palette) private var palette
    @State private var show = Show.all
    let run: Run

    /// Processes in start order, each under the one that started it.
    static func ordered(_ tree: [RunProc]) -> [(RunProc, Int)] {
        let pids = Set(tree.map(\.pid))
        var children: [Int32: [RunProc]] = [:]
        var roots: [RunProc] = []
        for proc in tree {
            if pids.contains(proc.ppid), proc.ppid != proc.pid { children[proc.ppid, default: []].append(proc) } else { roots.append(proc) }
        }
        var out: [(RunProc, Int)] = []
        var seen: Set<Int32> = []
        func walk(_ proc: RunProc, _ depth: Int) {
            guard seen.insert(proc.pid).inserted else { return }
            out.append((proc, depth))
            for child in children[proc.pid] ?? [] { walk(child, depth + 1) }
        }
        roots.forEach { walk($0, 0) }
        return out
    }

    var body: some View {
        let tree = run.procs.tree, notable = run.procs.notable
        VStack(alignment: .leading, spacing: Space.md) {
            // Receipts saved before the tree was kept still have their highlights.
            if tree.isEmpty {
                if notable.isEmpty {
                    QuietNote("\(LowtideFormat.count(run.procs.count, "process", "processes")), none worth a look.")
                } else {
                    Pane("Worth a look", subtitle: "\(LowtideFormat.count(run.procs.count, "process", "processes")) in all") {
                        RowStack(items: notable.enumerated().map { Indexed(index: $0.offset, value: $0.element) }) {
                            ChildRow(child: $0.value)
                        }
                    }
                }
            } else {
                let flagged = Dictionary(notable.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
                let scripts = tree.filter { $0.script != nil }.count
                if scripts > 0 || !notable.isEmpty {
                    Segmented($show, [(Show.all, "All")] + (scripts > 0 ? [(.scripts, "Install scripts")] : [])
                        + (notable.isEmpty ? [] : [(.notable, "Worth a look")]),
                              counts: [.all: tree.count, .scripts: scripts, .notable: notable.count])
                }
                let rows = Self.ordered(tree).filter { proc, _ in
                    show == .all || (show == .scripts ? proc.script != nil : flagged[proc.pid] != nil)
                }
                let more = run.procs.count - tree.count
                Pane(LowtideFormat.count(run.procs.count, "process", "processes"),
                     subtitle: more > 0 ? "first \(tree.count) of \(run.procs.count)" : nil) {
                    RowStack(items: rows.enumerated().map { Indexed(index: $0.offset, value: $0.element) }) { item in
                        ProcRow(proc: item.value.0, depth: show == .all ? item.value.1 : 0, end: run.ended,
                                flagged: flagged[item.value.0.pid])
                    }
                }
            }
            LeftRunning(run: run)
        }
    }
}

private struct ProcRow: View {
    @Environment(\.palette) private var palette
    let proc: RunProc
    let depth: Int
    let end: UInt64
    let flagged: RunChild?

    var body: some View {
        let ran = (proc.ended ?? end) >= proc.started ? (proc.ended ?? end) - proc.started : 0
        ExpandRow {
            HStack(spacing: Space.md) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                        Text(proc.name).font(.mono(.xs)).foregroundStyle(palette.ink.color)
                        Text(String(proc.pid)).font(.ui(.xs)).monospacedDigit().foregroundStyle(palette.ink4.color)
                        if proc.script != nil, let package = proc.package {
                            Text(package).font(.mono(.xxs)).foregroundStyle(palette.ink3.color).lineLimit(1)
                        }
                        if let reason = flagged?.reason {
                            Text(reason).font(.ui(.xs)).foregroundStyle((flagged?.severity ?? .info).reasonTone(palette).color)
                                .lineLimit(1)
                        }
                    }
                    Text(proc.command).font(.mono(.xxs)).foregroundStyle(palette.ink4.color).lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let script = proc.script {
                    Badge(script).help(proc.package.map { "\($0)'s \(script) script" } ?? script)
                }
                Text(proc.ended == nil ? "Running" : RunWords.duration(ran))
                    .font(.ui(.xs)).monospacedDigit().foregroundStyle(palette.ink3.color)
                    .frame(width: 64, alignment: .trailing)
            }
            .padding(.leading, CGFloat(min(depth, 5)) * 12)
        } detail: {
            Text(proc.command).font(.mono(.xxs)).foregroundStyle(palette.ink2.color).textSelection(.enabled)
            Text(facts(ran)).foregroundStyle(palette.ink3.color)
            Button("Copy Command") { FileActions.copy(proc.command, what: "Command") }
                .buttonStyle(.lowtide(.secondary, size: .small))
        }
    }

    private func facts(_ ran: UInt64) -> String {
        var text = "Started \(Clock.date(proc.started).timeOfDay)"
        text += proc.ended == nil ? ", still running when the run ended" : ", ran \(RunWords.duration(ran))"
        if let script = proc.script { text += " · the \(script) script" + (proc.package.map { " of \($0)" } ?? "") }
        return text + " · parent \(proc.ppid)"
    }
}

/// A quiet sentence in place of a list.
struct QuietNote: View {
    @Environment(\.palette) private var palette
    let text: String
    var small = false
    init(_ text: String, small: Bool = false) {
        self.text = text
        self.small = small
    }
    var body: some View {
        Text(text).font(.ui(small ? .xs : .sm)).foregroundStyle(palette.ink3.color)
            .frame(maxWidth: 620, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
