import LowtideKit
import SwiftUI

/// Width of the details card when it floats over a narrow map.
let dossierWidth = 340.0

/// Everything about what the map is locked on: an app's file, a country's
/// servers, the nearby edge, or this Mac. In the side column when there's
/// room, floating over the map when not.
struct Dossier: View {
    @Environment(\.palette) private var palette
    let target: MapTarget
    let edges: [NetEdge]
    let floating: Bool
    let onClose: () -> Void
    let onLock: (MapTarget) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Group {
                    switch target {
                    case .app(let name): AppFile(name: name, onLock: onLock)
                    case .country(let code): PlaceFile(code: code, edges: edges, onLock: onLock)
                    case .nearby: NearbyFile(edges: edges, onLock: onLock)
                    case .home: HomeFile()
                    }
                }
                .id(target)
            }
            .scrollIndicators(.automatic)
        }
        .overlay(alignment: .topTrailing) {
            IconButton("xmark", help: "Close (Esc)", action: onClose).padding(Space.sm)
        }
        .modifier(DossierFrame(floating: floating))
        .transition(.opacity.combined(with: .offset(y: 4)))
    }
}

private struct DossierFrame: ViewModifier {
    let floating: Bool
    func body(content: Content) -> some View {
        if floating {
            content.frame(width: dossierWidth).flatSurface(radius: Radius.lg)
        } else {
            content
        }
    }
}

/// A titled block of a dossier.
private struct Section<Content: View>: View {
    @Environment(\.palette) private var palette
    let title: String
    var meta: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Text(title).font(.ui(.xs, .semibold)).foregroundStyle(palette.ink2.color)
                Spacer()
                if let meta { Text(meta).font(.ui(.xxs)).foregroundStyle(palette.ink3.color).monospacedDigit().lineLimit(1) }
            }
            content
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .hairline(.top)
    }
}

/// Three figures under a header, labels above values.
private struct Figures: View {
    @Environment(\.palette) private var palette
    let items: [(String, String)]
    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            ForEach(items, id: \.0) { label, value in
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.ui(.xxs)).foregroundStyle(palette.ink3.color)
                    Text(value).font(.mono(.sm)).monospacedDigit().foregroundStyle(palette.ink.color).lineLimit(1)
                        .contentTransition(.numericText())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .hairline(.top)
    }
}

private struct Header: View {
    @Environment(\.palette) private var palette
    let title: String
    let subtitle: String
    var badge: (String, Tone)?
    var icon: String?

    var body: some View {
        HStack(spacing: Space.md) {
            if let icon { AppGlyph(path: icon, size: 40) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.ui(.lg, .semibold)).foregroundStyle(palette.ink.color).lineLimit(1).textSelection(.enabled)
                Text(subtitle).font(.ui(.xs)).foregroundStyle(palette.ink3.color).lineLimit(2)
            }
            Spacer(minLength: Space.sm)
            if let badge { Badge(badge.0, tone: badge.1) }
        }
        .padding(.leading, Space.lg)
        .padding(.trailing, 44)
        .padding(.top, Space.lg)
        .padding(.bottom, Space.md)
    }
}

// MARK: App

