import AppKit
import SwiftUI

/// A compact filter field for a list.
struct FilterField: View {
    @Environment(\.palette) private var palette
    @Binding var text: String
    var prompt = "Filter"
    var width: CGFloat = 240
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(palette.ink3.color)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.ui(.sm))
                .focused($focused)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(palette.ink4.color)
                }
                .buttonStyle(.plain).help("Clear")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .frame(maxWidth: width)
        .background(palette.fill.color, in: .rect(cornerRadius: Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(focused ? palette.ring.color : palette.line.color, lineWidth: focused ? 2 : 1))
    }
}

/// An app's or a file's icon from Finder, cached.
struct FileIcon: View {
    let path: String
    var size: CGFloat = 24

    var body: some View {
        Image(nsImage: IconCache.shared.icon(for: path, size: size))
            .resizable()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

final class IconCache {
    static let shared = IconCache()
    private let cache = NSCache<NSString, NSImage>()

    func icon(for path: String) -> NSImage {
        if let hit = cache.object(forKey: path as NSString) { return hit }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(image, forKey: path as NSString)
        return image
    }

    /// The icon drawn once at `size` points (Retina pixels): a list of rows
    /// then draws small bitmaps instead of scaling Finder's 1024-pixel icon
    /// down on every frame.
    func icon(for path: String, size: CGFloat) -> NSImage {
        let key = "\(path)#\(Int(size))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let full = icon(for: path)
        let points = NSSize(width: size, height: size)
        let small = NSImage(size: points)
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size * 2), pixelsHigh: Int(size * 2), bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0) {
            rep.size = points
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current?.imageInterpolation = .high
            full.draw(in: NSRect(origin: .zero, size: points), from: .zero, operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            small.addRepresentation(rep)
        } else {
            return full
        }
        cache.setObject(small, forKey: key)
        return small
    }

    /// The icon of the app with this bundle id, when it is installed.
    func icon(bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return icon(for: url.path)
    }
}

/// A destructive or consequential choice the person confirms first.
struct ConfirmRequest: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var confirm: String
    var destructive = true
    var action: () -> Void
}

extension View {
    /// Shows a native confirmation for a pending request.
    func confirmation(_ request: Binding<ConfirmRequest?>) -> some View {
        alert(request.wrappedValue?.title ?? "", isPresented: Binding(
            get: { request.wrappedValue != nil }, set: { if !$0 { request.wrappedValue = nil } }
        ), presenting: request.wrappedValue) { item in
            Button(item.confirm, role: item.destructive ? .destructive : nil) { item.action() }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text(item.message)
        }
    }
}
