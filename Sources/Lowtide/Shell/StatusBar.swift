import SwiftUI

/// Live facts for the bottom line of the window, set by the spaces that
/// own them (the network's interface, the CPU, the running jobs).
@Observable
final class StatusLine {
    static let shared = StatusLine()
    struct Item: Identifiable, Equatable {
        var id: String
        var text: String
        var tone: Tone = .neutral
        var symbol: String?
        static func == (a: Item, b: Item) -> Bool { a.id == b.id && a.text == b.text }
    }
    var items: [Item] = []

    func set(_ id: String, _ text: String?, tone: Tone = .neutral, symbol: String? = nil, order: Int? = nil) {
        guard let text else { items.removeAll { $0.id == id }; return }
        let item = Item(id: id, text: text, tone: tone, symbol: symbol)
        if let index = items.firstIndex(where: { $0.id == id }) {
            if items[index] != item { items[index] = item }
        } else if let order, order < items.count {
            items.insert(item, at: order)
        } else {
            items.append(item)
        }
    }
}

struct StatusBar: View {
    @Environment(\.palette) private var palette
    @Environment(\.privacy) private var privacy
    private var line = StatusLine.shared
    private var jobs = Jobs.shared

    /// The terminal and full screen keep their room: there the line only
    /// shows running jobs.
    private var items: [StatusLine.Item] {
        let model = AppModel.shared
        return model.page == .sessions || model.immersive ? [] : line.items
    }

    var body: some View {
        if !items.isEmpty || !jobs.running.isEmpty { bar }
    }

    private var bar: some View {
        HStack(spacing: Space.lg) {
            ForEach(items) { item in
                HStack(spacing: 5) {
                    if item.tone != .neutral { Circle().fill(item.tone.color(palette).color).frame(width: 6, height: 6) }
                    if let symbol = item.symbol { Image(systemName: symbol).font(.system(size: 10)) }
                    Text(item.text).font(.mono(.xxs)).lineLimit(1)
                }
                .foregroundStyle(palette.ink3.color)
            }
            Spacer(minLength: Space.md)
            ForEach(jobs.running) { job in
                Button {
                    if let page = job.page { AppModel.shared.open(page) }
                } label: {
                    HStack(spacing: 6) {
                        if let progress = job.progress {
                            ProgressView(value: progress).progressViewStyle(.linear).frame(width: 60).controlSize(.mini)
                        } else {
                            ProgressView().controlSize(.mini)
                        }
                        Text(job.detail.isEmpty ? job.title : "\(job.title): \(job.detail)")
                            .font(.ui(.xxs)).lineLimit(1).frame(maxWidth: 280, alignment: .leading)
                    }
                    .foregroundStyle(palette.ink2.color)
                }
                .buttonStyle(.plain)
                .help(job.title)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, Space.lg)
        .frame(height: 26)
        .hairline(.top)
    }
}
