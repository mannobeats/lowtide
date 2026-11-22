import AppKit
import LowtideKit
import SwiftUI
import UniformTypeIdentifiers

/// A pane being dragged onto another to swap them. Its own type, so a
/// file dropped on a terminal is never taken for one.
nonisolated struct TerminalPaneDrag: Codable, Transferable, Sendable {
    let id: String
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .terminalPane)
    }
}

nonisolated extension UTType {
    static let terminalPane = UTType(exportedAs: "dev.lowtide.terminal-pane", conformingTo: .data)
}

/// The active tab's panes, laid out by its split tree, with draggable
/// dividers. Moves glide; dragging a divider is immediate.
struct TerminalSplitArea: View {
    private var store = SessionStore.shared
    static let gap: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            let workspace = store.workspace
            if let root = workspace.activeID {
                let tree = workspace.layout(of: root)
                let zoom = workspace.zoomedPane(in: root)
                let placed = zoom.map { [(id: $0, rect: PaneLayout.Rect.full)] } ?? tree.rects()
                let framed = placed.count > 1 || zoom != nil || tree.leaves.count > 1
                ZStack(alignment: .topLeading) {
                    ForEach(placed, id: \.id) { item in
                        if let session = store.session(item.id) {
                            let frame = Self.frame(item.rect, in: geo.size)
                            TerminalPaneView(session: session, framed: framed, focused: item.id == workspace.focusedPane,
                                     zoomed: zoom != nil)
                                .frame(width: frame.width, height: frame.height)
                                .offset(x: frame.minX, y: frame.minY)
                        }
                    }
                    if zoom == nil {
                        ForEach(tree.dividers(), id: \.path) { divider in
                            DividerHandle(divider: divider, root: root, size: geo.size)
                        }
                    }
                }
                .coordinateSpace(.named("split"))
                .animation(store.dragging ? nil : Motion.base, value: placed.map(\.rect.x) + placed.map(\.rect.y) + placed.map(\.rect.w))
            }
        }
    }

    static func frame(_ rect: PaneLayout.Rect, in size: CGSize) -> CGRect {
        CGRect(x: rect.x * size.width + gap, y: rect.y * size.height + gap,
               width: max(0, rect.w * size.width - gap * 2), height: max(0, rect.h * size.height - gap * 2))
    }
}

/// A divider between two panes: drag to resize, double-click to even them.
private struct DividerHandle: View {
    @Environment(\.palette) private var palette
    @State private var hovering = false
    let divider: PaneLayout.Divider
    let root: String
    let size: CGSize

    var body: some View {
        let row = divider.axis == .row
        let r = divider.rect
        let thickness: CGFloat = 8
        let frame = row
            ? CGRect(x: (r.x + r.w * divider.ratio) * size.width - thickness / 2, y: r.y * size.height,
                     width: thickness, height: r.h * size.height)
            : CGRect(x: r.x * size.width, y: (r.y + r.h * divider.ratio) * size.height - thickness / 2,
                     width: r.w * size.width, height: thickness)
        ZStack {
            Rectangle().fill(hovering ? palette.brand.color : .clear)
                .frame(width: row ? 1 : nil, height: row ? nil : 1)
        }
        .frame(width: frame.width, height: frame.height)
        .contentShape(.rect)
        .offset(x: frame.minX, y: frame.minY)
        .onHover { hovering = $0 }
        .pointerStyle(row ? .columnResize : .rowResize)
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named("split"))
                .onChanged { value in
                    SessionStore.shared.dragging = true
                    let ratio = row
                        ? (value.location.x - r.x * size.width) / (r.w * size.width)
                        : (value.location.y - r.y * size.height) / (r.h * size.height)
                    SessionStore.shared.setRatio(root, path: divider.path, ratio: ratio)
                }
                .onEnded { _ in SessionStore.shared.dragging = false }
        )
        .onTapGesture(count: 2) { SessionStore.shared.setRatio(root, path: divider.path, ratio: 0.5) }
        .help("Drag to resize · double-click to split evenly")
        .accessibilityLabel("Resize panes")
    }
}

/// One session: its header when the tab is split, the terminal, and the
/// receipt line under it.
struct TerminalPaneView: View {
    @Environment(\.palette) private var palette
    @State private var dropTarget = false
    @State private var headerHovered = false
    let session: TerminalSession
    let framed: Bool
    let focused: Bool
    let zoomed: Bool

    private var store: SessionStore { SessionStore.shared }

