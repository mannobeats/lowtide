import Foundation

/// How numbers, sizes and times read everywhere in the app.
public enum Format {
    /// `3.7 GB`, decimal like Finder.
    public static func bytes(_ value: Int64) -> String {
        if value < 1000 { return "\(value) B" }
        let units = ["KB", "MB", "GB", "TB", "PB"]
        var size = Double(value) / 1000
        var unit = 0
        while size >= 1000, unit < units.count - 1 {
            size /= 1000
            unit += 1
        }
        return size >= 100 ? "\(Int(size.rounded())) \(units[unit])" : String(format: "%.1f %@", size, units[unit])
    }

    public static func bytes(_ value: Int) -> String { bytes(Int64(value)) }
    public static func bytes(_ value: UInt64) -> String { bytes(Int64(clamping: value)) }

    /// `2 KB/s`.
    public static func rate(_ bytesPerSecond: Double) -> String {
        bytes(Int64(bytesPerSecond.rounded())) + "/s"
    }

    /// `3 min ago`, `just now`, `yesterday`.
    public static func ago(_ date: Date, now: Date = .now) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 45 { return "just now" }
        if seconds < 3600 { return "\(Int((seconds / 60).rounded())) min ago" }
        if seconds < 86_400 { return "\(Int((seconds / 3600).rounded())) h ago" }
        if seconds < 172_800 { return "yesterday" }
        if seconds < 30 * 86_400 { return "\(Int(seconds / 86_400)) days ago" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// `1 h 4 min`, `42 s`.
    public static func duration(_ seconds: Double) -> String {
        if seconds < 1 { return "\(Int((seconds * 1000).rounded())) ms" }
        if seconds < 60 { return "\(Int(seconds.rounded())) s" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(rest) min"
    }

    /// `42%`.
    public static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

    /// `1 app`, `3 apps`.
    public static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n.formatted()) \(n == 1 ? singular : plural ?? singular + "s")"
    }
}
