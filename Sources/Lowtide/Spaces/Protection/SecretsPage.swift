import LowtideKit
import SwiftUI

/// Credentials on this Mac, two ways: keys left lying in files (Exposed),
/// and fake keys planted to catch whatever goes looking for them (Decoys).
struct SecretsPage: View {
    @Environment(\.palette) private var palette
    private var model = ProtectionModel.shared
    @State private var confirm: ConfirmRequest?

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            PageHeader("Secrets", description: description) {
                Segmented($model.secretsView, [(.exposed, "Exposed"), (.decoys, "Decoys")],
                          counts: [.exposed: model.activeSecrets.count, .decoys: model.decoyReads])
            } action: {
                actions
            }
            switch model.secretsView {
            case .exposed: ExposedView()
            case .decoys: DecoysView()
            }
        }
        .confirmation($confirm)
    }

    private var description: String {
        switch model.secretsView {
        case .exposed:
            if model.scanning { return "Scanning your home folder…" }
            guard let report = model.exposure else { return "Tokens and keys left on disk, not scanned yet" }
            return "Last scan \(LowtideFormat.ago(Clock.date(report.at))) · \(report.scanned.formatted()) files checked in "
                + String(format: "%.1f s", Double(report.ms) / 1000)
        case .decoys:
            guard let status = model.decoys else { return "Reading decoys…" }
            guard status.planted > 0 else { return "No decoys planted" }
            guard let last = status.reads.max() else { return "\(status.planted) decoys armed · nothing has read them" }
            return "\(status.planted) decoys · \(LowtideFormat.count(status.reads.count, "read")), the last "
                + Clock.date(last).formatted(date: .abbreviated, time: .shortened)
        }
    }

    @ViewBuilder private var actions: some View {
        switch model.secretsView {
        case .exposed:
            if model.scanning {
                Button("Stop") { model.stopScan() }.buttonStyle(.secondary)
            } else if model.exposure != nil {
                Button("Scan Again") { model.scanSecrets() }.buttonStyle(.secondary)
            }
        case .decoys:
            if let status = model.decoys, status.planted > 0 {
                if !status.reads.isEmpty {
                    Button("Clear History") { Task { await model.clearDecoyHistory() } }
                        .buttonStyle(.lowtide(.quiet, size: .small))
                        .disabled(model.decoyBusy)
                }
                Button("Remove Decoys…") {
                    confirm = ConfirmRequest(
                        title: "Remove all decoys?",
                        message: "Moves the decoy files Lowtide planted to the Trash and forgets their read history. Files that were already there are left alone. Nothing will alarm on these paths until you plant again.",
                        confirm: "Remove Decoys") { Task { await model.removeDecoys() } }
                }
                .buttonStyle(.lowtide(.secondary, size: .small))
                .disabled(model.decoyBusy)
            }
        }
    }
}

// MARK: Exposed

private struct ExposedView: View {
    @Environment(\.palette) private var palette
    private var model = ProtectionModel.shared
    @State private var checks = Checks<String>()
    @State private var showIgnored = false
    @State private var confirm: ConfirmRequest?

    static let groups: [(ExposureFinding.Level, String, String, Tone)] = [
        (.critical, "Critical", "Live keys that are synced to the cloud, committed to git, or unprotected keys other users can read. Rotate these first.", .bad),
        (.high, "High", "Tokens in shell history, private keys without a passphrase, and secrets in files that sync or are tracked by git.", .warn),
        (.medium, "Medium", "Tokens in local config and git-ignored .env files. Normal for development, worth knowing where they are.", .neutral),
        (.low, "Low", "Passphrase-protected keys and values that look like test data.", .neutral),
    ]

