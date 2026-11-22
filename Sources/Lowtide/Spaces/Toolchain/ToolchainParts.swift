import AppKit
import LowtideKit
import SwiftUI

/// Package managers' and runtimes' marks (`Resources/sources/<name>.svg`,
/// Tabler brand marks), drawn as template images.
enum SourceMarks {
    private static var cache: [String: NSImage] = [:]

    static func image(_ name: String) -> NSImage {
        if let hit = cache[name] { return hit }
        let url = AppResources.url("sources/\(name).svg")
        let image = (try? Data(contentsOf: url)).flatMap(NSImage.init(data:))
            ?? (name == "package" ? NSImage(systemSymbolName: "shippingbox", accessibilityDescription: nil)! : image("package"))
        image.isTemplate = true
        cache[name] = image
        return image
    }
}

/// The outlined square a mark sits in at the start of a row or a header.
struct SourceTile: View {
    @Environment(\.palette) private var palette
    let mark: String
    var size: CGFloat = 32
    var tone: Tone = .neutral

    var body: some View {
        Image(nsImage: SourceMarks.image(mark))
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .frame(width: size / 2, height: size / 2)
            .foregroundStyle((tone == .neutral ? palette.ink2 : tone.color(palette)).color)
            .frame(width: size, height: size)
            .background((tone == .neutral ? palette.fill : tone.soft(palette)).color, in: .rect(cornerRadius: size > 36 ? Radius.md : Radius.sm))
            .overlay(RoundedRectangle(cornerRadius: size > 36 ? Radius.md : Radius.sm).strokeBorder(palette.line.color))
            .accessibilityHidden(true)
    }
}

/// The mark for an inventory item: its manager's, or an app or terminal.
extension InventoryItem {
    var mark: String {
        switch itemType {
        case .app: "app-window"
        case .cli: sourceID == "standalone" ? "terminal" : (ToolchainModel.shared.info(sourceID)?.icon ?? "terminal")
        case .package: ToolchainModel.shared.info(sourceID)?.icon ?? "package"
        }
    }
}

/// A list on a card, rows edge to edge with hairlines between them.
struct ToolListCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .clipShape(.rect(cornerRadius: Radius.lg))
            .card()
    }
}

/// Hover fill for rows people click.
struct ToolRowHover: ViewModifier {
    @Environment(\.palette) private var palette
    @State private var hovering = false
    var selected = false

    func body(content: Content) -> some View {
        content
            .background((selected ? palette.selected : hovering ? palette.hover : ColorValue(r: 0, g: 0, b: 0, a: 0)).color)
            .onHover { hovering = $0 }
            .animation(Motion.fast, value: hovering)
    }
}

extension View {
    func toolRowHover(selected: Bool = false) -> some View { modifier(ToolRowHover(selected: selected)) }
}

enum ToolClipboard {
    static func copy(_ text: String, what: String) {
        Files.copy(text)
        Toasts.shared.show("\(what) copied")
    }
}

/// A mono line people copy: a path, a command.
struct ToolCommandLine: View {
    @Environment(\.palette) private var palette
    @State private var hovering = false
    let text: String
    var what = "Command"
    var symbol = "terminal"

    var body: some View {
        Button { ToolClipboard.copy(text, what: what) } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(palette.ink3.color)
                Text(text).font(.mono(.xs)).foregroundStyle(palette.ink.color).lineLimit(2).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "doc.on.doc").font(.system(size: 11)).foregroundStyle(palette.ink4.color)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, 7)
            .background((hovering ? palette.hover : palette.fill).color, in: .rect(cornerRadius: Radius.md))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Copy \(what.lowercased())")
        .contextMenu { Button("Copy") { ToolClipboard.copy(text, what: what) } }
    }
}

/// The bar that floats over a list while rows are ticked.
struct ToolSelectionBar<Actions: View>: View {
    @Environment(\.palette) private var palette
    let count: Int
    let noun: (String, String)
    var status: String?
    let clear: () -> Void
    @ViewBuilder var actions: Actions

    var body: some View {
        if count > 0 {
            HStack(spacing: Space.md) {
                Text("\(count.formatted()) \(count == 1 ? noun.0 : noun.1) selected")
                    .font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color).monospacedDigit()
                if let status { Text(status).font(.ui(.xs)).foregroundStyle(palette.ink3.color).lineLimit(1) }
                Spacer(minLength: Space.md)
                actions
                IconButton("xmark", help: "Clear selection", action: clear)
            }
            .padding(.leading, Space.lg)
            .padding(.trailing, Space.xs)
            .padding(.vertical, Space.xs)
            .frame(maxWidth: 560)
            .overlaySurface()
            .padding(.bottom, Space.lg)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// Recent operations, newest first: a dot, what happened, where, when,
/// and a live status line.
struct RecentToolActivity: View {
    @Environment(\.palette) private var palette
    let entries: [ActivityEntry]
    var loaded = true
    let status: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if entries.isEmpty, loaded {
                Text("No operations yet. Updates and removals land here.")
                    .font(.ui(.xs)).foregroundStyle(palette.ink3.color).frame(height: 32)
            }
            ForEach(entries.prefix(7)) { entry in
                HStack(spacing: 10) {
                    Circle().fill((entry.succeeded ? palette.ok : palette.bad).color).frame(width: 6, height: 6)
                        .accessibilityLabel(entry.succeeded ? "Done" : "Failed")
                    Text(Self.describe(entry)).font(.ui(.sm)).foregroundStyle(palette.ink2.color).lineLimit(1)
                        .help(entry.detail ?? "")
                    Spacer(minLength: Space.sm)
                    Text(entry.sourceName).font(.ui(.xs)).foregroundStyle(palette.ink3.color).lineLimit(1)
                    Text(Self.stamp(entry.createdAt)).font(.mono(.xxs)).foregroundStyle(palette.ink4.color)
                        .monospacedDigit().frame(width: 64, alignment: .trailing)
                }
                .frame(height: 32)
            }
            HStack(spacing: 10) {
                Circle().fill(palette.brand.color).frame(width: 6, height: 6)
                Text(status).font(.ui(.xs)).foregroundStyle(palette.ink3.color)
            }
            .frame(height: 28)
            .padding(.top, Space.xs)
        }
    }

    static func describe(_ entry: ActivityEntry) -> String {
        let versions = entry.previousVersion.flatMap { previous in entry.resultingVersion.map { " \(previous) → \($0)" } } ?? ""
        return "\(entry.action.capitalized) \(entry.itemName)\(versions)"
    }

    static func stamp(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
            : date.formatted(.dateTime.day().month(.abbreviated))
    }
}
