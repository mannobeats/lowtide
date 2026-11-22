import AppKit
import Metal
import QuartzCore

/// Extra brightness for XDR displays. A click-through window covers the
/// built-in screen with a Metal layer of "brighter than white" (EDR) pixels
/// in multiply mode: the multiply scales everything beneath by the same
/// factor, into the range the panel reserves for HDR. Off, the windows are
/// gone and the screen is untouched.
///
/// macOS only raises the backlight while extended-range content keeps being
/// presented, and takes it back about a second after the last present. So a
/// one-pixel plain EDR window (the multiply layer alone doesn't reliably
/// engage the headroom) and the overlay both present every 250 ms, the
/// factor stays within what the panel sustains, and it moves a small step
/// per tick: a grant that wobbles under HDR video drifts instead of flashing.
@MainActor
public final class XDRBoost {
    public static let shared = XDRBoost()

    public struct State: Sendable, Equatable {
        /// 0–1; 0 is off.
        public var level: Double
        /// nil until it's been tried once on this Mac.
        public var supported: Bool?
    }

    public private(set) var state = State(level: 0, supported: nil)

    private struct Panel {
        let window: NSWindow
        let layer: CAMetalLayer
    }

    /// The windows for one display; rebuilt together or not at all.
    private struct Shown {
        let overlay: Panel
        let trigger: Panel
        let queue: MTLCommandQueue
        /// Fullscreen video makes the same panel re-announce itself; those
        /// announcements reuse the live windows.
        let display: CGDirectDisplayID
    }

    private var shown: Shown?
    private var timer: Timer?
    /// The factor on screen, one smoothing step per tick toward the target.
    private var rendered = 1.0
    /// Consecutive ticks that read no engaged headroom.
    private var disengaged = 0
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    /// While the screens sleep the compositor stops recycling drawables and
    /// `nextDrawable` would stall the main thread.
    private var asleep = false

    /// Whether this Mac has a built-in XDR panel (without trying).
    public var isAvailable: Bool { builtinXDRScreen() != nil }

    /// Sets extra brightness, 0 (off) to 1 (the panel's full sustainable boost).
    public func set(level: Double) throws {
        state.level = min(max(level, 0), 1)
        sync()
        Tools.changed()
        if state.level > 0, state.supported == false {
            throw LowtideError.denied("Extra brightness needs an XDR display, like a MacBook Pro's.")
        }
    }

    // MARK: Lifecycle

    /// Applies the current level: starts, retunes at once (the slider is
    /// feedback, so it skips the ramp) or stops.
    private func sync() {
        guard state.level > 0 else { return stop() }
        let screen = builtinXDRScreen()
        state.supported = screen != nil
        guard let screen else {
            state.level = 0
            return stop()
        }
        installObservers()
        if shown != nil {
            render(immediate: true)
        } else {
            start(on: screen)
        }
    }

    private func start(on screen: NSScreen) {
        guard shown == nil, let shown = show(on: screen, factor: 1) else { return }
        self.shown = shown
        rendered = 1
        disengaged = 0
        // Four presents a second keep a margin over the second macOS waits
        // before revoking. Common modes keep the heartbeat going while a menu
        // or slider tracks the mouse.
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { XDRBoost.shared.render(immediate: false) }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        render(immediate: false)
    }

    private func stopRunning() {
        timer?.invalidate()
        timer = nil
        shown?.overlay.window.orderOut(nil)
        shown?.trigger.window.orderOut(nil)
        shown = nil
    }

    private func stop() {
        stopRunning()
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        asleep = false
    }

