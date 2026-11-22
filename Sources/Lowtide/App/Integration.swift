import LowtideKit
import Foundation
import Observation
import Synchronization

/// Connects the spaces: each one leaves hooks for data another space owns,
/// and this fills them with thin adapters over the owner's model or engine.
/// Called once at launch, before the spaces' `launch()`.
nonisolated enum Integration {
    @MainActor static func wire() {
        wireProtection()
        wireNetwork()
        wirePrivileged()
        FleetMonitor.setGeoLookup(fleetPlace)
        WidgetsLifecycle.networkFacts = widgetFacts
        wireCommandBar()
        wireAsk()
        follow({ ToolchainModel.shared.toolUpdateCount }) { count in
            if AppUpdatesModel.shared.toolUpdates != count { AppUpdatesModel.shared.toolUpdates = count }
        }
        RecipeModel.runInTerminal = { command in
            SessionStore.shared.openLocal(title: "Mac recipe", initialInput: command)
            AppModel.shared.show(.sessions)
        }
        wireReceipts()
    }

    // MARK: Protection ← Network, Terminal

    @MainActor private static func wireProtection() {
        ThreatSources.network = { networkThreats(NetworkModel.shared.overview) }
        ProtectionHooks.runSources = RunSources(
            terminals: {
                TerminalSessions.shared.foregrounds().filter { $0.kind == TerminalTab.Kind.local.rawValue }
                    .map { TerminalShell(id: $0.id, shell: $0.shell) }
            },
            connections: { NetworkEngine.shared.connections().filter { !$0.listening }.map(runConnection) },
            hostName: { NetworkEngine.shared.hostName(for: $0) },
            place: { ip in GeoIP.shared.lookup(ip).map { (org: $0.org, country: $0.country) } },
            boost: { NetworkEngine.shared.boost() })
        ProtectionHooks.traffic = { traffic($0) }
        ProtectionHooks.onAlert = { alert in NetworkEngine.shared.push(netEvent(alert)) }
    }

    /// Apps the monitor scores, its breaks from normal (last hour) and odd
    /// domain lookups, as Threats rows.
    static func networkThreats(_ overview: NetOverview) -> [ThreatFinding] {
        var found: [ThreatFinding] = []
        for app in overview.apps where app.score > 0 {
            let facts = "\(app.signature.label) · \(Format.count(app.conns, "connection")) to \(Format.count(app.hosts, "host")) · "
                + "\(Format.bytes(app.bytesIn)) in, \(Format.bytes(app.bytesOut)) out"
            found.append(ThreatFinding(
                id: "app:\(app.id)", kind: .app, title: app.name,
                detail: app.path ?? "pid \(app.pids.map(String.init).joined(separator: ", "))",
                score: app.score, severity: app.flagged ? .alert : .notice,
                reasons: app.reasons.map { .init(points: $0.points, label: $0.label) },
                summary: facts, appPath: app.app, path: app.path))
        }
        for event in overview.events {
            found.append(ThreatFinding(id: "event:\(event.id)", kind: .event, title: event.text,
                                       severity: event.severity == .alert ? .alert : .notice, at: event.t.date))
        }
        for record in overview.domainAlerts {
            found.append(ThreatFinding(id: "domain:\(record.id)", kind: .domain, title: record.name, detail: record.suspicious,
                                       severity: .notice, at: record.t.date))
        }
        return found
    }

    static func runConnection(_ conn: NetConn) -> RunConnection {
        RunConnection(id: UInt64(clamping: conn.id), pid: conn.pid, app: conn.app, ip: conn.remote, port: conn.remotePort,
                      bytesIn: UInt64(clamping: conn.bytesIn), bytesOut: UInt64(clamping: conn.bytesOut),
                      firstSeen: UInt64(clamping: conn.firstSeen), host: conn.host, org: conn.org, country: conn.country)
    }

    /// Protection's alert as an entry in the network's event log (its
    /// kinds: `tripwire`, `canary`, `exposure`).
    static func netEvent(_ alert: ProtectionAlert) -> NetEvent {
        NetEvent(t: Millis(clamping: alert.at), kind: alert.kind == .decoy ? "canary" : alert.kind.rawValue,
                 severity: alert.severity == .alert ? .alert : .notice, app: alert.subject, text: alert.text)
    }

    /// Last week's ledger, read once for a whole permission scan (it asks per app).
    private static let weekLedger = Mutex<(at: Millis, tallies: [String: Tally])>((0, [:]))

    /// Last week's traffic for an app, matched by name:
    /// the ledger keys by process name, which is usually the app's.
    static func traffic(_ app: String) -> PermissionMap.Traffic? {
        let tallies = weekLedger.withLock { cache in
            if Millis.now - cache.at > 10_000 { cache = (.now, NetworkEngine.shared.ledger(days: 7)) }
            return cache.tallies
        }
        let name = app.lowercased()
        var total = PermissionMap.Traffic(bytesIn: 0, bytesOut: 0, hosts: 0, countries: [])
        var found = false
        for (process, tally) in tallies {
            let process = process.lowercased()
            guard process == name || process.hasPrefix(name + " ") else { continue }
            found = true
            total.bytesIn += UInt64(clamping: tally.bytesIn)
            total.bytesOut += UInt64(clamping: tally.bytesOut)
            total.hosts += tally.hosts.count
            for country in tally.countries.sorted() where !total.countries.contains(country) { total.countries.append(country) }
        }
        return found ? total : nil
    }

    // MARK: Network ← Protection

    /// Package installs Protection followed, for the overnight report
    /// (NightShift asks synchronously, so it reads a copy kept here).
    private static let installs = Mutex<[Run]>([])

    @MainActor private static func wireNetwork() {
        follow({ RunsStore.shared.runs }) { runs in
            let list = runs.filter { $0.ecosystem != nil }
            installs.withLock { $0 = list }
        }
        NightShift.installs.withLock { $0 = installLines }
    }

    @Sendable static func installLines(_ from: Millis, _ to: Millis) -> [Briefing.InstallLine] {
        installs.withLock { runs in
            runs.filter { Millis(clamping: $0.ended) >= from && Millis(clamping: $0.started) <= to }.map {
                Briefing.InstallLine(id: Int64(clamping: $0.id), t: Millis(clamping: $0.started), command: $0.command,
                                     verdict: $0.verdict.rawValue, source: $0.source.rawValue)
            }
        }
    }

    // MARK: The privileged helper (Apps) → Protection, Network

    /// Each returns nil (or false) while the helper is off, so the caller
    /// asks for the password instead.
    @MainActor private static func wirePrivileged() {
        ProtectionHooks.privilegedLaunchd = { on, label in await PrivilegedHelper.launchd(enable: on, label: label) }
        CaptureAccessHook.helper = { await PrivilegedHelper.bpf() ?? false }
    }

    // MARK: Terminal ← Network, Widgets ← Network

    @Sendable static func fleetPlace(_ ip: String) -> Fleet.Place? {
        GeoIP.shared.lookup(ip).map { Fleet.Place(country: $0.country, org: $0.org) }
    }

    @MainActor static func widgetFacts() -> NetworkFacts? {
        guard NetworkModel.shared.overview.ready else { return nil }
        let summary = NetworkEngine.shared.summary()
        return NetworkFacts(todayIn: Double(summary.todayIn), todayOut: Double(summary.todayOut),
                            top: summary.top.map { (name: $0.name, down: Double($0.rateIn), up: Double($0.rateOut)) })
    }

    // MARK: Command bar ← System, Remote, Network

    @MainActor private static func wireCommandBar() {
        CommandBarHooks.quickControls = SystemQuickControls()
        CommandBarHooks.hosts = {
            RemoteStore.shared.snapshot.hosts.map { host in
                CommandBarHooks.Host(id: host.id, name: host.name, address: "\(host.username)@\(host.hostname)") {
                    RemoteStore.shared.connect(host)
                }
            }
        }
        CommandBarHooks.watchFacts = {
            guard NetworkModel.shared.overview.ready else { return nil }
            let s = NetworkEngine.shared.summary()
            return CommandBarHooks.WatchFacts(rateIn: Double(s.rateIn), rateOut: Double(s.rateOut), todayIn: s.todayIn,
                                              todayOut: s.todayOut, alerts: s.alerts, lastAlert: s.lastAlert)
        }
    }

    // MARK: Terminal ← Protection (receipts under each pane)

    /// The newest run already handed to a terminal.
    @MainActor private static var receiptsUpTo: UInt64 = 0
    @MainActor private static var activityShown: [TerminalSessions.Activity] = []

    @MainActor private static func wireReceipts() {
        follow({ RunsStore.shared.runs.first?.id }) { _ in
            let fresh = RunsStore.shared.runs.filter { $0.id > receiptsUpTo }
            receiptsUpTo = max(receiptsUpTo, fresh.map(\.id).max() ?? 0)
            // Runs loaded from disk at launch aren't news.
            let recent = Clock.now - 60_000
            for run in fresh.reversed() where run.ended >= recent {
                if let receipt = receipt(run) { TerminalSessions.shared.put(receipt) }
            }
        }
        // The live line: asked of the engine only while a terminal runs something.
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let busy = TerminalSessions.shared.foregrounds().contains { $0.group != $0.shell }
                guard busy || !activityShown.isEmpty else { continue }
                let live = await RunEngine.shared.following().compactMap(activity)
                guard live != activityShown else { continue }
                activityShown = live
                TerminalSessions.shared.setActivity(live)
            }
        }
    }

    static func receipt(_ run: Run) -> TerminalSessions.Receipt? {
        guard run.source == .terminal, let session = run.ptyId else { return nil }
        let summary = run.verdict != .info ? run.findings.first?.text ?? ""
            : "\(Format.count(run.net.dests.count, "host")) · \(Format.count(run.files.total, "file"))"
        return TerminalSessions.Receipt(sessionID: session, runID: String(run.id), command: run.command, started: run.startedAt,
                                        ended: run.endedAt, verdict: .init(rawValue: run.verdict.rawValue) ?? .info,
                                        summary: summary)
    }

    static func activity(_ run: ActiveRun) -> TerminalSessions.Activity? {
        guard run.source == .terminal, let session = run.ptyId else { return nil }
        return TerminalSessions.Activity(sessionID: session, command: run.command, started: Clock.date(run.started),
                                         hosts: run.dests, files: run.files)
    }

    // MARK: Helpers

    /// Runs `apply` with `read()` now and again whenever what it read changes.
    @MainActor static func follow<T>(_ read: @escaping @MainActor @Sendable () -> T,
                                     _ apply: @escaping @MainActor @Sendable (T) -> Void) {
        let value = withObservationTracking { read() } onChange: {
            Task { @MainActor in follow(read, apply) }
        }
        apply(value)
    }
}

