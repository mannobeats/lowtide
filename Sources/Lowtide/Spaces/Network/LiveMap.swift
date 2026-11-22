import AppKit
import LowtideKit
import SwiftUI

/// Where the map's camera looks: a point in map space and a zoom.
struct MapCamera: Equatable {
    var x: Double
    var y: Double
    var zoom: Double
}

/// The map's moving parts, kept across frames: the camera, the packets in
/// flight, the hover, the lock's start. A plain class, never observed:
/// it changes sixty times a second while SwiftUI draws.
final class MapSimulation {
    struct Particle {
        var link: Int
        /// Outbound travels from this Mac out; inbound the other way.
        var out: Bool
        var t: Double
    }

    var camera = MapCamera(x: 0, y: 0, zoom: 1)
    /// Set while the person pans or zooms by hand; a new lock clears it.
    var manual: MapCamera?
    var particles: [Particle] = []
    var credit: [String: Double] = [:]
    var hover: String?
    var lockKey = ""
    var lockAt: TimeInterval = 0
    var last: TimeInterval = 0
    var started: TimeInterval?
    var scene = MapScene()
    var size: CGSize = .zero
    var linkIndex: [String: Int] = [:]
    var sceneVersion = -1
    /// Labels resolved once and redrawn every frame (resolving text is the
    /// costliest part of a frame).
    var texts: [String: GraphicsContext.ResolvedText] = [:]

    static let maxParticles = 900
    static let introSeconds = 1.4
    static let lockSeconds = 0.38
    static let maxZoom = 12.0
    /// The map draws itself in once per launch, not on every visit.
    @MainActor static var introPlayed = false

    /// Map point under a view point.
    func toMap(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - size.width / 2) / camera.zoom + camera.x, y: (p.y - size.height / 2) / camera.zoom + camera.y)
    }

    func toScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - camera.x) * camera.zoom + size.width / 2, y: (p.y - camera.y) * camera.zoom + size.height / 2)
    }

    /// Nodes grow a little when zooming in, not as fast as the map.
    static func nodeScale(_ zoom: Double) -> Double { pow(zoom, -0.8) }

    /// The node nearest a view point, within reach.
    func pick(_ point: CGPoint) -> MapScene.Node? {
        let p = toMap(point)
        var best: MapScene.Node?
        var distance = 14 / camera.zoom
        for node in scene.nodes {
            let d = hypot(node.point.x - p.x, node.point.y - p.y) - node.r * Self.nodeScale(camera.zoom)
            if d < distance {
                best = node
                distance = d
            }
        }
        return best
    }

    func clamp(_ cam: MapCamera) -> MapCamera {
        MapCamera(x: min(max(cam.x, 0), size.width), y: min(max(cam.y, 0), size.height), zoom: min(max(cam.zoom, 1), Self.maxZoom))
    }

    /// Zooms by `factor`, keeping the point under `at` where it is.
    func zoom(by factor: Double, at: CGPoint) {
        let cam = manual ?? camera
        let zoom = min(max(cam.zoom * factor, 1), Self.maxZoom)
        let wx = (at.x - size.width / 2) / cam.zoom + cam.x
        let wy = (at.y - size.height / 2) / cam.zoom + cam.y
        let next = clamp(MapCamera(x: wx - (at.x - size.width / 2) / zoom, y: wy - (at.y - size.height / 2) / zoom, zoom: zoom))
        manual = next
        camera = next
    }

    func pan(dx: Double, dy: Double) {
        let cam = manual ?? camera
        let next = clamp(MapCamera(x: cam.x - dx / cam.zoom, y: cam.y - dy / cam.zoom, zoom: cam.zoom))
        manual = next
        camera = next
    }
}

/// Nodes and links a focus touches (both ways: an app's servers, a
/// server's apps), plus this Mac.
struct MapFocus {
    var links: Set<String>
    var nodes: Set<String>

    init?(_ scene: MapScene, _ target: MapTarget?) {
        guard let target else { return nil }
        links = []
        nodes = [MapScene.homeID]
        for link in scene.links {
            let hit = if case .app(let name) = target { link.app == name } else { link.to == target.nodeID }
            if hit {
                links.insert(link.id)
                nodes.insert(link.to)
            }
        }
        if case .app = target {} else { nodes.insert(target.nodeID) }
    }
}

