import LowtideKit
import SwiftUI

/// Developer › Sessions: terminal tabs with split panes. With no sessions,
/// a calm start with the last few saved hosts one click away.
struct SessionsPage: View {
    @Environment(\.palette) private var palette
    private var store = SessionStore.shared

    var body: some View {
        Group {
            if store.workspace.roots.isEmpty {
                Launchpad().overlay { TopEdge() }
            } else {
                VStack(spacing: 0) {
                    TabStrip()
                    TerminalSplitArea()
                        .padding(.horizontal, Space.xs)
                        .padding(.bottom, Space.xs)
                }
                .background(Color(nsColor: TerminalColors.current.background))
            }
        }
        .onAppear { store.focusSoon() }
        .task { if !store.remote.loaded { await store.remote.load() } }
    }
}

/// No sessions yet.
private struct Launchpad: View {
    @Environment(\.palette) private var palette
    private var remote = RemoteStore.shared

    var recent: [RemoteHost] {
        Array(remote.snapshot.hosts.sorted { ($0.lastConnectedAt ?? 0) > ($1.lastConnectedAt ?? 0) }.prefix(4))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Space.xl) {
                HeroArt("developer", size: 96)
                VStack(spacing: Space.xs) {
                    Text("No sessions open").font(.title(.xl)).foregroundStyle(palette.ink.color)
                    Text("Open a shell on this Mac, or connect to a server over SSH.")
                        .font(.ui(.sm)).foregroundStyle(palette.ink3.color)
                }
                HStack(spacing: Space.sm) {
                    Button {
                        SessionStore.shared.openLocal()
                    } label: {
                        HStack(spacing: 6) {
                            Text("New terminal")
                            Text("⌘T").opacity(0.7)
                        }
                    }
                    .buttonStyle(.primary)
                    Button {
                        QuickConnect.present()
                    } label: {
                        HStack(spacing: 6) {
                            Text("Quick connect")
                            Text("⇧⌘K").foregroundStyle(palette.ink3.color)
                        }
                    }
                    .buttonStyle(.secondary)
                }
                if !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        GroupHeading("Recent hosts").padding(.horizontal, Space.xs)
                        VStack(spacing: 0) {
                            ForEach(Array(recent.enumerated()), id: \.element.id) { index, host in
                                if index > 0 { Hairline() }
                                RecentHostRow(host: host)
                            }
                        }
                        .card()
                    }
                    .frame(width: 340)
                    .padding(.top, Space.md)
                }
            }
            .padding(Space.xxl)
            .frame(maxWidth: .infinity)
            .containerRelativeFrame(.vertical, alignment: .center) { length, _ in length }
        }
        .scrollContentBackground(.hidden)
    }
}

private struct RecentHostRow: View {
    @Environment(\.palette) private var palette
    @State private var hovering = false
    let host: RemoteHost

    var body: some View {
        Button { RemoteStore.shared.connect(host) } label: {
            HStack(spacing: Space.md) {
                Text(host.name).font(.ui(.sm)).foregroundStyle(palette.ink.color).lineLimit(1)
                Spacer(minLength: Space.sm)
                Sensitive(text: host.hostname, font: .mono(.xs))
                    .foregroundStyle(palette.ink3.color).lineLimit(1).frame(maxWidth: 150, alignment: .trailing)
            }
            .padding(.horizontal, Space.md)
            .frame(height: 40)
            .background(hovering ? palette.hover.color : .clear)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Connect to \(host.name)")
    }
}

// MARK: - Tab strip

/// The tabs, the new-tab button right after them (as in Safari and
/// Terminal), then one split button and a menu for the rest. Tabs drag to
/// reorder; the empty stretch moves the window and a double-click there
/// opens a tab, as in Safari.
private struct TabStrip: View {
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var store = SessionStore.shared
    private var model = AppModel.shared
    @State private var settingsOpen = false
    @State private var stripWidth: CGFloat = 0
    /// Each tab's place in the strip, for reordering by drag.
    @State private var frames: [String: CGRect] = [:]
    @State private var dragged: (id: String, grab: CGFloat)?
    @State private var dragX: CGFloat = 0