/// The command bar's Tools over the System space's tools.
nonisolated struct SystemQuickControls: QuickControls {
    func state() async -> QuickControlsState? {
        let tools = await Tools.state()
        let xdr = await MainActor.run { XDRBoost.shared.isAvailable }
        var state = QuickControlsState()
        state.awake = .init(on: tools.awake.on, display: tools.awake.display, until: tools.awake.until)
        state.brightness = tools.brightness
        state.boostLevel = Int((tools.boost.level * 100).rounded())
        state.boostSupported = xdr ? tools.boost.supported : false
        state.micMuted = tools.microphoneMuted
        state.outputs = tools.outputs.map { .init(id: $0.id, name: $0.name, current: $0.isCurrent) }
        return state
    }

    func keepAwake(minutes: Int?, display: Bool) async throws {
        try await MainActor.run { try KeepAwake.shared.start(minutes: minutes, display: display) }
    }

    func stopKeepingAwake() async throws { await MainActor.run { KeepAwake.shared.stop() } }
    func setBrightness(_ level: Double) async throws { try Brightness.set(level) }
    func setBoost(_ level: Int) async throws { try await MainActor.run { try XDRBoost.shared.set(level: Double(level) / 100) } }
    func toggleMicrophone() async throws -> Bool { try await Sound.toggleMicrophone() }
    func setOutput(_ id: UInt32) async throws { try Sound.selectOutput(id) }
    func pickColor() async -> String? { await ColorPicker.pick()?.hex }
}

