import LowtideKit
import SwiftUI

/// Counts shown beside pages in the sidebar and tabs. Spaces set them;
/// zero hides the capsule. `warning` turns it amber (it asks for action).
@Observable
final class SidebarBadges {
    static let shared = SidebarBadges()
    var counts: [Page: Int] = [:]
    var warning: Set<Page> = []
    /// A quiet total beside a page's name ("Installed 214").
    var totals: [Page: Int] = [:]
    /// A small amber dot (a report waiting).
    var dots: Set<Page> = []
}

/// A Mac source list for the current space: its name as the title, 28 pt
/// rows, group headings, an 8 pt selection in the brand tint. Home and
/// Network have none; it slides shut instead of jumping.
struct SourceList: View {
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var model = AppModel.shared
    @State private var shown: SpaceID = .apps
    /// Bumped when an extension is switched on or off (its group changes).
    @State private var revision = 0

    var body: some View {
        let open = model.hasSidebar && !model.sidebarHidden
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottom) {
                TitlebarArea()
                HStack(spacing: 0) {
                    Text(shown.title)
                        .font(.ui(.sm, .semibold))
                        .foregroundStyle(palette.ink.color)
                        .allowsHitTesting(false)
                    Spacer(minLength: 0)
                    SidebarToggle()
                }
                .padding(.leading, 16)
                .padding(.trailing, 8)
                .padding(.bottom, 2)
            }
            .frame(height: 48)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.groups.enumerated()), id: \.offset) { _, group in
                        if let heading = group.0 {
                            Text(heading)
                                .font(.ui(.xxs, .semibold))
                                .foregroundStyle(palette.ink3.color)
                                .frame(height: 24)
                                .padding(.horizontal, 8)
                                .padding(.top, 16)
                        }
                        VStack(spacing: 1) {
                            ForEach(group.1) { page in
                                SourceRow(page: page, active: model.page == page) { model.open(page) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.never)
        }
        .frame(width: 248)
        .frame(width: open ? 248 : 0, alignment: .leading)
        .clipped()
        .opacity(open ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: open)
        .id(revision)
        .onReceive(NotificationCenter.default.publisher(for: ExtensionState.changed)) { _ in revision += 1 }
        .onChange(of: model.page.space, initial: true) { _, space in
            if space.navigation == .sidebar { shown = space }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(shown.title) navigation")
    }
}

private struct SourceRow: View {
    @Environment(\.palette) private var palette
    @Environment(\.controlActiveState) private var windowState
    @State private var hovering = false
    private var badges = SidebarBadges.shared
    let page: Page
    let active: Bool
    let action: () -> Void

    init(page: Page, active: Bool, action: @escaping () -> Void) {
        self.page = page
        self.active = active
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                NavIcon(page.glyph, filled: active, size: 16)
                    .foregroundStyle((active ? palette.brand : hovering ? palette.ink2 : palette.ink3).color)
                HStack(spacing: 6) {
                    Text(page.title).foregroundStyle((active || hovering ? palette.ink : palette.ink2).color)
                    if let total = badges.totals[page], total > 0 {
                        Text(total.formatted()).font(.ui(.xs)).foregroundStyle(palette.ink4.color).monospacedDigit()
                    }
                }
                .font(.ui(.sm))
                .lineLimit(1)
                Spacer(minLength: 4)
                if badges.dots.contains(page) {
                    Circle().fill(palette.warn.color).frame(width: 6, height: 6)
                }
                CountCapsule(value: badges.counts[page] ?? 0, warning: badges.warning.contains(page))
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background((active ? (windowState == .inactive ? palette.selected : palette.selectedBrand)
                         : hovering ? palette.hover : ColorValue(r: 0, g: 0, b: 0, a: 0)).color,
                        in: .rect(cornerRadius: Radius.md))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.fast, value: hovering)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// A count in a capsule: quiet for a total, amber only when it asks for action.
struct CountCapsule: View {
    @Environment(\.palette) private var palette
    let value: Int
    var warning = false
    var body: some View {
        if value > 0 {
            Text(value.formatted())
                .font(.ui(.xxs, .medium)).monospacedDigit()
                .foregroundStyle((warning ? palette.warn : palette.ink3).color)
                .padding(.horizontal, 6)
                .frame(minWidth: 18, minHeight: 18)
                .background((warning ? palette.warnSoft : palette.fill).color, in: .capsule)
        }
    }
}

/// A space's pages as tabs above the page, in place of a sidebar, so the
/// page keeps the window's full width (Network's live map).
struct SpaceTabs: View {
    @Environment(\.palette) private var palette
    private var model = AppModel.shared
    private var badges = SidebarBadges.shared
    let space: SpaceID

    init(space: SpaceID) { self.space = space }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(space.pages) { page in
                let active = model.page == page
                Button { model.open(page) } label: {
                    HStack(spacing: 7) {
                        NavIcon(page.glyph, filled: active, size: 15)
                            .foregroundStyle((active ? palette.brand : palette.ink3).color)
                        Text(page.title).font(.ui(.sm)).foregroundStyle((active ? palette.ink : palette.ink2).color)
                        if badges.dots.contains(page) {
                            Circle().fill(palette.warn.color).frame(width: 6, height: 6)
                        }
                        CountCapsule(value: badges.counts[page] ?? 0, warning: badges.warning.contains(page))
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background((active ? palette.selectedBrand : ColorValue(r: 0, g: 0, b: 0, a: 0)).color, in: .rect(cornerRadius: Radius.md))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(page.title)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .fixedSize()
    }
}