    var body: some View {
        let findings = model.findings
        let active = findings.filter { !$0.ignored }
        let ignored = findings.filter(\.ignored)
        // In the order shown, so ⇧-click ranges follow the screen.
        let ordered = ExposureFinding.Level.allCases.flatMap { level in active.filter { $0.severity == level } }
        let order = ordered.map(\.id)
        let picked = ordered.filter { checks.has($0.id) }
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    content(active: active, ordered: ordered, order: order, ignored: ignored)
                }
                .padding(.horizontal, Space.page + 4)
                .padding(.top, Space.lg)
                .padding(.bottom, Space.page * 3)
                .frame(maxWidth: 1180, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .overlay(alignment: .top) { Hairline() }
            selectionBar(picked)
        }
        .animation(Motion.base, value: picked.count)
        .confirmation($confirm)
        .onChange(of: model.scanning) { checks.clear() }
    }

    @ViewBuilder
    private func content(active: [ExposureFinding], ordered: [ExposureFinding], order: [String],
                         ignored: [ExposureFinding]) -> some View {
        if model.scanning, active.isEmpty {
            ScanningState(title: "Checked \(model.scanned.formatted()) files…", detail: Paths.tilde(model.scanCurrent))
                .frame(minHeight: 300)
        }
        if model.scanning, !active.isEmpty {
            HStack(spacing: Space.sm) {
                ProgressView().controlSize(.mini)
                Text("Checked \(model.scanned.formatted()) files").monospacedDigit().fixedSize()
                Text(Paths.tilde(model.scanCurrent)).font(.mono(.xxs)).foregroundStyle(palette.ink4.color)
                    .lineLimit(1).truncationMode(.middle)
            }
            .font(.ui(.xs)).foregroundStyle(palette.ink3.color)
        }
        if !model.scanning, model.exposureLoaded, model.exposure == nil {
            VStack(spacing: Space.md) {
                HeroArt("protection", size: 72)
                Text("Find credentials left on disk").font(.ui(.base, .semibold)).foregroundStyle(palette.ink.color)
                Text("Looks through .env files, private keys, tool configs and shell histories in your home folder, iCloud Drive and cloud storage folders.")
                    .font(.ui(.sm)).foregroundStyle(palette.ink3.color).multilineTextAlignment(.center).frame(maxWidth: 420)
                Button("Scan Home Folder") { model.scanSecrets() }.buttonStyle(.primary).padding(.top, Space.xs)
            }
            .frame(maxWidth: .infinity, minHeight: 340)
        }
        if !model.scanning, let report = model.exposure, active.isEmpty {
            VStack(spacing: Space.md) {
                HeroArt("protection", size: 72)
                Text("Nothing exposed in \(report.scanned.formatted()) files").font(.ui(.base, .semibold))
                    .foregroundStyle(palette.ink.color)
                Text("No tokens, passwords or unprotected keys in .env files, tool configs, key files or shell histories.")
                    .font(.ui(.sm)).foregroundStyle(palette.ink3.color).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, minHeight: 300)
        }
        if ordered.count > 1 {
            let all = order.allSatisfy(checks.has)
            HStack(spacing: Space.sm) {
                Checkbox(checks.state(of: order), label: "Select all") { checks.set(order, on: !all) }
                Text("\(LowtideFormat.count(ordered.count, "finding")) · ⇧-click selects a range")
                    .font(.ui(.xs)).foregroundStyle(palette.ink3.color)
            }
            .padding(.leading, Space.sm)
            .padding(.bottom, -Space.sm)
        }
        ForEach(Self.groups, id: \.0) { level, title, reason, tone in
            let group = active.filter { $0.severity == level }
            if !group.isEmpty {
                Pane(title) {
                    Badge("\(group.count)", tone: tone)
                } content: {
                    Text(reason).font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                        .frame(maxWidth: 640, alignment: .leading)
                        .padding(.horizontal, Space.lg).padding(.bottom, Space.md)
                    Hairline()
                    RowStack(items: group) { finding in
                        FindingRow(finding: finding, checked: checks.has(finding.id), confirm: $confirm) {
                            checks.toggle(finding.id, in: order)
                        }
                    }
                }
            }
        }
        if !ignored.isEmpty {
            VStack(alignment: .leading, spacing: Space.sm) {
                Button("\(showIgnored ? "Hide" : "Show") \(ignored.count) Ignored") {
                    withAnimation(Motion.base) { showIgnored.toggle() }
                }
                .buttonStyle(.lowtide(.quiet, size: .small))
                if showIgnored {
                    RowStack(items: ignored) { FindingRow(finding: $0, checked: false, confirm: $confirm, onCheck: nil) }
                        .card()
                }
            }
        }
        QuietNote("Everything stays on this Mac: files are read locally, values never leave the scanner, and only their first few characters are shown.", small: true)
    }

    @ViewBuilder
    private func selectionBar(_ picked: [ExposureFinding]) -> some View {
        let fixable = picked.filter(\.worldReadable)
        let forgettable = picked.filter { $0.history && $0.line != nil }
        SelectionBar(count: picked.count, noun: "finding", clear: { checks.clear() }) {
            if !fixable.isEmpty {
                Button("Fix Permissions \(fixable.count)") { bulkFix(fixable) }.buttonStyle(.lowtide(.secondary, size: .small))
            }
            if !forgettable.isEmpty {
                Button("Remove from History \(forgettable.count)") { askForget(forgettable) }
                    .buttonStyle(.lowtide(.secondary, size: .small))
            }
            Button("Ignore") { bulkIgnore(picked) }.buttonStyle(.lowtide(.quiet, size: .small))
        }
    }

    private func bulkFix(_ findings: [ExposureFinding]) {
        let paths = Array(Set(findings.map(\.path)))
        Task {
            var failed = 0
            for path in paths {
                do { try await Exposure.shared.fixPermissions(path) } catch { failed += 1 }
            }
            await model.reloadExposure()
            checks.clear()
            let done = paths.count - failed
            Toasts.shared.show(failed == 0 ? "\(LowtideFormat.count(done, "file")) now readable only by you"
                               : "\(done) fixed, \(failed) couldn't be changed", tone: failed == 0 ? .ok : .warn)
        }
    }

    private func bulkIgnore(_ findings: [ExposureFinding]) {
        Task {
            for finding in findings { await Exposure.shared.ignore(finding.id, true) }
            await model.reloadExposure()
            checks.clear()
            Toasts.shared.show("\(LowtideFormat.count(findings.count, "finding")) ignored")
        }
    }

    private func askForget(_ findings: [ExposureFinding]) {
        confirm = ConfirmRequest(
            title: "Remove from shell history?",
            message: "Deletes \(LowtideFormat.count(findings.count, "command")) from your shell history. Rotate those secrets too: anything that read the history may already have them. No copy is kept, and shells that are open now may write their own history back when they exit.",
            confirm: "Remove the Entries") {
            // All of a history file's lines go in one rewrite.
            let byFile = Dictionary(grouping: findings, by: \.path)
            Task {
                var removed = 0, failures: [String] = []
                for (path, group) in byFile {
                    do {
                        removed += try await Exposure.shared.forgetHistory(path, lines: group.compactMap(\.line))
                    } catch {
                        failures.append("\(Paths.tilde(path)): \(error.localizedDescription)")
                    }
                }
                await model.reloadExposure()
                checks.clear()
                if failures.isEmpty {
                    Toasts.shared.show("Removed \(LowtideFormat.count(removed, "line")) from history")
                } else {
                    Toasts.shared.show("Some history couldn't be edited", detail: failures.joined(separator: "\n"), tone: .bad)
                }
            }
        }
    }
}