private struct AppFile: View {
    @Environment(\.palette) private var palette
    let name: String
    let onLock: (MapTarget) -> Void
    @State private var dossier: NetDossier?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let dossier {
                content(dossier)
            } else {
                Text(loaded ? "\(name) went quiet." : "Reading \(name)…")
                    .font(.ui(.sm)).foregroundStyle(palette.ink3.color).padding(Space.lg)
            }
        }
        .task(id: name) {
            let engine = NetworkEngine.shared
            while !Task.isCancelled {
                let found = await Task.detached { engine.dossier(app: name) }.value
                dossier = found
                loaded = true
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    @ViewBuilder
    private func content(_ d: NetDossier) -> some View {
        let app = d.app
        let model = NetworkModel.shared
        Header(title: app.name, subtitle: app.signature.label, badge: NetFormat.level(app.score), icon: app.app ?? app.path)
        Figures(items: [("Now", NetFormat.rate(app.rate)), ("Servers", "\(app.hosts)"),
                        ("First online", d.firstSeen.map { LowtideFormat.ago($0.date) } ?? "Unknown")])
        Section(title: "Why this score", meta: "\(app.score) of 100") {
            if app.reasons.isEmpty {
                Text("Nothing unusual about it.").font(.ui(.xs)).foregroundStyle(palette.ink3.color)
            }
            ForEach(app.reasons, id: \.label) { reason in
                HStack(alignment: .firstTextBaseline) {
                    Text(reason.label).font(.ui(.xs)).foregroundStyle(palette.ink2.color).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Text("+\(reason.points)").font(.mono(.xs)).foregroundStyle(palette.ink3.color)
                }
            }
        }
        Section(title: "Traffic", meta: d.usualOut.map { "Usually sends \(LowtideFormat.bytes(Int64($0)))/min" } ?? "Last hour") {
            History(points: d.history)
            Text("Received \(LowtideFormat.bytes(app.bytesIn)), sent \(LowtideFormat.bytes(app.bytesOut)) since watching")
                .font(.ui(.xs)).foregroundStyle(palette.ink3.color).monospacedDigit()
        }
        Section(title: "Rhythm") { Rhythm(intervals: d.intervals) }
        Section(title: "Servers", meta: "\(d.hosts.count) now · \(NetFormat.countries(d.countriesKnown)) ever") {
            ForEach(d.hosts.prefix(14)) { host in
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Sensitive(text: host.host, font: .mono(.xs)).foregroundStyle(palette.ink.color).lineLimit(1)
                        Spacer()
                        Text(host.rateIn + host.rateOut > 0 ? NetFormat.rate(host.rateIn + host.rateOut) : LowtideFormat.bytes(host.bytesIn + host.bytesOut))
                            .font(.mono(.xs)).monospacedDigit().foregroundStyle(palette.ink2.color)
                    }
                    HStack {
                        Text([host.country.map { WorldData.shared.name($0) } ?? "Local network", host.org, host.service ?? "port \(host.port)"]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.ui(.xxs)).foregroundStyle(palette.ink3.color).lineLimit(1)
                        Spacer()
                        Text(NetFormat.ms(host.rttMs)).font(.mono(.xxs)).foregroundStyle(palette.ink4.color)
                    }
                }
                .contextMenu {
                    Button("Copy host") { copy(host.host) }
                    Button("Copy address") { copy(host.ip) }
                    Button("Show its packets") { showPackets("host:\(host.ip)") }
                    if let country = host.country { Button("Show \(WorldData.shared.name(country)) on the map") { onLock(.country(country)) } }
                }
            }
        }
        Section(title: "Process tree", meta: app.pids.map(String.init).joined(separator: ", ")) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(d.processes.enumerated()), id: \.offset) { index, proc in
                    HStack(spacing: 6) {
                        if index > 0 { Text("└").foregroundStyle(palette.ink4.color) }
                        Text(proc.name).foregroundStyle((proc.own ? palette.ink : palette.ink3).color).lineLimit(1)
                        Text(String(proc.pid)).foregroundStyle(palette.ink4.color)
                    }
                    .font(.mono(.xxs))
                    .padding(.leading, Double(min(index, 6)) * 12)
                }
            }
            if let path = app.app ?? app.path {
                Sensitive(text: Paths.tilde(path), font: .mono(.xxs)).foregroundStyle(palette.ink4.color)
            }
        }
        if !d.events.isEmpty {
            Section(title: "Events", meta: "\(d.events.count)") {
                ForEach(d.events) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(NetFormat.clock(event.t)).font(.mono(.xxs)).foregroundStyle(palette.ink4.color)
                        Circle().fill((event.severity == .alert ? palette.bad : palette.warn).color).frame(width: 6, height: 6)
                        Text(event.text).font(.ui(.xs)).foregroundStyle(palette.ink2.color).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        HStack(spacing: Space.sm) {
            Button("Connections") {
                model.connectionsQuery = app.name
                model.liveView = .connections
            }
            .buttonStyle(.lowtide(.secondary, size: .small))
            Button("Packets") { showPackets("app:\(app.name)") }.buttonStyle(.lowtide(.secondary, size: .small))
            Spacer()
            if let path = app.app ?? app.path {
                IconButton("folder", help: "Show in Finder") {
                    Files.reveal([path])
                }
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .hairline(.top)
    }
}

func copy(_ text: String) {
    Files.copy(text)
}

func showPackets(_ filter: String) {
    NetworkModel.shared.packetQuery = filter
    AppModel.shared.open(.packets)
}

/// Traffic over the last hour: download filled, upload as a line.
private struct History: View {
    @Environment(\.palette) private var palette
    let points: [TimelinePoint]
    var body: some View {
        if points.count < 2 {
            Text("Collecting history…").font(.ui(.xs)).foregroundStyle(palette.ink3.color)
        } else {
            Canvas { context, size in
                let t0 = points[0].t
                let span = Double(max(1, points.last!.t - t0))
                let peak = Double(max(1, points.map { max($0.rateIn, $0.rateOut) }.max() ?? 1))
                let x = { (t: Millis) in Double(t - t0) / span * size.width }
                let y = { (v: Int64) in size.height - Double(v) / peak * (size.height - 2) }
                var down = Path(), up = Path()
                down.move(to: CGPoint(x: 0, y: size.height))
                for (i, p) in points.enumerated() {
                    down.addLine(to: CGPoint(x: x(p.t), y: y(p.rateIn)))
                    if i == 0 { up.move(to: CGPoint(x: x(p.t), y: y(p.rateOut))) } else { up.addLine(to: CGPoint(x: x(p.t), y: y(p.rateOut))) }
                }
                down.addLine(to: CGPoint(x: size.width, y: size.height))
                down.closeSubpath()
                context.fill(down, with: .color(palette.ok.opacity(0.1).color))
                context.stroke(down, with: .color(palette.ok.color), lineWidth: 1)
                context.stroke(up, with: .color(palette.brand.color), lineWidth: 1.2)
            }
            .frame(height: 48)
            .accessibilityLabel("Traffic over the last hour")
        }
    }
}

/// The gaps between connections it opened to the same server. A beacon
/// shows as one tall bar: it calls home on a timer.
private struct Rhythm: View {
    @Environment(\.palette) private var palette
    let intervals: [Double]
    static let bins: [Double] = [1, 2, 5, 10, 20, 30, 60, 120, 300, 600, 1800]

    var body: some View {
        if intervals.count < 3 {
            Text("Too few repeat connections to see a rhythm.").font(.ui(.xs)).foregroundStyle(palette.ink3.color)
        } else {
            let counts = Self.bins.indices.map { i in
                intervals.filter { gap in (Self.bins.firstIndex { gap < $0 * 1.5 } ?? Self.bins.count - 1) == i }.count
            }
            let peak = max(1, counts.max() ?? 1)
            let mean = intervals.reduce(0, +) / Double(intervals.count)
            let spread = sqrt(intervals.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(intervals.count)) / max(mean, 0.001)
            let regular = spread < 0.15 && mean >= 4
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(Array(counts.enumerated()), id: \.offset) { i, count in
                        Rectangle()
                            .fill((count == peak && regular ? palette.bad : palette.ink4.opacity(0.6)).color)
                            .frame(height: max(count > 0 ? 4 : 1, 48 * Double(count) / Double(peak)))
                            .help("\(count) gaps near \(Int(Self.bins[i])) s")
                    }
                }
                .frame(height: 48, alignment: .bottom)
                HStack {
                    ForEach(["1s", "10s", "1m", "10m", "30m"], id: \.self) { mark in
                        Text(mark).font(.ui(.xxs)).foregroundStyle(palette.ink4.color)
                        if mark != "30m" { Spacer() }
                    }
                }
                Text(regular ? "Regular: every ~\(Int(mean.rounded())) s. Timed check-ins look like a beacon."
                     : "Irregular, like normal use (\(intervals.count) gaps).")
                    .font(.ui(.xs)).foregroundStyle((regular ? palette.bad : palette.ink3).color)
            }
        }
    }
}

