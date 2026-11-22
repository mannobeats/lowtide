import Darwin
import Foundation
import os

/// A saved secret ssh may ask for during one connection.
public struct AskpassSecret: Equatable, Sendable {
    public enum Kind: Sendable { case password, passphrase }
    public var kind: Kind
    /// `user@host` for a password, the private key's path for a passphrase.
    public var match: String
    /// The Keychain account that holds it.
    public var account: String

    public init(kind: Kind, match: String, account: String) {
        self.kind = kind
        self.match = match
        self.account = account
    }
}

/// What ssh asked for, read from its prompt.
public enum AskpassPrompt: Equatable, Sendable {
    case password(destination: String?)
    case passphrase(keyPath: String?)
    /// "Are you sure you want to continue connecting (yes/no)?"
    case confirmation
    /// Anything else: a one-time code, a PIN.
    case other

    public static func classify(_ prompt: String) -> AskpassPrompt {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if lower.contains("(yes/no") { return .confirmation }
        if lower.contains("passphrase") {
            // `Enter passphrase for key '/Users/me/.ssh/id_ed25519':`
            if let open = text.firstIndex(of: "'"), let close = text.lastIndex(of: "'"), open < close {
                return .passphrase(keyPath: String(text[text.index(after: open)..<close]))
            }
            if let range = text.range(of: "passphrase for ", options: .caseInsensitive) {
                let path = text[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: ": "))
                return .passphrase(keyPath: path.isEmpty ? nil : path)
            }
            return .passphrase(keyPath: nil)
        }
        guard lower.hasSuffix("password:") || lower.hasSuffix("password: ") || lower.contains("'s password") else {
            return .other
        }
        // `me@host's password:` or `(me@host) Password:`.
        if text.hasPrefix("("), let close = text.firstIndex(of: ")") {
            return .password(destination: String(text[text.index(after: text.startIndex)..<close]))
        }
        if let range = text.range(of: "'s password") {
            return .password(destination: String(text[..<range.lowerBound]))
        }
        return .password(destination: nil)
    }

    /// The saved secret that answers this prompt, if one clearly does.
    public func secret(in secrets: [AskpassSecret]) -> AskpassSecret? {
        switch self {
        case .password(let destination):
            let passwords = secrets.filter { $0.kind == .password }
            if let destination, let hit = passwords.first(where: { $0.match.lowercased() == destination.lowercased() }) { return hit }
            return passwords.count == 1 ? passwords[0] : nil
        case .passphrase(let path):
            let keys = secrets.filter { $0.kind == .passphrase }
            if let path, let hit = keys.first(where: { $0.match == SSHCommand.expandHome(path) }) { return hit }
            return keys.count == 1 ? keys[0] : nil
        case .confirmation, .other:
            return nil
        }
    }
}

/// A question ssh asked that no saved secret answers: the app shows it.
public struct AskpassRequest: Sendable {
    public var prompt: String
    /// What the connection is for ("prod-api", "Forward db").
    public var label: String
    /// A saved secret was already sent for this prompt and ssh asked again.
    public var retry: Bool
}

/// Hands saved passwords and key passphrases from the Keychain to ssh.
///
/// ssh runs `SSH_ASKPASS` for every secret it needs. Ours is a three-line
/// shell script that asks this running app over a Unix socket; the app
/// checks that the asking process descends from an ssh it started itself
/// (and the connection's one-time token), reads the Keychain in-process and
/// answers. Secrets never touch argv, the environment or a file, the
/// Keychain item's access list stays "this app only", and a prompt no saved
/// secret answers (a one-time code) becomes a native dialog in the app.
public final class AskpassServer: Sendable {
    public static let shared = AskpassServer()

    struct Registration {
        var secrets: [AskpassSecret]
        var interactive: Bool
        var label: String
        var rootPID: pid_t?
        var answered: Set<String> = []
    }

    private struct State {
        var registrations: [String: Registration] = [:]
        var listener: Int32 = -1
        var prompter: (@Sendable (AskpassRequest) async -> String?)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public let directory: URL
    public var socketPath: String { directory.appending(path: "\(getpid()).sock").path }
    public var scriptURL: URL { directory.appending(path: "askpass-\(getpid()).sh") }

    init(directory: URL = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "lowtide-askpass")) {
        self.directory = directory
    }

    static let script = """
        #!/bin/sh
        # Lowtide: asks the running app for the secret ssh wants. Nothing is stored here.
        p=$(printf '%s' "$1" | /usr/bin/base64 | /usr/bin/tr -d '\\n')
        r=$(printf '%s %s\\n' "$LOWTIDE_ASKPASS_TOKEN" "$p" | /usr/bin/nc -U "$LOWTIDE_ASKPASS_SOCKET") || exit 1
        case "$r" in "OK "*) printf '%s' "${r#OK }" | /usr/bin/base64 -D ;; *) exit 1 ;; esac

        """

    /// The handler for prompts no saved secret answers (set by the app).
    public func setPrompter(_ prompter: @escaping @Sendable (AskpassRequest) async -> String?) {
        state.withLock { $0.prompter = prompter }
    }

    // MARK: Lifecycle

