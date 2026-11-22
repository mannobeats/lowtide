import LowtideKit
import SwiftUI

/// Network → Packets: every captured packet, decoded, filtered with a
/// small language, newest at the bottom while following.
struct PacketsPage: View {
    @Environment(\.palette) private var palette
    @Environment(\.privacy) private var privacy
    private var model = NetworkModel.shared
    @State private var filter = ""
    @State private var applied = ""
    @State private var follow = true
    @State private var page = PacketPage()
    @State private var loaded = false
    @State private var selected: Int?

    static let presets: [(String, String)] = [
        ("DNS", "dns"), ("TLS", "tls"), ("HTTP", "http"), ("QUIC", "quic"), ("Big uploads", "out len>1000"),
        ("Non-web TCP", "tcp -port:443,80"), ("Undecoded", "-dns,mdns,tls,quic,http"),
    ]

    var body: some View {
        let capture = model.overview.capture
        let locked = !capture.permitted && !capture.running && page.stored == 0
        VStack(spacing: 0) {
            PageHeader("Packets", description: locked ? nil : describe(capture), compact: true) {
                EmptyView()
            } action: {
                if capture.running || page.stored > 0 {
                    Button { follow.toggle() } label: {
                        Label(follow ? "Pause" : "Follow", systemImage: follow ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.lowtide(.quiet, size: .small))
                    .help(follow ? "Stop following new packets" : "Follow new packets as they arrive")
                }
                if !locked { CaptureButton() }
            }
            if locked {
                notPermitted
            } else {
                filterBar
                header
                list
                if let selected {
                    PacketDetailPane(seq: selected) { self.selected = nil }
                        .frame(height: 256)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .watchesNetwork()
        .onAppear(perform: takePending)
        .onChange(of: model.packetQuery) { _, _ in takePending() }
        .task(id: filter) {
            try? await Task.sleep(for: .milliseconds(250))
            applied = filter
        }
        .task(id: "\(applied)|\(follow)|\(capture.running)") {
            let engine = model.engine
            let query = applied
            repeat {
                page = await Task.detached { engine.packets(filter: query, limit: 3_000) }.value
                loaded = true
                try? await Task.sleep(for: .milliseconds(800))
            } while follow && capture.running && !Task.isCancelled
        }
        .animation(Motion.base, value: selected)
    }

    private func takePending() {
        guard let pending = model.packetQuery else { return }
        model.packetQuery = nil
        filter = pending
        applied = pending
    }

    private func describe(_ capture: CaptureStatus) -> String {
        let state = capture.running ? "capturing on \(capture.interface ?? "")" : "capture stopped"
        let dropped = capture.dropped > 0 ? " · \(capture.dropped.formatted()) dropped" : ""
        return "\(page.matched.formatted()) of \(page.stored.formatted()) packets in memory · \(state)\(dropped)"
    }

    private var notPermitted: some View {
        EmptyState("Packet capture is off", symbol: "lock.shield",
                   message: "Reading packets needs the capture devices (/dev/bpf*), which macOS opens only to an administrator. The live map works without them; packet details, DNS names and request counts need them.\n\nmacOS asks for your password once, and access lasts until the next restart. To keep it across restarts, install Wireshark with its \u{201C}Install ChmodBPF\u{201D} package.") {
            CaptureButton()
        }
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 11, weight: .medium)).foregroundStyle(palette.ink3.color)
                TextField("tls app:chrome host:github port:443,8443 out len>1000 -mdns", text: $filter)
                    .textFieldStyle(.plain).font(.mono(.xs)).autocorrectionDisabled()
                    .onExitCommand { filter = "" }
                if !filter.isEmpty {
                    Button { filter = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(palette.ink4.color) }
                        .buttonStyle(.plain).help("Clear the filter")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(palette.fill.color, in: .rect(cornerRadius: Radius.md))
            .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(palette.line.color))
            HStack(spacing: 6) {
                ForEach(Self.presets, id: \.0) { label, value in
                    let on = applied == value
                    Button(label) { filter = on ? "" : value }
                        .font(.ui(.xs))
                        .foregroundStyle((on ? palette.ink : palette.ink2).color)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background((on ? palette.brandSoft : palette.fill).color, in: .capsule)
                        .buttonStyle(.plain)
                        .help("Filter: \(value)")
                }
                Spacer(minLength: Space.md)
                Text("Every word must match. \(Text("-").font(.mono(.xxs))) excludes, commas mean any of. Keys: \(Text("host: app: port: proto: len> len< in out").font(.mono(.xxs)))")
                    .font(.ui(.xxs)).foregroundStyle(palette.ink4.color).lineLimit(1).truncationMode(.head)
            }
        }
        .padding(.horizontal, Space.page + 4)
        .padding(.vertical, Space.md)
        .hairline(.top)
        .hairline(.bottom)
    }

    private var header: some View {
        HStack(spacing: Space.md) {
            Text("Time").frame(width: 60, alignment: .leading)
            Color.clear.frame(width: 14)
            Text("App").frame(width: 104, alignment: .leading)
            Text("Source → destination").frame(maxWidth: .infinity, alignment: .leading)
            Text("Protocol").frame(width: 56, alignment: .leading)
            Text("Bytes").frame(width: 44, alignment: .trailing)
            Text("Info").frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.ui(.xs, .medium))
        .foregroundStyle(palette.ink3.color)
        .frame(height: 30)
        .padding(.horizontal, Space.page + Space.sm)
        .hairline(.bottom)
    }

    @ViewBuilder
    private var list: some View {
        if page.rows.isEmpty {
            EmptyState(applied.isEmpty ? "No packets" : "Nothing matches", symbol: "waveform.path.ecg",
                       message: model.overview.capture.running ? "No packet matches yet." : "Start a capture to fill this view.")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(page.rows) { packet in
                            PacketLine(packet: packet, selected: packet.seq == selected, privacy: privacy) {
                                selected = packet.seq
                                follow = false
                            }
                            .id(packet.seq)
                        }
                    }
                    .padding(.horizontal, Space.page)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: page.rows.last?.seq) { _, last in
                    if follow, let last { proxy.scrollTo(last, anchor: .bottom) }
                }
                .onKeyPress(.upArrow) { step(-1); return .handled }
                .onKeyPress(.downArrow) { step(1); return .handled }
            }
        }
    }

    private func step(_ by: Int) {
        guard let index = page.rows.firstIndex(where: { $0.seq == selected }) ?? (by < 0 ? page.rows.indices.last : nil) else { return }
        let next = min(max(index + by, 0), page.rows.count - 1)
        selected = page.rows[next].seq
        follow = false
    }
}

