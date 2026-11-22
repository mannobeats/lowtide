import AppKit
import LowtideKit
import SwiftUI

/// Developer › Credentials: SSH keys and passwords, used by many hosts.
/// Secrets stay in the Keychain.
struct CredentialsPage: View {
    @Environment(\.palette) private var palette
    private var remote = RemoteStore.shared
    @State private var adding = false
    @State private var deploying: Identity?
    @State private var confirm: ConfirmRequest?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("Credentials", description: remote.snapshot.identities.isEmpty ? nil
                       : "\(LowtideKitFormat.count(remote.snapshot.identities.count, "credential")) · secrets stay in the Keychain") {
                EmptyView()
            } action: {
                Button { adding = true } label: { Label("Add credential", systemImage: "plus") }.buttonStyle(.primary)
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await remote.load() }
        .sheet(isPresented: $adding) { IdentitySheet { adding = false } }
        .sheet(item: $deploying) { identity in KeyDeploymentSheet(identity: identity) { deploying = nil } }
        .confirmation($confirm)
    }

    @ViewBuilder private var content: some View {
        if !remote.loaded {
            ScanningState(title: "Loading credentials")
        } else if let error = remote.error {
            ErrorState(message: error) { Task { await remote.load() } }
        } else if remote.snapshot.identities.isEmpty {
            VStack(spacing: Space.lg) {
                HeroArt("developer", size: 80)
                EmptyState("No credentials yet", symbol: "key",
                           message: "Save an SSH key or password once and use it on many hosts. Secrets stay in the Keychain.") {
                    Button("Add credential") { adding = true }.buttonStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(remote.snapshot.identities.enumerated()), id: \.element.id) { index, identity in
                        if index > 0 { Hairline(inset: 60) }
                        IdentityRow(identity: identity, onDeploy: { deploying = identity },
                                    onRemove: { ask(remove: identity, files: false) },
                                    onRemoveFiles: { ask(remove: identity, files: true) })
                    }
                }
                .card()
                .padding(.horizontal, Space.page + 4)
                .padding(.bottom, Space.page * 2)
                .frame(maxWidth: 1180)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
        }
    }

    private func ask(remove identity: Identity, files: Bool) {
        let path = identity.keyPath.map { Paths.tilde(SSHCommand.expandHome($0)) } ?? ""
        confirm = files
            ? ConfirmRequest(title: "Move the SSH key to the Trash?",
                             message: "Remove “\(identity.name)” and move \(path) and its public key to the Trash? Hosts that use it will need another way in.",
                             confirm: "Move to Trash") { Task { await RemoteStore.shared.delete(identity, files: true) } }
            : ConfirmRequest(title: "Remove credential?",
                             message: "Remove “\(identity.name)” from Lowtide? Its saved secret leaves the Keychain\(identity.keyPath == nil ? "" : "; the key files stay in \(path)").",
                             confirm: "Remove Credential") { Task { await RemoteStore.shared.delete(identity, files: false) } }
    }
}

private struct IdentityRow: View {
    @Environment(\.palette) private var palette
    @State private var hovering = false
    let identity: Identity
    let onDeploy: () -> Void
    let onRemove: () -> Void
    let onRemoveFiles: () -> Void

    var users: Int {
        let resolution = RemoteStore.shared.resolution
        return resolution.hosts.filter { resolution.identity(for: $0)?.id == identity.id }.count
    }

    var body: some View {
        HStack(spacing: Space.md) {
            DevGlyphTile("credentials")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.sm) {
                    Text(identity.name).font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color).lineLimit(1)
                    if identity.hasPassphrase { Badge("Passphrase") }
                }
                HStack(spacing: 0) {
                    if identity.kind == .sshKey {
                        Sensitive(text: identity.keyPath.map { Paths.tilde(SSHCommand.expandHome($0)) } ?? "No key file", font: .mono(.xxs))
                    } else {
                        Text("Password").font(.ui(.xs))
                    }
                    if let user = identity.username, !user.isEmpty {
                        Text(" · ").font(.ui(.xs))
                        Sensitive(text: user, font: .mono(.xxs))
                    }
                }
                .foregroundStyle(palette.ink3.color)
                .lineLimit(1)
            }
            Spacer(minLength: Space.md)
            if hovering {
                HStack(spacing: Space.xs) {
                    if identity.kind == .sshKey, identity.publicKey != nil {
                        IconButton("server.rack", help: "Manage key on a host", action: onDeploy)
                    }
                    IconButton("trash", help: "Remove", action: onRemove)
                }
            } else {
                let count = users
                Text(count == 0 ? "Not used" : "Used by \(LowtideKitFormat.count(count, "host"))")
                    .font(.ui(.xs)).foregroundStyle(palette.ink4.color)
            }
        }
        .padding(.horizontal, Space.lg)
        .frame(minHeight: 54)
        .background(hovering ? palette.hover.color : .clear)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Manage Key on a Host…", action: onDeploy).disabled(identity.keyPath == nil || identity.publicKey == nil)
            Button(identity.publicKey == nil ? "Copy ID" : "Copy Public Key") {
                Files.copy(identity.publicKey ?? identity.id)
                Toasts.shared.show(identity.publicKey == nil ? "Copied the ID" : "Copied the public key")
            }
            if let path = identity.keyPath {
                Button("Show in Finder") {
                    Files.reveal([SSHCommand.expandHome(path)])
                }
            }
            Divider()
            Button("Remove from Lowtide…", role: .destructive, action: onRemove)
            if identity.kind == .sshKey, identity.keyPath != nil {
                Button("Move Key Files to the Trash…", role: .destructive, action: onRemoveFiles)
            }
        }
    }
}

