import Foundation

/// Where an ssh connection goes.
public struct SSHEndpoint: Equatable, Hashable, Sendable {
    public struct Jump: Equatable, Hashable, Sendable {
        public var host: String
        public var port: Int
        public var user: String
        /// The jump host's own key, when it has one.
        public var identityPath: String?
        public init(host: String, port: Int = 22, user: String, identityPath: String? = nil) {
            self.host = host
            self.port = port
            self.user = user
            self.identityPath = identityPath
        }
    }

    public var host: String
    public var port: Int
    public var user: String
    public var identityPath: String?
    public var jump: Jump?

    public init(host: String, port: Int = 22, user: String, identityPath: String? = nil, jump: Jump? = nil) {
        self.host = host
        self.port = port
        self.user = user
        self.identityPath = identityPath
        self.jump = jump
    }

    public var destination: String { "\(user)@\(host)" }
}

/// Builds the arguments for the system `ssh`. Every value a person typed is
/// checked first: nothing ssh could read as an option or split into words.
public enum SSHCommand {
    public static let program = "/usr/bin/ssh"

    /// Rejects user/host values ssh would parse as options or split into
    /// words: a leading `-` turns `-oProxyCommand=…@host` into command execution.
    public static func validate(user: String, host: String) throws {
        func valid(_ value: String) -> Bool {
            !value.isEmpty && !value.hasPrefix("-")
                && value.unicodeScalars.allSatisfy { !CharacterSet.whitespacesAndNewlines.contains($0)
                    && !CharacterSet.controlCharacters.contains($0) && $0 != "@" }
        }
        guard valid(user), valid(host) else { throw LowtideError.invalid("Invalid SSH destination \(user)@\(host)") }
    }

    public static func validPort(_ port: Int) -> Bool { (1...65_535).contains(port) }

    public static func expandHome(_ path: String) -> String {
        if path == "~" { return Paths.home.path }
        if path.hasPrefix("~/") { return Paths.home.appending(path: String(path.dropFirst(2))).path }
        return path
    }

    /// Single-quotes a word for a POSIX shell.
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Options shared by every connection: the key, the jump host, the port.
    static func connectionOptions(_ endpoint: SSHEndpoint, batch: Bool = false) throws -> [String] {
        try validate(user: endpoint.user, host: endpoint.host)
        guard validPort(endpoint.port) else { throw LowtideError.invalid("Port must be between 1 and 65535") }
        var args = ["-o", "StrictHostKeyChecking=accept-new", "-p", String(endpoint.port)]
        if let path = endpoint.identityPath, !path.isEmpty {
            args += ["-i", expandHome(path), "-o", "IdentitiesOnly=yes"]
        }
        if let jump = endpoint.jump {
            try validate(user: jump.user, host: jump.host)
            guard validPort(jump.port) else { throw LowtideError.invalid("The jump host's port must be between 1 and 65535") }
            if let key = jump.identityPath, !key.isEmpty {
                // `-J` would sign in to the jump host with the default keys
                // only; its own key needs an explicit proxy command.
                var inner = ["ssh", "-o", "StrictHostKeyChecking=accept-new", "-i", expandHome(key), "-o", "IdentitiesOnly=yes"]
                if batch { inner += ["-o", "BatchMode=yes"] }
                inner += ["-p", String(jump.port), "-W", "%h:%p", "--", "\(jump.user)@\(jump.host)"]
                let command = inner.map { word in
                    word == "%h:%p" ? word : shellQuote(word).replacingOccurrences(of: "%", with: "%%")
                }.joined(separator: " ")
                args += ["-o", "ProxyCommand=\(command)"]
            } else {
                args += ["-J", "\(jump.user)@\(jump.host):\(jump.port)"]
            }
        }
        return args
    }

    /// An interactive session in a terminal. With a remote command, the
    /// command runs and the session stays open in a login shell after it.
    public static func interactive(_ endpoint: SSHEndpoint, forwardAgent: Bool = false, remoteCommand: String? = nil) throws -> [String] {
        var args = ["-tt", "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3"]
        args += try connectionOptions(endpoint)
        if forwardAgent { args.append("-A") }
        args += ["--", endpoint.destination]
        if let remoteCommand { args.append(keepSessionOpen(remoteCommand)) }
        return args
    }

    static func keepSessionOpen(_ command: String) -> String {
        "\(command)\n__lowtide_status=$?\nprintf '\\n[command finished with exit %s — session remains open]\\n' \"$__lowtide_status\"\nexec \"${SHELL:-/bin/sh}\" -l"
    }

