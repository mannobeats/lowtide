import LowtideKit
import SwiftUI

/// Hosts › Fleet: the watched hosts' health, read over SSH once a minute,
/// and what broke their usual pattern.
struct FleetView: View {
    @Environment(\.palette) private var palette
    private var remote = RemoteStore.shared
    @State private var selectedID: String?
    let onWatch: () -> Void

    init(onWatch: @escaping () -> Void) { self.onWatch = onWatch }

    static func summary(_ servers: [Fleet.Server]) -> String? {
        guard !servers.isEmpty else { return nil }
        func count(_ state: Fleet.State) -> Int { servers.filter { $0.state == state }.count }
        var parts = [LowtideKitFormat.count(servers.count, "server"), "\(count(.ok)) online"]
        if count(.unreachable) > 0 { parts.append("\(count(.unreachable)) unreachable") }
        if count(.needsKey) > 0 { parts.append("\(count(.needsKey)) can't sign in") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let servers = remote.fleet
        let selected = servers.first { $0.id == selectedID } ?? servers.first
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                if servers.isEmpty {
                    VStack(spacing: Space.lg) {
                        HeroArt("developer", size: 80)
                        EmptyState("No servers watched", symbol: "waveform.path.ecg",
                                   message: "Once a minute Lowtide reads each watched server over SSH: health, open ports, who it talks to and who is signed in, and tells you when one breaks its usual pattern.") {
                            Button("Watch hosts…", action: onWatch).buttonStyle(.primary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, Space.xxl)
                } else {
                    Pane("Servers", subtitle: "Checked every minute") {
                        EmptyView()
                    } content: {
                        VStack(spacing: 0) {
                            HStack(spacing: Space.lg) {
                                Text("Server").frame(width: 210, alignment: .leading)
                                Text("Load").frame(maxWidth: .infinity, alignment: .leading)
                                Text("Memory").frame(maxWidth: .infinity, alignment: .leading)
                                Text("Disk").frame(maxWidth: .infinity, alignment: .leading)
                                Text("Network").frame(maxWidth: .infinity, alignment: .leading)
                                Text("Latency").frame(width: 64, alignment: .trailing)
                            }
                            .font(.ui(.xs))
                            .foregroundStyle(palette.ink3.color)
                            .padding(.horizontal, Space.lg)
                            .padding(.bottom, 6)
                            ForEach(servers) { server in
                                Hairline()
                                ServerRow(server: server, selected: server.id == selected?.id) { selectedID = server.id }
                            }
                        }
                    }
                    if let selected { ServerDetail(server: selected) }
                }
                ScriptDisclosure()
            }
            .padding(.horizontal, Space.page + 4)
            .padding(.bottom, Space.page * 2)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .task {
            while !Task.isCancelled {
                await remote.refreshFleet()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

private struct ServerRow: View {
    @Environment(\.palette) private var palette
    @State private var hovering = false
    let server: Fleet.Server
    let selected: Bool
    let select: () -> Void

    var body: some View {
        let s = server.snapshot
        let stale = server.state != .ok
        HStack(spacing: Space.lg) {
            VStack(alignment: .leading, spacing: 1) {
                Text(server.name).font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color).lineLimit(1)
                Sensitive(text: "\(server.user)@\(server.host)", font: .mono(.xxs)).foregroundStyle(palette.ink3.color).lineLimit(1)
                Text(Fleet.stateLine(server)).font(.ui(.xxs))
                    .foregroundStyle((stale ? server.state.tone.color(palette) : palette.ink4).color)
                    .lineLimit(1).help(Fleet.stateLine(server))
            }
            .frame(width: 210, alignment: .leading)
            Group {
                FleetMeter(share: s?.loadShare, label: s?.load.map { String(format: "%.2f", $0[0]) + " on \(s?.cpus.map(String.init) ?? "?") CPUs" },
                           history: server.history.map(\.load))
                FleetMeter(share: s?.memShare, label: s.flatMap { snap in snap.memShare.map { "\(Int(($0 * 100).rounded()))% of \(LowtideKitFormat.bytes(snap.memTotal ?? 0))" } },
                           history: server.history.map(\.mem))
                FleetMeter(share: s?.diskShare, label: s.flatMap { snap in snap.diskShare.map { "\(Int(($0 * 100).rounded()))% of \(LowtideKitFormat.bytes(snap.diskTotal ?? 0))" } },
                           history: nil)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(stale ? 0.4 : 1)
            VStack(alignment: .leading, spacing: 1) {
                if let s {
                    Text("\(s.listeners.count) listening · \(s.peers.count) peers").foregroundStyle(palette.ink3.color)
                    Text(Fleet.countriesLabel(s.countries)).font(.mono(.xxs)).foregroundStyle(palette.ink2.color)
                    Text("\(LowtideKitFormat.count(s.users.count, "user")) · \(s.failedLogins.map { "\($0) failed" } ?? "? failed")")
                        .foregroundStyle(((s.failedLogins ?? 0) > 20 ? palette.warn : palette.ink3).color)
                } else {
                    Text("–").foregroundStyle(palette.ink4.color)
                }
            }
            .font(.ui(.xxs))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(stale ? 0.4 : 1)
            Text(server.rtt.map { "\($0) ms" } ?? "–")
                .font(.mono(.xxs)).monospacedDigit().foregroundStyle(palette.ink3.color)
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, 10)
        .overlay(alignment: .leading) { Rectangle().fill(edge.color).frame(width: 2) }
        .background((selected ? palette.selected : hovering ? palette.hover : ColorValue(r: 0, g: 0, b: 0, a: 0)).color)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(perform: select)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    var edge: ColorValue {
        switch server.state {
        case .ok: palette.ok.opacity(0.7)
        case .unreachable: palette.bad
        case .needsKey: palette.warn
        case .probing: palette.ink4
        }
    }
}

/// A value, a thin bar under it and a sparkline.
private struct FleetMeter: View {
    @Environment(\.palette) private var palette
    let share: Double?
    let label: String?
    let history: [Double]?

    var body: some View {
        if let share, let label {
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.mono(.xxs)).monospacedDigit().foregroundStyle(palette.ink2.color).lineLimit(1)
                Meter(value: min(max(share, 0), 1), tone: share > 0.9 ? .bad : share > 0.75 ? .warn : .brand, height: 4)
                if let history, history.count > 1 {
                    Sparkline(values: history, tone: .neutral).frame(height: 12)
                }
            }
        } else {
            Text("–").font(.mono(.xxs)).foregroundStyle(palette.ink4.color)
        }
    }
}

private struct ServerDetail: View {
    @Environment(\.palette) private var palette
    let server: Fleet.Server
    private var remote: RemoteStore { RemoteStore.shared }

    var facts: [String] {
        var out: [String] = []
        let s = server.snapshot
        if let hostname = s?.hostname, !hostname.isEmpty, hostname != server.host { out.append(hostname) }
        if let country = server.place?.country { out.append([country, server.place?.org].compactMap { $0 }.joined(separator: " ")) }
        if let s {
            out.append("\(s.cpus.map(String.init) ?? "?") CPUs")
            if let total = s.memTotal { out.append("\(LowtideKitFormat.bytes(total)) memory") }
            out.append("up \(Fleet.uptime(s.uptime))")
        }
        if let last = server.lastProbe { out.append("checked at \(last.formatted(date: .omitted, time: .shortened))") }
        return out
    }

    var body: some View {
        let host = remote.host(server.id)
        let busy = server.busy || remote.probing.contains(server.id)
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack(alignment: .bottom, spacing: Space.lg) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: Space.sm) {
                        Text(server.name).font(.ui(.lg, .semibold)).foregroundStyle(palette.ink.color)
                        Badge(server.state.label, tone: server.state.tone)
                    }
                    HStack(spacing: 0) {
                        Sensitive(text: "\(server.user)@\(server.host)", font: .mono(.xs))
                        Text(facts.map { " · \($0)" }.joined()).font(.ui(.xs))
                    }
                    .foregroundStyle(palette.ink3.color)
                    .lineLimit(1)
                }
                Spacer()
                Button(busy ? "Checking…" : "Check now") {
                    if let host { Task { await remote.probe(host) } }
                }
                .buttonStyle(.lowtide(.quiet, size: .small))
                .disabled(busy || host == nil)
                Button("Open SSH session") { if let host { remote.connect(host) } }
                    .buttonStyle(.lowtide(.secondary, size: .small))
                    .disabled(host == nil)
            }
            if let error = server.error, server.state != .ok {
                let stale = Text(server.snapshot != nil && server.lastOK != nil
                                 ? " Showing the last good snapshot from \(server.lastOK!.formatted(date: .omitted, time: .shortened))." : "")
                    .foregroundStyle(palette.ink4.color)
                Text("\(Text(error).foregroundStyle(server.state.tone.color(palette).color))\(stale)")
                    .font(.ui(.xs))
                    .frame(maxWidth: 640, alignment: .leading)
                    .textSelection(.enabled)
            }
            if let s = server.snapshot {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.xl, alignment: .top), GridItem(.flexible(), alignment: .top)],
                          alignment: .leading, spacing: Space.xl) {
                    Pane("Listening", subtitle: "\(s.listeners.count)") { EmptyView() } content: { listeners(s) }
                    Pane("Talking to", subtitle: "\(s.peers.count)" + (s.countries.isEmpty ? "" : " · " + s.countries.joined(separator: " "))) {
                        EmptyView()
                    } content: { peers(s) }
                    Pane("Logged in", subtitle: s.failedLogins.map { LowtideKitFormat.count($0, "failed login") + " an hour" } ?? "Failed logins unknown") {
                        EmptyView()
                    } content: { users(s) }
                    Pane("Unusual activity", subtitle: "\(server.events.count)") { EmptyView() } content: { events }
                }
            }
        }
    }

    private func nothing(_ text: String) -> some View {
        Text(text).font(.ui(.xs)).foregroundStyle(palette.ink3.color).padding(.horizontal, Space.lg).padding(.bottom, Space.md)
    }

    private func line<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(spacing: Space.md) { content() }
                .font(.ui(.xs))
                .lineLimit(1)
                .padding(.horizontal, Space.lg)
                .frame(minHeight: 28)
        }
    }

    @ViewBuilder private func listeners(_ s: Fleet.Snapshot) -> some View {
        if s.listeners.isEmpty {
            nothing("Nothing listening, or the server won't say.")
        } else {
            VStack(spacing: 0) {
                ForEach(s.listeners, id: \.self) { l in
                    line {
                        Text("\(l.proto)/\(l.port)").font(.mono(.xxs)).monospacedDigit().frame(width: 80, alignment: .leading)
                        Sensitive(text: l.address, font: .mono(.xxs)).foregroundStyle(palette.ink3.color)
                        Spacer()
                        Text(l.process ?? "–").foregroundStyle(palette.ink2.color)
                    }
                }
            }
        }
    }

    @ViewBuilder private func peers(_ s: Fleet.Snapshot) -> some View {
        if s.peers.isEmpty {
            nothing("No established connections.")
        } else {
            VStack(spacing: 0) {
                ForEach(s.peers.prefix(60), id: \.self) { p in
                    line {
                        HStack(spacing: 2) {
                            Sensitive(text: "\(p.ip):\(p.port)", font: .mono(.xxs))
                            if p.count > 1 { Text("×\(p.count)").font(.mono(.xxs)).foregroundStyle(palette.ink4.color) }
                        }
                        Spacer()
                        Text(p.country.map { "\($0) \(p.org ?? "")" } ?? "Local network").foregroundStyle(palette.ink3.color)
                        Text("\(p.process ?? "–") :\(p.localPort)").foregroundStyle(palette.ink2.color)
                    }
                }
            }
        }
    }

    @ViewBuilder private func users(_ s: Fleet.Snapshot) -> some View {
        if s.users.isEmpty {
            nothing("Nobody logged in.")
        } else {
            VStack(spacing: 0) {
                ForEach(s.users, id: \.self) { u in
                    line {
                        Sensitive(text: u.user, font: .mono(.xxs))
                        Text(u.tty).font(.mono(.xxs)).foregroundStyle(palette.ink3.color)
                        Sensitive(text: u.from ?? "console", font: .mono(.xxs)).foregroundStyle(palette.ink3.color)
                        Spacer()
                        Text(u.since).monospacedDigit().foregroundStyle(palette.ink4.color)
                    }
                }
            }
        }
    }

    @ViewBuilder private var events: some View {
        if server.events.isEmpty {
            nothing(server.learning ? "Learning what's normal: alerts start after three checks." : "Nothing unusual.")
        } else {
            VStack(spacing: 0) {
                ForEach(server.events.reversed()) { event in
                    line {
                        Text(event.t.formatted(date: .omitted, time: .shortened)).font(.mono(.xxs)).foregroundStyle(palette.ink4.color)
                        Text(event.text).foregroundStyle((event.severity == .alert ? palette.bad : palette.warn).color)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
}

/// What runs on each server, shown as it is.
private struct ScriptDisclosure: View {
    @Environment(\.palette) private var palette
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("One ssh call a minute per server. Without a saved password it runs in batch mode, so it never prompts; with one, only that password is answered. The script goes in on stdin to sh -s. It only reads: nothing is installed, written or left running.")
                    .font(.ui(.xs)).foregroundStyle(palette.ink3.color).fixedSize(horizontal: false, vertical: true)
                Text(Fleet.script)
                    .font(.mono(.xxs)).foregroundStyle(palette.ink2.color)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.md)
                    .background(palette.fill.color, in: .rect(cornerRadius: Radius.md))
            }
            .padding(.top, Space.sm)
        } label: {
            Text("What runs on each server").font(.ui(.xs)).foregroundStyle(palette.ink3.color)
        }
        .frame(maxWidth: 680, alignment: .leading)
    }
}