    /// Opens the socket. Safe to call more than once.
    public func start() throws {
        if state.withLock({ $0.listener }) >= 0 { return }
        try makePrivateDirectory()
        let path = socketPath
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LowtideError.commandFailed("askpass socket: \(String(cString: strerror(errno)))") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else {
            close(fd)
            throw LowtideError.invalid("askpass socket path is too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw LowtideError.commandFailed("askpass socket: \(message)")
        }
        state.withLock { $0.listener = fd }
        let thread = Thread { [self] in acceptLoop(fd) }
        thread.name = "askpass"
        thread.start()
    }

    public func stop() {
        let fd = state.withLock { s -> Int32 in
            let fd = s.listener
            s.listener = -1
            s.registrations = [:]
            return fd
        }
        guard fd >= 0 else { return }
        shutdown(fd, SHUT_RDWR)
        close(fd)
        unlink(socketPath)
        try? FileManager.default.removeItem(at: scriptURL)
    }

    private func makePrivateDirectory() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0 else {
            throw LowtideError.denied("\(directory.path) is not a private folder")
        }
    }

    /// Writes the script again if anything changed it.
    private func ensureScript() throws {
        try makePrivateDirectory()
        let url = scriptURL
        let data = Data(Self.script.utf8)
        if (try? Data(contentsOf: url)) != data {
            try? FileManager.default.removeItem(at: url)
            try data.write(to: url, options: .atomic)
        }
        chmod(url.path, 0o500)
    }

    // MARK: Connections

    /// Registers a connection about to start and returns the environment to
    /// give its ssh. Call `attach` with the process id once it runs.
    public func register(secrets: [AskpassSecret], interactive: Bool, label: String) throws -> (token: String, environment: [String: String]) {
        try start()
        try ensureScript()
        var bytes = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw LowtideError.commandFailed("No randomness for the askpass token")
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        state.withLock { $0.registrations[token] = Registration(secrets: secrets, interactive: interactive, label: label) }
        return (token, [
            "SSH_ASKPASS": scriptURL.path, "SSH_ASKPASS_REQUIRE": "force",
            "LOWTIDE_ASKPASS_SOCKET": socketPath, "LOWTIDE_ASKPASS_TOKEN": token,
        ])
    }

    /// Roots a registration at the ssh Lowtide started. Only a process of
    /// our own can be a root: launchd (pid 1), or anything above us, would
    /// make every process on the Mac a descendant.
    public func attach(_ token: String, pid: pid_t) {
        guard pid > 1, pid != getpid(), Self.descends(pid, from: getpid()) else { return }
        state.withLock { $0.registrations[token]?.rootPID = pid }
    }

    public func unregister(_ token: String) {
        _ = state.withLock { $0.registrations.removeValue(forKey: token) }
    }

    private func acceptLoop(_ listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, [Int32(1)], socklen_t(MemoryLayout<Int32>.size))
            let peer = Self.peerPID(client)
            let line = Self.readLine(client)
            Task.detached { [self] in
                let answer = await respond(line: line, peer: peer)
                let reply = answer.map { "OK " + Data($0.utf8).base64EncodedString() + "\n" } ?? "NO\n"
                _ = reply.withCString { send(client, $0, strlen($0), 0) }
                close(client)
            }
        }
    }

    static func peerPID(_ fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0 else { return nil }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return nil }
        return pid
    }

    static func readLine(_ fd: Int32) -> String {
        var data = Data()
        var byte: UInt8 = 0
        while data.count < 16_384, recv(fd, &byte, 1, 0) == 1 {
            if byte == 0x0A { break }
            data.append(byte)
        }
        return String(decoding: data, as: UTF8.self)
    }

    func respond(line: String, peer: pid_t?) async -> String? {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, let peer,
              let promptData = Data(base64Encoded: parts[1]) else { return nil }
        let token = parts[0]
        let prompt = String(decoding: promptData, as: UTF8.self)
        // A request can race the process id being recorded: wait a moment.
        var registration: Registration?
        for _ in 0..<20 {
            registration = state.withLock { $0.registrations[token] }
            if registration?.rootPID != nil { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let registration, let root = registration.rootPID, Self.descends(peer, from: root) else {
            Log.terminal.error("askpass request refused")
            return nil
        }
        let kind = AskpassPrompt.classify(prompt)
        if kind == .confirmation { return nil }
        let key = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let retry = registration.answered.contains(key)
        if !retry, let secret = kind.secret(in: registration.secrets), let value = Keychain.get(secret.account) {
            state.withLock { _ = $0.registrations[token]?.answered.insert(key) }
            return value
        }
        guard registration.interactive, let prompter = state.withLock({ $0.prompter }) else { return nil }
        return await prompter(AskpassRequest(prompt: key, label: registration.label, retry: retry))
    }

    // MARK: Process ancestry

    static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }

    /// The askpass script (and `nc`) run under the ssh that needs the secret,
    /// sometimes through a proxy command's shell: a few levels at most.
    static func descends(_ pid: pid_t, from root: pid_t, maxDepth: Int = 8) -> Bool {
        var current: pid_t? = pid
        for _ in 0...maxDepth {
            guard let pid = current else { return false }
            if root <= 1 { return false }
            if pid == root { return true }
            if pid <= 1 { return false }
            current = parent(of: pid)
        }
        return false
    }
}
