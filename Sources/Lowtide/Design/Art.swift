import AppKit
import LowtideKit
import SwiftUI

/// The app's own glyphs (a 24 grid, 1.5 stroke, outline
/// and filled-when-selected), drawn from `Resources/glyphs/<name>[.fill].svg`
/// as vector template images, tinted like text.
enum Glyphs {
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor
    static func image(_ name: String, filled: Bool = false) -> NSImage {
        let key = filled ? "\(name).fill" : name
        if let hit = cache[key] { return hit }
        let url = AppResources.url("glyphs/\(key).svg")
        let image = (try? Data(contentsOf: url)).flatMap(NSImage.init(data:))
            ?? (filled ? image(name) : NSImage(systemSymbolName: "questionmark.square.dashed", accessibilityDescription: nil)!)
        image.isTemplate = true
        cache[key] = image
        return image
    }

    @MainActor
    static func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: AppResources.url("glyphs/\(name).svg").path)
    }
}

/// One of the app's own glyphs. Colour it with `.foregroundStyle`.
struct NavIcon: View {
    let name: String
    var filled = false
    var size: CGFloat = 16

    init(_ name: String, filled: Bool = false, size: CGFloat = 16) {
        self.name = name
        self.filled = filled
        self.size = size
    }

    var body: some View {
        Image(nsImage: Glyphs.image(name, filled: filled))
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A space's hero object: a graphite glass slab with the space's mark
/// embossed on it and one rim light in the space's hue
/// (`Resources/heroes/<name>.svg`). Materials follow the theme.
struct HeroArt: View {
    @Environment(\.palette) private var palette
    @Environment(\.spaceHue) private var hue
    let name: String
    var size: CGFloat = 88

    init(_ name: String, size: CGFloat = 88) {
        self.name = name
        self.size = size
    }

    var body: some View {
        Image(nsImage: HeroRenderer.image(name, palette: palette, hue: hue))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

enum HeroRenderer {
    @MainActor private static var templates: [String: String] = [:]
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor
    static func image(_ name: String, palette: Palette, hue: Double) -> NSImage {
        let key = "\(name)|\(palette.bg.r)\(palette.ink.r)\(palette.surface.g)|\(Int(hue))"
        if let hit = cache[key] { return hit }
        if templates[name] == nil {
            templates[name] = (try? String(contentsOf: AppResources.url("heroes/\(name).svg"), encoding: .utf8)) ?? ""
        }
        var svg = templates[name] ?? ""
        for (variable, value) in materials(palette, hue: hue) {
            svg = svg.replacingOccurrences(of: "var(\(variable))", with: value)
        }
        let image = NSImage(data: Data(svg.utf8)) ?? NSImage()
        if cache.count > 64 { cache.removeAll() }
        cache[key] = image
        return image
    }

    /// The hero art's materials, per scheme.
    static func materials(_ p: Palette, hue: Double) -> [(String, String)] {
        let black = ColorValue(r: 0, g: 0, b: 0), white = ColorValue(r: 1, g: 1, b: 1)
        if p.dark {
            return [
                ("--ha-face-top", css(p.ink.mixed(with: p.surface, 0.30))),
                ("--ha-face-bot", css(p.ink.mixed(with: p.panel, 0.04))),
                ("--ha-side", css(p.panel.mixed(with: black, 0.70))),
                ("--ha-inset-top", css(p.panel.mixed(with: black, 0.55))),
                ("--ha-inset-bot", css(p.ink.mixed(with: p.panel, 0.09))),
                ("--ha-hi", "#ffffff"),
                ("--ha-rim", css(.oklch(0.8, 0.15, hue))),
                ("--ha-mark-top", "#ffffff"),
                ("--ha-mark-bot", css(.oklch(0.84, 0.035, hue))),
                ("--ha-mark-shadow", "rgba(0,0,0,0.65)"),
                ("--ha-ground", "rgba(0,0,0,0.6)"),
                ("--ha-aura", "0.32"),
            ]
        }
        return [
            ("--ha-face-top", css(p.surface.mixed(with: white, 0.60))),
            ("--ha-face-bot", css(p.ink.mixed(with: p.bg, 0.13))),
            ("--ha-side", css(p.ink.mixed(with: p.bg, 0.34))),
            ("--ha-inset-top", css(p.ink.mixed(with: p.bg, 0.18))),
            ("--ha-inset-bot", css(p.ink.mixed(with: p.surface, 0.03))),
            ("--ha-hi", "#ffffff"),
            ("--ha-rim", css(.oklch(0.66, 0.16, hue))),
            ("--ha-mark-top", css(p.ink.mixed(with: p.bg, 0.72))),
            ("--ha-mark-bot", css(p.ink)),
            ("--ha-mark-shadow", "rgba(255,255,255,0.95)"),
            ("--ha-ground", "rgba(0,0,0,0.2)"),
            ("--ha-aura", "0.12"),
        ]
    }

    /// An sRGB CSS colour for the SVG renderer.
    static func css(_ c: ColorValue) -> String {
        let s = c.nsColor.usingColorSpace(.sRGB) ?? c.nsColor
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return c.a >= 0.999
            ? String(format: "#%02x%02x%02x", byte(s.redComponent), byte(s.greenComponent), byte(s.blueComponent))
            : "rgba(\(byte(s.redComponent)),\(byte(s.greenComponent)),\(byte(s.blueComponent)),\(String(format: "%.3f", c.a)))"
    }
}

/// Lowtide mark: an eye whose pupil is a terminal block cursor.
struct Logo: View {
    var size: CGFloat = 28
    var body: some View {
        Image(nsImage: Self.image).resizable().frame(width: size, height: size).accessibilityLabel("Lowtide")
    }
    @MainActor static let image: NSImage = (try? Data(contentsOf: AppResources.url("logo.svg"))).flatMap(NSImage.init(data:)) ?? NSImage()

    /// The mark alone, as a template so the menu bar tints it like its neighbours.
    @MainActor static let menuBar: NSImage = {
        let image = (try? Data(contentsOf: AppResources.url("menubar.svg"))).flatMap(NSImage.init(data:)) ?? NSImage()
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = "Lowtide"
        return image
    }()
}
