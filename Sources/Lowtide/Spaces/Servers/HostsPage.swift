import LowtideKit
import SwiftUI

/// Developer › Hosts: saved servers, their groups, and the Fleet (a view
/// of the same hosts: their health, once a minute).
struct HostsPage: View {
    enum Mode: String { case hosts, groups, fleet }

    @Environment(\.palette) private var palette
    private var remote = RemoteStore.shared
    @AppStorage("hosts.view") private var view: Mode = .hosts
    @State private var hostSheet: HostDraft?
    @State private var groupSheet: GroupDraft?
    @State private var watching = false

    var description: String? {
        let s = remote.snapshot
        switch view {
        case .hosts, .groups:
            guard !s.hosts.isEmpty || !s.groups.isEmpty else { return nil }
            return LowtideKitFormat.count(s.hosts.count, "host") + (s.groups.isEmpty ? "" : " in \(LowtideKitFormat.count(s.groups.count, "group"))")
        case .fleet:
            return FleetView.summary(remote.fleet)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("Hosts", description: description) {
                Segmented($view, [(.hosts, "All hosts"), (.groups, "Groups"), (.fleet, "Fleet")],
                          counts: [.fleet: remote.fleet.filter { $0.state == .unreachable || $0.state == .needsKey }.count])
            } action: {
                switch view {
                case .hosts:
                    Button { hostSheet = HostDraft() } label: { Label("New host", systemImage: "plus") }.buttonStyle(.primary)
                case .groups:
                    Button { groupSheet = GroupDraft() } label: { Label("New group", systemImage: "plus") }.buttonStyle(.primary)
                case .fleet:
                    Button("Watch hosts…") { watching = true }.buttonStyle(.secondary)
                }
            }
            Group {
                if !remote.loaded {
                    ScanningState(title: "Loading hosts")
                } else if let error = remote.error {
                    ErrorState(message: error) { Task { await remote.load() } }
                } else {
                    switch view {
                    case .hosts: HostList(onNew: { hostSheet = HostDraft() }, onEdit: { hostSheet = HostDraft($0) })
                    case .groups: GroupList(onNew: { groupSheet = GroupDraft() }, onEdit: { groupSheet = $0 })
                    case .fleet: FleetView(onWatch: { watching = true })
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await remote.load() }
        .sheet(item: $hostSheet) { draft in HostEditor(draft: draft) { hostSheet = nil } }
        .sheet(item: $groupSheet) { draft in GroupSheet(draft: draft) { groupSheet = nil } }
        .sheet(isPresented: $watching) { WatchSheet { watching = false } }
    }
}

// MARK: - All hosts

private struct HostList: View {
    @Environment(\.palette) private var palette
    private var remote = RemoteStore.shared
    let onNew: () -> Void
    let onEdit: (RemoteHost) -> Void
    @State private var filter = ""
    @State private var selection: Set<String> = []
    @State private var anchor: String?
    @State private var confirm: ConfirmRequest?

    init(onNew: @escaping () -> Void, onEdit: @escaping (RemoteHost) -> Void) {
        self.onNew = onNew
        self.onEdit = onEdit
    }

    var hosts: [RemoteHost] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return remote.snapshot.hosts }
        return remote.snapshot.hosts.filter { host in
            let group = remote.group(host.groupID)?.name ?? ""
            return "\(host.name) \(host.hostname) \(host.username) \(host.tags ?? "") \(group)".lowercased().contains(q)
        }
    }

    var body: some View {
        if remote.snapshot.hosts.isEmpty {
            VStack(spacing: Space.lg) {
                HeroArt("developer", size: 80)
                EmptyState("No hosts yet", symbol: "server.rack",
                           message: "Save a server once, then open an SSH session with one click.") {
                    Button("Add a host", action: onNew).buttonStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.md) {
                    PageToolbar {
                        FilterField(text: $filter, prompt: "Filter by name, address or tag")
                    } trailing: {
                        Text("Double-click to connect · ⇧-click selects a range")
                            .font(.ui(.xs)).foregroundStyle(palette.ink4.color)
                    }
                    let list = hosts
                    VStack(spacing: 0) {
                        if list.isEmpty {
                            Text("No host matches “\(filter)”.").font(.ui(.sm)).foregroundStyle(palette.ink3.color).padding(Space.xl)
                        }
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, host in
                            if index > 0 { Hairline(inset: 60) }
                            HostRow(host: host, selected: selection.contains(host.id),
                                    selectionCount: selection.contains(host.id) ? selection.count : 1,
                                    onClick: { click(host, in: list) },
                                    onEdit: { onEdit(host) },
                                    onDelete: { ask(delete: targets(host)) })
                        }
                    }
                    .card()
                }
                .padding(.horizontal, Space.page + 4)
                .padding(.bottom, Space.page * 3)
                .frame(maxWidth: 1180)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
            .onDeleteCommand { ask(delete: remote.snapshot.hosts.filter { selection.contains($0.id) }) }
            .onKeyPress(.return) {
                guard selection.count == 1, let host = remote.host(selection.first) else { return .ignored }
                remote.connect(host)
                return .handled
            }
            .onExitCommand { selection = [] }
            .overlay(alignment: .bottom) {
                if selection.count > 1 {
                    SelectionBar(count: selection.count, noun: "host") { selection = [] } actions: {
                        Button("Delete", role: .destructive) { ask(delete: remote.snapshot.hosts.filter { selection.contains($0.id) }) }
                            .buttonStyle(.lowtide(.destructive, size: .small))
                    }
                    .padding(.bottom, Space.xl)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(Motion.spring, value: selection.count > 1)
            .confirmation($confirm)
        }
    }

    private func targets(_ host: RemoteHost) -> [RemoteHost] {
        selection.contains(host.id) ? remote.snapshot.hosts.filter { selection.contains($0.id) } : [host]
    }

    /// Click selects, ⌘-click adds, ⇧-click selects a range.
    private func click(_ host: RemoteHost, in list: [RemoteHost]) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(host.id) { selection.remove(host.id) } else { selection.insert(host.id) }
            anchor = host.id
        } else if flags.contains(.shift), let anchor, let a = list.firstIndex(where: { $0.id == anchor }),
                  let b = list.firstIndex(where: { $0.id == host.id }) {
            selection = Set(list[min(a, b)...max(a, b)].map(\.id))
        } else {
            selection = [host.id]
            anchor = host.id
        }
    }

    private func ask(delete hosts: [RemoteHost]) {
        guard !hosts.isEmpty else { return }
        confirm = ConfirmRequest(
            title: hosts.count > 1 ? "Delete \(hosts.count) saved hosts?" : "Delete saved host?",
            message: "Delete \(hosts.count > 1 ? LowtideKitFormat.count(hosts.count, "host") : "“\(hosts[0].name)”") from Lowtide? Their port forwards are removed too. Credentials and local SSH keys are kept.",
            confirm: hosts.count > 1 ? "Delete \(hosts.count) Hosts" : "Delete Host") {
            selection.subtract(hosts.map(\.id))
            Task { await RemoteStore.shared.delete(hosts: hosts) }
        }
    }
}

private struct HostRow: View {
    @Environment(\.palette) private var palette
    @State private var hovering = false
    let host: RemoteHost
    let selected: Bool
    let selectionCount: Int
    let onClick: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var remote: RemoteStore { RemoteStore.shared }

