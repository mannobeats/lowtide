import LowtideKit
import SwiftUI

/// Short confirmations and failures at the bottom of the window. A failure
/// stays until dismissed; anything else goes after 4 s. An action (Undo,
/// Show in Finder) rides along.
@Observable
final class Toasts {
    static let shared = Toasts()

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var detail: String?
        var tone: Tone
        var actionTitle: String?
        var action: (() -> Void)?
        static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
    }

    private(set) var items: [Toast] = []

    func show(_ title: String, detail: String? = nil, tone: Tone = .ok, action: String? = nil, perform: (() -> Void)? = nil) {
        let toast = Toast(title: title, detail: detail, tone: tone, actionTitle: action, action: perform)
        withAnimation(Motion.spring) {
            items.append(toast)
            if items.count > 3 { items.removeFirst() }
        }
        guard tone != .bad else { return }
        // Long enough to reach for Undo.
        let seconds: Double = perform == nil ? 4 : 8
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            self.dismiss(toast.id)
        }
    }

    func failure(_ title: String, _ error: Error) {
        show(title, detail: error.localizedDescription, tone: .bad)
    }

    /// Undo for a move to the Trash: puts `moved` back (one password prompt
    /// for what belonged to the system), says how it went, then `then`.
    func putBack(_ moved: [Trash.Moved], then: @escaping () -> Void = {}) {
        Task {
            let back = await Trash.putBack(moved)
            if back.failed.isEmpty {
                show("Put back \(LowtideFormat.count(back.restored, "item"))")
            } else {
                show("Put back \(back.restored), \(back.failed.count) stayed in the Trash",
                     detail: back.failed.first.map { "\(Paths.tilde($0.path)): \($0.reason)" }, tone: .warn)
            }
            then()
        }
    }

    func dismiss(_ id: UUID) {
        withAnimation(Motion.base) { items.removeAll { $0.id == id } }
    }
}

struct ToastHost: View {
    @Environment(\.palette) private var palette
    var toasts = Toasts.shared

    var body: some View {
        VStack(spacing: Space.sm) {
            ForEach(toasts.items) { toast in
                HStack(spacing: Space.md) {
                    Image(systemName: toast.tone == .bad ? "exclamationmark.circle.fill" : toast.tone == .warn ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(toast.tone.color(palette).color)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(toast.title).font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color)
                        if let detail = toast.detail {
                            Text(detail).font(.ui(.xs)).foregroundStyle(palette.ink3.color).lineLimit(3)
                        }
                    }
                    Spacer(minLength: Space.md)
                    if let title = toast.actionTitle, let action = toast.action {
                        Button(title) { action(); toasts.dismiss(toast.id) }.buttonStyle(.lowtide(.secondary, size: .small))
                    }
                    IconButton("xmark", help: "Dismiss") { toasts.dismiss(toast.id) }
                }
                .padding(.leading, Space.md).padding(.trailing, Space.xs).padding(.vertical, Space.xs)
                .frame(width: 400)
                .overlaySurface()
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}
