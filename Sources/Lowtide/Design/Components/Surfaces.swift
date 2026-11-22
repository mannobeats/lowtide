import SwiftUI

extension View {
    /// A group on the canvas: surface fill and a hairline ring, flat. Depth
    /// is kept for what floats (`overlaySurface`). Lists, panes and cards.
    func card(radius: CGFloat = Radius.lg, padding: CGFloat? = nil) -> some View {
        modifier(CardModifier(radius: radius, padding: padding))
    }

    /// Floating layer: popovers, menus, toasts.
    func overlaySurface(radius: CGFloat = Radius.lg) -> some View {
        modifier(OverlayModifier(radius: radius))
    }

    /// Flat over a canvas (the map's zoom, a floating dossier): the canvas
    /// colour and a hairline, no shadow, so it reads as part of the page.
    func flatSurface(radius: CGFloat = Radius.lg) -> some View {
        modifier(FlatSurfaceModifier(radius: radius))
    }

    /// A hairline under a view.
    func hairline(_ edge: Edge = .bottom) -> some View { modifier(HairlineModifier(edge: edge)) }
}

private struct CardModifier: ViewModifier {
    @Environment(\.palette) private var palette
    let radius: CGFloat
    let padding: CGFloat?
    func body(content: Content) -> some View {
        content
            .padding(padding ?? 0)
            .background(palette.surface.color, in: .rect(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(palette.line.color, lineWidth: 1))
    }
}

private struct OverlayModifier: ViewModifier {
    @Environment(\.palette) private var palette
    let radius: CGFloat
    func body(content: Content) -> some View {
        content
            .background(palette.overlay.color, in: .rect(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(palette.lineStrong.color, lineWidth: 1))
            .shadow(color: .black.opacity(palette.dark ? 0.28 : 0.08), radius: 6, y: 4)
            .shadow(color: .black.opacity(palette.dark ? 0.36 : 0.12), radius: 20, y: 16)
    }
}

private struct FlatSurfaceModifier: ViewModifier {
    @Environment(\.palette) private var palette
    let radius: CGFloat
    func body(content: Content) -> some View {
        content
            .background(palette.bg.opacity(0.92).color, in: .rect(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(palette.line.color, lineWidth: 1))
    }
}

private struct HairlineModifier: ViewModifier {
    @Environment(\.palette) private var palette
    let edge: Edge
    func body(content: Content) -> some View {
        content.overlay(alignment: edge == .top ? .top : edge == .bottom ? .bottom : edge == .leading ? .leading : .trailing) {
            if edge == .top || edge == .bottom {
                Rectangle().fill(palette.line.color).frame(height: 1)
            } else {
                Rectangle().fill(palette.line.color).frame(width: 1)
            }
        }
    }
}

/// A titled group: a pane with a heading row and its content.
struct Pane<Content: View, Accessory: View>: View {
    @Environment(\.palette) private var palette
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(_ title: String, subtitle: String? = nil,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Text(title).font(.ui(.sm, .semibold)).foregroundStyle(palette.ink.color)
                if let subtitle {
                    Text(subtitle).font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                }
                Spacer(minLength: Space.sm)
                accessory
            }
            .padding(.horizontal, Space.lg)
            .frame(minHeight: 40)
            content
        }
        .card()
    }
}

/// A thin rule between rows.
struct Hairline: View {
    @Environment(\.palette) private var palette
    var inset: CGFloat = 0
    var body: some View {
        Rectangle().fill(palette.line.color).frame(height: 1).padding(.leading, inset)
    }
}
