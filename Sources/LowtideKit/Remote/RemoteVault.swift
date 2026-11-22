import Foundation

/// Hosts, groups, credentials, port forwards and snippets in the vault.
/// Foreign keys may be off in an imported vault, so every delete clears its
/// references here, at the app layer (as the schema notes say).
public struct RemoteVault: Sendable {
    public let db: SQLiteDatabase

    public init(db: SQLiteDatabase) { self.db = db }

    /// The app's vault; nil when it can't be opened.
    public static var shared: RemoteVault? { Vault.shared.map(RemoteVault.init) }

    /// Twelve URL-safe characters.
    public static func newID() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        return String((0..<12).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    }

    // MARK: Reading

    public struct Snapshot: Equatable, Sendable {
        public var hosts: [RemoteHost] = []
        public var groups: [HostGroup] = []
        public var identities: [Identity] = []
        public var forwards: [PortForward] = []
        public var snippets: [Snippet] = []
        public init() {}
    }

    public func load() async throws -> Snapshot {
        var snapshot = Snapshot()
        snapshot.hosts = try await hosts()
        snapshot.groups = try await groups()
        snapshot.identities = try await identities()
        snapshot.forwards = try await forwards()
        snapshot.snippets = try await snippets()
        return snapshot
    }

    public func hosts() async throws -> [RemoteHost] {
        try await db.query("SELECT * FROM hosts ORDER BY last_connected_at IS NULL, last_connected_at DESC, name COLLATE NOCASE ASC").map {
            RemoteHost(id: $0.string("id") ?? "", name: $0.string("name") ?? "", hostname: $0.string("hostname") ?? "",
                       port: $0.int("port") ?? 22, username: $0.string("username") ?? "",
                       identityID: $0.string("identity_id"), jumpHostID: $0.string("jump_host_id"),
                       groupID: $0.string("group_id"), color: $0.string("color"), tags: $0.string("tags"),
                       notes: $0.string("notes"), lastConnectedAt: $0.int("last_connected_at"),
                       createdAt: $0.int("created_at") ?? 0, updatedAt: $0.int("updated_at") ?? 0)
        }
    }

    public func groups() async throws -> [HostGroup] {
        try await db.query("SELECT * FROM groups ORDER BY name COLLATE NOCASE ASC").map {
            HostGroup(id: $0.string("id") ?? "", name: $0.string("name") ?? "", parentID: $0.string("parent_id"),
                      color: $0.string("color"), identityID: $0.string("identity_id"),
                      jumpHostID: $0.string("jump_host_id"), createdAt: $0.int("created_at") ?? 0,
                      updatedAt: $0.int("updated_at") ?? 0)
        }
    }

    public func identities() async throws -> [Identity] {
        try await db.query("SELECT * FROM identities ORDER BY name COLLATE NOCASE ASC").map {
            Identity(id: $0.string("id") ?? "", name: $0.string("name") ?? "",
                     kind: Identity.Kind(rawValue: $0.string("kind") ?? "") ?? .sshKey, username: $0.string("username"),
                     keyPath: $0.string("key_path"), publicKey: $0.string("public_key"),
                     hasPassphrase: $0.bool("has_passphrase"), createdAt: $0.int("created_at") ?? 0,
                     updatedAt: $0.int("updated_at") ?? 0)
        }
    }

    public func forwards() async throws -> [PortForward] {
        try await db.query("SELECT * FROM port_forwards ORDER BY name COLLATE NOCASE ASC").map {
            PortForward(id: $0.string("id") ?? "", name: $0.string("name") ?? "", hostID: $0.string("host_id") ?? "",
                        kind: PortForward.Kind(rawValue: $0.string("kind") ?? "") ?? .local, bindHost: $0.string("bind_host"),
                        bindPort: $0.int("bind_port") ?? 0, targetHost: $0.string("target_host"),
                        targetPort: $0.int("target_port"), autoStart: $0.bool("auto_start"),
                        createdAt: $0.int("created_at") ?? 0, updatedAt: $0.int("updated_at") ?? 0)
        }
    }

    public func snippets() async throws -> [Snippet] {
        let targets = try await db.query("SELECT * FROM snippet_targets")
        var bySnippet: [String: Set<SnippetTarget>] = [:]
        for row in targets {
            guard let id = row.string("snippet_id"),
                  let target = SnippetTarget(type: row.string("target_type") ?? "", id: row.string("target_id") ?? "") else { continue }
            bySnippet[id, default: []].insert(target)
        }
        return try await db.query("SELECT * FROM snippets ORDER BY name COLLATE NOCASE ASC").map {
            let id = $0.string("id") ?? ""
            return Snippet(id: id, name: $0.string("name") ?? "", content: $0.string("content") ?? "",
                           tags: $0.string("tags"), targets: bySnippet[id] ?? [],
                           createdAt: $0.int("created_at") ?? 0, updatedAt: $0.int("updated_at") ?? 0)
        }
    }

    // MARK: Hosts

    public func save(_ host: RemoteHost) async throws {
        try await db.execute("""
            INSERT INTO hosts (id, name, hostname, port, username, identity_id, jump_host_id, group_id, color, tags, notes,
                               last_connected_at, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, hostname = excluded.hostname, port = excluded.port,
              username = excluded.username, identity_id = excluded.identity_id, jump_host_id = excluded.jump_host_id,
              group_id = excluded.group_id, color = excluded.color, tags = excluded.tags, notes = excluded.notes,
              updated_at = excluded.updated_at
            """, [host.id, host.name, host.hostname, host.port, host.username, host.identityID,
                  host.jumpHostID == host.id ? nil : host.jumpHostID, host.groupID, host.color, host.tags, host.notes,
                  host.lastConnectedAt, host.createdAt, Vault.now()])
    }

