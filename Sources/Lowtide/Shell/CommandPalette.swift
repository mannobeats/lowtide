import SwiftUI

/// ⌘K inside the main window: the command bar over a dimmed canvas.
struct CommandPaletteOverlay: View {
    @Environment(\.palette) private var palette
    @Bindable var model = AppModel.shared

    var body: some View {
        if model.paletteOpen {
            ZStack(alignment: .top) {
                palette.scrim.opacity(0.5).color.ignoresSafeArea()
                    .onTapGesture { model.paletteOpen = false }
                CommandBarView { model.paletteOpen = false }
                    .frame(width: 680, height: 440)
                    .overlaySurface(radius: Radius.xl)
                    .padding(.top, 70)
                    .transition(.scale(scale: 0.97, anchor: .top).combined(with: .opacity))
            }
            .transition(.opacity)
        }
    }
}
