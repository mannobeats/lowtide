import Foundation
import Testing
@testable import LowtideKit

@Suite struct RemoteFleetTests {
    static let linux = """
        @@host
        web-1
        @@os
        Linux 6.8.0-45-generic
        @@uptime
        1234567.89
        @@load
        0.52 0.58 0.59 1/389 12345
        @@cpus
        4
        @@mem
        MemTotal:        8039920 kB
        MemAvailable:    5120000 kB
        @@disk
        /dev/sda1         81106868 76000000  5090000      94% /
        @@listen
        tcp   LISTEN 0      4096         0.0.0.0:22        0.0.0.0:*    users:(("sshd",pid=812,fd=3))
        tcp   LISTEN 0      511             [::]:80           [::]:*    users:(("nginx",pid=1001,fd=7),("nginx",pid=1000,fd=7))
        udp   UNCONN 0      0      127.0.0.53%lo:53        0.0.0.0:*    users:(("systemd-resolve",pid=500,fd=13))
        tcp   LISTEN 0      4096               *:9100            *:*
        @@peers
        0      0         10.0.0.5:22     203.0.113.9:51234 users:(("sshd",pid=1234,fd=4))
        0      0         10.0.0.5:443    198.51.100.7:40000 users:(("nginx",pid=1001,fd=12))
        0      0         10.0.0.5:443    198.51.100.7:40001 users:(("nginx",pid=1001,fd=13))
        0      0   [::ffff:10.0.0.5]:5432 [::ffff:127.0.0.1]:3333
        @@users
        root     pts/0        2024-05-01 10:11 (203.0.113.9)
        deploy   tty1         2024-05-01 09:00
        @@failed
        37
        @@end

        """

    @Test func parsesALinuxSnapshot() throws {
        let s = Fleet.parse(Self.linux)
        #expect(s.hostname == "web-1" && s.os == "Linux 6.8.0-45-generic")
        #expect(s.uptime == 1_234_567 && s.load == [0.52, 0.58, 0.59] && s.cpus == 4)
        #expect(s.memTotal == 8_039_920 * 1024 && s.memAvailable == 5_120_000 * 1024)
        #expect(s.diskTotal == 81_106_868 * 1024 && (s.diskShare ?? 0) > 0.9)
        #expect(s.listeners.count == 4 && s.listeners[0].port == 22 && s.listeners[0].process == "sshd")
        let dns = try #require(s.listeners.first { $0.port == 53 })
        #expect(dns.proto == "udp" && dns.address == "127.0.0.53")
        #expect(s.listeners.first { $0.port == 80 }?.address == "::")
        #expect(s.listeners.contains { $0.port == 9100 && $0.process == nil })
        #expect(s.peers.count == 2, "loopback dropped, same ip folded")
        #expect(s.peers[0].ip == "198.51.100.7" && s.peers[0].count == 2 && s.peers[0].localPort == 443)
        #expect(s.users.count == 2 && s.users[0].from == "203.0.113.9" && s.users[1].since == "2024-05-01 09:00")
        #expect(s.failedLogins == 37)
        #expect(abs((s.loadShare ?? 0) - 0.13) < 1e-9)
    }

    @Test func parsesNetstatAndMacOS() {
        let out = "@@host\nmini\n@@os\nDarwin 24.0.0\n@@uptime\n5000\n@@load\n{ 1.20 1.31 1.40 }\n@@cpus\n8\n@@mem\n@@listen\ntcp        0      0 0.0.0.0:22              0.0.0.0:*               LISTEN      812/sshd: /usr/sbin\ntcp6       0      0 :::8080                 :::*                    LISTEN      99/java\n@@peers\ntcp        0      0 10.0.0.5:22       203.0.113.9:50000    ESTABLISHED 1234/sshd: root\n@@users\n@@failed\n@@end\n"
        let s = Fleet.parse(out)
        #expect(s.load == [1.2, 1.31, 1.4] && s.memTotal == nil && s.failedLogins == nil)
        #expect(s.listeners[0].process == "sshd" && s.listeners[1].address == "::" && s.listeners[1].port == 8080)
        #expect(s.peers[0].ip == "203.0.113.9" && s.peers[0].process == "sshd")
        let busy = Array(repeating: "tcp 0 0 10.0.0.5:443 198.51.100.7:50000 ESTABLISHED 9/nginx", count: 20_000)
        let peers = Fleet.parsePeers(busy)
        #expect(peers.count == 1 && peers[0].count == 20_000)
    }

