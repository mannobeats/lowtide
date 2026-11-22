import LowtideKit
import SwiftUI

/// A theme file (examples in `Resources/themes`): base colours plus a terminal palette.
struct ThemeFile: Codable, Identifiable, Hashable {
    var format: String
    var version: Int
    var id: String
    var name: String
    var author: String?
    var description: String?
    var scheme: String
    var colors: [String: String]
    var terminal: [String: String]?
}

/// Every colour role a view uses, derived from a theme's base set.
/// Roles name a job, never a look. Views read `@Environment(\.palette)`.
struct Palette: Equatable {
    var dark: Bool
    var panel, terminal, bg, surface, overlay: ColorValue
    var ink, ink2, ink3, ink4: ColorValue
    var brand, onBrand, ok, warn, bad: ColorValue

    var fill: ColorValue { ink.opacity(0.06) }
    var hover: ColorValue { ink.opacity(0.06) }
    var selected: ColorValue { ink.opacity(0.10) }
    var selectedBrand: ColorValue { brand.opacity(dark ? 0.20 : 0.16) }
    var line: ColorValue { ink.opacity(0.08) }
    var lineStrong: ColorValue { ink.opacity(0.14) }
    var brandHover: ColorValue { brand.mixed(with: ink, 0.72) }
    var brandSoft: ColorValue { brand.opacity(0.14) }
    var ring: ColorValue { brand.opacity(0.55) }
    var okSoft: ColorValue { ok.opacity(0.13) }
    var warnSoft: ColorValue { warn.opacity(0.13) }
    var badSoft: ColorValue { bad.opacity(0.14) }
    var scrim: ColorValue { bg.mixed(with: ColorValue(r: 0, g: 0, b: 0), 0.5).opacity(0.6) }

    /// A space's hue at the top of the canvas.
    func wash(hue: Double) -> ColorValue {
        .oklch(dark ? 0.6 : 0.72, dark ? 0.13 : 0.10, hue, 0.12)
    }

    /// The hero art's rim light in a space's hue.
    func hueTint(_ hue: Double, strength: Double = 1) -> ColorValue {
        .oklch(dark ? 0.78 : 0.6, 0.12 * strength, hue)
    }

    init?(_ file: ThemeFile) {
        func c(_ key: String) -> ColorValue? { file.colors[key].flatMap(ColorValue.parse) }
        guard let bg = c("bg"), let ink = c("ink"), let brand = c("brand") else { return nil }
        dark = file.scheme != "light"
        self.bg = bg
        panel = c("panel") ?? bg
        surface = c("surface") ?? bg
        overlay = c("overlay") ?? surface
        terminal = c("terminal") ?? bg
        self.ink = ink
        ink2 = c("ink2") ?? ink.opacity(0.85)
        ink3 = c("ink3") ?? ink.opacity(0.68)
        ink4 = c("ink4") ?? ink.opacity(0.5)
        self.brand = brand
        onBrand = c("onBrand") ?? (brand.luminance > 0.4 ? ColorValue(r: 0.08, g: 0.1, b: 0.12) : ColorValue(r: 1, g: 1, b: 1))
        ok = c("ok") ?? .oklch(0.77, 0.15, 152)
        warn = c("warn") ?? .oklch(0.83, 0.14, 78)
        bad = c("bad") ?? .oklch(0.69, 0.19, 25)
    }

    static let fallback = Palette(ThemeFile(
        format: "lowtide-theme", version: 1, id: "situation", name: "Situation", scheme: "dark",
        colors: ["bg": "oklch(0.183 0.008 255)", "panel": "oklch(0.15 0.008 255)",
                 "surface": "oklch(0.215 0.008 255)", "overlay": "oklch(0.245 0.008 255)",
                 "terminal": "oklch(0.155 0.008 255)", "ink": "oklch(0.97 0.003 255)",
                 "ink2": "oklch(0.85 0.006 255)", "ink3": "oklch(0.69 0.009 255)",
                 "ink4": "oklch(0.52 0.009 255)", "brand": "oklch(0.79 0.12 200)",
                 "onBrand": "oklch(0.2 0.035 200)"]))!
}

extension EnvironmentValues {
    @Entry var palette: Palette = .fallback
}

/// The installed themes and the person's choice. "Automatic" follows the
/// Mac: Situation in dark mode, Paper in light.
@Observable
final class ThemeStore {
    static let shared = ThemeStore()
    static let automatic = "automatic"

    private(set) var themes: [ThemeFile] = []
    var choice: String {
        didSet { UserDefaults.standard.set(choice, forKey: "theme") }
    }
    /// The Mac's own appearance, kept current by the app.
    var systemDark = true

    init() {
        choice = UserDefaults.standard.string(forKey: "theme") ?? Self.automatic
        reload()
    }

    func reload() {
        var found: [ThemeFile] = []
        for folder in [AppResources.url("themes"), Paths.data.appending(path: "themes")] {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for url in files where url.pathExtension == "json" {
                guard let data = try? Data(contentsOf: url),
                      let theme = try? JSONDecoder().decode(ThemeFile.self, from: data),
                      theme.format == "lowtide-theme", Palette(theme) != nil
                else { continue }
                found.removeAll { $0.id == theme.id }
                found.append(theme)
            }
        }
        let order = ["situation", "paper", "graphite", "arctic", "amber", "crimson", "phosphor"]
        themes = found.sorted { (order.firstIndex(of: $0.id) ?? 99, $0.name) < (order.firstIndex(of: $1.id) ?? 99, $1.name) }
    }

    var current: ThemeFile? {
        let id = choice == Self.automatic ? (systemDark ? "situation" : "paper") : choice
        return themes.first { $0.id == id } ?? themes.first { $0.id == "situation" }
    }

    var palette: Palette { current.flatMap(Palette.init) ?? .fallback }

    var colorScheme: ColorScheme { palette.dark ? .dark : .light }

    /// Installs a theme file the person picked; returns its name.
    func install(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let theme = try JSONDecoder().decode(ThemeFile.self, from: data)
        guard Palette(theme) != nil else { throw LowtideError.invalid("This theme has no bg, ink or brand colour.") }
        let folder = Paths.data.appending(path: "themes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appending(path: "\(theme.id).json"), options: .atomic)
        reload()
        choice = theme.id
        return theme.name
    }
}