    var body: some View {
        VStack(spacing: 0) {
            if framed { header }
            ZStack(alignment: .topLeading) {
                TerminalSlot(session: session)
                    .padding(.leading, Space.sm)
                    .padding(.top, framed ? Space.xxs : Space.sm)
                Overlays(session: session, focused: focused)
                    .padding(.leading, Space.sm)
                    .padding(.top, framed ? Space.xxs : Space.sm)
            }
            ReceiptStrip(sessionID: session.id)
        }
        .background(Color(nsColor: TerminalColors.current.background))
        .clipShape(.rect(cornerRadius: framed ? Radius.md : 0))
        .overlay {
            if framed {
                RoundedRectangle(cornerRadius: Radius.md)
                    .strokeBorder((dropTarget ? palette.warn.opacity(0.6) : focused ? palette.brand.opacity(0.45) : palette.line).color)
            }
        }
        .opacity(framed && !focused ? 0.82 : 1)
        .dropDestination(for: TerminalPaneDrag.self) { items, _ in
            guard let from = items.first?.id, from != session.id, store.workspace.tab(from) != nil else { return false }
            store.swap(from, session.id)
            return true
        } isTargeted: { dropTarget = $0 }
        .onTapGesture { store.focusPane(session.id) }
    }

    private var header: some View {
        HStack(spacing: Space.sm) {
            HStack(spacing: 4) {
                Text(session.programTitle ?? session.tab.title).lineLimit(1).truncationMode(.middle)
                if session.tab.closed { Text("· Exited").foregroundStyle(palette.ink4.color) }
            }
            .font(.ui(.xs))
            .foregroundStyle(palette.ink3.color)
            Spacer(minLength: Space.sm)
            HStack(spacing: 0) {
                SmallTool("rectangle.split.2x1", help: "Split right (⌘D)") { store.split(session.id, axis: .row) }
                SmallTool("rectangle.split.1x2", help: "Split down (⇧⌘D)") { store.split(session.id, axis: .column) }
                SmallTool(zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                          help: zoomed ? "Restore (⇧⌘↩)" : "Zoom pane (⇧⌘↩)") {
                    store.focusPane(session.id)
                    store.toggleZoom()
                }
                SmallTool("xmark", help: "Close pane (⌘W)") { store.closePane(session.id) }
            }
            // The tools show when the pointer is on the header, so a row of
            // split panes reads as names, not as twelve buttons.
            .opacity(headerHovered ? 1 : 0)
            .animation(Motion.fast, value: headerHovered)
        }
        .padding(.leading, Space.sm)
        .padding(.trailing, Space.xxs)
        .frame(height: 24)
        .contentShape(.rect)
        .onHover { headerHovered = $0 }
        .draggable(TerminalPaneDrag(id: session.id)) {
            Text(session.tab.title).font(.ui(.xs)).padding(Space.xs).overlaySurface(radius: Radius.sm)
        }
        .help("Drag onto another pane to swap them")
    }
}

private struct SmallTool: View {
    @Environment(\.palette) private var palette
    @State private var hovering = false
    let symbol: String
    let help: String
    let action: () -> Void

    init(_ symbol: String, help: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .medium))
                .foregroundStyle((hovering ? palette.ink : palette.ink4).color)
                .frame(width: 20, height: 20)
                .background(hovering ? palette.hover.color : .clear, in: .rect(cornerRadius: Radius.sm))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - The terminal's NSView

/// Hosts a session's long-lived NSView. The view moves between slots (and
/// out of the window when its tab is hidden) but is never recreated, so a
/// shell never restarts because the page or the layout changed.
struct TerminalSlot: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> SlotView {
        let slot = SlotView()
        slot.adopt(session)
        return slot
    }

    func updateNSView(_ slot: SlotView, context: Context) { slot.adopt(session) }

    static func dismantleNSView(_ slot: SlotView, coordinator: ()) {
        if let view = slot.session?.view, view.superview === slot { view.removeFromSuperview() }
    }

    final class SlotView: NSView {
        weak var session: TerminalSession?
        override var isFlipped: Bool { true }

        func adopt(_ session: TerminalSession) {
            self.session = session
            let view = session.view
            if view.superview !== self {
                view.removeFromSuperview()
                view.frame = bounds
                view.autoresizingMask = [.width, .height]
                addSubview(view)
                focusIfInFront()
            }
            startIfReady()
        }

        override func layout() {
            super.layout()
            session?.view.frame = bounds
            startIfReady()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            startIfReady()
            focusIfInFront()
        }

        /// A new tab or pane takes the keyboard (and its cursor blinks) as
        /// soon as its view is in the window: asking earlier finds no window.
        private func focusIfInFront() {
            guard let session, let store = session.store, window != nil, store.page == .sessions,
                  store.workspace.focusedPane == session.id, window?.attachedSheet == nil,
                  !AppModel.shared.paletteOpen else { return }
            session.focus()
        }

        private func startIfReady() {
            guard let session, window != nil, bounds.width > 40, bounds.height > 30 else { return }
            if session.view.frame.size != bounds.size { session.view.frame = bounds }
            session.start()
        }
    }
}