/// Pick the hosts the Fleet watches.
struct WatchSheet: View {
    @Environment(\.palette) private var palette
    private var remote = RemoteStore.shared
    let close: () -> Void

    init(close: @escaping () -> Void) { self.close = close }

    var body: some View {
        DevSheet("Watch hosts", description: "Watched hosts are read over SSH once a minute, signing in with a key, ssh-agent or a saved password.") {
            if remote.snapshot.hosts.isEmpty {
                Text("No saved hosts yet. Add one under All hosts, then watch it here.").font(.ui(.sm)).foregroundStyle(palette.ink3.color)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(remote.snapshot.hosts.enumerated()), id: \.element.id) { index, host in
                        if index > 0 { Hairline() }
                        Toggle(isOn: Binding(get: { remote.watched.contains(host.id) }, set: { _ in remote.toggleWatch(host) })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(host.name).font(.ui(.sm)).foregroundStyle(palette.ink.color)
                                Sensitive(text: "\(host.username)@\(host.hostname):\(host.port)", font: .mono(.xxs))
                                    .foregroundStyle(palette.ink3.color)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(.horizontal, Space.md)
                        .frame(minHeight: 44)
                    }
                }
                .card()
            }
        } footer: {
            Button("Done", action: close).buttonStyle(.primary).keyboardShortcut(.defaultAction)
        }
    }
}

