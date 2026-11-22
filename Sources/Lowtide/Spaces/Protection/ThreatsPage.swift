import LowtideKit
import SwiftUI

/// Every threat in one place: apps the network monitor scores as
/// suspicious, breaks from an app's normal and odd domain lookups (when
/// the network space is wired), and what Protection found on this Mac.
struct ThreatsPage: View {
    @Environment(\.palette) private var palette
    private var model = ProtectionModel.shared

    var body: some View {
        let network = model.network ?? []
        let apps = network.filter { $0.kind == .app && $0.score > 0 }.sorted { $0.score > $1.score }
        let events = network.filter { $0.kind == .event }
        let domains = network.filter { $0.kind == .domain }
        let local = model.local
        VStack(spacing: 0) {
            PageHeader("Threats", description: description(apps: apps, domains: domains, local: local))
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    if model.networkWired, model.network == nil {
                        ScanningState(title: "Scoring every app that talks…").frame(minHeight: 200)
                    } else if apps.isEmpty, domains.isEmpty, local.isEmpty {
                        EmptyState("All clear", symbol: "checkmark.shield",
                                   message: model.networkWired
                                    ? "Every app on the network is signed by a known developer and behaving normally, and nothing on this Mac needs a look."
                                    : "No install alerts, decoy reads, exposed keys or broken start-up items on this Mac.")
                            .frame(minHeight: 280)
                    }
                    if !local.isEmpty {
                        Pane("On this Mac", subtitle: LowtideFormat.count(local.count, "finding")) {
                            RowStack(items: local) { LocalRow(finding: $0) }
                        }
                    }
                    if !apps.isEmpty {
                        Pane("Apps by suspicion", subtitle: LowtideFormat.count(apps.count, "app")) {
                            RowStack(items: apps) { SuspectRow(app: $0) }
                        }
                    }
                    if !events.isEmpty {
                        Pane("Breaks from normal", subtitle: "Last hour") {
                            RowStack(items: events) { event in
                                TimedRow(at: event.at, text: event.title, tone: event.severity == .alert ? .bad : nil)
                            }
                        }
                    }
                    if !domains.isEmpty {
                        Pane("Odd domain lookups") {
                            RowStack(items: domains) { record in
                                TimedRow(at: record.at, text: record.title, mono: true, trailing: record.detail)
                            }
                        }
                    }
                    if model.networkWired { HowTheScoreWorks() }
                }
                .padding(.horizontal, Space.page + 4)
                .padding(.top, Space.xs)
                .padding(.bottom, Space.page * 2)
                .frame(maxWidth: 1180, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .task {
            await model.loadPermissions(full: false)
            while !Task.isCancelled {
                await model.reloadNetwork()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func description(apps: [ThreatFinding], domains: [ThreatFinding], local: [ThreatFinding]) -> String {
        let here = local.isEmpty ? "nothing on this Mac" : "\(LowtideFormat.count(local.count, "finding")) on this Mac"
        guard model.networkWired else {
            return local.isEmpty ? "Nothing on this Mac needs a look" : "\(LowtideFormat.count(local.count, "finding")) on this Mac"
        }
        guard model.network != nil else { return "Scoring every app that talks…" }
        let flagged = apps.filter { $0.score >= ThreatFinding.flag }.count
        return "\(LowtideFormat.count(flagged, "app")) flagged · \(apps.count) worth a look · "
            + "\(LowtideFormat.count(domains.count, "odd domain lookup")) · \(here)"
    }
}

/// An app the network scores: its score, each reason with its points, and
/// one line of facts.
private struct SuspectRow: View {
    @Environment(\.palette) private var palette
    @Environment(\.privacy) private var privacy
    let app: ThreatFinding

    var body: some View {
        let level = ThreatFinding.level(app.score)
        HStack(alignment: .top, spacing: Space.md) {
            if let bundle = app.appPath {
                FileIcon(path: bundle, size: 32)
            } else {
                GlyphTile(glyph: "processes", quiet: true)
            }
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack(alignment: .top, spacing: Space.md) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.title).font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color).lineLimit(1)
                        if let detail = app.detail {
                            Text(privacy ? "•••" : Paths.tilde(detail)).font(.mono(.xxs)).foregroundStyle(palette.ink4.color)
                                .lineLimit(1).truncationMode(.middle).help(detail)
                        }
                    }
                    Spacer(minLength: Space.sm)
                    Badge("\(level.rawValue.capitalized) · \(app.score)",
                          tone: level == .high ? .bad : level == .medium ? .warn : .neutral)
                        .help("Suspicion score \(app.score)")
                }
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(app.reasons, id: \.label) { reason in
                        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                            Text("+\(reason.points)").font(.mono(.xxs)).monospacedDigit().foregroundStyle(palette.ink4.color)
                                .frame(width: 30, alignment: .trailing)
                            Text(reason.label).font(.ui(.sm)).foregroundStyle(palette.ink2.color)
                        }
                    }
                }
                if let summary = app.summary {
                    Text(summary).font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                }
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .contextMenu {
            if let path = app.appPath ?? app.path {
                Button("Show in Finder") { FileActions.reveal(path) }
                Button("Copy Path") { FileActions.copy(path) }
                Divider()
            }
            Button("Show Its Connections") { AppModel.shared.open(.networkLive) }
            Button("Show Its Packets") { AppModel.shared.open(.packets) }
        }
    }
}

