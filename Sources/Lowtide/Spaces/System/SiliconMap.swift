import LowtideKit
import SwiftUI

/// The chip as a floorplan: every CPU core a tile that fills with its load
/// and shows its clock, the GPU's cores lit by its activity, unified memory
/// and the Neural Engine along the bottom. Temperatures sit on each block.
struct SiliconMap: View {
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var model = SystemModel.shared
    @State private var pulse = false

    var body: some View {
        if let chip = model.chip, let sample = model.latest {
            VStack(spacing: Space.md) {
                SplitLayout(threshold: 640, ratio: 0.535) {
                    CPUSide(chip: chip, sample: sample)
                    GPUSide(chip: chip, sample: sample)
                }
                SplitLayout(threshold: 640, trailing: 200) {
                    MemoryStrip(chip: chip, sample: sample)
                    NeuralEngineBlock(sample: sample)
                }
            }
            .padding(Space.md)
            .card(radius: Radius.xl)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(chip.name): live load, clocks, temperatures and power")
        } else {
            Text("Reading the chip…")
                .font(.ui(.sm))
                .foregroundStyle(palette.ink3.color)
                .frame(maxWidth: .infinity)
                .aspectRatio(5 / 3, contentMode: .fit)
                .frame(maxHeight: 420)
                .card(radius: Radius.xl)
                .opacity(pulse ? 0.6 : 1)
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.easeInOut(duration: 1).repeatForever()) { pulse = true }
                }
        }
    }
}

/// A block of the floorplan: its name, its temperature, a line of meta.
private struct Block<Content: View>: View {
    @Environment(\.palette) private var palette
    let label: String
    let meta: Text
    var temp: Double?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Text(label).font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color).lineLimit(1)
                Spacer(minLength: 0)
                if let temp, temp > 0 {
                    Text("\(Int(temp.rounded()))°C").font(.ui(.xs)).monospacedDigit()
                        .foregroundStyle((Tone.heat(temp) == .neutral ? palette.ink3 : Tone.heat(temp).color(palette)).color)
                        .contentTransition(.numericText())
                }
            }
            meta.font(.ui(.xs)).monospacedDigit().foregroundStyle(palette.ink3.color).lineLimit(1)
                .padding(.top, 2).padding(.bottom, 10)
            content
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.bg.opacity(0.5).color, in: .rect(cornerRadius: Radius.lg))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg).strokeBorder(palette.line.color))
    }
}

/// One core: its load as a level rising from the floor, its clock below.
private struct CoreTile: View {
    @Environment(\.palette) private var palette
    let core: CoreLoad

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(Text("\(Int(core.usage.rounded()))").font(.title(.lg)).foregroundStyle(palette.ink.color))\(Text("%").font(.ui(.xs)).foregroundStyle(palette.ink3.color))")
                .monospacedDigit()
                .contentTransition(.numericText())
            Spacer(minLength: Space.xs)
            Text(core.mhz > 0 ? SystemFormat.clock(core.mhz) : "Idle")
                .font(.ui(.xxs)).monospacedDigit().foregroundStyle(palette.ink3.color).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, Space.sm)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .background(alignment: .bottom) {
            GeometryReader { geo in
                Rectangle().fill(palette.brand.opacity(0.25).color)
                    .frame(height: geo.size.height * min(max(core.usage / 100, 0), 1))
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .animation(Motion.slow, value: core.usage)
            }
        }
        .background(palette.fill.color)
        .clipShape(.rect(cornerRadius: Radius.md))
        .help("\(Int(core.usage.rounded()))% busy at \(core.mhz > 0 ? SystemFormat.clock(core.mhz) : "idle")")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(core.kind == .efficiency ? "Efficiency" : "Performance") core, \(Int(core.usage.rounded())) percent busy")
    }
}

private struct CPUSide: View {
    let chip: ChipInfo
    let sample: SystemSample