// MARK: - Over the terminal

/// Ghost text, suggestions, the find bar and the saved-credential picker.
private struct Overlays: View {
    @Environment(\.palette) private var palette
    let session: TerminalSession
    let focused: Bool

    private var store: SessionStore { SessionStore.shared }

    var body: some View {
        GeometryReader { geo in
            let caret = caretRect(in: geo.size)
            ZStack(alignment: .topLeading) {
                if let ghost = session.ghost, focused {
                    Text(ghost.text)
                        .font(Font(TerminalSettings.shared.font))
                        .foregroundStyle(palette.ink4.color)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(maxWidth: max(0, geo.size.width - caret.minX), maxHeight: caret.height, alignment: .leading)
                        .frame(height: caret.height)
                        .clipped()
                        .offset(x: caret.minX, y: caret.minY)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                if focused, !session.suggestions.isEmpty {
                    let height = CGFloat(session.suggestions.count) * 28 + 8
                    let below = caret.maxY + 4
                    let top = below + height <= geo.size.height - 8 ? below : max(8, caret.minY - height - 4)
                    SuggestionList(session: session)
                        .frame(maxWidth: min(520, geo.size.width - 16), alignment: .leading)
                        .fixedSize(horizontal: true, vertical: true)
                        .offset(x: min(max(8, caret.minX), max(8, geo.size.width - 520)), y: top)
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topLeading)))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .overlay(alignment: .topTrailing) {
                if focused, store.findOpen { FindBar().padding(Space.sm) }
            }
            .overlay(alignment: .bottomTrailing) {
                if session.suggestions.isEmpty { CredentialPicker(session: session).padding(Space.lg) }
            }
            .animation(Motion.fast, value: session.suggestions.isEmpty)
        }
    }

    /// The caret in the slot's top-left coordinates.
    private func caretRect(in size: CGSize) -> CGRect {
        let view = session.view
        let frame = view.caretFrame
        guard frame != .zero else { return CGRect(x: 8, y: 8, width: 8, height: 16) }
        let y = view.isFlipped ? frame.minY : view.bounds.height - frame.maxY
        return CGRect(x: frame.minX, y: y, width: frame.width, height: frame.height)
    }
}

private struct SuggestionList: View {
    @Environment(\.palette) private var palette
    let session: TerminalSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(session.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                SuggestionRow(suggestion: suggestion, selected: index == session.selectedSuggestion) {
                    session.accept(suggestion)
                }
            }
        }
        .padding(Space.xs)
        .frame(minWidth: 280, alignment: .leading)
        .overlaySurface(radius: Radius.md)
        .accessibilityLabel("Command suggestions")
    }
}

private struct SuggestionRow: View {
    @Environment(\.palette) private var palette
    @State private var hovering = false
    let suggestion: TerminalSuggestion
    let selected: Bool
    let accept: () -> Void

    var symbol: String {
        switch suggestion.kind {
        case .argument: "tag"
        case .command: "terminal"
        case .executable: "chevron.left.forwardslash.chevron.right"
        case .history: "clock.arrow.circlepath"
        case .option: "flag"
        case .path: "folder"
        case .project: "folder.badge.gearshape"
        case .snippet: "doc.text"
        case .subcommand: "chevron.right"
        }
    }

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: symbol).font(.system(size: 11))
                .foregroundStyle((selected ? palette.ink2 : palette.ink4).color)
                .frame(width: 14)
                .accessibilityLabel(suggestion.kind.rawValue)
            highlighted.font(.mono(.xs)).lineLimit(1).truncationMode(.tail)
            if suggestion.risky {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(palette.warn.color)
                    .accessibilityLabel("Changes or deletes data")
            }
            Spacer(minLength: Space.md)
            Text(suggestion.description).font(.ui(.xs)).foregroundStyle(palette.ink3.color).lineLimit(1)
            KeyCap(keys: "Tab").opacity(selected ? 1 : 0)
        }
        .padding(.horizontal, Space.sm)
        .frame(height: 28)
        .background((selected ? palette.selected : hovering ? palette.hover : ColorValue(r: 0, g: 0, b: 0, a: 0)).color,
                    in: .rect(cornerRadius: Radius.sm))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(perform: accept)
        .help(suggestion.risky ? "Changes or deletes data. Review before running." : suggestion.insertText)
    }

    /// The matched part in the brand colour.
    private var highlighted: Text {
        let label = suggestion.label
        let query = suggestion.highlight.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty, let range = label.lowercased().range(of: query),
              let start = label.index(label.startIndex, offsetBy: label.lowercased().distance(from: label.lowercased().startIndex, to: range.lowerBound), limitedBy: label.endIndex),
              let end = label.index(start, offsetBy: query.count, limitedBy: label.endIndex) else {
            return Text(label).foregroundStyle(palette.ink.color)
        }
        let match = Text(label[start..<end]).foregroundStyle(palette.brand.color)
        return Text("\(Text(label[..<start]))\(match)\(Text(label[end...]))").foregroundStyle(palette.ink.color)
    }
}

