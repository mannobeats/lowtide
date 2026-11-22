import LowtideKit
import SwiftUI

/// Protection's front page: one verdict, then each area in a line.
struct ProtectionOverviewPage: View {
    @Environment(\.palette) private var palette
    private var model = ProtectionModel.shared
    private var store = RunsStore.shared

    /// One area of Protection, summed up from its own page's data.
    struct Area: Identifiable {
        var id: String { name }
        let glyph: String
        let name: String
        /// One line under the name.
        let meta: String
        /// Right-hand state: a count that asks for action, or a quiet word
        /// ("" while it is being read).
        let value: String
        /// What needs you, as a phrase for the verdict.
        var issue: String?
        let open: () -> Void
    }

    var body: some View {
        let areas = [threats, permissions, secrets, decoys, installs]
        let issues = areas.filter { $0.issue != nil }
        let ready = areas.allSatisfy { !$0.value.isEmpty }
        let planted = (model.decoys?.planted ?? 0) > 0
        PageScaffold {
            PageHero(title(ready: ready, areas: areas, issues: issues), detail: detail(ready: ready, issues: issues, planted: planted),
                     art: "protection") {
                if ready, let first = issues.first {
                    Button("Review \(first.name.lowercased())", action: first.open).buttonStyle(.primary)
                } else if ready, !planted {
                    Button("Plant Decoy Keys") { Task { await model.plantDecoys() } }
                        .buttonStyle(.primary)
                        .disabled(model.decoyBusy)
                }
            }
        } content: {
            VStack(spacing: 0) {
                ForEach(Array(areas.enumerated()), id: \.element.id) { index, area in
                    if index > 0 { Hairline(inset: Space.lg + 32 + Space.md) }
                    AreaRow(area: area)
                }
            }
            .clipShape(.rect(cornerRadius: Radius.lg))
            .card()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Protection areas")
        }
        .task {
            await model.loadPermissions(full: false)
            while !Task.isCancelled {
                await model.reloadNetwork()
                await model.reloadDecoys()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private func title(ready: Bool, areas: [Area], issues: [Area]) -> String {
        guard ready else { return "Checking your protection…" }
        if !issues.isEmpty {
            return "\(CountWords.word(issues.count)) \(issues.count == 1 ? "thing needs" : "things need") you"
        }
        return "Your Mac looks protected"
    }

    private func detail(ready: Bool, issues: [Area], planted: Bool) -> String {
        guard ready else { return "Reading threats, permissions, secrets, decoys and installs on this Mac." }
        if !issues.isEmpty {
            let phrases = CountWords.list(issues.compactMap(\.issue))
            return phrases.prefix(1).uppercased() + phrases.dropFirst() + "."
        }
        return planted ? "No flagged apps, no exposed keys, and nothing has touched your decoys today."
            : "No flagged apps and no exposed keys. Plant decoy keys to catch credential stealers."
    }

    // MARK: Areas

    private var threats: Area {
        let open = { AppModel.shared.open(.threats) }
        guard model.networkWired else {
            let local = model.local.filter { $0.severity == .alert }.count
            return Area(glyph: "threats", name: "Threats",
                        meta: local > 0 ? "\(LowtideFormat.count(local, "finding")) on this Mac, listed below"
                            : "Install alerts, decoy reads and exposed keys on this Mac",
                        value: local > 0 ? "\(local) on this Mac" : "Clear", open: open)
        }
        guard let network = model.network else {
            return Area(glyph: "threats", name: "Threats", meta: "Scoring every app that talks…", value: "", open: open)
        }
        let apps = network.filter { $0.kind == .app && $0.score > 0 }
        let flagged = model.flaggedApps.count
        if flagged > 0 {
            return Area(glyph: "threats", name: "Threats", meta: "Unsigned, beaconing or reaching blocklisted servers",
                        value: "\(flagged) flagged", issue: "\(LowtideFormat.count(flagged, "app")) flagged on the network", open: open)
        }
        return Area(glyph: "threats", name: "Threats",
                    meta: apps.isEmpty ? "Every app on the network looks normal"
                        : "Nothing flagged, \(LowtideFormat.count(apps.count, "app")) worth a glance",
                    value: "Clear", open: open)
    }

    private var permissions: Area {
        let open = { AppModel.shared.open(.permissions) }
        guard let map = model.permissions else {
            return Area(glyph: "permissions", name: "Permissions", meta: "Reading permissions and login items…", value: "",
                        open: open)
        }
        let meta = map.grantsReadable
            ? "\(LowtideFormat.count(map.powerful, "app")) with powerful access, \(map.startAtLogin) open at login"
            : "\(map.startAtLogin) open at login. Privacy permissions need Full Disk Access"
        if map.broken > 0 {
            return Area(glyph: "permissions", name: "Permissions", meta: meta, value: "\(map.broken) broken",
                        issue: LowtideFormat.count(map.broken, "broken start-up item"), open: open)
        }
        return Area(glyph: "permissions", name: "Permissions", meta: meta, value: LowtideFormat.count(map.apps.count, "app"),
                    open: open)
    }

    private var secrets: Area {
        let open = { model.openSecrets(.exposed) }
        guard model.exposureLoaded else {
            return Area(glyph: "secrets", name: "Exposed secrets", meta: "Reading the last scan…", value: "", open: open)
        }
        guard let report = model.exposure else {
            return Area(glyph: "secrets", name: "Exposed secrets",
                        meta: "Looks for keys in .env files, tool configs and shell history", value: "Not scanned", open: open)
        }
        let active = model.activeSecrets
        let critical = model.criticalSecrets
        let when = "scanned \(LowtideFormat.ago(Clock.date(report.at)))"
        if critical > 0 {
            return Area(glyph: "secrets", name: "Exposed secrets", meta: "\(LowtideFormat.count(active.count, "finding")), \(when)",
                        value: "\(critical) critical", issue: "\(LowtideFormat.count(critical, "secret")) exposed", open: open)
        }
        return Area(glyph: "secrets", name: "Exposed secrets",
                    meta: active.isEmpty ? "Nothing exposed in \(report.scanned.formatted()) files, \(when)"
                        : "\(LowtideFormat.count(active.count, "finding")) to know about, \(when)",
                    value: active.isEmpty ? "Clear" : "\(active.count)", open: open)
    }

    private var decoys: Area {
        let open = { model.openSecrets(.decoys) }
        guard let status = model.decoys else {
            return Area(glyph: "decoys", name: "Decoy keys", meta: "Reading decoys…", value: "", open: open)
        }
        guard status.planted > 0 else {
            return Area(glyph: "decoys", name: "Decoy keys", meta: "Fake keys that raise an alarm the moment anything reads them",
                        value: "Not planted", open: open)
        }
        let reads = status.reads
        let recent = model.decoyReads
        let last = reads.max().map { LowtideFormat.ago(Clock.date($0)) }
        if recent > 0 {
            return Area(glyph: "decoys", name: "Decoy keys", meta: "Last read \(last ?? "")", value: LowtideFormat.count(recent, "read"),
                        issue: "\(LowtideFormat.count(recent, "decoy key")) read", open: open)
        }
        return Area(glyph: "decoys", name: "Decoy keys",
                    meta: last.map { "Nothing read today, last read \($0)" } ?? "Nothing has read them",
                    value: "\(status.planted) armed", open: open)
    }

    private var installs: Area {
        let open = { AppModel.shared.open(.installWatch) }
        guard store.loaded else {
            return Area(glyph: "install-watch", name: "Install watch", meta: "Reading followed installs…", value: "", open: open)
        }
        let list = store.installs
        guard let latest = list.map(\.started).max() else {
            return Area(glyph: "install-watch", name: "Install watch",
                        meta: "Installs from any terminal are followed from start to finish", value: "Armed", open: open)
        }
        let alerts = model.installAlerts
        let notices = list.filter { $0.verdict == .notice }.count
        let meta = "\(LowtideFormat.count(list.count, "install")) followed, the last \(LowtideFormat.ago(Clock.date(latest)))"
        if alerts > 0 {
            return Area(glyph: "install-watch", name: "Install watch", meta: meta, value: LowtideFormat.count(alerts, "alert"),
                        issue: LowtideFormat.count(alerts, "install alert"), open: open)
        }
        return Area(glyph: "install-watch", name: "Install watch", meta: meta,
                    value: notices > 0 ? "\(notices) worth knowing" : "Clear", open: open)
    }
}

private struct AreaRow: View {
    @Environment(\.palette) private var palette
    @State private var hovering = false
    let area: ProtectionOverviewPage.Area

    var body: some View {
        Button(action: area.open) {
            HStack(spacing: Space.md) {
                GlyphTile(glyph: area.glyph)
                VStack(alignment: .leading, spacing: 1) {
                    Text(area.name).font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color)
                    Text(area.meta).font(.ui(.xs)).foregroundStyle(palette.ink3.color).lineLimit(1)
                }
                Spacer(minLength: Space.md)
                if area.value.isEmpty {
                    ProgressView().controlSize(.mini)
                } else if area.issue != nil {
                    Badge(area.value, tone: .warn)
                } else {
                    Text(area.value).font(.ui(.xs)).monospacedDigit().foregroundStyle(palette.ink3.color)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle((hovering ? palette.ink3 : palette.ink4).color)
                    .offset(x: hovering ? 2 : 0)
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.sm + 2)
            .frame(minHeight: 56)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(hovering ? palette.hover.color : .clear)
        .onHover { hovering = $0 }
        .animation(Motion.fast, value: hovering)
        .accessibilityLabel("\(area.name), \(area.value)")
        .accessibilityHint(area.meta)
    }
}