/// The Live page's world map: arcs from this Mac to the countries its
/// servers are in (and the nearby edge beside it), packets flying as often
/// as real traffic flows, a camera that frames what's locked on.
struct LiveMapView: View {
    @Environment(\.palette) private var palette
    @Environment(\.privacy) private var privacy
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let edges: [NetEdge]
    let flagged: Set<String>
    let home: HomeLocation
    let capturing: Bool
    /// Width covered on the right by a floating dossier.
    var inset: Double = 0
    @Binding var target: MapTarget?
    @State private var sim = MapSimulation()
    @State private var zoomLevel = 1.0
    @State private var hovering: String?

    var body: some View {
        GeometryReader { geo in
            let scene = MapScene.world(size: geo.size, edges: edges, flagged: flagged, home: home)
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !WindowVisibility.shared.mainVisible)) { timeline in
                Canvas { context, size in
                    draw(&context, size: size, scene: scene, now: timeline.date.timeIntervalSinceReferenceDate)
                }
            }
            .overlay {
                MapInput(
                    onHover: { point in
                        let node = point.flatMap { sim.pick($0) }
                        sim.hover = node?.id
                        if hovering != node?.id { hovering = node?.id }
                        return node != nil
                    },
                    onClick: { point in
                        target = sim.pick(point).map(Self.target)
                    },
                    onPan: { dx, dy in
                        sim.pan(dx: dx, dy: dy)
                        zoomLevel = sim.camera.zoom
                    },
                    onZoom: { factor, point in
                        sim.zoom(by: factor, at: point)
                        zoomLevel = sim.camera.zoom
                    })
                .help(hovering.flatMap { id in scene.nodes.first { $0.id == id } }.map(hint) ?? "")
            }
            .overlay(alignment: .bottomLeading) { zoomControls(size: geo.size).padding(Space.md) }
            .overlay(alignment: .bottomTrailing) {
                Link("IP geolocation by DB-IP", destination: URL(string: "https://db-ip.com")!)
                    .font(.ui(.xxs)).foregroundStyle(palette.ink4.color).padding(Space.md)
                    .help("Where servers are registered, from DB-IP's free databases (CC BY 4.0), looked up on this Mac")
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("World map of connections")
            .accessibilityChildren {
                ForEach(scene.nodes) { node in
                    Button("Lock on \(node.label)") { target = Self.target(node) }
                }
            }
        }
        .onChange(of: target) { _, _ in
            sim.manual = nil
            zoomLevel = 1
        }
    }

    static func target(_ node: MapScene.Node) -> MapTarget {
        switch node.kind {
        case .home: .home
        case .nearby: .nearby
        case .country(let code): .country(code)
        }
    }

    private func hint(_ node: MapScene.Node) -> String {
        switch node.kind {
        case .home: "This Mac. Click to set its city."
        case .nearby: "Servers answering from close by: \(node.owners.prefix(3).joined(separator: ", "))"
        case .country: "\(node.label): \(node.owners.prefix(3).joined(separator: ", "))"
        }
    }

    /// The city search sits in the home dossier: keys go to it, not the map.
    private var typing: Bool { target == .home }

    private func zoomControls(size: CGSize) -> some View {
        HStack(spacing: 0) {
            IconButton("minus", help: "Zoom out (−)") {
                sim.zoom(by: 1 / 1.6, at: CGPoint(x: size.width / 2, y: size.height / 2))
                zoomLevel = sim.camera.zoom
            }
            .keyboardShortcut(typing ? nil : KeyboardShortcut("-", modifiers: []))
            .disabled(zoomLevel <= 1.01)
            Text(String(format: "%.1f×", zoomLevel)).font(.mono(.xxs)).monospacedDigit()
                .foregroundStyle(palette.ink3.color).frame(width: 40)
            IconButton("plus", help: "Zoom in (+). Pinch or scroll the wheel on the map; drag to pan.") {
                sim.zoom(by: 1.6, at: CGPoint(x: size.width / 2, y: size.height / 2))
                zoomLevel = sim.camera.zoom
            }
            .keyboardShortcut(typing ? nil : KeyboardShortcut("=", modifiers: []))
            .disabled(zoomLevel >= MapSimulation.maxZoom - 0.01)
            Rectangle().fill(palette.line.color).frame(width: 1, height: 16).padding(.horizontal, 2)
            IconButton("scope", help: "Fit the whole map (0)") {
                sim.manual = nil
                zoomLevel = 1
            }
            .keyboardShortcut(typing ? nil : KeyboardShortcut("0", modifiers: []))
        }
        .padding(2)
        .flatSurface(radius: Radius.md)
    }

    // MARK: Drawing

    private func draw(_ context: inout GraphicsContext, size: CGSize, scene: MapScene, now: TimeInterval) {
        let sim = sim
        sim.size = size
        if sim.sceneVersion < 0 || sim.scene.links.map(\.id) != scene.links.map(\.id) {
            sim.linkIndex = Dictionary(scene.links.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
            // Packets keep flying across a refresh; those on removed links land.
            sim.particles = sim.particles.compactMap { particle in
                guard particle.link < sim.scene.links.count, let index = sim.linkIndex[sim.scene.links[particle.link].id] else { return nil }
                var moved = particle
                moved.link = index
                return moved
            }
            sim.sceneVersion += 1
        }
        sim.scene = scene
        if sim.started == nil {
            sim.started = MapSimulation.introPlayed || reduceMotion ? now - MapSimulation.introSeconds : now
            MapSimulation.introPlayed = true
            sim.camera = MapCamera(x: size.width / 2, y: size.height / 2, zoom: 1)
        }
        let dt = min(0.1, max(0, now - sim.last))
        sim.last = now
        let key = target.map(\.nodeID) ?? ""
        if key != sim.lockKey {
            sim.lockKey = key
            sim.lockAt = now
        }
        let intro = min(1, (now - (sim.started ?? now)) / MapSimulation.introSeconds)
        let want = sim.manual ?? goal(scene, size: size)
        let k = reduceMotion ? 1 : 1 - exp(-dt * 5)
        sim.camera.x += (want.x - sim.camera.x) * k
        sim.camera.y += (want.y - sim.camera.y) * k
        sim.camera.zoom += (want.zoom - sim.camera.zoom) * k
        let cam = sim.camera

        var world = context
        world.translateBy(x: size.width / 2, y: size.height / 2)
        world.scaleBy(x: cam.zoom, y: cam.zoom)
        world.translateBy(x: -cam.x, y: -cam.y)
        drawField(&world, size: size, intro: intro, zoom: cam.zoom)
        let focus = MapFocus(scene, target ?? sim.hover.flatMap { id in scene.nodes.first { $0.id == id } }.map(Self.target))
        let fade = Self.easeOut((intro - 0.3) / 0.7)
        drawLinks(&world, scene: scene, focus: focus, zoom: cam.zoom, fade: fade)
        if !reduceMotion, intro >= 1 {
            emit(scene, dt: dt)
            drawParticles(&world, scene: scene, focus: focus, zoom: cam.zoom, dt: dt)
        }
        drawNodes(&world, scene: scene, focus: focus, zoom: cam.zoom, now: now, fade: fade)
        drawLabels(&context, scene: scene, focus: focus, fade: fade)
        if let target {
            drawLock(&context, scene: scene, target: target, progress: Self.easeOut((now - sim.lockAt) / MapSimulation.lockSeconds))
        }
    }

    static func easeOut(_ t: Double) -> Double { 1 - pow(1 - min(1, max(0, t)), 3) }

    /// Where the camera goes: the whole map, or framed on the target.
    private func goal(_ scene: MapScene, size: CGSize) -> MapCamera {
        let whole = MapCamera(x: size.width / 2, y: size.height / 2, zoom: 1)
        guard let hit = MapFocus(scene, target) else { return whole }
        let points = scene.nodes.filter { hit.nodes.contains($0.id) && ($0.kind != .home || target == .home) }.map(\.point)
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return whole }
        let pad = 70.0
        let room = size.width - inset
        let zoom = min(2, max(1, min(room / (maxX - minX + pad * 2), size.height / (maxY - minY + pad * 2))))
        // Shifted so the target sits in the part of the map left uncovered.
        return MapCamera(x: (minX + maxX) / 2 + inset / 2 / zoom, y: (minY + maxY) / 2, zoom: zoom)
    }

    private func drawField(_ context: inout GraphicsContext, size: CGSize, intro: Double, zoom: Double) {
        let projection = WorldProjection(size: size)
        let reveal = Self.easeOut(intro)
        var clipped = context
        clipped.clip(to: Path(CGRect(x: projection.x0, y: projection.y0 - 4, width: projection.width * reveal, height: projection.height + 8)))
        let hair = 1 / zoom
        // The grid fades out toward its ends, so the map has no box around it.
        let top = projection.project(GeoPoint(lat: projection.latMax, lon: 0))
        let bottom = projection.project(GeoPoint(lat: projection.latMin, lon: 0))
        let left = projection.project(GeoPoint(lat: 0, lon: -180))
        let right = projection.project(GeoPoint(lat: 0, lon: 180))
        func fading(_ tone: ColorValue, from start: CGPoint, to end: CGPoint) -> GraphicsContext.Shading {
            .linearGradient(Gradient(stops: [.init(color: tone.opacity(0).color, location: 0),
                                             .init(color: tone.color, location: 0.22),
                                             .init(color: tone.color, location: 0.78),
                                             .init(color: tone.opacity(0).color, location: 1)]),
                            startPoint: start, endPoint: end)
        }
        var meridians = Path()
        for lon in stride(from: -150.0, through: 150, by: 30) {
            meridians.move(to: projection.project(GeoPoint(lat: projection.latMax, lon: lon)))
            meridians.addLine(to: projection.project(GeoPoint(lat: projection.latMin, lon: lon)))
        }
        clipped.stroke(meridians, with: fading(palette.line, from: top, to: bottom), lineWidth: hair)
        var parallels = Path()
        for lat in [-30.0, 30, 60] {
            parallels.move(to: projection.project(GeoPoint(lat: lat, lon: -180)))
            parallels.addLine(to: projection.project(GeoPoint(lat: lat, lon: 180)))
        }
        clipped.stroke(parallels, with: fading(palette.line, from: left, to: right), lineWidth: hair)
        var equator = Path()
        equator.move(to: left)
        equator.addLine(to: right)
        clipped.stroke(equator, with: fading(palette.lineStrong, from: left, to: right),
                       style: StrokeStyle(lineWidth: hair, dash: [3 / zoom, 5 / zoom]))
        // Dots keep their size on screen while zooming: the grid opens up.
        let dot = max(1.1, WorldData.shared.step * projection.scale * 0.42) * pow(zoom, -0.45)
        clipped.opacity = 0.4
        if zoom < 1.02, let image = LandDots.image(size: size, dot: dot, color: palette.ink4) {
            // At rest: one bitmap instead of nine thousand squares a frame.
            clipped.draw(Image(decorative: image, scale: LandDots.scale), in: CGRect(origin: .zero, size: size))
        } else {
            clipped.fill(LandDots.path(size: size, dot: dot), with: .color(palette.ink4.color))
        }
    }

    private func drawLinks(_ context: inout GraphicsContext, scene: MapScene, focus: MapFocus?, zoom: Double, fade: Double) {
        for link in scene.links {
            let lit = focus?.links.contains(link.id) ?? false
            var alpha = link.active ? 0.38 : 0.14
            if focus != nil { alpha = lit ? 0.8 : 0.06 }
            var path = Path()
            path.move(to: link.segment.p0)
            path.addQuadCurve(to: link.segment.p1, control: link.segment.c)
            let tone = link.flagged ? palette.bad : lit ? palette.brand : palette.lineStrong
            context.stroke(path, with: .color(tone.opacity(alpha * fade).color), lineWidth: 1 / zoom)
        }
    }

    /// New packets for this frame: each link pays out what it owes.
    private func emit(_ scene: MapScene, dt: Double) {
        for (index, link) in scene.links.enumerated() {
            for out in [true, false] {
                let id = "\(link.id)|\(out)"
                var owed = (sim.credit[id] ?? 0)
                    + MapScene.emission(rate: out ? link.rateOut : link.rateIn, packets: link.packets, capturing: capturing) * dt
                while owed >= 1, sim.particles.count < MapSimulation.maxParticles {
                    sim.particles.append(.init(link: index, out: out, t: 0))
                    owed -= 1
                }
                sim.credit[id] = min(owed, 3)
            }
        }
    }

    private func drawParticles(_ context: inout GraphicsContext, scene: MapScene, focus: MapFocus?, zoom: Double, dt: Double) {
        let head = 1.3 / zoom
        // One path per colour and brightness: a few draw calls for hundreds of packets.
        var trails: [Int: Path] = [:]
        var heads: [Int: Path] = [:]
        sim.particles = sim.particles.compactMap { particle in
            guard particle.link < scene.links.count else { return nil }
            let link = scene.links[particle.link]
            var p = particle
            p.t += dt / link.travel
            guard p.t < 1 else { return nil }
            let t = p.out ? p.t : 1 - p.t
            let point = link.segment.at(t)
            let trail = link.segment.at(p.out ? max(0, t - 0.035) : min(1, t + 0.035))
            let dim = focus != nil && !(focus?.links.contains(link.id) ?? false)
            let tone = (link.flagged && p.out ? 2 : p.out ? 0 : 1) + (dim ? 3 : 0)
            trails[tone, default: Path()].move(to: trail)
            trails[tone]?.addLine(to: point)
            heads[tone, default: Path()].addEllipse(in: CGRect(x: point.x - head, y: point.y - head, width: head * 2, height: head * 2))
            return p
        }
        for (tone, path) in trails {
            let color = [palette.brand, palette.ok, palette.bad][tone % 3].opacity(tone >= 3 ? 0.08 : 0.9)
            context.stroke(path, with: .color(color.color), lineWidth: 1 / zoom)
            if let dots = heads[tone] { context.fill(dots, with: .color(color.color)) }
        }
    }

    private func circle(_ p: CGPoint, _ r: Double) -> Path {
        Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
    }

    private func drawNodes(_ context: inout GraphicsContext, scene: MapScene, focus: MapFocus?, zoom: Double, now: Double, fade: Double) {
        for node in scene.nodes {
            let dim = focus != nil && !(focus?.nodes.contains(node.id) ?? false)
            let alpha = (dim ? 0.18 : 1) * fade
            let r = node.r * MapSimulation.nodeScale(zoom)
            if node.kind == .home {
                // This Mac, breathing: alive, not alarmed.
                let pulse = 1 + sin(now / 0.9) * 0.05
                context.stroke(circle(node.point, 14 * pulse / zoom), with: .color(palette.brand.opacity(alpha).color), lineWidth: 1 / zoom)
                context.fill(circle(node.point, 4 / zoom), with: .color(palette.brand.opacity(alpha).color))
                continue
            }
            if node.flagged {
                // A ring spreading out of a flagged node, over and over.
                let wave = (now / 1.8).truncatingRemainder(dividingBy: 1)
                context.stroke(circle(node.point, r + (4 + wave * 16) / zoom),
                               with: .color(palette.bad.opacity((1 - wave) * alpha * 0.9).color), lineWidth: 1 / zoom)
            }
            if node.kind == .nearby {
                // The nearby edge: a ring like home's, it lives next door.
                context.fill(circle(node.point, r), with: .color(palette.bg.opacity(alpha).color))
                context.stroke(circle(node.point, r), with: .color((node.flagged ? palette.bad : palette.brand).opacity(alpha).color),
                               lineWidth: 1.5 / zoom)
                continue
            }
            let tone = node.flagged ? palette.bad : node.active ? palette.brand : palette.ink3
            context.fill(circle(node.point, r), with: .color(tone.opacity(node.active || node.flagged ? alpha : alpha * 0.7).color))
        }
    }

    /// Names beside the nodes. A label that would overlap one already drawn
    /// is left out; hovering a node always shows its own.
    private func drawLabels(_ context: inout GraphicsContext, scene: MapScene, focus: MapFocus?, fade: Double) {
        let zoom = sim.camera.zoom
        let hovered = sim.hover
        func rank(_ node: MapScene.Node) -> Int {
            if node.id == hovered { return 0 }
            if focus?.nodes.contains(node.id) == true { return node.kind == .home ? 2 : 1 }
            if node.kind == .home { return 3 }
            return node.kind == .nearby ? 4 : 5 + (node.active ? 0 : 1)
        }
        let order = scene.nodes.filter { node in
            if node.id == hovered { return true }
            if let focus { return focus.nodes.contains(node.id) }
            return node.pinned || zoom >= 1.6
        }.sorted { (rank($0), -$0.r) < (rank($1), -$1.r) }
        var taken: [CGRect] = []
        for node in order {
            let lit = focus?.nodes.contains(node.id) ?? false
            let at = sim.toScreen(node.point)
            let showSub = !node.sub.isEmpty && (node.id == hovered || lit || node.kind == .nearby)
            let strong = !node.isCountry || node.id == hovered || lit
            let tone = node.flagged ? palette.bad : node.kind == .home || strong ? palette.ink2 : palette.ink3
            let name = text(&context, privacy && node.kind == .home ? "This Mac" : node.label,
                            size: node.isCountry ? 11 : 12, weight: node.kind == .home ? .medium : .regular, tone: tone)
            let sub = text(&context, node.sub, size: 11, weight: .regular, tone: palette.ink4)
            let nameSize = name.measure(in: CGSize(width: 400, height: 40))
            let subSize = showSub ? sub.measure(in: CGSize(width: 400, height: 40)) : .zero
            let gap = node.r * MapSimulation.nodeScale(zoom) * zoom * 1.4 + 8
            let width = max(nameSize.width, subSize.width), height = showSub ? 27.0 : 14.0
            // Right of the node, else left of it; a label with no room is left out.
            let right = CGRect(x: at.x + gap, y: at.y - height / 2, width: width, height: height)
            let left = CGRect(x: at.x - gap - width, y: at.y - height / 2, width: width, height: height)
            let free = { (box: CGRect) in !taken.contains { $0.intersects(box) } }
            let onLeft = !free(right) && free(left)
            if node.id != hovered, !free(right), !free(left) { continue }
            taken.append(onLeft ? left : right)
            let x = onLeft ? at.x - gap : at.x + gap
            let anchor: UnitPoint = onLeft ? .trailing : .leading
            var layer = context
            layer.opacity = fade
            halo(&layer, name, at: CGPoint(x: x, y: at.y - (showSub ? 6 : 0)), anchor: anchor)
            if showSub { halo(&layer, sub, at: CGPoint(x: x, y: at.y + 7), anchor: anchor) }
        }
    }

    private func text(_ context: inout GraphicsContext, _ string: String, size: Double, weight: Font.Weight,
                      tone: ColorValue) -> GraphicsContext.ResolvedText {
        if sim.texts.count > 400 {
            sim.texts = [:]
        }
        let key = "\(string)|\(size)|\(String(describing: weight))"
        var resolved = sim.texts[key] ?? context.resolve(Text(string).font(.system(size: size, weight: weight)))
        sim.texts[key] = resolved
        resolved.shading = .color(tone.color)
        return resolved
    }

    /// Text with a ring of the map's colour around it, so it reads over
    /// arcs and dots: offset copies, cheaper than a blur every frame.
    private func halo(_ context: inout GraphicsContext, _ text: GraphicsContext.ResolvedText, at: CGPoint, anchor: UnitPoint) {
        var ring = text
        ring.shading = .color(palette.surface.color)
        for (dx, dy) in [(-1.0, 0.0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, 1), (-1, 1), (1, -1)] {
            context.draw(ring, at: CGPoint(x: at.x + dx, y: at.y + dy), anchor: anchor)
        }
        context.draw(text, at: at, anchor: anchor)
    }

    /// A ring settling onto the target, and its name above it.
    private func drawLock(_ context: inout GraphicsContext, scene: MapScene, target: MapTarget, progress: Double) {
        let zoom = sim.camera.zoom
        let nodes: [MapScene.Node]
        if case .app(let name) = target {
            nodes = scene.nodes.filter { $0.kind != .home && $0.apps.contains(name) }
        } else {
            nodes = scene.nodes.filter { $0.id == target.nodeID }
        }
        let tone = nodes.contains(where: \.flagged) ? palette.bad : palette.brand
        for node in nodes {
            let at = sim.toScreen(node.point)
            let half = (node.r * MapSimulation.nodeScale(zoom) * zoom + 9) * (1 + 1.4 * (1 - progress))
            context.stroke(circle(at, half * 0.8), with: .color(tone.opacity(progress).color), lineWidth: 1.5)
        }
        // A place is already labelled; an app has no node of its own, so it's named here.
        guard case .app(let app) = target, let first = nodes.first else { return }
        let at = sim.toScreen(first.point)
        let half = first.r * MapSimulation.nodeScale(zoom) * zoom + 9
        let name = privacy ? "An app" : app
        let extra = nodes.count > 1 ? " · \(nodes.count) places" : ""
        var layer = context
        layer.opacity = progress
        halo(&layer, text(&context, name + extra, size: 12, weight: .semibold, tone: tone),
             at: CGPoint(x: at.x - half, y: at.y - half - 6), anchor: .bottomLeading)
    }
}

