import LowtideKit
import SwiftUI
import UniformTypeIdentifiers

/// Extensions → Menu bar widgets: pick, order, style and colour the live
/// widgets beside the menu bar icon.
struct WidgetsPage: View {
    @Environment(\.palette) private var palette
    private var store = WidgetsStore.shared
    private var model = SystemModel.shared
    @State private var barDark: Bool?

    var body: some View {
        // Read each second through the model, so the previews are live.
        let readings = WidgetReadings(samples: model.samples, detail: model.detail)
        let dark = barDark ?? palette.dark
        PageScaffold(maxWidth: 820) {
            PageHero(title, detail: "CPU, memory, network and more, live in the menu bar. Click them for the details.",
                     art: "widgets") {
                if store.enabled {
                    Button("Turn Off") { store.setEnabled(false) }.buttonStyle(.secondary)
                } else {
                    Button("Turn On") { store.setEnabled(true) }.buttonStyle(.primary)
                }
            }
        } content: {
            MenuBarPreview(readings: readings, dark: dark, barDark: Binding(get: { dark }, set: { barDark = $0 }))
            ColorPresets(readings: readings, dark: dark)
            ShownList(readings: readings)
            Gallery(readings: readings, loaded: model.latest != nil)
        }
        .systemFeed("page.widgets")
    }

    private var title: String {
        guard store.enabled else { return "Menu bar widgets are off" }
        return store.widgets.isEmpty ? "No widgets in the menu bar" : "\(LowtideFormat.count(store.widgets.count, "widget")) in the menu bar"
    }
}

/// A strip of widgets on a menu bar of either appearance, drawn on the
/// bar material macOS itself uses.
private struct Strip: View {
    let bitmap: WidgetBitmap?
    let dark: Bool
    var trailingRoom: CGFloat = 0
    /// Scales the widgets down to the width it's given, as in a narrow tile.
    var fit = false

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            if let bitmap { WidgetGlyph(bitmap: bitmap, fit: fit).foregroundStyle(.primary) }
        }
        .padding(.leading, Space.md)
        .padding(.trailing, Space.md + trailingRoom)
        .frame(height: 24)
        .background(.bar, in: .rect(cornerRadius: Radius.sm))
        .overlay(RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(.separator))
        .environment(\.colorScheme, dark ? .dark : .light)
        .clipped()
    }
}

private struct MenuBarPreview: View {
    @Environment(\.palette) private var palette
    private var store = WidgetsStore.shared
    let readings: WidgetReadings
    let dark: Bool
    @Binding var barDark: Bool

    init(readings: WidgetReadings, dark: Bool, barDark: Binding<Bool>) {
        self.readings = readings
        self.dark = dark
        _barDark = barDark
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                GroupHeading("Menu bar")
                Segmented($barDark, [(true, "Dark"), (false, "Light")])
            }
            Strip(bitmap: WidgetDrawing.strip(store.resolved(), readings: readings, dark: dark), dark: dark, trailingRoom: 28)
                .overlay(alignment: .trailing) {
                    // Lowtide's own icon, where it sits beside the widgets.
                    Image(nsImage: Logo.menuBar).foregroundStyle(.primary)
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .padding(.trailing, Space.md)
                }
                .opacity(store.enabled ? 1 : 0.4)
                .accessibilityLabel("Preview of the widgets in the menu bar")
            if !store.enabled {
                HStack {
                    Text("Widgets are off.").font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                    Spacer()
                    Button("Turn On") { store.setEnabled(true) }.buttonStyle(.lowtide(.secondary, size: .small))
                }
                .padding(.horizontal, Space.xs)
            }
        }
    }
}

/// The colour presets, each tile showing the strip drawn in it.
private struct ColorPresets: View {
    @Environment(\.palette) private var palette
    private var store = WidgetsStore.shared
    let readings: WidgetReadings
    let dark: Bool

    init(readings: WidgetReadings, dark: Bool) {
        self.readings = readings
        self.dark = dark
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            GroupHeading("Colour")
            // Equal columns inside the page's width, whatever the window's.
            Grid(horizontalSpacing: Space.sm) {
                GridRow {
                    ForEach(WidgetColor.allCases, id: \.self) { color in
                        let on = store.color == color
                        Button { store.color = color } label: {
                            VStack(alignment: .leading, spacing: Space.sm) {
                                Strip(bitmap: WidgetDrawing.strip(store.resolved(color), readings: readings, dark: dark), dark: dark, fit: true)
                                Text(color.label).font(.ui(.xs, on ? .medium : .regular))
                                    .foregroundStyle((on ? palette.ink : palette.ink2).color)
                                    .padding(.horizontal, 2)
                            }
                            .padding(Space.sm)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .card(radius: Radius.lg)
                            .overlay(RoundedRectangle(cornerRadius: Radius.lg)
                                .strokeBorder(on ? palette.brand.color : .clear, lineWidth: 2))
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .help(color.hint)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
        }
    }
}

private struct ShownList: View {
    @Environment(\.palette) private var palette
    private var store = WidgetsStore.shared
    let readings: WidgetReadings
    @State private var dragged: String?

    init(readings: WidgetReadings) { self.readings = readings }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            GroupHeading("Shown", trailing: store.widgets.count > 1 ? "Drag to reorder" : nil)
            if store.widgets.isEmpty {
                Text("None yet. Add one below.").font(.ui(.sm)).foregroundStyle(palette.ink3.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.lg)
                    .card()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(store.widgets.enumerated()), id: \.element.id) { index, widget in
                        if index > 0 { Hairline() }
                        WidgetRow(widget: widget, index: index, readings: readings, dragging: dragged == widget.id)
                            .onDrag {
                                dragged = widget.id
                                return NSItemProvider(object: widget.id as NSString)
                            }
                            .onDrop(of: [.plainText], delegate: Reorder(target: widget.id, index: index, dragged: $dragged))
                    }
                }
                .card()
            }
        }
    }

    /// Moves the dragged row into place as it passes over others.
    private struct Reorder: DropDelegate {
        let target: String
        let index: Int
        @Binding var dragged: String?

        func dropEntered(info: DropInfo) {
            guard let dragged, dragged != target else { return }
            withAnimation(Motion.spring) { WidgetsStore.shared.move(dragged, to: index) }
        }

        func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

        func performDrop(info: DropInfo) -> Bool {
            dragged = nil
            return true
        }
    }
}

