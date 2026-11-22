import LowtideKit
import SwiftUI

/// Today's traffic and the busiest apps on the network, from the network
/// space's monitor (it registers `WidgetsLifecycle.networkFacts`). Without
/// it the popover shows the interface rates only.
struct NetworkFacts {
    var todayIn: Double
    var todayOut: Double
    /// Name, download and upload per second, busiest first.
    var top: [(name: String, down: Double, up: Double)]
}

/// The popover under the menu-bar widgets: a section for each kind of
/// widget shown, coloured like its widgets in the strip.
struct StatsPopoverView: View {
    static let width: CGFloat = 320
    /// Samples in each chart: a minute of the monitor.
    static let minute = 60

    @Environment(\.palette) private var palette
    private var model = SystemModel.shared
    private var store = WidgetsStore.shared
    @State private var contentHeight: CGFloat = 0

    enum Section: Hashable { case cpu, gpu, memory, network, disk, battery, sensors }

    private static func section(_ metric: WidgetMetric) -> Section {
        switch metric {
        case .cpu: .cpu
        case .gpu: .gpu
        case .memory: .memory
        case .network: .network
        case .disk: .disk
        case .battery: .battery
        case .fans, .power, .temperature: .sensors
        }
    }

    private var sections: [Section] {
        let ids = store.widgets.map { Self.section($0.metric) }
        var seen = Set<Section>()
        return (ids.isEmpty ? [.cpu, .memory, .network] : ids).filter { seen.insert($0).inserted }
    }

    /// Whether a section takes the strip's colours: like its widgets, or the
    /// strip's preset for a section shown by default.
    private func tinted(_ section: Section) -> Bool {
        let own = store.widgets.filter { Self.section($0.metric) == section }
        let colors = own.isEmpty ? [store.color] : own.map { $0.color ?? store.color }
        return colors.contains { $0 != .mono }
    }

    var body: some View {
        let minute = Array(model.samples.suffix(Self.minute))
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(sections.enumerated()), id: \.element) { i, section in
                        if i > 0 { Hairline() }
                        view(section, minute)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(contentHeight, 1), 640))
            footer
        }
        .frame(width: Self.width)
        .background {
            ZStack {
                VisualEffectBackground(material: .popover)
                palette.overlay.opacity(0.8).color
            }
        }
        .clipShape(.rect(cornerRadius: Radius.xl))
        .overlay(RoundedRectangle(cornerRadius: Radius.xl).strokeBorder(palette.lineStrong.color))
        .foregroundStyle(palette.ink2.color)
    }

    private var header: some View {
        HStack {
            Text(model.chip?.name ?? "This Mac").font(.ui(.sm, .semibold)).foregroundStyle(palette.ink.color).lineLimit(1)
            Spacer()
            if let chip = model.chip {
                Text("\(chip.performance)P + \(chip.efficiency)E · \(SystemFormat.memory(chip.memory))")
                    .font(.ui(.xs)).monospacedDigit().foregroundStyle(palette.ink3.color)
            }
        }
        .padding(.horizontal, Space.lg)
        .frame(height: 40)
        .hairline()
    }

    private var footer: some View {
        HStack {
            Button("Open Lowtide") {
                StatsPopover.shared.hide()
                AppModel.shared.show(.systemOverview)
            }
            .buttonStyle(.lowtide(.quiet, size: .small))
            Spacer()
            Button {
                StatsPopover.shared.hide()
                AppModel.shared.show(.widgets)
            } label: {
                NavIcon("settings", size: 16).frame(width: 26, height: 26).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.ink3.color)
            .help("Widget settings")
            .accessibilityLabel("Widget settings")
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, 6)
        .hairline(.top)
    }

    @ViewBuilder private func view(_ section: Section, _ minute: [SystemSample]) -> some View {
        switch section {
        case .cpu: CPUSection(samples: minute, tinted: tinted(.cpu))
        case .gpu: GPUSection(samples: minute, tinted: tinted(.gpu))
        case .memory: MemorySection(samples: minute, tinted: tinted(.memory))
        case .network: NetworkSection(samples: model.samples.suffix(20).map(\.network))
        case .disk: DiskSection(disk: model.latest?.disk, tinted: tinted(.disk))
        case .battery: if let battery = model.detail?.battery { BatterySection(battery: battery, tinted: tinted(.battery)) }
        case .sensors: SensorsSection(sample: model.latest, fans: model.detail?.fans ?? [])
        }
    }
}

// MARK: Pieces

