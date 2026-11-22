import SwiftUI

/// A line of recent values, filled underneath. Drawn with Canvas: cheap
/// enough to redraw every second for dozens of rows.
struct Sparkline: View {
    @Environment(\.palette) private var palette
    let values: [Double]
    var tone: Tone = .brand
    var maxValue: Double?

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let top = max(maxValue ?? (values.max() ?? 1), 0.000_001)
            let step = size.width / CGFloat(values.count - 1)
            var line = Path()
            for (i, v) in values.enumerated() {
                let p = CGPoint(x: CGFloat(i) * step, y: size.height - CGFloat(min(v / top, 1)) * (size.height - 1) - 0.5)
                i == 0 ? line.move(to: p) : line.addLine(to: p)
            }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            let color = tone.color(palette)
            context.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.28).color, color.opacity(0).color]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(color.color), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

/// A horizontal fill: usage, progress, share.
struct Meter: View {
    @Environment(\.palette) private var palette
    let value: Double
    var tone: Tone = .brand
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.fill.color)
                Capsule().fill(tone.color(palette).color)
                    .frame(width: max(height, geo.size.width * min(max(value, 0), 1)))
                    .opacity(value <= 0 ? 0 : 1)
            }
        }
        .frame(height: height)
        .animation(Motion.base, value: value)
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
    }
}

/// A ring gauge for a single share (CPU, memory, disk).
struct Gauge: View {
    @Environment(\.palette) private var palette
    let value: Double
    var tone: Tone = .brand
    var lineWidth: CGFloat = 6

    var body: some View {
        ZStack {
            Circle().stroke(palette.fill.color, lineWidth: lineWidth)
            Circle().trim(from: 0, to: min(max(value, 0), 1))
                .stroke(tone.color(palette).color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(Motion.base, value: value)
    }
}