/// Something Protection found on the Mac; opens where it can be dealt with.
private struct LocalRow: View {
    @Environment(\.palette) private var palette
    @Environment(\.privacy) private var privacy
    @State private var hovering = false
    let finding: ThreatFinding

    var body: some View {
        Button(action: open) {
            HStack(spacing: Space.md) {
                GlyphTile(glyph: glyph, tone: finding.severity == .alert ? .bad : .warn)
                VStack(alignment: .leading, spacing: 1) {
                    Text(finding.title).font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color).lineLimit(1)
                    if let detail = finding.detail {
                        Text(privacy && finding.kind != .install ? "•••" : detail)
                            .font(finding.kind == .install ? .ui(.xs) : .mono(.xxs))
                            .foregroundStyle(palette.ink3.color).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: Space.md)
                if let at = finding.at {
                    Text(LowtideFormat.ago(at)).font(.ui(.xs)).monospacedDigit().foregroundStyle(palette.ink3.color)
                }
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle((hovering ? palette.ink3 : palette.ink4).color)
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.sm + 2)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(hovering ? palette.hover.color : .clear)
        .onHover { hovering = $0 }
        .contextMenu {
            if let path = finding.path {
                Button("Show in Finder") { FileActions.reveal(path) }
                Button("Copy Path") { FileActions.copy(FileActions.expand(path)) }
            }
        }
    }

    private var glyph: String {
        switch finding.kind {
        case .install: "install-watch"
        case .decoy: "decoys"
        case .secret: "secrets"
        case .startup: "login-items"
        default: "threats"
        }
    }

    private func open() {
        switch finding.kind {
        case .install: AppModel.shared.open(.installWatch)
        case .decoy: ProtectionModel.shared.openSecrets(.decoys)
        case .secret: ProtectionModel.shared.openSecrets(.exposed)
        case .startup: AppModel.shared.open(.permissions)
        default: break
        }
    }
}

/// A timed line: an event or a lookup.
private struct TimedRow: View {
    @Environment(\.palette) private var palette
    let at: Date?
    let text: String
    var tone: Tone?
    var mono = false
    var trailing: String?

    var body: some View {
        HStack(spacing: Space.md) {
            Text(at?.timeOfDay ?? "").font(.ui(.xs)).monospacedDigit().foregroundStyle(palette.ink4.color)
                .frame(width: 64, alignment: .leading)
            Text(text).font(mono ? .mono(.xs) : .ui(.sm))
                .foregroundStyle((tone?.color(palette) ?? (mono ? palette.ink : palette.ink2)).color)
                .lineLimit(1).textSelection(.enabled)
            Spacer(minLength: Space.sm)
            if let trailing { Text(trailing).font(.ui(.xs)).foregroundStyle(palette.warn.color) }
        }
        .padding(.horizontal, Space.lg)
        .frame(minHeight: 36)
    }
}

private struct HowTheScoreWorks: View {
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs + 2) {
            Text("How the score works").font(.ui(.xs, .semibold)).foregroundStyle(palette.ink2.color)
            Text("No code signature (+30), running from a temporary, hidden or download folder without a known developer (+25), calling a server on a fixed timer (+20), uploading far more than downloading (+15), talking to over 60 hosts at once (+15), ad-hoc signing (+15), accepting connections from the network (+10) and unusual ports (+10). Apple's own software is trusted, and \(ThreatFinding.flag) or more is flagged in the menu bar.")
            Text("Each signal alone is common in honest tools; together they say where to look first. Lowtide also remembers what's normal for each app (the countries it reaches, how much it usually uploads) and reports the first time something breaks that pattern.")
        }
        .font(.ui(.xs))
        .foregroundStyle(palette.ink3.color)
        .frame(maxWidth: 620, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}