extension MapScene.Node {
    var isCountry: Bool { if case .country = kind { true } else { false } }
}

/// The land grid as one path of squares, built once per size and dot.
@MainActor
enum LandDots {
    private static var cache: (key: String, path: Path)?

    static func path(size: CGSize, dot: Double) -> Path {
        let key = "\(Int(size.width))x\(Int(size.height))@\(Int(dot * 20))"
        if let cache, cache.key == key { return cache.path }
        let projection = WorldProjection(size: size)
        var path = Path()
        for cell in WorldData.shared.landCells {
            let p = projection.project(cell)
            path.addRect(CGRect(x: p.x - dot / 2, y: p.y - dot / 2, width: dot, height: dot))
        }
        cache = (key, path)
        return path
    }

    static let scale = 2.0
    private static var bitmap: (key: String, image: CGImage)?

    /// The same squares, rasterised once at Retina scale.
    static func image(size: CGSize, dot: Double, color: ColorValue) -> CGImage? {
        let key = "\(Int(size.width))x\(Int(size.height))@\(Int(dot * 20))|\(color.r),\(color.g),\(color.b),\(color.a)"
        if let bitmap, bitmap.key == key { return bitmap.image }
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: Double(height))
        context.scaleBy(x: scale, y: -scale)
        context.setFillColor(color.nsColor.cgColor)
        context.addPath(path(size: size, dot: dot).cgPath)
        context.fillPath()
        guard let image = context.makeImage() else { return nil }
        bitmap = (key, image)
        return image
    }
}

