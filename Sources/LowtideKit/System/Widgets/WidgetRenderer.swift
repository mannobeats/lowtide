import AppKit
import CoreGraphics
import CoreText

/// The strip, drawn: an image and its straight RGBA pixels (for change
/// detection and tests). A template is black with the coverage as alpha.
public struct WidgetBitmap: Equatable, @unchecked Sendable {
    // @unchecked: CGImage is immutable and thread-safe.
    public let image: CGImage
    /// Straight (not premultiplied) RGBA, top row first.
    public let rgba: [UInt8]
    public let width: Int
    public let height: Int
    public let scale: Double
    public let template: Bool

    public static func == (a: WidgetBitmap, b: WidgetBitmap) -> Bool {
        a.width == b.width && a.height == b.height && a.template == b.template && a.rgba == b.rgba
    }

    /// The image's size in points.
    public var size: CGSize { CGSize(width: Double(width) / scale, height: Double(height) / scale) }
}

/// Draws the widgets as one image with CoreGraphics and CoreText. In Mono
/// only coverage matters: macOS tints a template image for the menu bar
/// under it, so partial alpha reads as the secondary text colour. A coloured
/// strip can't be a template, so it is drawn for the bar's actual
/// appearance: neutral ink in the menu bar's text colour, data in colours
/// tuned for a dark or a light bar.
///
/// Every widget has a fixed width, measured from its widest possible value
/// with monospaced digits, so the strip never changes size as numbers move.
public enum WidgetRenderer {
    private struct Fonts {
        let label = font(7, .medium)
        let value = font(11.5, .medium)
        let speed = font(9, .medium)
        let stack = font(5.5, .semibold)
        let battery = font(10, .medium)

