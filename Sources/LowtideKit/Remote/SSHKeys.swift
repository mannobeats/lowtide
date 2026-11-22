import Darwin
import Foundation

/// SSH key files in `~/.ssh`: finding them, making them, reading them.
public enum SSHKeys {
    public enum KeyType: String, Sendable, CaseIterable { case ed25519, ecdsa, rsa }

    public struct Found: Equatable, Sendable, Identifiable {
        public var name: String
        public var path: String
        public var publicKey: String?
        public var id: String { path }
    }

    public struct Generated: Equatable, Sendable {
        public var path: String
        public var publicKey: String
        public var fingerprint: String
    }

    public struct Inspection: Equatable, Sendable {
        public var path: String
        public var publicKey: String?
        public var fingerprint: String?
    }

    public static var directory: URL { Paths.home.appending(path: ".ssh") }

    static func isPrivateKey(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if ["authorized_keys", "config", "known_hosts"].contains(name) || name.hasSuffix(".pub") { return false }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 256)) ?? Data()
        return String(decoding: head, as: UTF8.self).contains("PRIVATE KEY")
    }

    public static func publicKeyURL(_ path: String) -> URL { URL(fileURLWithPath: SSHCommand.expandHome(path) + ".pub") }

    static func readPublicKey(_ path: String) -> String? {
        (try? String(contentsOf: publicKeyURL(path), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Private keys directly in `~/.ssh`.
    public static func found(in directory: URL = directory) -> [Found] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        return urls.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true && isPrivateKey($0)
        }
        .map { Found(name: $0.lastPathComponent, path: $0.path, publicKey: readPublicKey($0.path)) }
        .sorted { $0.name < $1.name }
    }

    /// `id_production-api` from "Production API".
    public static func fileName(for name: String) throws -> String {
        let cleaned = String(name.trimmingCharacters(in: .whitespaces).lowercased().map {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : "-"
        }).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !cleaned.isEmpty else { throw LowtideError.invalid("Give the key a name") }
        return "id_\(cleaned)"
    }

    public static func fingerprint(_ publicPath: URL) async -> String? {
        guard let out = try? await Shell.run("/usr/bin/ssh-keygen", ["-lf", publicPath.path], timeout: .seconds(10)), out.ok else {
            return nil
        }
        let words = out.stdout.split(separator: " ")
        return words.count > 1 ? String(words[1]) : nil
    }

    public static func inspect(_ path: String) async throws -> Inspection {
        let full = SSHCommand.expandHome(path.trimmingCharacters(in: .whitespaces))
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else {
            throw LowtideError.notFound("A key at \(Paths.tilde(full))")
        }
        let pub = publicKeyURL(full)
        let hasPublic = FileManager.default.fileExists(atPath: pub.path)
        return Inspection(path: full, publicKey: readPublicKey(full), fingerprint: hasPublic ? await fingerprint(pub) : nil)
    }

    /// Makes a key in `~/.ssh` with ssh-keygen. The passphrase is typed into
    /// ssh-keygen's own prompt in a private PTY, never passed as `-N`, so it
    /// never shows in the process list.
    public static func generate(name: String, type: KeyType, passphrase: String, comment: String = "",
                                directory: URL = directory) async throws -> Generated {
        let file = try fileName(for: name)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        chmod(directory.path, 0o700)
        let path = directory.appending(path: file).path
        guard !fm.fileExists(atPath: path), !fm.fileExists(atPath: path + ".pub") else {
            throw LowtideError.invalid("A key already exists at \(Paths.tilde(path))")
        }
        let label = comment.trimmingCharacters(in: .whitespaces).isEmpty ? "Lowtide \(name.trimmingCharacters(in: .whitespaces))" : comment
        var args = ["-q", "-t", type.rawValue, "-f", path, "-C", label]
        if type == .rsa { args += ["-b", "4096"] }
        try await Task.detached { try keygenInPTY(args, passphrase: passphrase) }.value
        let publicKey = (try String(contentsOf: URL(fileURLWithPath: path + ".pub"), encoding: .utf8))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Generated(path: path, publicKey: publicKey, fingerprint: await fingerprint(URL(fileURLWithPath: path + ".pub")) ?? "")
    }

    static func keygenInPTY(_ args: [String], passphrase: String) throws {
        var master: Int32 = -1
        var argv: [UnsafeMutablePointer<CChar>?] = (["/usr/bin/ssh-keygen"] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let pid = forkpty(&master, nil, nil, nil)
        if pid < 0 { throw LowtideError.commandFailed("ssh-keygen: \(String(cString: strerror(errno)))") }
        if pid == 0 {
            execv("/usr/bin/ssh-keygen", &argv)
            _exit(127)
        }
        defer { close(master) }
        // SIGKILL after a minute: ssh-keygen blocks SIGTERM while reading a passphrase.
        let watchdog = DispatchWorkItem { kill(pid, SIGKILL) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: watchdog)
        defer { watchdog.cancel() }
        var transcript = ""
        var answered = 0
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let n = read(master, &buffer, buffer.count)
            if n <= 0 { break }
            transcript += String(decoding: buffer[0..<n], as: UTF8.self)
            // Answer each prompt only once it's printed: ssh-keygen flushes
            // pending tty input (TCSAFLUSH) right before it asks.
            let prompts = transcript.components(separatedBy: "passphrase").count - 1
                - (transcript.components(separatedBy: "no passphrase").count - 1)
            if answered < min(prompts, 2), transcript.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(":") {
                let line = Array((passphrase + "\n").utf8)
                _ = line.withUnsafeBytes { write(master, $0.baseAddress, $0.count) }
                answered += 1
            }
            // Keep draining until EOF: on macOS a process can't finish
            // exiting while its terminal output is unread.
        }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        guard status & 0x7f == 0, (status >> 8) & 0xff == 0 else { throw LowtideError.commandFailed("ssh-keygen failed") }
    }

    /// Moves a key and its public half to the Trash. Only private keys
    /// directly in `~/.ssh`; never config, known_hosts or authorized_keys.
    public static func trash(_ path: String, directory: URL = directory) async throws {
        let full = URL(fileURLWithPath: SSHCommand.expandHome(path)).standardizedFileURL
        guard full.deletingLastPathComponent().path == directory.standardizedFileURL.path else {
            throw LowtideError.denied("Only keys stored directly in ~/.ssh can be removed")
        }
        let values = try? full.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values?.isSymbolicLink == true { throw LowtideError.denied("Refusing to remove a symbolic link") }
        guard isPrivateKey(full) else { throw LowtideError.denied("\(Paths.tilde(full.path)) is not an SSH private key") }
        var paths = [full.path]
        let pub = full.path + ".pub"
        if FileManager.default.fileExists(atPath: pub) { paths.append(pub) }
        let refused = await Trash.move(paths).refused
        if let first = refused.first { throw LowtideError.denied(first.reason) }
    }
}
