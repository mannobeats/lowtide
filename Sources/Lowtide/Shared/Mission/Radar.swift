import LowtideKit
import SwiftUI

/// One radar for the whole app: every scope draws the same field from
/// these numbers, in a 600-unit square.
enum RadarSpec {
    static let view: Double = 600
    static let c: Double = view / 2
    static let rim: Double = 264
    /// Range rings at a quarter, half and three quarters of the rim.
    static let rings: [Double] = [rim / 4, rim / 2, rim * 3 / 4]
    static let ringDash: [CGFloat] = [2, 5]
    /// Bearing ticks every 30°, as a share of the rim.
    static let majorStep = 30
    static let majorTick = 0.035
    /// One turn of the sweep, in seconds.
    static let sweepSeconds = 7.0
    /// Degrees from the sweep's faint tail to its bright leading edge.
    static let edge = 60.0
    static let sweepTail = 0.16 * 0.6
    static let sweepEdge = 0.55 * 0.6

    /// The point at `radius` on a compass bearing (0 = north, clockwise).
    static func onBearing(_ radius: Double, _ bearing: Double) -> CGPoint {
        let rad = (bearing - 90) * .pi / 180
        return CGPoint(x: c + radius * cos(rad), y: c + radius * sin(rad))
    }

    /// The bearing the sweep's bright edge is on at `time`.
    static func edgeBearing(at time: TimeInterval) -> Double {
        (time / sweepSeconds * 360 + edge).truncatingRemainder(dividingBy: 360)
    }

    /// How bright a blip on `bearing` flashes as the edge passes (0–1).
    static func flash(_ bearing: Double, at time: TimeInterval) -> Double {
        let behind = (edgeBearing(at: time) - bearing + 720).truncatingRemainder(dividingBy: 360)
        return behind < 50 ? 1 - behind / 50 : 0
    }
}

/// The radar every scope shares: a slow sweep, a centre glow, the rim,
/// range rings, crosshair and bearing ticks, with whatever sits on it
/// (`marks`) drawn in the same 600-unit square, a centre view, and a
/// readout under it. Square; fills its width.
struct RadarFrame<Centre: View>: View {
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let readout: String
    var marks: ((inout GraphicsContext, Double, TimeInterval) -> Void)?
    @ViewBuilder var centre: Centre

    init(title: String, readout: String, marks: ((inout GraphicsContext, Double, TimeInterval) -> Void)? = nil,
         @ViewBuilder centre: () -> Centre = { EmptyView() }) {
        self.title = title
        self.readout = readout
        self.marks = marks
        self.centre = centre()
    }

