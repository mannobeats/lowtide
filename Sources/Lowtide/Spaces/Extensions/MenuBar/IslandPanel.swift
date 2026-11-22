import AppKit
import LowtideKit
import SwiftUI

/// Where the notch is, in AppKit points. Without a notch, a pretend one
/// hangs from the top middle of the main screen.
struct IslandGeometry: Equatable {
    var frame: CGRect
    /// A real notch, not the pretend one.
    var real: Bool
    static let notchlessWidth: CGFloat = 190

    static func current() -> IslandGeometry? {
        let notched = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
        guard let screen = notched ?? NSScreen.main else { return nil }
        let full = screen.frame
        if notched != nil, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let height = screen.safeAreaInsets.top
            return IslandGeometry(frame: CGRect(x: left.maxX, y: full.maxY - height, width: right.minX - left.maxX, height: height),
                                  real: true)
        }
        let bar = full.maxY - screen.visibleFrame.maxY
        let height = bar > 0 ? bar : 24
        return IslandGeometry(frame: CGRect(x: full.minX + (full.width - notchlessWidth) / 2, y: full.maxY - height,
                                            width: notchlessWidth, height: height), real: false)
    }

    /// The same frame from the top of the primary screen, as Quartz has it.
    var quartzX: ClosedRange<Double> { frame.minX...frame.maxX }
}

/// The Island, an optional extra: a black shape that grows out of the notch
/// when you point at it, holding the icons you put there and live stats.
/// Icons pinned beside the notch stay out as two small ears. The pointer is
/// watched by polling its position, which needs no permission (a global
/// event monitor would).
final class IslandPanel {
    static let shared = IslandPanel()
    /// How long the pointer rests on the notch before it opens, and how long
    /// it may stray before it closes.
    static let hover: Duration = .milliseconds(140)
    static let away: TimeInterval = 0.38
    /// The view's closing animation.
    static let shrink: Duration = .milliseconds(220)

    let model = IslandModel()
    private var panel: NSPanel?
    private var watcher: Task<Void, Never>?
    private var feed: Task<Void, Never>?

    func configure(_ on: Bool) {
        watcher?.cancel()
        watcher = nil
        if on {
            watcher = Task { await watch() }
        } else {
            model.open = false
            panel?.orderOut(nil)
            panel = nil
        }
    }

    private func makePanel() -> NSPanel {
        if let panel { return panel }
        let panel = HUDPanel(contentRect: CGRect(x: 0, y: 0, width: 400, height: 40))
        // Above the menu bar's icons (`kCGStatusWindowLevel` is 25), below
        // the menus they open.
        panel.level = NSWindow.Level(rawValue: 26)
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)
        // In a plain container that never sizes the window, and blind to the
        // notch's safe area: otherwise the two resize each other in a loop
        // AppKit ends by aborting.
        let host = HUDHostingView(rootView: IslandView(model: model))
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.autoresizingMask = [.width, .height]
        let container = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        host.frame = container.bounds
        container.addSubview(host)
        panel.contentView = container
        self.panel = panel
        return panel
    }

    /// Sizes and shows the window for the current state. Closed it is
    /// exactly the notch and its ears, so it never covers a menu bar icon;
    /// open it is centred under the notch.
    func place() {
        guard let g = model.geometry else { return }
        let size = model.size
        if !model.open && !model.lingering && size.left + size.right <= 0 {
            panel?.orderOut(nil)
            return
        }
        let panel = makePanel()
        let notch = g.frame
        let frame: CGRect
        if model.open || model.lingering {
            let height = max(size.height, notch.height)
            frame = CGRect(x: notch.midX - size.width / 2, y: notch.maxY - height, width: size.width, height: height)
        } else {
            frame = CGRect(x: notch.minX - size.left, y: notch.minY, width: notch.width + size.left + size.right, height: notch.height)
        }
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    func layoutChanged() { place() }

    func open() {
        guard !model.open else { return }
        model.error = nil
        model.lingering = true
        withAnimation(.spring(duration: 0.28, bounce: 0.2)) { model.open = true }
        place()
        feed?.cancel()
        feed = Task {
            async let icons: Void = MenuBarManager.shared.watch(every: .seconds(3))
            async let stats: Void = model.sampleStats()
            _ = await (icons, stats)
        }
    }

    /// Shrinks back into the notch, after the view's animation.
    func close() {
        guard model.open else { return }
        feed?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) { model.open = false }
        Task {
            try? await Task.sleep(for: Self.shrink)
            guard !self.model.open else { return }
            self.model.lingering = false
            self.place()
        }
    }

    private func watch() async {
        var resting: Date?
        var away: Date?
        var measured = Date.distantPast
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(60))
            // Screens come and go (a lid closes, a display plugs in).
            if Date().timeIntervalSince(measured) > 2 {
                measured = Date()
                let fresh = IslandGeometry.current()
                var room = Double.greatestFiniteMagnitude
                if let fresh {
                    let right = Double(fresh.frame.maxX)
                    // macOS 27 has no window per icon: Accessibility says
                    // where the first one (or «) starts.
                    let edges = await Task.detached {
                        MenuBarManager.overflowing
                            ? MenuBarAX.items(quick: true).map(\.x).filter { $0 >= right }.sorted()
                            : MenuBarPointer.statusEdges(rightOf: right)
                    }.value
                    if let first = edges.first { room = first - right }
                }
                let changed = fresh != model.geometry || abs(model.room - room) > 2
                model.geometry = fresh
                model.room = room
                if changed { place() }
            }
            guard let g = model.geometry else { continue }
            let at = NSEvent.mouseLocation
            if model.open {
                let size = model.size
                let rect = CGRect(x: g.frame.midX - size.width / 2, y: g.frame.maxY - size.height, width: size.width, height: size.height)
                if rect.insetBy(dx: -10, dy: -10).contains(at) {
                    away = nil
                } else if Date().timeIntervalSince(away ?? { away = Date(); return Date() }()) > Self.away {
                    away = nil
                    close()
                }
            } else if g.frame.insetBy(dx: -2, dy: -2).contains(at) {
                let since = resting ?? Date()
                resting = since
                if Date().timeIntervalSince(since) > 0.14 {
                    resting = nil
                    open()
                }
            } else {
                resting = nil
            }
        }
    }
}