private struct WidgetRow: View {
    @Environment(\.palette) private var palette
    private var store = WidgetsStore.shared
    let widget: WidgetSpec
    let index: Int
    let readings: WidgetReadings
    let dragging: Bool
    @State private var hovering = false

    init(widget: WidgetSpec, index: Int, readings: WidgetReadings, dragging: Bool) {
        self.widget = widget
        self.index = index
        self.readings = readings
        self.dragging = dragging
    }

    var body: some View {
        let bitmap = WidgetDrawing.bitmap(widget, color: widget.color ?? store.color, readings: readings, dark: palette.dark)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Space.md) {
                Image(systemName: "line.3.horizontal")
                    .font(.ui(.xs, .medium))
                    .foregroundStyle((hovering ? palette.ink2 : palette.ink4).color)
                    .frame(width: 16)
                    .help("Drag to reorder")
                Group {
                    if bitmap != nil {
                        WidgetGlyph(bitmap: bitmap, fit: true).foregroundStyle(palette.ink.color)
                    } else {
                        Text("Not on this Mac").font(.ui(.xxs)).foregroundStyle(palette.ink3.color)
                    }
                }
                .frame(width: 72, alignment: .leading)
                Text(widget.metric.label).font(.ui(.sm)).foregroundStyle(palette.ink.color).lineLimit(1)
                Spacer(minLength: Space.sm)
                Picker("Colour", selection: Binding(get: { widget.color }, set: { store.setColor(widget.id, $0) })) {
                    Text("Strip (\(store.color.label))").tag(WidgetColor?.none)
                    Divider()
                    ForEach(WidgetColor.allCases, id: \.self) { Text($0.label).tag(WidgetColor?.some($0)) }
                }
                .labelsHidden()
                .fixedSize()
                .help("This widget's colour")
                IconButton("xmark", help: "Remove \(widget.metric.label)") {
                    withAnimation(Motion.base) { store.remove(widget.id) }
                }
                .opacity(hovering ? 1 : 0.6)
            }
            if widget.metric.styles.count > 1 {
                Segmented(Binding(get: { widget.style }, set: { store.setStyle(widget.id, $0) }),
                          widget.metric.styles.map { ($0, $0.label) })
                    .padding(.leading, 16 + Space.md + 72 + Space.md)
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
        .frame(minHeight: 44)
        .opacity(dragging ? 0.4 : 1)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Move Up") { store.move(widget.id, to: index - 1) }.disabled(index == 0)
            Button("Move Down") { store.move(widget.id, to: index + 1) }.disabled(index == store.widgets.count - 1)
            Divider()
            Button("Remove", role: .destructive) { store.remove(widget.id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(widget.metric.label)
        .accessibilityAction(named: "Move Up") { store.move(widget.id, to: index - 1) }
        .accessibilityAction(named: "Move Down") { store.move(widget.id, to: index + 1) }
    }
}

private struct Gallery: View {
    @Environment(\.palette) private var palette
    private var store = WidgetsStore.shared
    let readings: WidgetReadings
    let loaded: Bool

    init(readings: WidgetReadings, loaded: Bool) {
        self.readings = readings
        self.loaded = loaded
    }

    var body: some View {
        // Once read, a metric this Mac lacks (no battery, no fans) drops out.
        let items = WidgetMetric.allCases.compactMap { metric -> (WidgetMetric, WidgetBitmap?)? in
            let spec = WidgetSpec(id: "gallery-\(metric.rawValue)", metric: metric, style: metric.styles[0])
            let bitmap = WidgetDrawing.bitmap(spec, color: store.color, readings: readings, dark: palette.dark)
            return loaded && bitmap == nil ? nil : (metric, bitmap)
        }
        VStack(alignment: .leading, spacing: Space.sm) {
            GroupHeading("Add")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: Space.sm)], spacing: Space.sm) {
                ForEach(items, id: \.0) { metric, bitmap in
                    GalleryTile(metric: metric, bitmap: bitmap) {
                        withAnimation(Motion.base) { store.add(metric) }
                    }
                }
            }
        }
    }
}

private struct GalleryTile: View {
    @Environment(\.palette) private var palette
    let metric: WidgetMetric
    let bitmap: WidgetBitmap?
    let add: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: add) {
            VStack(alignment: .leading) {
                WidgetGlyph(bitmap: bitmap).foregroundStyle(palette.ink.color).frame(height: 24, alignment: .leading)
                Spacer(minLength: 0)
                HStack {
                    Text(metric.label).font(.ui(.xs)).foregroundStyle(palette.ink2.color)
                    Spacer()
                    Image(systemName: "plus").font(.ui(.xs, .medium))
                        .foregroundStyle((hovering ? palette.brand : palette.ink4).color)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 80, maxHeight: 80, alignment: .leading)
            .card(radius: Radius.lg)
            .overlay(RoundedRectangle(cornerRadius: Radius.lg).strokeBorder(hovering ? palette.lineStrong.color : .clear))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.fast, value: hovering)
        .help("Add \(metric.label)")
        .accessibilityLabel("Add \(metric.label)")
    }
}
