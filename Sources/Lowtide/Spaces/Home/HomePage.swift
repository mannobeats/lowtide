import LowtideKit
import SwiftUI

/// Home, as one composition rather than a stack of boxes: on the left the
/// answer in large type, this Mac's vitals as a single line, and each
/// finding as a figure with its words, then what the watchers noticed
/// lately; on the right the radar. Narrow windows stack, radar last.
struct HomePage: View {
    @Environment(\.palette) private var palette
    private var model = HomeModel.shared

    var body: some View {
        let checks = model.checks
        let attention = checks.filter(\.attention)
        let fine = checks.filter { !$0.attention }
        let answer = HomeModel.answer(ready: model.ready, attention: attention, fine: fine)
        // The radar has no width of its own, so the layout follows the card's.
        GeometryReader { geo in
            if geo.size.width >= 900 {
                HStack(alignment: .top, spacing: 64) {
                    column(answer: answer, attention: attention, fine: fine)
                        .frame(width: min(520, max(380, geo.size.width * 0.4)))
                    scope.frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 40)
                .frame(maxWidth: 1480)
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 40) {
                        columnContent(answer: answer, attention: attention, fine: fine)
                        scope.frame(height: 420)
                    }
                    .padding(.horizontal, 40)
                    .padding(.vertical, 48)
                }
            }
        }
        .task { await model.start() }
    }

    private func column(answer: (title: String, detail: String), attention: [HomeCheck], fine: [HomeCheck]) -> some View {
        ScrollView {
            columnContent(answer: answer, attention: attention, fine: fine)
                .padding(.top, 48)
                .padding(.bottom, 40)
        }
        .scrollIndicators(.never)
    }

    private func columnContent(answer: (title: String, detail: String), attention: [HomeCheck], fine: [HomeCheck]) -> some View {
        VStack(alignment: .leading, spacing: 40) {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 0) {
                    let needs = !attention.isEmpty
                    HStack(spacing: 8) {
                        Circle().fill((needs ? palette.warn : palette.ok).color).frame(width: 6, height: 6)
                        Text(needs ? "NEEDS YOU" : "ALL CLEAR")
                            .font(.ui(.xxs, .medium)).tracking(0.6)
                            .foregroundStyle((needs ? palette.warn : palette.ok).color)
                    }
                    .opacity(model.ready ? 1 : 0)
                    .padding(.bottom, 12)
                    Text(answer.title)
                        .font(.system(size: TextSize.display.rawValue, weight: .semibold))
                        .tracking(-0.6)
                        .foregroundStyle(palette.ink.color)
                        .contentTransition(.numericText())
                        .fixedSize(horizontal: false, vertical: true)
                    Text(answer.detail)
                        .font(.ui(.sm)).lineSpacing(3)
                        .foregroundStyle(palette.ink3.color)
                        .frame(maxWidth: 420, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                }
                Vitals()
            }
            if model.ready {
                Findings(label: "Needs a look", checks: attention)
                Findings(label: "Worth knowing", checks: fine)
                RecentlyNoticed()
            } else {
                FindingsPlaceholder()
            }
        }
        .animation(Motion.base, value: model.ready)
    }

    @ViewBuilder private var scope: some View {
        VStack {
            if SpaceState.isOn(.network) { NetworkScope() } else { NetworkScopeAtRest() }
        }
        .padding(.top, 40)
        .padding(.bottom, 32)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// One thing about this Mac: a count, what it means, where to act.
struct HomeCheck: Identifiable, Equatable {
    let id: String
    /// Something to act on (amber), or just worth knowing (quiet).
    var attention: Bool
    /// The number the row leads with, large: "17", "55 GB".
    var figure: String
    /// What the figure counts, read after it: "apps left things behind".
    var label: String
    var detail: String
    /// The check as a phrase inside the hero's sentence.
    var phrase: String
    var title: String
    var page: Page
}

/// Reads every space's state into Home's checks. Only what the person
/// switched on speaks up here.
@Observable
final class HomeModel {
    static let shared = HomeModel()

    private(set) var disk: (free: Int64, total: Int64) = (0, 0)
    private var started = false
    private let launched = Date()

    /// The list appears once, whole, instead of row by row as each source
    /// answers and pushes the rest down.
    var ready: Bool {
        let network = !SpaceState.isOn(.network) || !NetworkModel.shared.series.isEmpty
        let protection = !SpaceState.isOn(.protection) || ProtectionModel.shared.permissions != nil
        return (network && protection) || Date().timeIntervalSince(launched) > 8
    }

    func start() async {
        refreshDisk()
        guard !started else { return }
        started = true
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            refreshDisk()
        }
    }

    private func refreshDisk() {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        disk = (values?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(values?.volumeTotalCapacity ?? 0))
    }

    var diskLow: Bool { disk.total > 0 && Double(disk.free) / Double(disk.total) < 0.1 }

    var checks: [HomeCheck] {
        var checks: [HomeCheck] = []
        let on = SpaceState.isOn
        if on(.cleanup), diskLow {
            checks.append(HomeCheck(id: "disk", attention: true, figure: LowtideFormat.bytes(disk.free), label: "free on your disk",
                                    detail: "Almost full · \(LowtideFormat.bytes(disk.total)) in all", phrase: "a nearly full disk",
                                    title: "Your disk is almost full", page: .cleanup))
        }
        if on(.network), !NetworkModel.shared.series.isEmpty {
            let flagged = NetworkModel.shared.flaggedApps.count
            checks.append(HomeCheck(
                id: "threats", attention: flagged > 0, figure: "\(flagged)",
                label: "\(flagged == 1 ? "app" : "apps") flagged on the network",
                detail: flagged > 0 ? "Talking to servers on blocklists or behaving unusually" : "No app is talking to suspicious servers",
                phrase: "\(Self.some(flagged, "app")) flagged on the network",
                title: flagged > 0 ? "\(LowtideFormat.count(flagged, "app")) flagged on the network" : "Network looks clean",
                page: .threats))
        }
        if on(.protection) {
            let protection = ProtectionModel.shared
            let critical = protection.criticalSecrets
            if critical > 0 {
                checks.append(HomeCheck(id: "secrets", attention: true, figure: "\(critical)",
                                        label: critical == 1 ? "secret exposed" : "secrets exposed",
                                        detail: "Live keys in files that sync, git or other users can read",
                                        phrase: Self.some(critical, "exposed secret"),
                                        title: "\(LowtideFormat.count(critical, "secret")) exposed", page: .secrets))
            }
            let reads = protection.decoyReads
            if reads > 0 {
                checks.append(HomeCheck(id: "decoys", attention: true, figure: "\(reads)",
                                        label: reads == 1 ? "decoy key read" : "decoy keys read",
                                        detail: "Something read a decoy key in the last day",
                                        phrase: Self.some(reads, "decoy key read"),
                                        title: "\(LowtideFormat.count(reads, "decoy key")) read", page: .secrets))
            }
            let installs = protection.installAlerts
            if installs > 0 {
                checks.append(HomeCheck(id: "installs", attention: true, figure: "\(installs)",
                                        label: installs == 1 ? "install did something unusual" : "installs did something unusual",
                                        detail: "Follow what each one touched in Install watch",
                                        phrase: Self.some(installs, "unusual install"),
                                        title: "\(LowtideFormat.count(installs, "install")) need a look", page: .installWatch))
            }
        }
        if on(.apps), let scan = AppUpdatesModel.shared.scan {
            let pending = AppUpdatesModel.shared.pending
            let n = pending.count
            let names = pending.prefix(3).map(\.name).joined(separator: ", ")
            checks.append(HomeCheck(
                id: "updates", attention: n > 0, figure: "\(n)", label: n == 1 ? "app update" : "app updates",
                detail: n > 0 ? names + (n > 3 ? " and \(n - 3) more" : "") : "Checked \(LowtideFormat.count(scan.checked, "app"))",
                phrase: Self.some(n, "app update"),
                title: n > 0 ? "\(LowtideFormat.count(n, "app")) can be updated" : "Your apps are up to date", page: .appsUpdates))
        }
        if on(.cleanup), let leftovers = SidebarBadges.shared.counts[.leftovers], leftovers > 0 {
            checks.append(HomeCheck(
                id: "leftovers", attention: SidebarBadges.shared.warning.contains(.leftovers), figure: "\(leftovers)",
                label: "\(leftovers == 1 ? "app" : "apps") left things behind",
                detail: "Files, permissions and start-up items of apps that are gone",
                phrase: "leftovers from \(LowtideFormat.count(leftovers, "app"))",
                title: "\(LowtideFormat.count(leftovers, "app")) left things behind", page: .leftovers))
        }
        if on(.protection), let map = ProtectionModel.shared.permissions {
            if map.broken > 0 {
                checks.append(HomeCheck(id: "broken", attention: true, figure: "\(map.broken)",
                                        label: map.broken == 1 ? "broken start-up item" : "broken start-up items",
                                        detail: "Launch items whose program is gone",
                                        phrase: Self.some(map.broken, "broken start-up item"),
                                        title: "\(LowtideFormat.count(map.broken, "start-up item")) broken", page: .permissions))
            }
            let login = map.startAtLogin
            checks.append(HomeCheck(id: "login", attention: false, figure: "\(login)",
                                    label: "\(login == 1 ? "app opens" : "apps open") when you log in",
                                    detail: "Each one slows startup a little and can run in the background",
                                    phrase: LowtideFormat.count(login, "login item"),
                                    title: "\(LowtideFormat.count(login, "app")) open when you log in", page: .permissions))
        }
        if on(.developer) {
            let tools = ToolchainModel.shared.toolUpdateCount
            if tools > 0 {
                checks.append(HomeCheck(id: "tools", attention: false, figure: "\(tools)",
                                        label: tools == 1 ? "tool update" : "tool updates",
                                        detail: "Homebrew formulas, npm globals and other tools",
                                        phrase: Self.some(tools, "tool update"),
                                        title: "\(LowtideFormat.count(tools, "command-line tool")) can be updated", page: .appsUpdates))
            }
        }
        return checks
    }

    /// "an app" for one, "3 apps" for more.
    static func some(_ n: Int, _ one: String) -> String {
        n == 1 ? "\(one.first.map { "aeiou".contains($0.lowercased()) } == true ? "an" : "a") \(one)" : "\(n) \(one)s"
    }

    /// The answer to "is anything wrong?", in one sentence and one detail line.
    static func answer(ready: Bool, attention: [HomeCheck], fine: [HomeCheck]) -> (title: String, detail: String) {
        guard ready else { return ("Looking over this Mac…", "Reading updates, storage, permissions and the network.") }
        if attention.isEmpty {
            return ("Your Mac looks good",
                    fine.isEmpty ? "Nothing needs you right now." : "Nothing needs you right now. A few things are worth knowing.")
        }
        let words = ["No", "One", "Two", "Three", "Four", "Five", "Six", "Seven"]
        let n = attention.count
        let detail = ListFormatter.localizedString(byJoining: attention.map(\.phrase)) + "."
        return ("\(n < words.count ? words[n] : "\(n)") \(n == 1 ? "thing needs" : "things need") a look",
                detail.prefix(1).uppercased() + detail.dropFirst())
    }
}