@Observable
final class IslandModel {
    var open = false
    /// The window keeps its open size while the shape shrinks back.
    var lingering = false
    var geometry: IslandGeometry?
    /// Room right of the notch before the first menu bar icon.
    var room = Double.greatestFiniteMagnitude
    var error: String?
    var stats = IslandStats()

    var ears: (left: [IslandPin], right: [IslandPin]) {
        IslandLayout.ears(MenuBarManager.shared.prefs.pins, room: room)
    }

    var size: IslandLayout.Size {
        let prefs = MenuBarManager.shared.prefs
        let notch = geometry?.frame.size ?? CGSize(width: 200, height: 32)
        let ears = ears
        return IslandLayout.size(notchWidth: notch.width, notchHeight: notch.height, left: ears.left.count,
                                 right: ears.right.count, tiles: prefs.pins.count, stats: prefs.stats)
    }

    /// Live numbers, read only while the Island is open.
    func sampleStats() async {
        guard MenuBarManager.shared.prefs.stats else { return }
        var sampler = IslandSampler()
        while !Task.isCancelled {
            stats = sampler.sample()
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

/// The Island window: the notch's ears while closed; open, the icons put
/// there and live stats.
struct IslandView: View {
    let model: IslandModel
    private var manager = MenuBarManager.shared

    init(model: IslandModel) { self.model = model }

    var body: some View {
        if let g = model.geometry {
            let size = model.size
            let ears = model.ears
            let notch = g.frame.size
            let closedWidth = notch.width + size.left + size.right
            let shoulder = model.open ? IslandLayout.shoulder : 0
            let shapeWidth = model.open ? size.width : closedWidth
            let height = model.open ? size.height : notch.height
            ZStack(alignment: .top) {
                IslandShape(shoulder: shoulder, radius: model.open ? 24 : 10)
                    .fill(.black)
                    .shadow(color: .black.opacity(model.open ? 0.35 : 0), radius: 15, y: 10)
                VStack(spacing: 0) {
                    // The gap sits exactly under the notch, however many
                    // icons each ear holds.
                    HStack(spacing: 0) {
                        Ear(pins: ears.left, side: .left, width: size.left)
                        Color.clear.frame(width: notch.width)
                        Ear(pins: ears.right, side: .right, width: size.right)
                    }
                    .padding(.leading, model.open ? max(0, (shapeWidth - notch.width) / 2 - shoulder - size.left) : 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: notch.height)
                    if model.open {
                        body(size: size, notchHeight: notch.height)
                            .transition(.opacity.animation(.easeOut(duration: 0.15).delay(0.075)))
                    }
                }
                .padding(.horizontal, shoulder)
                .clipped()
            }
            .frame(width: shapeWidth, height: height)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
            .ignoresSafeArea()
        }
    }

    private func body(size: IslandLayout.Size, notchHeight: Double) -> some View {
        let pins = manager.prefs.pins
        return VStack(spacing: 0) {
            VStack(spacing: 0) {
                if !pins.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(IslandLayout.tile), spacing: 0),
                                             count: min(pins.count, IslandLayout.maxColumns)), spacing: 0) {
                        ForEach(pins) { pin in Tile(pin: pin) { model.error = $0 } }
                    }
                } else if !manager.prefs.stats {
                    Text("Right-click an icon in the bar under the chevron, or in Extensions, to add it here.")
                        .font(.ui(.xs)).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.center)
                        .padding(.horizontal, Space.xl)
                }
                if manager.prefs.stats { IslandStatsRow(stats: model.stats) }
            }
            .frame(maxHeight: .infinity)
            .padding(.top, Space.sm)
            HStack(spacing: Space.xs) {
                Text(model.error ?? "").lineLimit(1).truncationMode(.tail).help(model.error ?? "")
                Spacer(minLength: 0)
                Button { manager.showSettings() } label: {
                    Image(systemName: "gearshape").font(.ui(.xs))
                }
                .buttonStyle(ShelfButtonStyle())
                .help("Menu bar settings")
                .accessibilityLabel("Menu bar settings")
            }
            .font(.ui(.xxs))
            .foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, Space.md)
            .frame(height: IslandLayout.footer)
        }
        .frame(height: size.height - notchHeight)
    }
}

