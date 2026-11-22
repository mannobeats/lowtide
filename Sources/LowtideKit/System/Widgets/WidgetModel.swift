import Foundation

/// What a menu-bar widget measures.
public enum WidgetMetric: String, Codable, Sendable, CaseIterable {
    case cpu, gpu, memory, network, disk, battery, temperature, power, fans

    public var label: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "Memory"
        case .network: "Network"
        case .disk: "Disk"
        case .battery: "Battery"
        case .temperature: "Temperature"
        case .power: "Power"
        case .fans: "Fans"
        }
    }

    /// What it can look like; the first is its default.
    public var styles: [WidgetStyle] {
        switch self {
        case .cpu: [.value, .bar, .cores, .chart, .ring]
        case .gpu, .memory: [.value, .bar, .chart, .ring]
        case .disk: [.value, .bar, .ring]
        case .network: [.speed, .chart]
        case .battery, .temperature, .power, .fans: [.value]
        }
    }
}

public enum WidgetStyle: String, Codable, Sendable, CaseIterable {
    case value, bar, cores, chart, ring, speed

    public var label: String {
        switch self {
        case .value: "Value"
        case .bar: "Bar"
        case .cores: "Cores"
        case .chart: "Chart"
        case .ring: "Ring"
        case .speed: "Speed"
        }
    }
}

/// How the strip colours its data.
public enum WidgetColor: String, Codable, Sendable, CaseIterable {
    /// A template image, tinted by macOS like every other menu-bar item.
    case mono
    /// Each value by its own level: green when calm, amber, then red.
    case load
    /// One colour per metric.
    case accent

    public var label: String {
        switch self {
        case .mono: "Mono"
        case .load: "Load"
        case .accent: "Accent"
        }
    }

    public var hint: String {
        switch self {
        case .mono: "Tinted by macOS like every menu-bar item"
        case .load: "Each value by its level: green, amber, red"
        case .accent: "One colour per metric"
        }
    }
}

/// One widget in the strip.
public struct WidgetSpec: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var metric: WidgetMetric
    public var style: WidgetStyle
    /// This widget's own preset; nil follows the strip's.
    public var color: WidgetColor?

    public init(id: String, metric: WidgetMetric, style: WidgetStyle, color: WidgetColor? = nil) {
        self.id = id
        self.metric = metric
        self.style = style
        self.color = color
    }

    public init(metric: WidgetMetric) {
        self.init(id: "\(metric.rawValue)-\(UUID().uuidString.prefix(8).lowercased())", metric: metric,
                  style: metric.styles[0])
    }

    public static let defaults = [
        WidgetSpec(id: "cpu", metric: .cpu, style: .value),
        WidgetSpec(id: "memory", metric: .memory, style: .value),
        WidgetSpec(id: "network", metric: .network, style: .speed),
    ]
}

/// What the widgets show, read once per frame.
public struct WidgetReadings: Sendable, Equatable {
    /// Shares are 0–1.
    public var cpu: Double = 0
    /// Per core, efficiency cores first, and how many of them there are.
    public var cores: [Double] = []
    public var efficiency = 0
    public var gpu: Double = 0
    public var memory: Double = 0
    /// The least heat memory shows, from macOS's memory pressure.
    public var memoryPressure: Double = 0
    public var cpuHistory: [Double] = []
    public var gpuHistory: [Double] = []
    public var memoryHistory: [Double] = []
    /// Bytes per second.
    public var rateIn: Double = 0
    public var rateOut: Double = 0
    public var inHistory: [Double] = []
    public var outHistory: [Double] = []
    /// Used share of the home volume.
    public var disk: Double?
    /// Percent and charging; nil on a Mac without a battery.
    public var battery: (percent: Double, charging: Bool)?
    public var cpuTemp: Double = 0
    public var systemWatts: Double = 0
    /// Fastest fan; nil on a Mac without fans.
    public var fanRPM: Double?
    /// The busiest fan's share of its top speed.
    public var fanShare: Double = 0

    public init() {}

    public static func == (a: WidgetReadings, b: WidgetReadings) -> Bool {
        a.cpu == b.cpu && a.cores == b.cores && a.gpu == b.gpu && a.memory == b.memory && a.rateIn == b.rateIn
            && a.rateOut == b.rateOut && a.disk == b.disk && a.battery?.percent == b.battery?.percent
            && a.battery?.charging == b.battery?.charging && a.cpuTemp == b.cpuTemp && a.systemWatts == b.systemWatts
            && a.fanRPM == b.fanRPM && a.cpuHistory == b.cpuHistory && a.inHistory == b.inHistory
    }

