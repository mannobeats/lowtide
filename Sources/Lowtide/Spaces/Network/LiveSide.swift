import LowtideKit
import SwiftUI

/// Beside the map when there's room, under it when not: what needs a
/// look, the traffic, the busiest apps and the connections as they open.
/// Events live on the timeline, not here, so nothing shows twice.
struct LiveSide: View {
    @Environment(\.palette) private var palette
    let overview: NetOverview
    let flagged: [NetApp]
    let onLock: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NeedsALook(apps: overview.apps, flagged: flagged, onLock: onLock)
            Hairline()
            Readings(series: overview.series, capturing: overview.capture.running)
            Hairline()
            Busiest(apps: overview.apps, onLock: onLock)
            Hairline()
            Opened(conns: overview.recent, onLock: onLock)
        }
        .padding(.vertical, Space.xs)
    }
}

/// Only apps above the flag line: the same list the hero counts. Lower
/// scores are in each app's dossier.
private struct NeedsALook: View {
    @Environment(\.palette) private var palette
    let apps: [NetApp]
    let flagged: [NetApp]
    let onLock: (String) -> Void

    var body: some View {
        HUDSection("Needs a look") {
            if flagged.isEmpty { Text("All clear") } else { Text("\(flagged.count) flagged").foregroundStyle(palette.warn.color) }
        } content: {
            if flagged.isEmpty {
                Text("\(LowtideFormat.count(apps.count, "app")) checked. None needs a look.")
                    .font(.ui(.xs)).foregroundStyle(palette.ink3.color).padding(.horizontal, Space.sm).padding(.bottom, Space.xs)
            } else {
                ForEach(flagged.prefix(5)) { app in
                    HUDRow { onLock(app.name) } content: {
                        AppGlyph(path: app.app ?? app.path)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.name).font(.ui(.sm)).foregroundStyle(palette.ink.color).lineLimit(1)
                            Text(app.reasons.first?.label ?? "").font(.ui(.xxs)).foregroundStyle(palette.ink3.color).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text(String(app.score)).font(.mono(.xs)).monospacedDigit().foregroundStyle(palette.bad.color)
                    }
                    .frame(height: 40)
                    .help("Risk \(app.score) of 100. Open its dossier.")
                }
            }
        }
    }
}

/// The traffic every snapshot. Capture-only readings appear while
/// capturing; otherwise one line says capture is off.
private struct Readings: View {
    @Environment(\.palette) private var palette
    let series: [NetSample]
    let capturing: Bool

    var body: some View {
        let last = series.last ?? NetSample()
        HUDSection("Traffic") {
            Text("Every few seconds")
        } content: {
            reading("Download", NetFormat.rate(last.bytesIn), series.map { Double($0.bytesIn) }, .ok)
            reading("Upload", NetFormat.rate(last.bytesOut), series.map { Double($0.bytesOut) }, .brand)
            reading("New connections", "\(last.newConns)/s", series.map { Double($0.newConns) }, .neutral)
            reading("Open connections", "\(last.active)", series.map { Double($0.active) }, .neutral)
            if capturing {
                reading("Requests", "\(last.http)/s", series.map { Double($0.http) }, .neutral)
                reading("Packets", "\(last.packets)/s", series.map { Double($0.packets) }, .neutral)
                reading("DNS lookups", "\(last.dns)/s", series.map { Double($0.dns) }, .neutral)
            } else {
                Text("Capture off · requests, packets and DNS lookups need it")
                    .font(.ui(.xxs)).foregroundStyle(palette.ink4.color).lineLimit(2)
                    .padding(.horizontal, Space.sm).frame(minHeight: 26, alignment: .leading)
            }
        }
    }

