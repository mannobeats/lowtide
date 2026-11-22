import LowtideKit
import SwiftUI

/// The overlay's own small palette: Graphite
/// neutrals, one warm pearl for the voice, a cool aqua while it works,
/// green when it lands, coral when it can't. It floats over other apps, so
/// it follows the Mac's light or dark, not the app's theme.
struct HUDPalette {
    var plate: ColorValue
    var rim: ColorValue
    var edge: ColorValue
    var shadow: Double
    var sheen: Double
    var ink, ink2, ink3: ColorValue
    var wire, hot, glow, work, ok, bad: ColorValue

    static let dark = HUDPalette(
        plate: .srgb(26 / 255, 27 / 255, 30 / 255, 0.9), rim: .srgb(1, 1, 1, 0.11), edge: .srgb(0, 0, 0, 0.55),
        shadow: 0.32, sheen: 0.07,
        ink: .srgb(244 / 255, 245 / 255, 247 / 255), ink2: .srgb(166 / 255, 169 / 255, 176 / 255),
        ink3: .srgb(118 / 255, 121 / 255, 128 / 255), wire: .srgb(200 / 255, 204 / 255, 212 / 255),
        hot: .srgb(1, 238 / 255, 218 / 255), glow: .srgb(1, 226 / 255, 196 / 255), work: .srgb(128 / 255, 214 / 255, 230 / 255),
        ok: .srgb(112 / 255, 214 / 255, 150 / 255), bad: .srgb(1, 122 / 255, 104 / 255))

    static let light = HUDPalette(
        plate: .srgb(250 / 255, 250 / 255, 251 / 255, 0.92), rim: .srgb(1, 1, 1, 0.9), edge: .srgb(0, 0, 0, 0.11),
        shadow: 0.13, sheen: 0.6,
        ink: .srgb(29 / 255, 29 / 255, 31 / 255), ink2: .srgb(92 / 255, 94 / 255, 100 / 255),
        ink3: .srgb(134 / 255, 136 / 255, 142 / 255), wire: .srgb(66 / 255, 69 / 255, 76 / 255),
        // A white glow on a white plate: no halo, just a clean line.
        hot: .srgb(22 / 255, 22 / 255, 24 / 255), glow: .srgb(1, 1, 1), work: .srgb(0, 128 / 255, 160 / 255),
        ok: .srgb(36 / 255, 160 / 255, 82 / 255), bad: .srgb(222 / 255, 76 / 255, 58 / 255))
}

/// The dictation overlay. A 32 pt graphite capsule holding a filament your
/// voice plucks; the words heard so far float above it in a second capsule.
/// Listening, it breathes; transcribing, it narrows and a bead of light runs
/// the thread; done, the thread draws into a check and says where the text
/// went; empty, it lies flat; failing, it turns into a coral bead with what
/// to do, and only then takes a click.
struct HUDView: View {
    let model: HUDModel
    @Environment(\.accessibilityReduceMotion) private var reduced
    private var themes = ThemeStore.shared
    private var dictation = Dictation.shared

    init(model: HUDModel) { self.model = model }

    var body: some View {
        let palette = themes.systemDark ? HUDPalette.dark : .light
        TimelineView(.animation(paused: !model.animating)) { context in
            let frame = model.frame(at: context.date, words: dictation.preview, level: dictation.level.value,
                                    reduced: reduced)
            stack(frame, palette)
        }
        .frame(width: VoiceOverlay.size.width, height: VoiceOverlay.size.height, alignment: .bottom)
        .environment(\.colorScheme, themes.systemDark ? .dark : .light)
    }