private struct PopoverSection<Value: View, Content: View>: View {
    @Environment(\.palette) private var palette
    let title: String
    @ViewBuilder var value: Value
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.ui(.xs, .semibold)).foregroundStyle(palette.ink2.color)
                Spacer(minLength: Space.md)
                value.font(.ui(.base, .semibold)).monospacedDigit().foregroundStyle(palette.ink.color)
            }
            content
        }
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.md)
        .padding(.bottom, 14)
    }
}

/// Label left, figure right; the figure's slot never moves.
private struct Fact<Label: View>: View {
    @Environment(\.palette) private var palette
    @ViewBuilder var label: Label
    let value: String
    var tone: Tone?

    var body: some View {
        HStack(spacing: Space.md) {
            HStack(spacing: 6) { label }.foregroundStyle(palette.ink3.color).lineLimit(1)
            Spacer(minLength: 0)
            Text(value).monospacedDigit().foregroundStyle((tone?.color(palette) ?? palette.ink2).color)
        }
        .font(.ui(.xs))
        .frame(height: 20)
    }
}

extension Fact where Label == Text {
    init(_ label: String, _ value: String, tone: Tone? = nil) {
        self.label = Text(label)
        self.value = value
        self.tone = tone
    }
}

/// The Load ramp in the theme's state colours: ok, warn at ½, bad at 1.
private func heatColor(_ heat: Double, _ p: Palette) -> Color {
    let h = min(max(heat, 0), 1)
    return (h <= 0.5 ? p.warn.mixed(with: p.ok, h * 2) : p.bad.mixed(with: p.warn, (h - 0.5) * 2)).color
}

/// A minute as an area, newest at the right; `second` drawn as a line.
/// With a `scale` (calm and hot as shares of `max`) it takes the strip's
/// Load colours by height.
private struct MinuteSpark: View {
    @Environment(\.palette) private var palette
    let values: [Double]
    let max: Double
    var scale: WidgetScale?
    var second: [Double]?

    var body: some View {
        Canvas { context, size in
            let top = Swift.max(max, 0.000_001)
            let step = size.width / CGFloat(StatsPopoverView.minute - 1)
            func path(_ series: [Double]) -> Path {
                var line = Path()
                let start = size.width - step * CGFloat(series.count - 1)
                for (i, v) in series.enumerated() {
                    let p = CGPoint(x: start + CGFloat(i) * step,
                                    y: size.height - CGFloat(Swift.min(v, top) / top) * (size.height - 2) - 1)
                    i == 0 ? line.move(to: p) : line.addLine(to: p)
                }
                return line
            }
            var base = Path()
            base.move(to: CGPoint(x: 0, y: size.height - 0.5))
            base.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            context.stroke(base, with: .color(palette.lineStrong.color), lineWidth: 1)
            guard values.count > 1 else { return }
            let line = path(values)
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: size.width - step * CGFloat(values.count - 1), y: size.height))
            area.closeSubpath()
            let shading: GraphicsContext.Shading
            if let scale {
                // The gradient runs bottom to top: calm, the middle, hot.
                let stops = [Gradient.Stop(color: palette.ok.color, location: scale.calm),
                             Gradient.Stop(color: palette.warn.color, location: (scale.calm + scale.hot) / 2),
                             Gradient.Stop(color: palette.bad.color, location: scale.hot)]
                shading = .linearGradient(Gradient(stops: stops), startPoint: CGPoint(x: 0, y: size.height),
                                          endPoint: CGPoint(x: 0, y: 1))
            } else {
                shading = .color(palette.brand.color)
            }
            context.drawLayer { layer in
                layer.opacity = scale == nil ? 0.14 : 0.2
                layer.fill(area, with: shading)
            }
            context.stroke(line, with: shading, style: StrokeStyle(lineWidth: 1.25, lineJoin: .round))
            if let second, second.count > 1 {
                context.stroke(path(second), with: .color(palette.ink3.color), style: StrokeStyle(lineWidth: 1, lineJoin: .round))
            }
        }
        .frame(height: 36)
        .accessibilityHidden(true)
    }
}

/// A share of something, as a thin track.
private struct ShareBar: View {
    @Environment(\.palette) private var palette
    let share: Double
    var color: Color?

    var body: some View {
        GeometryReader { geo in
            Capsule().fill(palette.fill.color)
                .overlay(alignment: .leading) {
                    Capsule().fill(color ?? palette.ink2.color).frame(width: geo.size.width * min(max(share, 0), 1))
                }
        }
        .frame(height: 4)
        .animation(Motion.base, value: share)
    }
}