/// Icons pinned beside the notch.
private struct Ear: View {
    let pins: [IslandPin]
    let side: IslandPin.Side
    let width: Double

    var body: some View {
        HStack(spacing: 2) {
            ForEach(pins) { pin in
                Button { MenuBarManager.shared.open(pin.key) } label: {
                    MenuBarItemIcon(key: pin.key, appPath: pin.appPath, size: 18, onDark: true).frame(width: 24, height: 22)
                }
                .buttonStyle(ShelfButtonStyle())
                .help(pin.name)
            }
        }
        .padding(side == .left ? .leading : .trailing, Space.sm)
        .padding(side == .left ? .trailing : .leading, 6)
        .frame(width: width, alignment: side == .left ? .trailing : .leading)
    }
}

/// An icon put in the Island; its menu needs the live icon, else it can only leave.
private struct Tile: View {
    let pin: IslandPin
    let failed: (String) -> Void
    @State private var hovering = false
    private var manager = MenuBarManager.shared

    init(pin: IslandPin, failed: @escaping (String) -> Void) {
        self.pin = pin
        self.failed = failed
    }

    var body: some View {
        let name = pin.name
        Button { manager.open(pin.key, failed: failed) } label: {
            VStack(spacing: 6) {
                MenuBarItemIcon(key: pin.key, appPath: pin.appPath, size: 28, onDark: true)
                Text(name).font(.ui(.xxs)).lineLimit(1).truncationMode(.tail).padding(.horizontal, Space.xs)
            }
            .foregroundStyle(.white.opacity(hovering ? 1 : 0.75))
            .frame(width: IslandLayout.tile, height: IslandLayout.tile)
            .background(.white.opacity(hovering ? 0.1 : 0), in: .rect(cornerRadius: Radius.lg))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(pin.label.isEmpty ? pin.app : pin.label)
        .contextMenu {
            if let entry = manager.entry(pin.key) {
                MenuBarItemMenu(entry: entry, failed: failed)
            } else {
                Button("Remove from the Island") { manager.unpin(pin.key) }
            }
        }
    }
}

private struct IslandStatsRow: View {
    let stats: IslandStats

    var body: some View {
        HStack(spacing: Space.lg) {
            stat("cpu", stats.cpu.map(LowtideFormat.percent) ?? "–", help: "CPU")
            stat("memorychip", stats.memory.map(LowtideFormat.percent) ?? "–", help: "Memory in use")
            stat("arrow.down", LowtideFormat.rate(stats.rateIn), help: "Download")
            stat("arrow.up", LowtideFormat.rate(stats.rateOut), help: "Upload")
            if let battery = stats.battery { stat("battery.75percent", LowtideFormat.percent(battery), help: "Battery") }
        }
        .font(.ui(.xs))
        .monospacedDigit()
        .foregroundStyle(.white.opacity(0.8))
        .frame(height: IslandLayout.stats)
    }

    private func stat(_ symbol: String, _ value: String, help: String) -> some View {
        HStack(spacing: Space.xs) {
            Image(systemName: symbol).font(.ui(.xxs)).foregroundStyle(.white.opacity(0.45))
            Text(value).contentTransition(.numericText())
        }
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(help) \(value)")
    }
}

/// The Island's outline: square on top, round below, and when open, concave
/// shoulders where it meets the menu bar, so it grows out of the notch.
nonisolated struct IslandShape: Shape {
    var shoulder: CGFloat
    var radius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulder, radius) }
        set { shoulder = newValue.first; radius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let s = shoulder, w = rect.width, h = rect.height
        let r = min(radius, (w - 2 * s) / 2, h)
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addQuadCurve(to: CGPoint(x: s, y: s), control: CGPoint(x: s, y: 0))
        path.addLine(to: CGPoint(x: s, y: h - r))
        path.addQuadCurve(to: CGPoint(x: s + r, y: h), control: CGPoint(x: s, y: h))
        path.addLine(to: CGPoint(x: w - s - r, y: h))
        path.addQuadCurve(to: CGPoint(x: w - s, y: h - r), control: CGPoint(x: w - s, y: h))
        path.addLine(to: CGPoint(x: w - s, y: s))
        path.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - s, y: 0))
        path.closeSubpath()
        return path
    }
}
