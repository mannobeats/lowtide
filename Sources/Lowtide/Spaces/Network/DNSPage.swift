import LowtideKit
import SwiftUI

/// Network → DNS: every lookup answered while packets are captured. The
/// names learned here label connections and packets everywhere.
struct DNSPage: View {
    @Environment(\.palette) private var palette
    @Environment(\.privacy) private var privacy
    private var model = NetworkModel.shared
    @State private var records: [DNSRecord] = []
    @State private var query = ""
    @State private var show: Show = .all
    @State private var selection = Set<DNSRecord.ID>()
    @State private var sort = [KeyPathComparator(\DNSRecord.t, order: .reverse)]

    enum Show: Hashable { case all, failed, odd }

    /// Answers only: each lookup appears once, with what it resolved to.
    private var answered: [DNSRecord] { records.filter { $0.rcode != nil } }

    private func matches(_ record: DNSRecord, _ show: Show) -> Bool {
        switch show {
        case .all: true
        case .failed: record.rcode != nil && record.rcode != "NOERROR"
        case .odd: record.suspicious != nil
        }
    }

    var body: some View {
        let capturing = model.overview.capture.running
        let answered = answered
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = answered.filter { matches($0, show) }
            .filter { needle.isEmpty || "\($0.name) \($0.answers.joined(separator: " "))".lowercased().contains(needle) }
            .sorted(using: sort)
        VStack(spacing: 0) {
            PageHeader("DNS", description: capturing || !answered.isEmpty
                       ? "\(LowtideFormat.count(answered.count, "lookup")). Names learned here label connections and packets everywhere."
                       : "Start a packet capture to record DNS lookups.", compact: true) {
                EmptyView()
            } action: {
                if capturing || !answered.isEmpty { CaptureButton() }
            }
            if !answered.isEmpty {
            PageToolbar {
                Segmented($show, [(.all, "All"), (.failed, "Failed"), (.odd, "Odd names")],
                          counts: [.all: answered.count, .failed: answered.filter { matches($0, .failed) }.count,
                                   .odd: answered.filter { matches($0, .odd) }.count])
            } trailing: {
                FilterField(text: $query, prompt: "Filter lookups")
            }
            .padding(.horizontal, Space.page + 4)
            .padding(.bottom, Space.md)
            }
            if rows.isEmpty {
                EmptyState("No lookups", symbol: "globe",
                           message: capturing ? (needle.isEmpty ? "No lookups match yet." : "Nothing matches “\(query)”.")
                           : "DNS lookups appear here while packets are captured.") {
                    if !capturing, answered.isEmpty { CaptureButton() }
                }
            } else {
                table(rows).card().padding(.horizontal, Space.page + 4).padding(.bottom, Space.page)
            }
        }
        .watchesNetwork()
        .task(id: capturing) {
            let engine = model.engine
            repeat {
                records = await Task.detached { engine.dns(limit: 3_000) }.value
                try? await Task.sleep(for: .seconds(1.5))
            } while capturing && !Task.isCancelled
        }
    }

    private func table(_ rows: [DNSRecord]) -> some View {
        Table(rows, selection: $selection, sortOrder: $sort) {
            TableColumn("Time", value: \.t) { record in
                Text(NetFormat.clock(record.t)).font(.mono(.xxs)).monospacedDigit().foregroundStyle(palette.ink4.color)
            }
            .width(min: 60, ideal: 68, max: 80)
            TableColumn("Type", value: \.qtype) { record in
                Text(record.qtype).font(.mono(.xxs)).foregroundStyle(palette.ink3.color)
            }
            .width(min: 40, ideal: 52, max: 64)
            TableColumn("Name", value: \.name) { record in
                Text(privacy ? "•••••" : record.name).font(.mono(.xs))
                    .foregroundStyle((record.suspicious != nil ? palette.warn : palette.ink).color)
                    .lineLimit(1).truncationMode(.middle)
                    .help(record.suspicious ?? record.name)
            }
            .width(min: 160, ideal: 280)
            TableColumn("Answer") { record in
                Text(privacy ? "•••••" : record.answers.joined(separator: ", ")).font(.mono(.xs)).foregroundStyle(palette.ink3.color)
                    .lineLimit(1).truncationMode(.tail).help(record.answers.joined(separator: ", "))
            }
            .width(min: 160, ideal: 360)
            TableColumn("Result", value: \.result) { record in
                Group {
                    if record.rcode == "NOERROR" {
                        Text("OK").font(.ui(.xs)).foregroundStyle(palette.ink4.color)
                    } else {
                        Text(record.rcode ?? "").font(.mono(.xxs)).foregroundStyle(palette.bad.color)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 80, max: 100)
        }
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: DNSRecord.ID.self) { ids in
            if let record = records.first(where: { ids.contains($0.id) }) {
                Button("Copy Name") { copy(record.name) }
                if !record.answers.isEmpty { Button("Copy Answers") { copy(record.answers.joined(separator: "\n")) } }
                Divider()
                Button("Show Its Packets") { showPackets("dns \(record.name)") }
                if let first = record.answers.first(where: { MMDBReader.parse($0) != nil }) {
                    Button("Show Traffic to \(first)") { showPackets("host:\(first)") }
                }
            }
        }
        .onCopyCommand {
            records.filter { selection.contains($0.id) }.map { NSItemProvider(object: $0.name as NSString) }
        }
    }
}

extension DNSRecord {
    var result: String { rcode ?? "" }
}
