import Foundation
import Testing
@testable import LowtideKit

@Suite struct RemoteSSHTests {
    let plain = SSHEndpoint(host: "10.0.0.5", port: 2222, user: "ops")

    @Test func rejectsOptionLikeDestinations() {
        #expect(throws: (any Error).self) { try SSHCommand.validate(user: "-oProxyCommand=sh", host: "host") }
        #expect(throws: (any Error).self) { try SSHCommand.validate(user: "root", host: "-host") }
        #expect(throws: (any Error).self) { try SSHCommand.validate(user: "ro ot", host: "host") }
        #expect(throws: (any Error).self) { try SSHCommand.validate(user: "a@b", host: "host") }
        #expect(throws: (any Error).self) { try SSHCommand.interactive(SSHEndpoint(host: "h", port: 0, user: "u")) }
        #expect((try? SSHCommand.validate(user: "root", host: "10.0.0.1")) != nil)
    }

    @Test func buildsInteractiveSessions() throws {
        let args = try SSHCommand.interactive(plain)
        #expect(args.first == "-tt")
        #expect(args.suffix(2) == ["--", "ops@10.0.0.5"])
        #expect(args.contains("StrictHostKeyChecking=accept-new") && args.contains("2222"))
        let keyed = try SSHCommand.interactive(SSHEndpoint(host: "h", user: "u", identityPath: "~/.ssh/id_x"), forwardAgent: true)
        #expect(keyed.contains("-A") && keyed.contains(Paths.home.path + "/.ssh/id_x") && keyed.contains("IdentitiesOnly=yes"))
        let snippet = try SSHCommand.interactive(plain, remoteCommand: "uptime")
        #expect(snippet.last?.hasPrefix("uptime\n__lowtide_status=$?") == true)
        #expect(snippet.last?.hasSuffix("exec \"${SHELL:-/bin/sh}\" -l") == true)
    }

    @Test func jumpsWithProxyJumpOrTheJumpHostsOwnKey() throws {
        var endpoint = plain
        endpoint.jump = SSHEndpoint.Jump(host: "bastion", port: 22, user: "j")
        let args = try SSHCommand.interactive(endpoint)
        #expect(args.contains("-J") && args.contains("j@bastion:22"))
        endpoint.jump?.identityPath = "/keys/100% jump"
        let keyed = try SSHCommand.interactive(endpoint)
        #expect(!keyed.contains("-J"))
        let proxy = try #require(keyed.first { $0.hasPrefix("ProxyCommand=") })
        #expect(proxy.contains("'-i' '/keys/100%% jump'"))
        #expect(proxy.contains("'-W' %h:%p") && proxy.hasSuffix("'--' 'j@bastion'"))
        endpoint.jump = SSHEndpoint.Jump(host: "-evil", user: "j")
        #expect(throws: (any Error).self) { try SSHCommand.interactive(endpoint) }
    }

