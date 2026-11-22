import LowtideKit
import SwiftUI

/// Every extension, like a store shelf: install one, or open its page.
/// Installed extensions keep their settings when turned off.
struct ExtensionsGalleryPage: View {
    private var states = ExtensionStates.shared
    @State private var enabler = ExtensionEnabler()

    var body: some View {
        let count = ExtensionEntry.catalog.filter { states.isOn($0.id) }.count
        PageScaffold {
            PageHero(count == 0 ? "Add what you need to your Mac" : "\(count) of \(ExtensionEntry.catalog.count) extensions installed",
                     detail: "Each one runs on this Mac and asks only for what it needs. Installed extensions join the sidebar.",
                     art: "extensions")
        } content: {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: Space.md)], spacing: Space.md) {
                ForEach(Array(ExtensionEntry.catalog.enumerated()), id: \.element.id) { index, entry in
                    ExtensionCard(entry: entry, index: index, installed: states.isOn(entry.id)) { enabler.enable(entry.feature) }
                }
            }
        }
        .sheet(item: $enabler.asking) { _ in EnableSheet(enabler: enabler) }
    }
}

private struct ExtensionCard: View {
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let entry: ExtensionEntry
    let index: Int
    let installed: Bool
    let install: () -> Void
    @State private var hovering = false
    @State private var shown = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Button(action: open) {
                HStack(alignment: .top, spacing: Space.lg) {
                    HeroArt(entry.art, size: 64)
                        .scaleEffect(hovering && !reduceMotion ? 1.04 : 1)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.feature.label).font(.ui(.base, .semibold)).foregroundStyle(palette.ink.color)
                        Text(entry.tagline).font(.ui(.sm)).foregroundStyle(palette.ink2.color)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(entry.facts.joined(separator: " · ")).font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                            .padding(.top, Space.xs)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, Space.xs)
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            HStack(spacing: Space.sm) {
                if installed {
                    Label("Installed", systemImage: "checkmark").font(.ui(.xs)).foregroundStyle(palette.ok.color)
                    Spacer()
                    Button("Open", action: open).buttonStyle(.lowtide(.secondary, size: .small))
                } else {
                    Spacer()
                    Button("Install", action: install).buttonStyle(.lowtide(.primary, size: .small))
                }
            }
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
        .background((hovering ? palette.hover : ColorValue(r: 0, g: 0, b: 0, a: 0)).color, in: .rect(cornerRadius: Radius.xl))
        .card(radius: Radius.xl)
        .onHover { hovering = $0 }
        .animation(Motion.base, value: hovering)
        .contextMenu {
            Button("Open") { open() }
            if installed {
                Button("Turn Off") { entry.feature.set(false) }
            } else {
                Button("Install") { install() }
            }
        }
        .opacity(shown ? 1 : 0)
        .offset(y: shown || reduceMotion ? 0 : 8)
        .onAppear {
            withAnimation(Motion.slow.delay(Double(index) * 0.04)) { shown = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(entry.feature.label), \(installed ? "installed" : "not installed")")
    }

    private func open() { AppModel.shared.open(entry.page) }
}