extension Fleet.State {
    var label: String {
        switch self {
        case .ok: "Online"
        case .unreachable: "Unreachable"
        case .needsKey: "Can't sign in"
        case .probing: "Checking"
        }
    }

    var tone: Tone {
        switch self {
        case .ok: .ok
        case .unreachable: .bad
        case .needsKey: .warn
        case .probing: .neutral
        }
    }
}

extension Fleet {
    static func uptime(_ seconds: Int?) -> String {
        guard let seconds else { return "–" }
        let days = seconds / 86_400, hours = seconds % 86_400 / 3600
        return days > 0 ? "\(days)d \(hours)h" : "\(hours)h \(seconds % 3600 / 60)m"
    }

    static func countriesLabel(_ countries: [String], limit: Int = 4) -> String {
        guard !countries.isEmpty else { return "–" }
        let shown = countries.prefix(limit).joined(separator: " ")
        return countries.count > limit ? "\(shown) +\(countries.count - limit)" : shown
    }

    static func stateLine(_ server: Server) -> String {
        if server.state == .ok, let s = server.snapshot { return "\(s.os.isEmpty ? "Unknown OS" : s.os) · up \(uptime(s.uptime))" }
        if server.state == .probing { return "First check running…" }
        return server.error ?? server.state.label
    }
}
