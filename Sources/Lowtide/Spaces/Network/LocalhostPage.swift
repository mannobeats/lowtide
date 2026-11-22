import LowtideKit
import SwiftUI

/// Network → Localhost: every TCP service listening on this Mac, the
/// project and branch it runs from, who calls it, and whether it's open
/// to the network. Open one in the browser; stop one with a confirmation.
struct LocalhostPage: View {
    @Environment(\.palette) private var palette
    @State private var services: [LocalService]?
    @State private var selected: String?
    @State private var showSystem = false
    /// Kept by id so Stop acts on the live row, not the one the dialog opened on.
    @State private var stoppingID: String?
    @State private var now = Millis.now

    var body: some View {
        let all = services ?? []
        let yours = all.filter { !$0.system }
        let system = all.filter(\.system)
        let exposed = yours.filter(\.exposed).count
        let projects = Set(yours.compactMap(\.project)).count
        VStack(spacing: 0) {
            PageHeader("Localhost", description: services == nil ? nil
                       : "\(LowtideFormat.count(yours.count, "service")) in \(LowtideFormat.count(projects, "project")) · \(exposed) open to the network",
                       compact: true)
            if services == nil {
                ScanningState(title: "Reading what listens on this Mac…")
            } else if all.isEmpty {
                EmptyState("Nothing listening", symbol: "network.slash",
                           message: "Nothing on this Mac accepts TCP connections right now. Start a dev server and it shows up here.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.xl) {
                        if !yours.isEmpty {
                            MissionPane("Map", expandable: true) {
                                Text("Who calls what")
                            } content: { _ in
                                LocalhostTopology(services: yours, selected: $selected)
                            }
                            MissionPane("Your services", flush: true) {
                                Text("\(yours.count)")
                            } content: { _ in
                                list(yours)
                            }
                        }
                        if !system.isEmpty {
                            MissionPane("System services", flush: true) {
                                Button(showSystem ? "Hide" : "Show \(system.count)") { withAnimation(Motion.base) { showSystem.toggle() } }
                                    .buttonStyle(.plain).foregroundStyle(palette.ink3.color)
                            } content: { _ in
                                if showSystem {
                                    list(system)
                                } else {
                                    Text("macOS and other users: \(Array(Set(system.map(\.name))).sorted().joined(separator: ", "))")
                                        .font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                                        .padding(.horizontal, Space.lg).padding(.bottom, Space.sm)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Space.page + 4)
                    .padding(.bottom, Space.page * 2)
                    .frame(maxWidth: 1180)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .watchesNetwork()
        .task {
            while !Task.isCancelled {
                services = await Task.detached { Localhost.services() }.value
                now = .now
                if let id = stoppingID, services?.contains(where: { $0.id == id }) == false {
                    stoppingID = nil
                    Toasts.shared.show("That service already stopped.", tone: .neutral)
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .confirmationDialog("Stop this service?", isPresented: Binding(get: { stoppingID != nil }, set: { if !$0 { stoppingID = nil } }),
                            presenting: all.first { $0.id == stoppingID }) { service in
            Button("Stop", role: .destructive) { stop(service, force: false) }
            Button("Force Quit") { stop(service, force: true) }
            Button("Cancel", role: .cancel) {}
        } message: { service in
            Text("\(service.kind ?? service.name) on :\(String(service.port)), PID \(String(service.pid))\(service.project.map { " in \($0)" } ?? ""). Stop asks the process to exit. Force Quit ends it at once, and it can lose unsaved work.")
        }
    }

    private func stop(_ service: LocalService, force: Bool) {
        do {
            try Localhost.stop(pid: service.pid, force: force)
            Toasts.shared.show("Stopped :\(service.port)")
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                services = await Task.detached { Localhost.services() }.value
            }
        } catch {
            Toasts.shared.failure("Couldn't stop :\(service.port)", error)
        }
        stoppingID = nil
    }

    /// Services grouped by project, groups in order of their lowest port.
    private func list(_ services: [LocalService]) -> some View {
        var groups: [(String, [LocalService])] = []
        for service in services {
            if let i = groups.firstIndex(where: { $0.0 == service.group }) { groups[i].1.append(service) } else { groups.append((service.group, [service])) }
        }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(groups, id: \.0) { group, items in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Text(group).font(.ui(.xs, .semibold)).foregroundStyle(palette.ink2.color)
                        if let branch = items.first?.branch { Text(branch).font(.mono(.xxs)).foregroundStyle(palette.ink4.color) }
                    }
                    .padding(.horizontal, Space.lg)
                    .padding(.top, Space.md)
                    .padding(.bottom, 6)
                    ForEach(items) { service in
                        ServiceRow(service: service, now: now, open: selected == service.id,
                                   onSelect: { withAnimation(Motion.base) { selected = selected == service.id ? nil : service.id } },
                                   onStop: { stoppingID = service.id })
                    }
                }
                .hairline(.top)
            }
        }
    }
}

private struct ServiceRow: View {
    @Environment(\.palette) private var palette
    let service: LocalService
    let now: Millis
    let open: Bool
    let onSelect: () -> Void
    let onStop: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onSelect) {
                HStack(spacing: Space.lg) {
                    Text(verbatim: ":\(service.port)").font(.mono(.base, .medium)).monospacedDigit()
                        .foregroundStyle((open ? palette.brand : palette.ink).color).frame(width: 72, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 0) {
                            Text(service.kind ?? service.name).font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color)
                            if let kind = service.kind, kind.lowercased() != service.name.lowercased() {
                                Text(" · \(service.name)").font(.ui(.sm)).foregroundStyle(palette.ink3.color)
                            }
                        }
                        .lineLimit(1)
                        Text("\(service.branch.map { "On \($0) · " } ?? "")PID \(String(service.pid))\(service.started.map { " · up \(Localhost.uptime($0, now: now))" } ?? "")")
                            .font(.ui(.xs)).foregroundStyle(palette.ink3.color).lineLimit(1)
                    }
                    Spacer(minLength: Space.sm)
                    if !service.exposedBinds.isEmpty {
                        Badge("Open to the network", tone: .warn).help("Listening on \(service.exposedBinds.joined(separator: ", "))")
                    }
                    Text(LowtideFormat.count(service.clients.count, "client")).font(.ui(.xs)).monospacedDigit()
                        .foregroundStyle(palette.ink3.color).frame(width: 72, alignment: .trailing)
                }
                .padding(.horizontal, Space.lg)
                .frame(minHeight: 48)
                .background((open ? palette.selected : hovering ? palette.hover : ColorValue(r: 0, g: 0, b: 0, a: 0)).color)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .contextMenu { menu }
            if open { detail.transition(.opacity) }
        }
        .hairline(.top)
    }