    var body: some View {
        let live = remote.isConnected(host)
        let identity = remote.resolution.identity(for: host)
        HStack(spacing: Space.md) {
            DevGlyphTile("hosts", live: live)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.sm) {
                    if let color = host.color.flatMap(ColorValue.parse) {
                        // The host's own colour, the one it carries in tabs.
                        Circle().fill(color.color).frame(width: 8, height: 8)
                    }
                    Text(host.name).font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color).lineLimit(1)
                    if live { Badge("Connected", tone: .ok) }
                    if let group = remote.group(host.groupID) { Badge(group.name) }
                    if let identity { Badge(identity.name) }
                    if remote.watched.contains(host.id) { Badge("Watched") }
                }
                Sensitive(text: host.address, font: .mono(.xs)).foregroundStyle(palette.ink3.color).lineLimit(1)
            }
            Spacer(minLength: Space.md)
            if hovering {
                HStack(spacing: Space.xs) {
                    Button("Connect") { remote.connect(host) }.buttonStyle(.lowtide(.secondary, size: .small))
                    IconButton("pencil", help: "Edit", action: onEdit)
                    IconButton("trash", help: "Delete", action: onDelete)
                }
                .transition(.opacity)
            } else if let last = host.lastConnectedAt {
                Text(LowtideKitFormat.ago(Date(timeIntervalSince1970: Double(last) / 1000)))
                    .font(.ui(.xs)).foregroundStyle(palette.ink4.color)
            }
        }
        .padding(.horizontal, Space.lg)
        .frame(minHeight: 54)
        .background((selected ? palette.selectedBrand : hovering ? palette.hover : ColorValue(r: 0, g: 0, b: 0, a: 0)).color)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .animation(Motion.fast, value: hovering)
        .onTapGesture(count: 2) { remote.connect(host) }
        .onTapGesture(perform: onClick)
        .contextMenu {
            Button("Connect") { remote.connect(host) }
            Button("Edit Host…", action: onEdit)
            Button(remote.watched.contains(host.id) ? "Stop Watching in Fleet" : "Watch in Fleet") { remote.toggleWatch(host) }
            Button("Copy Address") {
                Files.copy("\(host.username)@\(host.hostname)" + (host.port == 22 ? "" : ":\(host.port)"))
            }
            Divider()
            Button(selectionCount > 1 ? "Delete \(selectionCount) Hosts…" : "Delete…", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Host sheet

struct HostDraft: Identifiable {
    var id = UUID()
    var host: RemoteHost?
    var name = ""
    var hostname = ""
    var port = "22"
    var username = ""
    var identityID: String?
    var groupID: String?
    var jumpHostID: String?
    var tags = ""
    var notes = ""
    var newPassword = false
    var passwordName = ""
    var password = ""

    init(_ host: RemoteHost? = nil) {
        self.host = host
        name = host?.name ?? ""
        hostname = host?.hostname ?? ""
        port = String(host?.port ?? 22)
        username = host?.username ?? ""
        identityID = host?.identityID
        groupID = host?.groupID
        jumpHostID = host?.jumpHostID
        tags = host?.tags ?? ""
        notes = host?.notes ?? ""
    }
}

struct HostEditor: View {
    @Environment(\.palette) private var palette
    @State var draft: HostDraft
    @State private var problem: String?
    @State private var saving = false
    let close: () -> Void
    private var remote: RemoteStore { RemoteStore.shared }
    static let newPassword = "__new_password__"

    init(draft: HostDraft, close: @escaping () -> Void) {
        _draft = State(initialValue: draft)
        self.close = close
    }

    var credentialBinding: Binding<String> {
        Binding(get: { draft.newPassword ? Self.newPassword : (draft.identityID ?? "") }, set: { value in
            if value == Self.newPassword {
                draft.identityID = nil
                draft.newPassword = true
                if draft.passwordName.isEmpty { draft.passwordName = "\(draft.name.isEmpty ? (draft.hostname.isEmpty ? "Host" : draft.hostname) : draft.name) password" }
            } else {
                draft.newPassword = false
                draft.identityID = value.isEmpty ? nil : value
            }
        })
    }

    /// What "Default" means for this host: the group's credential, or ssh's own.
    var inherited: String? {
        let probe = RemoteHost(name: "", hostname: "", username: "", groupID: draft.groupID)
        guard let group = remote.resolution.identitySource(for: probe),
              let identity = remote.identity(group.identityID) else { return nil }
        return "From \(group.name): \(identity.name)"
    }

    var body: some View {
        DevSheet(draft.host == nil ? "New host" : "Edit host", description: "Saved on this Mac. Passwords go to the Keychain.") {
            DevField("Name") { TextField("Media server", text: $draft.name).devField() }
            HStack(alignment: .top, spacing: Space.sm) {
                DevField("Hostname or IP") { TextField("server.example.com", text: $draft.hostname).devField() }
                DevField("Port") { TextField("22", text: $draft.port).devField() }.frame(width: 90)
            }
            DevField("User") { TextField("root", text: $draft.username).devField() }
            HStack(alignment: .top, spacing: Space.sm) {
                DevField("Credential", hint: draft.identityID == nil && !draft.newPassword ? inherited : nil) {
                    Picker("Credential", selection: credentialBinding) {
                        Text(inherited == nil ? "Default (ssh-agent, ~/.ssh)" : "From its group").tag("")
                        if !remote.snapshot.identities.isEmpty { Divider() }
                        ForEach(remote.snapshot.identities) { identity in
                            Text("\(identity.name) (\(identity.kind == .password ? "Password" : "SSH key"))").tag(identity.id)
                        }
                        Divider()
                        Text("Save a new password…").tag(Self.newPassword)
                    }
                    .labelsHidden()
                }
                DevField("Group") {
                    Picker("Group", selection: $draft.groupID) {
                        Text("Ungrouped").tag(String?.none)
                        ForEach(remote.groupTree, id: \.group.id) { item in
                            Text(String(repeating: "   ", count: item.depth) + item.group.name).tag(Optional(item.group.id))
                        }
                    }
                    .labelsHidden()
                }
            }
            if draft.newPassword {
                HStack(alignment: .top, spacing: Space.sm) {
                    DevField("Password name", hint: "Saved as a reusable credential.") {
                        TextField("Host password", text: $draft.passwordName).devField()
                    }
                    DevField("Password", hint: "Kept in the Keychain, never in the vault.") {
                        SecureField("Enter password", text: $draft.password).devField()
                    }
                }
                .padding(Space.md)
                .background(palette.fill.color, in: .rect(cornerRadius: Radius.lg))
            }
            DevField("Jump host", hint: "Route this connection through another saved host. Hosts in a group with a jump host use it unless they set their own.") {
                Picker("Jump host", selection: $draft.jumpHostID) {
                    Text("Direct connection").tag(String?.none)
                    ForEach(remote.snapshot.hosts.filter { $0.id != draft.host?.id }) { host in
                        Text(host.name).tag(Optional(host.id))
                    }
                }
                .labelsHidden()
            }
            DevField("Tags", hint: "Separate with commas. The filter finds hosts by tag.") {
                TextField("production, api, us-east", text: $draft.tags).devField()
            }
            DevField("Notes") {
                TextEditor(text: $draft.notes)
                    .font(.ui(.sm))
                    .scrollContentBackground(.hidden)
                    .padding(Space.xs)
                    .frame(height: 64)
                    .background(palette.fill.color, in: .rect(cornerRadius: Radius.md))
                    .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(palette.line.color))
            }
            if let problem { Text(problem).font(.ui(.xs)).foregroundStyle(palette.bad.color) }
        } footer: {
            Button("Cancel", action: close).buttonStyle(.quiet).keyboardShortcut(.cancelAction)
            Button(draft.host == nil ? "Save host" : "Save changes", action: save)
                .buttonStyle(.primary).keyboardShortcut(.defaultAction).disabled(saving)
        }
    }

    private func save() {
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        let hostname = draft.hostname.trimmingCharacters(in: .whitespaces)
        let user = draft.username.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !hostname.isEmpty, !user.isEmpty else {
            problem = "Name, hostname and user are required."
            return
        }
        guard let port = Int(draft.port.trimmingCharacters(in: .whitespaces)), SSHCommand.validPort(port) else {
            problem = "The port must be between 1 and 65535."
            return
        }
        do { try SSHCommand.validate(user: user, host: hostname) } catch {
            problem = "Hostname and user can't contain spaces or start with a dash."
            return
        }
        if draft.newPassword, draft.password.isEmpty {
            problem = "Enter the password you want to save."
            return
        }
        saving = true
        Task {
            var identityID = draft.identityID
            var created: Identity?
            if draft.newPassword {
                let identity = Identity(name: draft.passwordName.trimmingCharacters(in: .whitespaces).isEmpty ? "\(name) password" : draft.passwordName,
                                        kind: .password, username: user)
                guard await remote.create(identity, secret: draft.password) else {
                    saving = false
                    return
                }
                created = identity
                identityID = identity.id
            }
            var host = draft.host ?? RemoteHost(name: name, hostname: hostname, username: user)
            host.name = name
            host.hostname = hostname
            host.port = port
            host.username = user
            host.identityID = identityID
            host.groupID = draft.groupID
            host.jumpHostID = draft.jumpHostID
            let tags = draft.tags.trimmingCharacters(in: .whitespaces)
            host.tags = tags.isEmpty ? nil : tags
            host.notes = draft.notes.isEmpty ? nil : draft.notes
            if await remote.save(host) {
                remote.syncFleet()
                Toasts.shared.show(draft.host == nil ? "Saved \(name)" : "Updated \(name)")
                close()
            } else if let created {
                // Keep the original error; the new password goes with the failed save.
                await remote.delete(created, files: false)
            }
            saving = false
        }
    }
}

// MARK: - Groups

struct GroupDraft: Identifiable {
    var id = UUID()
    var group: HostGroup?
    var name = ""
    var parentID: String?
    var identityID: String?
    var jumpHostID: String?

    init(_ group: HostGroup? = nil, parent: String? = nil) {
        self.group = group
        name = group?.name ?? ""
        parentID = group?.parentID ?? parent
        identityID = group?.identityID
        jumpHostID = group?.jumpHostID
    }
}

private struct GroupList: View {
    @Environment(\.palette) private var palette
    private var remote = RemoteStore.shared
    @State private var confirm: ConfirmRequest?
    let onNew: () -> Void
    let onEdit: (GroupDraft) -> Void

    init(onNew: @escaping () -> Void, onEdit: @escaping (GroupDraft) -> Void) {
        self.onNew = onNew
        self.onEdit = onEdit
    }

    var body: some View {
        if remote.snapshot.groups.isEmpty {
            VStack(spacing: Space.lg) {
                HeroArt("developer", size: 80)
                EmptyState("No groups yet", symbol: "folder",
                           message: "Group hosts by environment or project, and give the group one credential and jump host they all use.") {
                    Button("New group", action: onNew).buttonStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    let tree = remote.groupTree
                    ForEach(Array(tree.enumerated()), id: \.element.group.id) { index, item in
                        if index > 0 { Hairline(inset: 60) }
                        GroupRow(group: item.group, depth: item.depth,
                                 onEdit: { onEdit(GroupDraft(item.group)) },
                                 onAddChild: { onEdit(GroupDraft(parent: item.group.id)) },
                                 onDelete: { ask(delete: item.group) })
                    }
                }
                .card()
                .padding(.horizontal, Space.page + 4)
                .padding(.bottom, Space.page * 2)
                .frame(maxWidth: 1180)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
            .confirmation($confirm)
        }
    }

    private func ask(delete group: HostGroup) {
        confirm = ConfirmRequest(title: "Delete host group?",
                                 message: "Delete “\(group.name)”? Its hosts and subgroups move to the top level.",
                                 confirm: "Delete Group") {
            Task { await RemoteStore.shared.delete(group) }
        }
    }
}

private struct GroupRow: View {
    @Environment(\.palette) private var palette
    @State private var hovering = false
    let group: HostGroup
    let depth: Int
    let onEdit: () -> Void
    let onAddChild: () -> Void
    let onDelete: () -> Void

    private var remote: RemoteStore { RemoteStore.shared }

    var detail: String {
        var parts: [String] = []
        if let parent = remote.group(group.parentID) { parts.append("In \(parent.name)") }
        parts.append(remote.identity(group.identityID).map { "Uses \($0.name)" } ?? "No credential")
        if let jump = remote.host(group.jumpHostID) { parts.append("Through \(jump.name)") }
        let count = remote.resolution.hosts(inGroups: [group.id]).count
        parts.append(LowtideKitFormat.count(count, "host"))
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: Space.md) {
            DevGlyphTile("hosts")
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name).font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color).lineLimit(1)
                Text(detail).font(.ui(.xs)).foregroundStyle(palette.ink3.color).lineLimit(1)
            }
            Spacer(minLength: Space.md)
            if hovering {
                HStack(spacing: Space.xs) {
                    IconButton("folder.badge.plus", help: "New subgroup", action: onAddChild)
                    IconButton("pencil", help: "Edit", action: onEdit)
                    IconButton("trash", help: "Delete", action: onDelete)
                }
            }
        }
        .padding(.leading, Space.lg + CGFloat(depth) * 28)
        .padding(.trailing, Space.lg)
        .frame(minHeight: 54)
        .background(hovering ? palette.hover.color : .clear)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: onEdit)
        .contextMenu {
            Button("Edit Group…", action: onEdit)
            Button("New Subgroup…", action: onAddChild)
            Divider()
            Button("Delete…", role: .destructive, action: onDelete)
        }
    }
}