/// One finding as a line of type, not a card: the figure large, what it
/// counts beside it, the detail under that. Amber when it needs you.
private struct Findings: View {
    @Environment(\.palette) private var palette
    let label: String
    let checks: [HomeCheck]

    var body: some View {
        if !checks.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel(text: label)
                ForEach(checks) { check in FindingRow(check: check) }
            }
        }
    }
}

private struct FindingRow: View {
    @Environment(\.palette) private var palette
    @State private var hovering = false
    let check: HomeCheck

    var body: some View {
        Button { AppModel.shared.open(check.page) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(check.figure)
                    .font(.system(size: TextSize.xxl.rawValue, weight: .semibold)).monospacedDigit().tracking(-0.4)
                    .foregroundStyle((check.attention ? palette.warn : palette.ink2).color)
                    .lineLimit(1)
                    .frame(width: 88, alignment: .trailing)
                VStack(alignment: .leading, spacing: 2) {
                    Text(check.label).font(.ui(.sm)).foregroundStyle(palette.ink.color).lineLimit(1)
                    Text(check.detail).font(.ui(.xs)).foregroundStyle(palette.ink3.color).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.ink4.color)
                    .opacity(hovering ? 1 : 0)
                    .offset(x: hovering ? 2 : 0)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            }
            .padding(.vertical, 12)
            .contentShape(.rect)
            .overlay(alignment: .bottom) {
                Rectangle().fill((hovering ? palette.lineStrong : palette.line).color).frame(height: 1)
            }
        }
        .buttonStyle(.plain)
        .help(check.title)
        .onHover { hovering = $0 }
        .animation(Motion.spring, value: hovering)
    }
}

