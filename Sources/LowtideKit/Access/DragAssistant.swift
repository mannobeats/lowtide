import AppKit
import QuartzCore

/// The permission drag assistant: a small panel beside System Settings with
/// Lowtide's icon, to drag into a privacy list (Accessibility, Full Disk
/// Access, App Management). It follows the Settings window, hides while
/// Settings is in the background, and closes once the permission is on,
/// Settings quits, or the person closes it. A ghost of the icon keeps
/// gliding from the panel into Settings' list, so the drag is shown rather
/// than described.
///
/// Based on Orca's
/// `PermissionDragAssistantController` (MIT).
@MainActor
public final class DragAssistant {
    public static let shared = DragAssistant()

    nonisolated static let settingsID = "com.apple.systempreferences"
    nonisolated static let size = NSSize(width: 340, height: 100)
    nonisolated static let gap: CGFloat = 12
    /// The centre of the icon in the panel's tile, where the ghost lifts off.
    nonisolated static let iconCentre = NSPoint(x: 40, y: 38)
    /// One glide of the ghost, pause included.
    nonisolated static let loop: CFTimeInterval = 2.6
    /// How long System Settings may take to launch before the panel gives up.
    nonisolated static let launchWait: TimeInterval = 10

    private var panel: NSPanel?
    private var guide: NSPanel?
    private var ghost: CALayer?
    private var route: (NSPoint, NSPoint)?
    private var follower: Task<Void, Never>?
    private var born = Date()
    private var seenSettings = false
    fileprivate var dragging = false

