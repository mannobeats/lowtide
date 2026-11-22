import LowtideKit
import SwiftUI

/// Every socket on this Mac: open, listening, and closed in the last ten
/// minutes, sortable by any column.
struct ConnectionsView: View {
    @Environment(\.palette) private var palette
    @Environment(\.privacy) private var privacy
    private var model = NetworkModel.shared
    let onLock: (String) -> Void
    @State private var all: [NetConn] = []
    @State private var loaded = false
    @State private var query = ""
    @State private var show: Show = .open
    @State private var selection = Set<NetConn.ID>()
    @State private var sort = [KeyPathComparator(\NetConn.rate, order: .reverse)]

    init(onLock: @escaping (String) -> Void) { self.onLock = onLock }

    enum Show: Hashable { case open, listening, closed, all }

    private func matches(_ conn: NetConn, _ show: Show) -> Bool {
        switch show {
        case .open: conn.closedAt == nil && !conn.listening
        case .listening: conn.listening
        case .closed: conn.closedAt != nil
        case .all: true
        }
    }

    private var rows: [NetConn] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return all.filter { matches($0, show) }.filter { conn in
            needle.isEmpty || "\(conn.app) \(conn.host ?? "") \(conn.remote) \(conn.remotePort) \(conn.service ?? "") \(conn.org ?? "") \(conn.country ?? "")"
                .lowercased().contains(needle)
        }.sorted(using: sort)
    }

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar {
                Segmented($show, [(.open, "Open"), (.listening, "Listening"), (.closed, "Closed"), (.all, "All")],
                          counts: [.open: all.filter { matches($0, .open) }.count, .listening: all.filter(\.listening).count,
                                   .closed: all.filter { $0.closedAt != nil }.count, .all: all.count])
            } trailing: {
                FilterField(text: $query, prompt: "Filter connections")
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.sm)
            let rows = rows
            if rows.isEmpty {
                EmptyState(loaded ? "No connections" : "Reading connections", symbol: "point.3.connected.trianglepath.dotted",
                           message: !loaded ? "Reading every socket on this Mac…"
                           : !query.trimmingCharacters(in: .whitespaces).isEmpty ? "Nothing matches “\(query.trimmingCharacters(in: .whitespaces))”."
                           : show == .all ? "No app has opened a connection yet." : "None right now. Try another filter.")
            } else {
                table(rows)
            }
        }
        .task {
            if let pending = model.connectionsQuery {
                query = pending
                model.connectionsQuery = nil
            }
            let engine = model.engine
            while !Task.isCancelled {
                all = await Task.detached { engine.connections() }.value
                loaded = true
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
        .onChange(of: model.connectionsQuery) { _, pending in
            if let pending {
                query = pending
                model.connectionsQuery = nil
            }
        }
    }

    private func table(_ rows: [NetConn]) -> some View {
        Table(rows, selection: $selection, sortOrder: $sort) {
            TableColumn("App", value: \.app) { conn in
                HStack(spacing: 8) {
                    AppGlyph(path: conn.appPath, size: 18)
                    Text(conn.app).font(.ui(.sm)).foregroundStyle(palette.ink.color).lineLimit(1)
                }
                .opacity(conn.closedAt == nil ? 1 : 0.5)
            }
            .width(min: 110, ideal: 160)
            TableColumn("Remote", value: \.remote) { conn in
                VStack(alignment: .leading, spacing: 0) {
                    Text(privacy ? "•••••" : conn.listening ? "Listening on \(conn.local):\(conn.localPort)"
                         : NetFormat.endpoint(conn.host, conn.remote, conn.remotePort))
                        .font(.mono(.xs)).foregroundStyle(palette.ink2.color).lineLimit(1).truncationMode(.middle)
                    if conn.host != nil, !privacy {
                        Text(conn.remote).font(.mono(.xxs)).foregroundStyle(palette.ink4.color).lineLimit(1).truncationMode(.middle)
                    }
                }
                .help(conn.remote)
            }
            .width(min: 160, ideal: 280)
            TableColumn("Owner", value: \.ownerKey) { conn in
                VStack(alignment: .leading, spacing: 0) {
                    Text(conn.country != nil ? conn.org ?? "Unknown owner" : Localhost.isLoopback(conn.remote) || conn.listening ? "This Mac" : "This network").font(.ui(.xs)).foregroundStyle(palette.ink2.color).lineLimit(1)
                    if let country = conn.country {
                        Text(WorldData.shared.name(country)).font(.ui(.xxs)).foregroundStyle(palette.ink4.color).lineLimit(1)
                    }
                }
                .help(conn.asn.map { "AS\($0)" } ?? "")
            }
            .width(min: 90, ideal: 150)
            TableColumn("Service", value: \.serviceKey) { conn in
                VStack(alignment: .leading, spacing: 0) {
                    Text(conn.service ?? conn.proto).font(.ui(.xs)).foregroundStyle(palette.ink2.color)
                    Text(conn.closedAt.map { "Closed \(LowtideFormat.ago($0.date))" } ?? (conn.state.isEmpty ? "Open" : conn.state))
                        .font(.ui(.xxs)).foregroundStyle(palette.ink4.color).lineLimit(1)
                }
            }
            .width(min: 70, ideal: 90)
            TableColumn("Ping", value: \.pingKey) { conn in
                Text(NetFormat.ms(conn.rttMs)).font(.mono(.xs)).monospacedDigit().foregroundStyle(palette.ink3.color)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 48, ideal: 56)
            TableColumn("Now", value: \.rate) { conn in
                Text(conn.rate > 0 ? NetFormat.rate(conn.rate) : "").font(.mono(.xs)).monospacedDigit().foregroundStyle(palette.ink.color)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 64, ideal: 76)
            TableColumn("In", value: \.bytesIn) { conn in
                Text(LowtideFormat.bytes(conn.bytesIn)).font(.mono(.xs)).monospacedDigit().foregroundStyle(palette.ink3.color)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 56, ideal: 64)
            TableColumn("Out", value: \.bytesOut) { conn in
                Text(LowtideFormat.bytes(conn.bytesOut)).font(.mono(.xs)).monospacedDigit().foregroundStyle(palette.ink3.color)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 56, ideal: 64)
        }
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: NetConn.ID.self) { ids in
            if let conn = all.first(where: { ids.contains($0.id) }) { menu(conn) }
        } primaryAction: { ids in
            if let conn = all.first(where: { ids.contains($0.id) }) { onLock(conn.app) }
        }
        .onCopyCommand {
            all.filter { selection.contains($0.id) }.map { NSItemProvider(object: address($0) as NSString) }
        }
    }

    private func address(_ conn: NetConn) -> String {
        conn.listening ? "\(conn.local):\(conn.localPort)" : "\(conn.remote):\(conn.remotePort)"
    }

    @ViewBuilder
    private func menu(_ conn: NetConn) -> some View {
        Button("Copy Address") { copy(address(conn)) }
        if let host = conn.host { Button("Copy Host Name") { copy(host) } }
        Divider()
        Button("Show on the Map") { onLock(conn.app) }
        if !conn.listening { Button("Show Its Packets") { showPackets("host:\(conn.remote)") } }
        Button("Only \(conn.app)") { query = conn.app }
    }
}

extension NetConn {
    var ownerKey: String { country == nil ? "" : org ?? "~" }
    var serviceKey: String { service ?? proto }
    var pingKey: Double { rttMs ?? .infinity }
}