// MARK: Places

/// Apps and servers of one group of edges.
private struct Servers: View {
    @Environment(\.palette) private var palette
    let edges: [NetEdge]
    let onLock: (MapTarget) -> Void

    var body: some View {
        let byApp = Dictionary(grouping: edges, by: \.app).sorted { $0.key < $1.key }
        Section(title: "Apps talking to it") {
            ForEach(byApp, id: \.key) { app, list in
                HUDRow { onLock(.app(app)) } content: {
                    Text(app).font(.ui(.sm)).foregroundStyle(palette.ink.color).lineLimit(1)
                    Spacer()
                    Text(NetFormat.rate(list.reduce(0) { $0 + $1.rateIn + $1.rateOut })).font(.mono(.xs)).foregroundStyle(palette.ink3.color)
                }
                .frame(height: 30)
                .padding(.horizontal, -Space.sm)
            }
        }
        Section(title: "Servers") {
            ForEach(edges) { edge in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Sensitive(text: edge.host, font: .mono(.xs)).foregroundStyle(palette.ink.color).lineLimit(1)
                        Text([edge.org, edge.country.map { WorldData.shared.name($0) }].compactMap { $0 }.joined(separator: " · "))
                            .font(.ui(.xxs)).foregroundStyle(palette.ink3.color).lineLimit(1)
                    }
                    Spacer()
                    Text(NetFormat.ms(edge.rttMs)).font(.mono(.xxs)).foregroundStyle(palette.ink4.color)
                }
                .contextMenu {
                    Button("Copy host") { copy(edge.host) }
                    Button("Show its packets") { showPackets("host:\(edge.ip.isEmpty ? edge.host : edge.ip)") }
                }
            }
        }
    }
}

