import AppKit
import LowtideKit
import SwiftUI

/// A sheet's frame: title, one line of description, the form, and the
/// footer with Cancel and the one action.
struct DevSheet<Content: View, Footer: View>: View {
    @Environment(\.palette) private var palette
    let title: String
    var description: String?
    var width: CGFloat = 460
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    init(_ title: String, description: String? = nil, width: CGFloat = 460,
         @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.description = description
        self.width = width
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.ui(.lg, .semibold)).foregroundStyle(palette.ink.color)
                if let description {
                    Text(description).font(.ui(.sm)).foregroundStyle(palette.ink3.color).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Space.xl)
            .padding(.top, Space.xl)
            .padding(.bottom, Space.lg)
            ScrollView {
                VStack(alignment: .leading, spacing: Space.md) { content }
                    .padding(.horizontal, Space.xl)
                    .padding(.bottom, Space.lg)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 560)
            .fixedSize(horizontal: false, vertical: true)
            Hairline()
            HStack(spacing: Space.sm) {
                Spacer()
                footer
            }
            .padding(.horizontal, Space.xl)
            .padding(.vertical, Space.md)
        }
        .frame(width: width)
        .background(palette.overlay.color)
    }
}

/// A labelled control with an optional hint under it.
struct DevField<Control: View>: View {
    @Environment(\.palette) private var palette
    let label: String
    var hint: String?
    @ViewBuilder var control: Control

    init(_ label: String, hint: String? = nil, @ViewBuilder control: () -> Control) {
        self.label = label
        self.hint = hint
        self.control = control()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.ui(.xs, .medium)).foregroundStyle(palette.ink2.color)
            control
            if let hint {
                Text(hint).font(.ui(.xs)).foregroundStyle(palette.ink3.color).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Presents a SwiftUI sheet on the main window from anywhere (menus, the
/// the rail, ⌘K), with the app's palette.
enum DevSheetHost {
    @MainActor private static var controller: NSViewController?

    static func present<Content: View>(_ content: @escaping (_ close: @escaping () -> Void) -> Content) {
        WindowRouter.showMain()
        Task { @MainActor in
            // The main window may be opening.
            for _ in 0..<20 {
                if mainWindow != nil { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let window = mainWindow, window.attachedSheet == nil, controller == nil else { return }
            let close = {
                guard let sheet = controller?.view.window else { return }
                window.endSheet(sheet)
                controller = nil
                SessionStore.shared.focusSoon()
            }
            let themes = ThemeStore.shared
            let root = content(close)
                .environment(\.palette, themes.palette)
                .environment(\.privacy, AppModel.shared.privacy)
                .tint(themes.palette.brand.color)
                .preferredColorScheme(themes.colorScheme)
            let hosting = NSHostingController(rootView: root)
            hosting.sizingOptions = .preferredContentSize
            controller = hosting
            let sheet = NSWindow(contentViewController: hosting)
            window.beginSheet(sheet) { _ in controller = nil }
        }
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == "main" || $0.title == "Lowtide" }
    }
}

extension View {
    /// A text field in the sheets' style.
    func devField() -> some View {
        textFieldStyle(.roundedBorder).controlSize(.large).font(.ui(.sm))
    }
}

/// A row's glyph on a quiet tile; brand when live.
struct DevGlyphTile: View {
    @Environment(\.palette) private var palette
    let glyph: String
    var live = false

    init(_ glyph: String, live: Bool = false) {
        self.glyph = glyph
        self.live = live
    }

    var body: some View {
        NavIcon(glyph, filled: live, size: 16)
            .foregroundStyle((live ? palette.brand : palette.ink2).color)
            .frame(width: 32, height: 32)
            .background((live ? palette.brandSoft : palette.fill).color, in: .rect(cornerRadius: Radius.md))
    }
}
