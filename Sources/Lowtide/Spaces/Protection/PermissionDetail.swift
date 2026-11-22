import LowtideKit
import SwiftUI

/// One app's panel on the permission map: its grants, what it starts with
/// the Mac, and last week's traffic when the network monitor knows it.
struct PermissionDetail: View {
    @Environment(\.palette) private var palette
    @Environment(\.privacy) private var privacy
    let app: MapApp
    @Binding var confirm: ConfirmRequest?
    let onClose: () -> Void

    var body: some View {
        let revocable = app.grants.filter(\.revocable).count
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                HStack(alignment: .top, spacing: Space.md) {
                    if let path = app.path { FileIcon(path: path, size: 40) } else { GlyphTile(glyph: "apps", quiet: true) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name).font(.title(.lg)).foregroundStyle(palette.ink.color).lineLimit(2)
                        Text(app.developer ?? app.bundleID ?? "Unknown developer").font(.ui(.xs))
                            .foregroundStyle(palette.ink3.color).lineLimit(1).textSelection(.enabled)
                        if app.broken, app.installed {
                            Text("Something it starts at login is no longer on disk.").font(.ui(.xs)).foregroundStyle(palette.bad.color)
                                .padding(.top, Space.xs)
                        }
                        if !app.installed, revocable == 0 {
                            Text("This app isn't on the Mac any more. Only System Settings can clear what it left.")
                                .font(.ui(.xs)).foregroundStyle(palette.ink3.color).padding(.top, Space.xs)
                        }
                        if let path = app.path {
                            Text(privacy ? "•••" : path).font(.mono(.xxs)).foregroundStyle(palette.ink4.color)
                                .lineLimit(1).truncationMode(.middle).help(path).textSelection(.enabled).padding(.top, 2)
                        }
                    }
                    Spacer(minLength: 0)
                    IconButton("xmark", help: "Close", action: onClose)
                }
                if !app.installed, revocable > 0 {
                    HStack(spacing: Space.md) {
                        Text("macOS keeps a deleted app's permissions. They can't be used, but you can clear them.")
                            .font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                        Button("Remove All") {
                            confirm = ConfirmRequest(
                                title: "Remove all permissions?",
                                message: "Clears the \(revocable) permissions macOS keeps for \(app.name). If you install it again, it will have to ask again.",
                                confirm: "Remove Permissions") { changePermissionMap("Couldn't remove permissions") {
                                    try await PermissionActions.shared.revoke(key: app.key, service: "All")
                                } }
                        }
                        .buttonStyle(.lowtide(.secondary, size: .small))
                    }
                }
                section("Permissions", count: app.grants.count) {
                    if app.grants.isEmpty {
                        Text("No privacy permissions granted.").font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                    } else {
                        ForEach(app.grants, id: \.self) { grant in GrantRow(app: app, grant: grant, confirm: $confirm) }
                    }
                }
                section("Starts with the Mac", count: app.background.count) {
                    if app.background.isEmpty {
                        Text("Nothing starts at login.").font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                    } else {
                        ForEach(app.background) { item in StartupRow(item: item, confirm: $confirm) }
                    }
                }
                if ProtectionHooks.traffic != nil {
                    section("Network", meta: "Last 7 days") { TrafficFacts(traffic: app.traffic) }
                }
            }
            .padding(Space.lg)
            .padding(.top, Space.xs)
        }
        .background(palette.bg.color)
    }

    private func section<Content: View>(_ title: String, count: Int? = nil, meta: String? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            GroupHeading(title, trailing: meta ?? count.map(String.init))
            content()
        }
    }
}

/// Runs one change to the map behind a toast on failure, then rescans.
@MainActor
func changePermissionMap(_ failure: String, _ work: @escaping () async throws -> Void) {
    Task {
        do { try await work() } catch { Toasts.shared.failure(failure, error) }
        await ProtectionModel.shared.loadPermissions(force: true)
    }
}

private struct GrantRow: View {
    @Environment(\.palette) private var palette
    let app: MapApp
    let grant: PermissionMap.Grant
    @Binding var confirm: ConfirmRequest?

    var body: some View {
        HStack(spacing: Space.md) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(Text(grant.label).foregroundStyle((PermissionMap.powerful.contains(grant.group) ? palette.ink : palette.ink2).color))\(Text((grant.target.map { " · controls \($0)" } ?? "") + (grant.limited ? " · limited" : "")).foregroundStyle(palette.ink3.color))")
                    .font(.ui(.sm)).lineLimit(1)
                if let modified = grant.modified {
                    Text("Since \(modified.formatted(date: .abbreviated, time: .omitted))").font(.ui(.xs))
                        .foregroundStyle(palette.ink3.color)
                }
            }
            Spacer(minLength: Space.sm)
            if grant.revocable {
                Button("Remove…") {
                    confirm = ConfirmRequest(
                        title: "Remove \(grant.label)?",
                        message: "\(app.name) loses \(grant.label) and has to ask again the next time it needs it.",
                        confirm: "Remove") { changePermissionMap("Couldn't remove \(grant.label)") {
                            try await PermissionActions.shared.revoke(key: app.key, service: grant.service)
                        } }
                }
                .buttonStyle(.lowtide(.quiet, size: .small))
            } else {
                Button {
                    NSWorkspace.shared.open(PermissionMap.settingsURL(grant.service))
                } label: {
                    Label("Settings", systemImage: "arrow.up.right")
                }
                .buttonStyle(.lowtide(.quiet, size: .small))
                .help("macOS only lets System Settings remove this one")
            }
        }
        .padding(.vertical, Space.xs)
    }
}