    /// Readings from the monitor's recent samples (oldest first) and detail.
    public init(samples: [SystemSample], detail: SystemDetail?) {
        let recent = samples.suffix(WidgetLayout.spark)
        cpuHistory = recent.map { $0.cpu / 100 }
        gpuHistory = recent.map { $0.gpu / 100 }
        memoryHistory = recent.map(\.memory.usedShare)
        inHistory = recent.map(\.network.bytesIn)
        outHistory = recent.map(\.network.bytesOut)
        if let last = samples.last {
            cpu = last.cpu / 100
            gpu = last.gpu / 100
            memory = last.memory.usedShare
            memoryPressure = switch last.memory.pressure {
            case .critical: 1
            case .warning: 0.65
            case .normal: 0
            }
            cores = last.cores.map { $0.usage / 100 }
            efficiency = last.cores.filter { $0.kind == .efficiency }.count
            cpuTemp = last.cpuTemp
            systemWatts = last.power.system > 0 ? last.power.system : last.power.total
            rateIn = last.network.bytesIn
            rateOut = last.network.bytesOut
            disk = last.disk?.usedShare
            if let fans = last.fanRPM.max() { fanRPM = fans }
        }
        if let b = detail?.battery ?? samples.last?.battery { battery = (b.percent, b.charging) }
        if let fans = detail?.fans, !fans.isEmpty {
            fanRPM = fanRPM ?? fans.map(\.rpm).max()
            fanShare = fans.filter { $0.max > $0.min }.map(\.share).max() ?? 0
        }
    }
}

/// One widget, resolved to what it draws.
public enum WidgetPiece: Equatable, Sendable {
    /// A tiny label over the value. `level` is in the metric's own units.
    case value(label: String, value: String, widest: [String], level: Double)
    /// Level bars; more than one is per core, `split` where P cores start.
    case bars(label: String, levels: [Double], split: Int)
    case chart(label: String, series: [Double])
    case ring(label: String, level: Double)
    case speed(up: String, down: String)
    /// Download filled, upload as a line, on one scale.
    case traffic(down: [Double], up: [Double])
    case battery(level: Double, charging: Bool, text: String)
}

/// Sizes of the strip, in points.
public enum WidgetLayout {
    /// The menu bar shows the image 18 pt tall.
    public static let height = 18.0
    /// Between widgets.
    public static let gap = 6.0
    /// Samples in a sparkline.
    public static let spark = 30
    static let stack = 6.0
    static let stackGap = 2.5
    static let chartWidth = 30.0
    static let barWidth = 5.0
    static let coreWidth = 2.5
    static let ringWidth = 16.0
    static let arrowWidth = 5.0
    static let batteryWidth = 22.5

    /// Where each widget starts, and the strip's width.
    public static func layout(_ widths: [Double]) -> (starts: [Double], total: Double) {
        var x = 0.0
        var starts: [Double] = []
        for (i, w) in widths.enumerated() {
            if i > 0 { x += gap }
            starts.append(x)
            x += w
        }
        return (starts, x)
    }

    /// Points of a sparkline in a rect, the newest at the right edge; a
    /// short history fills in from the right, one slot per sample.
    public static func sparkPoints(_ levels: [Double], x: Double, y: Double, width: Double, height: Double) -> [(Double, Double)] {
        let levels = levels.suffix(spark)
        let step = width / Double(spark - 1)
        let start = x + width - step * Double(max(levels.count - 1, 0))
        return levels.enumerated().map { i, v in (start + step * Double(i), y + min(max(v, 0), 1) * height) }
    }

    /// A series as 0–1 heights against `max` (or its own peak when 0).
    public static func scaled(_ values: [Double], max: Double) -> [Double] {
        let peak = max > 0 ? max : (values.max() ?? 0)
        guard peak > 0 else { return values.map { _ in 0 } }
        return values.map { Swift.min(Swift.max($0 / peak, 0), 1) }
    }
}