/// Three rows' room whether or not they are filled, so nothing below jumps.
private struct Rows<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 2) { content }.frame(minHeight: 64, alignment: .top)
    }
}

private func pct(_ v: Double) -> String { "\(Int(v.rounded()))%" }

// MARK: Sections

private struct CPUSection: View {
    @Environment(\.palette) private var palette
    var model = SystemModel.shared
    let samples: [SystemSample]
    let tinted: Bool

    var body: some View {
        let s = samples.last
        PopoverSection(title: "CPU") { Text(s.map { pct($0.cpu) } ?? "–") } content: {
            MinuteSpark(values: samples.map(\.cpu), max: 100, scale: tinted ? .usage : nil)
            HStack(alignment: .bottom, spacing: Space.xs) {
                ForEach(Array((s?.cores ?? []).enumerated()), id: \.offset) { i, core in
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 3).fill(palette.fill.color)
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(tinted ? heatColor(WidgetScale.usage.heat(core.usage / 100), palette)
                                          : (core.kind == .efficiency ? palette.ink3 : palette.ink2).color)
                                    .frame(height: geo.size.height * min(core.usage, 100) / 100)
                            }
                            .clipShape(.rect(cornerRadius: 3))
                    }
                    .help("\(core.kind == .efficiency ? "Efficiency" : "Performance") core \(i + 1): \(pct(core.usage))")
                }
            }
            .frame(height: 28)
            .animation(Motion.base, value: s?.cores.map(\.usage))
            VStack(spacing: 2) {
                ForEach(Array(clusters(s).prefix(3)), id: \.1.name) { label, c in
                    Fact(label, "\(pct(c.active)) · \(SystemFormat.clock(c.mhz))")
                }
            }
            Rows {
                ForEach(model.topProcesses(3)) { p in
                    Fact(label: {
                        ProcessIcon(app: p.app, size: 14)
                        Text(p.name).foregroundStyle(palette.ink2.color)
                    }, value: String(format: "%.1f%%", p.cpu))
                }
            }
        }
    }
}

/// "Efficiency", then "Performance" or "Performance 1", "Performance 2"
/// in the order the chip lists them (`PCPU`, `PCPU1`…).
private func clusters(_ sample: SystemSample?) -> [(String, ClusterLoad)] {
    let all = sample?.clusters ?? []
    let performance = all.filter { !$0.name.hasPrefix("E") }
    return all.map { c in
        if c.name.hasPrefix("E") { return ("Efficiency", c) }
        let n = (performance.firstIndex(of: c) ?? 0) + 1
        return (performance.count > 1 ? "Performance \(n)" : "Performance", c)
    }
}

private struct GPUSection: View {
    let samples: [SystemSample]
    let tinted: Bool

    var body: some View {
        let s = samples.last
        PopoverSection(title: "GPU") { Text(s.map { pct($0.gpu) } ?? "–") } content: {
            MinuteSpark(values: samples.map(\.gpu), max: 100, scale: tinted ? .usage : nil)
            VStack(spacing: 2) {
                Fact("Clock", s.map { SystemFormat.clock($0.gpuMHz) } ?? "–")
                Fact("Power", s.map { SystemFormat.watts($0.power.gpu) } ?? "–")
                Fact("Temperature", s.map { SystemFormat.celsius($0.gpuTemp) } ?? "–")
            }
        }
    }
}

private struct MemorySection: View {
    let samples: [SystemSample]
    let tinted: Bool

    var body: some View {
        let m = samples.last?.memory
        PopoverSection(title: "Memory") {
            Text(m.map { "\(SystemFormat.memory($0.used)) of \(SystemFormat.memory($0.total))" } ?? "–")
        } content: {
            MinuteSpark(values: samples.map(\.memory.usedShare), max: 1, scale: tinted ? .memory : nil)
            VStack(spacing: 2) {
                Fact("Pressure", m.map { $0.pressure.rawValue.prefix(1).uppercased() + $0.pressure.rawValue.dropFirst() } ?? "–",
                     tone: m.map { $0.pressure == .critical ? .bad : $0.pressure == .warning ? .warn : nil } ?? nil)
                Fact("Apps", m.map { SystemFormat.memory($0.app) } ?? "–")
                Fact("Wired", m.map { SystemFormat.memory($0.wired) } ?? "–")
                Fact("Compressed", m.map { SystemFormat.memory($0.compressed) } ?? "–")
                Fact("Swap", m.flatMap { $0.swapTotal > 0 ? "\(SystemFormat.memory($0.swapUsed)) of \(SystemFormat.memory($0.swapTotal))" : nil } ?? "None")
            }
        }
    }
}