private struct PacketLine: View {
    @Environment(\.palette) private var palette
    let packet: PacketRow
    let selected: Bool
    let privacy: Bool
    let onSelect: () -> Void
    @State private var hovering = false

    var body: some View {
        let src = side(packet.src, packet.sport, packet.direction == "in" ? packet.host : nil)
        let dst = side(packet.dst, packet.dport, packet.direction == "in" ? nil : packet.host)
        HStack(spacing: Space.md) {
            Text(NetFormat.clock(packet.t)).font(.mono(.xxs)).monospacedDigit().foregroundStyle(palette.ink4.color).frame(width: 60, alignment: .leading)
            direction.frame(width: 14)
            Text(packet.process ?? "—").font(.ui(.xs)).foregroundStyle(palette.ink2.color).lineLimit(1).frame(width: 104, alignment: .leading)
            Text("\(privacy ? "•••••" : src) \(Text("→").foregroundStyle(palette.ink4.color)) \(privacy ? "•••••" : dst)")
                .font(.mono(.xxs)).foregroundStyle(palette.ink3.color).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Plain HTTP travels unencrypted: the one protocol worth a second look.
            Text(packet.app.isEmpty ? packet.proto : packet.app).font(.ui(.xs))
                .foregroundStyle((packet.app == "HTTP" ? palette.warn : palette.ink2).color).frame(width: 56, alignment: .leading)
            Text(String(packet.length)).font(.mono(.xxs)).monospacedDigit().foregroundStyle(palette.ink3.color).frame(width: 44, alignment: .trailing)
            Text(packet.info).font(.ui(.xs)).foregroundStyle(palette.ink.color).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Space.sm)
        .frame(height: 30)
        .background((selected ? palette.selected : hovering ? palette.hover : ColorValue(r: 0, g: 0, b: 0, a: 0)).color,
                    in: .rect(cornerRadius: Radius.md))
        .contentShape(.rect)
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy Info") { copy(packet.info) }
            Button("Copy Source") { copy("\(packet.src):\(packet.sport)") }
            Button("Copy Destination") { copy("\(packet.dst):\(packet.dport)") }
            Divider()
            let remote = packet.direction == "in" ? packet.src : packet.dst
            Button("Only This Host") { showPackets("host:\(remote)") }
            if let process = packet.process { Button("Only \(process)") { showPackets("app:\(process.split(separator: " ").first ?? "")") } }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func side(_ ip: String, _ port: UInt16, _ host: String?) -> String {
        "\(host ?? ip)\(port > 0 ? ":\(port)" : "")"
    }

    @ViewBuilder
    private var direction: some View {
        switch packet.direction {
        case "out": Image(systemName: "arrow.up.right").foregroundStyle(palette.brand.color).help("Outbound")
        case "in": Image(systemName: "arrow.down.left").foregroundStyle(palette.ok.color).help("Inbound")
        default: Image(systemName: "arrow.left.and.right").foregroundStyle(palette.ink4.color).help("Local network")
        }
    }
}

/// One packet's layers and its first bytes.
private struct PacketDetailPane: View {
    @Environment(\.palette) private var palette
    let seq: Int
    let onClose: () -> Void
    @State private var detail: PacketDetail?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Packet \(Text(String(seq)).font(.mono(.sm)))").font(.ui(.sm, .semibold)).foregroundStyle(palette.ink.color)
                Spacer()
                IconButton("xmark", help: "Close the packet", action: onClose)
            }
            .padding(.horizontal, Space.page + 4)
            .padding(.vertical, Space.sm)
            if let detail {
                let dump = PacketDecoder.hexDump(detail.bytes)
                HStack(alignment: .top, spacing: Space.xl) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Space.lg) {
                            ForEach(detail.layers, id: \.name) { layer in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(layer.name).font(.ui(.xs, .semibold)).foregroundStyle(palette.ink2.color)
                                    Grid(alignment: .leading, horizontalSpacing: Space.md, verticalSpacing: 3) {
                                        ForEach(layer.fields, id: \.self) { field in
                                            GridRow {
                                                Text(field.name).foregroundStyle(palette.ink3.color).frame(width: 112, alignment: .leading)
                                                Text(field.value).foregroundStyle(palette.ink.color).lineLimit(1).truncationMode(.middle)
                                                    .textSelection(.enabled).help(field.value)
                                            }
                                            .font(.ui(.xs))
                                        }
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minWidth: 220)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("First \(detail.bytes.count) bytes").font(.ui(.xs, .semibold)).foregroundStyle(palette.ink2.color)
                            Spacer()
                            Button { copy(dump.joined(separator: "\n")) } label: { Label("Copy", systemImage: "doc.on.doc") }
                                .buttonStyle(.lowtide(.quiet, size: .small)).help("Copy the hex dump")
                        }
                        ScrollView([.vertical, .horizontal]) {
                            Text(dump.joined(separator: "\n")).font(.mono(.xxs)).foregroundStyle(palette.ink2.color)
                                .textSelection(.enabled).fixedSize().padding(.horizontal, Space.md).padding(.vertical, Space.sm)
                        }
                        .background(palette.fill.color, in: .rect(cornerRadius: Radius.md))
                    }
                    .frame(width: 520)
                }
                .padding(.horizontal, Space.page + 4)
                .padding(.bottom, Space.md)
            } else {
                Text(loaded ? "This packet has left the buffer." : "Decoding…").font(.ui(.sm)).foregroundStyle(palette.ink3.color)
                    .padding(.horizontal, Space.page + 4).padding(.vertical, Space.lg)
            }
        }
        .background(palette.surface.color)
        .hairline(.top)
        .task(id: seq) {
            let engine = NetworkEngine.shared
            detail = await Task.detached { engine.packet(seq: seq) }.value
            loaded = true
        }
    }
}
