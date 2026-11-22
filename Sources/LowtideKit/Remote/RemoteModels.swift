import Foundation

/// A saved server.
public struct RemoteHost: Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var hostname: String
    public var port: Int
    public var username: String
    public var identityID: String?
    public var jumpHostID: String?
    public var groupID: String?
    /// The host's own colour (`#rrggbb`), the one it carries in tabs.
    public var color: String?
    /// Comma separated.
    public var tags: String?
    public var notes: String?
    public var lastConnectedAt: Int?
    public var createdAt: Int
    public var updatedAt: Int

    public init(id: String = RemoteVault.newID(), name: String, hostname: String, port: Int = 22, username: String,
                identityID: String? = nil, jumpHostID: String? = nil, groupID: String? = nil, color: String? = nil,
                tags: String? = nil, notes: String? = nil, lastConnectedAt: Int? = nil,
                createdAt: Int = Vault.now(), updatedAt: Int = Vault.now()) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.identityID = identityID
        self.jumpHostID = jumpHostID
        self.groupID = groupID
        self.color = color
        self.tags = tags
        self.notes = notes
        self.lastConnectedAt = lastConnectedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// `user@host:port`.
    public var address: String { "\(username)@\(hostname):\(port)" }

    public var tagList: [String] {
        (tags ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// Hosts grouped by environment or project. Groups nest; a host without its
/// own credential or jump host uses the nearest group's.
public struct HostGroup: Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var parentID: String?
    public var color: String?
    public var identityID: String?
    public var jumpHostID: String?
    public var createdAt: Int
    public var updatedAt: Int

    public init(id: String = RemoteVault.newID(), name: String, parentID: String? = nil, color: String? = nil,
                identityID: String? = nil, jumpHostID: String? = nil,
                createdAt: Int = Vault.now(), updatedAt: Int = Vault.now()) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.color = color
        self.identityID = identityID
        self.jumpHostID = jumpHostID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A credential: an SSH key file, or a password. Secrets live in the
/// Keychain, never in the vault.
public struct Identity: Identifiable, Equatable, Hashable, Sendable {
    public enum Kind: String, Sendable { case sshKey = "ssh_key", password }

    public var id: String
    public var name: String
    public var kind: Kind
    public var username: String?
    public var keyPath: String?
    public var publicKey: String?
    public var hasPassphrase: Bool
    public var createdAt: Int
    public var updatedAt: Int

    public init(id: String = RemoteVault.newID(), name: String, kind: Kind, username: String? = nil,
                keyPath: String? = nil, publicKey: String? = nil, hasPassphrase: Bool = false,
                createdAt: Int = Vault.now(), updatedAt: Int = Vault.now()) {
        self.id = id
        self.name = name
        self.kind = kind
        self.username = username
        self.keyPath = keyPath
        self.publicKey = publicKey
        self.hasPassphrase = hasPassphrase
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The Keychain account of this identity's secret, when it has one.
    public var secretAccount: String? {
        switch kind {
        case .password: Self.passwordAccount(id)
        case .sshKey: hasPassphrase ? Self.passphraseAccount(id) : nil
        }
    }

    public static func passwordAccount(_ id: String) -> String { "identity:\(id):password" }
    public static func passphraseAccount(_ id: String) -> String { "identity:\(id):passphrase" }
}

/// A tunnel through a saved host.
public struct PortForward: Identifiable, Equatable, Hashable, Sendable {
    public enum Kind: String, Sendable, CaseIterable { case local, remote, dynamic }

    public var id: String
    public var name: String
    public var hostID: String
    public var kind: Kind
    public var bindHost: String?
    public var bindPort: Int
    public var targetHost: String?
    public var targetPort: Int?
    public var autoStart: Bool
    public var createdAt: Int
    public var updatedAt: Int

    public init(id: String = RemoteVault.newID(), name: String, hostID: String, kind: Kind, bindHost: String? = "127.0.0.1",
                bindPort: Int, targetHost: String? = nil, targetPort: Int? = nil, autoStart: Bool = false,
                createdAt: Int = Vault.now(), updatedAt: Int = Vault.now()) {
        self.id = id
        self.name = name
        self.hostID = hostID
        self.kind = kind
        self.bindHost = bindHost
        self.bindPort = bindPort
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.autoStart = autoStart
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The `-L`/`-R`/`-D` argument: `bind:port[:target:port]`.
    public var spec: String {
        let bind = "\(bindHost?.trimmingCharacters(in: .whitespaces).nonEmpty ?? "127.0.0.1"):\(bindPort)"
        if kind == .dynamic { return bind }
        return "\(bind):\(targetHost?.trimmingCharacters(in: .whitespaces).nonEmpty ?? "127.0.0.1"):\(targetPort ?? bindPort)"
    }

    public var flag: String {
        switch kind {
        case .local: "-L"
        case .remote: "-R"
        case .dynamic: "-D"
        }
    }

    /// `:5432 → db.internal:5432`, `:1080` for SOCKS.
    public var route: String {
        kind == .dynamic ? ":\(bindPort)" : ":\(bindPort) → \(targetHost?.nonEmpty ?? "127.0.0.1"):\(targetPort ?? bindPort)"
    }
}

/// Where a snippet runs.
public enum SnippetTarget: Hashable, Sendable, Comparable {
    /// The terminal in front (never saved).
    case active
    case local
    case allHosts
    case host(String)
    case group(String)

    /// The vault's `target_type`/`target_id` pair; nil for `active`.
    public var stored: (type: String, id: String)? {
        switch self {
        case .active: nil
        case .local: ("local", "")
        case .allHosts: ("all_hosts", "")
        case .host(let id): ("host", id)
        case .group(let id): ("group", id)
        }
    }

    public init?(type: String, id: String) {
        switch type {
        case "local": self = .local
        case "all_hosts": self = .allHosts
        case "host" where !id.isEmpty: self = .host(id)
        case "group" where !id.isEmpty: self = .group(id)
        case "active": self = .active
        default: return nil
        }
    }
}

/// A saved command.
public struct Snippet: Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var content: String
    public var tags: String?
    public var targets: Set<SnippetTarget>
    public var createdAt: Int
    public var updatedAt: Int

    public init(id: String = RemoteVault.newID(), name: String, content: String, tags: String? = nil,
                targets: Set<SnippetTarget> = [], createdAt: Int = Vault.now(), updatedAt: Int = Vault.now()) {
        self.id = id
        self.name = name
        self.content = content
        self.tags = tags
        self.targets = targets
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

fileprivate extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
