import SwiftUI

/// The window: the rail and the sidebar on the macOS sidebar material, then
/// the content as an inset rounded card, 8 pt clear of the frame on every
/// side, with the space's wash and the bottom status line. The page starts
/// at the card's top edge; that edge and the 8 pt above it drag the window.
struct MainWindow: View {
    @Bindable private var model = AppModel.shared
    private var themes = ThemeStore.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let palette = themes.palette
        let space = model.page.space
        ZStack {
            HStack(spacing: 0) {
                if !model.immersive {
                    ModeRail().transition(.move(edge: .leading).combined(with: .opacity))
                    SourceList()
                }
                ContentCard(space: space, immersive: model.immersive)
                    .padding(model.immersive ? 0 : 8)
            }
            .animation(reduceMotion ? nil : Motion.base, value: model.immersive)
            .opacity(model.onboarding ? 0 : 1)
            .allowsHitTesting(!model.onboarding)
            if model.onboarding { OnboardingLayer() }
        }
        .overlay(alignment: .top) {
            if !model.immersive { TitlebarArea().frame(height: 8) }
        }
        .background {
            ZStack {
                VisualEffectBackground().ignoresSafeArea()
                palette.panel.opacity(0.62).color.ignoresSafeArea()
            }
        }
        .ignoresSafeArea()
        .environment(\.palette, palette)
        .environment(\.spaceHue, space.hue)
        .environment(\.privacy, model.privacy)
        .tint(palette.brand.color)
        .preferredColorScheme(themes.colorScheme)
        .frame(minWidth: 980, minHeight: 620)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { note in
            if let window = note.object as? NSWindow, WindowRouter.isMain(window) { model.fullScreen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { note in
            if let window = note.object as? NSWindow, WindowRouter.isMain(window) { model.fullScreen = false }
        }
        .onAppear {
            WindowRouter.openWindow = openWindow
            WindowRouter.openSettingsAction = { openSettings() }
            // Opened from the command bar while another app stays active: in front of it, not behind.
            DispatchQueue.main.async {
                if let window = NSApp.windows.first(where: WindowRouter.isMain), window.isVisible, !NSApp.isActive { WindowRouter.raise(window) }
            }
        }
    }
}

/// The content: an opaque card on the window's material.
private struct ContentCard: View {
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var model = AppModel.shared
    let space: SpaceID
    let immersive: Bool

    init(space: SpaceID, immersive: Bool) {
        self.space = space
        self.immersive = immersive
    }

    var body: some View {
        let radius = immersive ? 0 : Radius.sheet
        VStack(spacing: 0) {
            if !immersive, space.navigation == .tabs { SpaceTabsBar(space: space) }
            ZStack {
                PageView(page: model.page)
                    .id(model.page)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 4)))
                // The terminal's tab strip is its own titlebar.
                if !immersive, space.navigation != .tabs, model.page != .sessions { TopEdge() }
                ToastHost()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            StatusBar()
        }
        .background {
            ZStack(alignment: .top) {
                palette.bg.color
                SpaceWash(hue: space.hue)
            }
        }
        .overlay { CommandPaletteOverlay() }
        .clipShape(.rect(cornerRadius: radius))
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(immersive ? .clear : palette.line.color))
        .animation(Motion.page, value: model.page)
        .animation(Motion.base, value: model.paletteOpen)
    }
}

/// The macOS sidebar material behind the rail and the source list, active
/// or inactive with the window.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.material = material }
}

/// Hides addresses, hostnames and user names on screen.
extension EnvironmentValues {
    @Entry var privacy: Bool = false
}

extension View {
    /// Blurs this view while Privacy Mode is on.
    func privacyBlur(_ on: Bool) -> some View {
        blur(radius: on ? 5 : 0).accessibilityHidden(on)
    }
}

/// A hostname, address or name, masked in Privacy Mode.
struct Sensitive: View {
    @Environment(\.privacy) private var privacy
    let text: String
    var font: Font = .mono(.xs)
    var body: some View {
        Text(privacy ? String(repeating: "•", count: min(max(text.count, 4), 14)) : text)
            .font(font)
            .textSelection(.enabled)
    }
}