    @Test func learnsThenFlags() {
        var known = Fleet.Known()
        var s = Fleet.parse(Self.linux)
        s.countries = ["DE"]
        for _ in 0..<Fleet.learningProbes { #expect(Fleet.learn(&known, s).isEmpty) }
        #expect(Fleet.learn(&known, s).isEmpty, "nothing new")
        s.listeners.append(Fleet.Listener(proto: "tcp", address: "0.0.0.0", port: 4444, process: "nc"))
        s.listeners.append(Fleet.Listener(proto: "tcp", address: "127.0.0.1", port: 6379, process: nil))
        s.users.append(Fleet.Login(user: "mallory", tty: "", since: "", from: nil))
        s.countries.append("RU")
        let events = Fleet.learn(&known, s)
        #expect(events.map(\.0) == [.alert, .alert, .notice])
        #expect(events[0].1.contains("4444"))
    }

    @Test func thresholdsFireOnce() {
        let s = Fleet.parse(Self.linux)
        #expect(Fleet.thresholds(nil, s).count == 2)
        #expect(Fleet.thresholds(s, s).isEmpty)
    }

    @Test func classifiesFailures() {
        if case .needsKey = Fleet.classify(status: 255, stdout: "", stderr: "user@h: Permission denied (publickey,password).\n") {} else {
            Issue.record("expected needsKey")
        }
        #expect(Fleet.classify(status: 255, stdout: "", stderr: "ssh: connect to host h port 22: Operation timed out\n")
            == .unreachable("ssh: connect to host h port 22: Operation timed out"))
        #expect(Fleet.classify(status: 255, stdout: "", stderr: "") == .unreachable("ssh exited with 255"))
        if case .ok = Fleet.classify(status: 1, stdout: Self.linux, stderr: "") {} else { Issue.record("expected ok") }
    }

    @Test func monitorsAndReportsUnreachableHosts() async {
        let monitor = FleetMonitor()
        let target = Fleet.Target(id: "t", name: "Nowhere", endpoint: SSHEndpoint(host: "127.0.0.1", port: 1, user: "nobody"))
        await monitor.watch([target])
        #expect(await monitor.status().first?.state == .probing)
        let server = await monitor.probe(target)
        #expect(server?.state == .unreachable && server?.error?.isEmpty == false && server?.busy == false)
        await monitor.watch([])
        #expect(await monitor.status().isEmpty)
    }

    @Test func explainsTunnelFailures() {
        #expect(Tunnels.reason(["bind [127.0.0.1]:5433: Address already in use", "channel_setup_fwd_listener_tcpip: cannot listen to port: 5433"], code: 255)
            == "The port is already in use on this Mac")
        #expect(Tunnels.reason(["Warning: Permanently added 'x' (ED25519) to the list of known hosts.", "u@h: Permission denied (publickey)."], code: 255)
            == "Sign-in failed: give the host a key or a saved password")
        #expect(Tunnels.reason([], code: 255) == "ssh exited with 255")
    }

    @Test func reportsATunnelThatCannotConnect() async throws {
        let events = Events()
        let tunnels = Tunnels()
        tunnels.observe { id, status in events.add(id, status) }
        let forward = PortForward(id: "fw", name: "x", hostID: "h", kind: .local, bindPort: 45_999, targetPort: 80)
        try tunnels.start(forward, endpoint: SSHEndpoint(host: "127.0.0.1", port: 1, user: "nobody"), secrets: [], label: "x")
        for _ in 0..<100 where events.last == nil || events.last == .some(.starting) {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard case .failed(let reason)?? = events.last else {
            Issue.record("expected a failure, got \(String(describing: events.last))")
            return
        }
        #expect(!reason.isEmpty)
        tunnels.dismiss("fw")
        #expect(tunnels.status("fw") == nil)
    }

    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Tunnels.Status?] = []
        func add(_ id: String, _ status: Tunnels.Status?) { lock.withLock { items.append(status) } }
        var last: Tunnels.Status?? { lock.withLock { items.last } }
    }
}

