import LowtideKit
import SwiftUI

/// The network monitor's threat findings (suspicious apps, breaks from an
/// app's normal, odd domain lookups). The network space wires this at
/// integration; without it Threats shows what Protection finds on the Mac.
enum ThreatSources {
    static var network: (() async -> [ThreatFinding])?
}

/// What other spaces give Protection. Each is optional.
enum ProtectionHooks {
    /// Lowtide's local terminals and the network monitor's connections,
    /// for command receipts. Changing it after launch takes effect at once.
    static var runSources = RunSources() {
        didSet { Task { await RunEngine.shared.setSources(runSources) } }
    }
    /// Last week's traffic for an app (by name), for the permission map.
    static var traffic: (@Sendable (String) async -> PermissionMap.Traffic?)?
    /// The privileged helper's launchd switch (on, label) → done, or nil to
    /// fall back to the password prompt.
    static var privilegedLaunchd: (@Sendable (Bool, String) async -> Bool?)? {
        didSet { Task { await PermissionActions.shared.setPrivilegedLaunchd(privilegedLaunchd) } }
    }
    /// Every alert, for the network space's event log.
    static var onAlert: ((ProtectionAlert) -> Void)?
}

/// Protection's state for its pages, the sidebar badges and Home: the
/// decoys, the last secrets scan, the permission map, network threats, and
/// the summary of what needs a look.
@Observable
final class ProtectionModel {
    static let shared = ProtectionModel()

    enum SecretsView: String, Hashable { case exposed, decoys }
    /// Which view the Secrets page shows (Overview opens either).
    var secretsView: SecretsView = .exposed

    // MARK: Decoys

    private(set) var decoys: Decoys.Status?
    var decoyBusy = false

    func reloadDecoys() async { decoys = await DecoyWatch.shared.status(errors: decoys?.errors ?? []) }

    /// The watcher saw a change (a trip, a decoy someone replaced).
    func apply(_ status: Decoys.Status) {
        decoys = status
        updateBadges()
    }

    func plantDecoys(_ ids: [String]? = nil) async {
        decoyBusy = true
        decoys = await DecoyWatch.shared.plant(ids: ids)
        decoyBusy = false
        if let errors = decoys?.errors, !errors.isEmpty {
            Toasts.shared.show("Some decoys weren't planted", detail: errors.joined(separator: "\n"), tone: .warn)
        }
        updateBadges()
    }

    func removeDecoys() async {
        decoyBusy = true
        decoys = await DecoyWatch.shared.remove()
        decoyBusy = false
        updateBadges()
        Toasts.shared.show("Removed the decoys", detail: "They're in the Trash; nothing alarms on those paths now.")
    }

    func clearDecoyHistory() async {
        decoys = await DecoyWatch.shared.clearHistory()
        updateBadges()
    }

    // MARK: Exposed secrets

    private(set) var exposure: ExposureReport?
    private(set) var exposureLoaded = false
    private(set) var scanning = false
    private(set) var scanned = 0
    private(set) var scanCurrent = ""
    private(set) var live: [ExposureFinding] = []
    private var watcher: FileWatcher?

    /// What the page lists: the live scan, else the last report.
    var findings: [ExposureFinding] { scanning ? live : exposure?.findings ?? [] }

    func reloadExposure() async {
        exposure = await Exposure.shared.last()
        exposureLoaded = true
        updateBadges()
    }

    func scanSecrets() {
        guard !scanning else { return }
        scanning = true
        live = []
        scanned = 0
        scanCurrent = ""
        Task {
            let result = await Exposure.shared.scan { event in
                Task { @MainActor in ProtectionModel.shared.receive(event) }
            }
            scanning = false
            if let result {
                exposure = result.report
                if result.freshCritical > 0 {
                    let noun = result.freshCritical == 1 ? "secret is" : "secrets are"
                    raise(ProtectionAlert(kind: .exposure, severity: .alert, subject: "Secrets",
                                          text: "\(result.freshCritical) new critical \(noun) exposed on disk"))
                }
            } else {
                exposure = await Exposure.shared.last()
            }
            await watchExposure()
            updateBadges()
        }
    }

    private func receive(_ event: ExposureEvent) {
        guard scanning else { return }
        switch event {
        case .progress(let count, let current):
            scanned = count
            scanCurrent = current
        case .finding(let finding):
            live.append(finding)
        }
    }

    func stopScan() { Exposure.shared.cancel() }

    /// Runs one change to the store, then reloads; failures are toasts.
    func exposureAction(_ failure: String, _ work: () async throws -> Void) async {
        do { try await work() } catch { Toasts.shared.failure(failure, error) }
        await reloadExposure()
    }

    /// Re-reads reported files as they change, so the report stays true
    /// after an edit, a fix or a delete.
    func watchExposure() async {
        watcher?.stop()
        let folders = await Exposure.shared.watchedFolders()
        guard !folders.isEmpty else {
            watcher = nil
            return
        }
        watcher = FileWatcher(paths: folders, latency: 1.5) { changed in
            Task { @MainActor in
                var touched = false
                for path in Set(changed) where await Exposure.shared.matters(path) {
                    await Exposure.shared.refresh(path)
                    touched = true
                }
                if touched { await ProtectionModel.shared.reloadExposure() }
            }
        }
    }

    func stopWatchingExposure() {
        watcher?.stop()
        watcher = nil
    }

    // MARK: Permissions

    private(set) var permissions: PermissionMap.Snapshot?
    private(set) var permissionsLoading = false
    /// The last scan asked System Events for the Open at Login list.
    private var permissionsFull = false