    private func installObservers() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor (XDRBoost) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler(XDRBoost.shared) }
            }
            observers.append((center, token))
        }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { $0.screensChanged() }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.asleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification) {
            $0.asleep = false
            $0.render(immediate: false)
        }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { $0.spaceChanged() }
    }

    /// The same panel re-announces itself in storms (an EDR headroom ramp
    /// alone fires this a hundred times in two seconds). With the panel and
    /// frame unchanged nothing happens here.
    private func screensChanged() {
        let screen = builtinXDRScreen()
        state.supported = screen != nil
        guard state.level > 0 else { return stop() }
        // Built-in display gone (clamshell): release the windows, keep the
        // level and the observers; a later change brings it back.
        guard let screen else { return stopRunning() }
        guard let shown else { return start(on: screen) }
        if shown.display == displayID(screen) {
            if shown.overlay.window.frame != screen.frame {
                shown.overlay.window.setFrame(screen.frame, display: false)
                shown.trigger.window.setFrame(Self.triggerFrame(screen), display: false)
                render(immediate: false)
            }
        } else {
            rebuild(on: screen)
        }
    }

    /// The pair is on every Space, so a desktop or fullscreen change needs
    /// only a fresh present, unless a window went missing.
    private func spaceChanged() {
        guard let shown else { return }
        guard let screen = builtinXDRScreen() else { return screensChanged() }
        if XDRBoostMath.canReuseSpaceWindows(sameDisplay: shown.display == displayID(screen),
                                             overlayOn: shown.overlay.window.isOnActiveSpace,
                                             triggerOn: shown.trigger.window.isOnActiveSpace) {
            render(immediate: false)
        } else {
            rebuild(on: screen)
        }
    }

    /// New windows, same heartbeat and factor, so the ramp doesn't restart.
    private func rebuild(on screen: NSScreen) {
        shown?.overlay.window.orderOut(nil)
        shown?.trigger.window.orderOut(nil)
        shown = show(on: screen, factor: rendered)
        if shown == nil { stopRunning() }
        render(immediate: false)
    }

    /// One heartbeat: presents the trigger pixel and the overlay at the
    /// factor the ramp reaches this tick (`immediate` snaps to the target).
    private func render(immediate: Bool) {
        guard !asleep, let shown, let screen = NSScreen.screens.first(where: { displayID($0) == shown.display }) else { return }
        if Self.systemAuthorizationIsActive() {
            shown.overlay.window.orderOut(nil)
            shown.trigger.window.orderOut(nil)
            return
        }
        for panel in [shown.overlay, shown.trigger] where !panel.window.isVisible { panel.window.orderFrontRegardless() }
        Self.present(shown.trigger.layer, queue: shown.queue, gray: XDRBoostMath.triggerGray)
        let headroom = Double(screen.maximumExtendedDynamicRangeColorComponentValue)
        let potential = Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue)
        let engaged = headroom > XDRBoostMath.headroomThreshold
        disengaged = engaged ? 0 : disengaged + 1
        let target = XDRBoostMath.renderFactor(level: state.level, current: headroom, potential: potential,
                                               reference: XDRBoostMath.reference(model: Host.model))
        rendered = immediate ? target : XDRBoostMath.ramped(rendered, toward: XDRBoostMath.graced(
            target, previous: rendered, engaged: engaged, disengagedTicks: disengaged))
        Self.present(shown.overlay.layer, queue: shown.queue, gray: rendered)
    }

    // MARK: Display

    private func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// The built-in XDR panel, if this Mac has one.
    private func builtinXDRScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let id = displayID(screen), CGDisplayIsBuiltin(id) != 0 else { return false }
            return XDRBoostMath.isSupportedPanel(model: Host.model, name: screen.localizedName,
                                                 potential: Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue))
        }
    }

    private static func triggerFrame(_ screen: NSScreen) -> NSRect {
        NSRect(x: screen.frame.maxX - 1, y: screen.frame.minY, width: 1, height: 1)
    }

    /// SecurityAgent's Touch ID / password panel and the App Store's purchase
    /// sheet stay hidden behind the overlay whatever its level; nothing needs
    /// the boost while either is up, so it steps aside.
    private static func systemAuthorizationIsActive() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.SecurityAgent").isEmpty
            || NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.AppStore"
    }

    // MARK: Windows

    private func show(on screen: NSScreen, factor: Double) -> Shown? {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let display = displayID(screen) else { return nil }
        let overlayLayer = Self.extendedLayer(device)
        overlayLayer.isOpaque = false
        // The window server multiplies everything beneath by this layer.
        overlayLayer.compositingFilter = "multiply"
        let overlay = Self.panel(frame: screen.frame, layer: overlayLayer, side: 2)
        let trigger = Self.panel(frame: Self.triggerFrame(screen), layer: Self.extendedLayer(device), side: 1)
        // First frames before the windows show: a rebuild mid-boost must come
        // up already multiplying, never with an empty (neutral) layer.
        Self.present(overlay.layer, queue: queue, gray: factor, wait: true)
        Self.present(trigger.layer, queue: queue, gray: XDRBoostMath.triggerGray, wait: true)
        overlay.window.orderFrontRegardless()
        trigger.window.orderFrontRegardless()
        return Shown(overlay: overlay, trigger: trigger, queue: queue, display: display)
    }

    private static func panel(frame: NSRect, layer: CAMetalLayer, side: CGFloat) -> Panel {
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.animationBehavior = .none
        // Desktop and overview transitions composite above screen-saver
        // windows, so both sit at the display-shield level.
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        // Screenshots and recordings see the screen, not the boosted composite.
        window.sharingType = .none
        // Resident on every Space: bound to one, the boost slid off screen
        // for a whole swipe and the presents that hold the headroom paused.
        window.collectionBehavior = [.ignoresCycle, .fullScreenAuxiliary, .canJoinAllApplications, .canJoinAllSpaces, .stationary]
        // A flat colour needs no resolution.
        layer.drawableSize = CGSize(width: side, height: side)
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer = layer
        layer.frame = view.bounds
        window.contentView = view
        return Panel(window: window, layer: layer)
    }

    private static func extendedLayer(_ device: MTLDevice) -> CAMetalLayer {
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .rgba16Float
        layer.wantsExtendedDynamicRangeContent = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        return layer
    }

    /// One clear pass of a flat gray, no shaders.
    private static func present(_ layer: CAMetalLayer, queue: MTLCommandQueue, gray: Double, wait: Bool = false) {
        guard let drawable = layer.nextDrawable(), let buffer = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: gray, green: gray, blue: gray, alpha: 1)
        buffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        buffer.present(drawable)
        buffer.commit()
        if wait { buffer.waitUntilScheduled() }
    }
}

