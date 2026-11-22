import Foundation

/// What the dictation overlay says when a take ends: the mark the filament
/// draws into, its words, and the action an error offers.
public struct HUDLabel: Equatable, Sendable {
    public enum Glyph: Sendable { case check, alert, flat }

    public var glyph: Glyph
    /// Said quietly (nothing heard).
    public var quiet: Bool
    public var text: String
    public var action: VoiceAction?

    static let kindMessage: [String: String] = [
        "helper": "Dictation stopped",
        "mic": "No microphone",
        "model-loading": "Model still loading",
        "no-focus": "Nowhere to type",
        "no-model": "No speech model",
        "permission": "Needs permission",
        "secure-input": "Keys are blocked",
    ]

    /// The label a finished, empty or failed take ends on; nil while one
    /// is under way.
    public static func of(_ s: VoiceState) -> HUDLabel? {
        switch s.phase {
        case .done:
            let into = s.app.map { " into \($0)" } ?? ""
            let text: String = switch s.method {
            case "accessibility", "typed": "Typed\(into)"
            case "copied": "Copied: press ⌘V"
            case "paste": "Pasted\(into)"
            default: s.message.isEmpty ? "Done" : s.message
            }
            return HUDLabel(glyph: .check, quiet: false, text: text, action: nil)
        case .empty:
            return HUDLabel(glyph: .flat, quiet: true, text: s.message.isEmpty ? "Didn’t catch that" : s.message, action: nil)
        case .error:
            let text = s.message.isEmpty ? (kindMessage[s.kind ?? ""] ?? "Something went wrong") : s.message
            return HUDLabel(glyph: .alert, quiet: false, text: text, action: s.action)
        default:
            return nil
        }
    }
}

/// The overlay's plate, in points: where the glyph's centre sits, where the
/// words start, and the room after them (less after an action's chip).
public enum HUDPlate {
    public static let glyphX = 17.0
    public static let height = 32.0
    public static let labelX = 31.0
    public static let maxWidth = 400.0
    public static let afterAction = 6.0
    public static let afterText = 14.0
    /// Room on the right for the queue count.
    public static let queue = 22.0

    /// The capsule's width for a state, or nil to keep it (on the way out).
    public static func width(_ phase: VoicePhase, label: HUDLabel?, labelWidth: Double, right: Double) -> Double? {
        if let label {
            return min(maxWidth, labelWidth + labelX + (label.action == nil ? afterText : afterAction))
        }
        switch phase {
        case .idle: return nil
        case .transcribing: return 80 + right
        default: return 124 + right
        }
    }

    /// Shortest time each phase stays up, so none is a flicker.
    public static func hold(_ phase: VoicePhase) -> Double {
        switch phase {
        case .done: 0.9
        case .empty: 1.4
        case .error: 2.6
        case .transcribing: 0.2
        default: 0
        }
    }

    /// How long to wait before showing `incoming` over `shown`, which has
    /// been up `elapsed` seconds. A new take cuts in at once.
    public static func delay(showing incoming: VoicePhase, over shown: VoicePhase, elapsed: Double) -> Double {
        if incoming == .listening || incoming == .recording { return 0 }
        return max(0, hold(shown) - elapsed)
    }
}

/// Every value the overlay animates, each on its own spring: geometry
/// bounces, the rest fades.
public struct HUDMotion: Sendable {
    public var anchor = HUDSpring(0)
    public var blur = HUDSpring(8)
    public var draw = HUDSpring(0)
    public var label = HUDSpring(0)
    public var labelX = HUDSpring(-6)
    public var opacity = HUDSpring(0)
    public var previewDim = HUDSpring(1)
    public var previewHeight = HUDSpring(36)
    public var previewOpacity = HUDSpring(0)
    public var previewWidth = HUDSpring(120)
    public var previewY = HUDSpring(6)
    public var scale = HUDSpring(0.9)
    public var span = HUDSpring(0)
    public var width = HUDSpring(HUDPlate.height)
    public var wire = HUDSpring(0)
    public var work = HUDSpring(0)

    public init() {}

    private static var geometry: [WritableKeyPath<HUDMotion, HUDSpring>] { [
        \.anchor, \.draw, \.labelX, \.previewHeight, \.previewWidth, \.previewY, \.scale, \.span, \.width,
    ] }
    private static var fades: [WritableKeyPath<HUDMotion, HUDSpring>] { [
        \.blur, \.label, \.opacity, \.previewDim, \.previewOpacity, \.wire, \.work,
    ] }

    /// Points every spring at what `phase` looks like. `width` nil keeps the
    /// capsule's (on the way out).
    public mutating func aim(_ phase: VoicePhase, labelled: Bool, width: Double?, words: Bool) {
        let visible = phase != .idle
        let thread = visible && !labelled
        let working = phase == .transcribing
        func on(_ yes: Bool, _ a: Double, _ b: Double) -> Double { yes ? a : b }
        anchor.target = on(labelled, 1, 0)
        blur.target = on(visible, 0, 3)
        label.target = on(labelled, 1, 0)
        labelX.target = on(labelled, 0, -6)
        opacity.target = on(visible, 1, 0)
        previewDim.target = on(working, 0.55, 1)
        previewOpacity.target = on(words, 1, 0)
        previewY.target = on(words, 0, 6)
        scale.target = on(visible, 1, 0.92)
        span.target = on(thread, 1, 0)
        wire.target = on(thread, 1, 0)
        work.target = on(working, 1, 0)
        if let width { self.width.target = width }
        if !labelled { draw.target = 0 }
    }

    /// One frame: the words' capsule follows its measured size (opening at
    /// it), the mark draws in once the thread has gathered to a point, and
    /// every spring steps.
    public mutating func step(_ dt: Double, reduced: Bool, labelled: Bool, previewSize: (Double, Double)) {
        if previewOpacity.x < 0.02 && previewOpacity.target > 0 {
            previewWidth.jump(previewSize.0)
            previewHeight.jump(previewSize.1)
        }
        previewWidth.target = previewSize.0
        previewHeight.target = previewSize.1
        if labelled { draw.target = span.x < 0.35 ? 1 : 0 }
        for path in Self.geometry {
            if reduced { self[keyPath: path].jump(self[keyPath: path].target) } else { self[keyPath: path].step(.morph, dt) }
        }
        for path in Self.fades {
            self[keyPath: path].step(reduced ? .reduced : .fade, dt)
        }
        if reduced { blur.jump(0) }
    }

    /// Faded out and still: the panel can go.
    public var gone: Bool { opacity.x < 0.01 && opacity.settled(0.01) }
}
