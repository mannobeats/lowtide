import AppKit
import LowtideKit
import QuickLook
import SwiftUI

/// Showing, opening and copying what a receipt names.
enum FileActions {
    /// `~/x` as a full path.
    static func expand(_ path: String) -> String {
        path.hasPrefix("~/") ? Paths.home.path + path.dropFirst(1) : path
    }

    static func reveal(_ path: String) {
        let full = expand(path)
        if FileManager.default.fileExists(atPath: full) {
            Files.reveal([full])
        } else {
            // Gone since: show the folder that held it.
            NSWorkspace.shared.open(URL(fileURLWithPath: (full as NSString).deletingLastPathComponent))
        }
    }

    static func open(_ path: String) { NSWorkspace.shared.open(URL(fileURLWithPath: expand(path))) }

    static func copy(_ text: String, what: String = "Path") {
        Files.copy(text)
        Toasts.shared.show("Copied \(what.lowercased())")
    }
}

/// A verdict as a dot: red to act, amber to know.
struct VerdictDot: View {
    @Environment(\.palette) private var palette
    let severity: Severity
    var size: CGFloat = 7

    var body: some View {
        Circle().fill(color.color).frame(width: size, height: size).accessibilityHidden(true)
    }

    private var color: ColorValue {
        switch severity {
        case .alert: palette.bad
        case .notice: palette.warn
        case .info: palette.ink4.opacity(0.7)
        }
    }
}

extension Severity {
    /// The tone a verdict reads in.
    var tone: Tone { self == .alert ? .bad : self == .notice ? .warn : .neutral }
}

/// A list row that opens in place to show more about itself.
struct ExpandRow<Summary: View, Detail: View>: View {
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var open = false
    @State private var hovering = false
    @ViewBuilder var summary: Summary
    @ViewBuilder var detail: Detail

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Motion.spring(reduceMotion)) { open.toggle() }
            } label: {
                HStack(spacing: Space.md) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.ink4.color)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 12)
                    summary
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, 6)
                .frame(minHeight: 38)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(open ? .isSelected : [])
            .accessibilityHint(open ? "Hides the details" : "Shows the details")
            if open {
                VStack(alignment: .leading, spacing: Space.sm) { detail }
                    .font(.ui(.xs))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, Space.lg + 12 + Space.md)
                    .padding(.trailing, Space.lg)
                    .padding(.bottom, Space.md)
                    .transition(.opacity)
            }
        }
        .background(hovering && !open ? palette.hover.color : .clear)
        .onHover { hovering = $0 }
    }
}

/// A path in mono (or `label`, a shorter name for it) with Show in Finder
/// on hover and Open, Quick Look and Copy path on right-click. Paths saved
/// before receipts kept them in full can't be opened.
struct PathLine: View {
    @Environment(\.palette) private var palette
    @Environment(\.privacy) private var privacy
    @State private var hovering = false
    @State private var preview: URL?
    let path: String
    var label: String?

    var body: some View {
        let openable = path.hasPrefix("/") || path.hasPrefix("~/")
        HStack(spacing: Space.sm) {
            // Privacy Mode hides the user name in a full path.
            Text(label ?? (privacy ? Paths.tilde(path).replacingOccurrences(of: "/Users/", with: "/Users/•••/") : Paths.tilde(path)))
                .font(.mono(.xxs))
                .foregroundStyle(palette.ink2.color)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            if openable {
                IconButton("folder", help: "Show in Finder") { FileActions.reveal(path) }
                    .opacity(hovering ? 1 : 0)
            }
        }
        .frame(minHeight: 24)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .help(path)
        .contextMenu {
            if openable {
                Button("Show in Finder") { FileActions.reveal(path) }
                Button("Open") { FileActions.open(path) }
                Button("Quick Look") { preview = URL(fileURLWithPath: FileActions.expand(path)) }
                Divider()
            }
            Button("Copy Path") { FileActions.copy(FileActions.expand(path)) }
        }
        .quickLookPreview($preview)
    }
}

/// A label and its value, for the facts inside an expanded row.
struct RunFactRow: View {
    @Environment(\.palette) private var palette
    let label: String
    let value: String
    var tone: Tone?
    var mono = false

    init(_ label: String, _ value: String, tone: Tone? = nil, mono: Bool = false) {
        self.label = label
        self.value = value
        self.tone = tone
        self.mono = mono
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            Text(label).font(.ui(.xs)).foregroundStyle(palette.ink3.color).frame(width: 96, alignment: .leading)
            Text(value)
                .font(mono ? .mono(.xxs) : .ui(.xs))
                .foregroundStyle((tone?.color(palette) ?? palette.ink).color)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 20)
    }
}

/// Rows in a card, with hairlines between them.
struct RowStack<Item: Identifiable, Row: View>: View {
    let items: [Item]
    @ViewBuilder var row: (Item) -> Row

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Hairline(inset: Space.lg) }
                row(item)
            }
        }
    }
}

extension Date {
    /// `14:05`: when on a timeline.
    var timeOfDay: String { formatted(date: .omitted, time: .shortened) }
}
