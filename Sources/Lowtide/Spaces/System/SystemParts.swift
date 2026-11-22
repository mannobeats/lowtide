import LowtideKit
import SwiftUI
import UniformTypeIdentifiers

/// Two children side by side once the width allows, else stacked. The
/// first takes `ratio` of the width (or the second a fixed `trailing`).
struct SplitLayout: Layout {
    let threshold: CGFloat
    let ratio: CGFloat
    let trailing: CGFloat?
    let spacing: CGFloat

    @MainActor init(threshold: CGFloat, ratio: CGFloat = 0.5, trailing: CGFloat? = nil, spacing: CGFloat = Space.md) {
        self.threshold = threshold
        self.ratio = ratio
        self.trailing = trailing
        self.spacing = spacing
    }

    private func wide(_ width: CGFloat) -> Bool { width >= threshold }

    private func widths(_ width: CGFloat) -> (CGFloat, CGFloat) {
        let usable = width - spacing
        if let trailing { return (usable - trailing, trailing) }
        return (usable * ratio, usable * (1 - ratio))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 800
        guard subviews.count == 2 else { return .zero }
        if wide(width) {
            let (a, b) = widths(width)
            let h = max(subviews[0].sizeThatFits(.init(width: a, height: nil)).height,
                        subviews[1].sizeThatFits(.init(width: b, height: nil)).height)
            return CGSize(width: width, height: h)
        }
        let h = subviews[0].sizeThatFits(.init(width: width, height: nil)).height
            + subviews[1].sizeThatFits(.init(width: width, height: nil)).height + spacing
        return CGSize(width: width, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        if wide(bounds.width) {
            let (a, b) = widths(bounds.width)
            subviews[0].place(at: bounds.origin, proposal: .init(width: a, height: bounds.height))
            subviews[1].place(at: CGPoint(x: bounds.minX + a + spacing, y: bounds.minY),
                              proposal: .init(width: b, height: bounds.height))
        } else {
            let h0 = subviews[0].sizeThatFits(.init(width: bounds.width, height: nil)).height
            subviews[0].place(at: bounds.origin, proposal: .init(width: bounds.width, height: h0))
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + h0 + spacing),
                              proposal: .init(width: bounds.width, height: nil))
        }
    }
}

/// A coloured dot before a legend label.
struct LegendDot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 8, height: 8) }
}

/// One share of a whole, as segments of a thin rounded bar.
struct StackedBar: View {
    @Environment(\.palette) private var palette
    struct Part: Identifiable {
        let id: String
        let value: Double
        let color: Color
        var help: String?
    }
    let parts: [Part]
    let total: Double
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(parts) { part in
                    Rectangle().fill(part.color)
                        .frame(width: total > 0 ? geo.size.width * min(max(part.value / total, 0), 1) : 0)
                        .help(part.help ?? "")
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .background(palette.fill.color)
        .clipShape(.capsule)
        .animation(Motion.slow, value: parts.map(\.value))
    }
}

/// A label left and its figure right, the figure's place fixed.
struct FactRow: View {
    @Environment(\.palette) private var palette
    let label: String
    let value: String
    var tone: Tone?
    var dot: Color?

    var body: some View {
        HStack(spacing: Space.sm) {
            if let dot { LegendDot(color: dot) }
            Text(label).foregroundStyle(palette.ink2.color).lineLimit(1)
            Spacer(minLength: Space.sm)
            Text(value).monospacedDigit()
                .foregroundStyle((tone?.color(palette) ?? palette.ink).color)
                .contentTransition(.numericText())
        }
        .font(.ui(.xs))
    }
}

/// A section's title and its headline figure on one baseline.
struct PanelHeading: View {
    @Environment(\.palette) private var palette
    let title: String
    let value: String
    var tone: Tone?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.ui(.sm, .semibold)).foregroundStyle(palette.ink.color)
            Spacer(minLength: Space.sm)
            Text(value).font(.title(.xl)).monospacedDigit()
                .foregroundStyle((tone?.color(palette) ?? palette.ink).color)
                .contentTransition(.numericText())
        }
    }
}

extension Tone {
    /// A temperature's tone: Apple silicon sits in the 80s under load and
    /// slows itself past 100 °C, so amber starts at 90.
    static func heat(_ celsius: Double) -> Tone {
        celsius >= 100 ? .bad : celsius >= 90 ? .warn : .neutral
    }

    static func thermal(_ level: ThermalLevel) -> Tone {
        switch level {
        case .nominal: .neutral
        case .fair: .warn
        case .serious, .critical: .bad
        }
    }
}

/// A process's icon: its app's, else the command-line tool icon.
struct ProcessIcon: View {
    let app: String?
    var size: CGFloat = 18

    private static let tool: NSImage = NSWorkspace.shared.icon(for: .unixExecutable)

    var body: some View {
        if let app {
            FileIcon(path: app, size: size)
        } else {
            Image(nsImage: Self.tool).resizable().interpolation(.high)
                .frame(width: size, height: size).accessibilityHidden(true)
        }
    }
}