@Suite struct RemoteAskpassTests {
    @Test func classifiesPrompts() {
        #expect(AskpassPrompt.classify("ops@10.0.0.5's password: ") == .password(destination: "ops@10.0.0.5"))
        #expect(AskpassPrompt.classify("(ops@host) Password: ") == .password(destination: "ops@host"))
        #expect(AskpassPrompt.classify("Password:") == .password(destination: nil))
        #expect(AskpassPrompt.classify("Enter passphrase for key '/Users/me/.ssh/id_ed25519': ")
            == .passphrase(keyPath: "/Users/me/.ssh/id_ed25519"))
        #expect(AskpassPrompt.classify("Enter passphrase for /Users/me/.ssh/id_rsa:") == .passphrase(keyPath: "/Users/me/.ssh/id_rsa"))
        #expect(AskpassPrompt.classify("Are you sure you want to continue connecting (yes/no/[fingerprint])? ") == .confirmation)
        #expect(AskpassPrompt.classify("(me@host) Verification code: ") == .other)
    }

    @Test func picksTheSecretThatAnswers() {
        let secrets = [
            AskpassSecret(kind: .password, match: "ops@web", account: "a"),
            AskpassSecret(kind: .password, match: "jump@bastion", account: "b"),
            AskpassSecret(kind: .passphrase, match: "/k/id", account: "c"),
        ]
        #expect(AskpassPrompt.password(destination: "jump@BASTION").secret(in: secrets)?.account == "b")
        #expect(AskpassPrompt.password(destination: nil).secret(in: secrets) == nil, "two passwords: ambiguous")
        #expect(AskpassPrompt.passphrase(keyPath: "/other").secret(in: secrets)?.account == "c", "the only key")
        #expect(AskpassPrompt.other.secret(in: secrets) == nil)
    }

    @Test func walksProcessAncestry() {
        #expect(AskpassServer.descends(getpid(), from: getpid()))
        #expect(AskpassServer.descends(getpid(), from: getppid()))
        #expect(!AskpassServer.descends(getppid(), from: getpid()))
        #expect(AskpassServer.parent(of: getpid()) == getppid())
    }

    /// The real script, `nc` and the socket: a saved secret reaches the
    /// asking process, a stranger's token gets nothing, and an unknown
    /// prompt goes to the app's prompter.
    @Test func answersThroughTheScript() async throws {
        let account = "lowtide-test-\(UUID().uuidString)"
        try Keychain.set("p@ss word'1", for: account)
        defer { Keychain.delete(account) }
        let dir = URL(fileURLWithPath: "/tmp").appending(path: "lowtide-ap-\(getpid())-\(Int.random(in: 0..<10_000))")
        let server = AskpassServer(directory: dir)
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: dir)
        }
        server.setPrompter { request in request.prompt.contains("code") ? "123456" : nil }
        let ticket = try server.register(secrets: [AskpassSecret(kind: .password, match: "ops@web", account: account)],
                                         interactive: true, label: "test")
        // Each prompt runs the real script as a child of its own "ssh" (a
        // shell the test starts), which is how ssh runs SSH_ASKPASS. `root`
        // is the registration rooted at that shell; nil leaves it unrooted.
        func ask(_ prompt: String, env: [String: String], root token: String?) async throws -> (ok: Bool, out: String) {
            let ssh = Process()
            ssh.executableURL = URL(fileURLWithPath: "/bin/sh")
            ssh.arguments = ["-c", "sleep 0.3; \"$0\" \"$1\"", server.scriptURL.path, prompt]
            ssh.environment = Shell.environment().merging(env) { _, new in new }
            let pipe = Pipe()
            ssh.standardOutput = pipe
            ssh.standardError = FileHandle.nullDevice
            // The exit arrives through terminationHandler: waitUntilExit can
            // hang on a background thread after the child has already gone.
            let (status, data): (Int32, Data) = try await withCheckedThrowingContinuation { continuation in
                ssh.terminationHandler = { process in
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(returning: (process.terminationStatus, data))
                }
                do { try ssh.run() } catch { continuation.resume(throwing: error); return }
                if let token { server.attach(token, pid: ssh.processIdentifier) }
            }
            return (status == 0, String(decoding: data, as: UTF8.self))
        }
        // The app itself, or launchd, can never be a root.
        server.attach(ticket.token, pid: getpid())
        server.attach(ticket.token, pid: 1)
        let unrooted = try await ask("ops@web's password: ", env: ticket.environment, root: nil)
        #expect(!unrooted.ok)
        let answer = try await ask("ops@web's password: ", env: ticket.environment, root: ticket.token)
        #expect(answer.ok && answer.out == "p@ss word'1")
        // Asked again for the same prompt: the saved one didn't work, so the app asks.
        let retry = try await ask("ops@web's password: ", env: ticket.environment, root: ticket.token)
        #expect(!retry.ok)
        let code = try await ask("(ops@web) Verification code: ", env: ticket.environment, root: ticket.token)
        #expect(code.ok && code.out == "123456")
        var stranger = ticket.environment
        stranger["LOWTIDE_ASKPASS_TOKEN"] = String(repeating: "0", count: 48)
        let strangerAnswer = try await ask("ops@web's password: ", env: stranger, root: ticket.token)
        #expect(!strangerAnswer.ok)
        // A process that knows a token but runs outside its ssh gets nothing.
        let other = try server.register(secrets: [AskpassSecret(kind: .password, match: "ops@web", account: account)],
                                        interactive: false, label: "other")
        let sibling = Process()
        sibling.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sibling.arguments = ["30"]
        try sibling.run()
        defer { sibling.terminate() }
        server.attach(other.token, pid: sibling.processIdentifier)
        let otherAnswer = try await ask("ops@web's password: ", env: other.environment, root: nil)
        #expect(!otherAnswer.ok)
        server.unregister(ticket.token)
        let gone = try await ask("(ops@web) Verification code: ", env: ticket.environment, root: ticket.token)
        #expect(!gone.ok)
    }
}
