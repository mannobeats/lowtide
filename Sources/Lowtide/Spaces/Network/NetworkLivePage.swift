import AppKit
import LowtideKit
import SwiftUI

/// Network → Live: who's online and whether any of it needs a look, the
/// world map with the last hour under it, and every connection.
struct NetworkLivePage: View {
    @Environment(\.palette) private var palette
    @Environment(\.privacy) private var privacy
    @Bindable private var model = NetworkModel.shared
    @State private var target: MapTarget?
    @State private var replay: Millis?
    @State private var frame: NetFrameView?
    private var app = AppModel.shared

    /// Wide enough for the map and a side column; narrower, they stack.
    private static let sideBySide = 760.0

    var body: some View {
        Group {
            if model.overview.ready {
                GeometryReader { geo in page(geo.size) }
            } else {
                ScanningState(title: "Listening to every connection on this Mac…")
            }
        }
        .watchesNetwork()
        .onAppear(perform: takePending)
        .onChange(of: model.pendingTarget) { _, _ in takePending() }
        .task(id: replay.map { $0 / 3_000 }) {
            guard let replay else { frame = nil; return }
            let engine = model.engine
            frame = await Task.detached { engine.frame(at: replay) }.value
        }
        .background {
            // Escape steps back one level: the lock, the replay, full screen.
            if target != nil || replay != nil || app.immersive {
                Button("Back") {
                    if target != nil { target = nil } else if replay != nil { replay = nil } else { toggleFullScreen() }
                }
                .keyboardShortcut(.cancelAction)
                .hidden()
            }
        }
    }

    private func takePending() {
        guard let pending = model.pendingTarget else { return }
        model.pendingTarget = nil
        model.liveView = .map
        target = pending
    }

    private func lock(_ name: String) {
        model.liveView = .map
        target = .app(name)
    }

    // MARK: Layout