        /// SF with monospaced digits, so values never shift.
        static func font(_ size: Double, _ weight: NSFont.Weight) -> CTFont {
            NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) as CTFont
        }
    }

    private static func line(_ text: String, _ font: CTFont) -> CTLine {
        // Text takes the context's fill colour, like every other mark.
        let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorFromContextAttributeName: true]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes as [NSAttributedString.Key: Any]))
    }

    static func measure(_ text: String, _ font: CTFont) -> Double {
        CTLineGetTypographicBounds(line(text, font), nil, nil, nil)
    }

    private static func widest(_ texts: [String], _ font: CTFont) -> Double {
        texts.map { measure($0, font) }.max() ?? 0
    }

    private static func width(_ piece: WidgetPiece, _ fonts: Fonts) -> Double {
        let beside = WidgetLayout.stack + WidgetLayout.stackGap
        switch piece {
        case let .value(label, _, widestValues, _):
            return max(measure(label, fonts.label), widest(widestValues, fonts.value)).rounded(.up)
        case let .bars(_, levels, split):
            if levels.count <= 1 { return beside + WidgetLayout.barWidth }
            let n = Double(levels.count)
            let group = split > 0 && split < levels.count ? 1.5 : 0
            return beside + n * WidgetLayout.coreWidth + (n - 1) + group
        case .chart, .traffic: return beside + WidgetLayout.chartWidth
        case .ring: return beside + WidgetLayout.ringWidth
        case .speed: return (WidgetLayout.arrowWidth + 2.5 + widest(WidgetText.rates, fonts.speed)).rounded(.up)
        case .battery: return (widest(WidgetText.percents, fonts.battery) + 3 + WidgetLayout.batteryWidth).rounded(.up)
        }
    }

    /// The width of one widget in points (fixed whatever its value).
    public static func width(of piece: WidgetPiece) -> Double { width(piece, Fonts()) }

    /// All pieces side by side, a gap apart, for a dark or light menu bar;
    /// a template when none of them has colour. nil when nothing is shown.
    public static func strip(_ pieces: [(WidgetPiece, WidgetTone)], dark: Bool, scale: Double = 2) -> WidgetBitmap? {
        let fonts = Fonts()
        let widths = pieces.map { width($0.0, fonts) }
        let (starts, total) = WidgetLayout.layout(widths)
        let template = pieces.allSatisfy { $0.1 == .ink }
        guard let painter = Painter(width: total, scale: scale, template: template, dark: dark) else { return nil }
        for ((piece, tone), (x, w)) in zip(pieces, zip(starts, widths)) {
            draw(painter, fonts, piece, tone, x: x, width: w)
        }
        return painter.finish()
    }

    // MARK: Drawing

    private final class Painter {
        let ctx: CGContext
        let pixelWidth: Int
        let pixelHeight: Int
        let scale: Double
        let template: Bool
        let dark: Bool

        init?(width: Double, scale: Double, template: Bool, dark: Bool) {
            let w = Int((width * scale).rounded(.up)), h = Int(WidgetLayout.height * scale)
            guard w > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            self.ctx = ctx
            pixelWidth = w
            pixelHeight = h
            self.scale = scale
            self.template = template
            self.dark = dark
            ctx.scaleBy(x: scale, y: scale)
            ctx.setShouldAntialias(true)
            ctx.setAllowsFontSmoothing(false)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ink(1)
        }

        /// Labels, tracks and baselines: the menu bar's own text colour, or
        /// black for a template, where only coverage counts.
        var inkColor: ([UInt8], Double) {
            if template { return ([0, 0, 0], 1) }
            return dark ? ([255, 255, 255], 1) : ([0, 0, 0], 0.85)
        }

        /// Fills and strokes from here on: `color`, or the ink when nil.
        func paint(_ color: [UInt8]?, _ alpha: Double) {
            let (ink, inkAlpha) = inkColor
            let rgb = color ?? ink
            let a = color == nil ? alpha * inkAlpha : alpha
            let c = CGColor(srgbRed: Double(rgb[0]) / 255, green: Double(rgb[1]) / 255, blue: Double(rgb[2]) / 255, alpha: a)
            ctx.setFillColor(c)
            ctx.setStrokeColor(c)
        }

        func ink(_ alpha: Double) { paint(nil, alpha) }

        func color(_ tone: WidgetTone, _ value: Double) -> [UInt8]? { tone.color(value, dark: dark) }

        func text(_ text: String, _ font: CTFont, x: Double, baseline: Double) {
            ctx.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(WidgetRenderer.line(text, font), ctx)
        }

        func textRight(_ text: String, _ font: CTFont, right: Double, baseline: Double) {
            self.text(text, font, x: right - WidgetRenderer.measure(text, font), baseline: baseline)
        }

        func rounded(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double) {
            let r = min(r, w / 2, h / 2)
            ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil))
        }

        func fillRounded(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double) {
            guard w > 0, h > 0 else { return }
            rounded(x, y, w, h, r)
            ctx.fillPath()
        }

        func polyline(_ points: [(Double, Double)]) {
            guard let first = points.first else { return }
            ctx.beginPath()
            ctx.move(to: CGPoint(x: first.0, y: first.1))
            for p in points.dropFirst() { ctx.addLine(to: CGPoint(x: p.0, y: p.1)) }
        }

        func strokeLine(_ points: [(Double, Double)], width: Double) {
            guard points.count >= 2 else { return }
            polyline(points)
            ctx.setLineWidth(width)
            ctx.strokePath()
        }

        /// The area under a line, down to `base`, as the current path.
        @discardableResult
        func area(_ points: [(Double, Double)], base: Double) -> Bool {
            guard points.count >= 2, let first = points.first, let last = points.last else { return false }
            polyline(points)
            ctx.addLine(to: CGPoint(x: last.0, y: base))
            ctx.addLine(to: CGPoint(x: first.0, y: base))
            ctx.closePath()
            return true
        }

        func fillUnder(_ points: [(Double, Double)], base: Double) {
            if area(points, base: base) { ctx.fillPath() }
        }

        /// Fills the current path, each sample's column in its own colour.
        func fillColumns(_ points: [(Double, Double)], _ colors: [[UInt8]?], alpha: Double) {
            ctx.saveGState()
            ctx.clip()
            // Column edges on whole pixels: neighbours meet without a seam.
            func snap(_ x: Double) -> Double { (x * scale).rounded() / scale }
            for (i, (point, color)) in zip(points, colors).enumerated() {
                let left = i == 0 ? 0 : snap((points[i - 1].0 + point.0) / 2)
                let right = i + 1 < points.count ? snap((point.0 + points[i + 1].0) / 2) : point.0 + WidgetLayout.chartWidth
                paint(color, alpha)
                ctx.fill(CGRect(x: left, y: 0, width: right - left, height: WidgetLayout.height))
            }
            ctx.restoreGState()
        }

        /// A sparkline, its area and line coloured per sample.
        func chart(_ points: [(Double, Double)], _ colors: [[UInt8]?]) {
            if area(points, base: 1.5) { fillColumns(points, colors, alpha: 0.3) }
            if points.count >= 2 {
                polyline(points)
                ctx.setLineWidth(1.1)
                ctx.replacePathWithStrokedPath()
                fillColumns(points, colors, alpha: 1)
            }
        }

        func finish() -> WidgetBitmap? {
            guard let image = ctx.makeImage(), let data = ctx.data else { return nil }
            let rowBytes = ctx.bytesPerRow
            var rgba = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
            let bytes = data.assumingMemoryBound(to: UInt8.self)
            for row in 0..<pixelHeight {
                for col in 0..<(pixelWidth * 4) { rgba[row * pixelWidth * 4 + col] = bytes[row * rowBytes + col] }
            }
            // CoreGraphics premultiplies; straight RGBA does not.
            for px in stride(from: 0, to: rgba.count, by: 4) {
                let a = Int(rgba[px + 3])
                guard a > 0, a < 255 else { continue }
                for c in 0..<3 { rgba[px + c] = UInt8(min((Int(rgba[px + c]) * 255 + a / 2) / a, 255)) }
            }
            return WidgetBitmap(image: image, rgba: rgba, width: pixelWidth, height: pixelHeight, scale: scale, template: template)
        }
    }

    /// Label letters stacked in a narrow column, like a rack unit's legend.
    private static func stack(_ p: Painter, _ fonts: Fonts, _ label: String, x: Double) {
        p.ink(0.7)
        for (i, ch) in label.prefix(3).enumerated() {
            let s = String(ch)
            p.text(s, fonts.stack, x: x + (WidgetLayout.stack - measure(s, fonts.stack)) / 2, baseline: 12.4 - 5.8 * Double(i))
        }
    }

    /// A vertical level: a faint track with the fill rising from the bottom.
    private static func levelBar(_ p: Painter, x: Double, w: Double, level: Double, color: [UInt8]?) {
        let (y, h) = (1.5, 15.0)
        let r = min(w, 2.5) / 2
        p.ink(0.25)
        p.fillRounded(x, y, w, h, r)
        p.paint(color, 1)
        p.fillRounded(x, y, w, max(h * min(max(level, 0), 1), level > 0 ? 1 : 0), r)
    }

    /// An arrow one row tall, pointing up or down.
    private static func arrow(_ p: Painter, x: Double, bottom: Double, up: Bool) {
        let top = bottom + 6.4, cx = x + WidgetLayout.arrowWidth / 2, head = 2.1
        let (tip, tail) = up ? (top, bottom) : (bottom, top)
        let back = up ? tip - head : tip + head
        p.strokeLine([(cx, tail), (cx, tip)], width: 1.15)
        p.strokeLine([(cx - head, back), (cx, tip), (cx + head, back)], width: 1.15)
    }

    /// Download and upload: ink, or their colour pair.
    private static func trafficColors(_ p: Painter, _ tone: WidgetTone) -> ([UInt8]?, [UInt8]?) {
        tone == .ink ? (nil, nil) : (WidgetSwatch.blue.on(dark: p.dark), WidgetSwatch.pink.on(dark: p.dark))
    }

    private static func draw(_ p: Painter, _ fonts: Fonts, _ piece: WidgetPiece, _ tone: WidgetTone, x: Double, width: Double) {
        let beside = x + WidgetLayout.stack + WidgetLayout.stackGap
        let chartW = WidgetLayout.chartWidth
        switch piece {
        case let .value(label, value, _, level):
            p.ink(0.62)
            p.text(label, fonts.label, x: x, baseline: 12)
            p.paint(p.color(tone, level), 1)
            p.text(value, fonts.value, x: x, baseline: 1.6)
        case let .bars(label, levels, split):
            stack(p, fonts, label, x: x)
            if levels.count == 1 {
                levelBar(p, x: beside, w: WidgetLayout.barWidth, level: levels[0], color: p.color(tone, levels[0]))
            } else {
                var cx = beside
                for (i, level) in levels.enumerated() {
                    if i > 0, i == split { cx += 1.5 }
                    levelBar(p, x: cx, w: WidgetLayout.coreWidth, level: level, color: p.color(tone, level))
                    cx += WidgetLayout.coreWidth + 1
                }
            }
        case let .chart(label, series):
            stack(p, fonts, label, x: x)
            let recent = Array(series.suffix(WidgetLayout.spark))
            let points = WidgetLayout.sparkPoints(recent, x: beside, y: 1.5, width: chartW, height: 15)
            p.ink(0.4)
            p.strokeLine([(beside, 1.25), (beside + chartW, 1.25)], width: 0.5)
            p.chart(points, recent.map { p.color(tone, $0) })
        case let .traffic(down, up):
            stack(p, fonts, "NET", x: x)
            let d = WidgetLayout.sparkPoints(down, x: beside, y: 1.5, width: chartW, height: 15)
            let u = WidgetLayout.sparkPoints(up, x: beside, y: 1.5, width: chartW, height: 15)
            let (downColor, upColor) = trafficColors(p, tone)
            p.ink(0.4)
            p.strokeLine([(beside, 1.25), (beside + chartW, 1.25)], width: 0.5)
            p.paint(downColor, 0.35)
            p.fillUnder(d, base: 1.5)
            p.paint(downColor, 1)
            p.strokeLine(d, width: 1)
            p.paint(upColor, upColor != nil ? 1 : 0.75)
            p.strokeLine(u, width: 1)
        case let .ring(label, level):
            stack(p, fonts, label, x: x)
            let center = CGPoint(x: beside + WidgetLayout.ringWidth / 2, y: WidgetLayout.height / 2)
            let r = 6.4
            p.ctx.setLineWidth(2.2)
            p.ink(0.25)
            p.ctx.beginPath()
            p.ctx.addArc(center: center, radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: false)
            p.ctx.strokePath()
            p.paint(p.color(tone, level), 1)
            let share = min(max(level, 0), 1)
            if share > 0 {
                p.ctx.beginPath()
                p.ctx.addArc(center: center, radius: r, startAngle: .pi / 2, endAngle: .pi / 2 - share * .pi * 2, clockwise: true)
                p.ctx.strokePath()
            }
        case let .speed(up, down):
            let right = x + width
            let (downColor, upColor) = trafficColors(p, tone)
            p.paint(upColor, 1)
            arrow(p, x: x, bottom: 10.2, up: true)
            p.paint(downColor, 1)
            arrow(p, x: x, bottom: 1.4, up: false)
            p.ink(1)
            p.textRight(up, fonts.speed, right: right, baseline: 10.3)
            p.textRight(down, fonts.speed, right: right, baseline: 1.5)
        case let .battery(level, charging, text):
            let bx = x + width - WidgetLayout.batteryWidth
            p.ink(1)
            p.textRight(text, fonts.battery, right: bx - 3, baseline: 5.2)
            let (by, bw, bh) = (4.25, 20.5, 9.5)
            p.ink(0.45)
            p.ctx.setLineWidth(1)
            p.rounded(bx + 0.5, by + 0.5, bw - 1, bh - 1, 2.6)
            p.ctx.strokePath()
            p.fillRounded(bx + bw + 0.5, by + 3, 1.5, bh - 6, 0.75)
            p.paint(p.color(tone, level), 1)
            p.fillRounded(bx + 1.75, by + 1.75, max((bw - 3.5) * min(max(level, 0), 1), 1), bh - 3.5, 1.4)
            if charging {
                let (mx, my) = (bx + bw / 2, by + bh / 2)
                let bolt = [(mx + 1.3, my + 4.6), (mx - 2.6, my - 0.4), (mx - 0.1, my - 0.4),
                            (mx - 1.3, my - 4.6), (mx + 2.6, my + 0.6), (mx + 0.1, my + 0.6)]
                // A clear halo first, so the bolt reads over fill and track.
                p.ctx.setBlendMode(.clear)
                p.polyline(bolt)
                p.ctx.closePath()
                p.ctx.setLineWidth(1.6)
                p.ctx.strokePath()
                p.ctx.setBlendMode(.normal)
                p.ink(1)
                p.polyline(bolt)
                p.ctx.closePath()
                p.ctx.fillPath()
            }
        }
    }
}