    private func stack(_ f: HUDFrame, _ p: HUDPalette) -> some View {
        let m = f.motion
        return VStack(spacing: Space.sm) {
            words(f, p)
            plate(f, p)
        }
        .padding(.bottom, Space.xl)
        .opacity(clamp(m.opacity.x))
        .scaleEffect(m.scale.x, anchor: .bottom)
        .blur(radius: m.blur.x > 0.05 ? m.blur.x : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    // MARK: The words

    private func words(_ f: HUDFrame, _ p: HUDPalette) -> some View {
        let m = f.motion
        let shown = clamp(m.previewOpacity.x)
        return ZStack(alignment: .bottomLeading) {
            Glass(palette: p, radius: 14, danger: false)
            Text(dictation.preview)
                .font(.ui(.sm))
                .foregroundStyle(p.ink.color)
                .lineSpacing(2)
                .frame(width: HUDText.wordsWidth, alignment: .bottomLeading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: HUDText.wordsWidth, height: 2 * HUDText.lineHeight, alignment: .bottomLeading)
                .clipped()
                // Once they overflow, older lines dissolve off the top.
                .mask {
                    LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: f.wordsFull ? 0.42 : 0)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .opacity(clamp(m.previewDim.x))
                .padding(.leading, 14)
                .padding(.bottom, 9)
                .frame(width: max(m.previewWidth.x, 1), height: max(m.previewHeight.x, 1), alignment: .bottomLeading)
                .clipped()
        }
        .frame(width: max(m.previewWidth.x, 1), height: max(m.previewHeight.x, 1))
        .clipShape(.rect(cornerRadius: 14))
        .opacity(shown)
        .scaleEffect(0.97 + 0.03 * shown)
        .offset(y: m.previewY.x)
        .accessibilityHidden(shown < 0.5)
    }

    // MARK: The plate

    private func plate(_ f: HUDFrame, _ p: HUDPalette) -> some View {
        let m = f.motion
        let width = max(HUDPlate.height, m.width.x)
        let shown = model.shown
        let clickable = shown.phase == .error && shown.action != nil
        return ZStack(alignment: .leading) {
            Glass(palette: p, radius: HUDPlate.height / 2, danger: clickable)
            Canvas { context, _ in
                FilamentPainter(frame: f, palette: p, width: width).paint(&context)
            }
            .frame(width: width, height: HUDPlate.height)
            if let label = f.label {
                HStack(spacing: Space.sm) {
                    Text(label.text)
                        .font(.ui(.xs, .medium))
                        .foregroundStyle((label.quiet ? p.ink2 : p.ink).color)
                    if let action = label.action {
                        Text(action.title)
                            .font(.ui(.xs, .medium))
                            .foregroundStyle(p.bad.color)
                            .padding(.horizontal, Space.sm)
                            .frame(height: 20)
                            .background(p.bad.opacity(0.14).color, in: .capsule)
                            .overlay(Capsule().strokeBorder(p.bad.opacity(0.3).color, lineWidth: 0.5))
                    }
                }
                .fixedSize()
                .opacity(clamp(m.label.x))
                .offset(x: HUDPlate.labelX + m.labelX.x)
            }
            if shown.queued > 0 && shown.phase.isLive {
                Text("+\(shown.queued)")
                    .font(.ui(.xxs))
                    .monospacedDigit()
                    .foregroundStyle(p.ink3.color)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, Space.md)
            }
        }
        .frame(width: width, height: HUDPlate.height, alignment: .leading)
        .clipShape(.capsule)
        .contentShape(.capsule)
        .onTapGesture {
            if clickable, let action = shown.action { Dictation.shared.run(action) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(f.label?.text ?? phaseName(shown.phase))
        .accessibilityAddTraits(clickable ? .isButton : [])
    }

    private func phaseName(_ phase: VoicePhase) -> String {
        switch phase {
        case .listening: "Opening the microphone"
        case .recording: "Listening"
        case .transcribing: "Transcribing"
        default: "Dictation"
        }
    }

    private func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
}

/// The capsule's glass: graphite with light on its top edge, a hairline
/// rim, and a shadow in three layers (contact, near, far).
private struct Glass: View {
    let palette: HUDPalette
    let radius: CGFloat
    /// An error's action makes the whole capsule a button: the rim warms.
    let danger: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let p = palette
        shape
            .fill(p.plate.color)
            .overlay {
                shape.fill(LinearGradient(colors: [.white.opacity(p.sheen), .white.opacity(0)],
                                          startPoint: .top, endPoint: .init(x: 0.5, y: 0.58)))
            }
            .overlay { shape.strokeBorder((danger ? p.bad.opacity(0.42) : p.rim).color, lineWidth: 0.5) }
            .overlay {
                shape.inset(by: 0.25)
                    .stroke(LinearGradient(colors: [.white.opacity(0.16), .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.2)),
                            lineWidth: 0.5)
            }
            .background { shape.stroke(p.edge.color, lineWidth: 1) }
            .shadow(color: .black.opacity(p.shadow * 0.6), radius: 1, y: 1)
            .shadow(color: .black.opacity(p.shadow), radius: 6, y: 6)
            .shadow(color: .black.opacity(p.shadow * 0.8), radius: 14, y: 16)
    }
}

/// Draws the filament and the mark a take ends on, in the plate's points.
private struct FilamentPainter {
    let frame: HUDFrame
    let palette: HUDPalette
    let width: Double
    static let inset = 15.0

    func paint(_ context: inout GraphicsContext) {
        let m = frame.motion
        let cy = HUDPlate.height / 2
        let full = max(0, width - Self.inset * 2 - frame.right)
        let half = full / 2 * max(0, m.span.x)
        let centre = (width - frame.right) / 2
        let cx = centre + (HUDPlate.glyphX - centre) * m.anchor.x
        if m.wire.x > 0.01 && half > 0.5 { thread(&context, cx: cx, cy: cy, half: half) }
        if let label = frame.label, m.draw.x > 0.01 { glyph(&context, label.glyph, x: cx, cy: cy) }
    }

    private func thread(_ context: inout GraphicsContext, cx: Double, cy: Double, half: Double) {
        let m = frame.motion
        let f = frame.filament
        let p = palette
        let wire = min(max(m.wire.x, 0), 1), work = min(max(m.work.x, 0), 1)
        let reach = HUDPlate.height / 2 - 5
        // A short thread can't hold a big swing: the amplitude follows length.
        let room = reach * min(1, half / 30)
        let x0 = cx - half
        let (main, depth) = f.shape(room: room)
        let heat = f.heat
        let color = p.wire.mixed(with: p.hot, 1 - heat)
        // Breathing while armed and quiet: the thread's light rises and falls.
        let breath = 0.78 + 0.22 * sin(frame.time * 2 * .pi / 2.6)
        let alpha = wire * (f.live ? 0.72 + 0.28 * heat : breath) * (1 - 0.55 * work)
        let start = CGPoint(x: x0, y: 0), end = CGPoint(x: x0 + half * 2, y: 0)
        func along(_ a: Double) -> GraphicsContext.Shading {
            .linearGradient(Gradient(stops: [
                .init(color: color.opacity(0).color, location: 0), .init(color: color.opacity(a).color, location: 0.14),
                .init(color: color.opacity(a).color, location: 0.86), .init(color: color.opacity(0).color, location: 1),
            ]), startPoint: start, endPoint: end)
        }
        func path(_ ys: [Double]) -> Path {
            var path = Path()
            for (j, y) in ys.enumerated() {
                let point = CGPoint(x: x0 + Double(j) / Double(ys.count - 1) * half * 2, y: cy + y)
                j == 0 ? path.move(to: point) : path.addLine(to: point)
            }
            return path
        }
        let round = StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
        // The thread's other plane of swing, faint: it gives the line depth.
        context.stroke(path(depth), with: along(alpha * 0.3), style: round)
        let bright = path(main)
        var lit = context
        lit.addFilter(.shadow(color: p.glow.opacity(0.25 + 0.75 * heat).color, radius: (3 + 7 * heat) / 2))
        lit.stroke(bright, with: along(alpha), style: StrokeStyle(lineWidth: 1.5 + 0.35 * heat, lineCap: .round, lineJoin: .round))
        if work > 0.01 {
            // A bead of light running the thread, there and back, while it works.
            let at = f.reduced ? 0.5 : 0.5 - 0.5 * cos(frame.time * 2 * .pi / 1.5)
            let spread = 0.3
            let stops: [Gradient.Stop] = [(-spread, 0.0), (-spread / 3, 0.55), (0, 1), (spread / 3, 0.55), (spread, 0)].map {
                .init(color: p.work.opacity($0.1 * work * wire).color, location: min(max(at + $0.0, 0), 1))
            }
            var bead = context
            bead.addFilter(.shadow(color: p.work.opacity(0.8 * work).color, radius: 4))
            bead.stroke(bright, with: .linearGradient(Gradient(stops: stops), startPoint: start, endPoint: end),
                        style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
        }
    }

    /// The mark a take ends on, drawn where the filament drew in.
    private func glyph(_ context: inout GraphicsContext, _ glyph: HUDLabel.Glyph, x: Double, cy: Double) {
        let d = max(0, frame.motion.draw.x)
        let k = min(1, d)
        let p = palette
        switch glyph {
        case .check:
            // Drawn on along its own length, like a pen stroke.
            let a = CGPoint(x: x - 4.6, y: cy + 0.2), b = CGPoint(x: x - 1.5, y: cy + 3.3), c = CGPoint(x: x + 4.6, y: cy - 3.5)
            let first = hypot(3.1, 3.1), second = hypot(6.1, 6.8)
            var left = k * (first + second)
            var path = Path()
            path.move(to: a)
            let t1 = min(1, left / first)
            path.addLine(to: CGPoint(x: a.x + (b.x - a.x) * t1, y: a.y + (b.y - a.y) * t1))
            left -= first
            if left > 0 {
                let t2 = min(1, left / second)
                path.addLine(to: CGPoint(x: b.x + (c.x - b.x) * t2, y: b.y + (c.y - b.y) * t2))
            }
            var lit = context
            lit.addFilter(.shadow(color: p.ok.opacity(0.45).color, radius: 3))
            lit.stroke(path, with: .color(p.ok.color), style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))
        case .alert:
            // A coral bead that lands with a bounce, an exclamation cut into it.
            let r = max(0, 7 * d)
            var lit = context
            lit.addFilter(.shadow(color: p.bad.opacity(0.5).color, radius: 4))
            lit.fill(Path(ellipseIn: CGRect(x: x - r, y: cy - r, width: 2 * r, height: 2 * r)), with: .color(p.bad.opacity(k).color))
            var bar = Path()
            bar.move(to: CGPoint(x: x, y: cy - 3.3 * k))
            bar.addLine(to: CGPoint(x: x, y: cy + 0.6 * k))
            let cut = p.plate.opacity(k / max(p.plate.a, 0.01))
            context.stroke(bar, with: .color(cut.color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            context.fill(Path(ellipseIn: CGRect(x: x - 0.95, y: cy + 3.2 * k - 0.95, width: 1.9, height: 1.9)), with: .color(cut.color))
        case .flat:
            // Nothing heard: the thread lies flat and dim.
            let w = 6 * k
            var line = Path()
            line.move(to: CGPoint(x: x - w, y: cy))
            line.addLine(to: CGPoint(x: x + w, y: cy))
            context.stroke(line, with: .color(p.ink3.opacity(k).color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        }
    }
}
