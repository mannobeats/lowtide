import SwiftUI

/// The standard page: a hero, then the page's groups, on a scrolling
/// canvas with the window's margins. Full-bleed pages (the terminal, the
/// map) don't use it.
struct PageScaffold<Hero: View, Content: View>: View {
    @ViewBuilder var hero: Hero
    @ViewBuilder var content: Content
    var maxWidth: CGFloat = 1180

    init(maxWidth: CGFloat = 1180, @ViewBuilder hero: () -> Hero, @ViewBuilder content: () -> Content) {
        self.maxWidth = maxWidth
        self.hero = hero()
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                hero.padding(.bottom, Space.xs)
                content
            }
            .padding(.horizontal, Space.page + 4)
            .padding(.top, Space.xl)
            .padding(.bottom, Space.page * 2)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
    }
}

/// A row of view switches and tools under the hero (Map · Connections, a
/// filter, a refresh).
struct PageToolbar<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.leading = leading()
        self.trailing = trailing()
    }
    var body: some View {
        HStack(spacing: Space.sm) {
            leading
            Spacer(minLength: Space.md)
            trailing
        }
    }
}
