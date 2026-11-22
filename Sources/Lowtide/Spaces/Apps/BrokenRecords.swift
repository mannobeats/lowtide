import LowtideKit
import SwiftUI

/// Homebrew records whose app bundle is gone. They aren't in Applications,
/// so they're listed from the catalog; one opens its sheet to repair
/// (reinstall) or remove the record.
struct BrokenRecordsList: View {
    @Environment(\.palette) private var palette
    private var model = InstalledAppsModel.shared
    @State private var open: Cask?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.records.broken, id: \.token) { cask in
                    SplitRow(checked: nil, selected: open?.token == cask.token, onSelect: { open = cask }) {
                        CaskTile(size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(cask.name).font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color).lineLimit(1)
                            Text("Missing from Applications").font(.ui(.xxs)).foregroundStyle(palette.bad.color)
                        }
                        Spacer(minLength: Space.xs)
                        Text(model.brewPending[cask.token]?.progress ?? cask.token).font(.mono(.xxs)).foregroundStyle(palette.ink3.color).lineLimit(1)
                    }
                    .contextMenu {
                        Button("Repair") { model.brew(.repair, cask) }.disabled(model.brewBusy)
                        Button("Remove the Record…") { open = cask }
                    }
                }
            }
            .padding(.vertical, Space.xs)
        }
        .overlay {
            if model.records.broken.isEmpty {
                EmptyState("No broken records", symbol: "checkmark.circle", message: "Every app Homebrew installed is still in Applications.")
            }
        }
        .sheet(item: Binding(get: { open.map(Identified.init) }, set: { open = $0?.cask })) { item in
            CaskSheet(cask: item.cask) { open = nil }
        }
    }

    struct Identified: Identifiable {
        var cask: Cask
        var id: String { cask.token }
    }
}

/// A cask's tile where there is no app to take an icon from.
private struct CaskTile: View {
    @Environment(\.palette) private var palette
    var size: CGFloat
    var body: some View {
        Image(systemName: "shippingbox")
            .font(.system(size: size * 0.45))
            .foregroundStyle(palette.ink3.color)
            .frame(width: size, height: size)
            .background(palette.fill.color, in: .rect(cornerRadius: size * 0.22))
            .overlay(RoundedRectangle(cornerRadius: size * 0.22).strokeBorder(palette.line.color))
    }
}

/// One Homebrew record: what Homebrew knows, Repair (reinstall) and
/// Remove app only (Homebrew forgets it).
private struct CaskSheet: View {
    @Environment(\.palette) private var palette
    private var model = InstalledAppsModel.shared
    let cask: Cask
    let close: () -> Void
    @State private var confirm: ConfirmRequest?

    init(cask: Cask, close: @escaping () -> Void) {
        self.cask = cask
        self.close = close
    }

    var body: some View {
        let pending = model.brewPending[cask.token]
        let locked = model.brewBusy || !model.records.homebrew
        VStack(alignment: .leading, spacing: Space.xl) {
            HStack(alignment: .top, spacing: Space.lg) {
                CaskTile(size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(cask.name).font(.title(.lg)).foregroundStyle(palette.ink.color)
                    if let desc = cask.desc { Text(desc).font(.ui(.sm)).foregroundStyle(palette.ink2.color).fixedSize(horizontal: false, vertical: true) }
                    HStack(spacing: Space.sm) {
                        Badge("Needs repair", tone: .warn)
                        Text(cask.token).font(.mono(.xxs)).foregroundStyle(palette.ink3.color).textSelection(.enabled)
                    }
                    .padding(.top, 2)
                }
            }
            VStack(spacing: 0) {
                KeyValueRow("Version", cask.version, mono: true)
                Hairline()
                KeyValueRow("Updates", cask.autoUpdates ? "Managed by the app" : "Managed by Homebrew")
                Hairline()
                KeyValueRow("Installs", cask.appNames.joined(separator: ", "))
            }
            .card()
            HStack(spacing: Space.sm) {
                if let url = URL(string: cask.homepage), url.scheme == "https" || url.scheme == "http" {
                    Button { NSWorkspace.shared.open(url) } label: { Label("Website", systemImage: "arrow.up.right.square") }
                        .buttonStyle(.lowtide(.secondary, size: .small))
                }
                Button {
                    Files.copy("brew install --cask \(cask.token)")
                    Toasts.shared.show("Copied the install command")
                } label: { Label("Copy install command", systemImage: "doc.on.doc") }
                    .buttonStyle(.lowtide(.secondary, size: .small))
            }
            HStack(spacing: Space.sm) {
                Button(pending == .uninstall ? Brew.Action.uninstall.progress : "Remove app only", role: .destructive) {
                    confirm = ConfirmRequest(
                        title: "Remove \(cask.name) only?",
                        message: "Homebrew forgets \(cask.name). Its settings, caches and support files stay; Leftovers in Cleanup finds those.",
                        confirm: "Remove the record"
                    ) { model.brew(.uninstall, cask) }
                }
                .buttonStyle(.destructive)
                .disabled(locked)
                Spacer()
                Button("Close", action: close).buttonStyle(.quiet).keyboardShortcut(.cancelAction)
                Button(pending == .repair ? Brew.Action.repair.progress : "Repair & reinstall") { model.brew(.repair, cask) }
                    .buttonStyle(.primary)
                    .disabled(locked)
                    .keyboardShortcut(.defaultAction)
            }
            if !model.records.homebrew {
                Text("Install Homebrew to manage this app.").font(.ui(.xs)).foregroundStyle(palette.warn.color)
            }
        }
        .padding(Space.page)
        .frame(width: 460)
        .background(palette.overlay.color)
        .confirmation($confirm)
    }
}
