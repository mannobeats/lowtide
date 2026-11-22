import SwiftUI

/// The app's buttons. One primary per view; red only for destructive.
struct LowtideButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet, destructive }
    enum Size { case small, regular, large }

    var kind: Kind = .secondary
    var size: Size = .regular

    func makeBody(configuration: Configuration) -> some View {
        LowtideButtonBody(configuration: configuration, kind: kind, size: size)
    }

}

private struct LowtideButtonBody: View {
        typealias Kind = LowtideButtonStyle.Kind
        typealias Size = LowtideButtonStyle.Size
        @Environment(\.palette) private var palette
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        let size: Size

        var body: some View {
            configuration.label
                .font(.ui(size == .small ? .xs : .sm, kind == .quiet ? .regular : .medium))
                .lineLimit(1)
                .labelStyle(TightLabelStyle())
                .foregroundStyle(foreground)
                .padding(.horizontal, size == .small ? 8 : size == .large ? 16 : 11)
                .frame(height: size == .small ? 22 : size == .large ? 32 : 26)
                .background(background, in: .rect(cornerRadius: Radius.md))
                .overlay {
                    if kind == .secondary {
                        RoundedRectangle(cornerRadius: Radius.md).strokeBorder(palette.line.color)
                    }
                }
                .opacity(enabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(Motion.fast, value: configuration.isPressed)
                .animation(Motion.fast, value: hovering)
                .contentShape(.rect(cornerRadius: Radius.md))
                .onHover { hovering = $0 }
        }

        private var foreground: Color {
            switch kind {
            case .primary: palette.onBrand.color
            case .destructive: .white
            case .secondary: palette.ink.color
            case .quiet: hovering ? palette.ink.color : palette.ink2.color
            }
        }

        private var background: AnyShapeStyle {
            switch kind {
            case .primary:
                AnyShapeStyle((hovering ? palette.brandHover : palette.brand).color)
            case .destructive:
                AnyShapeStyle(palette.bad.opacity(hovering ? 1 : 0.92).color)
            case .secondary:
                AnyShapeStyle((hovering ? palette.selected : palette.fill).color)
            case .quiet:
                AnyShapeStyle((hovering ? palette.hover : ColorValue(r: 0, g: 0, b: 0, a: 0)).color)
            }
        }
}

struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

extension ButtonStyle where Self == LowtideButtonStyle {
    static var primary: LowtideButtonStyle { LowtideButtonStyle(kind: .primary) }
    static var secondary: LowtideButtonStyle { LowtideButtonStyle(kind: .secondary) }
    static var quiet: LowtideButtonStyle { LowtideButtonStyle(kind: .quiet) }
    static var destructive: LowtideButtonStyle { LowtideButtonStyle(kind: .destructive) }
    static func lowtide(_ kind: LowtideButtonStyle.Kind, size: LowtideButtonStyle.Size = .regular) -> LowtideButtonStyle {
        LowtideButtonStyle(kind: kind, size: size)
    }
}

/// A square, icon-only button with a tooltip (every icon-only control has one).
struct IconButton: View {
    @Environment(\.palette) private var palette
    @State private var hovering = false
    let symbol: String
    let help: String
    var active = false
    let action: () -> Void

    init(_ symbol: String, help: String, active: Bool = false, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.active = active
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? palette.brand.color : hovering ? palette.ink.color : palette.ink3.color)
                .frame(width: 26, height: 26)
                .background((active ? palette.brandSoft : hovering ? palette.hover : ColorValue(r: 0, g: 0, b: 0, a: 0)).color,
                            in: .rect(cornerRadius: Radius.md))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
        .animation(Motion.fast, value: hovering)
    }
}

/// An icon that opens a menu, drawn like IconButton: for the few actions
/// that don't each need a button of their own.
struct IconMenu<Content: View>: View {
    @Environment(\.palette) private var palette
    @State private var hovering = false
    let symbol: String
    let help: String
    @ViewBuilder let content: () -> Content

    init(_ symbol: String, help: String, @ViewBuilder content: @escaping () -> Content) {
        self.symbol = symbol
        self.help = help
        self.content = content
    }

    var body: some View {
        Menu(content: content) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering ? palette.ink.color : palette.ink3.color)
                .frame(width: 26, height: 26)
                .background(hovering ? palette.hover.color : .clear, in: .rect(cornerRadius: Radius.md))
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
        .animation(Motion.fast, value: hovering)
    }
}
