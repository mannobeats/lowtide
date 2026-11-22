import LowtideKit
import SwiftUI

/// Secrets › Decoys: fake credential files in the places stealers look,
/// and what read them.
struct DecoysView: View {
    @Environment(\.palette) private var palette
    private var model = ProtectionModel.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                if let status = model.decoys {
                    if status.planted == 0 {
                        VStack(spacing: Space.md) {
                            HeroArt("protection", size: 72)
                            Text("Catch credential stealers").font(.ui(.base, .semibold)).foregroundStyle(palette.ink.color)
                            Text("Fake credential files in the hidden places credential stealers search: an AWS key backup, an old SSH key, a .env backup and more. Nothing honest reads them, so the moment something does, you get an alert. Your own files are never touched.")
                                .font(.ui(.sm)).foregroundStyle(palette.ink3.color).multilineTextAlignment(.center)
                                .frame(maxWidth: 460)
                            Button("Plant Decoys") { Task { await model.plantDecoys() } }
                                .buttonStyle(.primary).disabled(model.decoyBusy).padding(.top, Space.xs)
                        }
                        .frame(maxWidth: .infinity, minHeight: 360)
                    } else {
                        Pane("Decoys", subtitle: "Checked every 3 seconds") {
                            RowStack(items: status.decoys) { DecoyRow(decoy: $0) }
                        }
                        QuietNote("A read is noticed through the file's access time, which can't say who read it. Your own cat or grep, Time Machine and other backup apps trip a decoy too.", small: true)
                    }
                    if !status.errors.isEmpty {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            ForEach(status.errors, id: \.self) { Text($0) }
                        }
                        .font(.ui(.xs)).foregroundStyle(palette.warn.color)
                    }
                } else {
                    ScanningState(title: "Reading decoys…").frame(minHeight: 300)
                }
            }
            .padding(.horizontal, Space.page + 4)
            .padding(.top, Space.lg)
            .padding(.bottom, Space.page * 2)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .overlay(alignment: .top) { Hairline() }
        .task {
            while !Task.isCancelled {
                await model.reloadDecoys()
                try? await Task.sleep(for: Decoys.pollInterval)
            }
        }
    }
}

private struct DecoyRow: View {
    @Environment(\.palette) private var palette
    private var model = ProtectionModel.shared
    let decoy: Decoys.View

    init(decoy: Decoys.View) { self.decoy = decoy }

    var body: some View {
        let tripped = !decoy.trips.isEmpty
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.md) {
                GlyphTile(glyph: "decoys", quiet: !decoy.state.planted, tone: tripped ? .bad : nil)
                VStack(alignment: .leading, spacing: 1) {
                    Text(decoy.imitates).font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color).lineLimit(1)
                    Text(decoy.path).font(.mono(.xxs)).foregroundStyle((tripped ? palette.bad : palette.ink4).color)
                        .lineLimit(1).textSelection(.enabled)
                }
                Spacer(minLength: Space.md)
                meta.font(.ui(.xs)).monospacedDigit()
                if decoy.state == .absent || decoy.state == .missing {
                    Button("Plant") { Task { await model.plantDecoys([decoy.id]) } }
                        .buttonStyle(.lowtide(.quiet, size: .small)).disabled(model.decoyBusy)
                }
            }
            if let trip = decoy.trips.first {
                Suspects(trip: trip).padding(.leading, 32 + Space.md)
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .background(tripped ? palette.badSoft.opacity(0.5).color : .clear)
        .contextMenu {
            if decoy.state.planted {
                Button("Show in Finder") { FileActions.reveal(decoy.path) }
            }
            Button("Copy Path") { FileActions.copy(FileActions.expand(decoy.path)) }
        }
    }

    private static func when(_ ms: UInt64) -> String { Clock.date(ms).formatted(date: .abbreviated, time: .shortened) }

    @ViewBuilder private var meta: some View {
        if let last = decoy.trips.first {
            Text("Read \(Self.when(last.t))" + (decoy.trips.count > 1 ? ", \(decoy.trips.count) times" : ""))
                .foregroundStyle(palette.bad.color)
        } else if decoy.state == .armed, let armed = decoy.armedAt {
            Text("Armed since \(Self.when(armed))").foregroundStyle(palette.ink3.color)
        } else {
            Text(label).foregroundStyle((decoy.state == .missing ? palette.warn : palette.ink4).color)
        }
    }

    private var label: String {
        switch decoy.state {
        case .absent: "Not planted"
        case .armed: "Armed"
        case .arming: "Arming in 30 seconds"
        case .missing: "Deleted since planting"
        case .taken: "Skipped, a file of yours is here"
        }
    }
}

/// Processes that started around a read: leads, not proof.
private struct Suspects: View {
    @Environment(\.palette) private var palette
    @Environment(\.privacy) private var privacy
    let trip: Decoys.Trip

    var body: some View {
        if trip.suspects.isEmpty {
            Text("No process started within a minute of the read, so whatever read it was already running.")
                .font(.ui(.xs)).foregroundStyle(palette.ink3.color)
        } else {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Started around the same time").font(.ui(.xs, .semibold)).foregroundStyle(palette.ink2.color)
                Text("A read can't say who did it, so these are leads, not proof.").font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(trip.suspects, id: \.self) { s in
                        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                            Text(Clock.date(s.started).timeOfDay).monospacedDigit().foregroundStyle(palette.ink4.color)
                                .frame(width: 56, alignment: .leading)
                            Text(s.comm).font(.mono(.xs)).foregroundStyle((s.system ? palette.ink3 : palette.ink).color).fixedSize()
                            Text(s.path.map { privacy ? "•••" : Paths.tilde($0) } ?? "pid \(s.pid)").font(.mono(.xxs))
                                .foregroundStyle(palette.ink4.color).lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading).help(s.path ?? "")
                            if let parent = s.parent { Text("from \(parent)").foregroundStyle(palette.ink3.color).fixedSize() }
                        }
                        .font(.ui(.xs))
                        .frame(minHeight: 22)
                        .contextMenu {
                            if let path = s.path {
                                Button("Show in Finder") { FileActions.reveal(path) }
                                Button("Copy Path") { FileActions.copy(path) }
                            }
                        }
                    }
                }
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.xs + 2)
                .background(palette.fill.color, in: .rect(cornerRadius: Radius.md))
            }
        }
    }
}
