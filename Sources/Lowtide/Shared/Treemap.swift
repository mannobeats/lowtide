import SwiftUI

/// One tile of a treemap.
struct TreemapItem: Identifiable, Hashable {
    let id: String
    var name: String
    var size: Int64
    var path: String?
    var tone: Tone = .brand
    static func == (a: TreemapItem, b: TreemapItem) -> Bool { a.id == b.id && a.size == b.size }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A squarified treemap: where the space goes, at a glance. Shared by
/// Installed, Leftovers, Add-ons and Space Lens. Tiles too small to read
/// draw without a label.
struct TreemapView: View {
    @Environment(\.palette) private var palette
    let items: [TreemapItem]
    var selection: TreemapItem.ID?
    var onSelect: (TreemapItem) -> Void = { _ in }
    @State private var hovered: TreemapItem.ID?

    var body: some View {
        GeometryReader { geo in
            let tiles = Self.layout(items.filter { $0.size > 0 }.sorted { $0.size > $1.size },
                                    in: CGRect(origin: .zero, size: geo.size))
            ZStack(alignment: .topLeading) {
                ForEach(tiles, id: \.0.id) { item, rect in
                    tile(item, rect)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func tile(_ item: TreemapItem, _ rect: CGRect) -> some View {
        let on = item.id == selection || item.id == hovered
        let base = item.tone.color(palette)
        return RoundedRectangle(cornerRadius: min(Radius.md, rect.width / 4, rect.height / 4))
            .fill(base.opacity(on ? 0.42 : 0.22).color)
            .overlay(alignment: .topLeading) {
                if rect.width > 64, rect.height > 30 {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name).font(.ui(.xs, .medium)).foregroundStyle(palette.ink.color).lineLimit(1)
                        Text(LowtideFormat.bytes(item.size)).font(.mono(.xxs)).foregroundStyle(palette.ink2.color)
                    }
                    .padding(6)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: min(Radius.md, rect.width / 4, rect.height / 4))
                .strokeBorder(base.opacity(on ? 0.9 : 0.35).color, lineWidth: on ? 1.5 : 1))
            .frame(width: max(rect.width - 2, 1), height: max(rect.height - 2, 1))
            .offset(x: rect.minX + 1, y: rect.minY + 1)
            .onHover { hovered = $0 ? item.id : (hovered == item.id ? nil : hovered) }
            .onTapGesture { onSelect(item) }
            .help("\(item.name): \(LowtideFormat.bytes(item.size))")
            .accessibilityLabel("\(item.name), \(LowtideFormat.bytes(item.size))")
            .accessibilityAddTraits(.isButton)
    }

    /// Squarified layout (Bruls, Huizing, van Wijk): rows whose tiles stay
    /// close to square.
    static func layout(_ items: [TreemapItem], in rect: CGRect) -> [(TreemapItem, CGRect)] {
        let total = Double(items.reduce(0) { $0 + $1.size })
        guard total > 0, rect.width > 0, rect.height > 0 else { return [] }
        let scale = Double(rect.width * rect.height) / total
        var result: [(TreemapItem, CGRect)] = []
        var remaining = items[...]
        var free = rect
        while !remaining.isEmpty {
            let side = Double(min(free.width, free.height))
            var row: [TreemapItem] = []
            var best = Double.infinity
            while let next = remaining.first {
                let candidate = row + [next]
                let worst = worstRatio(candidate.map { Double($0.size) * scale }, side: side)
                if worst > best { break }
                best = worst
                row = candidate
                remaining = remaining.dropFirst()
            }
            let area = row.reduce(0.0) { $0 + Double($1.size) * scale }
            let horizontal = free.width >= free.height
            let thickness = CGFloat(area / side)
            var offset: CGFloat = 0
            for item in row {
                let length = CGFloat(Double(item.size) * scale / Double(thickness))
                let r = horizontal
                    ? CGRect(x: free.minX, y: free.minY + offset, width: thickness, height: length)
                    : CGRect(x: free.minX + offset, y: free.minY, width: length, height: thickness)
                result.append((item, r))
                offset += length
            }
            free = horizontal
                ? CGRect(x: free.minX + thickness, y: free.minY, width: free.width - thickness, height: free.height)
                : CGRect(x: free.minX, y: free.minY + thickness, width: free.width, height: free.height - thickness)
        }
        return result
    }

    private static func worstRatio(_ areas: [Double], side: Double) -> Double {
        let sum = areas.reduce(0, +)
        guard let maxA = areas.max(), let minA = areas.min(), sum > 0 else { return .infinity }
        let s2 = side * side, sum2 = sum * sum
        return max(s2 * maxA / sum2, sum2 / (s2 * minA))
    }
}

/// LowtideKit's formatting, under a name that can't clash with a view's own.
typealias LowtideFormat = LowtideKitFormat