// MARK: - Self-test

extension Integration {
    /// Waits (up to 20 s) for the network monitor's first snapshot.
    @MainActor private static func networkReady() async -> Bool {
        for _ in 0..<40 where !NetworkModel.shared.overview.ready { try? await Task.sleep(for: .milliseconds(500)) }
        return NetworkModel.shared.overview.ready
    }

    /// One step per hook `wire()` fills, each calling it the way its space does.
    @MainActor static var selfTests: [SelfTest.Step] {
        [
            SelfTest.Step("threats hear the network monitor") {
                guard await networkReady(), let source = ThreatSources.network else { return false }
                let apps = await source().filter { $0.kind == .app }
                return apps.count == NetworkModel.shared.overview.apps.filter { $0.score > 0 }.count
            },
            SelfTest.Step("command receipts reach the terminals and the network") {
                let s = ProtectionHooks.runSources
                guard let terminals = s.terminals, let connections = s.connections, let place = s.place, s.hostName != nil, s.boost != nil
                else { return false }
                _ = terminals()
                _ = await connections()
                return await place("8.8.8.8")?.country == "US"
            },
            SelfTest.Step("protection's alerts land in the network's event log") {
                let text = "Self-test \(UUID().uuidString)"
                ProtectionHooks.onAlert?(ProtectionAlert(kind: .exposure, severity: .notice, subject: "Self-test", text: text))
                return NetworkEngine.shared.history(since: .now - 5_000).contains { $0.text == text && $0.kind == "exposure" }
            },
            SelfTest.Step("the permission map reads last week's traffic") {
                guard let traffic = ProtectionHooks.traffic else { return false }
                return await traffic("no such app \(UUID().uuidString)") == nil
            },
            SelfTest.Step("privileged hooks fall back to the password while the helper is off") {
                guard PrivilegedHelper.state != .on else { return true }
                guard let launchd = ProtectionHooks.privilegedLaunchd, let bpf = CaptureAccessHook.helper else { return false }
                let refused = await launchd(true, "dev.lowtide.selftest") == nil
                let noCapture = await bpf() == false
                let trashed = await PrivilegedHelper.trash(["/nonexistent/lowtide-selftest"])
                return refused && noCapture && trashed == nil
            },
            SelfTest.Step("the overnight report lists protection's installs") {
                guard let lines = NightShift.installs.withLock({ $0 }) else { return false }
                return lines(0, .now).count == RunsStore.shared.installs.count
            },
            SelfTest.Step("the fleet places servers with the geo database") { fleetPlace("8.8.8.8")?.country == "US" },
            SelfTest.Step("widgets and the command bar get today's traffic") {
                guard await networkReady(), let facts = WidgetsLifecycle.networkFacts?(), let watch = CommandBarHooks.watchFacts()
                else { return false }
                return facts.todayIn >= 0 && watch.todayIn >= 0
            },
            SelfTest.Step("the command bar's tools read the system tools") {
                guard let state = await CommandBarHooks.quickControls.state() else { return false }
                return state.awake.on == KeepAwake.shared.state.on
            },
            SelfTest.Step("the command bar lists the saved hosts") {
                await RemoteStore.shared.load()
                return CommandBarHooks.hosts().map(\.id) == RemoteStore.shared.snapshot.hosts.map(\.id)
            },
            SelfTest.Step("every Ask tool is wired and answers") {
                for tool in AskTools.all {
                    guard tool.run != nil else { return false }
                    let answer = await AskTools.run(tool.name, AskArguments())
                    if answer.isEmpty || answer.hasPrefix("There is no tool") { return false }
                }
                return true
            },
            SelfTest.Step("app updates count the toolchain's") {
                await Task.yield()
                return AppUpdatesModel.shared.toolUpdates == ToolchainModel.shared.toolUpdateCount
            },
            SelfTest.Step("the Mac recipe runs in a terminal of Lowtide") { RecipeModel.runInTerminal != nil },
            SelfTest.Step("a finished terminal command becomes its pane's receipt") {
                let run = Run(id: .max, source: .terminal, ptyId: "selftest-\(UUID().uuidString)", command: "echo ok",
                              started: Clock.now - 1_000, ended: Clock.now)
                guard let receipt = receipt(run), let session = run.ptyId else { return false }
                TerminalSessions.shared.put(receipt)
                defer { TerminalSessions.shared.dismiss(session) }
                return TerminalSessions.shared.receipt(session)?.runID == String(run.id) && receipt.summary == "0 hosts · 0 files"
            },
        ]
    }
}

