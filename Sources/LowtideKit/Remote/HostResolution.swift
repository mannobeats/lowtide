import Foundation

/// How a saved host is reached: its own credential and jump host, else the
/// nearest group's up the chain (groups nest).
public struct HostResolution: Sendable {
    public var hosts: [RemoteHost]
    public var groups: [HostGroup]
    public var identities: [Identity]

    public init(hosts: [RemoteHost], groups: [HostGroup], identities: [Identity]) {
        self.hosts = hosts
        self.groups = groups
        self.identities = identities
    }

    public init(_ snapshot: RemoteVault.Snapshot) {
        self.init(hosts: snapshot.hosts, groups: snapshot.groups, identities: snapshot.identities)
    }

    /// The host's group and its ancestors, nearest first. Stops at a loop.
    public func groupChain(_ groupID: String?) -> [HostGroup] {
        var chain: [HostGroup] = []
        var seen = Set<String>()
        var next = groupID
        while let id = next, seen.insert(id).inserted, let group = groups.first(where: { $0.id == id }) {
            chain.append(group)
            next = group.parentID
        }
        return chain
    }

    public func identity(for host: RemoteHost) -> Identity? {
        if let own = host.identityID.flatMap({ id in identities.first { $0.id == id } }) { return own }
        for group in groupChain(host.groupID) {
            if let id = group.identityID { return identities.first { $0.id == id } }
        }
        return nil
    }

    /// Where the credential comes from, for the UI ("From Production").
    public func identitySource(for host: RemoteHost) -> HostGroup? {
        if host.identityID.flatMap({ id in identities.first { $0.id == id } }) != nil { return nil }
        return groupChain(host.groupID).first { $0.identityID != nil }
    }

    public func jumpHost(for host: RemoteHost) -> RemoteHost? {
        let id = host.jumpHostID ?? groupChain(host.groupID).lazy.compactMap(\.jumpHostID).first
        guard let id, id != host.id else { return nil }
        return hosts.first { $0.id == id }
    }

    /// Everything ssh needs to reach the host.
    public func endpoint(for host: RemoteHost) -> SSHEndpoint {
        let identity = identity(for: host)
        let jump = jumpHost(for: host).map { jump -> SSHEndpoint.Jump in
            let jumpIdentity = self.identity(for: jump)
            return SSHEndpoint.Jump(host: jump.hostname, port: jump.port, user: jump.username,
                                    identityPath: jumpIdentity?.kind == .sshKey ? jumpIdentity?.keyPath : nil)
        }
        return SSHEndpoint(host: host.hostname, port: host.port, user: host.username,
                           identityPath: identity?.kind == .sshKey ? identity?.keyPath : nil, jump: jump)
    }

    /// The Keychain secrets ssh may ask for on the way to this host: the
    /// host's password or key passphrase, and the jump host's.
    public func secrets(for host: RemoteHost) -> [AskpassSecret] {
        var out: [AskpassSecret] = []
        func add(_ identity: Identity?, user: String, host hostname: String) {
            guard let identity, let account = identity.secretAccount else { return }
            switch identity.kind {
            case .password: out.append(AskpassSecret(kind: .password, match: "\(user)@\(hostname)", account: account))
            case .sshKey: out.append(AskpassSecret(kind: .passphrase, match: identity.keyPath.map(SSHCommand.expandHome) ?? "",
                                                   account: account))
            }
        }
        add(identity(for: host), user: host.username, host: host.hostname)
        if let jump = jumpHost(for: host) { add(identity(for: jump), user: jump.username, host: jump.hostname) }
        return out
    }

    /// Every host in these groups and their subgroups.
    public func hosts(inGroups ids: Set<String>) -> [RemoteHost] {
        var selected = ids
        var changed = true
        while changed {
            changed = false
            for group in groups where group.parentID.map(selected.contains) == true && !selected.contains(group.id) {
                selected.insert(group.id)
                changed = true
            }
        }
        return hosts.filter { $0.groupID.map(selected.contains) == true }
    }
}