    private func reading(_ label: String, _ value: String, _ values: [Double], _ tone: Tone) -> some View {
        HStack(spacing: Space.md) {
            Text(label).font(.ui(.xs)).foregroundStyle(palette.ink3.color).lineLimit(1)
            Spacer(minLength: 4)
            Sparkline(values: Array(values.suffix(60)), tone: tone == .neutral ? .neutral : tone).frame(width: 48, height: 16)
            Text(value).font(.mono(.xs)).monospacedDigit().foregroundStyle(palette.ink.color)
                .frame(width: 76, alignment: .trailing).contentTransition(.numericText())
        }
        .padding(.horizontal, Space.sm)
        .frame(height: 26)
        .accessibilityElement(children: .combine)
    }
}

/// Apps moving data now, ranked by what they moved over the last five
/// minutes, so rows keep their place between snapshots. Idle apps step out.
private struct Busiest: View {
    @Environment(\.palette) private var palette
    let apps: [NetApp]
    let onLock: (String) -> Void

    var body: some View {
        let busy = apps.filter { $0.rate > 0 }.sorted { ($0.recentBytes, $1.name) > ($1.recentBytes, $0.name) }.prefix(6)
        let peak = Double(max(1, busy.map(\.rate).max() ?? 1))
        HUDSection("Busiest apps") {
            Text("\(apps.count) online")
        } content: {
            if busy.isEmpty {
                Text("Nothing is moving data right now.").font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                    .padding(.horizontal, Space.sm).padding(.bottom, Space.xs)
            }
            ForEach(Array(busy)) { app in
                HUDRow { onLock(app.name) } content: {
                    AppGlyph(path: app.app ?? app.path)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name).font(.ui(.sm)).foregroundStyle(palette.ink.color).lineLimit(1)
                        GeometryReader { geo in
                            HStack(spacing: 0) {
                                Rectangle().fill(palette.ok.color).frame(width: geo.size.width * Double(app.rateIn) / peak)
                                Rectangle().fill(palette.brand.color).frame(width: geo.size.width * Double(app.rateOut) / peak)
                                Spacer(minLength: 0)
                            }
                            .background(palette.fill.color)
                            .clipShape(.capsule)
                            .animation(Motion.slow, value: app.rate)
                        }
                        .frame(height: 2)
                    }
                    Text(NetFormat.rate(app.rate)).font(.mono(.xs)).monospacedDigit().foregroundStyle(palette.ink2.color)
                        .frame(width: 80, alignment: .trailing)
                }
                .frame(height: 36)
                .help("\(NetFormat.rate(app.rateIn)) down, \(NetFormat.rate(app.rateOut)) up · \(LowtideFormat.bytes(app.recentBytes)) in the last 5 min")
            }
        }
    }
}

/// Connections as they open, newest first.
private struct Opened: View {
    @Environment(\.palette) private var palette
    @Environment(\.privacy) private var privacy
    let conns: [NetConn]
    let onLock: (String) -> Void

    var body: some View {
        HUDSection("Activity") {
            Text("\(conns.count) recent connections")
        } content: {
            if conns.isEmpty {
                Text("New connections appear here as apps open them.").font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                    .padding(.horizontal, Space.sm).padding(.bottom, Space.xs)
            }
            ForEach(conns.prefix(30)) { conn in
                HUDRow { onLock(conn.app) } content: {
                    Text(NetFormat.clock(conn.firstSeen)).font(.mono(.xxs)).monospacedDigit().foregroundStyle(palette.ink4.color)
                        .frame(width: 56, alignment: .leading)
                    Text(conn.app).font(.ui(.xs)).foregroundStyle(palette.ink2.color).lineLimit(1).layoutPriority(1)
                    Text(privacy ? "•••••" : NetFormat.endpoint(conn.host, conn.remote, conn.remotePort))
                        .font(.mono(.xxs)).foregroundStyle(palette.ink3.color).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .frame(height: 26)
                .opacity(conn.closedAt == nil ? 1 : 0.55)
                .help([conn.org, conn.country.map { WorldData.shared.name($0) }].compactMap { $0 }.joined(separator: " · "))
            }
        }
    }
}
