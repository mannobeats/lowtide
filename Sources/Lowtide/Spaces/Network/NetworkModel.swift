import AppKit
import LowtideKit
import SwiftUI

/// What the map has locked on: an app, a country's servers, the nearby
/// edge (servers answering from close by), or this Mac.
enum MapTarget: Hashable {
    case app(String)
    case country(String)
    case nearby
    case home

    var nodeID: String {
        switch self {
        case .app(let name): "app:\(name)"
        case .country(let code): "c:\(code)"
        case .nearby: "nearby"
        case .home: "home"
        }
    }
}

/// The network, as the app sees it: the monitor's latest snapshot, the
/// link, the overnight reports, and the person's choices (home city,
/// sound). Home, the menu bar, the badges and the status line read it.
@MainActor @Observable
final class NetworkModel {
    static let shared = NetworkModel()

    let engine = NetworkEngine.shared
    private(set) var overview = NetOverview()
    private(set) var timeline = NetTimeline()
    private(set) var link = NetLink()
    private(set) var home = HomeLocation.current()
    private(set) var briefings: [Briefing] = []
    private(set) var shiftStatus = NightShift.Status(away: false, since: nil, idleSeconds: 0)
    private(set) var capturePending = false

    /// Beep on alerts and notices while the Live page is open.
    var ping: Bool = UserDefaults.standard.bool(forKey: "network.ping") {
        didSet { UserDefaults.standard.set(ping, forKey: "network.ping") }
    }

    /// Where other pages send the person: a filter for Packets, a query for
    /// Connections, a lock on the map. Pages take them when they appear.
    var packetQuery: String?
    var connectionsQuery: String?
    var pendingTarget: MapTarget?
    /// The Live page's side column is tucked away (⌥⌘0).
    var sideHidden: Bool = UserDefaults.standard.bool(forKey: "network.sideHidden") {
        didSet { UserDefaults.standard.set(sideHidden, forKey: "network.sideHidden") }
    }
    /// Map or Connections, as the person left it.
    var liveView: LiveView = LiveView(rawValue: UserDefaults.standard.string(forKey: "network.liveView") ?? "") ?? .map {
        didSet { UserDefaults.standard.set(liveView.rawValue, forKey: "network.liveView") }
    }

    enum LiveView: String, Hashable { case map, connections }

    private var tasks: [Task<Void, Never>] = []
    /// The newest event already announced; nil until the first snapshot
    /// (events from before the app opened aren't news).
    private var lastAnnounced: Int?

    // MARK: Home's summary

    /// The numbers Home shows about the network.
    struct Summary {
        var appsOnline = 0
        var flagged = 0
        /// Bytes moved over the samples on hand, and the minutes they span.
        var bytesMoved: Int64 = 0
        var minutes = 1
        var countries = 0
        var servers = 0
        var rateIn: Int64 = 0
        var rateOut: Int64 = 0
    }

    var summary: Summary {
        var s = Summary()
        s.appsOnline = overview.apps.count
        s.flagged = flaggedApps.count
        let series = overview.series
        for (a, b) in zip(series, series.dropFirst()) {
            s.bytesMoved += (b.bytesIn + b.bytesOut) * (b.t - a.t) / 1000
        }
        if let first = series.first, let last = series.last { s.minutes = max(1, Int((Double(last.t - first.t) / 60_000).rounded())) }
        s.countries = Set(overview.edges.compactMap(\.country)).count
        s.servers = overview.hosts
        s.rateIn = series.last?.bytesIn ?? 0
        s.rateOut = series.last?.bytesOut ?? 0
        return s
    }

    /// The traffic series (rates per snapshot) for Home and widgets.
    var series: [NetSample] { overview.series }

    /// Flagged apps, riskiest first: the hero, "Needs a look" and the menu
    /// bar use the same list, so they never disagree.
    var flaggedApps: [NetApp] {
        overview.apps.filter(\.flagged).sorted { ($0.score, $1.name) > ($1.score, $0.name) }
    }

    var unseenBriefing: Briefing? { briefings.first { !$0.seen } }

    // MARK: Running