/// The map's pointer and gestures, the Mac way: hover shows names, a click
/// locks on, drag pans, a two-finger scroll pans, pinch or the mouse wheel
/// zooms around the pointer, double-click zooms in (⌥ out).
struct MapInput: NSViewRepresentable {
    var onHover: (CGPoint?) -> Bool
    var onClick: (CGPoint) -> Void
    var onPan: (Double, Double) -> Void
    var onZoom: (Double, CGPoint) -> Void

    func makeNSView(context: Context) -> InputView {
        let view = InputView()
        view.input = self
        return view
    }

    func updateNSView(_ view: InputView, context: Context) { view.input = self }

    final class InputView: NSView {
        var input: MapInput?
        private var down: CGPoint?
        private var dragged = false
        private var overNode = false

        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                           owner: self))
        }

        private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

        override func mouseMoved(with event: NSEvent) {
            overNode = input?.onHover(point(event)) ?? false
            (overNode ? NSCursor.pointingHand : NSCursor.openHand).set()
        }

        override func mouseExited(with event: NSEvent) {
            _ = input?.onHover(nil)
            NSCursor.arrow.set()
        }

        override func mouseDown(with event: NSEvent) {
            down = point(event)
            dragged = false
            if event.clickCount == 2 { input?.onZoom(event.modifierFlags.contains(.option) ? 0.5 : 2, point(event)) }
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = down else { return }
            let now = point(event)
            if !dragged, hypot(now.x - start.x, now.y - start.y) < 4 { return }
            dragged = true
            NSCursor.closedHand.set()
            input?.onPan(event.deltaX, event.deltaY)
        }

        override func mouseUp(with event: NSEvent) {
            if !dragged, event.clickCount < 2 { input?.onClick(point(event)) }
            down = nil
            dragged = false
            (overNode ? NSCursor.pointingHand : NSCursor.openHand).set()
        }

        override func scrollWheel(with event: NSEvent) {
            if event.hasPreciseScrollingDeltas {
                input?.onPan(event.scrollingDeltaX, event.scrollingDeltaY)
            } else {
                input?.onZoom(exp(event.scrollingDeltaY * 0.08), point(event))
            }
        }

        override func magnify(with event: NSEvent) {
            input?.onZoom(1 + event.magnification, point(event))
        }
    }
}