    var body: some View {
        VStack(spacing: Space.md) {
            // Three layers so a frame costs little: the field drawn once, the
            // sweep a fixed gradient the GPU only rotates, and the marks (which
            // flare as the sweep passes) redrawn each frame through Metal.
            ZStack {
                Canvas { context, size in
                    let scale = min(size.width, size.height) / RadarSpec.view
                    context.scaleBy(x: scale, y: scale)
                    drawField(&context, scale: scale)
                }
                if !reduceMotion && WindowVisibility.shared.mainVisible { RadarSweep(brand: palette.brand) }
                if let marks {
                    // Blips flare as the sweep passes: five updates a second
                    // read as a fade, and each one costs a whole-window layout pass.
                    TimelineView(.periodic(from: .now, by: reduceMotion || !WindowVisibility.shared.mainVisible ? 3600 : 1 / 5)) { timeline in
                        Canvas { context, size in
                            let scale = min(size.width, size.height) / RadarSpec.view
                            context.scaleBy(x: scale, y: scale)
                            marks(&context, scale, timeline.date.timeIntervalSinceReferenceDate)
                        }
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .overlay { centre.allowsHitTesting(false) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(readout)
            Text(readout)
                .font(.ui(.xs))
                .foregroundStyle(palette.ink3.color)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)
                .contentTransition(.opacity)
                .animation(Motion.fast, value: readout)
        }
    }

    /// Lines stay 1 px whatever the size.
    private func drawField(_ context: inout GraphicsContext, scale: Double) {
        let c = CGPoint(x: RadarSpec.c, y: RadarSpec.c)
        let hair = 1 / scale
        let rim = Path(ellipseIn: CGRect(x: c.x - RadarSpec.rim, y: c.y - RadarSpec.rim, width: RadarSpec.rim * 2, height: RadarSpec.rim * 2))
        let glow = RadarSpec.view * 0.12
        context.fill(Path(ellipseIn: CGRect(x: c.x - glow, y: c.y - glow, width: glow * 2, height: glow * 2)),
                     with: .radialGradient(Gradient(colors: [palette.brand.opacity(0.07).color, palette.brand.opacity(0).color]),
                                           center: c, startRadius: 0, endRadius: glow))
        for r in RadarSpec.rings {
            context.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(palette.line.color),
                           style: StrokeStyle(lineWidth: hair, dash: RadarSpec.ringDash.map { $0 / scale }))
        }
        context.stroke(rim, with: .color(palette.lineStrong.color), lineWidth: hair)
        var cross = Path()
        cross.move(to: CGPoint(x: c.x, y: c.y - RadarSpec.rim))
        cross.addLine(to: CGPoint(x: c.x, y: c.y + RadarSpec.rim))
        cross.move(to: CGPoint(x: c.x - RadarSpec.rim, y: c.y))
        cross.addLine(to: CGPoint(x: c.x + RadarSpec.rim, y: c.y))
        context.stroke(cross, with: .color(palette.line.color), lineWidth: hair)
        var ticks = Path()
        for bearing in stride(from: 0, to: 360, by: RadarSpec.majorStep) {
            ticks.move(to: RadarSpec.onBearing(RadarSpec.rim, Double(bearing)))
            ticks.addLine(to: RadarSpec.onBearing(RadarSpec.rim * (1 - RadarSpec.majorTick), Double(bearing)))
        }
        context.stroke(ticks, with: .color(palette.ink4.color), lineWidth: hair)
    }
}

/// Apps on the network as a radar scope (Home's centrepiece). Each keeps
/// its own bearing; the more it has moved, the closer it sits to this Mac
/// at the centre. Live traffic draws a link, flagged apps glow red, and
/// every blip flares as the sweep passes. Clicking a blip opens it on the
/// Live map.
struct NetworkScope: View {
    @Environment(\.palette) private var palette
    @Environment(\.privacy) private var privacy
    private var model = NetworkModel.shared
    @State private var focused: String?

    struct Blip: Identifiable {
        var app: NetApp
        var bearing: Double
        var point: CGPoint
        var size: Double
        var live: Bool
        var label: String?
        var labelAt: CGPoint = .zero
        var labelLeft = false
        var id: String { app.id }
    }

    var body: some View {
        let blips = Self.blips(model.overview.apps, privacy: privacy)
        RadarFrame(title: "Apps on the network", readout: readout(blips), marks: { context, scale, time in
            draw(blips, in: &context, scale: scale, time: time)
        }, centre: {
            VStack(spacing: 6) {
                Logo(size: 44)
                Text("This Mac").font(.ui(.xs, .medium)).foregroundStyle(palette.ink3.color)
            }
        })
        .overlay {
            GeometryReader { geo in
                let scale = min(geo.size.width, geo.size.height) / RadarSpec.view
                Color.clear.contentShape(.rect)
                    .onContinuousHover { phase in
                        if case .active(let at) = phase {
                            focused = Self.hit(blips, at: CGPoint(x: at.x / scale, y: at.y / scale))?.id
                        } else {
                            focused = nil
                        }
                    }
                    .onTapGesture { at in
                        guard let blip = Self.hit(blips, at: CGPoint(x: at.x / scale, y: at.y / scale)) else { return }
                        model.pendingTarget = .app(blip.app.name)
                        model.liveView = .map
                        AppModel.shared.open(.networkLive)
                    }
                    .help(focused.flatMap { id in blips.first { $0.id == id } }.map { "Open \($0.app.name) on the map" } ?? "")
            }
            .aspectRatio(1, contentMode: .fit)
            .padding(.bottom, 28)
        }
        .watchesNetwork()
    }

    private func readout(_ blips: [Blip]) -> String {
        if let id = focused, let blip = blips.first(where: { $0.id == id }) {
            let name = privacy ? "An app" : blip.app.name
            return "\(name)\(blip.app.flagged ? " (flagged)" : ""): \(LowtideFormat.rate(Double(blip.app.rateIn))) down, "
                + "\(LowtideFormat.rate(Double(blip.app.rateOut))) up, \(LowtideFormat.count(blip.app.hosts, "server"))"
        }
        let flagged = blips.filter(\.app.flagged).count
        let live = blips.filter(\.live).count
        return "\(LowtideFormat.count(blips.count, "app")) on the network, " + (flagged > 0 ? "\(flagged) flagged" : "\(live) talking") + ". Closer is busier."
    }

    private static func hit(_ blips: [Blip], at point: CGPoint) -> Blip? {
        blips.min { hypot($0.point.x - point.x, $0.point.y - point.y) < hypot($1.point.x - point.x, $1.point.y - point.y) }
            .flatMap { hypot($0.point.x - point.x, $0.point.y - point.y) < 16 ? $0 : nil }
    }

    /// A stable bearing per app, so blips don't jump between updates.
    static func bearing(_ id: String) -> Double {
        var h = 7
        for unit in id.utf16 { h = (h * 31 + Int(unit)) % 3_600_000 }
        return Double(h % 3600) / 10
    }

    static func blips(_ apps: [NetApp], privacy: Bool) -> [Blip] {
        let top = apps.sorted { $0.bytesIn + $0.bytesOut > $1.bytesIn + $1.bytesOut }.prefix(40)
        let peak = Double(max(1, top.map(\.rate).max() ?? 1))
        var blips: [Blip] = top.enumerated().map { index, app in
            // A fixed log scale (1 KB far out, 10 GB at the centre): a blip
            // drifts as its total grows instead of hopping.
            let scale = (log10(1 + Double(app.bytesIn + app.bytesOut)) - 3) / 7
            let distance = RadarSpec.rim * (0.9 - 0.62 * min(1, max(0, scale)))
            let bearing = bearing(app.id)
            let name = privacy ? "•••••" : String(app.name.prefix(18))
            return Blip(app: app, bearing: bearing, point: RadarSpec.onBearing(distance, bearing),
                        size: 3.5 + 4.2 * sqrt(Double(app.rate) / peak), live: app.rate > 0,
                        label: app.flagged || index < 9 ? name : nil)
        }
        // Labels that would collide are left out; flagged names first.
        var taken = [CGRect(x: RadarSpec.c - 60, y: RadarSpec.c - 42, width: 120, height: 84)]
        for i in blips.indices.sorted(by: { (blips[$0].app.flagged ? 0 : 1) < (blips[$1].app.flagged ? 0 : 1) }) {
            guard let label = blips[i].label else { continue }
            let width = Double(label.count) * 7.2 + 6
            let left = blips[i].point.x >= RadarSpec.c + RadarSpec.rim * 0.45
            let x = left ? blips[i].point.x - 10 - width : blips[i].point.x + 10
            let spot = [-8.0, -24, 8].map { CGRect(x: x, y: blips[i].point.y + $0, width: width, height: 16) }
                .first { box in !taken.contains { $0.intersects(box) } }
            if let spot {
                taken.append(spot)
                blips[i].labelAt = CGPoint(x: left ? spot.maxX : spot.minX, y: spot.midY)
                blips[i].labelLeft = left
            } else {
                blips[i].label = nil
            }
        }
        return blips
    }

    private func draw(_ blips: [Blip], in context: inout GraphicsContext, scale: Double, time: TimeInterval) {
        let c = CGPoint(x: RadarSpec.c, y: RadarSpec.c)
        for blip in blips where blip.live {
            var line = Path()
            line.move(to: c)
            line.addLine(to: blip.point)
            let tone = blip.app.flagged ? palette.bad.opacity(0.45) : palette.brand.opacity(0.25)
            context.stroke(line, with: .color(tone.color),
                           style: StrokeStyle(lineWidth: 1 / scale, dash: [3 / scale, 7 / scale], dashPhase: -time * 12 / scale))
        }
        for blip in blips {
            let tone = blip.app.flagged ? palette.bad : palette.brand
            let flash = RadarSpec.flash(blip.bearing, at: time)
            if flash > 0 {
                let r = blip.size + 1.5 + flash * 4
                context.fill(Path(ellipseIn: CGRect(x: blip.point.x - r, y: blip.point.y - r, width: r * 2, height: r * 2)),
                             with: .color(tone.opacity(0.35 * flash).color))
            }
            if blip.app.flagged {
                let wave = (time / 1.8).truncatingRemainder(dividingBy: 1)
                let r = blip.size + 3.5 + wave * 10
                context.stroke(Path(ellipseIn: CGRect(x: blip.point.x - r, y: blip.point.y - r, width: r * 2, height: r * 2)),
                               with: .color(palette.bad.opacity(1 - wave).color), lineWidth: 1 / scale)
            }
            let r = blip.size
            let dot = Path(ellipseIn: CGRect(x: blip.point.x - r, y: blip.point.y - r, width: r * 2, height: r * 2))
            context.fill(dot, with: .color(tone.opacity(blip.live || blip.app.flagged ? 1 : 0.45).color))
            if focused == blip.id { context.stroke(dot, with: .color(palette.ink.color), lineWidth: 2 / scale) }
            if let label = blip.label {
                let colour = blip.app.flagged ? palette.bad : focused == blip.id ? palette.ink : palette.ink3
                // In radar units: it scales with the scope, like the field.
                context.draw(Text(label).font(.system(size: 13)).foregroundStyle(colour.color),
                             at: blip.labelAt, anchor: blip.labelLeft ? .trailing : .leading)
            }
        }
    }
}

/// The scope with the network monitor off: the same frame, nothing on it.
struct NetworkScopeAtRest: View {
    var body: some View {
        RadarFrame(title: "This Mac", readout: "Network monitoring is off.", centre: { Logo(size: 44) })
    }
}


/// The sweep's trailing light: a conic gradient layer that Core Animation
/// turns in the window server, so the app does no work per frame (a SwiftUI
/// animation re-runs the window's layout every frame). It starts at the
/// angle the clock gives, so the sweep and the blips' flares agree.
struct RadarSweep: NSViewRepresentable {
    let brand: ColorValue

    func makeNSView(context: Context) -> SweepView { SweepView() }

    func updateNSView(_ view: SweepView, context: Context) { view.brand = brand }

    final class SweepView: NSView {
        private let gradient = CAGradientLayer()
        var brand: ColorValue? {
            didSet { if brand != oldValue { colorize() } }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            gradient.type = .conic
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            // Zero points up (AppKit's unit space has y up); the gradient's
            // angle runs counter-clockwise, so the stops below are mirrored.
            gradient.endPoint = CGPoint(x: 0.5, y: 1)
            layer?.addSublayer(gradient)
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            let side = min(bounds.width, bounds.height)
            let diameter = side * RadarSpec.rim * 2 / RadarSpec.view
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            gradient.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
            gradient.cornerRadius = diameter / 2
            gradient.masksToBounds = true
            CATransaction.commit()
            spin()
        }

        private func colorize() {
            guard let brand else { return }
            // The bright edge sits `edge` degrees clockwise from the top and
            // its tail fades out behind it (counter-clockwise), as SwiftUI drew it.
            let stops: [(Double, Double)] = [
                (0, 0), (0, 1 - (RadarSpec.edge + 0.4) / 360), (RadarSpec.sweepEdge, 1 - RadarSpec.edge / 360),
                (RadarSpec.sweepTail, 1 - (RadarSpec.edge - 1) / 360), (0, 1),
            ]
            gradient.colors = stops.map { brand.opacity($0.0).nsColor.cgColor }
            gradient.locations = stops.map { NSNumber(value: $0.1) }
        }

        /// One turn every `sweepSeconds`, phased to the clock. AppKit's y
        /// axis points up, so the layer turns clockwise with a negative angle.
        private func spin() {
            gradient.removeAnimation(forKey: "sweep")
            let now = Date().timeIntervalSinceReferenceDate
            let phase = (now / RadarSpec.sweepSeconds).truncatingRemainder(dividingBy: 1)
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = -phase * 2 * .pi
            turn.toValue = -(phase + 1) * 2 * .pi
            turn.duration = RadarSpec.sweepSeconds
            turn.repeatCount = .infinity
            turn.isRemovedOnCompletion = false
            gradient.add(turn, forKey: "sweep")
        }
    }
}
