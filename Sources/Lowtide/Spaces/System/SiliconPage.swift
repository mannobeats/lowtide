import LowtideKit
import SwiftUI

/// System → Silicon: how the Mac is doing, the chip as a live floorplan,
/// where the watts and the memory bandwidth go, heat, and ten minutes of
/// history.
struct SiliconPage: View {
    @Environment(\.palette) private var palette
    var model = SystemModel.shared

    var body: some View {
        PageScaffold {
            PageHero(title, detail: detail, art: "system") {
                Button("Show processes") { AppModel.shared.open(.processes) }.buttonStyle(.primary)
            }
        } content: {
            SiliconMap()
            if let sample = model.latest {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: Space.xl, alignment: .top)],
                          alignment: .leading, spacing: Space.xl) {
                    PowerPanel(sample: sample).card(padding: Space.lg)
                    BandwidthPanel(sample: sample, chip: model.chip).card(padding: Space.lg)
                    ThermalPanel(sample: sample, fans: model.detail?.fans ?? []).card(padding: Space.lg)
                }
            }
            Timelines(samples: model.samples)
        }
        .systemFeed("page.silicon")
    }

    private var title: String {
        guard let sample = model.latest else { return model.chip?.name ?? "This Mac" }
        let mood = SystemFormat.mood(thermal: sample.thermal, cpuTemp: sample.cpuTemp)
        return "\(mood) · \(Int(sample.power.total.rounded())) W"
    }

    private var detail: String {
        guard let chip = model.chip else { return "Reading the chip…" }
        var parts = ["\(chip.name) · \(chip.cores)-core CPU (\(chip.performance) performance, \(chip.efficiency) efficiency)"]
        if chip.gpuCores > 0 { parts.append("\(chip.gpuCores)-core GPU") }
        parts.append("\(SystemFormat.memory(chip.memory)) unified memory")
        return parts.joined(separator: ", ")
    }
}

/// Where the watts go, one row per block, and the whole Mac on top.
private struct PowerPanel: View {
    @Environment(\.palette) private var palette
    let sample: SystemSample

    var body: some View {
        let p = sample.power
        let blocks: [(String, Double, Color)] = [
            ("CPU", p.cpu, palette.brand.color), ("GPU", p.gpu, palette.brand.opacity(0.6).color),
            ("Neural Engine", p.ane, palette.brand.opacity(0.35).color), ("Memory", p.dram, palette.ink3.color),
        ]
        let rest = max(0, p.total - p.chip)
        VStack(alignment: .leading, spacing: Space.md) {
            PanelHeading(title: "Power", value: SystemFormat.watts(p.total))
            StackedBar(parts: blocks.map { .init(id: $0.0, value: $0.1, color: $0.2) }
                + [.init(id: "rest", value: rest, color: palette.ink4.color)], total: p.total)
            VStack(spacing: 6) {
                ForEach(blocks, id: \.0) { block in
                    if unreported.contains(block.0) {
                        FactRow(label: block.0, value: "Not reported", tone: .neutral, dot: block.2)
                            .help("This version of macOS doesn't report this block's energy; it's counted in the rest.")
                    } else {
                        FactRow(label: block.0, value: SystemFormat.watts(block.1), dot: block.2)
                    }
                }
                if p.system > 0 {
                    FactRow(label: restLabel, value: SystemFormat.watts(rest), dot: palette.ink4.color)
                }
            }
        }
    }

    private var unreported: [String] {
        (sample.power.cpuReported ? [] : ["CPU"]) + (sample.power.dramReported ? [] : ["Memory"])
    }

    /// What the SMC's whole-Mac figure covers beyond the measured blocks.
    private var restLabel: String {
        switch unreported.count {
        case 0: "Display, SSD and the rest"
        case 1: "\(unreported[0]) and the rest"
        default: "\(unreported[0]), \(unreported[1].lowercased()) and the rest"
        }
    }
}

/// Memory bandwidth: how much, against the chip's peak, and who moves it.
private struct BandwidthPanel: View {
    @Environment(\.palette) private var palette
    let sample: SystemSample
    let chip: ChipInfo?

    private static let mainClients = ["CPU", "GPU", "Display"]

    /// The same four rows every second, so nothing below jumps.
    private var rows: [(String, Double)] {
        let traffic = sample.memTraffic
        let main = Self.mainClients.map { client in (client, traffic.first { $0.client == client }?.bytes ?? 0) }
        let other = traffic.filter { !Self.mainClients.contains($0.client) }.reduce(0) { $0 + $1.bytes }
        return main + [("Other", other)]
    }

