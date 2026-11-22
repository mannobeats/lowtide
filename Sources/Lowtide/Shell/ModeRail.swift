import SwiftUI

/// The rail: the logo and search (⌘K), then each space as its glyph over
/// its name (the name is what tells them apart at a glance), and privacy
/// mode and Settings at the bottom. The
/// current space's glyph sits in a flat filled pill and turns solid in the
/// brand colour.
struct ModeRail: View {
    @Environment(\.palette) private var palette
    private var model = AppModel.shared
    @State private var shown = SpaceID.allCases.filter { SpaceState.isOn($0) }

    var body: some View {
        VStack(spacing: 0) {
            TitlebarArea().frame(height: 48)
            Logo(size: 28).padding(.bottom, 10)
            RailIcon(glyph: "search", on: false, help: "Search pages and actions (⌘K)") { model.paletteOpen = true }
                .padding(.bottom, 10)
            VStack(spacing: 4) {
                ForEach(Array(shown.enumerated()), id: \.element) { index, space in
                    let current = model.page.space == space
                    RailButton(glyph: space.glyph, label: space.title, active: current,
                               help: "\(space.title) (⌘\(index + 1))") {
                        // The current space again brings back a hidden sidebar.
                        if current, model.hasSidebar, model.sidebarHidden { model.toggleSidebar() } else { model.open(space) }
                    }
                }
            }
            TitlebarArea(doubleClick: .none).frame(maxHeight: .infinity)
            RailIcon(glyph: "privacy", on: model.privacy,
                     help: model.privacy ? "Privacy mode is on: addresses, names and paths are hidden (⇧⌘P)"
                                         : "Privacy mode: hide addresses, names and paths for demos (⇧⌘P)") {
                model.privacy.toggle()
            }
            .padding(.bottom, 6)
            RailButton(glyph: "settings", label: "Settings", active: false, help: "Settings (⌘,)") {
                WindowRouter.showSettings()
            }
            .padding(.bottom, 12)
        }
        .frame(width: 72)
        .onReceive(NotificationCenter.default.publisher(for: SpaceState.changed)) { _ in
            withAnimation(Motion.base) { shown = SpaceID.allCases.filter { SpaceState.isOn($0) } }
        }
    }
}

private struct RailButton: View {
    @Environment(\.palette) private var palette
    @State private var hovering = false
    let glyph: String
    let label: String
    let active: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                NavIcon(glyph, filled: active, size: 20)
                    .foregroundStyle((active ? palette.brand : hovering ? palette.ink : palette.ink3).color)
                    .frame(width: 44, height: 28)
                    .background {
                        if active || hovering {
                            RoundedRectangle(cornerRadius: Radius.md)
                                .fill((active ? palette.selected : palette.hover).color)
                        }
                    }
                Text(label)
                    .font(.ui(.xxs, active ? .medium : .regular))
                    .foregroundStyle((active || hovering ? palette.ink : palette.ink3).color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 68)
            .padding(.vertical, 2)
            .contentShape(.rect)
        }
        .buttonStyle(RailPress())
        .help(help)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
        .onHover { hovering = $0 }
        .animation(Motion.fast, value: hovering)
        .animation(Motion.fast, value: active)
    }
}

/// A rail tool without a label: search, privacy mode. Lit in the brand
/// colour while it is on.
private struct RailIcon: View {
    @Environment(\.palette) private var palette
    @State private var hovering = false
    let glyph: String
    let on: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            NavIcon(glyph, filled: on, size: 18)
                .foregroundStyle((on ? palette.brand : hovering ? palette.ink : palette.ink3).color)
                .frame(width: 44, height: 28)
                .background((on ? palette.brandSoft : hovering ? palette.hover : ColorValue(r: 0, g: 0, b: 0, a: 0)).color,
                            in: .rect(cornerRadius: Radius.md))
                .contentShape(.rect)
        }
        .buttonStyle(RailPress())
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(on ? .isSelected : [])
        .onHover { hovering = $0 }
        .animation(Motion.fast, value: hovering)
        .animation(Motion.fast, value: on)
    }
}

private struct RailPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.96 : 1).animation(Motion.fast, value: configuration.isPressed)
    }
}
