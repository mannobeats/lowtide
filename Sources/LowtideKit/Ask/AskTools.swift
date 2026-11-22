import Foundation
import Synchronization

/// What a tool was called with, read by name.
public struct AskArguments: Equatable, Sendable {
    public var integers: [String: Int] = [:]
    public var texts: [String: String] = [:]
    public var flags: [String: Bool] = [:]

    public init(integers: [String: Int] = [:], texts: [String: String] = [:], flags: [String: Bool] = [:]) {
        self.integers = integers
        self.texts = texts
        self.flags = flags
    }

    public func int(_ name: String, default value: Int) -> Int { integers[name] ?? value }
    /// Trimmed and lowercased, "" when absent.
    public func text(_ name: String) -> String { (texts[name] ?? "").trimmingCharacters(in: .whitespaces).lowercased() }
    public func flag(_ name: String) -> Bool { flags[name] ?? false }
}

/// One lookup the on-device model may make. The model never sees raw data:
/// it calls a tool, and the tool answers with a short, ranked summary
/// computed on this Mac.
public struct AskTool: Sendable {
    public enum Parameter: Sendable {
        case integer(String, String, ClosedRange<Int>)
        case text(String, String)
        case flag(String, String)

        public var name: String {
            switch self {
            case .integer(let name, _, _), .text(let name, _), .flag(let name, _): name
            }
        }
    }

    public var name: String
    public var description: String
    /// What the lookup is called on screen: "Checked data usage · 7 days".
    public var label: String
    public var parameters: [Parameter]
    /// nil until the area that knows the answer wires it in.
    public var run: (@Sendable (AskArguments) async -> String)?

    public init(_ name: String, label: String, description: String, parameters: [Parameter] = [],
                run: (@Sendable (AskArguments) async -> String)? = nil) {
        self.name = name
        self.label = label
        self.description = description
        self.parameters = parameters
        self.run = run
    }
}

/// Every tool Ask knows. The ones that need another area's data (traffic,
/// threats, updates, servers…) start unwired; that area wires its summary
/// in at launch with `AskTools.wire("network_usage") { args in … }`. Only
/// wired tools are offered to the model, so it never calls one that can't answer.
public enum AskTools {
    private static let registry = Mutex<[AskTool]>(defaults)

    public static var all: [AskTool] { registry.withLock { $0 } }
    public static var wired: [AskTool] { all.filter { $0.run != nil } }

    /// Gives a tool its answer. Replaces an earlier one.
    public static func wire(_ name: String, _ run: @escaping @Sendable (AskArguments) async -> String) {
        registry.withLock { tools in
            if let at = tools.firstIndex(where: { $0.name == name }) { tools[at].run = run }
        }
    }

    public static func tool(_ name: String) -> AskTool? { all.first { $0.name == name } }

    /// Runs a tool, keeping its answer short: the model's memory is small.
    public static func run(_ name: String, _ arguments: AskArguments) async -> String {
        guard let run = tool(name)?.run else { return "There is no tool called \(name)." }
        let answer = await run(arguments)
        return answer.count > 1800 ? String(answer.prefix(1800)) + "…" : answer
    }

    /// "data usage · 7 days · Safari".
    public static func line(_ name: String, _ arguments: AskArguments) -> String {
        let label = tool(name)?.label ?? name
        var detail: [String] = []
        if let days = arguments.integers["days"], days > 0 { detail.append(days == 1 ? "1 day" : "\(days) days") }
        if let hours = arguments.integers["hours"], hours > 0 { detail.append("\(hours) h") }
        if let port = arguments.integers["port"], port > 0 { detail.append("port \(port)") }
        for key in ["app", "country", "query"] {
            if let value = arguments.texts[key]?.trimmingCharacters(in: .whitespaces), !value.isEmpty { detail.append(value) }
        }
        return ([label] + detail).joined(separator: " · ")
    }