/// ⌘F: search the scrollback of the focused pane.
private struct FindBar: View {
    @Environment(\.palette) private var palette
    @Bindable private var store = SessionStore.shared
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(palette.ink3.color)
            TextField("Find in scrollback", text: $store.findText)
                .textFieldStyle(.plain)
                .font(.ui(.sm))
                .frame(width: 180)
                .focused($focused)
                .onSubmit { store.find(next: !NSEvent.modifierFlags.contains(.shift)) }
                .onChange(of: store.findText) { _, _ in store.find(next: true) }
            if let summary = store.findSummary {
                Text(summary.total == 0 ? "No results" : "\(summary.index) of \(summary.total)")
                    .font(.ui(.xxs)).monospacedDigit().foregroundStyle(palette.ink3.color)
                    .fixedSize()
            }
            IconButton("textformat", help: "Match case", active: store.findCaseSensitive) {
                store.findCaseSensitive.toggle()
                store.find(next: true)
            }
            IconButton("chevron.up", help: "Previous (⇧⌘G)") { store.find(next: false) }
            IconButton("chevron.down", help: "Next (⌘G)") { store.find(next: true) }
            IconButton("xmark", help: "Done (Esc)") { store.closeFind() }
        }
        .padding(.leading, Space.sm)
        .padding(.trailing, Space.xxs)
        .frame(height: 34)
        .overlaySurface(radius: Radius.md)
        .onAppear { focused = true }
        .onExitCommand { store.closeFind() }
    }
}

/// Offers saved credentials only while the shell asks for a secret; ⇧⌘P
/// opens the list at any time.
private struct CredentialPicker: View {
    @Environment(\.palette) private var palette
    let session: TerminalSession

    struct Option: Identifiable {
        let id: String
        let label: String
        let meta: String
        let preferred: Bool
    }

    var options: [Option] {
        let preferred = session.preferredCredential(for: session.secretPrompt)
        return RemoteStore.shared.snapshot.identities.compactMap { identity -> Option? in
            switch identity.kind {
            case .password:
                let account = Identity.passwordAccount(identity.id)
                return Option(id: account, label: identity.name,
                              meta: identity.username.map { "Password · \($0)" } ?? "Password", preferred: account == preferred)
            case .sshKey where identity.hasPassphrase:
                let account = Identity.passphraseAccount(identity.id)
                return Option(id: account, label: identity.name, meta: "SSH key passphrase", preferred: account == preferred)
            default:
                return nil
            }
        }
        .sorted { $0.preferred && !$1.preferred }
    }

    var body: some View {
        let options = options
        if !options.isEmpty {
            if session.credentialPickerOpen {
                list(options)
            } else if session.secretPrompt != nil {
                Button { session.credentialPickerOpen = true } label: {
                    HStack(spacing: Space.sm) {
                        NavIcon("credentials", size: 14).foregroundStyle(palette.brand.color)
                        Text("Fill saved password").font(.ui(.sm))
                        KeyCap(keys: "⇧⌘P")
                    }
                    .padding(.horizontal, Space.md)
                    .frame(height: 32)
                    .overlaySurface(radius: Radius.md)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Choose a saved credential (⇧⌘P)")
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
            }
        }
    }

    private func list(_ options: [Option]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Saved credentials").font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color)
                    Text(session.secretPrompt != nil ? "Sent straight from the macOS Keychain" : "Use when the terminal asks for a password")
                        .font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                }
                Spacer()
                IconButton("xmark", help: "Close saved credentials") { session.credentialPickerOpen = false }
            }
            .padding(.leading, Space.md)
            .padding(.trailing, Space.xs)
            .padding(.vertical, Space.sm)
            Hairline()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(options) { option in
                        CredentialRow(option: option) {
                            if !session.sendSecret(option.id) {
                                Toasts.shared.show("Wait until the terminal asks for a password or passphrase", tone: .warn)
                            }
                        }
                    }
                }
                .padding(Space.xs)
            }
            .frame(maxHeight: 256)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 320)
        .overlaySurface(radius: Radius.lg)
        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
    }
}

