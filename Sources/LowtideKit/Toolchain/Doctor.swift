import Foundation

public enum DoctorStatus: String, Sendable, Codable, Comparable {
    case pass, warn, fail
    /// Not applicable here (the tool isn't installed).
    case skip

    var severity: Int {
        switch self {
        case .skip: 0
        case .pass: 1
        case .warn: 2
        case .fail: 3
        }
    }

    public static func < (a: DoctorStatus, b: DoctorStatus) -> Bool { a.severity < b.severity }
}

/// A fix Lowtide can apply itself, shown (with what it will do) before it runs.
public struct DoctorFix: Sendable, Hashable, Codable {
    public var id: String
    public var label: String
    /// What it will do, in words or as the command.
    public var command: String
}

/// One problem a check found: where it comes from and how to fix it.
public struct DoctorIssue: Sendable, Hashable, Codable, Identifiable {
    public var title: String
    public var detail: String
    public var path: String?
    /// `file:line` of the shell config that causes it.
    public var source: String?
    public var suggestion: String
    /// A command to copy and run in a terminal, when the fix is one.
    public var command: String?
    public var fix: DoctorFix?

    public var id: String { "\(title)|\(path ?? "")|\(detail)" }

    init(_ title: String, _ detail: String, _ suggestion: String, command: String? = nil,
         path: String? = nil, source: String? = nil, fix: DoctorFix? = nil) {
        self.title = title
        self.detail = detail
        self.suggestion = suggestion
        self.command = command
        self.path = path
        self.source = source
        self.fix = fix
    }
}

public struct DoctorCheck: Sendable, Identifiable, Hashable {
    public var id: String
    public var category: String
    public var title: String
    public var status: DoctorStatus
    public var summary: String
    public var issues: [DoctorIssue]
    public var duration: TimeInterval
}

public struct PlannedCheck: Sendable, Identifiable, Hashable {
    public var id: String
    public var category: String
    public var title: String
}

/// Health checks for a developer Mac. Each says what it looked at, whether
/// it passed, and for each problem where it comes from and how to fix it.
public enum Doctor {
    struct Outcome {
        var status: DoctorStatus
        var summary: String
        var issues: [DoctorIssue] = []

        static func pass(_ summary: String) -> Outcome { Outcome(status: .pass, summary: summary) }
        static func skip(_ summary: String) -> Outcome { Outcome(status: .skip, summary: summary) }
    }

    /// Every check, in the order they're listed (grouped by category).
    public static let planned: [PlannedCheck] = [
        PlannedCheck(id: "disk-space", category: "System", title: "Free disk space"),
        PlannedCheck(id: "xcode-clt", category: "System", title: "Xcode Command Line Tools"),
        PlannedCheck(id: "path-login", category: "PATH", title: "Lowtide sees your terminal's PATH"),
        PlannedCheck(id: "path-entries", category: "PATH", title: "PATH entries"),
        PlannedCheck(id: "path-order", category: "PATH", title: "Homebrew before system tools"),
        PlannedCheck(id: "path-duplicates", category: "PATH", title: "One copy of each tool"),
        PlannedCheck(id: "path-links", category: "PATH", title: "Command links resolve"),
        PlannedCheck(id: "path-shims", category: "PATH", title: "Version manager shims run"),
        PlannedCheck(id: "shell-startup", category: "Shell", title: "Shell startup time"),
        PlannedCheck(id: "git-identity", category: "Git", title: "Commit identity"),
        PlannedCheck(id: "ssh-permissions", category: "SSH", title: "Key permissions"),
        PlannedCheck(id: "ssh-agent", category: "SSH", title: "SSH agent"),
        PlannedCheck(id: "brew-doctor", category: "Homebrew", title: "brew doctor"),
        PlannedCheck(id: "brew-missing", category: "Homebrew", title: "Formula dependencies"),
        PlannedCheck(id: "npm-prefix", category: "Node", title: "Global npm installs without sudo"),
        PlannedCheck(id: "runtimes-eol", category: "Runtimes", title: "Supported runtime versions"),
        PlannedCheck(id: "registries", category: "Network", title: "Package registries reachable"),
    ]