    /// Deletes a host, its port forwards, its snippet targets and the jump
    /// references to it. Returns the ids of the forwards that went with it.
    @discardableResult
    public func deleteHost(_ id: String) async throws -> [String] {
        try await db.transaction { @Sendable db in
            let forwards = try db.query("SELECT id FROM port_forwards WHERE host_id = ?", [id]).compactMap { $0.string("id") }
            try db.execute("DELETE FROM port_forwards WHERE host_id = ?", [id])
            try db.execute("DELETE FROM snippet_targets WHERE target_type = 'host' AND target_id = ?", [id])
            try db.execute("UPDATE hosts SET jump_host_id = NULL WHERE jump_host_id = ?", [id])
            try db.execute("UPDATE groups SET jump_host_id = NULL WHERE jump_host_id = ?", [id])
            try db.execute("DELETE FROM hosts WHERE id = ?", [id])
            return forwards
        }
    }

    public func touchHost(_ id: String) async throws {
        try await db.execute("UPDATE hosts SET last_connected_at = ? WHERE id = ?", [Vault.now(), id])
    }

    // MARK: Groups

    public func save(_ group: HostGroup) async throws {
        try await db.execute("""
            INSERT INTO groups (id, name, parent_id, color, identity_id, jump_host_id, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, parent_id = excluded.parent_id, color = excluded.color,
              identity_id = excluded.identity_id, jump_host_id = excluded.jump_host_id, updated_at = excluded.updated_at
            """, [group.id, group.name, group.parentID == group.id ? nil : group.parentID, group.color, group.identityID,
                  group.jumpHostID, group.createdAt, Vault.now()])
    }

    /// Its hosts and subgroups move to the top level.
    public func deleteGroup(_ id: String) async throws {
        try await db.transaction { @Sendable db in
            try db.execute("UPDATE hosts SET group_id = NULL WHERE group_id = ?", [id])
            try db.execute("UPDATE groups SET parent_id = NULL WHERE parent_id = ?", [id])
            try db.execute("DELETE FROM snippet_targets WHERE target_type = 'group' AND target_id = ?", [id])
            try db.execute("DELETE FROM groups WHERE id = ?", [id])
        }
    }

    // MARK: Identities

    /// Saves a credential and its secret (in the Keychain). A Keychain
    /// failure undoes the row, so no credential points at a missing secret.
    public func create(_ identity: Identity, secret: String?) async throws {
        var identity = identity
        if identity.kind == .sshKey { identity.hasPassphrase = !(secret ?? "").isEmpty }
        try await db.execute("""
            INSERT INTO identities (id, name, kind, username, key_path, public_key, has_passphrase, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [identity.id, identity.name, identity.kind.rawValue, identity.username, identity.keyPath,
                  identity.publicKey, identity.hasPassphrase, identity.createdAt, identity.updatedAt])
        guard let secret, !secret.isEmpty, let account = identity.secretAccount else { return }
        do {
            try Keychain.set(secret, for: account)
        } catch {
            _ = try? await db.execute("DELETE FROM identities WHERE id = ?", [identity.id])
            throw error
        }
    }

    public func deleteIdentity(_ id: String) async throws {
        try await db.transaction { @Sendable db in
            try db.execute("UPDATE hosts SET identity_id = NULL WHERE identity_id = ?", [id])
            try db.execute("UPDATE groups SET identity_id = NULL WHERE identity_id = ?", [id])
            try db.execute("DELETE FROM identities WHERE id = ?", [id])
        }
        Keychain.delete(Identity.passwordAccount(id))
        Keychain.delete(Identity.passphraseAccount(id))
    }

    // MARK: Port forwards

    public func save(_ forward: PortForward) async throws {
        try await db.execute("""
            INSERT INTO port_forwards (id, name, host_id, kind, bind_host, bind_port, target_host, target_port, auto_start,
                                       created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, host_id = excluded.host_id, kind = excluded.kind,
              bind_host = excluded.bind_host, bind_port = excluded.bind_port, target_host = excluded.target_host,
              target_port = excluded.target_port, auto_start = excluded.auto_start, updated_at = excluded.updated_at
            """, [forward.id, forward.name, forward.hostID, forward.kind.rawValue, forward.bindHost, forward.bindPort,
                  forward.kind == .dynamic ? nil : forward.targetHost, forward.kind == .dynamic ? nil : forward.targetPort,
                  forward.autoStart, forward.createdAt, Vault.now()])
    }

    public func deleteForward(_ id: String) async throws {
        try await db.execute("DELETE FROM port_forwards WHERE id = ?", [id])
    }

    // MARK: Snippets

    /// Saves a snippet and replaces its saved targets.
    public func save(_ snippet: Snippet) async throws {
        try await db.transaction { @Sendable db in
            try db.execute("""
                INSERT INTO snippets (id, name, content, tags, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET name = excluded.name, content = excluded.content, tags = excluded.tags,
                  updated_at = excluded.updated_at
                """, [snippet.id, snippet.name, snippet.content, snippet.tags, snippet.createdAt, Vault.now()])
            try db.execute("DELETE FROM snippet_targets WHERE snippet_id = ?", [snippet.id])
            for target in snippet.targets.sorted() {
                guard let stored = target.stored else { continue }
                try db.execute("INSERT OR IGNORE INTO snippet_targets (snippet_id, target_type, target_id) VALUES (?, ?, ?)",
                               [snippet.id, stored.type, stored.id])
            }
        }
    }

    public func deleteSnippet(_ id: String) async throws {
        try await db.transaction { @Sendable db in
            try db.execute("DELETE FROM snippet_targets WHERE snippet_id = ?", [id])
            try db.execute("DELETE FROM snippets WHERE id = ?", [id])
        }
    }
}
