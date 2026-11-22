import Foundation

/// The judgement behind command receipts and the install tripwire: which
/// command lines are installers, where each ecosystem is expected to
/// connect, what a written path means, and which child processes deserve a
/// second look. Pure functions, tested in `ProtectionRunTests`.
public enum RunRules {
    static let installVerbs: Set<String> = ["install", "i", "add", "ci", "update", "upgrade", "reinstall", "sync"]

    static func hasVerb(_ words: ArraySlice<String>, _ verbs: Set<String>) -> Bool {
        words.dropFirst().contains { verbs.contains($0) }
    }

    static func tool(_ word: String) -> String {
        word.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? word
    }

    static let tools: Set<String> = [
        "npm", "npm-cli.js", "pnpm", "yarn", "bun", "pip", "pip3", "pipx", "uv", "python", "python3",
        "brew", "brew.sh", "cargo", "gem", "bundle", "go",
    ]

    /// The ecosystem when `argv` (or a shell command line) installs packages.
    public static func installer(_ args: [String]) -> Ecosystem? {
        let line = args.joined(separator: " ")
        if pipesIntoShell(line) { return .script }
        let all = line.split(whereSeparator: \.isWhitespace).map(String.init)
        // Scripts run through an interpreter: `node …/npm-cli.js install`,
        // `python3 -m pip install`, `/bin/bash …/brew.sh install`.
        guard let start = all.firstIndex(where: { tools.contains(tool($0)) || $0.hasSuffix("npm-cli.js") }) else { return nil }
        let words = all[start...]
        let name = tool(words.first!)
        let verbs = { (set: Set<String>) in hasVerb(words, set) }
        if ["npm", "npm-cli.js", "pnpm", "yarn", "bun"].contains(name) { return verbs(installVerbs) ? .npm : nil }
        if ["pip", "pip3", "pipx", "uv"].contains(name) { return verbs(installVerbs) ? .python : nil }
        if ["python", "python3"].contains(name) { return words.contains("pip") && verbs(installVerbs) ? .python : nil }
        if ["brew", "brew.sh"].contains(name) { return verbs(["install", "upgrade", "reinstall"]) ? .homebrew : nil }
        if name == "cargo" { return verbs(["install"]) ? .cargo : nil }
        if ["gem", "bundle"].contains(name) { return verbs(["install", "update"]) ? .ruby : nil }
        if name == "go" { return verbs(["install", "get"]) ? .go : nil }
        return nil
    }

    /// Like `installer`, for a process seen anywhere on the Mac: the process
    /// itself must be the tool (directly, or its script under an
    /// interpreter), never a shell carrying the words in a `-c` string.
    public static func installerProcess(_ argv: [String]) -> Ecosystem? {
        // A process that renamed itself (npm sets its title to
        // `npm install left-pad`) shows one space-separated argument.
        let args = argv.count == 1 ? argv[0].split(whereSeparator: \.isWhitespace).map(String.init) : argv
        guard let first = args.first else { return nil }
        var rest = args[...]
        if ["node", "python", "python3", "ruby", "bash", "sh", "zsh"].contains(tool(first)) {
            rest = args.dropFirst()
            // Interpreter flags (`bash -p`), but never inline code.
            while let flag = rest.first, flag.hasPrefix("-") {
                if ["-c", "-e", "--eval"].contains(flag) { return nil }
                rest = rest.dropFirst()
                if flag == "-m" { break }
            }
        }
        guard let head = rest.first,
              tools.contains(tool(head)) || head.hasSuffix("npm-cli.js") || head.hasSuffix("brew.sh")
        else { return nil }
        let found = installer(Array(rest))
        return found == .script ? nil : found
    }

    /// `curl -fsSL https://x | sh`, `wget -qO- … | bash`.
    static func pipesIntoShell(_ line: String) -> Bool {
        guard line.contains("curl ") || line.contains("wget ") else { return false }
        return line.split(separator: "|", omittingEmptySubsequences: false).dropFirst().contains { part in
            let first = part.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            return ["sh", "bash", "zsh", "sudo"].contains(tool(first))
        }
    }

    /// Hosts named in a command line's URLs: a piped script is expected to
    /// talk to where it came from.
    public static func urlHosts(_ line: Substring) -> [String] {
        line.split(whereSeparator: \.isWhitespace).compactMap { word in
            let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard let range = trimmed.range(of: "://") else { return nil }
            let host = trimmed[range.upperBound...].split(omittingEmptySubsequences: false,
                                                          whereSeparator: { "/:?".contains($0) }).first ?? ""
            return host.isEmpty ? nil : host.lowercased()
        }
    }