    /// Rescans unless the map is fresh. `full` includes Open at Login (the
    /// first time, macOS asks to let Lowtide read it).
    func loadPermissions(force: Bool = false, full: Bool = true) async {
        if !force, let permissions, permissionsFull || !full, Date.now.timeIntervalSince(permissions.scannedAt) < 300 { return }
        guard !permissionsLoading else { return }
        permissionsLoading = true
        // The first map comes without Open at Login (System Events can take
        // seconds, or wait on its permission prompt): show it, then add those.
        if full, permissions == nil {
            let quick = await PermissionMap.scan(loginItems: false, traffic: ProtectionHooks.traffic)
            await PermissionActions.shared.remember(quick)
            permissions = quick
        }
        let map = await PermissionMap.scan(loginItems: full, traffic: ProtectionHooks.traffic)
        await PermissionActions.shared.remember(map)
        permissions = map
        permissionsFull = full
        permissionsLoading = false
        updateBadges()
    }

    // MARK: Network threats

    /// nil until the network monitor answered (or when it isn't wired).
    private(set) var network: [ThreatFinding]?
    var networkWired: Bool { ThreatSources.network != nil }

    func reloadNetwork() async {
        guard let source = ThreatSources.network else { return }
        network = await source()
        updateBadges()
    }

    var flaggedApps: [ThreatFinding] { (network ?? []).filter { $0.kind == .app && $0.score >= ThreatFinding.flag } }

    /// What Protection itself found on the Mac.
    var local: [ThreatFinding] {
        ThreatFinding.local(runs: RunsStore.shared.runs, decoys: decoys, exposure: exposure, permissions: permissions)
    }

    // MARK: Alerts

    /// Tells the person: a toast while the window is in front, a
    /// notification otherwise; and the network's event log hears it.
    func raise(_ alert: ProtectionAlert) {
        ProtectionHooks.onAlert?(alert)
        updateBadges()
        let tone: Tone = alert.severity == .alert ? .bad : .warn
        if NSApp.isActive, NSApp.keyWindow != nil {
            Toasts.shared.show(alert.text, tone: tone, action: "Review") { [weak self] in self?.open(alert) }
            return
        }
        let title = switch alert.kind {
        case .tripwire: "Install watch"
        case .decoy: "A decoy key was read"
        case .exposure: "Exposed secrets"
        }
        Notify.post(title, [alert.text], sound: true)
    }

    func open(_ alert: ProtectionAlert) {
        switch alert.kind {
        case .tripwire: AppModel.shared.show(.installWatch)
        case .decoy: openSecrets(.decoys)
        case .exposure: openSecrets(.exposed)
        }
    }

    func openSecrets(_ view: SecretsView) {
        secretsView = view
        AppModel.shared.show(.secrets)
    }

    // MARK: The summary

    static let day: TimeInterval = 86_400

    var installAlerts: Int {
        let since = UInt64((Date.now.timeIntervalSince1970 - Self.day) * 1000)
        return RunsStore.shared.installs.filter { $0.verdict == .alert && $0.started >= since }.count
    }

    var decoyReads: Int { decoys?.reads(since: UInt64((Date.now.timeIntervalSince1970 - Self.day) * 1000)) ?? 0 }

    var activeSecrets: [ExposureFinding] { (exposure?.findings ?? []).filter { !$0.ignored } }
    var criticalSecrets: Int { activeSecrets.filter { $0.severity == .critical }.count }

    /// Threats that need a look: flagged apps. What Protection finds on the
    /// Mac is badged where it is dealt with (Secrets, Install watch), never twice.
    var threatCount: Int { flaggedApps.count }

    func updateBadges() {
        let badges = SidebarBadges.shared
        set(badges, .threats, threatCount)
        set(badges, .secrets, criticalSecrets + decoyReads)
        set(badges, .installWatch, installAlerts)
    }

    private func set(_ badges: SidebarBadges, _ page: Page, _ count: Int) {
        badges.counts[page] = count > 0 ? count : nil
        if count > 0 { badges.warning.insert(page) } else { badges.warning.remove(page) }
    }

    /// One thing Home lists under "needs a look".
    struct Attention: Identifiable, Hashable {
        var id: String
        var text: String
        var tone: Tone
        var page: Page
    }

    /// What needs the person, worst first, in words.
    var attention: [Attention] {
        var items: [Attention] = []
        let plural = LowtideFormat.count
        if installAlerts > 0 {
            items.append(Attention(id: "installs", text: "\(plural(installAlerts, "install", nil)) need a look", tone: .bad,
                                   page: .installWatch))
        }
        if decoyReads > 0 {
            items.append(Attention(id: "decoys", text: decoyReads == 1 ? "A decoy key was read" : "Decoy keys were read \(decoyReads) times",
                                   tone: .bad, page: .secrets))
        }
        if criticalSecrets > 0 {
            items.append(Attention(id: "secrets", text: "\(plural(criticalSecrets, "secret", nil)) exposed", tone: .warn,
                                   page: .secrets))
        }
        if !flaggedApps.isEmpty {
            items.append(Attention(id: "threats", text: "\(plural(flaggedApps.count, "app", nil)) flagged on the network",
                                   tone: .warn, page: .threats))
        }
        if let broken = permissions?.broken, broken > 0 {
            items.append(Attention(id: "startup", text: plural(broken, "broken start-up item", nil), tone: .warn,
                                   page: .permissions))
        }
        return items
    }

    /// Home's line about Protection.
    var headline: (text: String, tone: Tone) {
        let items = attention
        if items.isEmpty { return ("Protection: nothing needs you", .ok) }
        return (items.count == 1 ? items[0].text : "\(items.count) things in Protection need you",
                items.contains { $0.tone == .bad } ? .bad : .warn)
    }
}
