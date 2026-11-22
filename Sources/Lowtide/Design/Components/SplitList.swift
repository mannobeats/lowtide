import SwiftUI

/// The split: a list on the left (search, filters, a select-all
/// row, rows, the bulk bar), the selected item on the right.
struct SplitList<Filters: View, List: View, Detail: View>: View {
    @Environment(\.palette) private var palette
    @Binding var query: String
    let searchPrompt: String
    var selectAll: (state: CheckState, summary: String, toggle: () -> Void)?
    @ViewBuilder var filters: Filters
    @ViewBuilder var list: List
    @ViewBuilder var detail: Detail

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: Space.sm) {
                    FilterField(text: $query, prompt: searchPrompt, width: .infinity)
                    filters
                }
                .padding(.horizontal, Space.md)
                .padding(.top, Space.md)
                .padding(.bottom, Space.sm)
                if let selectAll {
                    HStack(spacing: Space.sm) {
                        Checkbox(selectAll.state, label: "Select all", toggle: selectAll.toggle)
                        Text(selectAll.summary).font(.ui(.xs)).foregroundStyle(palette.ink3.color).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Space.md)
                    .frame(height: 30)
                    .hairline(.bottom)
                    .hairline(.top)
                }
                list.frame(maxHeight: .infinity)
            }
            .frame(width: 330)
            .hairline(.trailing)
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .hairline(.top)
    }
}

/// A row in a split list: a checkbox, the row's body, selected or not.
struct SplitRow<Content: View>: View {
    @Environment(\.palette) private var palette
    @State private var hovering = false
    var checked: Bool?
    var checkLabel = ""
    var selected = false
    var dimmed = false
    var onCheck: () -> Void = {}
    var onSelect: () -> Void = {}
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: Space.sm + 2) {
            if let checked {
                Checkbox(checked, label: checkLabel, toggle: onCheck)
            } else {
                Color.clear.frame(width: 14, height: 14)
            }
            content
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, 5)
        .frame(minHeight: 44)
        .background {
            RoundedRectangle(cornerRadius: Radius.md)
                .fill((selected ? palette.selectedBrand : hovering ? palette.hover : ColorValue(r: 0, g: 0, b: 0, a: 0)).color)
                .padding(.horizontal, Space.xs)
        }
        .opacity(dimmed ? 0.55 : 1)
        .contentShape(.rect)
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .animation(Motion.fast, value: hovering)
    }
}
