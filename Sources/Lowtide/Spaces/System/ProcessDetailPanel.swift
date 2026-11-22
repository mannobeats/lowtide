import LowtideKit
import SwiftUI

/// One process in depth, beside the table: right now, since it started,
/// its family and signature, its connections and where it runs from.
struct ProcessDetailPanel: View {
    @Environment(\.palette) private var palette
    @Environment(\.privacy) private var privacy
    let process: ProcessRow
    let history: [Double]
    let onClose: () -> Void
    let onSelect: (Int32) -> Void
    let onEnd: (ProcessControl.Mode) -> Void
    @State private var detail: ProcessDetail?

    private static let started: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM HH:mm")
        return f
    }()

    var body: some View {
        let p = process
        VStack(spacing: 0) {
            HStack(spacing: Space.md) {
                ProcessIcon(app: p.app, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name).font(.ui(.lg, .semibold)).foregroundStyle(palette.ink.color).lineLimit(1)
                        .textSelection(.enabled)
                    Text("\(p.kind) · PID \(p.pid)\(detail.map { " · \(privacy ? "•••" : $0.user)" } ?? "")")
                        .font(.ui(.xs)).monospacedDigit().foregroundStyle(palette.ink3.color).lineLimit(1)
                }
                Spacer(minLength: 0)
                IconButton("xmark", help: "Close", action: onClose)
            }
            .padding(Space.lg)
            .hairline()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    section("Right now", first: true) {
                        Sparkline(values: history, maxValue: max(100, history.max() ?? 0))
                            .frame(height: 32)
                        fact("CPU", String(format: "%.1f%%", p.cpu))
                        fact("GPU", p.gpu >= 0.1 ? String(format: "%.1f%%", p.gpu) : "–")
                        fact("Memory", SystemFormat.memory(p.memory))
                        fact("Power", p.watts >= 0.01 ? SystemFormat.watts(p.watts) : "–")
                        fact("Disk", p.diskRate >= 1024 ? SystemFormat.rate(p.diskRate) : "–")
                    }
                    if let d = detail {
                        sinceStarted(d)
                        family(d)
                        if !d.connections.isEmpty { connections(d) }
                        whereFrom(d)
                    }
                }
            }
            .scrollContentBackground(.hidden)

            HStack(spacing: Space.sm) {
                if let path = p.app ?? p.path {
                    Button {
                        Files.reveal([path])
                    } label: { Label("Show in Finder", systemImage: "folder") }
                        .buttonStyle(.lowtide(.secondary, size: .small))
                }
                Spacer(minLength: 0)
                if p.userOwned {
                    Button("Quit") { onEnd(.quit) }.buttonStyle(.lowtide(.secondary, size: .small))
                    if !(detail?.children.isEmpty ?? true) {
                        Button("Quit with Children") { onEnd(.quitTree) }.buttonStyle(.lowtide(.secondary, size: .small))
                            .help("Quit it and every process it started")
                    }
                    Button("Force Quit") { onEnd(.forceQuit) }.buttonStyle(.lowtide(.destructive, size: .small))
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.md)
            .hairline(.top)
        }
        .background(palette.bg.color)
        .task(id: p.pid) {
            detail = nil
            while !Task.isCancelled {
                let next = await ProcessTable.detail(p.pid)
                if !Task.isCancelled, next != detail { detail = next }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func sinceStarted(_ d: ProcessDetail) -> some View {
        section("Since it started") {
            fact("Running for", "\(SystemFormat.running(since: d.started)), since \(Self.started.string(from: d.started))")
            fact("CPU time", SystemFormat.cpuTime(d.cpuSeconds))
            if d.gpuSeconds > 0.01 { fact("GPU time", SystemFormat.cpuTime(d.gpuSeconds)) }
            fact("Peak memory", SystemFormat.memory(d.peakMemory))
            fact("Read from disk", LowtideFormat.bytes(d.diskRead))
            fact("Written to disk", LowtideFormat.bytes(d.diskWritten))
            if let threads = d.threads { fact("Threads", threads.formatted()) }
            if let ipc = d.ipc { fact("Efficiency", String(format: "%.2f instructions per cycle", ipc)) }
        }
    }

    private func family(_ d: ProcessDetail) -> some View {
        section("Family") {
            if let parent = d.parent {
                HStack {
                    Text("Started by").foregroundStyle(palette.ink3.color)
                    Spacer()
                    Button("\(parent.name) · \(parent.pid)") { onSelect(parent.pid) }
                        .buttonStyle(.plain)
                        .foregroundStyle(palette.brand.color)
                        .help("Show \(parent.name)")
                }
                .font(.ui(.xs))
                .padding(.vertical, Space.xs)
            }
            HStack {
                Text("Signed").foregroundStyle(palette.ink3.color)
                Spacer()
                signature(d)
            }
            .font(.ui(.xs))
            .padding(.vertical, Space.xs)
            if !d.children.isEmpty {
                VStack(spacing: 0) {
                    ForEach(d.children.prefix(12), id: \.pid) { child in
                        ChildRow(name: child.name, pid: child.pid) { onSelect(child.pid) }
                    }
                    if d.children.count > 12 {
                        Text("and \(d.children.count - 12) more").font(.ui(.xxs)).foregroundStyle(palette.ink4.color)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, Space.xs)
                    }
                }
                .padding(.top, Space.xs)
            }
        }
    }

    @ViewBuilder private func signature(_ d: ProcessDetail) -> some View {
        if d.apple {
            Text("Part of macOS").foregroundStyle(palette.ok.color)
        } else if let team = d.team {
            Text("Developer team \(team)").foregroundStyle(palette.ink.color).textSelection(.enabled)
        } else {
            Text("No developer signature").foregroundStyle(palette.warn.color)
        }
    }

    private func connections(_ d: ProcessDetail) -> some View {
        section("Connected to \(LowtideFormat.count(d.connections.count, "server"))") {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(d.connections.prefix(10), id: \.self) { c in
                    Sensitive(text: "\(c.ip):\(c.port)", font: .mono(.xxs))
                        .foregroundStyle(palette.ink2.color)
                }
            }
            Button {
                AppModel.shared.open(.networkLive)
            } label: {
                HStack(spacing: 6) {
                    NavIcon("network", size: 14)
                    Text("See its traffic in Network")
                }
            }
            .buttonStyle(.plain)
            .font(.ui(.xs))
            .foregroundStyle(palette.brand.color)
            .padding(.top, Space.sm)
        }
    }

    private func whereFrom(_ d: ProcessDetail) -> some View {
        section("Where it runs from") {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(d.path ?? "Unknown").font(.mono(.xxs)).foregroundStyle(palette.ink2.color)
                if let command = d.command, command != d.path {
                    Text(command).font(.mono(.xxs)).foregroundStyle(palette.ink3.color)
                }
                if let cwd = d.cwd, cwd != "/" {
                    Text("in \(cwd)").font(.mono(.xxs)).foregroundStyle(palette.ink3.color)
                }
            }
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .redacted(reason: privacy ? .privacy : [])
        }
    }

    private func section<Content: View>(_ title: String, first: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.ui(.xs, .semibold)).foregroundStyle(palette.ink2.color).padding(.bottom, Space.xs)
            content()
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { if !first { Hairline() } }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.lg) {
            Text(label).foregroundStyle(palette.ink3.color)
            Spacer(minLength: 0)
            Text(value).foregroundStyle(palette.ink.color).monospacedDigit().lineLimit(1).truncationMode(.middle)
        }
        .font(.ui(.xs))
        .padding(.vertical, Space.xs)
    }
}

private struct ChildRow: View {
    @Environment(\.palette) private var palette
    let name: String
    let pid: Int32
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(name).foregroundStyle(palette.ink2.color).lineLimit(1)
                Spacer()
                Text(String(pid)).font(.mono(.xxs)).foregroundStyle(palette.ink4.color)
            }
            .font(.ui(.xs))
            .padding(.horizontal, 6).padding(.vertical, Space.xs)
            .background((hovering ? palette.hover : palette.hover.opacity(0)).color, in: .rect(cornerRadius: Radius.sm))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Show \(name)")
    }
}