private struct CredentialRow: View {
    @Environment(\.palette) private var palette
    @State private var hovering = false
    let option: CredentialPicker.Option
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.sm) {
                NavIcon("credentials", size: 16).foregroundStyle((option.preferred ? palette.brand : palette.ink3).color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label).font(.ui(.sm)).foregroundStyle(palette.ink.color).lineLimit(1)
                    Text(option.preferred ? "Suggested · \(option.meta)" : option.meta)
                        .font(.ui(.xs)).foregroundStyle(palette.ink3.color).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.sm)
            .padding(.vertical, 6)
            .background(hovering ? palette.hover.color : .clear, in: .rect(cornerRadius: Radius.sm))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Receipt strip

/// The line under a pane: what the running command is doing, then the
/// receipt of the last one until the next starts. The install watch fills
/// it; sessions it doesn't follow show nothing here.
private struct ReceiptStrip: View {
    @Environment(\.palette) private var palette
    let sessionID: String
    private var feed = TerminalReceiptFeed.shared

    init(sessionID: String) { self.sessionID = sessionID }

    var body: some View {
        let _ = feed.version
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let activity = TerminalSessions.shared.activity(sessionID)
            if let activity, context.date.timeIntervalSince(activity.started) > 2.5 {
                // Quick commands don't need a live line; long ones do.
                HStack(spacing: Space.sm) {
                    StatusDot(tone: .brand, pulsing: true)
                    Text(activity.command).font(.mono(.xxs)).foregroundStyle(palette.ink2.color).lineLimit(1)
                    Spacer(minLength: Space.sm)
                    Text("\(LowtideKitFormat.duration(context.date.timeIntervalSince(activity.started))) · \(LowtideKitFormat.count(activity.hosts, "host")) · \(LowtideKitFormat.count(activity.files, "file"))")
                        .font(.ui(.xxs)).monospacedDigit().foregroundStyle(palette.ink3.color)
                }
                .padding(.horizontal, Space.sm)
                .frame(height: 24)
                .hairline(.top)
            } else if activity == nil, let receipt = TerminalSessions.shared.receipt(sessionID) {
                receiptLine(receipt)
            }
        }
    }

    private func receiptLine(_ receipt: TerminalSessions.Receipt) -> some View {
        let tone: Tone = switch receipt.verdict {
        case .alert: .bad
        case .notice: .warn
        case .info: .ok
        }
        return HStack(spacing: Space.sm) {
            Image(systemName: receipt.verdict == .alert ? "xmark.shield.fill" : receipt.verdict == .notice ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 10)).foregroundStyle(tone.color(palette).color)
            Button {
                RunsStore.shared.focus = receipt.runID.flatMap { UInt64($0) }
                AppModel.shared.open(.history)
            } label: {
                HStack(spacing: Space.sm) {
                    Text(receipt.command).font(.mono(.xxs)).foregroundStyle(palette.ink2.color).lineLimit(1)
                        .frame(maxWidth: 280, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    Text(LowtideKitFormat.duration(receipt.ended.timeIntervalSince(receipt.started))).font(.ui(.xxs)).monospacedDigit()
                    Text(receipt.summary).font(.ui(.xxs)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(palette.ink3.color)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Open the full receipt")
            IconButton("xmark", help: "Dismiss receipt") { TerminalSessions.shared.dismiss(sessionID) }
                .scaleEffect(0.8)
        }
        .padding(.leading, Space.sm)
        .frame(height: 24)
        .background(receipt.verdict == .info ? .clear : tone.soft(palette).opacity(0.4).color)
        .hairline(.top)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// Re-renders the receipt lines when the install watch hands one back.
@Observable
final class TerminalReceiptFeed {
    static let shared = TerminalReceiptFeed()
    private(set) var version = 0

    func start() {
        TerminalSessions.shared.observe {
            Task { @MainActor in TerminalReceiptFeed.shared.version += 1 }
        }
    }
}