    var body: some View {
        let roots = store.workspace.roots
        HStack(spacing: Space.xs) {
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(Array(roots.enumerated()), id: \.element.id) { index, tab in
                        if index > 0, !tab.pinned, roots[index - 1].pinned {
                            Rectangle().fill(palette.lineStrong.color).frame(width: 1, height: 16).padding(.horizontal, Space.xs)
                        }
                        TabItem(tab: tab, active: tab.id == store.workspace.activeID,
                                panes: store.workspace.panes(of: tab.id).count, lifted: dragged?.id == tab.id)
                            .offset(x: offset(of: tab.id))
                            .zIndex(dragged?.id == tab.id ? 1 : 0)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("tabs")) } action: { frames[tab.id] = $0 }
                            .gesture(reorder(tab))
                    }
                    IconButton("plus", help: "New local terminal (⌘T)") { store.openLocal() }
                    TitlebarArea(doubleClick: .run { SessionStore.shared.openLocal() })
                        .frame(minWidth: Space.xl, maxWidth: .infinity)
                }
                .frame(minWidth: stripWidth, alignment: .leading)
                .padding(.vertical, Space.xs)
                .coordinateSpace(.named("tabs"))
            }
            .scrollIndicators(.never)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { stripWidth = $0 }
            IconButton("rectangle.split.2x1", help: "Split right (⌘D) · ⇧⌘D splits down") { store.split(axis: .row) }
            IconMenu("ellipsis", help: "More") { menu }
                .popover(isPresented: $settingsOpen, arrowEdge: .bottom) { TerminalSettingsPopover() }
        }
        .padding(.horizontal, Space.sm)
        .frame(height: 38)
        .hairline(.bottom)
    }

    @ViewBuilder private var menu: some View {
        let panes = store.workspace.activeID.map { store.workspace.panes(of: $0).count } ?? 0
        Button("Quick Connect…") { QuickConnect.present() }.keyboardShortcut("k", modifiers: [.command, .shift])
        Divider()
        Button("Split Right") { store.split(axis: .row) }.keyboardShortcut("d")
        Button("Split Down") { store.split(axis: .column) }.keyboardShortcut("d", modifiers: [.command, .shift])
        Button(store.workspace.activeID.flatMap { store.workspace.zoomedPane(in: $0) } == nil ? "Zoom Pane" : "Restore Panes") {
            store.toggleZoom()
        }
        .keyboardShortcut(.return, modifiers: [.command, .shift])
        .disabled(panes < 2)
        Button("Even Out Panes") { store.equalize() }.disabled(panes < 2)
        Divider()
        Button("Find in Scrollback…") { store.findOpen = true }.keyboardShortcut("f")
        Divider()
        Button(model.sidebarHidden ? "Show Sidebar" : "Hide Sidebar") { model.toggleSidebar() }
            .keyboardShortcut("s", modifiers: [.command, .control])
        Button((NSApp.keyWindow?.styleMask.contains(.fullScreen) ?? false) ? "Exit Full Screen" : "Enter Full Screen") {
            NSApp.keyWindow?.toggleFullScreen(nil)
        }
        .keyboardShortcut(.return)
        Divider()
        Button("Terminal Settings…") { settingsOpen = true }
    }

    private func offset(of id: String) -> CGFloat {
        guard let dragged, dragged.id == id, let frame = frames[id] else { return 0 }
        return dragX - dragged.grab - frame.minX
    }

    /// Drag a tab along the strip: it follows the pointer and its
    /// neighbours slide out of the way once the pointer passes their middle.
    private func reorder(_ tab: TerminalTab) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("tabs"))
            .onChanged { value in
                if dragged == nil {
                    guard let frame = frames[tab.id] else { return }
                    dragged = (tab.id, value.startLocation.x - frame.minX)
                    store.select(tab.id)
                }
                dragX = value.location.x
                guard let own = frames[tab.id] else { return }
                let x = value.location.x
                let passed = store.workspace.roots.first { other in
                    guard other.id != tab.id, other.pinned == tab.pinned, let frame = frames[other.id] else { return false }
                    return frame.minX > own.minX ? x > frame.midX && x <= frame.maxX + 2
                                                 : x < frame.midX && x >= frame.minX - 2
                }
                if let passed {
                    withAnimation(reduceMotion ? nil : Motion.fast) { store.moveTab(tab.id, to: passed.id) }
                }
            }
            .onEnded { _ in
                withAnimation(reduceMotion ? nil : Motion.spring) { dragged = nil }
                store.focusSoon()
            }
    }
}

/// A tab: its icon and name in the middle, the close button on the right
/// (on hover, and always on the active tab).
private struct TabItem: View {
    @Environment(\.palette) private var palette
    @State private var hovering = false
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool
    let tab: TerminalTab
    let active: Bool
    let panes: Int
    var lifted = false