private struct GroupSheet: View {
    @Environment(\.palette) private var palette
    @State var draft: GroupDraft
    @State private var problem: String?
    let close: () -> Void
    private var remote: RemoteStore { RemoteStore.shared }

    init(draft: GroupDraft, close: @escaping () -> Void) {
        _draft = State(initialValue: draft)
        self.close = close
    }

    var body: some View {
        let excluded = draft.group.map { remote.descendants(of: $0.id) } ?? []
        DevSheet(draft.group == nil ? "New host group" : "Edit host group",
                 description: "Hosts in the group use its credential and jump host unless they set their own. Subgroups inherit them too.") {
            DevField("Name") { TextField("Production, staging, homelab…", text: $draft.name).devField() }
            DevField("Parent group") {
                Picker("Parent group", selection: $draft.parentID) {
                    Text("None (top level)").tag(String?.none)
                    ForEach(remote.groupTree.filter { !excluded.contains($0.group.id) }, id: \.group.id) { item in
                        Text(String(repeating: "   ", count: item.depth) + item.group.name).tag(Optional(item.group.id))
                    }
                }
                .labelsHidden()
            }
            DevField("Default credential") {
                Picker("Default credential", selection: $draft.identityID) {
                    Text("None").tag(String?.none)
                    ForEach(remote.snapshot.identities) { identity in Text(identity.name).tag(Optional(identity.id)) }
                }
                .labelsHidden()
            }
            DevField("Jump host") {
                Picker("Jump host", selection: $draft.jumpHostID) {
                    Text("Direct connection").tag(String?.none)
                    ForEach(remote.snapshot.hosts) { host in Text(host.name).tag(Optional(host.id)) }
                }
                .labelsHidden()
            }
            if let problem { Text(problem).font(.ui(.xs)).foregroundStyle(palette.bad.color) }
        } footer: {
            Button("Cancel", action: close).buttonStyle(.quiet).keyboardShortcut(.cancelAction)
            Button("Save group", action: save).buttonStyle(.primary).keyboardShortcut(.defaultAction)
        }
    }

    private func save() {
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            problem = "Name is required."
            return
        }
        var group = draft.group ?? HostGroup(name: name)
        group.name = name
        group.parentID = draft.parentID
        group.identityID = draft.identityID
        group.jumpHostID = draft.jumpHostID
        Task {
            if await remote.save(group) {
                remote.syncFleet()
                Toasts.shared.show("Saved \(name)")
                close()
            }
        }
    }
}