    @Test func buildsTunnels() throws {
        let forward = PortForward(name: "db", hostID: "h", kind: .local, bindHost: "", bindPort: 5433, targetHost: "db.internal", targetPort: 5432)
        #expect(forward.spec == "127.0.0.1:5433:db.internal:5432")
        #expect(forward.route == ":5433 → db.internal:5432")
        let args = try SSHCommand.tunnel(plain, forward: forward, batch: true)
        #expect(args.contains("-N") && args.contains("ExitOnForwardFailure=yes") && args.contains("BatchMode=yes"))
        #expect(!args.contains("-tt"))
        let dash = args.firstIndex(of: "--")!
        #expect(args[dash - 2] == "-L" && args[dash - 1] == "127.0.0.1:5433:db.internal:5432")
        let socks = PortForward(name: "s", hostID: "h", kind: .dynamic, bindPort: 1080)
        let socksArgs = try SSHCommand.tunnel(plain, forward: socks, batch: false)
        #expect(socksArgs.contains("-D"))
        #expect(socks.spec == "127.0.0.1:1080" && socks.route == ":1080")
        let remote = PortForward(name: "r", hostID: "h", kind: .remote, bindHost: "0.0.0.0", bindPort: 8080, targetPort: 3000)
        #expect(remote.spec == "0.0.0.0:8080:127.0.0.1:3000" && remote.flag == "-R")
        let bad = PortForward(name: "b", hostID: "h", kind: .local, bindHost: "a b", bindPort: 1, targetPort: 2)
        #expect(throws: (any Error).self) { try SSHCommand.tunnel(plain, forward: bad, batch: true) }
        #expect(throws: (any Error).self) {
            try SSHCommand.tunnel(plain, forward: PortForward(name: "x", hostID: "h", kind: .local, bindPort: 70_000), batch: true)
        }
    }

    @Test func buildsProbesThatFitTheSocketLimit() throws {
        var endpoint = plain
        endpoint.jump = SSHEndpoint.Jump(host: "bastion", user: "j")
        let control = try Fleet.controlPath(endpoint)
        // ssh's temporary name while creating the socket must fit sun_path.
        #expect(control.utf8.count + 17 < 104)
        let again = try Fleet.controlPath(endpoint)
        #expect(again == control)
        let args = try SSHCommand.probe(endpoint, controlPath: control, batch: true)
        #expect(args.contains("BatchMode=yes") && !args.contains("-tt"))
        #expect(args.suffix(2) == ["ops@10.0.0.5", "sh -s"])
        let interactive = try SSHCommand.probe(endpoint, controlPath: control, batch: false)
        #expect(!interactive.contains("BatchMode=yes"))
    }

    @Test func managesKeysOnHosts() throws {
        let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl me@mac"
        let parsed = try #require(SSHCommand.parsePublicKey(key))
        #expect(parsed.type == "ssh-ed25519" && parsed.comment == "me@mac")
        #expect(SSHCommand.parsePublicKey("ssh-ed25519 not;base64") == nil)
        #expect(SSHCommand.parsePublicKey("evil AAAA") == nil)
        let install = try SSHCommand.installKey(plain, publicKey: key)
        let script = try #require(install.last)
        #expect(script.hasPrefix("sh -c '"))
        #expect(script.contains("AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"))
        #expect(install.contains("--") && install.contains("ops@10.0.0.5"))
        let remove = try SSHCommand.removeKey(plain, publicKey: key)
        #expect(remove.last?.contains("awk") == true)
        #expect(throws: (any Error).self) { try SSHCommand.installKey(plain, publicKey: "garbage") }
    }

    @Test func installScriptRunsInAPOSIXShell() async throws {
        // The script itself, run locally against a temporary HOME.
        let home = FileManager.default.temporaryDirectory.appending(path: "lowtide-ak-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl it's me"
        let install = try #require(try SSHCommand.installKey(plain, publicKey: key).last)
        let remove = try #require(try SSHCommand.removeKey(plain, publicKey: key).last)
        for _ in 0..<2 {
            let out = try await Shell.run("/bin/sh", ["-c", install], environment: ["HOME": home.path])
            #expect(out.ok)
        }
        let file = home.appending(path: ".ssh/authorized_keys")
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines == [Substring(key)])
        let out = try await Shell.run("/bin/sh", ["-c", remove], environment: ["HOME": home.path])
        let left = try String(contentsOf: file, encoding: .utf8)
        #expect(out.ok && left.isEmpty)
    }

    @Test func parsesQuickConnectTargets() {
        #expect(SSHCommand.parseTarget("root@1.2.3.4")! == ("root", "1.2.3.4", 22))
        #expect(SSHCommand.parseTarget("ubuntu@server.example.com:2222")! == ("ubuntu", "server.example.com", 2222))
        #expect(SSHCommand.parseTarget("me@[::1]:2200")! == ("me", "::1", 2200))
        #expect(SSHCommand.parseTarget("me@fe80::1")! == ("me", "fe80::1", 22))
        #expect(SSHCommand.parseTarget("host")! == ("", "host", 22))
        #expect(SSHCommand.parseTarget("me@host:99999") == nil)
        #expect(SSHCommand.parseTarget("me@host:abc") == nil)
        #expect(SSHCommand.parseTarget("me @host") == nil)
        #expect(SSHCommand.parseTarget("") == nil)
    }

    @Test func namesGeneratedKeys() throws {
        #expect(try SSHKeys.fileName(for: "Production API") == "id_production-api")
        #expect(throws: (any Error).self) { try SSHKeys.fileName(for: "...") }
    }

    @Test func generatesKeysWithAPassphraseOutsideArgv() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "lowtide-keygen-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = try await SSHKeys.generate(name: "Test", type: .ed25519, passphrase: "s3cret pass", directory: dir)
        #expect(key.path.hasSuffix("/id_test") && key.publicKey.hasPrefix("ssh-ed25519 "))
        #expect(key.fingerprint.hasPrefix("SHA256:"))
        func unlocks(_ pass: String) async throws -> Bool {
            try await Shell.run("/usr/bin/ssh-keygen", ["-y", "-P", pass, "-f", key.path]).ok
        }
        let right = try await unlocks("s3cret pass")
        let wrong = try await unlocks("wrong")
        #expect(right && !wrong)
        #expect(SSHKeys.found(in: dir).map(\.name) == ["id_test"])
        await #expect(throws: (any Error).self) { _ = try await SSHKeys.generate(name: "Test", type: .ed25519, passphrase: "", directory: dir) }
        let inspected = try await SSHKeys.inspect(key.path)
        #expect(inspected.publicKey == key.publicKey && inspected.fingerprint == key.fingerprint)
        // Only private keys in the folder given, to the Trash.
        await #expect(throws: (any Error).self) { try await SSHKeys.trash(key.path + ".pub", directory: dir) }
        await #expect(throws: (any Error).self) { try await SSHKeys.trash(key.path, directory: dir.appending(path: "other")) }
    }
}