    /// The map fills the page edge to edge, the summary and the controls sit
    /// on it, and the side column is a flush pane on the right behind a
    /// hairline (hidden with ⌥⌘0).
    /// Connections trade the floating parts for one slim row over the list.
    private func page(_ size: CGSize) -> some View {
        let wide = size.width >= Self.sideBySide
        return Group {
            switch model.liveView {
            case .map:
                if wide {
                    stage(wide: true, height: size.height)
                } else {
                    ScrollView { stage(wide: false, height: size.height) }
                }
            case .connections:
                VStack(spacing: 0) {
                    HStack(spacing: Space.md) {
                        summary
                        Spacer(minLength: Space.md)
                        controls(side: false)
                    }
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.sm)
                    .hairline(.bottom)
                    ConnectionsView(onLock: lock)
                }
            }
        }
    }

    private var title: String {
        let flagged = model.flaggedApps
        let online = model.overview.apps.count
        return online == 0 ? "Nothing is online right now"
            : flagged.isEmpty ? "\(LowtideFormat.count(online, "app")) online, all behaving"
            : "\(LowtideFormat.count(online, "app")) online · \(flagged.count) \(flagged.count == 1 ? "needs" : "need") a look"
    }

    /// One line of numbers under the title; the full sentence is its tooltip.
    private var detail: (short: String, full: String) {
        let summary = model.summary
        let short = ["\(LowtideFormat.bytes(summary.bytesMoved)) in \(summary.minutes) min",
                     LowtideFormat.count(summary.servers, "server"), NetFormat.countries(summary.countries),
                     model.link.vpn ? "VPN" : nil, model.overview.learning ? "learning" : nil]
            .compactMap { $0 }.joined(separator: " · ")
        let full = ["\(LowtideFormat.bytes(summary.bytesMoved)) moved in the last \(summary.minutes) min across "
            + "\(LowtideFormat.count(summary.servers, "server")) in \(NetFormat.countries(summary.countries)).",
            model.link.vpn ? "Traffic goes through a VPN tunnel." : nil,
            model.overview.learning ? "Still learning what's normal for this Mac." : nil].compactMap { $0 }.joined(separator: " ")
        return (short, full)
    }

    /// The page's answer, small: the sentence, the numbers and the one
    /// action, straight on the map in place of a full hero.
    private var summary: some View {
        let flagged = model.flaggedApps
        return HStack(spacing: Space.lg) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    StatusDot(tone: flagged.isEmpty ? .ok : .warn, pulsing: !flagged.isEmpty)
                    Text(title).font(.ui(.base, .semibold)).foregroundStyle(palette.ink.color)
                        .contentTransition(.numericText())
                }
                Text(detail.short).font(.ui(.xs)).monospacedDigit().foregroundStyle(palette.ink3.color)
            }
            .lineLimit(1)
            .help(detail.full)
            if let worst = flagged.first {
                Button("Review \(worst.name)") { lock(worst.name) }.buttonStyle(.lowtide(.primary, size: .small))
            } else {
                CaptureButton()
            }
        }
        .animation(Motion.base, value: title)
    }

    /// Map or Connections, the alert sound, the side column and full screen.
    private func controls(side: Bool) -> some View {
        HStack(spacing: 2) {
            Segmented($model.liveView, [(.map, "Map"), (.connections, "Connections")])
                .padding(.trailing, Space.xs)
            IconButton(model.ping ? "speaker.wave.2" : "speaker.slash", help: model.ping ? "Alert sound on: click to mute" : "Play a sound on new events",
                       active: model.ping) {
                model.ping.toggle()
                if model.ping { NetworkSound.ping(alert: true) }
            }
            if side {
                IconButton("sidebar.right", help: model.sideHidden ? "Show the side column (⌥⌘0)" : "Hide the side column (⌥⌘0)",
                           active: !model.sideHidden) {
                    withAnimation(Motion.base) { model.sideHidden.toggle() }
                }
                .keyboardShortcut("0", modifiers: [.command, .option])
            }
            IconButton(app.immersive ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                       help: app.immersive ? "Leave full screen (⇧⌘F)" : "Full screen: only the map (⇧⌘F)", action: toggleFullScreen)
                .keyboardShortcut("f", modifiers: [.command, .shift])
        }
    }

    private func toggleFullScreen() {
        (NSApp.keyWindow ?? NSApp.windows.first(where: WindowRouter.isMain))?.toggleFullScreen(nil)
    }

    // MARK: Stage

    private var edges: [NetEdge] { replay != nil ? frame?.edges ?? [] : model.overview.edges }

    private func stage(wide: Bool, height: Double) -> some View {
        // The dossier floats on the map when there's no side column for it.
        let floating = target != nil && (!wide || model.sideHidden)
        return Group {
            if wide {
                HStack(spacing: 0) {
                    mapStage(floating: floating)
                    if !model.sideHidden {
                        side
                            .frame(width: height > 760 ? 360 : 320)
                            .hairline(.leading)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .frame(height: height)
            } else {
                VStack(spacing: 0) {
                    mapStage(floating: floating).frame(height: max(420, height * 0.62))
                    if !floating { side.frame(height: 520).hairline(.top) }
                }
            }
        }
        .animation(Motion.base, value: target)
        .animation(Motion.base, value: model.sideHidden)
    }

    @ViewBuilder
    private var side: some View {
        if let target {
            Dossier(target: target, edges: edges, floating: false, onClose: { self.target = nil }, onLock: { self.target = $0 })
        } else {
            ScrollView {
                LiveSide(overview: model.overview, flagged: model.flaggedApps, onLock: lock)
            }
        }
    }

    /// The map edge to edge on the page's own canvas with the timeline under
    /// it; the summary at the top left and the controls at the top right sit
    /// on it flat, without cards.
    private func mapStage(floating: Bool) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                LiveMapView(edges: edges, flagged: Set(model.flaggedApps.map(\.name)), home: model.home,
                            capturing: model.overview.capture.running && replay == nil,
                            inset: floating ? dossierWidth + 12 : 0, target: $target)
                // On the map itself, no cards: one plane with the page.
                HStack(alignment: .center, spacing: Space.md) {
                    summary
                    Spacer(minLength: Space.md)
                    if !floating { controls(side: true) }
                }
                .padding(.horizontal, Space.lg)
                .padding(.top, Space.md)
                if let replay {
                    let at = frame?.t ?? replay
                    Text("Replaying \(NetFormat.clock(at)), \(max(1, Int((Double(Millis.now - at) / 60_000).rounded()))) min ago")
                        .font(.ui(.xs)).foregroundStyle(palette.ink2.color)
                        .padding(.horizontal, Space.md).padding(.vertical, 5)
                        .flatSurface(radius: 999)
                        .padding(.top, 64)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
                if floating, let target {
                    Dossier(target: target, edges: edges, floating: true, onClose: { self.target = nil }, onLock: { self.target = $0 })
                        .padding(Space.md)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .clipped()
            LiveTimeline(timeline: model.timeline, replay: $replay, onLock: lock)
        }
    }
}
