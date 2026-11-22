import AppKit
import Foundation
import FoundationModels
import Testing
@testable import LowtideKit

/// Ask's tools, its on-device engine, and the access assistant's geometry.
@Suite struct AskTests {
    /// `lsof -nP -iTCP -sTCP:LISTEN -F pcn` on a Mac with a dev server running.
    static let lsof = """
    p443
    crapportd
    f12
    n*:59196
    f17
    n*:59197
    p482
    cControlCenter
    f10
    n*:7000
    f11
    n*:7000
    f12
    n*:5000
    p844
    cWavesPluginServer
    f10
    n127.0.0.1:14101
    f11
    n[::1]:14101
    p9120
    cnode
    f23
    n[::1]:5173
    """

    @Test func readsWhatIsListening() {
        let listeners = LocalServices.parse(Self.lsof)
        #expect(listeners.map(\.port) == [5000, 5173, 7000, 14101, 59196, 59197])
        let waves = listeners.first { $0.port == 14101 }
        #expect(waves?.process == "WavesPluginServer" && waves?.pid == 844)
        #expect(waves?.addresses == ["127.0.0.1", "::1"] && waves?.exposed == false)
        #expect(listeners.first { $0.port == 7000 }?.exposed == true)
        #expect(listeners.first { $0.port == 7000 }?.addresses == ["*"])
        #expect(LocalServices.parse("").isEmpty)
        #expect(LocalServices.parse("p1\nccmd\nnnot-a-port\n").isEmpty)
    }

    @Test func summarisesListeners() {
        let listeners = LocalServices.parse(Self.lsof)
        let all = LocalServices.summaryText(listeners, port: 0)
        #expect(all.hasPrefix("Listening on this Mac:\n- port 5000: ControlCenter (pid 482), REACHABLE FROM THE NETWORK"))
        #expect(all.contains("- port 5173: node (pid 9120), this Mac only"))
        #expect(LocalServices.summaryText(listeners, port: 5173) == "Listening on this Mac:\n- port 5173: node (pid 9120), this Mac only")
        #expect(LocalServices.summaryText(listeners, port: 8080) == "Nothing of yours is listening on port 8080.")
        #expect(LocalServices.summaryText([], port: 0) == "Nothing of yours is listening on this Mac.")
    }

