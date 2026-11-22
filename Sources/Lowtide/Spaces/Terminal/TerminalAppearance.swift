import AppKit
import LowtideKit
import SwiftTerm
import SwiftUI

/// How terminals look and behave, kept across launches.
@Observable
final class TerminalSettings {
    static let shared = TerminalSettings()

    nonisolated enum Cursor: String, CaseIterable, Codable, Sendable { case bar, block, underline }

    nonisolated struct Stored: Codable, Sendable {
        var fontSize: Double = 13
        var cursor: Cursor = .bar
        var cursorBlink = true
        var copyOnSelect = false
        var autocomplete = true
        var scrollback = 10_000
        var optionAsMeta = true
    }

    var fontSize: Double { didSet { save() } }
    var cursor: Cursor { didSet { save() } }
    var cursorBlink: Bool { didSet { save() } }
    var copyOnSelect: Bool { didSet { save() } }
    var autocomplete: Bool { didSet { save() } }
    var scrollback: Int { didSet { save() } }
    var optionAsMeta: Bool { didSet { save() } }

    static let fontRange: ClosedRange<Double> = 9...28
    private let file = "terminal-settings.json"

    init() {
        let stored = JSONStore.load(file, default: Stored())
        fontSize = min(max(stored.fontSize, Self.fontRange.lowerBound), Self.fontRange.upperBound)
        cursor = stored.cursor
        cursorBlink = stored.cursorBlink
        copyOnSelect = stored.copyOnSelect
        autocomplete = stored.autocomplete
        scrollback = stored.scrollback
        optionAsMeta = stored.optionAsMeta
    }

    private func save() {
        JSONStore.save(Stored(fontSize: fontSize, cursor: cursor, cursorBlink: cursorBlink, copyOnSelect: copyOnSelect,
                              autocomplete: autocomplete, scrollback: scrollback, optionAsMeta: optionAsMeta), to: file)
    }

    var font: NSFont { NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular) }

    var cursorStyle: CursorStyle {
        switch (cursor, cursorBlink) {
        case (.bar, true): .blinkBar
        case (.bar, false): .steadyBar
        case (.block, true): .blinkBlock
        case (.block, false): .steadyBlock
        case (.underline, true): .blinkUnderline
        case (.underline, false): .steadyUnderline
        }
    }

    func bigger() { fontSize = min(Self.fontRange.upperBound, fontSize + 1) }
    func smaller() { fontSize = max(Self.fontRange.lowerBound, fontSize - 1) }
    func actualSize() { fontSize = 13 }
}

/// A theme's terminal palette, in the form SwiftTerm draws with. Themes
/// without one get a palette made from their base colours.
struct TerminalColors: Equatable {
    var background: NSColor
    var foreground: NSColor
    var cursor: NSColor
    var cursorText: NSColor
    var selection: NSColor
    /// Selected text keeps the theme's text colour (SwiftTerm's default is
    /// black, which disappears into a dark selection).
    var selectionText: NSColor
    var ansi: [SwiftTerm.Color]

    static let ansiKeys = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
                           "brightBlack", "brightRed", "brightGreen", "brightYellow", "brightBlue",
                           "brightMagenta", "brightCyan", "brightWhite"]

    /// The Situation theme's palette, for themes that have none.
    static let fallbackANSI = ["#2c2e31", "#f47a79", "#75d78d", "#f2c86c", "#75aef5", "#d28ce1", "#5ddae0", "#e6e8ea",
                               "#66696c", "#ff9e9b", "#9fe9ae", "#fdd990", "#9dc7fe", "#e1afed", "#99ebf0", "#f2f4f5"]

    /// `#rrggbb`, `#rrggbbaa` or `rgb(a)(r, g, b[, a])` as sRGB.
    static func srgb(_ text: String) -> (r: Double, g: Double, b: Double, a: Double)? {
        let s = text.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasPrefix("#") {
            let hex = String(s.dropFirst())
            guard hex.count == 6 || hex.count == 8, let v = UInt64(hex, radix: 16) else { return nil }
            let alpha = hex.count == 8
            return (Double((v >> (alpha ? 24 : 16)) & 0xff) / 255, Double((v >> (alpha ? 16 : 8)) & 0xff) / 255,
                    Double((v >> (alpha ? 8 : 0)) & 0xff) / 255, alpha ? Double(v & 0xff) / 255 : 1)
        }
        guard s.hasPrefix("rgb"), let open = s.firstIndex(of: "("), s.hasSuffix(")") else {
            // oklch() and friends: let the design system parse it.
            return ColorValue.parse(text).map { color in
                let ns = color.nsColor.usingColorSpace(.sRGB) ?? color.nsColor
                return (Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent), Double(ns.alphaComponent))
            }
        }
        let parts = s[s.index(after: open)..<s.index(before: s.endIndex)]
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" }).compactMap { Double($0) }
        guard parts.count >= 3 else { return nil }
        return (parts[0] / 255, parts[1] / 255, parts[2] / 255, parts.count > 3 ? parts[3] : 1)
    }

    static func ns(_ text: String?) -> NSColor? {
        text.flatMap(srgb).map { NSColor(srgbRed: $0.r, green: $0.g, blue: $0.b, alpha: $0.a) }
    }

    static func term(_ text: String) -> SwiftTerm.Color? {
        srgb(text).map { SwiftTerm.Color(red: UInt16($0.r * 65535), green: UInt16($0.g * 65535), blue: UInt16($0.b * 65535)) }
    }

    init(theme: ThemeFile?, palette: Palette) {
        let t = theme?.terminal ?? [:]
        background = Self.ns(t["background"]) ?? palette.terminal.nsColor
        foreground = Self.ns(t["foreground"]) ?? palette.ink.nsColor
        cursor = Self.ns(t["cursor"]) ?? palette.brand.nsColor
        cursorText = Self.ns(t["cursorAccent"]) ?? background
        selection = Self.ns(t["selectionBackground"]) ?? palette.brand.opacity(0.24).nsColor
        selectionText = Self.ns(t["selectionForeground"]) ?? foreground
        ansi = Self.ansiKeys.enumerated().map { index, key in
            t[key].flatMap(Self.term) ?? Self.term(Self.fallbackANSI[index])!
        }
    }

    static func == (a: TerminalColors, b: TerminalColors) -> Bool {
        a.background == b.background && a.foreground == b.foreground && a.cursor == b.cursor && a.selection == b.selection
            && a.selectionText == b.selectionText
            && a.ansi.count == b.ansi.count && zip(a.ansi, b.ansi).allSatisfy { $0.red == $1.red && $0.green == $1.green && $0.blue == $1.blue }
    }

    static var current: TerminalColors {
        TerminalColors(theme: ThemeStore.shared.current, palette: ThemeStore.shared.palette)
    }
}