private struct NetworkSection: View {
    @Environment(\.palette) private var palette
    let samples: [NetworkRate]

    var body: some View {
        let now = samples.last ?? NetworkRate()
        let facts = WidgetsLifecycle.networkFacts?()
        let peak = max(10_000, samples.map { max($0.bytesIn, $0.bytesOut) }.max() ?? 0)
        PopoverSection(title: "Network") {
            HStack(spacing: Space.md) {
                HStack(spacing: Space.xs) {
                    Image(systemName: "arrow.down").foregroundStyle(palette.brand.color)
                    Text(SystemFormat.rate(now.bytesIn))
                }
                HStack(spacing: Space.xs) {
                    Image(systemName: "arrow.up").foregroundStyle(palette.ink3.color)
                    Text(SystemFormat.rate(now.bytesOut)).foregroundStyle(palette.ink2.color)
                }
            }
            .font(.ui(.sm, .semibold))
        } content: {
            MinuteSpark(values: samples.map(\.bytesIn), max: peak, second: samples.map(\.bytesOut))
            if let facts {
                Fact("Today", "↓ \(SystemFormat.amount(facts.todayIn))  ↑ \(SystemFormat.amount(facts.todayOut))")
                Rows {
                    ForEach(facts.top.prefix(3), id: \.name) { row in
                        Fact(label: { Text(row.name).foregroundStyle(palette.ink2.color) },
                             value: "↓ \(SystemFormat.rate(row.down))  ↑ \(SystemFormat.rate(row.up))")
                    }
                }
            } else if let interface = now.interface {
                Fact("Busiest interface", interface)
            }
        }
    }
}

private struct DiskSection: View {
    @Environment(\.palette) private var palette
    let disk: DiskSpace?
    let tinted: Bool

    var body: some View {
        let used = disk?.usedShare ?? 0
        PopoverSection(title: "Disk") { Text(disk.map { _ in pct(used * 100) } ?? "–") } content: {
            ShareBar(share: used, color: tinted ? heatColor(WidgetScale.disk.heat(used), palette)
                     : used > 0.9 ? palette.warn.color : nil)
            Fact("Free", disk.map { "\(SystemFormat.amount(Double($0.available))) of \(SystemFormat.amount(Double($0.total)))" } ?? "–")
        }
    }
}

private struct BatterySection: View {
    @Environment(\.palette) private var palette
    let battery: BatteryState
    let tinted: Bool

    var body: some View {
        let state = battery.charging ? "Charging" : battery.plugged ? "Plugged in" : "On battery"
        let charge = battery.charging ? palette.ok.color : heatColor(WidgetScale.battery.heat(battery.percent / 100), palette)
        PopoverSection(title: "Battery") {
            HStack(spacing: Space.xs) {
                if battery.charging { Image(systemName: "bolt.fill").font(.ui(.xs)).foregroundStyle(palette.ok.color) }
                Text(pct(battery.percent))
            }
        } content: {
            ShareBar(share: battery.percent / 100, color: tinted ? charge : battery.percent < 15 ? palette.bad.color : nil)
            VStack(spacing: 2) {
                // Plugged in and not charging, the estimate means nothing.
                Fact(state, battery.minutes.map(SystemFormat.minutes) ?? "–")
                Fact("Health", battery.health > 0 ? pct(battery.health) : "–")
                Fact("Cycles", battery.cycles.formatted())
            }
        }
    }
}

private struct SensorsSection: View {
    let sample: SystemSample?
    let fans: [Fan]

    var body: some View {
        let thermal = sample?.thermal ?? .nominal
        PopoverSection(title: "Sensors") { Text(sample.map { SystemFormat.celsius($0.cpuTemp) } ?? "–") } content: {
            VStack(spacing: 2) {
                Fact("Thermal state", thermal.title, tone: thermal == .nominal ? nil : Tone.thermal(thermal))
                Fact("GPU", sample.map { SystemFormat.celsius($0.gpuTemp) } ?? "–")
                Fact("Power", sample.flatMap { $0.power.system > 0 ? SystemFormat.watts($0.power.system) : nil } ?? "–")
                ForEach(fans.indices, id: \.self) { i in
                    Fact(fans.count > 1 ? "Fan \(i + 1)" : "Fan", "\(Int(fans[i].rpm.rounded())) rpm")
                }
            }
        }
    }
}