    public static func urlHosts(_ line: String) -> [String] { urlHosts(line[...]) }

    /// Whether `host` is `expected` or one of its subdomains.
    public static func hostMatches(_ host: String, _ expected: String) -> Bool {
        host == expected || host.hasSuffix("." + expected)
    }

    // MARK: Places

    static let sensitive = [
        ".ssh/", ".aws/", ".gnupg/", ".kube/", ".docker/config.json", ".npmrc", ".netrc",
        ".git-credentials", ".config/gh/", ".pypirc", "Library/Keychains/",
    ]
    static let persistence = [
        "Library/LaunchAgents/", ".zshrc", ".zprofile", ".zshenv", ".bashrc", ".bash_profile", ".profile",
        ".config/fish/config.fish", ".config/autostart/",
    ]
    static let caches = [
        ".npm/", ".cache/", ".pnpm-store/", "Library/pnpm/", ".bun/install/", ".cargo/registry/", ".cargo/git/",
        ".rustup/", "go/pkg/", ".gradle/", ".m2/", "Library/Caches/", ".yarn/",
    ]
    /// Files every shell and editor rewrites on its own.
    static let churn = [
        ".zsh_history", ".zsh_sessions/", ".bash_history", ".bash_sessions/", ".zcompdump", ".lesshst",
        ".viminfo", ".local/share/fish/", ".python_history",
    ]

    /// The part of `path` under `root/`, if it is under it.
    static func under(_ path: String, _ root: String) -> Substring? {
        guard path.hasPrefix(root) else { return nil }
        let rest = path.dropFirst(root.count)
        return rest.first == "/" ? rest.dropFirst() : nil
    }

    /// Classifies a changed path, or nil for churn nobody needs to see
    /// (other apps' state under ~/Library, shell history, Lowtide's own files).
    public static func place(of path: String, home: String, cwd: String?) -> FilePlace? {
        if path.contains("/\(Paths.bundleID)/") || path.hasSuffix("/.DS_Store") {
            return nil
        }
        let inHome = under(path, home)
        if let rest = inHome, churn.contains(where: { rest.hasPrefix($0) }) { return nil }
        if path.hasPrefix("/Library/LaunchAgents/") || path.hasPrefix("/Library/LaunchDaemons/") { return .persistence }
        if let cwd, cwd != home, under(path, cwd) != nil { return .project }
        if let rest = inHome {
            if sensitive.contains(where: { rest.hasPrefix($0) }) { return .sensitive }
            if persistence.contains(where: { rest.hasPrefix($0) }) { return .persistence }
            if caches.contains(where: { rest.hasPrefix($0) }) { return .cache }
            // Other apps rewrite their state under ~/Library all the time.
            return rest.hasPrefix("Library/") ? nil : .home
        }
        let system = ["/opt/homebrew/", "/usr/local/", "/Applications/", "/Library/"]
        return system.contains(where: { path.hasPrefix($0) }) ? .system : nil
    }

    /// The folder a change is grouped under: two levels below its place's root.
    public static func group(of path: String, home: String, cwd: String?, place: FilePlace) -> String {
        let root = switch place {
        case .project: cwd ?? home
        case .system: ""
        default: home
        }
        let rest = (path.hasPrefix(root) ? path.dropFirst(root.count) : path[...]).drop { $0 == "/" }
        let parts = rest.split(separator: "/", omittingEmptySubsequences: false)
        let first = parts.first.map(String.init) ?? ""
        let group = parts.count > 2 ? "\(first)/\(parts[1])" : first
        switch place {
        case .project: return group
        case .system: return "/" + group
        default: return "~/" + group
        }
    }

    // MARK: Processes

    /// A child process that deserves a line in the receipt: how serious, the
    /// rule's id (the UI explains each one) and why, in words.
    public static func notable(_ comm: String, _ args: [String]) -> (Severity, String, String)? {
        let line = args.joined(separator: " ")
        switch comm {
        case "security": return (.alert, "keychain", "read or changed the keychain")
        case "osascript": return (.alert, "applescript", "ran AppleScript")
        case "launchctl": return (.alert, "service", "registered a background service")
        case "crontab": return (.alert, "cron", "changed scheduled jobs")
        case "nc", "ncat", "socat", "telnet": return (.alert, "socket", "opened a raw network socket")
        case "xattr" where line.contains("quarantine") || line.contains(" -c") || line.contains(" -cr"):
            return (.alert, "quarantine", "removed Gatekeeper's quarantine flag")
        case "curl", "wget": return (.notice, "download", "downloaded something")
        case "base64" where line.contains(" -d") || line.contains("--decode"):
            return (.notice, "decode", "decoded hidden data")
        case "ssh", "scp", "sftp": return (.notice, "ssh", "opened an SSH connection")
        case "sudo": return (.notice, "sudo", "asked for administrator rights")
        case "chmod" where line.contains("+x") || line.contains("777"):
            return (.info, "executable", "made a file executable")
        case "node", "python", "python3", "ruby", "perl":
            return line.contains(" -e ") || line.contains(" -c ") ? (.info, "inline-code", "ran inline code") : nil
        default: return nil
        }
    }