private struct StartupRow: View {
    @Environment(\.palette) private var palette
    @Environment(\.privacy) private var privacy
    let item: PermissionMap.Background
    @Binding var confirm: ConfirmRequest?

    var body: some View {
        let state = Self.state(item)
        HStack(alignment: .top, spacing: Space.md) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.ui(.sm)).foregroundStyle(palette.ink.color).lineLimit(1).textSelection(.enabled)
                Text("\(Text(Self.kind(item.kind)).foregroundStyle(palette.ink3.color))\(Text(" · ").foregroundStyle(palette.ink4.color))\(Text(state.0).foregroundStyle(state.1.color(palette).color))")
                    .font(.ui(.xs))
                if let target = item.executable ?? item.plist {
                    Text(privacy ? "•••" : Paths.tilde(target)).font(.mono(.xxs)).foregroundStyle(palette.ink4.color)
                        .lineLimit(1).truncationMode(.middle).help(target)
                }
            }
            Spacer(minLength: Space.sm)
            action
        }
        .padding(.vertical, Space.xs)
        .contextMenu {
            if let plist = item.plist { Button("Show in Finder") { FileActions.reveal(plist) } }
            if let label = item.label { Button("Copy Label") { FileActions.copy(label, what: "Label") } }
        }
    }

    static func kind(_ kind: PermissionMap.Background.Kind) -> String {
        switch kind {
        case .agent: "Background agent"
        case .daemon: "System daemon"
        case .loginItem: "Login item"
        case .openAtLogin: "Opens at login"
        }
    }

    static func state(_ item: PermissionMap.Background) -> (String, Tone) {
        if item.missing { return ("points to something that's gone", .bad) }
        if item.overridden { return ("stopped", .neutral) }
        if !item.allowed { return ("not allowed in Login Items", .neutral) }
        if !item.enabled { return ("turned off by the app", .neutral) }
        return ("starts with the Mac", .ok)
    }

    @ViewBuilder private var action: some View {
        if item.removable {
            Button("Move to Trash…") {
                confirm = ConfirmRequest(title: "Move \(item.name) to the Trash?",
                                         message: "\(item.name) is unloaded and its plist moves to the Trash. Put it back from the Trash to undo.",
                                         confirm: "Move to Trash") {
                    changePermissionMap("Couldn't move \(item.name) to the Trash") { try await PermissionActions.shared.trashLeftover(id: item.id) }
                }
            }
            .buttonStyle(.lowtide(.destructive, size: .small))
        } else if item.control == .settings {
            Button {
                NSWorkspace.shared.open(PermissionMap.settingsURL("login"))
            } label: {
                Label("Login Items", systemImage: "arrow.up.right")
            }
            .buttonStyle(.lowtide(.quiet, size: .small))
        } else if item.kind == .openAtLogin {
            Button("Remove…") {
                confirm = ConfirmRequest(title: "Stop opening \(item.name) at login?",
                                         message: "Removes it from the Open at Login list. Add it back in System Settings → Login Items.",
                                         confirm: "Remove") {
                    changePermissionMap("Couldn't remove \(item.name)") { try await PermissionActions.shared.setStartup(id: item.id, on: false) }
                }
            }
            .buttonStyle(.lowtide(.quiet, size: .small))
        } else {
            let on = item.overridden
            Button(on ? "Allow" : "Stop…") {
                let change = {
                    changePermissionMap("Couldn't change \(item.name)") { try await PermissionActions.shared.setStartup(id: item.id, on: on) }
                }
                if on {
                    change()
                } else {
                    confirm = ConfirmRequest(
                        title: "Stop \(item.name) at login?",
                        message: "Unloads it and keeps it from starting with the Mac. Allow it again here any time."
                            + (item.control == .admin ? " macOS asks for an administrator password." : ""),
                        confirm: "Stop", destructive: false, action: change)
                }
            }
            .buttonStyle(.lowtide(.quiet, size: .small))
            .help(item.control == .admin ? "macOS will ask for an administrator password" : "")
        }
    }
}

private struct TrafficFacts: View {
    @Environment(\.palette) private var palette
    let traffic: PermissionMap.Traffic?

    var body: some View {
        if let traffic {
            VStack(alignment: .leading, spacing: 2) {
                RunFactRow("Downloaded", LowtideFormat.bytes(traffic.bytesIn))
                RunFactRow("Uploaded", LowtideFormat.bytes(traffic.bytesOut))
                RunFactRow("Hosts", traffic.hosts.formatted())
                if !traffic.countries.isEmpty {
                    RunFactRow("Countries", traffic.countries.map { Locale.current.localizedString(forRegionCode: $0) ?? $0 }
                        .joined(separator: ", "))
                }
            }
        } else {
            Text("No traffic seen under this name in the last 7 days.").font(.ui(.xs)).foregroundStyle(palette.ink3.color)
        }
    }
}
