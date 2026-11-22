import AppKit
import LowtideKit
import ScreenCaptureKit
import SwiftUI

/// An icon's picture: what it really looks like in the menu bar (with Screen
/// Recording, kept from when it was last on screen), else a glyph for
/// macOS's own icons, else its app's icon.
struct MenuBarItemIcon: View {
    @Environment(\.palette) private var palette
    let key: String
    let appPath: String?
    var size: CGFloat = 16
    /// On the bar and the Island (always dark), not the page.
    var onDark = false
    private var pictures = MenuBarPictures.shared

    init(key: String, appPath: String?, size: CGFloat = 16, onDark: Bool = false) {
        self.key = key
        self.appPath = appPath
        self.size = size
        self.onDark = onDark
    }

    private var tint: Color { onDark ? Color.white.opacity(0.85) : palette.ink2.color }

    var body: some View {
        if let picture = pictures.image(key) {
            Image(nsImage: picture)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(tint)
                .frame(height: size)
                .frame(minWidth: size)
                .accessibilityHidden(true)
        } else if let symbol = Self.symbol(key) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.72, weight: .regular))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else if let appPath {
            FileIcon(path: appPath, size: size)
        } else {
            Image(systemName: MenuBarNames.fallbackSymbol)
                .font(.system(size: size * 0.72))
                .foregroundStyle(onDark ? Color.white.opacity(0.6) : palette.ink3.color)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }

    /// macOS's own icons by their identifier (`owner#identifier` keys).
    static func symbol(_ key: String) -> String? {
        guard key.hasPrefix(MenuBarNames.systemOwner + "#") else { return nil }
        return MenuBarNames.symbol(identifier: MenuBarNames.identifier(inKey: key), system: true)
    }
}

/// Each icon's real picture, cut out of a capture of the menu bar at the
/// frame Accessibility reports for it, while it's on screen, and kept by its
/// key (in memory and in the cache folder) for while it's hidden. Needs
/// Screen Recording; nothing else of the screen is kept.
@Observable
final class MenuBarPictures {
    static let shared = MenuBarPictures()
    /// Re-taken at most this often while on screen (a battery's level, a clock).
    static let fresh: TimeInterval = 30

    private var images: [String: NSImage] = [:]
    @ObservationIgnored private var taken: [String: Date] = [:]
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var capturing = false

    private static var folder: URL { Paths.cache.appending(path: "menubar-icons", directoryHint: .isDirectory) }

    /// A file name for a key that reads back to it (base64url): keys hold
    /// any character an app puts in its description.
    private static func file(_ key: String, template: Bool) -> URL {
        let name = Data(key.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return folder.appending(path: "\(name)\(template ? ".t" : "").png")
    }

    private static func key(_ file: URL) -> (key: String, template: Bool)? {
        var name = file.deletingPathExtension().lastPathComponent
        let template = name.hasSuffix(".t")
        if template { name.removeLast(2) }
        var base64 = name.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), let key = String(data: data, encoding: .utf8) else { return nil }
        return (key, template)
    }

    func image(_ key: String) -> NSImage? {
        if !loaded { load() }
        return images[key]
    }

    /// Pictures kept from earlier launches, for icons hidden since.
    private func load() {
        loaded = true
        guard let files = try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil) else { return }
        for url in files where url.pathExtension == "png" {
            guard let (key, template) = Self.key(url), images[key] == nil, let image = NSImage(contentsOf: url) else { continue }
            image.isTemplate = template
            images[key] = image
        }
    }

    /// Takes pictures of the items on screen now whose picture is missing or
    /// old. One capture of the menu bar, cropped per item.
    func capture(_ items: [MenuBarItem], force: Bool = false) async {
        guard !capturing, Permission.screenRecording.state == .granted else { return }
        let now = Date()
        let due = items.filter { item in
            force || images[item.key] == nil || now.timeIntervalSince(taken[item.key] ?? .distantPast) > Self.fresh
        }.filter { MenuBarPointer.onScreen(x: $0.x, width: $0.width, y: $0.centerY) }
        guard !due.isEmpty else { return }
        capturing = true
        defer { capturing = false }
        let found = await Self.take(due)
        for (key, shot) in found {
            images[key] = shot.image
            taken[key] = now
            Self.save(shot.png, key: key, template: shot.image.isTemplate)
        }
    }

    private static func save(_ png: Data?, key: String, template: Bool) {
        guard let png else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: file(key, template: !template))
        try? png.write(to: file(key, template: template), options: .atomic)
    }

    nonisolated struct Shot: @unchecked Sendable {
        // NSImage isn't Sendable; each one is made here and handed over once.
        let image: NSImage
        let png: Data?
    }

    /// Captures off the main thread: one picture of the menu bar's window
    /// (MenuBarAgent's on macOS 27, transparent around the icons), or on
    /// macOS 26 each icon's own window.
    @concurrent
    private static func take(_ items: [MenuBarItem]) async -> [String: Shot] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else {
            return [:]
        }
        var found: [String: Shot] = [:]
        let all = MenuBarPointer.windows(all: true)
        var bar: (image: CGImage, frame: CGRect)?
        var looked = false
        for item in items {
            if let window = MenuBarPointer.iconWindow(at: item.center, all),
               let shareable = content.windows.first(where: { Int($0.windowID) == window.id }) {
                let config = SCStreamConfiguration()
                config.width = Int(window.bounds.width * 2)
                config.height = Int(window.bounds.height * 2)
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true
                if let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: shareable),
                                                                            configuration: config) {
                    found[item.key] = shot(image, size: window.bounds.size)
                }
                continue
            }
            if !looked {
                looked = true
                bar = await menuBar(content)
            }
            guard let bar else { continue }
            let scale = Double(bar.image.width) / bar.frame.width
            let top = item.centerY - item.height / 2 - bar.frame.minY
            let crop = CGRect(x: (item.x - bar.frame.minX) * scale, y: top * scale, width: item.width * scale, height: item.height * scale)
            if let piece = bar.image.cropping(to: crop.integral) {
                found[item.key] = shot(piece, size: CGSize(width: item.width, height: item.height))
            }
        }
        return found
    }

    nonisolated private static func shot(_ image: CGImage, size: CGSize) -> Shot {
        let picture = NSImage(cgImage: image, size: size)
        // The menu bar draws most icons in one colour for the wallpaper under
        // it (white on a dark one): as templates they take the page's ink.
        picture.isTemplate = monochrome(image)
        let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        return Shot(image: picture, png: png)
    }

    /// Nearly every visible pixel is grey: a template, not a coloured icon.
    nonisolated static func monochrome(_ image: CGImage) -> Bool {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return true }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return true }
        var seen = 0, coloured = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[index + 3])
            guard alpha > 50 else { continue }
            seen += 1
            let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
            if (max(r, g, b) - min(r, g, b)) * 255 / alpha > 40 { coloured += 1 }
        }
        return seen == 0 || coloured * 10 < seen
    }

    /// The menu bar agent's strip at the top of the main screen.
    nonisolated private static func menuBar(_ content: SCShareableContent) async -> (image: CGImage, frame: CGRect)? {
        guard let window = content.windows.first(where: {
            $0.owningApplication?.bundleIdentifier == "com.apple.MenuBarAgent" && $0.frame.minY < 1 && $0.frame.height <= 50
                && $0.frame.minX <= 0
        }) else { return nil }
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * 2)
        config.height = Int(window.frame.height * 2)
        config.showsCursor = false
        let filter = SCContentFilter(desktopIndependentWindow: window)
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
        return (image, window.frame)
    }
}