    /// Runs one check and times it.
    public static func run(_ id: String) async -> DoctorCheck {
        await Shell.ready()
        let plan = planned.first { $0.id == id } ?? PlannedCheck(id: id, category: "Other", title: id)
        let started = Date()
        let outcome: Outcome = switch id {
        case "disk-space": diskSpace()
        case "xcode-clt": await xcodeTools()
        case "path-login": loginPath(app: Shell.path, login: Shell.loginPath)
        case "path-entries": pathEntries(pathDirectories())
        case "path-order": pathOrder(pathDirectories())
        case "path-duplicates": duplicateTools(pathDirectories())
        case "path-links": brokenLinks(pathDirectories())
        case "path-shims": await shims(pathDirectories())
        case "shell-startup": await shellStartup()
        case "git-identity": await gitIdentity()
        case "ssh-permissions": sshPermissions(Paths.home.appending(path: ".ssh"))
        case "ssh-agent": await sshAgent()
        case "brew-doctor": await brewDoctor()
        case "brew-missing": await brewMissing()
        case "npm-prefix": await npmPrefix()
        case "runtimes-eol": runtimesEOL(await Runtimes.all())
        case "registries": await registries()
        default: .skip("Unknown check")
        }
        return DoctorCheck(id: plan.id, category: plan.category, title: plan.title, status: outcome.status,
                           summary: outcome.summary, issues: outcome.issues, duration: Date().timeIntervalSince(started))
    }

    // MARK: PATH

    /// The PATH the person's terminals get (their login shell's), not the
    /// one Lowtide extends for its own child processes.
    static func pathDirectories() -> [String] {
        (Shell.loginPath ?? ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
    }

    static let shellFiles = [".zshrc", ".zprofile", ".zshenv", ".profile", ".bash_profile", ".bashrc"]

    /// The shell config line that mentions `needle`, as `file:line`.
    static func shellSource(_ needle: String, home: URL = Paths.home) -> String? {
        let tilde = needle.hasPrefix(home.path) ? "~" + needle.dropFirst(home.path.count) : nil
        for name in shellFiles {
            let file = home.appending(path: name)
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
            if let index = lines.firstIndex(where: { line in
                !line.trimmingCharacters(in: .whitespaces).hasPrefix("#")
                    && (line.contains(needle) || tilde.map { line.contains($0) } == true)
            }) {
                return "\(file.path):\(index + 1)"
            }
        }
        return nil
    }

    /// Folders Lowtide adds to its own PATH that the login shell doesn't
    /// have, holding tools a terminal wouldn't find.
    static func loginPath(app: String, login: String?, executables: (String) -> [String] = executables(in:)) -> Outcome {
        guard let login else {
            return Outcome(status: .warn, summary: "Couldn't read your login shell's PATH", issues: [DoctorIssue(
                "Your shell didn't answer in time",
                "Lowtide asks your login shell for its PATH at launch. It took over 4 s or printed nothing, so Lowtide uses a standard PATH and may find different tools than your terminal does.",
                "Look for a prompt or a slow network call in your shell config; the Shell startup time check below shows how long it takes.")])
        }
        let loginDirectories = Set(login.split(separator: ":").map(String.init))
        let loginTools = Set(loginDirectories.flatMap(executables))
        var issues: [DoctorIssue] = []
        for directory in app.split(separator: ":").map(String.init) where !loginDirectories.contains(directory) {
            let onlyHere = executables(directory).filter { !loginTools.contains($0) }.sorted()
            guard !onlyHere.isEmpty else { continue }
            let shown = onlyHere.prefix(8).joined(separator: ", ") + (onlyHere.count > 8 ? " and \(onlyHere.count - 8) more" : "")
            let folder = Paths.tilde(directory).replacingOccurrences(of: "~", with: "$HOME")
            issues.append(DoctorIssue(
                "\(Format.count(onlyHere.count, "tool")) only Lowtide finds", shown,
                "This folder isn't on your terminal's PATH, so typing these there says \"command not found\". Add it to ~/.zprofile.",
                command: "echo 'export PATH=\"\(folder):$PATH\"' >> ~/.zprofile", path: directory))
        }
        let count = login.split(separator: ":").count
        if issues.isEmpty { return .pass("Same tools as your terminal, \(count) folders") }
        return Outcome(status: .warn, summary: "\(Format.count(issues.count, "folder")) missing from your terminal", issues: issues)
    }

    static func executables(in directory: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { name in
            let path = "\(directory)/\(name)"
            var isDirectory: ObjCBool = false
            return !name.hasPrefix(".") && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: path)
        }
    }