    /// A background tunnel: no shell, no tty, and a failed forward ends it.
    public static func tunnel(_ endpoint: SSHEndpoint, forward: PortForward, batch: Bool) throws -> [String] {
        guard validPort(forward.bindPort), forward.kind == .dynamic || validPort(forward.targetPort ?? forward.bindPort) else {
            throw LowtideError.invalid("Ports must be between 1 and 65535")
        }
        let spec = forward.spec
        guard !spec.contains(where: { $0.isWhitespace }), !spec.hasPrefix("-") else {
            throw LowtideError.invalid("Invalid forward \(spec)")
        }
        var args = ["-N", "-T", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3"]
        if batch { args += ["-o", "BatchMode=yes"] }
        args += try connectionOptions(endpoint, batch: batch)
        args += [forward.flag, spec, "--", endpoint.destination]
        return args
    }

    /// Runs one command and returns (no tty); for snippet runs.
    public static func run(_ endpoint: SSHEndpoint, command: String, batch: Bool = false) throws -> [String] {
        var args = ["-T", "-o", "ConnectTimeout=15"]
        if batch { args += ["-o", "BatchMode=yes"] }
        args += try connectionOptions(endpoint, batch: batch)
        args += ["--", endpoint.destination, command]
        return args
    }

    /// Fleet: non-interactive, key/agent (or saved secret) only, a shared
    /// connection, the script on stdin.
    public static func probe(_ endpoint: SSHEndpoint, controlPath: String, batch: Bool) throws -> [String] {
        var args = ["-T", "-o", "ConnectTimeout=8", "-o", "ControlMaster=auto", "-o", "ControlPersist=120",
                    "-o", "ControlPath=\(controlPath)"]
        if batch { args += ["-o", "BatchMode=yes"] }
        args += try connectionOptions(endpoint, batch: batch)
        args += ["--", endpoint.destination, "sh -s"]
        return args
    }

    // MARK: Keys on hosts

    /// A public key ssh accepts: `type base64 [comment]`.
    public static func parsePublicKey(_ text: String) -> (type: String, data: String, comment: String)? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2,
              parts[0].range(of: #"^(ssh-[a-z0-9-]+|ecdsa-sha2-[a-z0-9-]+|sk-[a-z0-9@.-]+)$"#, options: .regularExpression) != nil,
              parts[1].range(of: #"^[A-Za-z0-9+/]+=*$"#, options: .regularExpression) != nil else { return nil }
        let comment = parts.count > 2 ? parts[2].filter { !$0.isNewline } : ""
        return (parts[0], parts[1], comment)
    }

    /// Adds a public key to the host's authorized_keys once, without duplicates.
    public static func installKey(_ endpoint: SSHEndpoint, publicKey: String) throws -> [String] {
        guard let key = parsePublicKey(publicKey) else { throw LowtideError.invalid("Invalid SSH public key") }
        let line = [key.type, key.data, key.comment].filter { !$0.isEmpty }.joined(separator: " ")
        let script = """
            umask 077; mkdir -p "$HOME/.ssh" && touch "$HOME/.ssh/authorized_keys" || exit 1; \
            if grep -qF \(shellQuote(key.data)) "$HOME/.ssh/authorized_keys"; then echo 'The key is already installed.'; \
            else printf '%s\\n' \(shellQuote(line)) >> "$HOME/.ssh/authorized_keys" && echo 'Key installed.'; fi
            """
        return try interactive(endpoint) + [shellWrapped(script)]
    }

    /// Removes exactly this public key from the host's authorized_keys.
    public static func removeKey(_ endpoint: SSHEndpoint, publicKey: String) throws -> [String] {
        guard let key = parsePublicKey(publicKey) else { throw LowtideError.invalid("Invalid SSH public key") }
        // Any field: options (`from="…" ssh-ed25519 KEY`) push the key past $2.
        let script = """
            umask 077; file="$HOME/.ssh/authorized_keys"; [ -f "$file" ] || { echo 'No authorized_keys file.'; exit 0; }; \
            tmp="$file.lowtide.$$"; awk '{ for (i = 1; i <= NF; i++) if ($i == "\(key.data)") next; print }' "$file" > "$tmp" \
            && chmod 600 "$tmp" && mv "$tmp" "$file" && echo 'Key removed.'
            """
        return try interactive(endpoint) + [shellWrapped(script)]
    }

    /// Runs a POSIX script whatever the login shell is (fish, nu…).
    static func shellWrapped(_ script: String) -> String { "sh -c \(shellQuote(script))" }

    // MARK: Quick connect

    /// `user@host`, `user@host:2222`, `user@[::1]:2222` or `user@::1`.
    public static func parseTarget(_ input: String) -> (user: String, host: String, port: Int)? {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        var user = ""
        var rest = Substring(text)
        if let at = text.lastIndex(of: "@") {
            user = String(text[..<at])
            rest = text[text.index(after: at)...]
        }
        var host: String
        var port = 22
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            host = String(rest[rest.index(after: rest.startIndex)..<close])
            let after = rest[rest.index(after: close)...]
            if !after.isEmpty {
                guard after.hasPrefix(":"), let p = Int(after.dropFirst()) else { return nil }
                port = p
            }
        } else if rest.filter({ $0 == ":" }).count > 1 {
            host = String(rest) // bare IPv6, no port
        } else if let colon = rest.firstIndex(of: ":") {
            host = String(rest[..<colon])
            guard let p = Int(rest[rest.index(after: colon)...]) else { return nil }
            port = p
        } else {
            host = String(rest)
        }
        guard !host.isEmpty, validPort(port) else { return nil }
        return (user, host, port)
    }
}
