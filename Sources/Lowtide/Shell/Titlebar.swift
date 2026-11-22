import SwiftUI

/// The card has no titlebar row: pages start at the top, search lives in
/// the rail (and ⌘K), and the sidebar toggle in the sidebar's header. Only
/// a space with tabs (Network) keeps a slim row for them. Empty stretches
/// of it drag the window and double-click as a titlebar does.
struct SpaceTabsBar: View {
    let space: SpaceID

    var body: some View {
        ZStack(alignment: .leading) {
            TitlebarArea()
            SpaceTabs(space: space).padding(.horizontal, 12)
        }
        .frame(height: 44)
        .hairline(.bottom)
    }
}

/// The top edge of a page without a bar: a strip as tall as the pages' own
/// top margin, so the window drags from there without covering controls.
struct TopEdge: View {
    var body: some View {
        TitlebarArea().frame(height: 12).frame(maxHeight: .infinity, alignment: .top)
    }
}

/// Shows or hides the source list. It sits in the sidebar's header, as in
/// Finder and Notes; once hidden, ⌃⌘S, View › Show Sidebar or a click on
/// the current space in the rail brings it back.
struct SidebarToggle: View {
    @Environment(\.palette) private var palette
    @State private var hovering = false
    private var model = AppModel.shared

    var body: some View {
        let help = model.sidebarHidden ? "Show sidebar (⌃⌘S)" : "Hide sidebar (⌃⌘S)"
        Button { model.toggleSidebar() } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle((hovering ? palette.ink : palette.ink3).color)
                .frame(width: 28, height: 28)
                .background(hovering ? palette.hover.color : .clear, in: .rect(cornerRadius: Radius.md))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
    }
}