@Suite struct RemoteResolutionTests {
    let key = Identity(id: "k", name: "deploy", kind: .sshKey, keyPath: "~/.ssh/id_deploy", hasPassphrase: true)
    let password = Identity(id: "p", name: "prod pw", kind: .password, username: "root")
    var groups: [HostGroup] {
        [HostGroup(id: "prod", name: "Production", identityID: "k", jumpHostID: "bastion"),
         HostGroup(id: "api", name: "API", parentID: "prod"),
         HostGroup(id: "loop1", name: "L1", parentID: "loop2"),
         HostGroup(id: "loop2", name: "L2", parentID: "loop1")]
    }
    var hosts: [RemoteHost] {
        [RemoteHost(id: "bastion", name: "Bastion", hostname: "bastion.example", username: "jump", identityID: "p"),
         RemoteHost(id: "api1", name: "api-1", hostname: "10.1.0.1", username: "ops", groupID: "api"),
         RemoteHost(id: "own", name: "own", hostname: "own.example", username: "me", identityID: "p", jumpHostID: nil, groupID: "api"),
         RemoteHost(id: "lost", name: "lost", hostname: "l", username: "u", groupID: "loop1")]
    }
    var resolution: HostResolution { HostResolution(hosts: hosts, groups: groups, identities: [key, password]) }

    @Test func cascadesCredentialsAndJumpHostsThroughNestedGroups() {
        let api1 = hosts[1]
        #expect(resolution.identity(for: api1)?.id == "k")
        #expect(resolution.identitySource(for: api1)?.id == "prod")
        #expect(resolution.jumpHost(for: api1)?.id == "bastion")
        let endpoint = resolution.endpoint(for: api1)
        #expect(endpoint.identityPath == "~/.ssh/id_deploy" && endpoint.jump?.host == "bastion.example")
        // A password jump host has no key to pass.
        #expect(endpoint.jump?.identityPath == nil)
        // Its own credential wins; the jump still comes from the group.
        #expect(resolution.identity(for: hosts[2])?.id == "p" && resolution.identitySource(for: hosts[2]) == nil)
        #expect(resolution.jumpHost(for: hosts[2])?.id == "bastion")
        // The jump host never jumps through itself.
        #expect(resolution.jumpHost(for: hosts[0]) == nil)
        // Loops end.
        #expect(resolution.identity(for: hosts[3]) == nil && resolution.groupChain("loop1").count == 2)
    }

    @Test func collectsTheSecretsOnTheWay() {
        let secrets = resolution.secrets(for: hosts[1])
        #expect(secrets == [
            AskpassSecret(kind: .passphrase, match: Paths.home.path + "/.ssh/id_deploy", account: "identity:k:passphrase"),
            AskpassSecret(kind: .password, match: "jump@bastion.example", account: "identity:p:password"),
        ])
    }

    @Test func resolvesSnippetTargets() {
        let r = resolution
        #expect(SnippetRuns.hosts(for: [.group("prod")], in: r).map(\.id) == ["api1", "own"])
        #expect(SnippetRuns.hosts(for: [.host("bastion"), .group("api")], in: r).map(\.id) == ["bastion", "api1", "own"])
        #expect(SnippetRuns.hosts(for: [.allHosts], in: r).count == 4)
        #expect(SnippetRuns.hosts(for: [.local], in: r).isEmpty)
        #expect(SnippetRuns.summary([], in: r) == "Choose targets when running")
        #expect(SnippetRuns.summary([.local, .group("api")], in: r) == "Local · 2 hosts")
        #expect(SnippetRuns.summary([.allHosts], in: r) == "All hosts (4)")
        var picked = SnippetRuns.toggle(.host("api1"), in: [.local])
        #expect(picked == [.local, .host("api1")])
        picked = SnippetRuns.toggle(.allHosts, in: picked)
        #expect(picked == [.local, .allHosts])
        picked = SnippetRuns.toggle(.group("api"), in: picked)
        #expect(picked == [.local, .group("api")])
        #expect(SnippetRuns.toggle(.local, in: picked) == [.group("api")])
    }

    @Test func runsSnippetsLocally() async {
        let ok = await SnippetRuns.runLocally("echo hi; echo oops >&2")
        #expect(ok.state == .succeeded && ok.output == "hi\noops")
        let failed = await SnippetRuns.runLocally("exit 3")
        #expect(failed.state == .failed(3))
        let failedRemote = await SnippetRuns.runRemotely("uptime", endpoint: SSHEndpoint(host: "-x", user: "u"), secrets: [], label: "x")
        if case .couldNotStart = failedRemote.state {} else { Issue.record("expected couldNotStart") }
    }
}

