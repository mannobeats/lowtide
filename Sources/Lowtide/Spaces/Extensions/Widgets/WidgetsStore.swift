import LowtideKit
import SwiftUI

/// The widgets the person picked, in menu-bar order, and the strip's colour
/// preset. Whether the extension is on lives in `extension.widgets`
/// (the Extensions gallery toggles it).
@Observable
final class WidgetsStore {
    static let shared = WidgetsStore()
    static let enabledKey = "extension.widgets"
    static let changedNotification = Notification.Name("Lowtide.extensionsChanged")

    private static let listKey = "widgets.list"
    private static let colorKey = "widgets.color"

    var widgets: [WidgetSpec] { didSet { save() } }
    var color: WidgetColor { didSet { UserDefaults.standard.set(color.rawValue, forKey: Self.colorKey); changed() } }
    private(set) var enabled: Bool

    init() {
        let defaults = UserDefaults.standard
        widgets = defaults.data(forKey: Self.listKey).flatMap { try? JSONDecoder().decode([WidgetSpec].self, from: $0) }
            ?? WidgetSpec.defaults
        color = defaults.string(forKey: Self.colorKey).flatMap(WidgetColor.init(rawValue:)) ?? .load
        enabled = ExtensionState.isOn(.widgets)
    }

    /// Re-reads the on/off switch (after the gallery changed it).
    func reloadEnabled() { enabled = ExtensionState.isOn(.widgets) }

    func setEnabled(_ on: Bool) {
        ExtensionState.set(.widgets, on)
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
    }

    /// Each widget with the preset it draws in.
    func resolved(_ strip: WidgetColor? = nil) -> [(WidgetSpec, WidgetColor)] {
        widgets.map { ($0, strip ?? $0.color ?? color) }
    }

    func add(_ metric: WidgetMetric) { widgets.append(WidgetSpec(metric: metric)) }

    func remove(_ id: String) { widgets.removeAll { $0.id == id } }

    func move(_ id: String, to index: Int) {
        guard let from = widgets.firstIndex(where: { $0.id == id }), widgets.indices.contains(index), from != index else { return }
        let item = widgets.remove(at: from)
        widgets.insert(item, at: index)
    }

    func setStyle(_ id: String, _ style: WidgetStyle) {
        guard let i = widgets.firstIndex(where: { $0.id == id }) else { return }
        widgets[i].style = style
    }

    func setColor(_ id: String, _ color: WidgetColor?) {
        guard let i = widgets.firstIndex(where: { $0.id == id }) else { return }
        widgets[i].color = color
    }

    private func save() {
        if let data = try? JSONEncoder().encode(widgets) { UserDefaults.standard.set(data, forKey: Self.listKey) }
        changed()
    }

    private func changed() { WidgetsStatusItem.shared.redraw() }
}

/// Drawing the strip from the live readings, for the menu bar and the page.
enum WidgetDrawing {
    /// One widget with live readings, or nil when this Mac can't show it.
    static func bitmap(_ spec: WidgetSpec, color: WidgetColor, readings: WidgetReadings, dark: Bool,
                       scale: Double = 2) -> WidgetBitmap? {
        guard let piece = widgetPiece(spec.metric, spec.style, readings) else { return nil }
        return WidgetRenderer.strip([(piece, widgetTone(spec.metric, color, readings))], dark: dark, scale: scale)
    }

    /// Several widgets as one strip.
    static func strip(_ specs: [(WidgetSpec, WidgetColor)], readings: WidgetReadings, dark: Bool, scale: Double = 2) -> WidgetBitmap? {
        let pieces = specs.compactMap { spec, color in
            widgetPiece(spec.metric, spec.style, readings).map { ($0, widgetTone(spec.metric, color, readings)) }
        }
        return pieces.isEmpty ? nil : WidgetRenderer.strip(pieces, dark: dark, scale: scale)
    }

    @MainActor static var readings: WidgetReadings {
        WidgetReadings(samples: SystemModel.shared.samples, detail: SystemModel.shared.detail)
    }
}

/// A widget exactly as the menu bar draws it: a template tinted with the
/// text colour, or a coloured drawing made for the bar behind it.
struct WidgetGlyph: View {
    let bitmap: WidgetBitmap?
    /// Shrinks to the width it's given (never grows past its own size), so a
    /// whole strip fits a narrow tile.
    var fit = false

    var body: some View {
        if let bitmap {
            let image = Image(decorative: bitmap.image, scale: bitmap.scale)
            let drawn = Group {
                if bitmap.template { image.renderingMode(.template) } else { image }
            }
            if fit {
                let scaled = image.resizable().interpolation(.high)
                Group {
                    if bitmap.template { scaled.renderingMode(.template) } else { scaled }
                }
                .aspectRatio(bitmap.size, contentMode: .fit)
                .frame(maxWidth: bitmap.size.width, maxHeight: bitmap.size.height)
            } else {
                drawn.frame(width: bitmap.size.width, height: bitmap.size.height)
            }
        } else {
            RoundedRectangle(cornerRadius: 3).fill(.quaternary).frame(width: 32, height: 18)
        }
    }
}