    @ViewBuilder
    private var menu: some View {
        if service.httpish { Button("Open in Browser") { openBrowser() } }
        Button("Copy Port") { copy(String(service.port)) }
        Button("Copy URL") { copy("http://localhost:\(service.port)") }
        if let folder = service.projectRoot ?? service.cwd {
            Button("Reveal Folder") { Files.reveal([folder]) }
        }
        if !(service.system || service.own) {
            Divider()
            Button("Stop…", role: .destructive, action: onStop)
        }
    }

    private func openBrowser() {
        if let url = URL(string: "http://localhost:\(service.port)") { NSWorkspace.shared.open(url) }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let command = service.command { field("Command", command) }
            if let path = service.path { field("Program", Paths.tilde(path)) }
            if let folder = service.projectRoot ?? service.cwd { field("Folder", Paths.tilde(folder)) }
            field("Listens on", service.binds.joined(separator: "  "))
            field("Traffic", "\(LowtideFormat.bytes(service.bytesIn)) in · \(LowtideFormat.bytes(service.bytesOut)) out · \(service.conns) open", mono: false)
            ForEach(service.clients) { client in
                HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                    Text("Client").foregroundStyle(palette.ink3.color).frame(width: 80, alignment: .leading)
                    Text("\(Text(client.name).foregroundStyle(palette.ink2.color))  \(Text("PID \(Text(String(client.pid)).font(.mono(.xxs)))").foregroundStyle(palette.ink4.color))")
                        .lineLimit(1)
                    Spacer()
                    Text("\(client.conns) open · \(LowtideFormat.bytes(client.bytes))").foregroundStyle(palette.ink3.color).monospacedDigit()
                }
                .font(.ui(.xs))
            }
            HStack(spacing: 6) {
                if service.httpish { Button("Open in Browser", action: openBrowser).buttonStyle(.lowtide(.secondary, size: .small)) }
                if let folder = service.projectRoot ?? service.cwd {
                    Button("Reveal Folder") { Files.reveal([folder]) }
                        .buttonStyle(.lowtide(.secondary, size: .small))
                }
                Button("Copy Port") { copy(String(service.port)) }.buttonStyle(.lowtide(.secondary, size: .small))
                Spacer()
                if !(service.system || service.own) {
                    Button("Stop…", action: onStop).buttonStyle(.lowtide(.destructive, size: .small))
                }
            }
            .padding(.top, Space.sm)
        }
        .padding(.leading, 72 + Space.lg * 2)
        .padding(.trailing, Space.lg)
        .padding(.vertical, Space.md)
        .hairline(.top)
    }

    private func field(_ label: String, _ value: String, mono: Bool = true) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            Text(label).font(.ui(.xs)).foregroundStyle(palette.ink3.color).frame(width: 80, alignment: .leading)
            Text(value).font(mono ? .mono(.xxs) : .ui(.xs)).foregroundStyle(palette.ink2.color)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// Who calls whom on this Mac: processes on the left, services to the
