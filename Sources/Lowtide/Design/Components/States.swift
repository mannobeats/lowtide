import SwiftUI

/// What a page shows before there is data: what it is, why it's empty, the
/// one thing to do.
struct EmptyState<Action: View>: View {
    @Environment(\.palette) private var palette
    let symbol: String
    let title: String
    var message: String?
    @ViewBuilder var action: Action

    init(_ title: String, symbol: String, message: String? = nil, @ViewBuilder action: () -> Action = { EmptyView() }) {
        self.title = title
        self.symbol = symbol
        self.message = message
        self.action = action()
    }

    var body: some View {
        VStack(spacing: Space.md) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(palette.ink3.color)
                .symbolRenderingMode(.hierarchical)
            Text(title).font(.ui(.base, .semibold)).foregroundStyle(palette.ink.color)
            if let message {
                Text(message).font(.ui(.sm)).foregroundStyle(palette.ink3.color)
                    .multilineTextAlignment(.center).frame(maxWidth: 380)
            }
            action.padding(.top, Space.xs)
        }
        .padding(Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A scan in progress: what's being looked at, how far along.
struct ScanningState: View {
    @Environment(\.palette) private var palette
    let title: String
    var detail: String?
    var progress: Double?

    var body: some View {
        VStack(spacing: Space.md) {
            if let progress {
                ProgressView(value: progress).progressViewStyle(.linear).frame(width: 220).tint(palette.brand.color)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(title).font(.ui(.sm, .medium)).foregroundStyle(palette.ink2.color)
            if let detail {
                Text(detail).font(.mono(.xxs)).foregroundStyle(palette.ink3.color).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// An error in place of content, with a retry.
struct ErrorState: View {
    @Environment(\.palette) private var palette
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        EmptyState("Something went wrong", symbol: "exclamationmark.triangle", message: message) {
            if let retry { Button("Try Again", action: retry).buttonStyle(.secondary) }
        }
    }
}
