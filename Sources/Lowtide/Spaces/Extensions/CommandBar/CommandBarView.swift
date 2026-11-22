import AppKit
import LowtideKit
import SwiftUI

/// The command bar: one search for apps, Lowtide's pages and actions, the
/// Mac's settings and controls, quick answers and Ask. The floating panel
/// shows it on a frosted backdrop; ⌘K shows it in the main window:
/// `CommandBarView { model.paletteOpen = false }` on an `.overlaySurface()`.
/// Either way it fills a fixed frame: the list scrolls, the footer stays.
struct CommandBarView: View {
    @State private var model: CommandBarModel
    private let onDone: () -> Void
    private let ask: Bool

    init(host: CommandBarModel.Host = .window, ask: Bool = false, onDone: @escaping () -> Void) {
        _model = State(initialValue: CommandBarModel(host: host))
        self.ask = ask
        self.onDone = onDone
    }

    var body: some View {
        CommandBarContent(model: model)
            .onAppear {
                model.onHide = onDone
                model.opened(ask: ask)
            }
    }
}

/// The bar's content over a model (the panel keeps one for its life).
struct CommandBarContent: View {
    enum Chrome { case panel, plain }

    @Environment(\.palette) private var palette
    @Bindable var model: CommandBarModel
    var chrome: Chrome = .plain
    @FocusState private var focused: Bool

    init(model: CommandBarModel, chrome: Chrome = .plain) {
        self.model = model
        self.chrome = chrome
    }

    private var collapsed: Bool { model.collapsed }
    private var showList: Bool { model.mode.isSearch || model.mode.isActions }

    var body: some View {
        VStack(spacing: 0) {
            field
            if !collapsed {
                Rectangle().fill(palette.line.color).frame(height: 1)
                VStack(spacing: 0) {
                    // The views stay while you type (narrow the results with
                    // them), so the list never jumps up under the first key.
                    if showList, !model.chips.isEmpty {
                        BarChips(model: model)
                    }
                    modeCard
                    if model.mode.isAsk {
                        AskThreadView(model: model)
                    } else if showList {
                        BarResultList(model: model)
                    }
                    if case .slider(let row, let level, let saved) = model.mode {
                        BarSliderCard(row: row, level: level) { model.slide(row, to: $0, saved: saved) }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                BarFooter(model: model)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if case .actions(let row, let index) = model.mode {
                BarActionsPanel(model: model, row: row, index: index)
                    .padding(.trailing, Space.md)
                    .padding(.bottom, 52)
                    .transition(.scale(scale: 0.97, anchor: .bottomTrailing).combined(with: .opacity))
            }
        }
        .animation(Motion.fast, value: model.mode.isActions)
        .background(KeyMonitor(model: model))
        // It appears at once, like Spotlight: no opening animation to wait for.
        .onChange(of: model.focusToken, initial: true) { focused = true }
        // Data lands after the bar opens (apps, settings panes, facts).
        // The floating bar's view lives for the app's life: closed, it waits for its next opening.
        .onChange(of: model.data.version) { if model.showing { model.recompute() } }
        .onChange(of: model.settings.prefs) { if model.showing { model.recompute() } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command bar")
    }

    private var field: some View {
        HStack(spacing: Space.md) {
            if let chip = model.chipLabel {
                HStack(spacing: Space.xs) {
                    if model.mode.isAsk { NavIcon("ask", filled: true, size: 13).foregroundStyle(palette.brand.color) }
                    Text(chip.count > 30 ? chip.prefix(29) + "…" : chip).font(.ui(.sm)).foregroundStyle(palette.ink.color).lineLimit(1)
                    Button { model.escape() } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(palette.ink3.color)
                            .frame(width: 18, height: 18).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("Back (Esc)")
                }
                .padding(.leading, Space.sm)
                .padding(.trailing, Space.xxs)
                .frame(height: 26)
                .background(palette.selected.color, in: .rect(cornerRadius: Radius.sm))
                .fixedSize()
            }
            TextField(model.placeholder, text: Binding(get: { model.query }, set: { model.typed($0) }))
                .textFieldStyle(.plain)
                .font(.ui(.lg))
                .foregroundStyle(palette.ink.color)
                .focused($focused)
                .disabled({ if case .slider = model.mode { true } else { false } }())
                .accessibilityLabel(model.mode.isAsk ? "Ask a question about this Mac" : "Search")
            if !model.query.isEmpty {
                Button { model.setQuery("") } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(palette.ink4.color)
                }
                .buttonStyle(.plain)
                .help("Clear")
            } else if model.mode.isSearch, model.category == nil {
                Button { model.enterAsk(nil) } label: {
                    HStack(spacing: 6) {
                        NavIcon("ask", size: 13).foregroundStyle(palette.ink3.color)
                        Text("Ask").font(.ui(.xs)).foregroundStyle(palette.ink2.color)
                        KeyCap(keys: "⌘J")
                    }
                    .padding(.leading, Space.sm)
                    .padding(.trailing, Space.xs)
                    .frame(height: 26)
                    .background(palette.fill.color, in: .rect(cornerRadius: Radius.sm, style: .continuous))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Ask about this Mac (⌘J)")
            }
        }
        .padding(.leading, Space.xl)
        .padding(.trailing, Space.md)
        .frame(height: CommandBarPanel.compactHeight)
    }

    @ViewBuilder private var modeCard: some View {
        switch model.mode {
        case .confirm(let row, let action, _):
            BarConfirmCard(row: row, prompt: action?.confirm ?? row.confirm ?? "Are you sure?", onCancel: model.cancelMode,
                           onConfirm: model.confirm)
        case .number(let row, _):
            BarPromptCard(row: row, hint: "Return applies · Esc goes back", warning: model.message)
        case .naming(let row, _, let warning):
            BarPromptCard(row: row, hint: "Return saves · Esc goes back", warning: warning)
        default:
            EmptyView()
        }
    }
}

/// Hands the bar's keys to the model before the field sees them, while the
/// bar's window is key.
private struct KeyMonitor: NSViewRepresentable {
    let model: CommandBarModel

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.model = model
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) { view.model = model }

    final class MonitorView: NSView {
        var model: CommandBarModel?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // Local monitors run on the main thread.
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let model = self.model, let window = self.window, event.window === window,
                          window.isKeyWindow else { return false }
                    return model.handle(event)
                }
                return handled ? nil : event
            }
        }

        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            super.removeFromSuperview()
        }
    }
}

