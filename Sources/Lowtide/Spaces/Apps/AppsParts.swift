import AppKit
import LowtideKit
import SwiftUI

/// An app's icon from Finder, in its rounded tile.
struct AppsIcon: View {
    let path: String
    var size: CGFloat = 32
    var body: some View { FileIcon(path: path, size: size) }
}

/// `1.2 → 1.3`, in mono.
struct AppsVersionStep: View {
    @Environment(\.palette) private var palette
    let from: String
    let to: String

    var body: some View {
        HStack(spacing: 4) {
            Text(from).foregroundStyle(palette.ink3.color).lineLimit(1)
            Image(systemName: "arrow.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(palette.ink4.color)
                .accessibilityLabel("to")
            Text(to).foregroundStyle(palette.ink.color).lineLimit(1)
        }
        .font(.mono(.xxs))
        .monospacedDigit()
    }
}

/// `Firefox, Slack and Zoom`, `Firefox, Slack, Zoom and 2 more`.
func appsNames(_ names: [String]) -> String {
    let shown = Array(names.prefix(3))
    let more = names.count - shown.count
    if more > 0 { return "\(shown.joined(separator: ", ")) and \(more) more" }
    guard shown.count > 1 else { return shown.first ?? "" }
    return shown.dropLast().joined(separator: ", ") + " and " + shown.last!
}

/// `last opened 3 days ago`, `never opened`.
func appsLastOpened(_ date: Date?) -> String {
    guard let date else { return "never opened" }
    return "opened \(LowtideFormat.ago(date))"
}