// MARK: - Add a credential

private struct IdentitySheet: View {
    enum Mode: Hashable { case generate, existing, password }

    @Environment(\.palette) private var palette
    @State private var mode: Mode = .generate
    @State private var keyType: SSHKeys.KeyType = .ed25519
    @State private var name = ""
    @State private var username = ""
    @State private var keyPath = ""
    @State private var secret = ""
    @State private var found: [SSHKeys.Found] = []
    @State private var problem: String?
    @State private var working = false
    let close: () -> Void

    var body: some View {
        DevSheet("Add credential", description: "Generate a secure key, use one from ~/.ssh, or save a password in the Keychain.") {
            Segmented($mode, [(.generate, "Generate key"), (.existing, "Existing key"), (.password, "Password")])
            HStack(alignment: .top, spacing: Space.sm) {
                DevField("Name") { TextField("production-api", text: $name).devField() }
                DevField("Default username") { TextField("root", text: $username).devField() }
            }
            switch mode {
            case .generate:
                DevField("Key algorithm", hint: "Ed25519 is the best default. RSA 4096 is there for older servers.") {
                    Segmented($keyType, [(.ed25519, "Ed25519"), (.ecdsa, "ECDSA"), (.rsa, "RSA 4096")])
                }
                DevField("Passphrase (optional)", hint: "The key is written to ~/.ssh, private to you. The passphrase also goes to the Keychain.") {
                    SecureField("Recommended for production keys", text: $secret).devField()
                }
            case .existing:
                if !found.isEmpty {
                    DevField("Keys in ~/.ssh") {
                        Picker("Keys in ~/.ssh", selection: Binding(get: { found.contains { $0.path == keyPath } ? keyPath : "" }, set: pick)) {
                            Text("Choose a key…").tag("")
                            ForEach(found) { key in Text(key.name).tag(key.path) }
                        }
                        .labelsHidden()
                    }
                }
                DevField("Private key", hint: "An absolute path or one starting with ~/.") {
                    HStack(spacing: Space.sm) {
                        TextField("~/.ssh/id_ed25519", text: $keyPath).devField().font(.mono(.sm))
                        Button("Choose…", action: choose).buttonStyle(.secondary)
                    }
                }
                DevField("Passphrase (optional)", hint: "Kept in the Keychain, never in the vault.") {
                    SecureField("", text: $secret).devField()
                }
            case .password:
                DevField("Password", hint: "Kept in the Keychain, never in the vault.") {
                    SecureField("", text: $secret).devField()
                }
            }
            if let problem { Text(problem).font(.ui(.xs)).foregroundStyle(palette.bad.color) }
        } footer: {
            if working { ProgressView().controlSize(.small) }
            Button("Cancel", action: close).buttonStyle(.quiet).keyboardShortcut(.cancelAction)
            Button(mode == .generate ? "Generate and save" : "Save credential", action: save)
                .buttonStyle(.primary).keyboardShortcut(.defaultAction).disabled(working)
        }
        .onChange(of: mode) { _, _ in problem = nil }
        .task { found = await Task.detached { SSHKeys.found() }.value }
    }