/// right of their callers (web, then API, then the database). Services
/// reachable from the network wear an amber ring.
struct LocalhostTopology: View {
    @Environment(\.palette) private var palette
    let services: [LocalService]
    @Binding var selected: String?

    struct Node: Identifiable {
        var id: String
        var column: Int
        var exposed: Bool
        var group: String
        var label: String
        var sub: String
        var service: Bool
        var point = CGPoint.zero
    }

    struct Edge: Hashable {
        var from: String
        var to: String
        var live: Bool
    }

    private static let row = 66.0
    private static let pad = 24.0
    /// A depth wraps into sub-columns this tall, so twenty services stay a block, not a tower.
    private static let maxRows = 5
    private static let subColumn = 190.0
    private static let columnGap = 140.0

    static func build(_ services: [LocalService]) -> ([Node], [Edge]) {
        var byPid: [Int32: LocalService] = [:]
        for service in services where byPid[service.pid] == nil { byPid[service.pid] = service }
        // Column per service: one right of the furthest service that calls it.
        var column = Dictionary(uniqueKeysWithValues: services.map { ($0.id, 1) })
        for _ in 0..<4 {
            for service in services {
                for client in service.clients {
                    if let caller = byPid[client.pid], caller.id != service.id {
                        column[service.id] = max(column[service.id] ?? 1, min(4, (column[caller.id] ?? 1) + 1))
                    }
                }
            }
        }
        var nodes: [String: Node] = [:]
        var edges: [Edge] = []
        for service in services {
            nodes[service.id] = Node(id: service.id, column: column[service.id] ?? 1, exposed: service.exposed, group: service.group,
                                     label: ":\(service.port)", sub: [service.kind ?? service.name, service.project].compactMap { $0 }.joined(separator: " · "),
                                     service: true)
            for client in service.clients {
                let from = byPid[client.pid]?.id ?? "p:\(client.pid)"
                if byPid[client.pid] == nil, nodes[from] == nil {
                    nodes[from] = Node(id: from, column: 0, exposed: false, group: "", label: client.name, sub: "PID \(client.pid)", service: false)
                }
                if from != service.id { edges.append(Edge(from: from, to: service.id, live: client.conns > 0)) }
            }
        }
        return (Array(nodes.values), Array(Set(edges)))
    }

