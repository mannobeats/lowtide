import Foundation

/// How the system monitor's numbers read.
public enum SystemFormat {
    /// Memory, which macOS counts in powers of two: 16 GB of RAM is 16 GiB.
    /// `412 KB`, `6.3 GB`, `16 GB`.
    public static func memory(_ bytes: UInt64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(bytes) / 1024
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return value >= 10 ? "\(Int(value.rounded())) \(units[unit])" : String(format: "%.1f %@", value, units[unit])
    }

    /// `3.23 GHz`, `912 MHz`.
    public static func clock(_ mhz: Int) -> String {
        mhz >= 1000 ? String(format: "%.2f GHz", Double(mhz) / 1000) : "\(mhz) MHz"
    }

    /// `12.4 W`, `0.42 W`.
    public static func watts(_ w: Double) -> String {
        w >= 10 ? String(format: "%.1f W", w) : String(format: "%.2f W", w)
    }

    /// `12.3 GB/s`.
    public static func bandwidth(_ bytesPerSecond: Double) -> String {
        String(format: "%.1f GB/s", bytesPerSecond / 1e9)
    }

    /// Decimal amounts, compact: `1.2 GB`, `340 KB`.
    public static func amount(_ bytes: Double) -> String {
        if bytes >= 1e9 { return String(format: "%.1f GB", bytes / 1e9) }
        if bytes >= 1e6 { return String(format: "%.1f MB", bytes / 1e6) }
        if bytes >= 1e3 { return "\(Int((bytes / 1e3).rounded())) KB" }
        return "\(Int(bytes.rounded())) B"
    }

    /// `1.2 MB/s`.
    public static func rate(_ bytesPerSecond: Double) -> String { amount(bytesPerSecond) + "/s" }

    /// `64°C`, or a dash when unknown.
    public static func celsius(_ c: Double) -> String { c > 0 ? "\(Int(c.rounded()))°C" : "–" }

    /// `2 h 14 min`.
    public static func minutes(_ m: Int) -> String { "\(m / 60) h \(m % 60) min" }

    /// How long something has been running: `14 min`, `3 h 2 min`, `4 days`.
    public static func running(since: Date, now: Date = .now) -> String {
        let minutes = max(Int(now.timeIntervalSince(since) / 60), 0)
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        return hours < 48 ? "\(hours) h \(minutes % 60) min" : "\(hours / 24) days"
    }

    /// CPU time: `4.2 s`, `12 min 3 s`, `3 h 12 min`.
    public static func cpuTime(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        let m = Int(seconds / 60)
        return m < 120 ? "\(m) min \(Int(seconds.truncatingRemainder(dividingBy: 60).rounded())) s" : "\(m / 60) h \(m % 60) min"
    }

    /// Peak memory bandwidth by chip, GB/s (Apple's published figures).
    public static func peakBandwidth(_ chip: String) -> Double? {
        let table: [([String], Double)] = [
            (["M1 Ultra", "M2 Ultra"], 800), (["M3 Ultra"], 819), (["M4 Max"], 546),
            (["M1 Max", "M2 Max", "M3 Max"], 400), (["M4 Pro"], 273), (["M1 Pro", "M2 Pro"], 200),
            (["M3 Pro"], 150), (["M4"], 120), (["M2", "M3"], 100), (["M1"], 68),
        ]
        return table.first { names, _ in names.contains { chip.contains($0) } }?.1
    }

    /// How the Mac is doing, in a few words: heat first.
    public static func mood(thermal: ThermalLevel, cpuTemp: Double) -> String {
        if thermal >= .serious { return "Running hot" }
        if thermal == .fair || cpuTemp >= 85 { return "Running warm" }
        return "Running cool"
    }
}