    /// Folders macOS itself puts on PATH (`/etc/paths.d/10-cryptex`,
    /// `10-pmk-global`): they often don't exist and aren't the person's to
    /// remove, so they are not flagged as left behind.
    static func isAppleManaged(_ directory: String) -> Bool {
        ["/var/run/com.apple.", "/private/var/run/com.apple.", "/System/", "/Library/Apple/", "/pkg/env/"]
            .contains { directory.hasPrefix($0) }
    }

    /// Which `/etc/paths` or `/etc/paths.d` file adds each folder.
    static func systemPathSources(_ root: String = "/etc") -> [String: String] {
        var sources: [String: String] = [:]
        let files = ["\(root)/paths"] + ((try? FileManager.default.contentsOfDirectory(atPath: "\(root)/paths.d")) ?? [])
            .sorted().map { "\(root)/paths.d/\($0)" }
        for file in files {
            let lines = ((try? String(contentsOfFile: file, encoding: .utf8)) ?? "").split(whereSeparator: \.isNewline)
            for line in lines {
                let entry = line.trimmingCharacters(in: .whitespaces)
                if !entry.isEmpty, sources[entry] == nil { sources[entry] = file }
            }
        }
        return sources
    }

    static func pathEntries(_ directories: [String], exists: (String) -> Bool = { isDirectory($0) },
                            systemSources: [String: String] = systemPathSources()) -> Outcome {
        var seen: Set<String> = []
        var issues: [DoctorIssue] = []
        for directory in directories {
            if !seen.insert(directory).inserted {
                issues.append(DoctorIssue(
                    "Duplicate PATH entry", "This folder appears more than once, so every command lookup checks it twice.",
                    "Remove the repeated export from your shell config.", path: directory, source: shellSource(directory)))
            } else if !exists(directory), !isAppleManaged(directory) {
                if let file = systemSources[directory] {
                    issues.append(DoctorIssue(
                        "PATH folder doesn't exist", "\(file) adds it for every user; the tool that installed it was probably removed.",
                        "Remove \(file) if you no longer use that tool (it needs your password).", path: directory))
                } else {
                    issues.append(DoctorIssue(
                        "PATH folder doesn't exist", "A tool was probably uninstalled but its PATH line was left behind.",
                        "Remove this entry from your shell config.", path: directory, source: shellSource(directory)))
                }
            }
        }
        if issues.isEmpty { return .pass("\(directories.count) folders, all present and unique") }
        return Outcome(status: .warn, summary: "\(issues.count) of \(directories.count) entries need attention", issues: issues)
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func pathOrder(_ directories: [String]) -> Outcome {
        guard let brew = directories.firstIndex(of: "/opt/homebrew/bin") ?? directories.firstIndex(of: "/usr/local/bin") else {
            return .skip("Homebrew isn't on PATH")
        }
        if let system = directories.firstIndex(of: "/usr/bin"), brew > system {
            return Outcome(status: .warn, summary: "System tools win over Homebrew's", issues: [DoctorIssue(
                "/usr/bin comes before Homebrew",
                "Commands like git, python3 and ruby run Apple's older copies instead of the ones Homebrew installed.",
                "Evaluate `brew shellenv` near the top of ~/.zprofile.",
                command: "echo 'eval \"$(\(directories[brew])/brew shellenv)\"' >> ~/.zprofile",
                source: shellSource("/usr/bin"))])
        }
        return .pass("Homebrew tools take priority")
    }

    static let commonTools = ["node", "npm", "pnpm", "bun", "python3", "pip3", "ruby", "gem", "cargo", "rustc", "go",
                              "java", "git", "docker"]

    static func duplicateTools(_ directories: [String]) -> Outcome {
        let issues = commonTools.compactMap { tool -> DoctorIssue? in
            let copies = copiesOnPath(tool, directories)
            guard copies.count > 1 else { return nil }
            return DoctorIssue(
                "\(copies.count) copies of \(tool)", copies.map(Paths.tilde).joined(separator: "\n"),
                "The first one runs. Editors, Git hooks and GUI apps with a shorter PATH may run another; uninstall the copies you don't use.",
                command: "which -a \(tool)")
        }
        if issues.isEmpty { return .pass("\(commonTools.count) common tools each resolve to one install") }
        return Outcome(status: .warn, summary: "\(Format.count(issues.count, "tool")) installed more than once", issues: issues)
    }

    /// Distinct executables named `command` on PATH, in PATH order.
    static func copiesOnPath(_ command: String, _ directories: [String]) -> [String] {
        var seen: Set<String> = []
        // Apple's /usr/bin copies (git, python3, ruby…) always exist and are
        // meant to be shadowed; they aren't a second install.
        return directories.filter { !isSystemDirectory($0) }.map { "\($0)/\(command)" }.filter { candidate in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue,
                  FileManager.default.isExecutableFile(atPath: candidate) else { return false }
            return seen.insert(URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path).inserted
        }
    }

    static func isSystemDirectory(_ path: String) -> Bool { ["/bin", "/sbin", "/usr/bin", "/usr/sbin"].contains(path) }

    /// Symlinks in `directory` whose target is gone.
    static func brokenLinks(in directory: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.map { "\(directory)/\($0)" }.filter { path in
            (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil && !FileManager.default.fileExists(atPath: path)
        }.sorted()
    }

    static func brokenLinks(_ directories: [String]) -> Outcome {
        var issues: [DoctorIssue] = []
        var seen: Set<String> = []
        for directory in directories where !isSystemDirectory(directory) {
            guard seen.insert(URL(fileURLWithPath: directory).resolvingSymlinksInPath().path).inserted else { continue }
            let links = brokenLinks(in: directory)
            guard !links.isEmpty else { continue }
            let names = links.map { ($0 as NSString).lastPathComponent }
            issues.append(DoctorIssue(
                "\(Format.count(links.count, "broken command link"))", names.joined(separator: ", "),
                "They point at tools that were removed. Typing them gives \"command not found\" or runs something unexpected.",
                path: directory,
                fix: DoctorFix(id: "broken-links:\(directory)", label: "Move links to Trash", command: "Move \(names.joined(separator: ", ")) to the Trash")))
        }
        if issues.isEmpty { return .pass("Every command link points at a real file") }
        return Outcome(status: .fail, summary: "Broken links in \(Format.count(issues.count, "folder"))", issues: issues)
    }

    /// Version managers whose shims folder can sit on PATH, and the command
    /// that regenerates the shims.
    static let shimManagers: [(tool: String, folder: String, rehash: [String])] = [
        ("pyenv", ".pyenv/shims", ["rehash"]), ("rbenv", ".rbenv/shims", ["rehash"]),
        ("nodenv", ".nodenv/shims", ["rehash"]), ("goenv", ".goenv/shims", ["rehash"]),
        ("jenv", ".jenv/shims", ["rehash"]), ("asdf", ".asdf/shims", ["reshim"]),
        ("mise", ".local/share/mise/shims", ["reshim"]),
    ]

    /// A shim is broken when its manager can't say which program it runs:
    /// the version it points at was removed, or none is set.
    static func shims(_ directories: [String]) async -> Outcome {
        let active = shimManagers.filter { manager in
            directories.contains(Paths.home.appending(path: manager.folder).path) && Shell.isAvailable(manager.tool)
        }
        guard !active.isEmpty else { return .skip("No version manager shims on PATH") }
        var issues: [DoctorIssue] = []
        var total = 0
        for manager in active {
            let folder = Paths.home.appending(path: manager.folder).path
            let names = Array(executables(in: folder).sorted().prefix(150))
            total += names.count
            let broken = await withTaskGroup(of: String?.self) { group in
                var pending = names[...]
                var broken: [String] = []
                for _ in 0..<8 {
                    guard let name = pending.popFirst() else { break }
                    group.addTask { await shimRuns(manager.tool, name) ? nil : name }
                }
                while let result = await group.next() {
                    if let result { broken.append(result) }
                    if let name = pending.popFirst() { group.addTask { await shimRuns(manager.tool, name) ? nil : name } }
                }
                return broken.sorted()
            }
            guard !broken.isEmpty else { continue }
            let command = ([manager.tool] + manager.rehash).joined(separator: " ")
            issues.append(DoctorIssue(
                "\(Format.count(broken.count, "\(manager.tool) shim")) that don't run", broken.joined(separator: ", "),
                "They point at a version that was removed or isn't selected. Regenerating the shims drops the stale ones; select a version for the rest.",
                command: command, path: folder,
                fix: DoctorFix(id: "rehash:\(manager.tool)", label: "Regenerate shims", command: command)))
        }
        if issues.isEmpty { return .pass("\(Format.count(total, "shim")) all resolve") }
        return Outcome(status: .warn, summary: "\(issues.map { $0.title }.joined(separator: ", "))", issues: issues)
    }

    static func shimRuns(_ manager: String, _ name: String) async -> Bool {
        (try? await Shell.run(manager, ["which", name], timeout: .seconds(10)))?.ok ?? true
    }

    // MARK: Shell

    static func shellStartup() async -> Outcome {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let name = (shell as NSString).lastPathComponent
        // Best of two, so a cold disk cache doesn't count against the config.
        var best: TimeInterval?
        for _ in 0..<2 {
            let started = Date()
            do {
                _ = try await Shell.run(shell, ["-i", "-c", "exit"], timeout: .seconds(10), quiet: false)
            } catch LowtideError.commandFailed(let message) where message.hasSuffix("timed out") {
                return Outcome(status: .fail, summary: "\(name) took over 10 s to start", issues: [DoctorIssue(
                    "Interactive shell hangs", "Something in your shell config waits for input or the network.",
                    "Run it with tracing to see which line stalls.", command: "\(name) -xv -i -c exit")])
            } catch {
                return .skip("\(shell) couldn't start: \(error.localizedDescription)")
            }
            let elapsed = Date().timeIntervalSince(started)
            best = min(best ?? elapsed, elapsed)
        }
        return startupOutcome(name: name, milliseconds: Int(((best ?? 0) * 1000).rounded()))
    }

    static func startupOutcome(name: String, milliseconds: Int) -> Outcome {
        let summary = "\(name) starts in \(milliseconds) ms"
        let advice = DoctorIssue(
            "Slow shell startup",
            "Every new terminal tab waits for this. Version managers (nvm), conda and oh-my-zsh plugins are the usual cause.",
            "Profile with `zmodload zsh/zprof` at the top of ~/.zshrc and `zprof` at the bottom; switch nvm to fnm or lazy-load it.",
            command: "zsh -i -c 'zmodload zsh/zprof; source ~/.zshrc; zprof' | head -30")
        switch milliseconds {
        case ...400: return .pass(summary)
        case ...1000: return Outcome(status: .warn, summary: summary, issues: [advice])
        default: return Outcome(status: .fail, summary: summary, issues: [advice])
        }
    }

    // MARK: Git and SSH

    static func gitIdentity() async -> Outcome {
        guard Shell.isAvailable("git") else { return .skip("git isn't installed") }
        func value(_ key: String) async -> String? {
            guard let out = try? await Shell.run("git", ["config", "--global", key]), out.ok else { return nil }
            let text = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        async let name = value("user.name")
        async let email = value("user.email")
        let (n, e) = await (name, email)
        if let n, let e { return .pass("\(n) <\(e)>") }
        let missing = [n == nil ? "user.name" : nil, e == nil ? "user.email" : nil].compactMap { $0 }.joined(separator: " and ")
        return Outcome(status: .warn, summary: "\(missing) not set", issues: [DoctorIssue(
            "Commits have no proper author",
            "Global git \(missing) is empty, so commits fall back to your login and host name.",
            "Set your name and email once for every repository.",
            command: "git config --global user.name \"Your Name\" && git config --global user.email you@example.com")])
    }

    /// Files in ~/.ssh that must not be readable by anyone else.
    static func privateSSHFiles(_ folder: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        return files.filter { file in
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return false }
            let name = file.lastPathComponent
            if name == "config" || name == "authorized_keys" { return true }
            guard !name.hasSuffix(".pub"), let handle = try? FileHandle(forReadingFrom: file) else { return false }
            defer { try? handle.close() }
            let head = String(decoding: (try? handle.read(upToCount: 64)) ?? Data(), as: UTF8.self)
            return head.hasPrefix("-----BEGIN") && head.contains("PRIVATE KEY")
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func mode(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    }

    static func sshPermissions(_ folder: URL) -> Outcome {
        guard isDirectory(folder.path) else { return .skip("No ~/.ssh folder") }
        var problems: [String] = []
        if let mode = mode(folder), mode & 0o777 & ~0o700 != 0 { problems.append("~/.ssh is \(String(mode & 0o777, radix: 8))") }
        for file in privateSSHFiles(folder) {
            if let mode = mode(file), mode & 0o777 & ~0o600 != 0 {
                problems.append("\(file.lastPathComponent) is \(String(mode & 0o777, radix: 8))")
            }
        }
        if problems.isEmpty { return .pass("~/.ssh and private keys are private to you") }
        return Outcome(status: .fail, summary: "\(Format.count(problems.count, "file")) too open", issues: [DoctorIssue(
            "Private SSH files readable by others", problems.joined(separator: "\n"),
            "OpenSSH refuses keys other users can read (\"UNPROTECTED PRIVATE KEY FILE\").",
            fix: DoctorFix(id: "ssh-permissions", label: "Fix permissions", command: "chmod 700 ~/.ssh && chmod 600 <private keys, config>"))])
    }

    static func sshAgent() async -> Outcome {
        guard let out = try? await Shell.run("ssh-add", ["-l"], timeout: .seconds(10)) else { return .skip("ssh-add isn't available") }
        return sshAgentOutcome(status: out.status, stdout: out.stdout)
    }

    static func sshAgentOutcome(status: Int32, stdout: String) -> Outcome {
        switch status {
        case 0: return .pass("\(Format.count(stdout.split(whereSeparator: \.isNewline).count, "key")) loaded")
        case 1: return .pass("Agent running, no keys loaded yet")
        default:
            return Outcome(status: .warn, summary: "No SSH agent reachable", issues: [DoctorIssue(
                "SSH agent not running",
                "Every connection with a passphrase-protected key asks for the passphrase again.",
                "Add `UseKeychain yes` and `AddKeysToAgent yes` under `Host *` in ~/.ssh/config.")])
        }
    }

    // MARK: System

    static func xcodeTools() async -> Outcome {
        if let out = try? await Shell.run("/usr/bin/xcode-select", ["-p"], timeout: .seconds(10)), out.ok {
            return .pass(out.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return Outcome(status: .fail, summary: "Not installed", issues: [DoctorIssue(
            "Command Line Tools missing",
            "Compilers, git and make come from them; Homebrew and native npm modules fail without.",
            "Install them with Apple's installer.", command: "xcode-select --install")])
    }

    static func diskSpace(_ folder: URL = Paths.home) -> Outcome {
        guard let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
              let total = values.volumeTotalCapacity, total > 0,
              let available = values.volumeAvailableCapacityForImportantUsage else { return .skip("Couldn't read disk usage") }
        return diskOutcome(available: available, total: Int64(total))
    }

    static func diskOutcome(available: Int64, total: Int64) -> Outcome {
        let summary = "\(Format.bytes(available)) free of \(Format.bytes(total))"
        let advice = DoctorIssue("Disk almost full", "Builds, Docker and Xcode slow down or fail when the disk fills up.",
                                 "Open Cleanup to reclaim caches and old build folders.")
        switch available * 100 / max(total, 1) {
        case ...4: return Outcome(status: .fail, summary: summary, issues: [advice])
        case ...9: return Outcome(status: .warn, summary: summary, issues: [advice])
        default: return .pass(summary)
        }
    }

    // MARK: Homebrew

    /// `brew doctor` prints one "Warning:" paragraph per problem.
    static func parseBrewDoctor(_ output: String) -> [(String, String)] {
        output.components(separatedBy: "Warning: ").dropFirst().map { block in
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let newline = trimmed.firstIndex(of: "\n") else { return (trimmed, "") }
            return (trimmed[..<newline].trimmingCharacters(in: .whitespaces),
                    trimmed[trimmed.index(after: newline)...].trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// The command Homebrew suggests inside a warning, if it names one.
    static func suggestedCommand(_ detail: String) -> String? {
        let lines = detail.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if let line = lines.first(where: { $0.hasPrefix("brew ") && !$0.contains("<") }) { return line }
        if let range = detail.range(of: #"`(brew [^`<]+)`"#, options: .regularExpression) {
            return String(detail[range].dropFirst().dropLast())
        }
        return nil
    }

    static func brewDoctor() async -> Outcome {
        guard Shell.isAvailable("brew") else { return .skip("Homebrew isn't installed") }
        guard let out = try? await Shell.run("brew", ["doctor"], timeout: .seconds(180)) else { return .skip("brew doctor couldn't run") }
        return brewDoctorOutcome(status: out.status, output: out.stdout + "\n" + out.stderr)
    }

    static func brewDoctorOutcome(status: Int32, output: String) -> Outcome {
        let warnings = parseBrewDoctor(output)
        if status == 0 || warnings.isEmpty { return .pass("Your system is ready to brew") }
        let issues = warnings.map { title, detail in
            DoctorIssue(title, detail, "Follow Homebrew's advice above; most warnings are safe to ignore if everything builds.",
                        command: suggestedCommand(detail))
        }
        return Outcome(status: .warn, summary: Format.count(issues.count, "warning"), issues: issues)
    }

    /// `formula: dep dep` for every formula missing a dependency.
    static func parseBrewMissing(_ output: String) -> [String: [String]] {
        var missing: [String: [String]] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let dependencies = line[line.index(after: colon)...].split(whereSeparator: \.isWhitespace).map(String.init)
            if !dependencies.isEmpty { missing[line[..<colon].trimmingCharacters(in: .whitespaces)] = dependencies }
        }
        return missing
    }

    static func missingDependencies() async -> [String] {
        guard let out = try? await Shell.run("brew", ["missing"], timeout: .seconds(120)) else { return [] }
        return Array(Set(parseBrewMissing(out.stdout).values.flatMap { $0 })).sorted()
    }

    static func brewMissing() async -> Outcome {
        guard Shell.isAvailable("brew") else { return .skip("Homebrew isn't installed") }
        let dependencies = await missingDependencies()
        if dependencies.isEmpty { return .pass("Every installed formula has its dependencies") }
        let command = "brew install \(dependencies.joined(separator: " "))"
        return Outcome(status: .fail, summary: "Broken formulae", issues: [DoctorIssue(
            dependencies.count == 1 ? "1 missing dependency" : "\(dependencies.count) missing dependencies",
            dependencies.joined(separator: ", "), "Tools that need them crash at launch with \"Library not loaded\".",
            command: command, fix: DoctorFix(id: "brew-missing", label: "Install them", command: command))])
    }

    // MARK: Node, runtimes, network

    static func npmPrefix() async -> Outcome {
        guard Shell.isAvailable("npm") else { return .skip("npm isn't installed") }
        guard let out = try? await Shell.run("npm", ["config", "get", "prefix"], timeout: .seconds(20)), out.ok else {
            return .skip("Couldn't read the npm prefix")
        }
        let prefix = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let library = "\(prefix)/lib/node_modules"
        let target = isDirectory(library) ? library : prefix
        let attributes = try? FileManager.default.attributesOfItem(atPath: target)
        let owner = (attributes?[.ownerAccountID] as? NSNumber)?.uint32Value
        let mode = (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0
        if owner == getuid(), mode & 0o200 != 0 { return .pass("Installs into \(Paths.tilde(prefix))") }
        return Outcome(status: .warn, summary: "\(Paths.tilde(target)) isn't yours", issues: [DoctorIssue(
            "Global npm installs need sudo",
            "Running npm with sudo leaves root-owned files that break later installs.",
            "Install Node through fnm or Homebrew, or set a user prefix.",
            command: "npm config set prefix ~/.npm-global")])
    }

    static func runtimesEOL(_ runtimes: [LanguageRuntime]) -> Outcome {
        let ended = runtimes.filter { $0.standing == .eol }.map { runtime in
            DoctorIssue("\(runtime.name) \(runtime.version) no longer gets fixes",
                        "Its release line is past end of life: security issues stay unpatched.",
                        runtime.upgradeHint == nil ? "Upgrade to a supported release line." : "Move to a supported line with its manager.",
                        command: runtime.upgradeHint, path: runtime.path)
        }
        if ended.isEmpty { return .pass("\(Format.count(runtimes.count, "runtime")) on supported release lines") }
        return Outcome(status: .warn, summary: "\(ended.count) past end of life", issues: ended)
    }

    static let registryURLs: [(String, String)] = [
        ("npm", "https://registry.npmjs.org/"), ("crates.io", "https://index.crates.io/config.json"),
        ("PyPI", "https://pypi.org/simple/"), ("Go proxy", "https://proxy.golang.org/"),
        ("GitHub", "https://github.com/"), ("Homebrew", "https://formulae.brew.sh/"),
    ]

    static func registries() async -> Outcome {
        let results = await withTaskGroup(of: (String, Bool, Int).self) { group in
            for (name, address) in registryURLs {
                group.addTask {
                    let started = Date()
                    var request = URLRequest(url: URL(string: address)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
                    request.httpMethod = "HEAD"
                    let response = try? await HTTP.session.data(for: request).1 as? HTTPURLResponse
                    return (name, response.map { $0.statusCode < 500 } ?? false, Int(Date().timeIntervalSince(started) * 1000))
                }
            }
            var all: [(String, Bool, Int)] = []
            for await result in group { all.append(result) }
            return all
        }
        let down = registryURLs.map(\.0).filter { name in results.contains { $0.0 == name && !$0.1 } }
        if down.isEmpty {
            return .pass("\(results.count) registries reachable, slowest \(results.map(\.2).max() ?? 0) ms")
        }
        return Outcome(status: .fail, summary: "\(down.joined(separator: ", ")) unreachable", issues: [DoctorIssue(
            "Registry unreachable", down.joined(separator: ", "),
            "Updates and installs from these will fail. Check VPN, proxy (HTTPS_PROXY) or DNS settings.")])
    }

    // MARK: Fixes

    /// Applies a fix and says what it did.
    public static func fix(_ id: String) async throws -> String {
        await Shell.ready()
        if id.hasPrefix("broken-links:") {
            let directory = String(id.dropFirst("broken-links:".count))
            // Only folders on PATH, and only links still broken now.
            guard pathDirectories().contains(directory), !isSystemDirectory(directory) else {
                throw LowtideError.denied("Not a PATH folder")
            }
            let links = brokenLinks(in: directory)
            guard !links.isEmpty else { return "Nothing left to remove" }
            let refused = await Trash.move(links).refused
            if let first = refused.first { throw LowtideError.denied(first.reason) }
            return "Moved \(Format.count(links.count, "link")) to the Trash"
        }
        if id.hasPrefix("rehash:") {
            let tool = String(id.dropFirst("rehash:".count))
            guard let manager = shimManagers.first(where: { $0.tool == tool }) else { throw LowtideError.invalid("Unknown fix \(id)") }
            try await ToolCommand.output(manager.tool, manager.rehash)
            return "Regenerated \(tool)'s shims"
        }
        switch id {
        case "ssh-permissions":
            let folder = Paths.home.appending(path: ".ssh")
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            let files = privateSSHFiles(folder)
            for file in files { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
            return "Secured ~/.ssh and \(Format.count(files.count, "file"))"
        case "brew-missing":
            let dependencies = await missingDependencies()
            guard !dependencies.isEmpty else { return "Nothing missing" }
            try await ToolLock.shared.with("brew") {
                _ = try await ToolCommand.stream(Invocation("brew", ["install"] + dependencies)) { _ in }
            }
            return "Installed \(dependencies.joined(separator: ", "))"
        default:
            throw LowtideError.invalid("Unknown fix \(id)")
        }
    }

    /// Opens a shell config at the offending line: VS Code, Cursor or Zed
    /// when installed (they jump to the line), else the default text editor.
    public static func openInEditor(_ source: String) async throws {
        await Shell.ready()
        var file = source
        var line = 1
        if let colon = source.lastIndex(of: ":"), let number = Int(source[source.index(after: colon)...]) {
            file = String(source[..<colon])
            line = number
        }
        guard shellFiles.contains(where: { Paths.home.appending(path: $0).path == file }) else {
            throw LowtideError.denied("Only shell config files open from here")
        }
        let target = "\(file):\(line)"
        for editor in ["code", "cursor", "zed"] where Shell.isAvailable(editor) {
            try await ToolCommand.output(editor, editor == "zed" ? [target] : ["-g", target])
            return
        }
        try await ToolCommand.output("/usr/bin/open", ["-t", file])
    }
}