    /// Positions, and the size they need.
    static func place(_ raw: [Node]) -> ([Node], CGSize) {
        let depths = Array(Set(raw.map(\.column))).sorted()
        var placed: [Node] = []
        var x = pad
        var tallest = 1
        for depth in depths {
            let nodes = raw.filter { $0.column == depth }.sorted { ($0.group, $0.label) < ($1.group, $1.label) }
            tallest = max(tallest, min(maxRows, nodes.count))
            let subs = Int((Double(nodes.count) / Double(maxRows)).rounded(.up))
            for (i, node) in nodes.enumerated() {
                var node = node
                node.point = CGPoint(x: x + Double(i / maxRows) * subColumn, y: pad + 24 + Double(i % maxRows) * row)
                placed.append(node)
            }
            x += Double(subs) * subColumn + columnGap
        }
        return (placed, CGSize(width: x - columnGap + pad, height: pad * 2 + 24 + Double(tallest - 1) * row + 30))
    }

    var body: some View {
        let (raw, edges) = Self.build(services)
        let (nodes, size) = Self.place(raw)
        ScrollView(.horizontal) {
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    let at = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.point) })
                    for edge in edges {
                        guard let a = at[edge.from], let b = at[edge.to] else { continue }
                        var path = Path()
                        path.move(to: a)
                        let mid = (a.x + b.x) / 2
                        path.addCurve(to: b, control1: CGPoint(x: mid, y: a.y), control2: CGPoint(x: mid, y: b.y))
                        let hot = selected == edge.to || selected == edge.from
                        let tone = hot ? palette.brand : edge.live ? palette.brand.opacity(0.7) : palette.lineStrong
                        context.stroke(path, with: .color(tone.color), style: StrokeStyle(lineWidth: 1, dash: edge.live ? [] : [3, 3]))
                    }
                }
                ForEach(nodes) { node in
                    NodeMark(node: node, active: node.id == selected)
                        .offset(x: node.point.x - 9, y: node.point.y - 28)
                        .onTapGesture { if node.service { selected = selected == node.id ? nil : node.id } }
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .scrollIndicators(.automatic)
        .frame(height: size.height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Local service topology")
    }
}

private struct NodeMark: View {
    /// A sub-column, less the gap that keeps names apart.
    static let width = 174.0
    @Environment(\.palette) private var palette
    let node: LocalhostTopology.Node
    let active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(node.label).font(node.service ? .mono(.xs) : .ui(.xs))
                .foregroundStyle((active ? palette.brand : palette.ink).color).lineLimit(1)
                .background(palette.surface.color.padding(-2))
            ZStack {
                if node.exposed { Circle().strokeBorder(palette.warn.color, lineWidth: 1).frame(width: 16, height: 16) }
                Circle().fill((node.service ? palette.surface : palette.fill).color)
                    .overlay(Circle().strokeBorder((active ? palette.brand : palette.ink3).color, lineWidth: 1))
                    .frame(width: node.service ? 9 : 6, height: node.service ? 9 : 6)
            }
            .frame(width: 18, height: 18)
            // A name never runs into the next column: the warning shortens
            // to its icon before the name is cut.
            ViewThatFits(in: .horizontal) {
                Text(node.exposed ? "\(node.sub) · open to the network" : node.sub)
                HStack(spacing: 3) {
                    if node.exposed { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8)) }
                    Text(node.sub).truncationMode(.middle)
                }
            }
            .font(.ui(.xxs))
            .foregroundStyle((node.exposed ? palette.warn : palette.ink4).color).lineLimit(1)
            // Links run under the names, not through them.
            .background(palette.surface.color.padding(-2))
        }
        .frame(width: Self.width, alignment: .leading)
        .contentShape(.rect)
        .help(node.service ? "Select \(node.label)" + (node.exposed ? " (\(node.sub), open to the network)" : "") : node.sub)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(node.service ? .isButton : [])
    }
}