    @Test func describesTheBattery() {
        let pmset = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=7471203)\t64%; discharging; 3:12 remaining present: true\n"
        let ioreg = """
          |   "MaxCapacity" = 100
          |   "CycleCount" = 1318
          |   "BatteryData" = {"CurrentCapacity"=100,"AppleRawMaxCapacity"=6358,"DesignCapacity"=8694,"MaxCapacity"=100}
        """
        #expect(MacReadings.batteryText(pmset: pmset, ioreg: ioreg)
            == "Battery: 64%, on battery, 3:12 remaining, 1318 cycles, health 73% of its original capacity.")
        let charged = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=1)\t100%; charged; 0:00 remaining present: true\n"
        #expect(MacReadings.batteryText(pmset: charged, ioreg: "") == "Battery: 100%, on power, not charging.")
        #expect(MacReadings.batteryText(pmset: "Now drawing from 'AC Power'\n", ioreg: "") == "This Mac has no battery.")
    }

    @Test func describesUptime() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let text = MacReadings.uptimeText(started: now.addingTimeInterval(-(3 * 86_400 + 4 * 3600 + 120)), now: now, load: [1.5, 1.25, 1])
        #expect(text.hasPrefix("Up 3 days 4 h, since "))
        #expect(text.contains("Load average 1.50, 1.25, 1.00 over 1, 5 and 15 minutes"))
        #expect(MacReadings.uptimeText(started: now.addingTimeInterval(-300), now: now, load: []).hasPrefix("Up 5 min, since "))
    }

    @Test func readsThisMacDirectly() async {
        #expect(await MacReadings.diskSpace(AskArguments()).hasPrefix("Startup disk"))
        #expect(await MacReadings.uptime(AskArguments()).hasPrefix("Up "))
        #expect(await MacReadings.battery(AskArguments()).isEmpty == false)
        #expect(await LocalServices.summary(AskArguments(integers: ["port": 1])) == "Nothing of yours is listening on port 1.")
    }

    @Test func offersOnlyWiredTools() async {
        let wired = Set(AskTools.wired.map(\.name))
        #expect(wired.isSuperset(of: ["disk_space", "uptime", "battery", "local_services"]))
        #expect(!wired.contains("network_usage") || AskTools.tool("network_usage")?.run != nil)
        #expect(Set(AskTools.all.map(\.name)).count == AskTools.all.count)
        #expect(await AskTools.run("nope", AskArguments()) == "There is no tool called nope.")

        AskTools.wire("servers") { _ in String(repeating: "x", count: 2000) }
        #expect(AskTools.wired.contains { $0.name == "servers" })
        let long = await AskTools.run("servers", AskArguments())
        #expect(long.count == 1801 && long.hasSuffix("…"))
    }

    @Test func namesEachLookup() {
        #expect(AskTools.line("network_usage", AskArguments(integers: ["days": 7], texts: ["app": "Safari"])) == "data usage · 7 days · Safari")
        #expect(AskTools.line("recent_events", AskArguments(integers: ["hours": 24])) == "the event log · 24 h")
        #expect(AskTools.line("network_usage", AskArguments(integers: ["days": 1])) == "data usage · 1 day")
        #expect(AskTools.line("local_services", AskArguments(integers: ["port": 0])) == "local services")
        #expect(AskTools.line("mystery", AskArguments()) == "mystery")
    }

    @Test func buildsToolSchemasAndReadsArgumentsBack() throws {
        let tool = try #require(AskTools.tool("network_usage"))
        let dynamic = DynamicTool(tool) { _ in }
        #expect(dynamic.name == "network_usage")
        let content = GeneratedContent(properties: ["days": 90, "app": "Mail"])
        let args = dynamic.arguments(content)
        #expect(args.integers["days"] == 35)
        #expect(args.text("app") == "mail")
        let flags = DynamicTool(try #require(AskTools.tool("command_runs"))) { _ in }
        #expect(flags.arguments(GeneratedContent(properties: ["installsOnly": true, "query": "npm"])) ==
            AskArguments(texts: ["query": "npm"], flags: ["installsOnly": true]))
        for tool in AskTools.all { _ = DynamicTool.schema(tool) }
    }

    @Test func explainsFailures() {
        #expect(AskEngine.explain(CancellationError()).0 == false)
        #expect(AskEngine.instructions(now: .now, tools: ["uptime"]).contains("can't see that yet"))
    }

    /// A real question to Apple's on-device model, when this Mac has it.
    @Test(.timeLimit(.minutes(1))) func answersOnThisMac() async {
        let availability = AskEngine.availability()
        guard availability.available else {
            #expect(!availability.reason.isEmpty)
            let events = await collect(AskEngine().ask("How long has this Mac been up?", conversation: "test"))
            #expect(events == [.failed(availability.reason)])
            return
        }
        let events = await collect(AskEngine().ask("How long has this Mac been up?", conversation: "test"))
        let done = events.compactMap { if case .done(let text) = $0 { text } else { nil } }.first
        let failed = events.compactMap { if case .failed(let text) = $0 { text } else { nil } }.first
        #expect(done != nil || failed != nil)
        if let done { #expect(!done.isEmpty) }
        #expect(await collect(AskEngine().ask("   ", conversation: "test")) == [.failed("Ask something first.")])
    }

    func collect(_ stream: AsyncStream<AskEvent>) async -> [AskEvent] {
        var out: [AskEvent] = []
        for await event in stream { out.append(event) }
        return out
    }

    // MARK: The drag assistant

    static let screen = NSRect(x: 0, y: 0, width: 1440, height: 875)

    @Test func docksRightThenLeftThenInside() {
        let size = NSSize(width: 340, height: 100)
        #expect(DragAssistant.dock(NSRect(x: 100, y: 200, width: 700, height: 500), size: size, screen: Self.screen) == NSPoint(x: 812, y: 400))
        #expect(DragAssistant.dock(NSRect(x: 700, y: 200, width: 700, height: 500), size: size, screen: Self.screen).x == CGFloat(700 - 12 - 340))
        #expect(DragAssistant.dock(NSRect(x: 100, y: 200, width: 1300, height: 600), size: size, screen: Self.screen)
            == NSPoint(x: 1400 - 12 - 340, y: 212))
    }

    @Test func staysOnAScreenShorterThanThePanel() {
        let at = DragAssistant.dock(NSRect(x: 0, y: 0, width: 400, height: 50), size: DragAssistant.size,
                                    screen: NSRect(x: 0, y: 0, width: 1440, height: 60))
        #expect(at.y == 0)
    }

    @Test func flipsQuartzToAppKit() {
        #expect(DragAssistant.flip(NSRect(x: 10, y: 25, width: 700, height: 500), primaryHeight: 900).origin == NSPoint(x: 10, y: 375))
        // A display above the primary one has negative Quartz y.
        #expect(DragAssistant.flip(NSRect(x: 0, y: -1000, width: 700, height: 500), primaryHeight: 900).minY == 1400)
    }

    @Test func unionAndOverlap() {
        #expect(DragAssistant.union(NSRect(x: 0, y: 10, width: 10, height: 10), NSRect(x: 5, y: 0, width: 20, height: 5))
            == NSRect(x: 0, y: 0, width: 25, height: 20))
        #expect(DragAssistant.overlap(NSRect(x: 0, y: 0, width: 10, height: 10), NSRect(x: 20, y: 0, width: 10, height: 10)) == 0)
        #expect(DragAssistant.overlap(NSRect(x: 0, y: 0, width: 10, height: 10), NSRect(x: 5, y: 5, width: 10, height: 10)) == 25)
    }

    @Test func readsPermissionsWithoutAsking() async {
        let some = await Access.status([.microphone, .accessibility, .fullDisk])
        #expect(Set(some.keys) == [.microphone, .accessibility, .fullDisk])
        // A test binary isn't an app: notifications answer nil, not a crash.
        #expect(await Access.notifications.granted() == nil)
        #expect(Access.allCases.allSatisfy { $0.settingsURL.scheme == "x-apple.systempreferences" })
        #expect(Access.allCases.filter(\.isList) == [.fullDisk, .appManagement, .accessibility])
    }
}