private func owners(_ edges: [NetEdge]) -> [String] {
    var rate: [String: Int64] = [:]
    for edge in edges { rate[edge.org ?? "Unknown owner", default: 0] += edge.rateIn + edge.rateOut + 1 }
    return rate.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
}

/// A country's servers: who runs them and which apps reach them.
private struct PlaceFile: View {
    @Environment(\.palette) private var palette
    let code: String
    let edges: [NetEdge]
    let onLock: (MapTarget) -> Void

    var body: some View {
        let model = NetworkModel.shared
        let margin = model.home.uncertaintyKm + 150
        let mine = edges.filter { $0.country == code && !isNearby($0, margin: margin) }
        let list = owners(mine)
        VStack(alignment: .leading, spacing: 0) {
            Header(title: WorldData.shared.name(code), subtitle: list.isEmpty ? "No servers right now" : list.joined(separator: ", "))
            Figures(items: [("Now", NetFormat.rate(mine.reduce(0) { $0 + $1.rateIn + $1.rateOut })),
                            ("Apps", "\(Set(mine.map(\.app)).count)"), ("Servers", "\(mine.count)")])
            if let best = mine.compactMap(\.rttMs).min(), let label = WorldData.shared.countries[code]?.label,
               model.home.point.distance(to: label) > best * Plausibility.kmPerMs + margin {
                Text("Drawn at the nearest part of \(WorldData.shared.name(code)) in reach: its servers answer in \(NetFormat.ms(best)), so they're within about \(Int(best * Plausibility.kmPerMs).formatted()) km of you.")
                    .font(.ui(.xs)).foregroundStyle(palette.ink3.color).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.lg).padding(.vertical, Space.md).hairline(.top)
            }
            Servers(edges: mine, onLock: onLock)
        }
    }

    private func isNearby(_ edge: NetEdge, margin: Double) -> Bool {
        if case .nearby = Plausibility.check(home: NetworkModel.shared.home.point, country: edge.country, rttMs: edge.rttMs, margin: margin) {
            return true
        }
        return false
    }
}

/// Servers that answer too fast to be where they're registered.
private struct NearbyFile: View {
    @Environment(\.palette) private var palette
    let edges: [NetEdge]
    let onLock: (MapTarget) -> Void

