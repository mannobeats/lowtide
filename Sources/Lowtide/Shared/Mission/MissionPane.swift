import SwiftUI

/// A titled section that can open over the window for a closer look: a
/// small semibold title row with its meta, and an expand button.
struct MissionPane<Content: View, Meta: View>: View {
    @Environment(\.palette) private var palette
    let title: String
    var expandable = false
    /// Rows go edge to edge (lists); otherwise the pane pads its content.
    var flush = false
    @ViewBuilder var meta: Meta
    @ViewBuilder var content: (Bool) -> Content
    @State private var expanded = false

    init(_ title: String, expandable: Bool = false, flush: Bool = false,
         @ViewBuilder meta: () -> Meta = { EmptyView() }, @ViewBuilder content: @escaping (Bool) -> Content) {
        self.title = title
        self.expandable = expandable
        self.flush = flush
        self.meta = meta()
        self.content = content
    }

    var body: some View {
        frame(open: false)
            .sheet(isPresented: $expanded) {
                frame(open: true)
                    .frame(minWidth: 860, idealWidth: 1100, minHeight: 560, idealHeight: 760)
                    .padding(Space.lg)
                    .background(palette.bg.color)
                    .onExitCommand { expanded = false }
            }
    }

    private func frame(open: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.sm) {
                Text(title).font(.ui(.xs, .semibold)).foregroundStyle(palette.ink2.color).lineLimit(1)
                Spacer(minLength: Space.sm)
                meta.font(.ui(.xs)).foregroundStyle(palette.ink3.color).monospacedDigit()
                if expandable {
                    IconButton(open ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                               help: open ? "Close (Esc)" : "Expand \(title)") { expanded.toggle() }
                }
            }
            .padding(.horizontal, Space.lg)
            .frame(height: 36)
            Group {
                if open || !expanded { content(open) } else { Color.clear.frame(height: 80) }
            }
            .padding(.horizontal, flush ? 0 : Space.lg)
            .padding(.bottom, flush ? Space.xs : Space.lg)
            .frame(maxHeight: open ? .infinity : nil, alignment: .top)
        }
        .card()
    }
}