    var body: some View {
        let e = sample.cores.filter { $0.kind == .efficiency }
        let p = sample.cores.filter { $0.kind == .performance }
        let pClusters = sample.clusters.filter { $0.name.hasPrefix("PCPU") }
        let eCluster = sample.clusters.first { $0.name.hasPrefix("ECPU") }
        let groups = max(1, pClusters.count)
        let per = Int((Double(p.count) / Double(groups)).rounded(.up))
        VStack(spacing: Space.md) {
            HStack(alignment: .top, spacing: Space.md) {
                ForEach(0..<groups, id: \.self) { g in
                    let cores = Array(p.dropFirst(g * per).prefix(per))
                    let cluster = pClusters.indices.contains(g) ? pClusters[g] : nil
                    Block(label: groups > 1 ? "Performance \(g + 1)" : "Performance",
                          meta: Text(cluster.map { "\(SystemFormat.clock($0.mhz)) · \(Int($0.active.rounded()))% active" }
                              ?? "\(cores.count) cores"),
                          temp: g == 0 ? sample.cpuTemp : nil) {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                            ForEach(cores.indices, id: \.self) { CoreTile(core: cores[$0]) }
                        }
                    }
                }
            }
            if chip.efficiency > 0 {
                Block(label: "Efficiency",
                      meta: Text(eCluster.map { "\(SystemFormat.clock($0.mhz)) · \(Int($0.active.rounded()))% active" }
                          ?? "\(chip.efficiency) cores")) {
                    HStack(spacing: 6) {
                        ForEach(e.indices, id: \.self) { CoreTile(core: e[$0]) }
                    }
                }
            }
        }
    }
}

/// The GPU is one engine: its cores light together with its load.
private struct GPUSide: View {
    @Environment(\.palette) private var palette
    let chip: ChipInfo
    let sample: SystemSample

    var body: some View {
        let count = max(chip.gpuCores, 8)
        let cols = count >= 32 ? 8 : Int(Double(count).squareRoot().rounded(.up))
        let rows = Int((Double(count) / Double(cols)).rounded(.up))
        let level = 0.08 + 0.42 * min(1, sample.gpu / 100)
        let label = chip.gpuCores > 0 ? "GPU, \(chip.gpuCores) cores" : "GPU"
        Block(label: label,
              meta: Text("\(sample.gpuMHz > 0 ? SystemFormat.clock(sample.gpuMHz) : "Idle") · \(Int(sample.gpu.rounded()))% active · \(SystemFormat.watts(sample.power.gpu))"),
              temp: sample.gpuTemp) {
            VStack(spacing: Space.xs) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: Space.xs) {
                        ForEach(0..<cols, id: \.self) { col in
                            let i = row * cols + col
                            RoundedRectangle(cornerRadius: 3)
                                .fill(palette.brand.color)
                                // A slight, fixed unevenness so the block reads as silicon.
                                .opacity(i < count ? level * (0.86 + 0.14 * Double((i * 37) % 7) / 6) : 0)
                                .frame(minHeight: 16)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .animation(Motion.slow, value: level)
        }
    }
}

private struct MemoryStrip: View {
    @Environment(\.palette) private var palette
    let chip: ChipInfo
    let sample: SystemSample

    private var parts: [(key: String, label: String, value: UInt64, color: Color)] {
        let m = sample.memory
        return [("app", "Apps", m.app, palette.brand.color),
                ("wired", "Wired", m.wired, palette.brand.opacity(0.55).color),
                ("compressed", "Compressed", m.compressed, palette.brand.opacity(0.3).color),
                ("cached", "Cached", m.cached, palette.ink4.color)]
    }

    var body: some View {
        let m = sample.memory
        let total = Double(m.total > 0 ? m.total : max(chip.memory, 1))
        let pressure = m.pressure == .normal
            ? Text("No memory pressure")
            : Text("Memory pressure \(m.pressure.rawValue)").foregroundStyle(palette.warn.color)
        Block(label: "Unified memory",
              meta: Text("\(SystemFormat.memory(m.used)) of \(SystemFormat.memory(UInt64(total))) used · \(SystemFormat.memory(m.swapUsed)) swap · \(pressure)")) {
            VStack(alignment: .leading, spacing: Space.sm) {
                StackedBar(parts: parts.map { .init(id: $0.key, value: Double($0.value), color: $0.color,
                                                    help: "\($0.label): \(SystemFormat.memory($0.value))") },
                           total: total)
                HStack(spacing: Space.lg) {
                    ForEach(parts, id: \.key) { part in
                        HStack(spacing: 6) {
                            LegendDot(color: part.color)
                            Text(part.label).foregroundStyle(palette.ink3.color)
                            Text(SystemFormat.memory(part.value)).foregroundStyle(palette.ink2.color)
                        }
                        .font(.ui(.xxs)).monospacedDigit().lineLimit(1)
                    }
                }
            }
        }
    }
}

private struct NeuralEngineBlock: View {
    @Environment(\.palette) private var palette
    let sample: SystemSample

    var body: some View {
        let active = sample.power.ane > 0.01
        Block(label: "Neural Engine", meta: Text(active ? SystemFormat.watts(sample.power.ane) : "Idle")) {
            Capsule().fill((active ? palette.brand.opacity(0.7) : palette.fill).color)
                .frame(height: 8)
                .animation(Motion.slow, value: active)
        }
    }
}