/// The views under the field: All, then each extension with something to show.
private struct BarChips: View {
    @Environment(\.palette) private var palette
    let model: CommandBarModel

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                chip(nil, "All")
                ForEach(model.chips, id: \.self) { chip($0, $0.label) }
            }
            .padding(.horizontal, Space.lg)
        }
        .scrollIndicators(.never)
        .padding(.top, Space.sm)
    }

    private func chip(_ category: BarCategory?, _ label: String) -> some View {
        let on = model.category == category
        return Button { model.setCategory(category) } label: {
            Text(label)
                .font(.ui(.xs))
                .foregroundStyle((on ? palette.ink : palette.ink3).color)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background((on ? palette.selected : ColorValue(r: 0, g: 0, b: 0, a: 0)).color, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The rows, with headings, the selection kept in view, and the empty state.
private struct BarResultList: View {
    @Environment(\.palette) private var palette
    let model: CommandBarModel

    static let tries = ["100 km to mi", "2+2*3", "volume 40", ":fire", "time in tokyo"]

    var body: some View {
        let rows = model.list.rows
        let quick = model.list.quickCount
        let empty = rows.isEmpty && (!model.query.isEmpty || model.category != nil)
        // The reader takes the space it's given without asking the rows how
        // tall they'd like to be: measuring every row on each keystroke was
        // half the cost of typing.
        GeometryReader { geo in
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Rows keep their place, not their result: typing swaps
                    // what a row shows instead of tearing rows down and
                    // building new ones, as native lists reuse their cells.
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if let heading = model.list.headings[index] {
                            Text(heading)
                                .font(.ui(.xxs, .medium))
                                .foregroundStyle(palette.ink3.color)
                                .padding(.horizontal, Space.md)
                                .padding(.top, index == 0 ? Space.sm : Space.md)
                                .padding(.bottom, 6)
                        }
                        BarRowView(row: row, selected: index == model.selectedIndex, badge: index < quick ? index + 1 : nil,
                                   query: model.split.text)
                            .id(index)
                            .onTapGesture { tap(row) }
                            .onContinuousHover { phase in if case .active = phase { model.hover(row.id) } }
                            .contextMenu { menu(row) }
                    }
                    if empty { emptyState }
                }
                .padding(.horizontal, Space.sm)
                .padding(.top, Space.xs)
                .padding(.bottom, Space.sm)
            }
            .scrollIndicators(.never)
            .frame(width: geo.size.width, height: geo.size.height)
            .onChange(of: model.selectedIndex) { follow(proxy) }
            .onChange(of: model.list.rows.first?.id) { follow(proxy) }
        }
        }
    }

    private func follow(_ proxy: ScrollViewProxy) {
        guard model.follow, model.selected != nil else { return }
        if model.selectedIndex == 0 {
            proxy.scrollTo(0, anchor: .bottom)
        } else {
            proxy.scrollTo(model.selectedIndex)
        }
    }

    private func tap(_ row: BarRow) {
        // A click outside the ⌘K list closes it, like any macOS menu.
        if model.mode.isActions {
            model.cancelMode()
        } else {
            model.run(row)
        }
    }

    @ViewBuilder private func menu(_ row: BarRow) -> some View {
        Button(row.copy != nil || row.answer ? "Copy" : "Open") { model.run(row) }
        Divider()
        ForEach(model.actions(for: row)) { action in
            Button(action.title, systemImage: action.symbol, role: action.destructive ? .destructive : nil) { model.runAction(row, action) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Space.lg) {
            Text(model.query.isEmpty ? "Nothing here right now." : "Nothing here by that name.")
                .font(.ui(.base)).foregroundStyle(palette.ink3.color)
            HStack(spacing: 6) {
                Text("Try").font(.ui(.xs)).foregroundStyle(palette.ink4.color)
                ForEach(Self.tries, id: \.self) { example in
                    Button { model.setQuery(example) } label: {
                        Text(example).font(.ui(.xs)).foregroundStyle(palette.ink2.color)
                            .padding(.horizontal, 10).frame(height: 24)
                            .background(palette.fill.color, in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
            Button("See suggestions") { model.setCategory(nil) }
                .buttonStyle(.lowtide(.secondary, size: .small))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.xxl + Space.sm)
    }
}

/// "Restart the Mac?" and friends: Return confirms, Esc cancels.
private struct BarConfirmCard: View {
    @Environment(\.palette) private var palette
    let row: BarRow
    let prompt: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        HStack(spacing: Space.lg) {
            BarIconView(icon: row.icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(prompt).font(.ui(.base)).foregroundStyle(palette.ink.color)
                Text("Return confirms · Esc cancels").font(.ui(.xs)).foregroundStyle(palette.ink3.color)
            }
            Spacer(minLength: Space.sm)
            Button("Cancel", action: onCancel).buttonStyle(.secondary)
            Button("Confirm", action: onConfirm).buttonStyle(.destructive)
        }
        .padding(Space.lg)
        .background(palette.badSoft.color, in: .rect(cornerRadius: Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(palette.bad.opacity(0.35).color))
        .padding(Space.md)
        .transition(.scale(scale: 0.98).combined(with: .opacity))
    }
}

/// A one-line prompt card: a number ("0 to 100"), or naming a row.
private struct BarPromptCard: View {
    @Environment(\.palette) private var palette
    let row: BarRow
    let hint: String
    let warning: String?

    var body: some View {
        HStack(spacing: Space.md) {
            BarIconView(icon: row.icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.ui(.base)).foregroundStyle(palette.ink.color).lineLimit(1)
                if let warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill").font(.ui(.xs)).foregroundStyle(palette.warn.color)
                } else {
                    Text(hint).font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, 14)
        .background(palette.fill.color, in: .rect(cornerRadius: Radius.md))
        .padding(Space.md)
    }
}

/// A live 0 to 100 slider for a row. Keys are handled by the model (← → or
/// ↑ ↓ step, ⌥ finer, Space toggles); the slider is only for the pointer.
private struct BarSliderCard: View {
    @Environment(\.palette) private var palette
    let row: BarRow
    let level: Int
    let onChange: (Int) -> Void

    var body: some View {
        let on = level > 0
        VStack(spacing: Space.md) {
            HStack(spacing: Space.md) {
                BarIconView(icon: row.icon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(.ui(.base)).foregroundStyle(palette.ink.color).lineLimit(1)
                    Text("← → adjust · ⌥ finer · Space \(on ? "off" : "on") · Return done")
                        .font(.ui(.xs)).foregroundStyle(palette.ink3.color).lineLimit(1)
                }
                Spacer(minLength: Space.sm)
                Text(on ? "\(level)%" : "Off")
                    .font(.title(.xl)).monospacedDigit().foregroundStyle(palette.ink.color)
                    .contentTransition(.numericText())
                    .frame(minWidth: 56, alignment: .trailing)
                Button(on ? "Turn Off" : "Turn On") { onChange(on ? 0 : 100) }.buttonStyle(.lowtide(.secondary, size: .small))
            }
            Slider(value: Binding(get: { Double(level) }, set: { onChange(Int($0.rounded())) }), in: 0...100, step: 1)
                .controlSize(.small)
                .accessibilityLabel(row.title)
                .accessibilityValue(on ? "\(level)%" : "Off")
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, 14)
        .background(palette.fill.color, in: .rect(cornerRadius: Radius.md))
        .padding(Space.md)
        .animation(Motion.fast, value: level)
    }
}

/// The ⌘K list for the selected row, floating over the bottom right.
private struct BarActionsPanel: View {
    @Environment(\.palette) private var palette
    let model: CommandBarModel
    let row: BarRow
    let index: Int

    var body: some View {
        let actions = model.actions(for: row)
        VStack(spacing: 0) {
            Text(row.title).font(.ui(.xs)).foregroundStyle(palette.ink3.color).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.md).padding(.vertical, 10)
                .hairline(.bottom)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(actions.enumerated()), id: \.element.id) { i, action in
                            let selected = i == index
                            let tone: Tone = action.destructive ? .bad : .neutral
                            HStack(spacing: 10) {
                                Image(systemName: action.symbol).font(.system(size: 13)).frame(width: 18).opacity(0.8)
                                Text(action.title).font(.ui(.sm)).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle((action.destructive ? palette.bad : palette.ink).color)
                            .padding(.horizontal, 10)
                            .frame(height: 34)
                            .background((selected ? (action.destructive ? tone.soft(palette) : palette.selected)
                                : ColorValue(r: 0, g: 0, b: 0, a: 0)).color, in: .rect(cornerRadius: Radius.sm))
                            .contentShape(.rect)
                            .id(i)
                            .onTapGesture { model.runAction(row, action) }
                            .onContinuousHover { if case .active = $0 { model.mode = .actions(row, index: i) } }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 300)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: index) { proxy.scrollTo(index) }
            }
        }
        .frame(width: 328)
        .overlaySurface()
    }
}

/// Bottom line: where you are, what Return does, and ⌘K.
private struct BarFooter: View {
    @Environment(\.palette) private var palette
    let model: CommandBarModel

    var body: some View {
        HStack(spacing: Space.md) {
            HStack(spacing: Space.sm) {
                if let message = model.message {
                    Text(message).foregroundStyle(palette.ink2.color).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                } else if model.mode.isAsk {
                    NavIcon("ask", filled: true, size: 14).foregroundStyle(palette.brand.color)
                    Text("Answered on this Mac by Apple Intelligence").foregroundStyle(palette.ink3.color).lineLimit(1)
                } else {
                    Logo(size: 16)
                    Text("Lowtide").foregroundStyle(palette.ink3.color)
                    if model.prefs.hotkeyEnabled, model.host == .panel {
                        Text("· \(model.prefs.hotkey.label)").foregroundStyle(palette.ink4.color)
                    }
                }
            }
            .font(.ui(.xs))
            Spacer(minLength: Space.sm)
            if model.mode.isAsk {
                if model.conversation.running {
                    hint("Stop", keys: ["⌘", "."])
                } else if !model.conversation.exchanges.isEmpty {
                    hint("New chat", keys: ["⌘", "N"])
                    divider
                }
                if let primary = model.primaryLabel { hint(primary, keys: ["↩"], strong: true) }
                divider
                hint("Search", keys: ["⇥"])
            } else {
                if let primary = model.primaryLabel { hint(primary, keys: ["↩"], strong: true) }
                if model.mode.isActions || (model.mode.isSearch && model.selected.map { !$0.answer } == true) {
                    divider
                    hint(model.mode.isActions ? "Close" : "Actions", keys: ["⌘", "K"])
                }
            }
        }
        .padding(.horizontal, Space.lg)
        .frame(height: 40)
        .hairline(.top)
    }

    private var divider: some View { Rectangle().fill(palette.lineStrong.color).frame(width: 1, height: 16) }

    private func hint(_ label: String, keys: [String], strong: Bool = false) -> some View {
        HStack(spacing: 5) {
            Text(label).font(.ui(.xs)).foregroundStyle((strong ? palette.ink2 : palette.ink3).color)
            ForEach(keys, id: \.self) { KeyCap(keys: $0) }
        }
    }
}