/// Lines the size of real ones, while the checks are being read.
private struct FindingsPlaceholder: View {
    @Environment(\.palette) private var palette
    @State private var pulse = false
    var body: some View {
        VStack(spacing: 0) {
            ForEach([0.56, 0.44, 0.64], id: \.self) { width in
                HStack(spacing: 16) {
                    Capsule().fill(palette.fill.color).frame(width: 40, height: 24).frame(width: 88, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 6) {
                        GeometryReader { geo in Capsule().fill(palette.fill.color).frame(width: geo.size.width * width, height: 12) }
                            .frame(height: 12)
                        GeometryReader { geo in Capsule().fill(palette.fill.color).frame(width: geo.size.width * 0.6, height: 10) }
                            .frame(height: 10)
                    }
                }
                .padding(.vertical, 16)
                .hairline()
            }
        }
        .opacity(pulse ? 0.5 : 1)
        .animation(.easeInOut(duration: 1).repeatForever(), value: pulse)
        .onAppear { pulse = true }
        .accessibilityLabel("Loading")
    }
}

private struct SectionLabel: View {
    @Environment(\.palette) private var palette
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.ui(.xxs, .medium)).tracking(0.6)
            .foregroundStyle(palette.ink3.color)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hairline()
    }
}

/// This Mac at a glance, as one line: free space, and live traffic when
/// Network is on.
private struct Vitals: View {
    @Environment(\.palette) private var palette
    private var home = HomeModel.shared
    private var network = NetworkModel.shared