@Suite struct RemoteVaultTests {
    func vault() throws -> RemoteVault {
        let url = FileManager.default.temporaryDirectory.appending(path: "lowtide-\(UUID()).db")
        return RemoteVault(db: try SQLiteDatabase(url: url, migrations: Vault.migrations))
    }

    @Test func savesAndCascadesDeletes() async throws {
        let v = try vault()
        let identity = Identity(id: "i1", name: "key", kind: .sshKey, keyPath: "~/.ssh/id")
        try await v.create(identity, secret: nil)
        try await v.save(HostGroup(id: "g1", name: "Prod", identityID: "i1"))
        try await v.save(HostGroup(id: "g2", name: "API", parentID: "g1"))
        try await v.save(RemoteHost(id: "j", name: "Jump", hostname: "j.example", username: "u"))
        try await v.save(RemoteHost(id: "h", name: "Web", hostname: "w.example", username: "u", identityID: "i1", jumpHostID: "j", groupID: "g2"))
        try await v.save(PortForward(id: "f", name: "db", hostID: "h", kind: .local, bindPort: 5433, targetPort: 5432, autoStart: true))
        try await v.save(Snippet(id: "s", name: "up", content: "uptime", targets: [.host("h"), .group("g2"), .local, .active]))
        var snapshot = try await v.load()
        #expect(snapshot.hosts.count == 2 && snapshot.forwards.first?.autoStart == true)
        #expect(snapshot.snippets.first?.targets == [.host("h"), .group("g2"), .local])
        try await v.touchHost("h")
        let first = try await v.hosts().first?.id
        #expect(first == "h")

        // Deleting the group lifts its children to the top level.
        try await v.deleteGroup("g2")
        snapshot = try await v.load()
        #expect(snapshot.hosts.first { $0.id == "h" }?.groupID == nil)
        #expect(snapshot.snippets.first?.targets == [.host("h"), .local])

        // Deleting the jump host clears the jump; deleting a host takes its forwards.
        try await v.deleteHost("j")
        let jump = try await v.hosts().first { $0.id == "h" }?.jumpHostID
        #expect(jump == nil)
        let gone = try await v.deleteHost("h")
        #expect(gone == ["f"])
        snapshot = try await v.load()
        #expect(snapshot.forwards.isEmpty && snapshot.snippets.first?.targets == [.local])

        try await v.deleteIdentity("i1")
        let groupIdentity = try await v.groups().first?.identityID
        #expect(groupIdentity == nil)
        try await v.deleteSnippet("s")
        let snippets = try await v.snippets()
        #expect(snippets.isEmpty)
    }

    @Test func upsertsInPlace() async throws {
        let v = try vault()
        var host = RemoteHost(id: "h", name: "Web", hostname: "w", username: "u")
        try await v.save(host)
        host.name = "Web 2"
        host.port = 2222
        host.jumpHostID = "h" // never itself
        try await v.save(host)
        let saved = try await v.hosts()
        #expect(saved.count == 1 && saved[0].name == "Web 2" && saved[0].port == 2222 && saved[0].jumpHostID == nil)
        var forward = PortForward(id: "f", name: "x", hostID: "h", kind: .local, bindPort: 1, targetHost: "t", targetPort: 2)
        try await v.save(forward)
        forward.kind = .dynamic
        try await v.save(forward)
        let f = try await v.forwards()
        #expect(f.count == 1 && f[0].kind == .dynamic && f[0].targetHost == nil)
    }
}
