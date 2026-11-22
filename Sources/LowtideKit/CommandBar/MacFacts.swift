import AppKit

/// Battery, memory, storage, Wi-Fi, appearance, Finder and sound, for the
/// bar's answer rows and its toggles' titles ("Switch to light").
public struct MacFacts: Equatable, Sendable {
    public struct Battery: Equatable, Sendable {
        public var percent: Int
        public var charging: Bool
        public var onPower: Bool
    }

    public var battery: Battery?
    /// App memory + wired + compressed, as Activity Monitor counts it.
    public var memoryUsed: UInt64 = 0
    public var memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    /// Free space on the boot volume "for important usage".
    public var storageAvailable: Int64 = 0
    public var storageTotal: Int64 = 0
    /// nil when the Mac has no Wi-Fi interface.
    public var wifi: Bool?
    public var darkMode = false
    public var hiddenFiles = false
    public var desktopIcons = true
    public var muted = false
    public var volume = 0

    public init() {}

    static let probe: Duration = .seconds(2)

    /// Everything, read concurrently; a probe that fails or takes longer
    /// than 2 s keeps its default.
    public static func read() async -> MacFacts {
        async let battery = run("/usr/bin/pmset", ["-g", "batt"]).flatMap(parseBattery)
        async let memory = run("/usr/bin/vm_stat", []).flatMap(parseVMStat)
        async let wifi = wifiPower()
        async let sound = run("/usr/bin/osascript", ["-e", "get volume settings"]).map(parseVolume)
        var facts = MacFacts()
        facts.battery = await battery
        facts.memoryUsed = await memory ?? 0
        facts.wifi = await wifi
        (facts.volume, facts.muted) = await sound ?? (0, false)
        (facts.storageAvailable, facts.storageTotal) = storage()
        facts.darkMode = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        facts.hiddenFiles = finderFlag("AppleShowAllFiles") ?? false
        facts.desktopIcons = finderFlag("CreateDesktop") ?? true
        return facts
    }

    static func run(_ program: String, _ args: [String]) async -> String? {
        guard let out = try? await Shell.run(program, args, timeout: probe), out.ok else { return nil }
        return out.stdout
    }

    /// `pmset -g batt`. nil on a Mac without a battery.
    static func parseBattery(_ text: String) -> Battery? {
        let onPower = text.contains("'AC Power'")
        guard let line = text.split(separator: "\n").first(where: { $0.contains("InternalBattery") }),
              let percentAt = line.firstIndex(of: "%") else { return nil }
        let digits = String(line[..<percentAt].reversed().prefix { $0.isASCIIDigit }.reversed())
        guard let percent = Int(digits) else { return nil }
        let fields = line.split(separator: ";")
        let state = fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespaces) : ""
        return Battery(percent: min(percent, 100), charging: state == "charging" || state == "finishing charge", onPower: onPower)
    }

    /// Memory in use from `vm_stat`: app memory (anonymous minus purgeable),
    /// wired, and what the compressor occupies.
    static func parseVMStat(_ text: String) -> UInt64? {
        guard let sizeText = text.components(separatedBy: "page size of ").dropFirst().first?.split(separator: " ").first,
              let page = UInt64(sizeText) else { return nil }
        func pages(_ label: String) -> UInt64 {
            for line in text.split(separator: "\n") where line.hasPrefix(label) {
                let rest = line.dropFirst(label.count).drop { $0 == ":" }.trimmingCharacters(in: .whitespaces)
                return UInt64(rest.hasSuffix(".") ? String(rest.dropLast()) : rest) ?? 0
            }
            return 0
        }
        let anonymous = pages("Anonymous pages"), purgeable = pages("Pages purgeable")
        let app = anonymous > purgeable ? anonymous - purgeable : 0
        return (app + pages("Pages wired down") + pages("Pages occupied by compressor")) * page
    }

    /// The Wi-Fi device name (`en0`) from `networksetup -listallhardwareports`.
    static func parseWifiDevice(_ text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, line) in lines.enumerated() where line.hasPrefix("Hardware Port:") {
            let port = line.dropFirst("Hardware Port:".count).trimmingCharacters(in: .whitespaces)
            guard port == "Wi-Fi" || port == "AirPort", i + 1 < lines.count, lines[i + 1].hasPrefix("Device:") else { continue }
            let device = lines[i + 1].dropFirst("Device:".count).trimmingCharacters(in: .whitespaces)
            return device.isEmpty ? nil : device
        }
        return nil
    }

    /// Output volume and mute from AppleScript's `get volume settings`.
    static func parseVolume(_ text: String) -> (Int, Bool) {
        func field(_ name: String) -> String? {
            text.split(separator: ",").lazy.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { $0.hasPrefix(name) }.map { String($0.dropFirst(name.count)).trimmingCharacters(in: .whitespaces) }
        }
        return (min(Int(field("output volume:") ?? "") ?? 0, 100), field("output muted:") == "true")
    }

    private static let wifiDeviceCache = OSAllocatedLock<String??>(initialState: nil)

    static func wifiDevice() async -> String? {
        if let cached = wifiDeviceCache.withLock({ $0 }) { return cached }
        guard let text = await run("/usr/sbin/networksetup", ["-listallhardwareports"]) else { return nil }
        let device = parseWifiDevice(text)
        wifiDeviceCache.withLock { $0 = .some(device) }
        return device
    }

    static func wifiPower() async -> Bool? {
        guard let device = await wifiDevice(),
              let text = await run("/usr/sbin/networksetup", ["-getairportpower", device]) else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("On")
    }

    static func storage() -> (Int64, Int64) {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) else { return (0, 0) }
        return (values.volumeAvailableCapacityForImportantUsage ?? 0, Int64(values.volumeTotalCapacity ?? 0))
    }

    /// A Finder boolean preference; nil when it was never set.
    static func finderFlag(_ key: String) -> Bool? {
        guard let value = CFPreferencesCopyAppValue(key as CFString, "com.apple.finder" as CFString) else { return nil }
        if let flag = value as? Bool { return flag }
        if let text = value as? String { return ["1", "true", "yes"].contains(text.lowercased()) }
        return nil
    }
}

import os

typealias OSAllocatedLock = OSAllocatedUnfairLock