    private var store: SessionStore { SessionStore.shared }

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 18, height: 18)
            HStack(spacing: 6) {
                if tab.pinned {
                    Image(systemName: "pin.fill").font(.system(size: 9)).rotationEffect(.degrees(45))
                        .foregroundStyle(palette.ink3.color)
                } else {
                    NavIcon(tab.kind == .ssh ? "hosts" : "sessions", filled: active, size: 14)
                        .foregroundStyle((active && !tab.closed ? palette.brand : palette.ink4).color)
                }
                if editing {
                    TextField("Name", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.ui(.xs))
                        .focused($fieldFocused)
                        .onSubmit(commit)
                        .onExitCommand { editing = false }
                        .onChange(of: fieldFocused) { _, focused in if !focused { commit() } }
                        .frame(minWidth: 60)
                } else {
                    Text(tab.title).font(.ui(.sm)).lineLimit(1).truncationMode(.middle)
                }
                if tab.closed, !editing {
                    Text("Exited").font(.ui(.xxs)).foregroundStyle(palette.ink4.color)
                }
                if panes > 1, !editing {
                    Text("×\(panes)").font(.ui(.xxs)).monospacedDigit().foregroundStyle(palette.ink4.color)
                        .help("\(panes) panes")
                }
            }
            .frame(maxWidth: .infinity)
            CloseButton { store.close(tab.id) }
                .opacity(hovering || active ? 1 : 0)
                .allowsHitTesting(hovering || active)
        }
        .foregroundStyle((active ? palette.ink : tab.closed ? palette.ink4 : hovering ? palette.ink2 : palette.ink3).color)
        .padding(.horizontal, Space.xs)
        .frame(minWidth: tab.pinned ? 0 : 120, maxWidth: tab.pinned ? 160 : 220)
        .frame(height: 28)
        .background((active ? palette.fill : hovering ? palette.hover : ColorValue(r: 0, g: 0, b: 0, a: 0)).color,
                    in: .rect(cornerRadius: Radius.md))
        .overlay {
            if active { RoundedRectangle(cornerRadius: Radius.md).strokeBorder(palette.line.color) }
        }
        .shadow(color: .black.opacity(lifted ? 0.25 : 0), radius: 6, y: 2)
        .contentShape(.rect)
        // Both taps are simultaneous so a single click selects at once
        // instead of waiting to see whether a second one follows.
        .simultaneousGesture(TapGesture().onEnded { store.select(tab.id) })
        .simultaneousGesture(TapGesture(count: 2).onEnded { startRename() })
        .onHover { hovering = $0 }
        .animation(Motion.fast, value: hovering)
        .help(tab.title)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Close") { store.close(tab.id) }
        .contextMenu {
            Button("Rename") { startRename() }
            Button("Duplicate") { store.duplicate(tab.id) }.disabled(tab.oneShot)
            Button(tab.pinned ? "Unpin" : "Pin Tab") { store.togglePin(tab.id) }.disabled(tab.oneShot)
            Divider()
            Button("Close Others") { store.closeOthers(tab.id) }
            Button("Close Tab", role: .destructive) { store.close(tab.id) }
        }
    }

    private func startRename() {
        draft = tab.title
        editing = true
        fieldFocused = true
    }

    private func commit() {
        guard editing else { return }
        editing = false
        store.rename(tab.id, to: draft)
        store.focusSoon()
    }
}

private struct CloseButton: View {
    @Environment(\.palette) private var palette
    @State private var hovering = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                .foregroundStyle((hovering ? palette.ink : palette.ink3).color)
                .frame(width: 18, height: 18)
                .background(hovering ? palette.hover.color : .clear, in: .rect(cornerRadius: Radius.sm))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Close tab (⌘W)")
        .accessibilityLabel("Close tab")
    }
}

/// Font size, cursor and behaviour, changed live.
private struct TerminalSettingsPopover: View {
    @Bindable private var settings = TerminalSettings.shared

    var body: some View {
        Form {
            LabeledContent("Text size") {
                HStack(spacing: Space.sm) {
                    Text("\(Int(settings.fontSize)) pt").monospacedDigit()
                    Stepper("Text size", value: $settings.fontSize, in: TerminalSettings.fontRange, step: 1).labelsHidden()
                }
            }
            Picker("Cursor", selection: $settings.cursor) {
                Text("Bar").tag(TerminalSettings.Cursor.bar)
                Text("Block").tag(TerminalSettings.Cursor.block)
                Text("Underline").tag(TerminalSettings.Cursor.underline)
            }
            Toggle("Blinking cursor", isOn: $settings.cursorBlink)
            Toggle("Copy text when selected", isOn: $settings.copyOnSelect)
            Toggle("Suggest commands as I type", isOn: $settings.autocomplete)
            Toggle("Use Option as Meta", isOn: $settings.optionAsMeta)
        }
        .formStyle(.grouped)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
    }
}