    func start() {
        guard tasks.isEmpty else { return }
        engine.start()
        NightShift.shared.start()
        tasks.append(Task { [weak self] in
            guard let stream = self?.engine.updates() else { return }
            for await _ in stream {
                await self?.refresh()
            }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshLink()
                try? await Task.sleep(for: .seconds(30))
            }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshBriefings()
                try? await Task.sleep(for: .seconds(15))
            }
        })
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
        NightShift.shared.stop()
        engine.stop()
    }

    /// A page showing network data is on screen.
    func watch() { engine.demand() }

    func refresh() async {
        let engine = engine
        let (overview, timeline) = await Task.detached(priority: .userInitiated) {
            (engine.overview(), engine.timeline())
        }.value
        self.overview = overview
        self.timeline = timeline
        publish()
        notifyAlerts()
    }

    private func refreshLink() async {
        link = await NetLinkReader.read()
        publish()
    }

    func refreshBriefings() {
        briefings = NightShift.shared.briefings
        shiftStatus = NightShift.shared.status
        if unseenBriefing != nil { SidebarBadges.shared.dots.insert(.overnight) } else { SidebarBadges.shared.dots.remove(.overnight) }
    }

    /// Badges and the window's bottom line.
    private func publish() {
        let badges = SidebarBadges.shared
        let open = overview.series.last?.active ?? 0
        if badges.counts[.networkLive] != open { badges.counts[.networkLive] = open }
        let packets = overview.capture.running ? overview.capture.stored : 0
        if badges.counts[.packets] != packets { badges.counts[.packets] = packets }
        if let interface = link.interface {
            let parts = ["\(interface) up", link.ip, link.gateway.map { "gw \($0)" }, link.dns.map { "dns \($0)" },
                         link.vpn ? "tunnel" : nil].compactMap { $0 }
            StatusLine.shared.set("net", parts.joined(separator: " · "), tone: .ok, order: 0)
        } else if link != NetLink() || overview.ready {
            StatusLine.shared.set("net", "offline", tone: .bad, order: 0)
        }
        StatusLine.shared.set("capture", overview.capture.running
            ? "capture \(overview.capture.interface ?? "") · \(overview.capture.stored.formatted()) packets" : nil, tone: .brand)
    }

    // MARK: Home location

    func setHome(_ city: City?) {
        HomeLocation.set(city)
        home = HomeLocation.current()
    }

    // MARK: Capture

    /// Starts or stops packet capture. Without access to `/dev/bpf*`, asks
    /// for it first (the privileged helper when installed, else macOS's
    /// password prompt), then starts.
    func toggleCapture() async {
        guard !capturePending else { return }
        capturePending = true
        defer { capturePending = false }
        if overview.capture.running {
            await engine.stopCapture()
            await refresh()
            return
        }
        if !CaptureAccess.permitted {
            var granted = false
            if let helper = CaptureAccessHook.helper { granted = await helper() }
            if !granted {
                guard let command = CaptureAccess.allowCommand(user: NSUserName()) else {
                    Toasts.shared.show("Couldn't open packet capture", detail: "This account's name can't be used in the command.", tone: .bad)
                    return
                }
                switch await Admin.run(command,
                                       prompt: "Lowtide wants to let you capture network packets until this Mac restarts.") {
                case .success: break
                case .failure(.cancelled): return
                case .failure(let refused):
                    Toasts.shared.show("Couldn't open packet capture", detail: refused.message, tone: .bad)
                    return
                }
            }
            guard CaptureAccess.permitted else {
                Toasts.shared.show("Still no access to packet capture",
                                   detail: "macOS didn't open the capture devices to this account. Try again; if it keeps failing, restart the Mac.", tone: .bad)
                return
            }
        }
        do {
            try await engine.startCapture()
        } catch {
            Toasts.shared.failure("Couldn't start packet capture", error)
        }
        await refresh()
    }

    // MARK: Alerts

    /// New events: a beep while the Live page is open (when the sound is
    /// on), macOS notifications for alerts while the window is hidden.
    private func notifyAlerts() {
        let newest = overview.events.first?.id ?? 0
        guard let last = lastAnnounced else {
            lastAnnounced = newest
            return
        }
        let fresh = overview.events.filter { $0.id > last }
        lastAnnounced = max(last, newest)
        guard !fresh.isEmpty else { return }
        if ping, AppModel.shared.page == .networkLive, NSApp.isActive {
            NetworkSound.ping(alert: fresh.contains { $0.severity == .alert })
        }
        // Protection notifies about its own alerts (install watch, decoys, secrets).
        let alerts = fresh.filter { $0.severity == .alert && !["tripwire", "canary", "exposure"].contains($0.kind) }
        let visible = NSApp.isActive && NSApp.windows.contains { $0.identifier?.rawValue == "main" && $0.isVisible }
        guard !visible else { return }
        Notify.post("Lowtide", alerts.prefix(3).map(\.text))
    }
}

/// Where the privileged helper (ported by the Apps space) plugs in: when
/// set, capture access is asked of it before falling back to a password
/// prompt. It returns whether `/dev/bpf*` was opened.
enum CaptureAccessHook {
    static var helper: (@MainActor () async -> Bool)?
}

/// A view that shows network data keeps the monitor sampling every few
/// seconds while it's on screen (otherwise every ten).
struct WatchesNetwork: ViewModifier {
    func body(content: Content) -> some View {
        content.task {
            while !Task.isCancelled {
                NetworkModel.shared.watch()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

extension View {
    func watchesNetwork() -> some View { modifier(WatchesNetwork()) }
}
