import LowtideKit
import SwiftUI

/// Everything known about one package: what it is, the versions, links,
/// where it's installed, dependencies, notes; Update and Uninstall at the
/// bottom. Lives in the window's inspector.
struct PackageDetailsPanel: View {
    @Environment(\.palette) private var palette
    private var queue = ToolUpdateQueue.shared
    let item: InventoryItem
    let onUpdate: () -> Void
    let onUninstall: () -> Void
    let onClose: () -> Void
    @State private var details: PackageDetails?
    @State private var error: String?
    @State private var loading = false

    init(item: InventoryItem, onUpdate: @escaping () -> Void, onUninstall: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.item = item
        self.onUpdate = onUpdate
        self.onUninstall = onUninstall
        self.onClose = onClose
    }

    private var package: ToolPackage { item.package }
    private var source: PackageSourceInfo? { ToolchainModel.shared.info(item.sourceID) }
    private var job: ToolUpdateQueue.Job? { queue.job(item.sourceID, package.id) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Package details").font(.ui(.sm, .semibold)).foregroundStyle(palette.ink.color)
                Spacer()
                IconButton("xmark", help: "Close details", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.leading, Space.lg).padding(.trailing, Space.sm)
            .frame(height: 44)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if loading && details == nil { skeleton }
                    if let error { failure(error) }
                    if let details { content(details) }
                }
                .padding(.bottom, Space.lg)
            }
            Hairline()
            footer
        }
        .background(palette.overlay.color)
        .task(id: item.id) { await load() }
    }

    private func load() async {
        if let cached = Self.cache[item.id], Date().timeIntervalSince(cached.at) < 300 {
            details = cached.details
            return
        }
        details = nil
        error = nil
        loading = true
        defer { loading = false }
        guard let source = PackageSources.source(item.sourceID) else { return }
        do {
            let found = try await source.details(package.id)
            Self.cache[item.id] = (found, .now)
            details = found
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private static var cache: [String: (details: PackageDetails, at: Date)] = [:]

    // MARK: Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.md) {
                SourceTile(mark: item.mark, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Space.sm) {
                        Text(package.name).font(.ui(.lg, .semibold)).foregroundStyle(palette.ink.color).lineLimit(1)
                            .textSelection(.enabled)
                        if let type = details?.packageType { Badge(type) }
                    }
                    Text(item.ownerName).font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                }
            }
            if let text = details?.description ?? package.description, !text.isEmpty {
                Text(text).font(.ui(.sm)).foregroundStyle(palette.ink2.color).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            versions
        }
        .padding(Space.lg)
    }

    private var versions: some View {
        let latest = package.checked ? (package.latestVersion ?? package.currentVersion) : "Unknown"
        return HStack(spacing: Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Installed").font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                Text(package.currentVersion.isEmpty ? "Unknown" : package.currentVersion)
                    .font(.mono(.sm)).foregroundStyle(palette.ink.color).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled).help(package.currentVersion)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right").font(.system(size: 12, weight: .medium))
                .foregroundStyle((package.outdated ? palette.warn : palette.ink4).color)
            VStack(alignment: .leading, spacing: 2) {
                Text(package.outdated ? "Available" : "Latest").font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                Text(latest).font(.mono(.sm)).foregroundStyle((package.outdated ? palette.warn : palette.ink2).color)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(latest)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, 10)
        .background(palette.fill.color, in: .rect(cornerRadius: Radius.md))
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            ForEach([72.0, 96, 140], id: \.self) { height in
                RoundedRectangle(cornerRadius: Radius.md).fill(palette.fill.color).frame(height: height)
            }
        }
        .padding(.horizontal, Space.lg)
        .phaseAnimator([0.5, 1]) { view, phase in view.opacity(phase) } animation: { _ in .easeInOut(duration: 0.8) }
        .accessibilityLabel("Loading details")
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Couldn't load package details").font(.ui(.sm, .medium)).foregroundStyle(palette.bad.color)
            Text(message).font(.ui(.xs)).foregroundStyle(palette.ink2.color).textSelection(.enabled)
            Button("Try Again") { Task { await load() } }.buttonStyle(.lowtide(.secondary, size: .small))
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.badSoft.color, in: .rect(cornerRadius: Radius.md))
        .padding(.horizontal, Space.lg)
    }

    @ViewBuilder
    private func content(_ details: PackageDetails) -> some View {
        let links = [
            ("globe", "Website", details.homepage), ("shippingbox", "\(item.ownerName) page", details.packageURL),
            ("chevron.left.forwardslash.chevron.right", "Source code", details.repository),
            ("book", "Documentation", details.documentation),
        ].compactMap { symbol, label, value in value.flatMap(Self.webURL).map { (symbol, label, $0) } }
        if !links.isEmpty {
            section("Links") {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.xs), GridItem(.flexible())], spacing: 0) {
                    ForEach(links, id: \.1) { symbol, label, url in DetailLink(symbol: symbol, label: label, url: url) }
                }
                .padding(.horizontal, -Space.sm)
            }
        }
        if details.latestReleaseDate != nil || details.releaseNotes != nil {
            section("Latest release", meta: details.latestReleaseDate.map(Self.releaseDate)) {
                if let notes = details.releaseNotes {
                    ScrollView {
                        Text(notes).font(.ui(.xs)).foregroundStyle(palette.ink2.color).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(Space.md)
                    }
                    .frame(maxHeight: 200)
                    .background(palette.fill.color, in: .rect(cornerRadius: Radius.sm))
                }
            }
        }
        section("Installation") {
            VStack(spacing: 0) {
                fact("Managed by", item.ownerName)
                fact("Package ID", package.id, mono: true)
                if let license = details.license { fact("License", license) }
                if !details.availableVersions.isEmpty {
                    fact("Releases", details.availableVersions.joined(separator: ", "), mono: true)
                }
                if let path = details.installPath {
                    HStack(spacing: Space.md) {
                        Text("Installed at").font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                        Spacer(minLength: Space.md)
                        Text(Paths.tilde(path)).font(.mono(.xs)).foregroundStyle(palette.ink.color).lineLimit(1)
                            .truncationMode(.middle).help(path).textSelection(.enabled)
                        IconButton("doc.on.doc", help: "Copy the installation path") { ToolClipboard.copy(path, what: "Path") }
                        IconButton("folder", help: "Show in Finder") {
                            Files.reveal([path])
                        }
                    }
                    .frame(minHeight: 28)
                }
            }
        }
        if !details.dependencies.isEmpty {
            section("Dependencies", meta: details.dependencies.count.formatted()) {
                FlowLayout(spacing: 6) {
                    ForEach(details.dependencies, id: \.self) { dependency in
                        Text(dependency).font(.mono(.xxs)).foregroundStyle(palette.ink2.color)
                            .padding(.horizontal, 7).frame(height: 20)
                            .background(palette.fill.color, in: .rect(cornerRadius: Radius.sm))
                    }
                }
            }
        }
        if let caveats = details.caveats {
            section("Notes") {
                ScrollView {
                    Text(caveats).font(.mono(.xxs)).foregroundStyle(palette.ink2.color).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(Space.md)
                }
                .frame(maxHeight: 180)
                .background(palette.fill.color, in: .rect(cornerRadius: Radius.sm))
            }
        }
        if details.license == nil, links.isEmpty, details.dependencies.isEmpty {
            Text("\(item.ownerName) doesn't publish more about this package.")
                .font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                .padding(.horizontal, Space.lg).padding(.top, Space.md)
        }
    }

    private func section<Content: View>(_ title: String, meta: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Hairline().padding(.horizontal, -Space.lg)
            HStack {
                Text(title).font(.ui(.xs, .semibold)).foregroundStyle(palette.ink2.color)
                Spacer()
                if let meta { Text(meta).font(.ui(.xs)).foregroundStyle(palette.ink3.color) }
            }
            .padding(.top, Space.sm)
            content()
        }
        .padding(.horizontal, Space.lg)
        .padding(.bottom, Space.sm)
    }

    private func fact(_ key: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            Text(key).font(.ui(.xs)).foregroundStyle(palette.ink3.color)
            Spacer(minLength: Space.md)
            Text(value).font(mono ? .mono(.xs) : .ui(.xs)).foregroundStyle(palette.ink.color)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(value)
        }
        .frame(minHeight: 26)
    }

    private var footer: some View {
        HStack(spacing: Space.sm) {
            if item.ownerID == "homebrew-apps" {
                Text("Mac apps are updated and removed in Apps").font(.ui(.xs)).foregroundStyle(palette.ink3.color).lineLimit(2)
                Spacer()
                Button("Open Apps") { AppModel.shared.open(package.needsUpdate ? .appsUpdates : .appsInstalled) }
                    .buttonStyle(.secondary)
            } else {
                if let refusal = PackageSources.source(item.sourceID)?.removalRefusal {
                    Text(refusal).font(.ui(.xs)).foregroundStyle(palette.ink3.color).lineLimit(2)
                } else {
                    Button(role: .destructive, action: onUninstall) {
                        Label(job?.action == .uninstall && job?.status.active == true ? "Uninstalling…" : "Uninstall", systemImage: "trash")
                    }
                    .buttonStyle(.quiet)
                    .disabled(job?.status.active == true)
                }
                Spacer()
                if package.canUpdate {
                    Button(action: onUpdate) {
                        Label(updateLabel, systemImage: "arrow.up")
                    }
                    .buttonStyle(.primary)
                    .disabled(job?.status.active == true)
                    .help(package.latestVersion.map { "Update to \($0)" } ?? "Update to the latest version")
                }
            }
        }
        .padding(.horizontal, Space.lg)
        .frame(height: 52)
        .background(palette.panel.color)
    }

    private var updateLabel: String {
        guard let job, job.action == .update else { return "Update" }
        return job.status == .running ? "Updating…" : job.status == .queued ? "Queued" : "Update"
    }

    static func webURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)), ["http", "https"].contains(url.scheme ?? "") else { return nil }
        return url
    }

    static func releaseDate(_ text: String) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = iso.date(from: text) ?? {
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: text)
        }()
        return date?.formatted(date: .abbreviated, time: .shortened) ?? text
    }
}

private struct DetailLink: View {
    @Environment(\.palette) private var palette
    @State private var hovering = false
    let symbol: String
    let label: String
    let url: URL

    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(palette.ink3.color).frame(width: 16)
                Text(label).font(.ui(.sm)).foregroundStyle((hovering ? palette.ink : palette.ink2).color).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(palette.ink4.color).opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, Space.sm)
            .frame(height: 34)
            .background((hovering ? palette.hover : ColorValue(r: 0, g: 0, b: 0, a: 0)).color, in: .rect(cornerRadius: Radius.sm))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(url.absoluteString)
        .contextMenu { Button("Copy Link") { ToolClipboard.copy(url.absoluteString, what: "Link") } }
    }
}