    static let defaults: [AskTool] = [
        AskTool("network_usage", label: "data usage",
                description: "Data usage per app: how much each app uploaded (sent) and downloaded (received) over the last N days, ranked. Use for any question about uploads, downloads, bandwidth or which app used the most data.",
                parameters: [.integer("days", "How many days back, 1 for today, 7 for this week", 1...35),
                             .text("app", "An app name to focus on, or empty for all apps")]),
        AskTool("live_traffic", label: "live traffic",
                description: "The network right now, this second: current speeds and the apps active at this moment. Use only for questions about now."),
        AskTool("countries_reached", label: "countries reached",
                description: "Countries apps connected to over the last N days. Use for questions about countries, regions or where data went.",
                parameters: [.integer("days", "How many days back", 1...35),
                             .text("country", "A country name or two-letter code to focus on, or empty for all")]),
        AskTool("recent_events", label: "the event log",
                description: "Alerts and unusual events over the last N hours. Use for questions about anything suspicious, alerts, warnings or what changed.",
                parameters: [.integer("hours", "How many hours back", 1...720)]),
        AskTool("command_runs", label: "command receipts",
                description: "Terminal commands and package installs (npm, pip, brew, cargo) and what they did. Use only for questions about commands, installs or packages.",
                parameters: [.flag("installsOnly", "Only package installs (npm, pip, brew, cargo…)"),
                             .text("query", "Words to look for in the command, or empty")]),
        AskTool("local_services", label: "local services",
                description: "Servers listening on ports on this Mac (dev servers, databases) and which process holds each port. Use for questions about ports, localhost, dev servers or what is listening.",
                parameters: [.integer("port", "One port to look at, or 0 for all", 0...65535)], run: LocalServices.summary),
        AskTool("away_briefings", label: "overnight reports",
                description: "What happened while the user was away from the Mac, such as overnight. Use for questions about last night or while I was away."),
        AskTool("servers", label: "the fleet",
                description: "The user's remote SSH servers and their health. Use for questions about servers."),
        AskTool("security_status", label: "protection status",
                description: "Security overview: threats, decoy credential canaries, secrets exposed on disk, install tripwire. Use for questions about security, threats, secrets or canaries."),
        AskTool("app_updates", label: "app updates",
                description: "Apps and command-line tools with updates waiting. Use for questions about updates, outdated apps or new versions."),
        AskTool("disk_space", label: "disk space",
                description: "Free and total space on the startup disk and other mounted disks. Use for questions about storage, disk space or how full the Mac is.",
                run: MacReadings.diskSpace),
        AskTool("uptime", label: "uptime",
                description: "How long the Mac has been running since it last started, and its load. Use for questions about uptime, restarts or when the Mac last booted.",
                run: MacReadings.uptime),
        AskTool("battery", label: "the battery",
                description: "The battery's charge, whether it is charging, its health and cycle count. Use for questions about the battery or power.",
                run: MacReadings.battery),
    ]
}

/// Readings Ask answers from directly, with nothing but system calls.
public enum MacReadings {
    @Sendable public static func diskSpace(_: AskArguments) async -> String {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
                                      .volumeIsRootFileSystemKey, .volumeIsBrowsableKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var lines: [String] = []
        for url in volumes {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable != false,
                  let total = v.volumeTotalCapacity, total > 0 else { continue }
            let free = v.volumeAvailableCapacityForImportantUsage ?? 0
            let name = v.volumeIsRootFileSystem == true ? "Startup disk (\(v.volumeName ?? "Macintosh HD"))" : v.volumeName ?? url.lastPathComponent
            let used = Double(Int64(total) - free) / Double(total)
            let line = "\(name): \(Format.bytes(free)) free of \(Format.bytes(Int64(total))), \(Format.percent(used)) used"
            if v.volumeIsRootFileSystem == true { lines.insert(line, at: 0) } else { lines.append(line) }
        }
        return lines.isEmpty ? "Couldn't read the disks." : lines.joined(separator: "\n")
    }