/// The numbers as the strip prints them: never wider than measured.
public enum WidgetText {
    static let percents = ["100%"]
    static let rates = ["888 KB/s", "8.8 MB/s", "888 MB/s", "8.8 GB/s"]

    public static func percent(_ share: Double) -> String { "\(Int((min(max(share, 0), 1) * 100).rounded()))%" }

    /// Decimal: `0 KB/s`, `340 KB/s`, `1.2 MB/s`, `48 MB/s`, `1.1 GB/s`.
    /// Never more than three digits.
    public static func rate(_ bytes: Double) -> String {
        if bytes < 999_500 { return "\(Int((bytes / 1e3).rounded())) KB/s" }
        if bytes < 9.95e6 { return String(format: "%.1f MB/s", bytes / 1e6) }
        if bytes < 999.5e6 { return "\(Int((bytes / 1e6).rounded())) MB/s" }
        return String(format: "%.1f GB/s", bytes / 1e9)
    }

    public static func celsius(_ c: Double) -> String { c <= 0 ? "–" : "\(Int(min(c, 199).rounded()))°" }

    public static func watts(_ w: Double) -> String {
        if w <= 0 { return "–" }
        return w < 9.95 ? String(format: "%.1f W", w) : "\(Int(min(w, 999).rounded())) W"
    }

    public static func rpm(_ r: Double) -> String { "\(Int(min(max(r, 0), 9999).rounded()))" }
}

/// What a widget shows; nil hides it (no battery, no fans, an unknown pairing).
public func widgetPiece(_ metric: WidgetMetric, _ style: WidgetStyle, _ r: WidgetReadings) -> WidgetPiece? {
    let label: String, level: Double, history: [Double]?
    switch metric {
    case .cpu: (label, level, history) = ("CPU", r.cpu, r.cpuHistory)
    case .gpu: (label, level, history) = ("GPU", r.gpu, r.gpuHistory)
    case .memory: (label, level, history) = ("RAM", r.memory, r.memoryHistory)
    // Free space moves too slowly to chart.
    case .disk:
        guard let disk = r.disk else { return nil }
        (label, level, history) = ("SSD", disk, nil)
    case .network:
        let peak = max(10_000, (r.inHistory + r.outHistory).max() ?? 0)
        return style == .chart
            ? .traffic(down: WidgetLayout.scaled(r.inHistory, max: peak), up: WidgetLayout.scaled(r.outHistory, max: peak))
            : .speed(up: WidgetText.rate(r.rateOut), down: WidgetText.rate(r.rateIn))
    case .battery:
        guard let battery = r.battery else { return nil }
        return .battery(level: battery.percent / 100, charging: battery.charging, text: WidgetText.percent(battery.percent / 100))
    case .temperature:
        return .value(label: "TEMP", value: WidgetText.celsius(r.cpuTemp), widest: ["188°"], level: r.cpuTemp)
    case .power:
        return .value(label: "POWER", value: WidgetText.watts(r.systemWatts), widest: ["888 W", "8.8 W"], level: r.systemWatts)
    case .fans:
        guard let rpm = r.fanRPM else { return nil }
        return .value(label: "FAN", value: WidgetText.rpm(rpm), widest: ["8888"], level: r.fanShare)
    }
    switch style {
    case .bar: return .bars(label: label, levels: [level], split: 0)
    case .cores where metric == .cpu && !r.cores.isEmpty: return .bars(label: label, levels: r.cores, split: r.efficiency)
    case .chart where history != nil: return .chart(label: label, series: history ?? [])
    case .ring: return .ring(label: label, level: level)
    default: return .value(label: label, value: WidgetText.percent(level), widest: WidgetText.percents, level: level)
    }
}

// MARK: Colour

/// One colour in two tunings: lighter for a dark menu bar, deeper for a
/// light one, so it reads on both.
public struct WidgetSwatch: Equatable, Sendable {
    public let dark: [UInt8]
    public let light: [UInt8]
    public func on(dark isDark: Bool) -> [UInt8] { isDark ? dark : light }