    var body: some View {
        let model = NetworkModel.shared
        let margin = model.home.uncertaintyKm + 150
        let mine = edges.filter { edge in
            if case .nearby = Plausibility.check(home: model.home.point, country: edge.country, rttMs: edge.rttMs, margin: margin) { return true }
            return false
        }
        let registered = Array(Set(mine.compactMap(\.country))).sorted().map { WorldData.shared.name($0) }
        let slowest = mine.compactMap(\.rttMs).max() ?? 0
        if mine.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Header(title: "Nearby edge", subtitle: "No servers right now")
                Text("Servers that answer too fast to be where their addresses are registered appear here, beside this Mac. Anycast networks like Cloudflare and Google do that: they answer from the data centre closest to you.")
                    .font(.ui(.xs)).foregroundStyle(palette.ink3.color).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.lg).padding(.vertical, Space.md).hairline(.top)
            }
        } else {
        VStack(alignment: .leading, spacing: 0) {
            Header(title: "Nearby edge", subtitle: owners(mine).joined(separator: ", "))
            Figures(items: [("Now", NetFormat.rate(mine.reduce(0) { $0 + $1.rateIn + $1.rateOut })),
                            ("Apps", "\(Set(mine.map(\.app)).count)"), ("Within", "\(Int(slowest * Plausibility.kmPerMs).formatted()) km")])
            Text("These servers answer in \(NetFormat.ms(slowest)) or less, so they're within about \(Int(slowest * Plausibility.kmPerMs).formatted()) km of you, though their addresses are registered in \(registered.formatted(.list(type: .and))). Networks like Cloudflare and Google answer from the data centre closest to you, so they're drawn here, beside this Mac.")
                .font(.ui(.xs)).foregroundStyle(palette.ink3.color).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Space.lg).padding(.vertical, Space.md).hairline(.top)
            Servers(edges: mine, onLock: onLock)
        }
        }
    }
}

// MARK: This Mac

/// Where this Mac is and how it reaches the internet. The city is the
/// person's choice; without one the map centres on the time zone and
/// names no city.
private struct HomeFile: View {
    @Environment(\.palette) private var palette
    private var model = NetworkModel.shared

    var body: some View {
        let home = model.home
        VStack(alignment: .leading, spacing: 0) {
            Header(title: "This Mac", subtitle: home.city.map { "In \($0.name), \(WorldData.shared.name($0.country))" }
                   ?? "No city set: the map centres on your time zone")
            Section(title: "Where it is") {
                CityPicker(selection: home.city) { model.setHome($0) }
                Text("Used only on this Mac, to judge how far servers can be from their round trip and to draw this Mac on the map.")
                    .font(.ui(.xxs)).foregroundStyle(palette.ink4.color).fixedSize(horizontal: false, vertical: true)
            }
            Section(title: "Connection") {
                KeyValueRow("Interface", model.link.interface.map { "\($0)\(model.link.vpn ? " (tunnel)" : "")" } ?? "Offline", mono: true)
                    .padding(.horizontal, -Space.lg)
                KeyValueRow("Address", AppModel.shared.privacy && model.link.ip != nil ? "•••••" : model.link.ip ?? "None", mono: true)
                    .padding(.horizontal, -Space.lg)
                KeyValueRow("Gateway", model.link.gateway ?? "None", mono: true).padding(.horizontal, -Space.lg)
                KeyValueRow("DNS", model.link.dns ?? "None", mono: true).padding(.horizontal, -Space.lg)
            }
        }
    }
}

/// A search over the bundled cities.
struct CityPicker: View {
    @Environment(\.palette) private var palette
    let selection: City?
    let onPick: (City?) -> Void
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                FilterField(text: $query, prompt: selection.map { "\($0.name), \($0.country)" } ?? "Search for your city")
                if selection != nil {
                    Button("Clear") { onPick(nil) }.buttonStyle(.lowtide(.quiet, size: .small)).help("Forget the city; use the time zone")
                }
            }
            let results = City.search(query).prefix(6)
            if !query.isEmpty, results.isEmpty {
                Text("No city by that name. Try a larger one nearby.").font(.ui(.xs)).foregroundStyle(palette.ink3.color)
            }
            ForEach(Array(results)) { city in
                HUDRow {
                    onPick(city)
                    query = ""
                } content: {
                    Text(city.name).font(.ui(.sm)).foregroundStyle(palette.ink.color)
                    Text(WorldData.shared.name(city.country)).font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                    Spacer()
                }
                .frame(height: 28)
                .padding(.horizontal, -Space.sm)
            }
        }
    }
}
