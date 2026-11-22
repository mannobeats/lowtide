import AppKit
import LowtideKit
import SwiftUI

/// The dictation overlay: a small capsule at the bottom of the screen you're
/// on, the words heard so far above it. A non-activating panel that never
/// takes focus (the text has to land in the app you were in) and lets
/// clicks through, except while an error offers a way out.
///
/// The panel is a fixed transparent frame big enough for every state; the
/// view draws and animates the capsule inside it. The panel comes in when a
/// take starts and goes once the view's exit has played.
final class VoiceOverlay {
    static let shared = VoiceOverlay()

    /// Room for the widest capsule, the words above it and their shadows.
    static let size = CGSize(width: 440, height: 160)
    /// The frame's bottom edge above the Dock; the view leaves 20 pt under
    /// the capsule, so it floats 36 pt up.
    static let lift: CGFloat = 16

    let model = HUDModel()
    private var panel: HUDPanel?
    private var watchdog: DispatchWorkItem?

    /// Made on first show, not at launch: SwiftUI doesn't present the main
    /// window at launch when the app already has one, even a hidden panel.
    private func makePanel() -> HUDPanel {
        if let panel { return panel }
        let panel = HUDPanel(contentRect: CGRect(origin: .zero, size: Self.size))
        let host = HUDHostingView(rootView: HUDView(model: model))
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.frame = CGRect(origin: .zero, size: Self.size)
        panel.contentView = host
        self.panel = panel
        return panel
    }

    func remove() {
        panel?.orderOut(nil)
        panel = nil
        model.reset()
    }

    /// The helper's state changed: the overlay holds each for its minimum,
    /// then shows it.
    func update() {
        let state = Dictation.shared.state
        model.receive(state)
        watchdog?.cancel()
        // A finished take always comes down, whatever its exit animation
        // does (a paused frame loop left "Pasted into …" up for good): a
        // moment after idle, or a while after a done, empty or error that
        // idle never followed. Never while a take is live.
        guard let after = state.phase == .idle ? Duration.seconds(1.5) : state.shownFor.map({ $0 + .seconds(2) }) else { return }
        // A main-queue timer, not Task.sleep: it fires even if Swift's
        // thread pool is stuck.
        let check = DispatchWorkItem { [weak self] in
            switch Dictation.shared.state.phase {
            case .idle, .done, .empty, .error: self?.dismiss()
            default: break
            }
        }
        watchdog = check
        let (seconds, atto) = after.components
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(seconds) + Double(atto) / 1e18, execute: check)
    }

    /// Down now, and the next take starts from a fresh pill.
    private func dismiss() {
        hide()
        model.reset()
    }

    /// A state is on screen: bring the panel in (or keep it), clickable
    /// only while an error offers an action.
    func present(clickable: Bool) {
        guard Dictation.shared.enabled else { return }
        let panel = makePanel()
        let here = panel.isOnActiveSpace
        // Still up on another Space (a full-screen app came forward): out
        // first, so it comes back on this one.
        if panel.isVisible && !here { panel.orderOut(nil) }
        // Set afresh on every show: AppKit can keep a panel tied to one Space
        // after the Dock icon comes or goes while still reporting the old
        // behaviour, and setting an unchanged one does nothing (Hex #1084).
        panel.collectionBehavior = []
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary,
                                    .ignoresCycle]
        if !panel.isVisible || !here { place(panel) }
        panel.appearance = NSAppearance(named: ThemeStore.shared.systemDark ? .darkAqua : .aqua)
        panel.ignoresMouseEvents = !clickable
        panel.orderFrontRegardless()
    }

    /// The view's exit has played.
    func finished() {
        guard model.shown.phase == .idle, Dictation.shared.state.phase == .idle else { return }
        hide()
    }

    private func hide() {
        panel?.ignoresMouseEvents = true
        panel?.orderOut(nil)
        model.animating = false
    }

    /// Centred at the bottom of the screen under the pointer.
    private func place(_ panel: NSPanel) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let origin = CGPoint(x: (visible.minX + (visible.width - Self.size.width) / 2).rounded(), y: visible.minY + Self.lift)
        panel.setFrame(CGRect(origin: origin, size: Self.size), display: true)
    }
}

