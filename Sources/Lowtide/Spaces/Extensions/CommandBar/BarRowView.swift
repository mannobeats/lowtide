import LowtideKit
import SwiftUI

/// One row of the bar: icon, title with the typed letters in bold, a quiet
/// subtitle, and on the right its value, keys or kind.
struct BarRowView: View {
    @Environment(\.palette) private var palette
    @Environment(\.privacy) private var privacy
    let row: BarRow
    let selected: Bool
    /// ⌘1–9 for Quick access rows.
    let badge: Int?
    let query: String

    var body: some View {
        HStack(spacing: 10) {
            BarIconView(icon: row.icon)
                .overlay(alignment: .topTrailing) {
                    if row.active {
                        Circle().fill(palette.ok.color).frame(width: 8, height: 8)
                            .overlay(Circle().strokeBorder(palette.overlay.color, lineWidth: 1.5))
                            .offset(x: 2, y: -2)
                            .accessibilityLabel("Running")
                    }
                }
            if row.answer {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title).font(.title(.xl)).monospacedDigit().foregroundStyle(palette.ink.color).lineLimit(1)
                        .textSelection(.enabled)
                    Text(row.subtitle ?? "").font(.ui(.xs)).foregroundStyle(palette.ink3.color).lineLimit(1)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    highlighted.font(.ui(.md)).foregroundStyle(palette.ink.color).lineLimit(1)
                    if let subtitle = row.subtitle {
                        Text(shown(subtitle)).font(.ui(.md)).foregroundStyle(palette.ink3.color).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            Spacer(minLength: Space.sm)
            accessory
        }
        .padding(.horizontal, Space.md)
        .frame(height: row.answer ? 64 : 40)
        // 8 inside the list's 8 pt inset: concentric with the panel's 16.
        .background((selected ? palette.selected : ColorValue(r: 0, g: 0, b: 0, a: 0)).color,
                    in: .rect(cornerRadius: Radius.md, style: .continuous))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    /// Privacy Mode masks hosts, addresses and home folders in subtitles.
    private func shown(_ text: String) -> String { privacy ? PrivacyText.redact(text) : text }

    private var highlighted: Text {
        let title = row.title
        let ranges = Ranking.highlights(title, query.hasPrefix(":") ? String(query.dropFirst()) : query)
        guard !ranges.isEmpty else { return Text(title) }
        var attributed = AttributedString(title)
        let chars = Array(title)
        var offset = 0
        var at = attributed.startIndex
        for range in ranges where range.lowerBound >= offset {
            at = attributed.characters.index(at, offsetBy: range.lowerBound - offset)
            let end = attributed.characters.index(at, offsetBy: min(range.count, chars.count - range.lowerBound))
            attributed[at..<end].font = .ui(.md, .semibold)
            at = end
            offset = range.upperBound
        }
        return Text(attributed)
    }

    static let kindLabel: [BarSource: String] = [
        .apps: "Application", .awake: "Tool", .colors: "Tool", .display: "Tool", .emoji: "Emoji", .files: "File",
        .folders: "Folder", .links: "Shortcut", .macSettings: "System Settings", .processes: "Process", .quit: "Command",
        .sound: "Tool", .system: "Command", .lowtide: "Lowtide",
    ]

    @ViewBuilder private var accessory: some View {
        if let badge {
            // Quiet until its row is picked: a column of keycaps is noise.
            KeyCap(keys: "⌘\(badge)").opacity(selected ? 1 : 0.5)
        } else if let value = row.value {
            Text(value).font(.ui(.sm, .medium)).monospacedDigit().foregroundStyle(palette.ink2.color)
        } else if let shortcut = row.shortcut {
            KeyCap(keys: shortcut)
        } else if let label = row.kind ?? Self.kindLabel[row.source], label != row.subtitle {
            Text(label).font(.ui(.sm)).foregroundStyle(palette.ink3.color)
        }
    }
}

/// A row's icon: Finder's icon, an emoji, a colour swatch, or a glyph on a plate.
struct BarIconView: View {
    @Environment(\.palette) private var palette
    let icon: BarIcon

    var body: some View {
        Group {
            switch icon {
            case .file(let path):
                FileIcon(path: path, size: 24)
            case .emoji(let char):
                Text(char).font(.ui(.lg))
            case .swatch(let color):
                Circle().fill(Color(.sRGB, red: color.r / 255, green: color.g / 255, blue: color.b / 255, opacity: color.a))
                    .frame(width: 20, height: 20)
                    .overlay(Circle().strokeBorder(palette.lineStrong.color))
            case .glyph(let name):
                plate { NavIcon(name, size: 14).foregroundStyle(palette.ink2.color) }
            case .symbol(let name, let destructive):
                plate {
                    Image(systemName: name).font(.system(size: 12, weight: .medium))
                        .foregroundStyle((destructive ? palette.bad : palette.ink2).color)
                }
            }
        }
        .frame(width: 24, height: 24)
    }

    private func plate(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .frame(width: 24, height: 24)
            .background(palette.fill.color, in: .rect(cornerRadius: Radius.sm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).strokeBorder(palette.line.color))
    }
}
