import SwiftUI

/// The top of a space: its glass object on the left, the answer in one
/// sentence, a line of detail and the one action. The art takes the space's
/// hue. Short windows get a compact hero so the list under it keeps room.
struct PageHero<Actions: View>: View {
    @Environment(\.palette) private var palette
    let art: String
    let title: String
    var detail: String?
    @ViewBuilder var actions: Actions

    init(_ title: String, detail: String? = nil, art: String, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.title = title
        self.detail = detail
        self.art = art
        self.actions = actions()
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            layout(compact: false)
            layout(compact: true)
        }
        .animation(Motion.base, value: title)
    }

    private func layout(compact: Bool) -> some View {
        HStack(alignment: .center, spacing: compact ? Space.lg : Space.page) {
            HeroArt(art, size: compact ? 56 : 88)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.title(compact ? .xl : .xxl))
                    .tracking(-0.3)
                    .foregroundStyle(palette.ink.color)
                    .contentTransition(.numericText())
                    .lineLimit(2)
                if let detail {
                    Text(detail).font(.ui(.sm)).foregroundStyle(palette.ink3.color).lineLimit(2).padding(.top, 6)
                }
                HStack(spacing: Space.sm) { actions }.padding(.top, compact ? 10 : Space.lg)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, compact ? 0 : Space.sm)
    }
}

/// The masthead a page without a hero shares: the title, one line of meta,
/// views under it, and the page's one action on the right.
struct PageHeader<Action: View, Tabs: View>: View {
    @Environment(\.palette) private var palette
    let title: String
    var description: String?
    /// One row (title, its line of facts, the action) for pages that are
    /// mostly a live list: the rows start right under it.
    var compact = false
    @ViewBuilder var tabs: Tabs
    @ViewBuilder var action: Action

    init(_ title: String, description: String? = nil, compact: Bool = false,
         @ViewBuilder tabs: () -> Tabs = { EmptyView() },
         @ViewBuilder action: () -> Action = { EmptyView() }) {
        self.title = title
        self.description = description
        self.compact = compact
        self.tabs = tabs()
        self.action = action()
    }

    var body: some View {
        if compact { row } else { masthead }
    }

    private var row: some View {
        HStack(alignment: .center, spacing: Space.md) {
            Text(title).font(.title(.lg)).tracking(-0.2).foregroundStyle(palette.ink.color).fixedSize()
            if let description {
                Text(description).font(.ui(.sm)).foregroundStyle(palette.ink3.color).lineLimit(1).truncationMode(.tail)
                    .help(description)
            }
            Spacer(minLength: Space.md)
            HStack(spacing: 6) { action }.fixedSize()
        }
        .frame(minHeight: 32)
        .padding(.horizontal, Space.page + 4)
        .padding(.top, Space.md)
        .padding(.bottom, Space.sm)
    }

    private var masthead: some View {
        HStack(alignment: .bottom, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title(.xl)).tracking(-0.2).foregroundStyle(palette.ink.color)
                if let description {
                    Text(description).font(.ui(.sm)).foregroundStyle(palette.ink3.color).frame(maxWidth: 640, alignment: .leading)
                }
                tabs.padding(.top, 8)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) { action }
        }
        .padding(.horizontal, Space.page + 4)
        .padding(.top, Space.page)
        .padding(.bottom, Space.lg)
    }
}

/// Each space's hue, set by the shell: its wash and its hero's rim light.
extension EnvironmentValues {
    @Entry var spaceHue: Double = 195
}

/// The breath of the space's colour at the top of the canvas.
struct SpaceWash: View {
    @Environment(\.palette) private var palette
    let hue: Double
    var body: some View {
        LinearGradient(colors: [palette.wash(hue: hue).color, palette.wash(hue: hue).opacity(0).color],
                       startPoint: .top, endPoint: .bottom)
            .frame(height: 280)
            .frame(maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.4), value: hue)
    }
}