/// A borderless panel that can never become key: a click on an error's
/// action must not take the keyboard from the app you were typing in.
final class HUDPanel: NSPanel {
    init(contentRect: CGRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        hidesOnDeactivate = false
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        // The view draws the capsule's shadow; a window shadow would outline
        // the whole transparent frame.
        hasShadow = false
        ignoresMouseEvents = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// An error's action is one click, without a first click to focus.
final class HUDHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// What the overlay shows and how far each value has come. `shown` lags the
/// helper's state so no phase is a flicker; the springs and the filament
/// step once per frame and aren't observed.
@Observable
final class HUDModel {
    private(set) var shown = VoiceState.idle
    /// The frame loop runs while the panel is up.
    var animating = false

    @ObservationIgnored private var shownSince = Date()
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored var motion = HUDMotion()
    @ObservationIgnored var filament = Filament()
    @ObservationIgnored private var lastFrame: Date?
    /// The overlay is (or is coming) on screen; false once its exit played.
    @ObservationIgnored private var onScreen = false
    /// A label fading out keeps its words until it's gone.
    @ObservationIgnored private(set) var lastLabel: HUDLabel?

    func reset() {
        pending?.cancel()
        shown = .idle
        animating = false
        onScreen = false
        motion = HUDMotion()
        filament = Filament()
    }

    /// Holds each phase for its minimum; a new take cuts in at once.
    func receive(_ incoming: VoiceState) {
        pending?.cancel()
        let wait = HUDPlate.delay(showing: incoming.phase, over: shown.phase,
                                      elapsed: Date().timeIntervalSince(shownSince))
        guard wait > 0 else { apply(incoming); return }
        pending = Task {
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self.apply(incoming)
        }
    }

    private func apply(_ next: VoiceState) {
        if next.phase != shown.phase { shownSince = Date() }
        shown = next
        if let label = HUDLabel.of(next) { lastLabel = label }
        if next.phase != .idle {
            if !onScreen {
                // Coming in from hidden: a point of light, small and soft,
                // and a thread at rest.
                onScreen = true
                motion = HUDMotion()
                filament = Filament()
                lastFrame = nil
            }
            animating = true
            VoiceOverlay.shared.present(clickable: next.phase == .error && next.action != nil)
        }
    }

    /// One frame at `date`: aims the springs at the shown state and steps
    /// them and the filament. Each date is stepped once, however often the
    /// view asks.
    func frame(at date: Date, words: String, level: Double, reduced: Bool) -> HUDFrame {
        let label = HUDLabel.of(shown)
        let drawn = label ?? lastLabel
        let live = shown.phase.isLive
        let right = shown.queued > 0 && live ? HUDPlate.queue : 0
        let showWords = live && !words.isEmpty
        let preview = HUDText.preview(words)
        if lastFrame != date {
            let dt = min(lastFrame.map { date.timeIntervalSince($0) } ?? 0, 1.0 / 30)
            lastFrame = date
            filament.reduced = reduced
            filament.live = shown.phase == .recording
            filament.input = level
            filament.advance(dt)
            motion.aim(shown.phase, labelled: label != nil,
                       width: HUDPlate.width(shown.phase, label: label,
                                                 labelWidth: label.map(HUDText.labelWidth) ?? 0, right: right),
                       words: showWords)
            motion.step(dt, reduced: reduced, labelled: label != nil, previewSize: (preview.width + 28, preview.height + 18))
            if shown.phase == .idle && onScreen && motion.gone {
                onScreen = false
                DispatchQueue.main.async { VoiceOverlay.shared.finished() }
            }
        }
        return HUDFrame(motion: motion, filament: filament, label: drawn, right: right,
                            time: date.timeIntervalSinceReferenceDate, wordsFull: preview.full)
    }
}

/// A frame's values, handed to the view.
struct HUDFrame {
    let motion: HUDMotion
    let filament: Filament
    let label: HUDLabel?
    let right: Double
    let time: Double
    let wordsFull: Bool
}

/// Sizes of the overlay's words, measured with the fonts it draws them in.
enum HUDText {
    static let labelFont = NSFont.systemFont(ofSize: TextSize.xs.rawValue, weight: .medium)
    static let wordsFont = NSFont.systemFont(ofSize: TextSize.sm.rawValue)
    static let lineHeight: CGFloat = 18
    static let wordsWidth: CGFloat = 300

    private static func width(_ text: String, _ font: NSFont) -> Double {
        ceil(Double((text as NSString).size(withAttributes: [.font: font]).width))
    }

    /// The label's width: its words, and the action's chip after them.
    static func labelWidth(_ label: HUDLabel) -> Double {
        let text = width(label.text, labelFont)
        guard let action = label.action else { return text }
        return text + 8 + width(action.title, labelFont) + 16
    }

    /// The words' box: two lines at most, the newest at the bottom; `full`
    /// once older lines go off the top.
    static func preview(_ words: String) -> (width: Double, height: Double, full: Bool) {
        guard !words.isEmpty else { return (92, 18, false) }
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        let box = (words as NSString).boundingRect(
            with: CGSize(width: wordsWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: wordsFont, .paragraphStyle: style])
        let lines = max(1, Int((box.height / lineHeight).rounded()))
        return (min(Double(wordsWidth), ceil(Double(box.width))), Double(min(lines, 2)) * Double(lineHeight), lines > 2)
    }
}