    private func pick(_ path: String) {
        keyPath = path
        if name.isEmpty, let key = found.first(where: { $0.path == path }) { name = key.name }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.directoryURL = SSHKeys.directory
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        panel.message = "Choose a private SSH key"
        if panel.runModal() == .OK, let url = panel.url { pick(url.path) }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { problem = "Give the credential a name."; return }
        if mode == .password, secret.isEmpty { problem = "Enter the password."; return }
        if mode == .existing, keyPath.trimmingCharacters(in: .whitespaces).isEmpty { problem = "Choose an SSH key."; return }
        working = true
        problem = nil
        let user = username.trimmingCharacters(in: .whitespaces)
        Task {
            defer { working = false }
            var generated: String?
            do {
                var identity: Identity
                var fingerprint = ""
                switch mode {
                case .password:
                    identity = Identity(name: trimmed, kind: .password, username: user.isEmpty ? nil : user)
                case .generate:
                    let key = try await SSHKeys.generate(name: trimmed, type: keyType, passphrase: secret)
                    generated = key.path
                    fingerprint = key.fingerprint
                    identity = Identity(name: trimmed, kind: .sshKey, username: user.isEmpty ? nil : user, keyPath: key.path, publicKey: key.publicKey)
                case .existing:
                    let key = try await SSHKeys.inspect(keyPath)
                    fingerprint = key.fingerprint ?? ""
                    identity = Identity(name: trimmed, kind: .sshKey, username: user.isEmpty ? nil : user, keyPath: key.path, publicKey: key.publicKey)
                }
                if await RemoteStore.shared.create(identity, secret: secret.isEmpty ? nil : secret) {
                    Toasts.shared.show("Saved \(trimmed)", detail: fingerprint.isEmpty ? nil : fingerprint)
                    close()
                } else if let generated {
                    try? await SSHKeys.trash(generated)
                }
            } catch {
                if let generated { try? await SSHKeys.trash(generated) }
                problem = error.localizedDescription
            }
        }
    }
}

// MARK: - Keys on hosts

private struct KeyDeploymentSheet: View {
    @Environment(\.palette) private var palette
    let identity: Identity
    let close: () -> Void
    @State private var install = true
    @State private var hostID: String?
    @State private var confirm: ConfirmRequest?
    private var remote: RemoteStore { RemoteStore.shared }

    init(identity: Identity, close: @escaping () -> Void) {
        self.identity = identity
        self.close = close
    }

    var body: some View {
        DevSheet("Manage key on a host", description: "Add this public key to a server, or take it off. It runs in a terminal tab so you can watch it.") {
            DevField("Public key") {
                VStack(alignment: .leading, spacing: 2) {
                    Text(identity.name).font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color)
                    Text(identity.publicKey ?? "").font(.mono(.xxs)).foregroundStyle(palette.ink3.color)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                .padding(Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.fill.color, in: .rect(cornerRadius: Radius.md))
            }
            DevField("Operation") { Segmented($install, [(true, "Install"), (false, "Remove")]) }
            DevField("Host", hint: install ? "Adds the key once, without duplicates." : "Removes only this exact key from authorized_keys.") {
                Picker("Host", selection: $hostID) {
                    Text("Choose a saved host…").tag(String?.none)
                    ForEach(remote.snapshot.hosts) { host in Text("\(host.name) · \(host.username)@\(host.hostname)").tag(Optional(host.id)) }
                }
                .labelsHidden()
            }
        } footer: {
            Button("Cancel", action: close).buttonStyle(.quiet).keyboardShortcut(.cancelAction)
            Button(install ? "Install key" : "Remove key") {
                if install { run() } else {
                    confirm = ConfirmRequest(title: "Revoke SSH access?",
                                             message: "Remove “\(identity.name)” from the host's authorized_keys? Keep another working way in.",
                                             confirm: "Remove Key from Host") { run() }
                }
            }
            .buttonStyle(install ? .primary : .destructive)
            .keyboardShortcut(.defaultAction)
            .disabled(hostID == nil)
        }
        .confirmation($confirm)
    }

    private func run() {
        guard let host = remote.host(hostID), let key = identity.publicKey else { return }
        do {
            // Same sign-in as a normal connect: the host's own key, else its group's.
            let endpoint = remote.resolution.endpoint(for: host)
            let args = install ? try SSHCommand.installKey(endpoint, publicKey: key) : try SSHCommand.removeKey(endpoint, publicKey: key)
            SessionStore.shared.openSSH(host, title: "\(install ? "Install" : "Remove") key · \(host.name)", args: args, oneShot: true)
            AppModel.shared.open(.sessions)
            Toasts.shared.show("Opened in a terminal tab so you can check it")
            close()
        } catch {
            Toasts.shared.failure("Couldn't \(install ? "install" : "remove") the key", error)
        }
    }
}