    /// Opens the panel for `access` and keeps it beside System Settings until done.
    public func show(for access: Access) {
        close()
        let panel = makePanel()
        let (guide, ghost) = makeGuide()
        self.panel = panel
        self.guide = guide
        self.ghost = ghost
        born = Date()
        seenSettings = false
        follower = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                ticks += 1
                guard let self, !Task.isCancelled else { return }
                if ticks % 4 == 0, self.panel?.isVisible == true, await access.granted() == true { break }
                if !self.follow() { break }
            }
            self?.close()
        }
    }

    public func close() {
        follower?.cancel()
        follower = nil
        panel?.close()
        guide?.close()
        panel = nil
        guide = nil
        ghost = nil
        route = nil
    }

    /// Places the panel beside System Settings while Settings is in front,
    /// hides it otherwise. False when it's time to go (Settings quit, or
    /// never started).
    private func follow() -> Bool {
        guard let panel else { return false }
        guard let settings = NSRunningApplication.runningApplications(withBundleIdentifier: Self.settingsID).first else {
            // Closing System Settings' window quits it.
            hide()
            return !(seenSettings || Date().timeIntervalSince(born) > Self.launchWait)
        }
        seenSettings = true
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == settings.processIdentifier
        guard front, let quartz = Self.settingsFrame(settings.processIdentifier), let primary = NSScreen.screens.first else {
            hide()
            return true
        }
        let frame = Self.flip(quartz, primaryHeight: primary.frame.height)
        guard let screen = NSScreen.screens.max(by: { Self.overlap($0.frame, frame) < Self.overlap($1.frame, frame) }) else { return true }
        let origin = Self.dock(frame, size: Self.size, screen: screen.visibleFrame)
        panel.setFrameOrigin(origin)
        if !panel.isVisible {
            panel.orderFrontRegardless()
            panel.invalidateShadow()
        }
        if dragging { hideGuide() } else { showGuide(panel: origin, settings: frame) }
        return true
    }

    private func hide() {
        panel?.orderOut(nil)
        hideGuide()
    }

    /// Glides the ghost from the panel's icon to the middle of Settings'
    /// content, where the app list is; restarted only when a window moves.
    private func showGuide(panel origin: NSPoint, settings: NSRect) {
        guard let guide, let ghost else { return }
        let from = NSPoint(x: origin.x + Self.iconCentre.x, y: origin.y + Self.iconCentre.y)
        let to = NSPoint(x: settings.minX + settings.width * 0.62, y: settings.minY + settings.height * 0.5)
        if route.map({ $0.0 != from || $0.1 != to }) ?? true {
            let frame = Self.union(NSRect(origin: origin, size: Self.size), settings)
            let local = { (p: NSPoint) in NSPoint(x: p.x - frame.minX, y: p.y - frame.minY) }
            guide.setFrame(frame, display: false)
            Self.glide(ghost, from: local(from), to: local(to))
            route = (from, to)
        }
        if !guide.isVisible { guide.orderFrontRegardless() }
    }

    fileprivate func hideGuide() {
        guard route != nil else { return }
        route = nil
        guide?.orderOut(nil)
        ghost?.removeAllAnimations()
    }

    /// Lift (fade in, grow), glide, drop (shrink, fade out), rest; on repeat.
    static func glide(_ ghost: CALayer, from: NSPoint, to: NSPoint) {
        let times: [NSNumber] = [0, 0.14, 0.68, 0.8, 1]
        let curves = [CAMediaTimingFunctionName.easeOut, .easeInEaseOut, .easeIn, .linear].map(CAMediaTimingFunction.init)
        func keyframes(_ key: String, _ values: [Any]) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: key)
            animation.values = values
            animation.keyTimes = times
            animation.timingFunctions = curves
            animation.duration = loop
            return animation
        }
        let group = CAAnimationGroup()
        group.animations = [
            keyframes("position", [from, from, to, to, to].map { NSValue(point: $0) }),
            keyframes("opacity", [0, 1, 1, 0, 0]),
            keyframes("transform.scale", [1, 1.12, 1.12, 0.8, 0.8]),
        ]
        group.duration = loop
        group.repeatCount = .infinity
        ghost.removeAllAnimations()
        ghost.add(group, forKey: "glide")
    }

    // MARK: Geometry

    nonisolated static func union(_ a: NSRect, _ b: NSRect) -> NSRect {
        let x = min(a.minX, b.minX), y = min(a.minY, b.minY)
        return NSRect(x: x, y: y, width: max(a.maxX, b.maxX) - x, height: max(a.maxY, b.maxY) - y)
    }

    /// Quartz (top-left origin) to AppKit (bottom-left origin); both are
    /// measured from the primary display.
    nonisolated static func flip(_ frame: NSRect, primaryHeight: CGFloat) -> NSRect {
        NSRect(x: frame.minX, y: primaryHeight - frame.minY - frame.height, width: frame.width, height: frame.height)
    }

    nonisolated static func overlap(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let width = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        let height = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return max(width, 0) * max(height, 0)
    }

    /// Beside `settings` on whichever side fits `screen`, vertically
    /// centred; over its bottom-right corner when neither side fits.
    nonisolated static func dock(_ settings: NSRect, size: NSSize, screen: NSRect) -> NSPoint {
        let right = settings.maxX + gap
        let left = settings.minX - gap - size.width
        let x: CGFloat, y: CGFloat
        if right + size.width <= screen.maxX {
            (x, y) = (right, settings.minY + (settings.height - size.height) / 2)
        } else if left >= screen.minX {
            (x, y) = (left, settings.minY + (settings.height - size.height) / 2)
        } else {
            (x, y) = (right - 2 * gap - size.width, settings.minY + gap)
        }
        let top = screen.maxY - size.height
        // max-then-min rather than a clamp: a screen shorter than the panel
        // has no valid range.
        return NSPoint(x: x, y: max(min(y, top), screen.minY))
    }

    /// System Settings' main window on screen, in Quartz coordinates. Bounds
    /// and owner need no Screen Recording permission; titles would.
    nonisolated static func settingsFrame(_ pid: pid_t) -> NSRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        for window in list {
            guard (window[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid,
                  window[kCGWindowLayer as String] as? Int == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"],
                  // Sheets and popovers are smaller than the window itself.
                  width >= 400, height >= 300 else { continue }
            return NSRect(x: x, y: y, width: width, height: height)
        }
        return nil
    }

    // MARK: Windows

    static var appIcon: NSImage { NSApp.applicationIconImage ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath) }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        // Lowtide isn't the active app while System Settings is in front.
        panel.hidesOnDeactivate = false
        // It belongs beside Settings; a drag on it moves the app, not the panel.
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = AssistView(owner: self)
        return panel
    }

    /// A transparent, click-through window over the panel and Settings for
    /// the ghost: the icon with a grabbing hand on it.
    private func makeGuide() -> (NSPanel, CALayer) {
        let guide = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        guide.isReleasedWhenClosed = false
        guide.isOpaque = false
        guide.backgroundColor = .clear
        guide.hasShadow = false
        guide.ignoresMouseEvents = true
        guide.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        guide.hidesOnDeactivate = false
        guide.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let view = NSView(frame: NSRect(origin: .zero, size: Self.size))
        view.wantsLayer = true
        guide.contentView = view

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let ghost = CALayer()
        ghost.bounds = NSRect(x: 0, y: 0, width: 40, height: 40)
        ghost.contents = Self.appIcon
        ghost.contentsGravity = .resizeAspect
        ghost.contentsScale = scale
        // Hidden between loops: only the animation shows it.
        ghost.opacity = 0
        ghost.shadowOpacity = 0.35
        ghost.shadowRadius = 6
        ghost.shadowOffset = NSSize(width: 0, height: -3)
        let handImage = NSCursor.closedHand.image
        let hand = CALayer()
        hand.bounds = NSRect(origin: .zero, size: handImage.size)
        hand.position = NSPoint(x: 30, y: 12)
        hand.contents = handImage
        hand.contentsScale = scale
        ghost.addSublayer(hand)
        view.layer?.addSublayer(ghost)
        return (guide, ghost)
    }

    fileprivate func dragEnded() { dragging = false }

    fileprivate func dismissed() {
        follower?.cancel()
        hide()
        // Released on its own turn, never from inside the close button's action.
        Task { @MainActor [weak self] in self?.close() }
    }
}