    @Sendable public static func uptime(_: AskArguments) async -> String {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return "Couldn't read when the Mac started." }
        let started = Date(timeIntervalSince1970: TimeInterval(boot.tv_sec))
        return uptimeText(started: started, now: .now, load: loadAverages())
    }

    static func loadAverages() -> [Double] {
        var load = [Double](repeating: 0, count: 3)
        return getloadavg(&load, 3) == 3 ? load : []
    }

    static func uptimeText(started: Date, now: Date, load: [Double]) -> String {
        let seconds = Int(now.timeIntervalSince(started))
        let days = seconds / 86_400, hours = seconds % 86_400 / 3600, minutes = seconds % 3600 / 60
        let span = days > 0 ? "\(days) \(days == 1 ? "day" : "days") \(hours) h" : hours > 0 ? "\(hours) h \(minutes) min" : "\(minutes) min"
        var text = "Up \(span), since \(started.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute()))."
        if load.count == 3 {
            text += String(format: " Load average %.2f, %.2f, %.2f over 1, 5 and 15 minutes, on %d cores.", load[0], load[1], load[2],
                           ProcessInfo.processInfo.activeProcessorCount)
        }
        return text
    }

    @Sendable public static func battery(_: AskArguments) async -> String {
        guard let text = try? await Shell.run("/usr/bin/pmset", ["-g", "batt"], timeout: .seconds(3)), text.ok else {
            return "Couldn't read the battery."
        }
        let registry = try? await Shell.run("/usr/sbin/ioreg", ["-rn", "AppleSmartBattery"], timeout: .seconds(3))
        return batteryText(pmset: text.stdout, ioreg: registry?.stdout ?? "")
    }

    /// `pmset -g batt` and `ioreg -rn AppleSmartBattery` into one line.
    static func batteryText(pmset: String, ioreg: String) -> String {
        guard let battery = MacFacts.parseBattery(pmset) else { return "This Mac has no battery." }
        var parts = ["\(battery.percent)%"]
        parts.append(battery.charging ? "charging" : battery.onPower ? "on power, not charging" : "on battery")
        if let line = pmset.split(separator: "\n").first(where: { $0.contains("InternalBattery") }),
           let match = line.firstMatch(of: /(\d+:\d\d) remaining/), match.1 != "0:00" {
            parts.append("\(match.1) remaining")
        }
        func number(_ key: String) -> Int? {
            (ioreg.firstMatch(of: try! Regex("\"\(key)\"\\s*=\\s*(\\d+)"))?.output[1].substring).flatMap { Int($0) }
        }
        if let cycles = number("CycleCount") { parts.append("\(cycles) cycles") }
        if let max = number("AppleRawMaxCapacity"), let design = number("DesignCapacity"), design > 0 {
            parts.append("health \(Int((Double(max) / Double(design) * 100).rounded()))% of its original capacity")
        }
        return "Battery: " + parts.joined(separator: ", ") + "."
    }
}

/// What's listening on this Mac's ports, from `lsof` (the person's own
/// processes; macOS shows no one else's without root).
public enum LocalServices {
    public struct Listener: Equatable, Sendable {
        public var port: Int
        public var pid: Int
        public var process: String
        /// Every address it listens on: `*`, `127.0.0.1`, `::1`…
        public var addresses: [String]

        /// Reachable from other machines, not just this Mac.
        public var exposed: Bool { addresses.contains { !["127.0.0.1", "::1", "localhost"].contains($0) } }
    }

    /// `lsof -nP -iTCP -sTCP:LISTEN -F pcn` output into one listener per port and process.
    public static func parse(_ text: String) -> [Listener] {
        var pid = 0, command = ""
        var byKey: [String: Listener] = [:]
        for line in text.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int(value) ?? 0
            case "c": command = value
            case "n":
                guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) else { continue }
                var address = String(value[..<colon])
                if address.hasPrefix("["), address.hasSuffix("]") { address = String(address.dropFirst().dropLast()) }
                let key = "\(port)/\(pid)"
                var listener = byKey[key] ?? Listener(port: port, pid: pid, process: command, addresses: [])
                if !listener.addresses.contains(address) { listener.addresses.append(address) }
                byKey[key] = listener
            default: continue
            }
        }
        return byKey.values.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    public static func list() async -> [Listener] {
        guard let out = try? await Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"], timeout: .seconds(8)) else {
            return []
        }
        return parse(out.stdout)
    }

    @Sendable public static func summary(_ arguments: AskArguments) async -> String {
        summaryText(await list(), port: arguments.int("port", default: 0))
    }

    static func summaryText(_ listeners: [Listener], port: Int) -> String {
        let shown = port > 0 ? listeners.filter { $0.port == port } : listeners
        if shown.isEmpty {
            return port > 0 ? "Nothing of yours is listening on port \(port)." : "Nothing of yours is listening on this Mac."
        }
        let lines = shown.prefix(15).map { l in
            "- port \(l.port): \(l.process) (pid \(l.pid))\(l.exposed ? ", REACHABLE FROM THE NETWORK" : ", this Mac only")"
        }
        return "Listening on this Mac:\n" + lines.joined(separator: "\n")
    }
}
