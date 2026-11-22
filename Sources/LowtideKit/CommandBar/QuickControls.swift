import Foundation

/// What the bar's Tools show: keep awake, brightness, extra brightness, the
/// microphone and the sound output.
public struct QuickControlsState: Equatable, Sendable {
    public struct Awake: Equatable, Sendable {
        public var on: Bool
        /// The screen stays on too (not only the Mac).
        public var display: Bool
        public var until: Date?

        public init(on: Bool = false, display: Bool = true, until: Date? = nil) {
            self.on = on
            self.display = display
            self.until = until
        }
    }

    public struct Output: Equatable, Sendable, Identifiable {
        public var id: UInt32
        public var name: String
        public var current: Bool

        public init(id: UInt32, name: String, current: Bool) {
            self.id = id
            self.name = name
            self.current = current
        }
    }

    public var awake = Awake()
    /// 0–1; nil when the screen's brightness can't be read (an external display).
    public var brightness: Double?
    /// Extra brightness beyond the maximum, 0–100.
    public var boostLevel = 0
    /// nil while unknown; false on screens without XDR.
    public var boostSupported: Bool?
    public var micMuted = false
    public var outputs: [Output] = []

    public init() {}
}

/// The system controls the bar drives. The real ones live with the System
/// tools (keep awake, display, audio, colour picker); the app wires them in
/// at launch (`CommandBarHooks.quickControls`).
public protocol QuickControls: Sendable {
    /// The controls' state, or nil when there are none (then the bar shows no Tools).
    func state() async -> QuickControlsState?
    /// Keeps the Mac awake for `minutes` (nil: until turned off); the screen too with `display`.
    func keepAwake(minutes: Int?, display: Bool) async throws
    func stopKeepingAwake() async throws
    /// 0–1.
    func setBrightness(_ level: Double) async throws
    /// 0–100; 0 turns it off.
    func setBoost(_ level: Int) async throws
    /// Returns whether the microphone is muted now.
    func toggleMicrophone() async throws -> Bool
    func setOutput(_ id: UInt32) async throws
    /// Lets the person click any pixel; its HEX ("#1A2B3C"), already copied, or nil when cancelled.
    func pickColor() async -> String?
}

/// No controls: the bar hides its Tools until real ones are wired in.
public struct NoQuickControls: QuickControls {
    public init() {}
    public func state() async -> QuickControlsState? { nil }
    public func keepAwake(minutes: Int?, display: Bool) async throws {}
    public func stopKeepingAwake() async throws {}
    public func setBrightness(_ level: Double) async throws {}
    public func setBoost(_ level: Int) async throws {}
    public func toggleMicrophone() async throws -> Bool { false }
    public func setOutput(_ id: UInt32) async throws {}
    public func pickColor() async -> String? { nil }
}

/// Every way to write a colour the bar picked: HEX, RGB, HSL, OKLCH, SwiftUI.
public enum ColorFormats {
    public static func rgb(_ hex: String) -> (Int, Int, Int)? {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let n = Int(text, radix: 16) else { return nil }
        return ((n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff)
    }

    static func hsl(_ r: Int, _ g: Int, _ b: Int) -> String {
        let c = Answers.rgbToHSL(RGBA(r: Double(r), g: Double(g), b: Double(b)))
        return "hsl(\(Int(c.0.rounded())), \(Int((c.1 * 100).rounded()))%, \(Int((c.2 * 100).rounded()))%)"
    }

    /// CSS `oklch()`, the space Tailwind v4 writes its palette in.
    static func oklch(_ r: Int, _ g: Int, _ b: Int) -> String {
        func lin(_ c: Int) -> Double {
            let v = Double(c) / 255
            return v <= 0.040_45 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let (lr, lg, lb) = (lin(r), lin(g), lin(b))
        let l = cbrt(0.412_221_470_8 * lr + 0.536_332_536_3 * lg + 0.051_445_992_9 * lb)
        let m = cbrt(0.211_903_498_2 * lr + 0.680_699_545_1 * lg + 0.107_396_956_6 * lb)
        let s = cbrt(0.088_302_461_9 * lr + 0.281_718_837_6 * lg + 0.629_978_700_5 * lb)
        let L = 0.210_454_255_3 * l + 0.793_617_785 * m - 0.004_072_046_8 * s
        let A = 1.977_998_495_1 * l - 2.428_592_205 * m + 0.450_593_709_9 * s
        let B = 0.025_904_037_1 * l + 0.782_771_766_2 * m - 0.808_675_766 * s
        let C = (A * A + B * B).squareRoot()
        let H = C < 0.0001 ? 0 : (atan2(B, A) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        return String(format: "oklch(%.1f%% %.3f %.1f)", L * 100, C, H)
    }

    /// (label, text) for every format.
    public static func all(_ hex: String) -> [(String, String)] {
        guard let (r, g, b) = rgb(hex) else { return [] }
        let unit = { (v: Int) in String(format: "%.3f", Double(v) / 255) }
        return [
            ("HEX", String(format: "#%02X%02X%02X", r, g, b)),
            ("RGB", "rgb(\(r), \(g), \(b))"),
            ("HSL", hsl(r, g, b)),
            ("OKLCH", oklch(r, g, b)),
            ("SwiftUI", "Color(red: \(unit(r)), green: \(unit(g)), blue: \(unit(b)))"),
        ]
    }
}