/// One finding: what it is, where, why it matters, and the fixes.
private struct FindingRow: View {
    @Environment(\.palette) private var palette
    @Environment(\.privacy) private var privacy
    @State private var hovering = false
    private var model = ProtectionModel.shared
    let finding: ExposureFinding
    let checked: Bool
    @Binding var confirm: ConfirmRequest?
    /// Ignored findings can't be checked.
    var onCheck: (() -> Void)?

    init(finding: ExposureFinding, checked: Bool, confirm: Binding<ConfirmRequest?>, onCheck: (() -> Void)?) {
        self.finding = finding
        self.checked = checked
        _confirm = confirm
        self.onCheck = onCheck
    }

    private var canFix: Bool { finding.worldReadable && !finding.ignored }
    private var canForget: Bool { finding.history && finding.line != nil && !finding.ignored }

    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            if let onCheck {
                Checkbox(checked, label: "Select \(finding.label) in \(finding.path)", toggle: onCheck)
                    .padding(.top, 1)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                    Text(finding.label).font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color).fixedSize()
                    Text(finding.preview).font(.mono(.xxs)).foregroundStyle(palette.ink3.color).lineLimit(1)
                }
                Text(privacy ? Paths.tilde(finding.location).replacingOccurrences(of: "/Users/", with: "/Users/•••/") : finding.location)
                    .font(.mono(.xxs)).foregroundStyle(palette.ink4.color)
                    .lineLimit(1).truncationMode(.middle).help(finding.path).textSelection(.enabled)
                let flags = Self.flags(finding)
                if !flags.isEmpty {
                    HStack(spacing: Space.xs + 2) {
                        ForEach(flags, id: \.0) { flag, risky in Badge(flag, tone: risky ? .warn : .neutral) }
                    }
                    .padding(.top, Space.xs + 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: Space.xs) {
                if canFix { Button("Fix Permissions", action: fix).buttonStyle(.lowtide(.secondary, size: .small)) }
                if canForget { Button("Remove from History…", action: askForget).buttonStyle(.lowtide(.secondary, size: .small)) }
                Group {
                    Button("Show in Finder") { FileActions.reveal(finding.path) }
                    if finding.kind != "certificate-bundle" { Button("Open", action: open) }
                }
                .buttonStyle(.lowtide(.quiet, size: .small))
                .opacity(hovering ? 1 : 0)
                Button(finding.ignored ? "Restore" : "Ignore", action: ignore)
                    .buttonStyle(.lowtide(.quiet, size: .small))
                    .opacity(hovering || finding.ignored ? 1 : 0)
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .animation(Motion.fast, value: hovering)
        .contextMenu {
            Button("Show in Finder") { FileActions.reveal(finding.path) }
            Button("Copy Path") { FileActions.copy(finding.path) }
            if canFix || canForget { Divider() }
            if canFix { Button("Fix Permissions", action: fix) }
            if canForget { Button("Remove from History…", action: askForget) }
            Divider()
            Button(finding.ignored ? "Restore" : "Ignore", action: ignore)
        }
    }

    /// Why this finding matters, as short plain phrases; risky ones in amber.
    static func flags(_ f: ExposureFinding) -> [(String, Bool)] {
        var flags: [(String, Bool)] = []
        if f.synced {
            flags.append((f.path.contains("/Library/Mobile Documents/") ? "Synced to iCloud" : "Synced to cloud storage", true))
        }
        if f.tracked { flags.append(("Tracked by git", true)) } else if f.inGit { flags.append(("Git-ignored", false)) }
        if f.worldReadable { flags.append(("Readable by other users", true)) }
        if f.history { flags.append(("In shell history", true)) }
        if f.encrypted == true { flags.append(("Passphrase protected", false)) }
        if f.encrypted == false { flags.append(("No passphrase", true)) }
        if f.test { flags.append(("Looks like a test value", false)) }
        return flags
    }

    private func fix() {
        Task {
            await model.exposureAction("Couldn't change permissions") { try await Exposure.shared.fixPermissions(finding.path) }
            Toasts.shared.show("Only you can read this file now")
        }
    }

    private func open() {
        Task {
            do { try await Exposure.shared.open(finding.path) } catch { Toasts.shared.failure("Couldn't open", error) }
        }
    }

    private func ignore() {
        Task { await model.exposureAction("Couldn't save") { await Exposure.shared.ignore(finding.id, !finding.ignored) } }
    }

    private func askForget() {
        let line = finding.line ?? 0
        let path = finding.path
        confirm = ConfirmRequest(
            title: "Remove from shell history?",
            message: "Deletes the command on line \(line) of \(Paths.tilde(path)). Rotate the \(finding.label.lowercased()) too: anything that read this file may already have it. No copy is kept, and shells that are open now may write their own history back when they exit.",
            confirm: "Remove the Entry") {
            Task {
                do {
                    let removed = try await Exposure.shared.forgetHistory(path, lines: [line])
                    Toasts.shared.show("Removed \(LowtideFormat.count(removed, "line")) from history")
                } catch {
                    Toasts.shared.failure("Couldn't edit history", error)
                }
                await ProtectionModel.shared.reloadExposure()
            }
        }
    }
}