    // The load ramp.
    static let green = WidgetSwatch(dark: [60, 214, 120], light: [20, 150, 72])
    static let amber = WidgetSwatch(dark: [255, 202, 40], light: [190, 128, 0])
    static let red = WidgetSwatch(dark: [255, 84, 72], light: [214, 38, 38])
    // Accents, one per metric.
    static let teal = WidgetSwatch(dark: [80, 212, 230], light: [0, 130, 152])
    static let violet = WidgetSwatch(dark: [176, 148, 255], light: [118, 78, 214])
    static let honey = WidgetSwatch(dark: [255, 184, 80], light: [180, 104, 0])
    static let mint = WidgetSwatch(dark: [110, 222, 176], light: [0, 134, 96])
    static let indigo = WidgetSwatch(dark: [140, 152, 255], light: [78, 86, 212])
    static let yellow = WidgetSwatch(dark: [236, 214, 90], light: [148, 118, 0])
    /// Download and upload.
    static let blue = WidgetSwatch(dark: [100, 172, 255], light: [10, 104, 214])
    static let pink = WidgetSwatch(dark: [255, 122, 172], light: [198, 40, 110])
}

/// Where a metric goes from calm to hot, in its own units; `calm > hot`
/// where less is worse (a battery). `floor` is the least heat it shows.
public struct WidgetScale: Equatable, Sendable {
    public var calm: Double
    public var hot: Double
    public var floor: Double = 0

    /// 0 calm … 1 hot.
    public func heat(_ value: Double) -> Double {
        let h = (value - calm) / (hot - calm)
        // A NaN from bad input becomes the floor.
        return h.isNaN ? floor : max(min(max(h, 0), 1), floor)
    }

    public static let usage = WidgetScale(calm: 0.3, hot: 0.9)
    /// macOS keeps memory busy on purpose; pressure raises the floor.
    public static let memory = WidgetScale(calm: 0.6, hot: 0.95)
    public static let disk = WidgetScale(calm: 0.75, hot: 0.95)
    /// °C at the CPU.
    public static let temperature = WidgetScale(calm: 55, hot: 100)
    /// Red at 20% and below.
    public static let battery = WidgetScale(calm: 0.5, hot: 0.2)
}

/// Green at 0, amber at ½, red at 1; orange between amber and red.
public func widgetRamp(_ heat: Double, dark: Bool) -> [UInt8] {
    func lerp(_ a: [UInt8], _ b: [UInt8], _ t: Double) -> [UInt8] {
        zip(a, b).map { x, y in UInt8((Double(x) + (Double(y) - Double(x)) * t).rounded()) }
    }
    let t = min(max(heat, 0), 1) * 2
    return t <= 1
        ? lerp(WidgetSwatch.green.on(dark: dark), WidgetSwatch.amber.on(dark: dark), t)
        : lerp(WidgetSwatch.amber.on(dark: dark), WidgetSwatch.red.on(dark: dark), t - 1)
}

/// How a widget colours its data; labels, tracks and baselines stay ink.
public enum WidgetTone: Equatable, Sendable {
    case ink
    case solid(WidgetSwatch)
    case scale(WidgetScale)

    /// The colour for `value`; nil is the ink.
    func color(_ value: Double, dark: Bool) -> [UInt8]? {
        switch self {
        case .ink: nil
        case .solid(let s): s.on(dark: dark)
        case .scale(let s): widgetRamp(s.heat(value), dark: dark)
        }
    }
}

public func widgetTone(_ metric: WidgetMetric, _ mode: WidgetColor, _ r: WidgetReadings) -> WidgetTone {
    let level: WidgetScale? = switch metric {
    case .cpu, .gpu, .fans: .usage
    case .memory: WidgetScale(calm: WidgetScale.memory.calm, hot: WidgetScale.memory.hot, floor: r.memoryPressure)
    case .disk: .disk
    case .temperature: .temperature
    case .battery: .battery
    case .network, .power: nil
    }
    let accent: WidgetSwatch? = switch metric {
    case .cpu: .teal
    case .gpu: .violet
    case .memory: .honey
    case .disk: .mint
    case .fans: .indigo
    case .power: .yellow
    // Rates have no level: download and upload keep their pair.
    case .network: .blue
    case .battery, .temperature: nil
    }
    if mode == .mono { return .ink }
    if metric == .battery, r.battery?.charging == true { return .solid(.green) }
    // A battery's and a temperature's colour is their state in any preset.
    if metric == .battery || metric == .temperature { return .scale(level ?? .usage) }
    if mode == .load {
        if let level { return .scale(level) }
        if metric == .network, let accent { return .solid(accent) }
        return .ink
    }
    return accent.map { .solid($0) } ?? .ink
}
