import AppKit
import LowtideKit
import Quartz
import SwiftUI

/// What every path the pages show can do from its context menu.
enum Files {
    static func reveal(_ paths: [String]) {
        NSWorkspace.shared.activateFileViewerSelecting(paths.filter(CleanupFS.exists).map { URL(fileURLWithPath: $0) })
    }

    static func open(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func quickLook(_ paths: [String]) { QuickLookPanel.shared.show(paths) }
}

/// The Quick Look panel, fed directly (Space on a row, or the menu).
final class QuickLookPanel: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookPanel()
    private var urls: [URL] = []

    func show(_ paths: [String]) {
        urls = paths.filter(CleanupFS.exists).map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        if panel.isVisible { panel.reloadData() } else { panel.makeKeyAndOrderFront(nil) }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls.indices.contains(index) ? urls[index] as NSURL : nil
    }
}

/// The context menu of a file or folder.
struct PathMenu<Extra: View>: View {
    let path: String
    var count = 1
    var onTrash: (() -> Void)?
    @ViewBuilder var extra: Extra

    init(_ path: String, count: Int = 1, onTrash: (() -> Void)? = nil, @ViewBuilder extra: () -> Extra = { EmptyView() }) {
        self.path = path
        self.count = count
        self.onTrash = onTrash
        self.extra = extra()
    }

    var body: some View {
        Button("Show in Finder") { Files.reveal([path]) }
        Button("Open") { Files.open(path) }
        Button("Quick Look") { Files.quickLook([path]) }
        extra
        Divider()
        Button("Copy Path") { Files.copy(path) }
        if let onTrash {
            Divider()
            Button(count > 1 ? "Move \(count) Items to Trash" : "Move to Trash", role: .destructive, action: onTrash)
        }
    }
}