/// The panel math behind the boost, kept apart so it can be tested.
public enum XDRBoostMath {
    /// The overlay has to show extended-range content before macOS engages
    /// the panel's headroom: the first frames render this small boost.
    static let engagementFactor = 1.10
    /// Headroom past this is real (values near 1 are noise).
    static let headroomThreshold = 1.05
    /// Panels that fake EDR by dimming the rest (every MacBook Air, Intel
    /// MacBook Pro, iMac) report exactly 2.0; true XDR panels report far above.
    static let capabilityFloor = 2.05
    /// In extended range so the headroom engages, dim enough that the single
    /// pixel in the corner stays unobtrusive.
    static let triggerGray = 1.8

    /// Every Mac with a built-in mini-LED XDR panel: the 14 and 16 inch
    /// MacBook Pro, M1 Pro/Max through M5.
    static let xdrModels: Set<String> = [
        "MacBookPro18,1", "MacBookPro18,2", "MacBookPro18,3", "MacBookPro18,4",
        "Mac14,5", "Mac14,6", "Mac14,9", "Mac14,10",
        "Mac15,3", "Mac15,6", "Mac15,7", "Mac15,8", "Mac15,9", "Mac15,10", "Mac15,11",
        "Mac16,1", "Mac16,5", "Mac16,6", "Mac16,7", "Mac16,8",
        "Mac17,2", "Mac17,6", "Mac17,7", "Mac17,8", "Mac17,9",
    ]

    /// The M1/M2 MacBook Pro panels reference 500 nits in SDR; from M3 on, 600.
    static let sdr500Models: Set<String> = [
        "MacBookPro18,1", "MacBookPro18,2", "MacBookPro18,3", "MacBookPro18,4", "Mac14,5", "Mac14,6", "Mac14,9", "Mac14,10",
    ]

    /// Whether a built-in panel can truly exceed its SDR brightness. AppKit
    /// names every built-in panel "Built-in Retina Display", so the model is
    /// the primary signal; unknown (future) models pass on real headroom or
    /// an XDR name.
    static func isSupportedPanel(model: String?, name: String, potential: Double) -> Bool {
        if let model, xdrModels.contains(model) { return true }
        return potential > capabilityFloor || name.lowercased().contains("xdr")
    }

    struct Reference: Equatable {
        /// The headroom the panel is expected to grant.
        var edr: Double
        /// The multiplier tops out at 1 + bonus: a touch below the ceiling
        /// proven sustainable. More looks brighter for an instant, then macOS
        /// claws the headroom back and the whole boost drops out.
        var bonus: Double
    }

    static func reference(model: String?) -> Reference {
        if let model, sdr500Models.contains(model) { return Reference(edr: 3.2, bonus: 0.58) }
        return Reference(edr: 2.66, bonus: 0.48)
    }

    /// The multiplier for a level (0–1) given the headroom macOS grants.
    static func boostFactor(level: Double, maxEDR: Double, reference: Reference) -> Double {
        let granted = min(max(maxEDR, 0) / reference.edr, 1)
        return 1 + min(max(level, 0), 1) * reference.bonus * granted
    }

    /// The factor to show now: before the panel engages only the small
    /// engagement boost; then the level mapped into the headroom available,
    /// never past it. No potential headroom: no attempt.
    static func renderFactor(level: Double, current: Double, potential: Double, reference: Reference) -> Double {
        if potential <= headroomThreshold { return 1 }
        if current <= headroomThreshold {
            return min(engagementFactor, boostFactor(level: level, maxEDR: reference.edr, reference: reference))
        }
        return min(boostFactor(level: level, maxEDR: current, reference: reference), max(current, 1))
    }

    static let rampUpStep = 0.03
    static let rampDownShare = 0.25
    static let rampMinStep = 0.01
    /// Consecutive no-headroom readings to ride out before believing them
    /// (entering fullscreen video briefly reports none at all).
    static let dropoutGraceTicks = 3

    /// One smoothing step: up by a small fixed step, down by a share of the
    /// gap, so a revocation is respected within seconds without flashing.
    static func ramped(_ previous: Double, toward target: Double) -> Double {
        if target > previous { return min(previous + rampUpStep, target) }
        if target < previous { return max(previous - max((previous - target) * rampDownShare, rampMinStep), target) }
        return previous
    }

    /// A grant that vanished moments ago keeps the previous factor through
    /// the grace window; a persistent dropout is taken at face value.
    static func graced(_ instantaneous: Double, previous: Double, engaged: Bool, disengagedTicks: Int) -> Double {
        engaged || disengagedTicks > dropoutGraceTicks ? instantaneous : max(instantaneous, previous)
    }

    /// Whether the live window pair followed a Space change and can keep
    /// presenting. Both matter: losing the trigger pixel lets macOS revoke.
    static func canReuseSpaceWindows(sameDisplay: Bool, overlayOn: Bool, triggerOn: Bool) -> Bool {
        sameDisplay && overlayOn && triggerOn
    }
}
