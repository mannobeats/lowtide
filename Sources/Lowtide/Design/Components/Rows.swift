import SwiftUI

/// A list row: icon, title, a line under it, and what sits at the end.
struct ListRow<Leading: View, Trailing: View>: View {
    @Environment(\.palette) private var palette
    let title: String
    var subtitle: String?
    var monoSubtitle = false
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    init(_ title: String, subtitle: String? = nil, monoSubtitle: Bool = false,
         @ViewBuilder leading: () -> Leading = { EmptyView() },
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.monoSubtitle = monoSubtitle
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: Space.md) {
            leading
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color).lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(monoSubtitle ? .mono(.xxs) : .ui(.xs))
                        .foregroundStyle(palette.ink3.color)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: Space.sm)
            trailing
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, 7)
        .frame(minHeight: 40)
        .contentShape(.rect)
    }
}

/// A label and its value on one line.
struct KeyValueRow: View {
    @Environment(\.palette) private var palette
    let key: String
    let value: String
    var mono = false
    var tone: Tone?

    init(_ key: String, _ value: String, mono: Bool = false, tone: Tone? = nil) {
        self.key = key
        self.value = value
        self.mono = mono
        self.tone = tone
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).font(.ui(.sm)).foregroundStyle(palette.ink3.color)
            Spacer(minLength: Space.md)
            Text(value)
                .font(mono ? .mono(.xs) : .ui(.sm))
                .foregroundStyle((tone?.color(palette) ?? palette.ink).color)
                .textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, Space.lg)
        .frame(minHeight: 30)
    }
}

/// A small heading above a group.
struct GroupHeading: View {
    @Environment(\.palette) private var palette
    let text: String
    var trailing: String?
    init(_ text: String, trailing: String? = nil) {
        self.text = text
        self.trailing = trailing
    }
    var body: some View {
        HStack {
            Text(text).font(.ui(.xxs, .semibold)).foregroundStyle(palette.ink3.color)
            Spacer()
            if let trailing { Text(trailing).font(.ui(.xxs)).foregroundStyle(palette.ink4.color) }
        }
    }
}

/// A big number with its label: hero stats and summary tiles.
struct StatTile: View {
    @Environment(\.palette) private var palette
    let label: String
    let value: String
    var detail: String?
    var tone: Tone = .neutral

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.ui(.xs)).foregroundStyle(palette.ink3.color)
            Text(value).font(.title(.xl)).monospacedDigit()
                .foregroundStyle((tone == .neutral ? palette.ink : tone.color(palette)).color)
                .contentTransition(.numericText())
            if let detail { Text(detail).font(.ui(.xs)).foregroundStyle(palette.ink3.color).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: Space.lg)
    }
}