// MARK: - Ask ← every space

/// Each Ask tool answers with a short, ranked summary from the space that
/// owns the data, tool by tool.
nonisolated extension Integration {
    @MainActor static func wireAsk() {
        AskTools.wire("network_usage") { networkUsage(NetworkEngine.shared.ledger(days: days($0)), days: days($0), app: $0.text("app")) }
        AskTools.wire("live_traffic") { _ in liveTraffic(NetworkEngine.shared.overview()) }
        AskTools.wire("countries_reached") {
            countriesReached(NetworkEngine.shared.ledger(days: days($0)), days: days($0), country: $0.text("country"))
        }
        AskTools.wire("recent_events") { args in
            let hours = min(max(args.int("hours", default: 24), 1), 720)
            let from = Millis.now - Millis(hours) * 3_600_000
            return recentEvents(NetworkEngine.shared.history(since: from), briefings: NightShift.shared.between(from, .now),
                                from: from, hours: hours)
        }
        AskTools.wire("command_runs") { args in
            commandRuns(await RunEngine.shared.list(installsOnly: args.flag("installsOnly")), query: args.text("query"))
        }
        AskTools.wire("away_briefings") { _ in awayBriefings(NightShift.shared.briefings) }
        AskTools.wire("servers") { _ in servers(await MainActor.run { RemoteStore.shared.fleet }) }
        AskTools.wire("security_status") { _ in
            let week = Clock.now - 7 * 86_400_000
            return securityStatus(decoys: await DecoyWatch.shared.status(), exposure: await Exposure.shared.last(),
                                  installs: await RunEngine.shared.runs(from: week, to: Clock.now).filter { $0.ecosystem != nil },
                                  flagged: NetworkEngine.shared.summary().flagged.map(\.name))
        }
        AskTools.wire("app_updates") { _ in await MainActor.run { appUpdates() } }
    }

    private static func days(_ args: AskArguments) -> Int { min(max(args.int("days", default: 7), 1), 35) }

    private static func period(_ days: Int) -> String { days == 1 ? "today" : "the last \(days) days" }

    private static func ago(_ ms: Millis) -> String { Format.ago(ms.date) }

    private static func countries(_ tally: Tally) -> String {
        tally.countries.isEmpty ? "" : " (\(tally.countries.sorted().joined(separator: ", ")))"
    }

    static func networkUsage(_ tallies: [String: Tally], days: Int, app: String) -> String {
        let period = period(days)
        if tallies.isEmpty { return "No traffic recorded for \(period) yet." }
        if !app.isEmpty {
            guard let (name, tally) = tallies.sorted(by: { $0.key < $1.key }).first(where: { $0.key.lowercased().contains(app) }) else {
                return "No app matching \"\(app)\" used the network in \(period)."
            }
            let hosts = tally.hosts.sorted().prefix(10)
            return "\(name) in \(period): sent \(Format.bytes(tally.bytesOut)), received \(Format.bytes(tally.bytesIn))\(countries(tally)). "
                + "Hosts include: \(hosts.isEmpty ? "none named" : hosts.joined(separator: ", "))."
        }
        let bySent = tallies.sorted { ($0.value.bytesOut, $1.key) > ($1.value.bytesOut, $0.key) }
        var out = "Ranked by data sent (uploaded), \(period):\n"
        for (rank, (name, tally)) in bySent.prefix(8).enumerated() {
            out += "\(rank + 1). \(name): sent \(Format.bytes(tally.bytesOut)), received \(Format.bytes(tally.bytesIn))\(countries(tally))\n"
        }
        let received = tallies.sorted { ($0.value.bytesIn, $1.key) > ($1.value.bytesIn, $0.key) }.prefix(5).enumerated()
            .map { "\($0.offset + 1). \($0.element.key) \(Format.bytes($0.element.value.bytesIn))" }
        out += "Ranked by data received (downloaded): \(received.joined(separator: ", ")).\n"
        let sent = tallies.values.reduce(Int64(0)) { $0 + $1.bytesOut }, got = tallies.values.reduce(Int64(0)) { $0 + $1.bytesIn }
        return out + "All \(tallies.count) apps together: sent \(Format.bytes(sent)), received \(Format.bytes(got))."
    }

    static func liveTraffic(_ overview: NetOverview) -> String {
        let last = overview.series.last ?? NetSample()
        var out = "Right now: downloading \(Format.bytes(last.bytesIn))/s, uploading \(Format.bytes(last.bytesOut))/s, "
            + "\(Format.count(last.active, "open connection")).\n"
        let busy = overview.apps.filter { $0.rate > 0 }.prefix(6).enumerated().map { rank, app in
            "\(rank + 1). \(app.name): ↓ \(Format.bytes(app.rateIn))/s ↑ \(Format.bytes(app.rateOut))/s, \(Format.count(app.conns, "connection"))"
        }
        out += busy.isEmpty ? "No app is moving data this second.\n" : "Busiest now:\n\(busy.joined(separator: "\n"))\n"
        let flagged = overview.apps.filter(\.flagged).map { "\($0.name) (score \($0.score))" }
        return out + (flagged.isEmpty ? "No app is flagged as suspicious." : "Flagged as suspicious: \(flagged.joined(separator: ", ")).")
    }

    static func countriesReached(_ tallies: [String: Tally], days: Int, country: String) -> String {
        var byCountry: [String: [(app: String, bytes: Int64)]] = [:]
        for (app, tally) in tallies {
            for code in tally.countries { byCountry[code, default: []].append((app, tally.bytesIn + tally.bytesOut)) }
        }
        if byCountry.isEmpty { return "No countries recorded in the last \(days) days yet." }
        if !country.isEmpty {
            // "germany" or "de".
            let code = country.count == 2 ? country.uppercased()
                : Locale.Region.isoRegions.first { Locale(identifier: "en").localizedString(forRegionCode: $0.identifier)?.lowercased() == country }?
                    .identifier ?? country.uppercased()
            guard let apps = byCountry[code] else { return "No app reached \(code) in the last \(days) days." }
            let names = apps.sorted { ($0.bytes, $1.app) > ($1.bytes, $0.app) }.prefix(10).map(\.app)
            return "Apps that reached \(code) in the last \(days) days: \(names.joined(separator: ", "))."
        }
        let list = byCountry.map { ($0.key, $0.value.count) }.sorted { ($0.1, $1.0) > ($1.1, $0.0) }
        let lines = list.prefix(20).map { "\($0.0) (\(Format.count($0.1, "app")))" }
        return "\(list.count) countries reached in the last \(days) days, by number of apps: \(lines.joined(separator: ", "))."
    }

    static func recentEvents(_ events: [NetEvent], briefings: [Briefing], from: Millis, hours: Int) -> String {
        var lines = events.map { (t: $0.t, alert: $0.severity == .alert, text: "\($0.text) (\($0.severity.rawValue), \(ago($0.t)))") }
        // Older than this launch: the night shift's briefings kept theirs.
        for event in briefings.flatMap(\.events) where event.t >= from && !lines.contains(where: { $0.t == event.t }) {
            lines.append((event.t, event.severity == "alert", "\(event.text) (\(event.severity), \(ago(event.t)))"))
        }
        if lines.isEmpty { return "No alerts or unusual events in the last \(hours) hours." }
        lines.sort { $0.t > $1.t }
        let alerts = lines.filter(\.alert).count
        return "\(Format.count(lines.count, "event")) in the last \(hours) hours (\(Format.count(alerts, "alert"))), newest first:\n"
            + lines.prefix(15).map { "- \($0.text)" }.joined(separator: "\n")
    }

    static func commandRuns(_ runs: [Run], query: String) -> String {
        let list = runs.filter { query.isEmpty || $0.command.lowercased().contains(query) }.prefix(8)
        if list.isEmpty { return "No matching commands or installs recorded." }
        let lines = list.map { run in
            let hosts = run.net.dests.prefix(4).map(\.name).joined(separator: ", ")
            let verdict = run.findings.first.map { " Finding: \($0.text)." } ?? (run.ecosystem != nil ? " Tripwire: clean." : "")
            return "- \(run.command.prefix(120)) (\(Format.ago(run.startedAt)), took \(run.took / 1000) s): "
                + "reached \(Format.count(run.net.dests.count, "host")) [\(hosts)], sent \(Format.bytes(run.net.bytesOut)), "
                + "\(Format.count(run.files.total, "file")) changed, \(run.procs.leftRunning.count) left running.\(verdict)"
        }
        return "Newest first:\n" + lines.joined(separator: "\n")
    }

    static func awayBriefings(_ briefings: [Briefing]) -> String {
        if briefings.isEmpty { return "No away briefings yet: none written since the night shift started." }
        return briefings.prefix(5).map { b in
            "- \(b.kind == "away" ? "Away" : "Briefed on request") \(ago(b.start)) for \((b.end - b.start) / 60_000) min, "
                + "ended \(ago(b.end)): \(b.headline)"
        }.joined(separator: "\n")
    }

    static func servers(_ fleet: [Fleet.Server]) -> String {
        if fleet.isEmpty { return "No servers are being watched. Watch some in Developer, Hosts, Fleet view." }
        let rows = fleet.map { server in
            let state = switch server.state {
            case .ok: "healthy"
            case .unreachable: "unreachable"
            case .needsKey: "needs a key"
            case .probing: "being checked"
            }
            let snapshot = server.snapshot
            let error = server.error.map { " (\($0))" } ?? ""
            let load = snapshot?.load?.first.map { String(format: ", load %.2f", $0) } ?? ""
            let users = snapshot.map { ", \(Format.count($0.users.count, "user")) logged in" } ?? ""
            let failed = snapshot?.failedLogins.map { ", \($0) failed logins last hour" } ?? ""
            return "- \(server.name): \(state)\(error)\(load)\(users)\(failed)"
        }
        return "Watched servers:\n" + rows.joined(separator: "\n")
    }

    static func securityStatus(decoys: Decoys.Status, exposure: ExposureReport?, installs: [Run], flagged: [String]) -> String {
        var out = [flagged.isEmpty ? "Threats: no app on the network is flagged." : "Threats: flagged \(flagged.joined(separator: ", "))."]
        let armed = decoys.decoys.filter { $0.state == .armed }.count
        let trips = decoys.decoys.compactMap { d in d.trips.first.map { "\(d.path) read \(Format.ago(Clock.date($0.t)))" } }
        if decoys.planted == 0 {
            out.append("Decoys: not planted.")
        } else {
            out.append(trips.isEmpty ? "Decoys: \(armed) decoy credentials armed, none read." : "Decoys: \(armed) armed. READ: \(trips.joined(separator: "; ")).")
        }
        if let exposure {
            let open = exposure.findings.filter { !$0.ignored }
            out.append("Exposed secrets (scan \(Format.ago(Clock.date(exposure.at)))): \(Format.count(open.count, "finding")), "
                + "\(open.filter { $0.severity == .critical }.count) critical, \(open.filter { $0.severity == .high }.count) high.")
        } else {
            out.append("Exposed secrets: never scanned.")
        }
        out.append("Install tripwire (7 days): \(installs.count) followed, \(installs.filter { !$0.findings.isEmpty }.count) with findings.")
        return out.joined(separator: "\n")
    }

    @MainActor static func appUpdates() -> String {
        let apps = AppUpdatesModel.shared
        let tools = ToolchainModel.shared.toolUpdates
        var out: [String] = []
        if apps.scan == nil {
            out.append("Apps haven't been checked for updates yet.")
        } else if apps.pending.isEmpty {
            out.append("Every app is up to date.")
        } else {
            out.append("\(Format.count(apps.pending.count, "app update")) waiting:")
            out += apps.pending.prefix(10).map { "- \($0.name) \($0.installed) → \($0.available) (\($0.method.label))" }
        }
        if tools.isEmpty {
            out.append(ToolchainModel.shared.lastScan == nil ? "Command-line tools haven't been checked yet." : "Every command-line tool is up to date.")
        } else {
            out.append("\(Format.count(tools.count, "command-line tool update")) waiting:")
            out += tools.prefix(10).map { "- \($0.package.name) \($0.package.currentVersion) → \($0.package.latestVersion ?? "newer") (\($0.ownerName))" }
        }
        return out.joined(separator: "\n")
    }
}
