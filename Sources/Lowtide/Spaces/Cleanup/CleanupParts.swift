import AppKit
import LowtideKit
import SwiftUI

// The parts every Cleanup page shares: check rows, select-all, sizes, tiles,
// keys, and moving to the Trash with Undo. Checkboxes, the selection bar,
// the path menu and Quick Look are the shared ones in Design/Components.

enum Clean {
    static let clear = ColorValue(r: 0, g: 0, b: 0, a: 0)

    /// A list row with a checkbox. A click checks it (⇧ for a run); with
    /// `onSelect`, a click opens it and only the box checks.
    struct CheckRow<Content: View, Menu: View>: View {
        @Environment(\.palette) private var palette
        @State private var hovering = false
        let checked: Bool
        var disabled = false
        var selected = false
        var label: String
        var help: String?
        var onCheck: () -> Void
        var onSelect: (() -> Void)?
        @ViewBuilder var content: Content
        @ViewBuilder var menu: Menu

        var body: some View {
            HStack(spacing: Space.md) {
                Checkbox(checked, label: label, enabled: !disabled, toggle: onCheck)
                content
            }
            .padding(.leading, Space.sm)
            .padding(.trailing, Space.lg)
            .frame(minHeight: 44)
            .background((selected ? palette.selectedBrand : hovering ? palette.hover : Clean.clear).color)
            .contentShape(.rect)
            .onTapGesture {
                if let onSelect { onSelect() } else if !disabled { onCheck() }
            }
            .onHover { hovering = $0 }
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: onSelect == nil ? "Check" : "Open") { if let onSelect { onSelect() } else if !disabled { onCheck() } }
            .contextMenu { menu }
            .help(help ?? "")
            .animation(Motion.fast, value: hovering)
        }
    }

    /// Bytes in a column: mono, lined up.
    struct SizeLabel: View {
        @Environment(\.palette) private var palette
        let bytes: Int64?
        var strong = false
        var measuring = false

        var body: some View {
            Group {
                if let bytes {
                    Text(LowtideFormat.bytes(bytes))
                } else if measuring {
                    Text("Measuring").foregroundStyle(palette.ink4.color).phaseAnimator([0.4, 1]) { $0.opacity($1) }
                } else {
                    Text("–").foregroundStyle(palette.ink4.color)
                }
            }
            .font(.mono(.xs))
            .monospacedDigit()
            .foregroundStyle((strong ? palette.ink : palette.ink2).color)
            .contentTransition(.numericText())
        }
    }

    /// A glyph or symbol in a quiet rounded tile.
    struct Tile: View {
        @Environment(\.palette) private var palette
        var glyph: String?
        var symbol: String?
        var tone: Tone = .neutral
        var size: CGFloat = 28

        var body: some View {
            RoundedRectangle(cornerRadius: Radius.md)
                .fill((tone == .neutral ? palette.fill : tone.soft(palette)).color)
                .overlay {
                    Group {
                        if let glyph { NavIcon(glyph, size: size * 0.56) }
                        if let symbol { Image(systemName: symbol).font(.system(size: size * 0.46, weight: .medium)) }
                    }
                    .foregroundStyle((tone == .neutral ? palette.ink3 : tone.color(palette)).color)
                }
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }


    // MARK: Trash

    /// Confirms, moves to the Trash, and says what happened with Undo.
    enum Removal {
        struct Item { let path: String; let name: String; let bytes: Int64? }

        static func request(_ items: [Item], run: @escaping @MainActor () -> Void) -> ConfirmRequest {
            let label = items.count == 1 ? "“\(items[0].name)”" : "\(items.count) items"
            let bytes = items.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
            return ConfirmRequest(title: "Move \(label) to the Trash?",
                                  message: "\(label) (\(LowtideFormat.bytes(bytes))) go to the Trash. You can put them back until you empty it.",
                                  confirm: "Move to Trash", action: run)
        }

        /// Moves `items`, reports, and hands `done` the paths that went.
        static func run(_ items: [Item], mover: @escaping @Sendable ([String]) async -> Trash.Outcome = { await Trash.move($0) },
                        done: @escaping @MainActor ([String]) -> Void, restored: @escaping @MainActor () -> Void = {}) {
            Task { @MainActor in
                let outcome = await mover(items.map(\.path))
                let gone = Set(outcome.removed)
                let bytes = items.filter { gone.contains($0.path) }.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
                done(outcome.removed)
                report(moved: outcome.removed.count, bytes: bytes, refused: outcome.refused.map { (CleanupFS.name($0.path), $0.reason) },
                       undo: outcome.undoable, restored: restored)
            }
        }

        /// The toast after a removal: what went, with Undo, and what stayed.
        static func report(moved: Int, bytes: Int64, refused: [(String, String)], undo: [Trash.Moved],
                           restored: @escaping @MainActor () -> Void) {
            if moved > 0 {
                let title = "Moved \(LowtideFormat.count(moved, "item")) (\(LowtideFormat.bytes(bytes))) to the Trash"
                if undo.isEmpty {
                    Toasts.shared.show(title)
                } else {
                    Toasts.shared.show(title, action: "Undo") { Toasts.shared.putBack(undo, then: restored) }
                }
            }
            if let first = refused.first {
                let more = refused.count > 1 ? " and \(refused.count - 1) more" : ""
                Toasts.shared.show(refused.count == 1 ? "\(first.0) stayed" : "\(LowtideFormat.count(refused.count, "item")) stayed",
                                   detail: "\(first.0)\(more): \(first.1)", tone: .bad)
            }
        }
    }

    /// "Select all" over a list: the box, and a line saying what's shown.
    struct SelectAll<Trailing: View>: View {
        @Environment(\.palette) private var palette
        let state: CheckState
        let text: String
        var onChange: (Bool) -> Void
        @ViewBuilder var trailing: Trailing

        init(state: CheckState, text: String, onChange: @escaping (Bool) -> Void, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
            self.state = state
            self.text = text
            self.onChange = onChange
            self.trailing = trailing()
        }

        var body: some View {
            HStack(spacing: Space.md) {
                Checkbox(state, label: state == .on ? "Deselect all" : "Select all") { onChange(state != .on) }
                Text(text).font(.ui(.xs)).foregroundStyle(palette.ink3.color).monospacedDigit()
                Spacer(minLength: Space.sm)
                trailing
            }
            .padding(.leading, Space.sm).padding(.trailing, Space.lg)
            .frame(height: 34)
            .hairline(.bottom)
        }
    }

    /// Paths as a person reads them: `~/x`.
    static func tilde(_ path: String) -> String { Paths.tilde(path) }

    /// `Used 3 days ago`.
    static func relative(_ date: Date?, _ prefix: String? = nil) -> String {
        guard let date else { return "" }
        let ago = LowtideFormat.ago(date)
        return prefix.map { "\($0) \(ago)" } ?? ago.prefix(1).uppercased() + ago.dropFirst()
    }

    // MARK: Keys

    /// Space (Quick Look) and ⌘⌫ (Move to Trash) on a page's rows, as in
    /// Finder, while no text field is being typed in.
    struct Keys: ViewModifier {
        var space: (() -> Void)?
        var delete: (() -> Void)?
        @State private var monitor: Any?

        func body(content: Content) -> some View {
            content
                .onAppear {
                    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                        let typing = NSApp.keyWindow?.firstResponder is NSText
                        guard !typing, NSApp.keyWindow?.identifier?.rawValue == "main" || NSApp.keyWindow?.title == "Lowtide" else { return event }
                        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                        if event.keyCode == 49, flags.isEmpty, let space {
                            space()
                            return nil
                        }
                        if event.keyCode == 51, flags == .command, let delete {
                            delete()
                            return nil
                        }
                        return event
                    }
                }
                .onDisappear {
                    if let monitor { NSEvent.removeMonitor(monitor) }
                    monitor = nil
                }
        }
    }
}
