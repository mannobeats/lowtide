import Foundation
import Testing
@testable import LowtideKit

/// Real `nettop -L 1 -n -x -J interface,state,bytes_in,bytes_out,rtt_min,rtt_avg`
/// output (trimmed), odd lines included.
private let snapshot = """
,interface,state,bytes_in,bytes_out,rtt_min,rtt_avg,
launchd.1,,,0,0,,,
tcp6 ::1.8021<->*.*,lo0,Listen,,,,,
tcp4 127.0.0.1:8021<->*:*,lo0,Listen,,,,,
apsd.142,,,419625,751703,,,
tcp4 192.168.1.153:57859<->17.57.144.149:5223,en0,Established,419625,751703,21.22 ms,48.78 ms,
nesessionmanage.149,,,0,0,,,
udp4 *:*<->*:*,,,,,,,
syspolicyd.260,,,22579,15292,,,
quic6 2600:1700:1000:1c90:dd79:bc64:6e8f:b981.56144<->2620:149:a41:480::2:2.443,en0,,6193,6006,,22.47 ms,
mDNSResponder.264,,,14754884,5705274,,,
udp4 *:5353<->*:*,bridge100,,8761431,4026971,,,
tcp4 *:50415<->*:*,,Listen,,,,,
Zeeli Helper.33329,,,38429,39546,,,
tcp6 2600:1700:1000:1c90:dd79:bc64:6e8f:b981.49158<->2606:4700:3033::ac43:d0b5.443,en0,Established,13388,14082,5.00 ms,121.56 ms,
Tailscale.875,,,8116022,327,,,
tcp4 127.0.0.1:60930<->127.0.0.1:60926,lo0,Established,8116022,327,1.00 ms,1.00 ms,
"""

@Suite struct NetworkMonitorTests {
    @Test func parsesNettopSnapshots() throws {
        let rows = Nettop.parse(snapshot)
        #expect(rows.count == 9)
        let push = try #require(rows.first { $0.name == "apsd" })
        #expect(push.pid == 142 && push.socket.proto == "tcp" && push.socket.remoteIP == "17.57.144.149" && push.socket.remotePort == 5223)
        #expect(push.iface == "en0" && push.state == "Established" && push.bytesIn == 419_625 && push.bytesOut == 751_703)
        #expect(push.rttMin == 21.22 && push.rttAvg == 48.78)
        let quic = try #require(rows.first { $0.socket.proto == "quic" })
        #expect(quic.socket.v6 && quic.socket.remoteIP == "2620:149:a41:480::2:2" && quic.socket.remotePort == 443)
        #expect(quic.rttMin == nil && quic.rttAvg == 22.47)
        let helper = try #require(rows.first { $0.name == "Zeeli Helper" })
        #expect(helper.pid == 33329 && helper.rttMin == 5)
        let listen = try #require(rows.first { $0.socket.key == "tcp6 ::1.8021<->*.*" })
        #expect(listen.socket.listening && listen.socket.localIP == "::1" && listen.socket.localPort == 8021)
        #expect(rows.first { $0.name == "Tailscale" }?.socket.loopback == true)
        #expect(NetSocket("launchd.1") == nil)
        // Columns follow the header, whatever their order.
        let swapped = Nettop.parse(",state,interface,bytes_out,bytes_in,rtt_avg,\nx.9,,,,,\ntcp4 1.2.3.4:5<->5.6.7.8:443,Established,en1,10,20,3.00 ms,\n")
        #expect(swapped.first?.iface == "en1" && swapped.first?.bytesIn == 20 && swapped.first?.bytesOut == 10 && swapped.first?.rttAvg == 3)
    }