    /// The install script a process is: npm, pnpm, yarn and bun name the
    /// lifecycle event and its package in the environment; Cargo build
    /// scripts sit in `build/<crate>-<hash>/`. `(event, package)`.
    public static func script(of args: [String], env: [String]) -> (String, String?)? {
        func variable(_ name: String) -> String? {
            for pair in env where pair.hasPrefix(name + "=") {
                let value = String(pair.dropFirst(name.count + 1))
                return value.isEmpty ? nil : value
            }
            return nil
        }
        if let event = variable("npm_lifecycle_event") {
            let package = variable("npm_package_name").map { name in
                variable("npm_package_version").map { "\(name)@\($0)" } ?? name
            }
            return (event, package)
        }
        guard let program = args.first, program.hasSuffix("/build-script-build") else { return nil }
        let dir = program.dropLast("/build-script-build".count)
        guard let folder = dir.split(separator: "/").last, let dash = folder.lastIndex(of: "-") else { return nil }
        return ("build script", String(folder[..<dash]))
    }

    /// A package a changed path belongs to: name, version when the path says
    /// it, and the package's own folder. Covers node_modules (and pnpm's
    /// store), Python's dist-info, Homebrew's Cellar and Caskroom, Cargo's
    /// registry sources, Go modules and gems.
    public static func package(of path: String) -> (name: String, version: String?, dir: String)? {
        let s = path
        func dir(_ end: String.Index) -> String { String(s[..<end]) }
        func end(from start: String.Index) -> String.Index { s[start...].firstIndex(of: "/") ?? s.endIndex }
        // pnpm: node_modules/.pnpm/@scope+name@1.2.3_peer/…
        if let at = s.range(of: "/node_modules/.pnpm/", options: .backwards) {
            let start = at.upperBound
            let stop = end(from: start)
            let id = s[start..<stop]
            let core = id.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "_" || $0 == "(" }).first ?? id
            guard let (name, version) = splitVersion(String(core), "@") else { return nil }
            return (name.replacingFirst("+", with: "/"), version, dir(stop))
        }
        if let at = s.range(of: "/node_modules/", options: .backwards) {
            let start = at.upperBound
            let parts = s[start...].split(separator: "/", omittingEmptySubsequences: false)
            guard let first = parts.first, !first.isEmpty, !first.hasPrefix(".") else { return nil }
            var name = String(first)
            if first.hasPrefix("@") {
                guard parts.count > 1, !parts[1].isEmpty else { return nil }
                name += "/" + parts[1]
            }
            return (name, nil, dir(s.index(start, offsetBy: name.count)))
        }
        if let at = s.range(of: "/site-packages/") {
            let start = at.upperBound
            let stop = end(from: start)
            let folder = s[start..<stop]
            guard folder.hasSuffix(".dist-info"), let dash = folder.firstIndex(of: "-") else { return nil }
            let base = folder.dropLast(".dist-info".count)
            return (String(base[..<dash]), String(base[base.index(after: dash)...]), dir(stop))
        }
        for root in ["/Cellar/", "/Caskroom/"] {
            guard let at = s.range(of: root) else { continue }
            let parts = s[at.upperBound...].split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count > 1, !parts[0].isEmpty, !parts[1].isEmpty, !parts[1].hasPrefix(".") else { return nil }
            let stop = s.index(at.upperBound, offsetBy: parts[0].count + 1 + parts[1].count)
            return (String(parts[0]), String(parts[1]), dir(stop))
        }
        // The last `/gems/`: Ruby's own tree is `…/gems/3.3.0/gems/rake-13.2.1`.
        for root in ["/.cargo/registry/src/", "/gems/"] {
            guard let at = s.range(of: root, options: .backwards) else { continue }
            var start = at.upperBound
            if root.contains("cargo") {
                // Past the index folder (`index.crates.io-…`).
                guard let slash = s[start...].firstIndex(of: "/") else { return nil }
                start = s.index(after: slash)
            }
            let stop = end(from: start)
            guard let (name, version) = splitVersion(String(s[start..<stop]), "-") else { return nil }
            return (name, version, dir(stop))
        }
        if let at = s.range(of: "/go/pkg/mod/") {
            let start = at.upperBound
            if s[start...].hasPrefix("cache/") { return nil }
            guard let sign = s[start...].firstIndex(of: "@") else { return nil }
            let stop = end(from: sign)
            return (String(s[start..<sign]), String(s[s.index(after: sign)..<stop]), dir(stop))
        }
        return nil
    }

    /// `name@1.2.3` or `name-1.2.3`: split at the last separator followed by
    /// a digit (a leading `@` is a scope, not a version).
    static func splitVersion(_ id: String, _ separator: Character) -> (String, String)? {
        let chars = Array(id)
        guard chars.count > 1 else { return nil }
        for i in stride(from: chars.count - 2, through: 1, by: -1)
        where chars[i] == separator && chars[i + 1].isASCII && chars[i + 1].isNumber {
            return (String(chars[..<i]), String(chars[(i + 1)...]))
        }
        return nil
    }

    /// Long-lived helpers that tools start on purpose.
    public static func expectedDaemon(_ comm: String) -> Bool {
        [
            "gradle", "java", "turbo", "esbuild", "watchman", "sccache", "rust-analyzer", "tsserver", "gopls",
            "bazel", "nx", "ssh-agent", "gpg-agent", "com.docker.cli",
        ].contains(comm)
    }

    /// Shortens a command line for display, and never shows what looks like
    /// a secret passed as an argument.
    public static func displayCommand(_ args: [String]) -> String {
        let secretWords = ["token", "password", "passwd", "secret", "key", "auth"]
        func secretish(_ text: Substring) -> Bool {
            let lower = text.lowercased()
            return secretWords.contains { lower.contains($0) }
        }
        // The MySQL clients take the password glued to `-p`.
        let glued = args.first.map { ["mysql", "mysqldump", "mysqladmin", "mariadb", "mariadb-dump"].contains(tool($0)) } ?? false
        var out: [String] = []
        var hideNext = false, userNext = false
        for arg in args {
            let shown: String
            if hideNext {
                shown = "•••"
            } else if userNext, let colon = arg.firstIndex(of: ":") {
                // `curl -u user:password`
                shown = "\(arg[..<colon]):•••"
            } else if glued, arg.hasPrefix("-p"), arg.count > 2 {
                shown = "-p•••"
            } else if let eq = arg.firstIndex(of: "="), secretish(arg[..<eq]) {
                shown = "\(arg[..<eq])=•••"
            } else if let colon = arg.firstIndex(of: ":"), secretish(arg[..<colon]) {
                // A header: `-H "Authorization: Bearer …"`, `X-Api-Key: …`.
                shown = "\(arg[..<colon]): •••"
            } else if SecretDetector.hasToken(arg) {
                shown = "•••"
            } else {
                shown = urlPassword(arg) ?? arg
            }
            hideNext = !hideNext && arg.hasPrefix("-") && secretish(arg[...])
            userNext = arg == "-u" || arg == "--user"
            out.append(shown)
        }
        let line = out.joined(separator: " ")
        return line.count > 240 ? String(line.prefix(240)) + "…" : line
    }

    /// `scheme://user:password@host/…` with the password hidden.
    static func urlPassword(_ arg: String) -> String? {
        guard let scheme = arg.range(of: "://") else { return nil }
        let start = scheme.upperBound
        let stop = arg[start...].firstIndex(where: { "/?#".contains($0) }) ?? arg.endIndex
        guard let at = arg[start..<stop].lastIndex(of: "@"), let colon = arg[start..<at].firstIndex(of: ":") else { return nil }
        return "\(arg[...colon])•••\(arg[at...])"
    }

    /// `npm install left-pad` from a long command line, for alerts.
    public static func shortForAlert(_ command: String) -> String {
        let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
        let start = words.firstIndex { !["node", "python", "python3", "bash", "sh", "ruby"].contains(tool($0)) } ?? 0
        var out = words.dropFirst(start).prefix(4).map(tool)
        if !out.isEmpty {
            var first = out[0]
            if first.hasSuffix(".js") { first.removeLast(3) }
            if first.hasSuffix("-cli") { first.removeLast(4) }
            out[0] = first
        }
        return out.joined(separator: " ")
    }
}

extension String {
    func replacingFirst(_ target: String, with replacement: String) -> String {
        guard let range = range(of: target) else { return self }
        return replacingCharacters(in: range, with: replacement)
    }
}