    var body: some View {
        HStack(alignment: .top, spacing: 32) {
            Vital(label: "Storage",
                  value: home.disk.total > 0 ? "\(LowtideFormat.bytes(home.disk.free)) free" : "…",
                  valueTone: home.diskLow ? .bad : .neutral,
                  meta: home.disk.total > 0 ? "of \(LowtideFormat.bytes(home.disk.total))" : "",
                  page: .spaceLens) {
                Meter(value: home.disk.total > 0 ? 1 - Double(home.disk.free) / Double(home.disk.total) : 0,
                      tone: home.diskLow ? .bad : .neutral, height: 4)
            }
            if SpaceState.isOn(.network) {
                let last = network.series.last
                Vital(label: "Network", value: "↓ \(LowtideFormat.rate(Double(last?.bytesIn ?? 0)))", valueTone: .neutral,
                      meta: "↑ \(LowtideFormat.rate(Double(last?.bytesOut ?? 0)))", page: .networkLive) {
                    Sparkline(values: network.series.suffix(90).map { Double($0.bytesIn + $0.bytesOut) })
                        .frame(height: 20)
                }
                .help(LowtideFormat.count(last?.active ?? 0, "open connection"))
            }
        }
        .padding(.top, 16)
        .overlay(alignment: .top) { Rectangle().fill(palette.line.color).frame(height: 1) }
    }
}

private struct Vital<Graphic: View>: View {
    @Environment(\.palette) private var palette
    @State private var hovering = false
    let label: String
    let value: String
    let valueTone: Tone
    let meta: String
    let page: Page
    @ViewBuilder var graphic: Graphic

    var body: some View {
        Button { AppModel.shared.open(page) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(label).foregroundStyle((hovering ? palette.ink2 : palette.ink3).color)
                    Text(value).fontWeight(.medium).monospacedDigit()
                        .foregroundStyle((valueTone == .neutral ? palette.ink : valueTone.color(palette)).color)
                        .fixedSize()
                    Spacer(minLength: 4)
                    Text(meta).monospacedDigit().foregroundStyle(palette.ink4.color)
                }
                .font(.ui(.xs))
                .lineLimit(1)
                graphic.frame(height: 20, alignment: .bottom)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// What the watchers noticed lately, as quiet lines of type.
private struct RecentlyNoticed: View {
    @Environment(\.palette) private var palette
    @Environment(\.privacy) private var privacy
    private var network = NetworkModel.shared

    static let glyphs: [String: String] = [
        "away": "overnight", "canary": "decoys", "exposure": "secrets", "firstApp": "apps", "flagged": "threats",
        "fleet": "fleet", "newCountry": "network", "tripwire": "threats", "uploadSpike": "network",
    ]

    var body: some View {
        let events = Array(network.overview.events.reversed().prefix(4))
        if SpaceState.isOn(.network), !events.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel(text: "Recently noticed")
                ForEach(events) { event in
                    Button {
                        AppModel.shared.open(event.kind == "flagged" ? .threats : .networkLive)
                    } label: {
                        HStack(spacing: 12) {
                            NavIcon(Self.glyphs[event.kind] ?? "network", size: 14)
                                .foregroundStyle((event.severity == .alert ? palette.warn : palette.ink4).color)
                            Text(privacy ? event.text.replacingOccurrences(of: #"\d+\.\d+\.\d+\.\d+"#, with: "•••", options: .regularExpression) : event.text)
                                .font(.ui(.xs)).foregroundStyle(palette.ink3.color).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(LowtideFormat.ago(Date(timeIntervalSince1970: Double(event.t) / 1000)))
                                .font(.ui(.xs)).monospacedDigit().foregroundStyle(palette.ink4.color)
                        }
                        .frame(height: 36)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
