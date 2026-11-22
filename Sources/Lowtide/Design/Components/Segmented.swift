import SwiftUI

/// A segmented control whose thumb springs to the chosen segment. For
/// views inside a page (Map · Connections) and small filters.
struct Segmented<Value: Hashable>: View {
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var thumb
    @Binding var selection: Value
    let options: [(Value, String)]
    var counts: [Value: Int] = [:]

    init(_ selection: Binding<Value>, _ options: [(Value, String)], counts: [Value: Int] = [:]) {
        _selection = selection
        self.options = options
        self.counts = counts
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                let on = value == selection
                Button {
                    withAnimation(Motion.spring(reduceMotion)) { selection = value }
                } label: {
                    HStack(spacing: 5) {
                        Text(label)
                        if let count = counts[value], count > 0 {
                            Text(count.formatted()).font(.ui(.xxs, .medium)).monospacedDigit()
                                .foregroundStyle((on ? palette.ink2 : palette.ink3).color)
                        }
                    }
                    .font(.ui(.xs, on ? .semibold : .regular))
                    .foregroundStyle((on ? palette.ink : palette.ink3).color)
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: Radius.sm)
                                .fill(palette.overlay.color)
                                .overlay(RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(palette.line.color))
                                .matchedGeometryEffect(id: "thumb", in: thumb)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(palette.fill.color, in: .rect(cornerRadius: Radius.md))
    }
}
