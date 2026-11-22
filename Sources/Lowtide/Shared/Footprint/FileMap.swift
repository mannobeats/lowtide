import LowtideKit
import SwiftUI

/// A squarified map of files and folders, built on `TreemapView.layout`:
/// area by size, a label where it fits, a click to open or select, and the
/// path menu on every tile (Finder, Quick Look, Copy Path, Trash). Space
/// lens shows one folder with it; the footprint map shows an app's files
/// grouped by kind.
struct FileMap: View {
    struct Cell: Identifiable {
        enum Style { case folder, file, selected, kept, removed, shared, more }
        let id: String
        let name: String
        let bytes: Int64?
        /// What the tile's area follows (bytes, or a softened weight).
        let weight: Double
        var path: String?
        var style: Style
        var detail: String?
    }

    struct Group: Identifiable {
        let id: String
        var title: String?
        var bytes: Int64?
        var cells: [Cell]
    }

    @Environment(\.palette) private var palette
    let groups: [Group]
    var height: CGFloat = 260
    var onTap: (Cell) -> Void = { _ in }
    var onTrash: ((Cell) -> Void)?
    @State private var hovered: String?

    var body: some View {
        GeometryReader { geo in
            let outer = Self.rects(groups.map { ($0.id, $0.cells.reduce(0) { $0 + $1.weight }) },
                                   in: CGRect(origin: .zero, size: geo.size))
            ZStack(alignment: .topLeading) {
                ForEach(groups) { group in
                    if let rect = outer[group.id] {
                        let labelled = group.title != nil && rect.height > 36 && rect.width > 70
                        let inner = labelled ? CGRect(x: rect.minX + 1, y: rect.minY + 16, width: rect.width - 2, height: rect.height - 17)
                            : rect.insetBy(dx: 1, dy: 1)
                        if labelled, let title = group.title {
                            HStack(spacing: 4) {
                                Text(title).foregroundStyle(palette.ink3.color)
                                if let bytes = group.bytes { Text(LowtideFormat.bytes(bytes)).font(.mono(.xxs)).foregroundStyle(palette.ink4.color) }
                            }
                            .font(.ui(.xxs)).lineLimit(1)
                            .padding(.horizontal, 6)
                            .frame(width: rect.width, height: 16, alignment: .leading)
                            .offset(x: rect.minX, y: rect.minY)
                        }
                        let cells = Self.rects(group.cells.map { ($0.id, $0.weight) }, in: inner)
                        ForEach(group.cells) { cell in
                            if let r = cells[cell.id] { tile(cell, r) }
                        }
                    }
                }
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .contain)
    }

    /// `TreemapView.layout` by id; weights scaled to integers it can take.
    static func rects(_ weights: [(String, Double)], in rect: CGRect) -> [String: CGRect] {
        let items = weights.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
            .map { TreemapItem(id: $0.0, name: $0.0, size: Int64(max(1, ($0.1 * 1000).rounded()))) }
        var out: [String: CGRect] = [:]
        for (item, r) in TreemapView.layout(items, in: rect) { out[item.id] = r }
        return out
    }

    private func colors(_ style: Cell.Style, on: Bool) -> (fill: ColorValue, edge: ColorValue, dashed: Bool) {
        switch style {
        case .folder: (palette.brand.opacity(on ? 0.3 : 0.16), palette.brand.opacity(0.3), false)
        case .file: (on ? palette.selected : palette.fill, palette.line, false)
        case .selected: (palette.bad.opacity(on ? 0.3 : 0.16), palette.bad.opacity(0.5), false)
        case .removed: (palette.brand.opacity(on ? 0.3 : 0.2), palette.brand.opacity(0.35), false)
        case .shared: (palette.warn.opacity(on ? 0.3 : 0.2), palette.warn.opacity(0.4), false)
        case .kept: (on ? palette.hover : Clean.clear, palette.lineStrong, true)
        case .more: (Clean.clear, palette.line, true)
        }
    }

    private func tile(_ cell: Cell, _ rect: CGRect) -> some View {
        let on = hovered == cell.id
        let (fill, edge, dashed) = colors(cell.style, on: on)
        let radius = min(Radius.sm, rect.width / 4, rect.height / 4)
        return RoundedRectangle(cornerRadius: radius)
            .fill(fill.color)
            .overlay(RoundedRectangle(cornerRadius: radius)
                .strokeBorder(edge.color, style: StrokeStyle(lineWidth: 1, dash: dashed ? [3, 2] : [])))
            .overlay(alignment: cell.style == .more ? .center : .topLeading) {
                if cell.style == .more {
                    if rect.width > 60 { Text(cell.name).font(.ui(.xxs)).foregroundStyle(palette.ink3.color).monospacedDigit() }
                } else if rect.width > 64, rect.height > 26 {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(cell.name).font(.ui(.xxs)).foregroundStyle(palette.ink.color).lineLimit(1)
                        if rect.height > 42, let bytes = cell.bytes {
                            Text(LowtideFormat.bytes(bytes)).font(.mono(.xxs)).foregroundStyle(palette.ink3.color)
                        }
                    }
                    .padding(.horizontal, 6).padding(.top, 5)
                }
            }
            .frame(width: max(rect.width - 3, 1), height: max(rect.height - 3, 1))
            .contentShape(.rect)
            .offset(x: rect.minX + 1.5, y: rect.minY + 1.5)
            .onHover { hovered = $0 ? cell.id : (hovered == cell.id ? nil : hovered) }
            .onTapGesture { if cell.style != .more { onTap(cell) } }
            .help([cell.name, cell.bytes.map(LowtideFormat.bytes), cell.path.map(Clean.tilde), cell.detail].compactMap { $0 }.joined(separator: "\n"))
            .contextMenu {
                if let path = cell.path {
                    PathMenu(path, onTrash: onTrash.map { trash in { trash(cell) } })
                }
            }
            .accessibilityLabel("\(cell.name), \(cell.bytes.map(LowtideFormat.bytes) ?? "size unknown")")
            .accessibilityAddTraits(.isButton)
            .animation(Motion.fast, value: on)
    }
}
