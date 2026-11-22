import LowtideKit
import SwiftUI

/// The last hour along the bottom of the map: traffic as a trace, events
/// as markers. Drag across it to replay the map at that moment; click a
/// marker to read the event. The one place events are listed on Live.
struct LiveTimeline: View {
    @Environment(\.palette) private var palette
    let timeline: NetTimeline
    @Binding var replay: Millis?
    let onLock: (String) -> Void
    @State private var width: Double = 0
    @State private var hover: NetEvent?
    @State private var hoverX: Double = 0
    @State private var picked: NetEvent?
    @State private var dragging = false
    @FocusState private var focused: Bool

    private static let minSpan: Millis = 10 * 60_000
    private static let maxSpan: Millis = 60 * 60_000
    private static let height = 36.0

    var body: some View {
        let end = Millis.now
        let first = timeline.points.first?.t ?? end
        let span = min(Self.maxSpan, max(Self.minSpan, end - first))
        let start = end - span
        let minutes = Int((Double(span) / 60_000).rounded())
        HStack(alignment: .top, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Last \(minutes) min").font(.ui(.xs, .semibold)).foregroundStyle(palette.ink2.color)
                if let replay, let at = nearest(replay) {
                    Text(NetFormat.rate(at.rateIn + at.rateOut)).font(.mono(.xxs)).monospacedDigit().foregroundStyle(palette.ink3.color)
                } else {
                    Text(LowtideFormat.count(timeline.events.count, "event")).font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                }
            }
            .frame(width: 96, alignment: .leading)
            trace(start: start, end: end, span: span, minutes: minutes)
            Group {
                if replay == nil {
                    Text("Live").font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                } else {
                    Button("Back to live") { replay = nil }.buttonStyle(.lowtide(.secondary, size: .small))
                        .keyboardShortcut(.cancelAction)
                }
            }
            .frame(width: 104, alignment: .trailing)
        }
        .padding(.horizontal, Space.lg)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .hairline(.top)
    }

    private func nearest(_ t: Millis) -> TimelinePoint? {
        timeline.points.min { abs($0.t - t) < abs($1.t - t) }
    }

    private func trace(start: Millis, end: Millis, span: Millis, minutes: Int) -> some View {
        let x = { (t: Millis) in Double(t - start) / Double(span) * width }
        let time = { (px: Double) in start + Millis(px / max(width, 1) * Double(span)) }
        return Canvas { context, size in
            let h = Self.height
            let points = timeline.points
            let peak = Double(max(1, points.map { $0.rateIn + $0.rateOut }.max() ?? 1))
            // Square root: quiet stretches stay visible next to a big download.
            let y = { (rate: Int64) in h - sqrt(Double(rate) / peak) * (h - 4) }
            let every = max(1, Int((Double(minutes) / 4).rounded()))
            for mark in (1...4).map({ $0 * every }) where mark < minutes {
                let px = x(end - Millis(mark) * 60_000)
                guard px < size.width - 60 else { continue }
                var line = Path()
                line.move(to: CGPoint(x: px, y: 0))
                line.addLine(to: CGPoint(x: px, y: h))
                context.stroke(line, with: .color(palette.line.color), lineWidth: 1)
                context.draw(Text("−\(mark)m").font(.mono(.xxs)).foregroundStyle(palette.ink4.color),
                             at: CGPoint(x: px + 3, y: h + 8), anchor: .leading)
            }
            context.draw(Text("Now").font(.ui(.xxs)).foregroundStyle(palette.ink4.color), at: CGPoint(x: size.width, y: h + 8), anchor: .trailing)
            if let firstPoint = points.first, let lastPoint = points.last {
                var total = Path(), upload = Path(), area = Path()
                area.move(to: CGPoint(x: x(firstPoint.t), y: h))
                for (i, p) in points.enumerated() {
                    let a = CGPoint(x: x(p.t), y: y(p.rateIn + p.rateOut)), b = CGPoint(x: x(p.t), y: y(p.rateOut))
                    if i == 0 { total.move(to: a); upload.move(to: b) } else { total.addLine(to: a); upload.addLine(to: b) }
                    area.addLine(to: a)
                }
                area.addLine(to: CGPoint(x: x(lastPoint.t), y: h))
                area.closeSubpath()
                context.fill(area, with: .color(palette.brand.opacity(0.08).color))
                context.stroke(total, with: .color(palette.ok.opacity(0.6).color), lineWidth: 1)
                context.stroke(upload, with: .color(palette.brand.opacity(0.6).color), lineWidth: 1)
            }
            for event in timeline.events {
                let px = x(event.t)
                let tone = event.severity == .alert ? palette.bad : palette.warn
                var tick = Path()
                tick.move(to: CGPoint(x: px, y: 5))
                tick.addLine(to: CGPoint(x: px, y: h))
                context.stroke(tick, with: .color(tone.opacity(0.6).color), lineWidth: 1)
                let r = picked?.id == event.id || hover?.id == event.id ? 3.5 : 2.5
                context.fill(Path(ellipseIn: CGRect(x: px - r, y: 3 - r, width: r * 2, height: r * 2)), with: .color(tone.color))
            }
            if let replay {
                let cursor = x(replay)
                context.fill(Path(CGRect(x: cursor, y: 0, width: max(0, size.width - cursor), height: h)),
                             with: .color(palette.surface.opacity(0.5).color))
                var line = Path()
                line.move(to: CGPoint(x: cursor, y: -4))
                line.addLine(to: CGPoint(x: cursor, y: h + 2))
                context.stroke(line, with: .color(palette.brand.color), lineWidth: 1.5)
            }
        }
        .frame(height: Self.height + 14)
        .onGeometryChange(for: Double.self) { $0.size.width } action: { width = $0 }
        .contentShape(.rect)
        .onContinuousHover { phase in
            if case .active(let at) = phase {
                hoverX = at.x
                hover = timeline.events.first { abs(x($0.t) - at.x) < 5 }
            } else {
                hover = nil
            }
        }
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { drag in
                if !dragging, abs(drag.translation.width) < 3 { return }
                dragging = true
                picked = nil
                scrub(drag.location.x, time: time)
            }
            .onEnded { drag in
                defer { dragging = false }
                guard !dragging else { return }
                if let event = timeline.events.first(where: { abs(x($0.t) - drag.location.x) < 6 }) {
                    picked = event
                } else {
                    scrub(drag.location.x, time: time)
                }
            })
        .overlay(alignment: .topLeading) {
            if let hover, picked == nil {
                HStack(spacing: 6) {
                    Text(NetFormat.clock(hover.t)).font(.mono(.xxs)).monospacedDigit().foregroundStyle(palette.ink4.color)
                    Text(hover.text).font(.ui(.xs)).foregroundStyle(palette.ink.color).lineLimit(1)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .overlaySurface(radius: Radius.md)
                .fixedSize()
                .offset(x: max(0, hoverX - 120), y: -40)
                .allowsHitTesting(false)
            }
        }
        .popover(item: $picked, arrowEdge: .top) { event in
            EventCard(event: event) {
                picked = nil
                onLock(event.app)
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) {
            replay = max(start, (replay ?? end) - 30_000)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            let next = (replay ?? end) + 30_000
            replay = next >= end - 3_000 ? nil : next
            return .handled
        }
        .accessibilityElement()
        .accessibilityLabel("Traffic over the last hour. Drag to replay.")
        .accessibilityValue(replay.map { "Replaying \(NetFormat.clock($0))" } ?? "Live")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .decrement: replay = max(start, (replay ?? end) - 30_000)
            case .increment:
                let next = (replay ?? end) + 30_000
                replay = next >= end - 3_000 ? nil : next
            @unknown default: break
            }
        }
        .help("Drag to replay the map at that moment; click a marker to read its event (← → step half a minute)")
    }

    private func scrub(_ px: Double, time: (Double) -> Millis) {
        let clamped = min(max(px, 0), width)
        // The last few pixels are "now".
        replay = clamped > width - 6 ? nil : time(clamped)
    }
}

/// One event, opened from its marker on the timeline.
private struct EventCard: View {
    @Environment(\.palette) private var palette
    let event: NetEvent
    let onShow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: 6) {
                Circle().fill((event.severity == .alert ? palette.bad : palette.warn).color).frame(width: 7, height: 7)
                Text(event.severity == .alert ? "Alert" : "Notice").font(.ui(.xs, .semibold)).foregroundStyle(palette.ink2.color)
                Spacer()
                Text(NetFormat.clock(event.t)).font(.mono(.xxs)).monospacedDigit().foregroundStyle(palette.ink4.color)
            }
            Text(event.text).font(.ui(.sm)).foregroundStyle(palette.ink.color).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !event.app.isEmpty, event.kind != "away" {
                Button("Show \(event.app)", action: onShow).buttonStyle(.lowtide(.secondary, size: .small))
            }
        }
        .padding(Space.lg)
        .frame(width: 300, alignment: .leading)
    }
}