    @Test func namesAppsAndSigners() {
        #expect(Nettop.appBundle("/Applications/Google Chrome.app/Contents/Frameworks/x/Google Chrome Helper.app/Contents/MacOS/h")
            == "/Applications/Google Chrome.app")
        #expect(Nettop.appBundle("/usr/sbin/mDNSResponder") == nil)
        #expect(Nettop.toolName("/Users/a/.local/share/claude/versions/2.1.283") == "claude")
        #expect(Nettop.toolName("/opt/homebrew/bin/gh") == "gh")
        #expect(Nettop.parseSignature("Platform identifier=26\nAuthority=macOS Software Signing") == .apple)
        #expect(Nettop.parseSignature("Authority=Software Signing\nAuthority=Apple Code Signing") == .apple)
        #expect(Nettop.parseSignature("Authority=Developer ID Application: 1804 AUDIO LLC (7CPDA6H8CT)\n") == .developer("1804 AUDIO LLC (7CPDA6H8CT)"))
        #expect(Signature.developer("1804 AUDIO LLC (7CPDA6H8CT)").label == "1804 AUDIO LLC")
        #expect(Nettop.parseSignature("x: code object is not signed at all") == .unsigned)
        #expect(Nettop.parseSignature("Signature=adhoc\n") == .adHoc)
        #expect(Nettop.parseSignature("Authority=Apple Development: Jo (X1)") == .development("Jo (X1)"))
    }

    @Test func spotsTimersNotBursts() {
        let steady: [Millis] = (0..<8).map { Millis($0) * 30_000 + Millis($0 % 2) * 400 }
        #expect(ThreatScore.beaconInterval(steady) == 30)
        #expect(ThreatScore.beaconInterval([0, 1_000, 50_000, 51_000, 140_000, 400_000, 401_000]) == nil)
        #expect(ThreatScore.beaconInterval((0..<8).map { Millis($0) * 500 }) == nil)
        #expect(ThreatScore.beaconInterval([0, 30_000]) == nil)
    }

    @Test func flagsGeneratedDomainsOnly() {
        #expect(ThreatScore.oddDomain("www.google.com") == nil)
        #expect(ThreatScore.oddDomain("d1a2b3c4.cloudfront.net") == nil)
        #expect(ThreatScore.oddDomain("x7k2q9zv1m4p8w3r6t0y5u.example.com") != nil)
        #expect(ThreatScore.oddDomain("aGVsbG8gd29ybGQgdGhpcyBpcyBleGZpbHRyYXRpb24gZGF0YQ.t.evil.io") != nil)
    }

    @Test func scoresBehaviour() {
        func input(_ signature: Signature, path: String? = "/Applications/X.app/Contents/MacOS/X", listens: [UInt16] = [],
                   out: Int64 = 0, inn: Int64 = 0, hosts: Int = 1, ports: [UInt16] = [443],
                   opens: [(host: String, times: [Millis])] = []) -> ThreatScore.Input {
            .init(signature: signature, path: path, listens: listens, bytesOut: out, bytesIn: inn, hosts: hosts,
                  remotePorts: ports, opens: opens, home: "/Users/a")
        }
        #expect(ThreatScore.score(input(.developer("Acme"))).0 == 0)
        // Unsigned, from Downloads, on a timer: well over the line.
        let beacon = (0..<8).map { Millis($0) * 60_000 }
        let (bad, reasons) = ThreatScore.score(input(.unsigned, path: "/Users/a/Downloads/tool", opens: [("evil.io", beacon)]))
        #expect(bad == 75 && bad >= ThreatScore.flag)
        #expect(reasons.map(\.label) == ["Not code-signed", "Runs from a temporary, hidden or download folder",
                                         "Calls home on a timer: evil.io every ~60s"])
        // A dev tool in a hidden folder is fine when signed.
        #expect(ThreatScore.score(input(.developer("Acme"), path: "/Users/a/.config/x/bin/x")).0 == 0)
        #expect(ThreatScore.score(input(.adHoc, path: "/Users/a/.cargo/bin/x")).0 == 15)
        // Apple's daemons talk on odd ports and listen: no penalty.
        #expect(ThreatScore.score(input(.apple, listens: [7000], ports: [5223, 31_337])).0 == 0)
        let (busy, why) = ThreatScore.score(input(.developer("Acme"), listens: [8080, 60_000], out: 400_000_000, inn: 1_000,
                                                  hosts: 80, ports: [443, 6667, 6667, 52_000]))
        #expect(busy == 50)
        #expect(why.map(\.label).contains("Unusual remote ports: 6667"))
        #expect(why.map(\.label).contains("Accepts connections from the network on 8080"))
        #expect(why.map(\.label).contains("Uploads far more than it downloads (400 MB out)"))
    }

    @Test func remembersWhatsNormal() {
        var baseline = Baseline()
        baseline.load(now: 0, from: nil)
        // While learning, nothing is news.
        #expect(baseline.observe(online: ["Slack": [.init(country: "US", org: "Slack")]], now: 1_000).isEmpty)
        #expect(baseline.firstSeen("Slack") == 1_000)
        let later: Millis = Baseline.learningMs + 1
        let events = baseline.observe(online: ["Slack": [.init(country: "US", org: nil), .init(country: "IE", org: "Amazon")],
                                               "Zoom": []], now: later)
        #expect(events.map(\.kind).sorted() == ["firstApp", "newCountry"])
        #expect(events.first { $0.kind == "newCountry" }?.text == "Slack reached Ireland for the first time via Amazon")
        #expect(baseline.knownCountries("Slack") == 2)
        // A fresh app's first countries are not news.
        #expect(baseline.observe(online: ["Arc": [.init(country: "US", org: nil), .init(country: "DE", org: nil)]], now: later + 1)
            .map(\.kind) == ["firstApp"])
    }

    @Test func notesUploadSpikesAfterSettling() {
        var baseline = Baseline()
        baseline.load(now: 0, from: Baseline.Memory(created: 0, apps: ["Box": .init(firstSeen: 0, countries: [], minutes: 40, usualOut: 1_000_000)]))
        let now = Baseline.learningMs + 120_000
        baseline.minuteStart = now - 60_000
        baseline.addUpload("Box", 50_000_000)
        let events = baseline.observe(online: ["Box": []], now: now)
        #expect(events.map(\.kind) == ["uploadSpike"])
        #expect(events.first?.text == "Box uploaded 50 MB in a minute, 50× its usual")
        #expect(baseline.usualOut("Box") ?? 0 > 1_000_000)
    }

    @Test func talliesByDay() {
        var ledger = Ledger()
        let today: Millis = 20_000 * Ledger.dayMs + 5_000
        ledger.add(now: today - Ledger.dayMs, app: "Slack", country: "US", host: "slack.com", bytesIn: 10, bytesOut: 20)
        ledger.add(now: today, app: "Slack", country: "IE", host: "slack.com", bytesIn: 1, bytesOut: 2)
        ledger.add(now: today - 9 * Ledger.dayMs, app: "Slack", country: nil, host: nil, bytesIn: 100, bytesOut: 100)
        let week = ledger.since(now: today, days: 7)
        #expect(week["Slack"]?.bytesIn == 11 && week["Slack"]?.bytesOut == 22 && week["Slack"]?.countries.count == 2)
        ledger.prune(now: today + 30 * Ledger.dayMs)
        #expect(ledger.data.days.count == 2)
        // The file shape: days keyed by number as text.
        let json = String(decoding: try! JSONEncoder().encode(ledger.data), as: UTF8.self)
        #expect(json.contains("\"19999\"") || json.contains("\"20000\""))
    }

    @Test func writesHeadlines() {
        let apps = ["Dropbox": Tally(bytesIn: 1_000, bytesOut: 2_000_000_000)]
        let quiet = NightShift.build(kind: "brief", apps: apps, events: [], start: 0, end: 60_000, slept: [], installs: [])
        #expect(quiet.headline.hasPrefix("Quiet. 2.0 GB moved by 1 app"))
        #expect(quiet.seen)
        let spike = NetEvent(t: 10, kind: "uploadSpike", severity: .alert, app: "Dropbox", text: "Dropbox uploaded 40× its usual")
        let busy = NightShift.build(kind: "away", apps: apps, events: [spike], start: 0, end: 60_000, slept: [[5, 25]],
                                    installs: [.init(id: 1, t: 5, command: "npm i x", verdict: "notice", source: "Terminal")])
        #expect(busy.attention == 2 && busy.headline == "2 things to look at. Dropbox uploaded 40× its usual")
        #expect(busy.sleptMs == 20 && !busy.seen)
        #expect(NightShift.idleSeconds() >= 0)
    }

    @Test func readsTheLink() {
        let route = "   route to: default\ndestination: default\n    gateway: 192.168.1.1\n  interface: en0\n      flags: <UP,GATEWAY,DONE>\n"
        let link = NetLinkReader.parse(route: route, ip: "192.168.1.4", dns: "resolver #1\n  nameserver[0] : 1.1.1.1\n")
        #expect(link == NetLink(interface: "en0", ip: "192.168.1.4", gateway: "192.168.1.1", dns: "1.1.1.1", vpn: false))
        #expect(NetLinkReader.parse(route: "interface: utun4\n", ip: nil, dns: "").vpn)
    }

    @Test func understandsLocalServices() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "lowtide-localhost-\(UUID())").path
        let repo = base + "/repo", app = repo + "/apps/web"
        try FileManager.default.createDirectory(atPath: app + "/src", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: repo + "/.git", withIntermediateDirectories: true)
        try "ref: refs/heads/feat/map\n".write(toFile: repo + "/.git/HEAD", atomically: true, encoding: .utf8)
        try #"{"name":"@acme/web"}"#.write(toFile: app + "/package.json", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let root = try #require(Localhost.projectRoot(app + "/src", home: base))
        #expect(root == app)
        #expect(Localhost.projectName(root) == "@acme/web")
        #expect(Localhost.gitBranch(root, home: base) == "feat/map")
        #expect(Localhost.projectRoot(base + "/elsewhere", home: base) == nil)
        // A worktree's `.git` is a file pointing at its git dir.
        let tree = base + "/tree", meta = base + "/meta"
        try FileManager.default.createDirectory(atPath: tree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: meta, withIntermediateDirectories: true)
        try "ref: refs/heads/hotfix\n".write(toFile: meta + "/HEAD", atomically: true, encoding: .utf8)
        try "gitdir: ../meta\n".write(toFile: tree + "/.git", atomically: true, encoding: .utf8)
        #expect(Localhost.gitBranch(tree, home: base) == "hotfix")

        #expect(Localhost.parseHead("ref: refs/heads/main\n") == "main")
        #expect(Localhost.parseHead("3f2a9c1d0e4b5a6978") == "3f2a9c1")
        #expect(Localhost.parseHead("garbage") == nil)
        #expect(Localhost.guessKind(command: "node /x/node_modules/.bin/vite --port 5173", name: "node") == "Vite")
        #expect(Localhost.guessKind(command: "next-server (v15)", name: "node") == "Next.js")
        #expect(Localhost.guessKind(command: "/opt/homebrew/opt/postgresql@16/bin/postgres -D x", name: "postgres") == "Postgres")
        #expect(Localhost.guessKind(command: "", name: "com.docker.backend") == "Docker")
        #expect(Localhost.guessKind(command: "python manage.py runserver", name: "Python") == "Django")
        #expect(Localhost.guessKind(command: "", name: "rapportd") == nil)
        #expect(Localhost.isLoopback("::1") && Localhost.isLoopback("fe80::1%lo0") && !Localhost.isLoopback("0.0.0.0"))
        #expect(Localhost.systemPath("/usr/libexec/rapportd") && !Localhost.systemPath("/usr/local/bin/redis-server"))
        #expect(Localhost.uptime(0, now: 3 * 3_600_000 + 12 * 60_000) == "3h 12m")
        #expect(Localhost.uptime(0, now: 12_000) == "12s")
        #expect(throws: Localhost.StopRefusal.isSelf) { try Localhost.stop(pid: getpid(), force: false) }
        #expect(throws: Localhost.StopRefusal.notStoppable) { try Localhost.stop(pid: 1, force: false) }
    }

    @Test func readsProcessesFromTheKernel() throws {
        let me = try #require(NetProcess.info(getpid()))
        #expect(me.uid == getuid() && me.started > 0)
        #expect(ProcTable.path(getpid()) != nil)
        #expect(ProcTable.cwd(getpid()) != nil)
        #expect(ProcTable.arguments(getpid())?.isEmpty == false)
        let chain = NetProcess.lineage(of: [getpid()])
        #expect(chain.first?.pid == 1 && chain.last?.pid == getpid() && chain.last?.own == true)
        #expect(ProcTable.pids().contains(getpid()))
    }

    /// Two snapshots through the engine: rates, apps, edges and the map frame.
    @Test func foldsSnapshotsIntoTheState() throws {
        let engine = NetworkEngine()
        engine.state.withLock { $0.baseline.load(now: .now, from: nil) }
        let rows = Nettop.parse(snapshot)
        let t0 = Millis.now
        engine.commit(rows, first: true, elapsed: 1, now: t0)
        var more = rows
        for i in more.indices where more[i].name == "Zeeli Helper" {
            more[i].bytesIn += 30_000
            more[i].bytesOut += 3_000
        }
        more.removeAll { $0.name == "apsd" }
        engine.commit(more, first: false, elapsed: 3_000, now: t0 + 3_000)
        let overview = engine.overview()
        #expect(overview.ready)
        #expect(overview.series.last?.bytesIn == 10_000 && overview.series.last?.bytesOut == 1_000)
        let edge = try #require(overview.edges.first)
        #expect(edge.rateIn == 10_000 && edge.country != nil && edge.org?.hasPrefix("Cloudflare") == true && edge.rttMs == 5)
        // apsd's socket went away: closed, kept for ten minutes.
        let closed = engine.connections().filter { $0.closedAt != nil }
        #expect(closed.contains { $0.remote == "17.57.144.149" })
        #expect(engine.timeline().points.count == 1)
        #expect(engine.frame(at: t0)?.edges.first?.rateIn == 10_000)
        // Listening services show up on the localhost map.
        #expect(engine.localhostRaw().contains { $0.port == 50415 && $0.binds == ["0.0.0.0"] })
        engine.push(NetEvent(t: t0, kind: "tripwire", severity: .alert, app: "npm", text: "npm ran a script"))
        #expect(engine.alerts(after: 0).map(\.text) == ["npm ran a script"])
        #expect(engine.history(since: 0).count == 1)
    }

    @Test func filesCapturedPackets() throws {
        let engine = NetworkEngine()
        let response = [0x12, 0x34, 0x81, 0x80, 0, 1, 0, 1, 0, 0, 0, 0] + [7] + Array("example".utf8) + [3] + Array("com".utf8)
            + [0, 0, 1, 0, 1] + [0xC0, 12, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 93, 184, 216, 34]
        let udp: [UInt8] = [0, 53, 0xC7, 0x38, 0, UInt8(8 + response.count), 0, 0] + response
        let ip: [UInt8] = [0x45, 0, 0, UInt8(20 + udp.count), 0, 0, 0x40, 0, 64, 17, 0, 0, 192, 168, 1, 1, 192, 168, 1, 4] + udp
        engine.record(.init(t: 1_000, length: ip.count, link: 12, bytes: ip), local: ["192.168.1.4"])
        let page = engine.packets(filter: "dns in")
        #expect(page.stored == 1 && page.matched == 1)
        #expect(page.rows.first?.info == "A example.com → 93.184.216.34" && page.rows.first?.direction == "in")
        #expect(engine.packets(filter: "out").matched == 0)
        #expect(engine.dns().first?.answers == ["93.184.216.34"])
        #expect(engine.hostName(for: "93.184.216.34") == "example.com")
        let detail = try #require(engine.packet(seq: 1))
        #expect(detail.layers.map(\.name) == ["IPv4", "UDP", "DNS"])
    }
}