/// The panel's content: the hint, the close button, and the tile to drag.
private final class AssistView: NSVisualEffectView, NSDraggingSource {
    weak var owner: DragAssistant?

    init(owner: DragAssistant) {
        self.owner = owner
        super.init(frame: NSRect(origin: .zero, size: DragAssistant.size))
        material = .hudWindow
        blendingMode = .behindWindow
        // Stays lit although Lowtide isn't the active app.
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true

        if let image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close") {
            let close = NSButton(image: image, target: self, action: #selector(dismiss))
            close.isBordered = false
            close.contentTintColor = .secondaryLabelColor
            close.frame = NSRect(x: 10, y: 72, width: 18, height: 18)
            close.toolTip = "Close"
            addSubview(close)
        }
        let hint = NSTextField(labelWithString: "Drag Lowtide into the list, then switch it on.")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 34, y: 72, width: 296, height: 18)
        addSubview(hint)

        let tile = NSBox(frame: NSRect(x: 12, y: 12, width: DragAssistant.size.width - 24, height: 52))
        tile.boxType = .custom
        tile.titlePosition = .noTitle
        tile.contentViewMargins = .zero
        tile.cornerRadius = 10
        tile.borderColor = .separatorColor
        tile.fillColor = .quaternaryLabelColor
        let icon = NSImageView(image: DragAssistant.appIcon)
        icon.frame = NSRect(x: 8, y: 6, width: 40, height: 40)
        tile.contentView?.addSubview(icon)
        let name = NSTextField(labelWithString: Paths.appName)
        name.font = .boldSystemFont(ofSize: 14)
        name.frame = NSRect(x: 58, y: 16, width: 240, height: 20)
        tile.contentView?.addSubview(name)
        addSubview(tile)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Every click lands here except on the close button, so a drag can
    /// start anywhere on the panel.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit is NSButton ? hit : self
    }

    // The panel never becomes key, so the first click must count.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        let path = Bundle.main.bundlePath
        // A bare binary isn't an .app: System Settings would refuse the folder.
        guard path.hasSuffix(".app") else { return }
        let item = NSDraggingItem(pasteboardWriter: URL(fileURLWithPath: path) as NSURL)
        let at = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: at.x - 32, y: at.y - 32, width: 64, height: 64), contents: DragAssistant.appIcon)
        beginDraggingSession(with: [item], event: event, source: self)
        owner?.dragging = true
        owner?.hideGuide()
    }

    @objc private func dismiss() { owner?.dismissed() }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // The next follow brings the ghost back if the drop missed.
        owner?.dragEnded()
    }
}
