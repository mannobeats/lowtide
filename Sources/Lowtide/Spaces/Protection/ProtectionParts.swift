import AppKit
import LowtideKit
import SwiftUI

/// One of the app's glyphs on a small raised tile, the leading mark of an
/// area or a decoy row.
struct GlyphTile: View {
    @Environment(\.palette) private var palette
    let glyph: String
    var quiet = false
    var tone: Tone?

    var body: some View {
        NavIcon(glyph, size: 16)
            .foregroundStyle((tone?.color(palette) ?? (quiet ? palette.ink4 : palette.ink2)).color)
            .frame(width: 32, height: 32)
            .background((tone?.soft(palette) ?? palette.fill).color, in: .rect(cornerRadius: Radius.md))
            .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(palette.line.color))
    }
}

/// "Two things need you": counts as words, up to five.
enum CountWords {
    static func word(_ n: Int) -> String {
        ["No", "One", "Two", "Three", "Four", "Five"].indices.contains(n) ? ["No", "One", "Two", "Three", "Four", "Five"][n] : "\(n)"
    }

    /// `a, b and c`.
    static func list(_ items: [String]) -> String { items.formatted(.list(type: .and)) }
}