    var body: some View {
        let total = sample.memoryBandwidth
        let peak = chip.flatMap { SystemFormat.peakBandwidth($0.name) }
        let top = max(1, rows.map(\.1).max() ?? 1)
        VStack(alignment: .leading, spacing: Space.md) {
            PanelHeading(title: "Memory bandwidth", value: SystemFormat.bandwidth(total))
            if let peak {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Meter(value: total / 1e9 / peak, height: 8)
                    // Two lines, so a narrow column never breaks inside "GB/s".
                    Group {
                        Text("\(Int((total / 1e9 / peak * 100).rounded()))% of the chip's \(Int(peak)) GB/s peak")
                        Text("\(SystemFormat.bandwidth(sample.memWrite)) of it writes")
                    }
                    .font(.ui(.xs)).monospacedDigit().foregroundStyle(palette.ink3.color).lineLimit(1)
                }
            }
            VStack(spacing: 6) {
                ForEach(rows, id: \.0) { client, bytes in
                    HStack(spacing: Space.sm) {
                        Text(client).foregroundStyle(palette.ink2.color).frame(width: 88, alignment: .leading)
                        Meter(value: bytes / top, tone: .brand)
                            .opacity(0.75)
                        Text(bytes >= 1e7 ? SystemFormat.bandwidth(bytes) : "–")
                            .foregroundStyle(palette.ink.color).monospacedDigit()
                            .frame(width: 72, alignment: .trailing)
                    }
                    .font(.ui(.xs)).lineLimit(1)
                }
            }
        }
    }
}

private struct ThermalPanel: View {
    @Environment(\.palette) private var palette
    let sample: SystemSample
    let fans: [Fan]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            PanelHeading(title: "Thermals", value: sample.thermal.title,
                         tone: sample.thermal == .nominal ? nil : Tone.thermal(sample.thermal))
            Text(sample.thermal == .nominal ? "No slowing down for heat." : "macOS is slowing the chip to keep it cool.")
                .font(.ui(.xs)).foregroundStyle(palette.ink3.color)
            VStack(spacing: 6) {
                FactRow(label: "CPU", value: SystemFormat.celsius(sample.cpuTemp))
                FactRow(label: "GPU", value: SystemFormat.celsius(sample.gpuTemp))
                ForEach(fans.indices, id: \.self) { i in
                    FactRow(label: fans.count > 1 ? "Fan \(i + 1)" : "Fan", value: "\(Int(fans[i].rpm.rounded())) rpm")
                }
            }
        }
    }
}

/// Ten minutes of each measure, its current value above it.
private struct Timelines: View {
    @Environment(\.palette) private var palette
    let samples: [SystemSample]

    var body: some View {
        let total = Double(samples.last?.memory.total ?? 0) / 1_073_741_824
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Last 10 minutes").font(.ui(.sm, .semibold)).foregroundStyle(palette.ink.color)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: Space.xxl, alignment: .top)],
                      alignment: .leading, spacing: Space.xl) {
                Timeline(label: "CPU", values: samples.map(\.cpu), max: 100) { "\(Int($0.rounded()))%" }
                Timeline(label: "GPU", values: samples.map(\.gpu), max: 100) { "\(Int($0.rounded()))%" }
                Timeline(label: "Power", values: samples.map(\.power.total)) { SystemFormat.watts($0) }
                Timeline(label: "CPU temperature", values: samples.map(\.cpuTemp), max: 110) { "\(Int($0.rounded()))°C" }
                Timeline(label: "Memory used", values: samples.map { Double($0.memory.used) / 1_073_741_824 },
                         max: total > 0 ? total : nil) { String(format: "%.1f GB", $0) }
                Timeline(label: "Memory bandwidth", values: samples.map { $0.memoryBandwidth / 1e9 }) { String(format: "%.1f GB/s", $0) }
                Timeline(label: "Disk", values: samples.map { $0.diskRead + $0.diskWrite }) { SystemFormat.rate($0) }
            }
        }
    }
}

private struct Timeline: View {
    @Environment(\.palette) private var palette
    let label: String
    let values: [Double]
    var max: Double?
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).foregroundStyle(palette.ink3.color).lineLimit(1)
                Spacer(minLength: Space.sm)
                Text(values.last.map(format) ?? "–").foregroundStyle(palette.ink.color).monospacedDigit()
            }
            .font(.ui(.xs))
            Sparkline(values: values, maxValue: max ?? Swift.max(1, values.max() ?? 1) * 1.15)
                .frame(height: 48)
                .overlay(alignment: .bottom) { Hairline() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(values.last.map(format) ?? "no reading yet")")
    }
}
