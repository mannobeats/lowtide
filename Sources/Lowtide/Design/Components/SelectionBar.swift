import SwiftUI

/// The floating bar under a multiple selection: how many (and `status`, e.g.
/// their size or what a running action is doing), what can be done with
/// them, and clear. A measured bar runs along its bottom edge while
/// `working`. Hidden while nothing is selected.
struct SelectionBar<Actions: View>: View {
    @Environment(\.palette) private var palette
    let count: Int
    let noun: String
    var plural: String?
    var status: String?
    var progress: Double?
    var working = false
    let clear: () -> Void
    @ViewBuilder var actions: Actions

    init(count: Int, noun: String, plural: String? = nil, status: String? = nil, progress: Double? = nil, working: Bool = false,
         clear: @escaping () -> Void, @ViewBuilder actions: () -> Actions) {
        self.count = count
        self.noun = noun
        self.plural = plural
        self.status = status
        self.progress = progress
        self.working = working
        self.clear = clear
        self.actions = actions()
    }

    var body: some View {
        if count > 0 {
            HStack(spacing: Space.md) {
                Text("\(LowtideFormat.count(count, noun, plural)) selected")
                    .font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color).monospacedDigit().lineLimit(1).fixedSize()
                if let status {
                    Text(status).font(.ui(.xs)).foregroundStyle(palette.ink3.color).monospacedDigit().lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: Space.xs)
                actions
                IconButton("xmark", help: "Clear the selection (Esc)", action: clear)
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
            }
            .padding(.leading, Space.lg)
            .padding(.trailing, Space.xs)
            .frame(height: 44)
            .overlay(alignment: .bottom) {
                if working {
                    Meter(value: progress ?? 0.04, height: 2).padding(.horizontal, Space.sm).padding(.bottom, 1)
                }
            }
            .overlaySurface(radius: Radius.lg)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
