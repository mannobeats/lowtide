import Foundation

/// A package ecosystem, or a piped install script (`curl … | sh`).
public enum Ecosystem: String, Codable, Sendable, CaseIterable {
    case npm, python, homebrew, cargo, ruby, go, script

    /// Where an install of this kind fetches from, for findings.
    public var registry: String {
        switch self {
        case .npm: "npm registry"
        case .python: "PyPI"
        case .homebrew: "Homebrew"
        case .cargo: "crates.io"
        case .ruby: "RubyGems"
        case .go: "the Go proxy"
        case .script: "the script's host"
        }
    }

    /// The ecosystem's name, for people.
    public var label: String {
        switch self {
        case .npm: "npm"
        case .python: "Python"
        case .homebrew: "Homebrew"
        case .cargo: "Cargo"
        case .ruby: "RubyGems"
        case .go: "Go"
        case .script: "Install script"
        }
    }

    /// Hosts an install in this ecosystem normally talks to.
    public var expectedHosts: [String] {
        let github = ["github.com", "codeload.github.com", "objects.githubusercontent.com", "raw.githubusercontent.com"]
        switch self {
        case .npm:
            return ["registry.npmjs.org", "registry.yarnpkg.com", "registry.npmjs.com", "npm.pkg.github.com", "nodejs.org",
                    github[0], github[1], github[2]]
        case .python: return ["pypi.org", "files.pythonhosted.org", github[0], github[2]]
        case .homebrew:
            return ["formulae.brew.sh", "ghcr.io", "pkg-containers.githubusercontent.com", github[0], github[2], github[3]]
        case .cargo: return ["crates.io", "index.crates.io", "static.crates.io", github[0], github[1]]
        case .ruby: return ["rubygems.org", "index.rubygems.org", github[0]]
        case .go: return ["proxy.golang.org", "sum.golang.org", "storage.googleapis.com", github[0], github[1]]
        case .script: return [github[0], github[2], github[3]]
        }
    }

    /// Casks and scripts fetch from each vendor's own site: an unexpected
    /// destination there is normal, not worth a warning.
    public var vendorDownloads: Bool { self == .homebrew || self == .script }
}

/// What a written path means.
public enum FilePlace: String, Codable, Sendable, Comparable, CaseIterable {
    /// Credentials: keys, tokens, cloud config.
    case sensitive
    /// Makes something run again later: launch agents, shell start-up files.
    case persistence
    /// Inside the folder the command ran in.
    case project
    /// Package caches.
    case cache
    /// Homebrew prefixes, /Applications, /Library.
    case system
    /// Anywhere else in the home folder.
    case home

    var order: Int { Self.allCases.firstIndex(of: self)! }
    public static func < (a: FilePlace, b: FilePlace) -> Bool { a.order < b.order }

    public var label: String {
        switch self {
        case .cache: "Package caches"
        case .home: "Elsewhere in your home folder"
        case .persistence: "Start-up items"
        case .project: "Project folder"
        case .sensitive: "Credentials"
        case .system: "System folders"
        }
    }

    /// Credentials and start-up files keep every path.
    public var risky: Bool { self == .sensitive || self == .persistence }
}

/// How serious a finding is.
public enum Severity: String, Codable, Sendable, Comparable {
    case info, notice, alert
    var rank: Int { self == .info ? 0 : self == .notice ? 1 : 2 }
    public static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
}

public struct RunFinding: Codable, Sendable, Hashable {
    public var severity: Severity
    public var text: String
    /// Which rule raised it (`startup`, `keychain`, `unexpected-host`…);
    /// nil in receipts saved before.
    public var rule: String?
    /// What triggered it: the paths, hosts or command line, in full.
    public var evidence: [String]

    public init(severity: Severity, text: String, rule: String?, evidence: [String]) {
        self.severity = severity
        self.text = text
        self.rule = rule
        self.evidence = evidence
    }

    enum CodingKeys: String, CodingKey { case severity, text, rule, evidence }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        severity = try c.decode(Severity.self, forKey: .severity)
        text = try c.decode(String.self, forKey: .text)
        rule = try c.decodeIfPresent(String.self, forKey: .rule)
        evidence = try c.decodeIfPresent([String].self, forKey: .evidence) ?? []
    }
}

public struct RunDest: Codable, Sendable, Hashable {
    public var ip: String
    public var host: String?
    public var org: String?
    public var country: String?
    public var bytesIn: UInt64
    public var bytesOut: UInt64
    /// Where this kind of install is expected to connect.
    public var expected: Bool
    public var apps: [String]
    public var ports: [UInt16]

    public init(ip: String, host: String? = nil, org: String? = nil, country: String? = nil, bytesIn: UInt64 = 0,
                bytesOut: UInt64 = 0, expected: Bool = false, apps: [String] = [], ports: [UInt16] = []) {
        self.ip = ip
        self.host = host
        self.org = org
        self.country = country
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.expected = expected
        self.apps = apps
        self.ports = ports
    }

    enum CodingKeys: String, CodingKey { case ip, host, org, country, bytesIn, bytesOut, expected, apps, ports }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ip = try c.decode(String.self, forKey: .ip)
        host = try c.decodeIfPresent(String.self, forKey: .host)
        org = try c.decodeIfPresent(String.self, forKey: .org)
        country = try c.decodeIfPresent(String.self, forKey: .country)
        bytesIn = try c.decodeIfPresent(UInt64.self, forKey: .bytesIn) ?? 0
        bytesOut = try c.decodeIfPresent(UInt64.self, forKey: .bytesOut) ?? 0
        expected = try c.decodeIfPresent(Bool.self, forKey: .expected) ?? false
        apps = try c.decodeIfPresent([String].self, forKey: .apps) ?? []
        ports = try c.decodeIfPresent([UInt16].self, forKey: .ports) ?? []
    }

    /// The name shown for it.
    public var name: String { host ?? ip }
}

/// A process worth a line: notable, or left running.
public struct RunChild: Codable, Sendable, Hashable {
    public var pid: Int32
    public var name: String
    public var command: String
    public var reason: String?
    public var severity: Severity?
    /// The rule behind `reason` (see `RunRules.notable`).
    public var rule: String?
    /// Start time (ms), so a stop never reaches a later process given the
    /// same pid (nil in receipts saved before it was recorded).
    public var started: UInt64?

    public init(pid: Int32, name: String, command: String, reason: String? = nil, severity: Severity? = nil,
                rule: String? = nil, started: UInt64? = nil) {
        self.pid = pid
        self.name = name
        self.command = command
        self.reason = reason
        self.severity = severity
        self.rule = rule
        self.started = started
    }
}

/// Every process a run started, for its process tree.
public struct RunProc: Codable, Sendable, Hashable {
    public var pid: Int32
    public var ppid: Int32
    public var name: String
    public var command: String
    public var started: UInt64
    /// When it was last seen alive; nil while it is still running.
    public var ended: UInt64?
    /// The install script it is (`postinstall`, `build script`).
    public var script: String?
    /// The package whose script it is (`esbuild@0.21.5`).
    public var package: String?

    public init(pid: Int32, ppid: Int32, name: String, command: String, started: UInt64, ended: UInt64? = nil,
                script: String? = nil, package: String? = nil) {
        self.pid = pid
        self.ppid = ppid
        self.name = name
        self.command = command
        self.started = started
        self.ended = ended
        self.script = script
        self.package = package
    }
}

/// One folder's changes within a place.
public struct FileGroup: Codable, Sendable, Hashable {
    /// As shown: `node_modules/react`, `~/.npm/_cacache`.
    public var name: String
    /// The folder itself, for Show in Finder (empty in older receipts).
    public var path: String
    public var count: Int
    /// Changes that created the file, and files gone when it ended.
    public var added: Int
    public var removed: Int
    /// A few of its paths.
    public var samples: [String]

    public init(name: String, path: String = "", count: Int = 0, added: Int = 0, removed: Int = 0, samples: [String] = []) {
        self.name = name
        self.path = path
        self.count = count
        self.added = added
        self.removed = removed
        self.samples = samples
    }

    enum CodingKeys: String, CodingKey { case name, path, count, added, removed, samples }

    /// Receipts saved before folders had details kept `[name, count]` pairs.
    public init(from decoder: Decoder) throws {
        if var pair = try? decoder.unkeyedContainer() {
            self.init(name: try pair.decode(String.self), count: try pair.decode(Int.self))
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try c.decode(String.self, forKey: .name),
                  path: try c.decodeIfPresent(String.self, forKey: .path) ?? "",
                  count: try c.decodeIfPresent(Int.self, forKey: .count) ?? 0,
                  added: try c.decodeIfPresent(Int.self, forKey: .added) ?? 0,
                  removed: try c.decodeIfPresent(Int.self, forKey: .removed) ?? 0,
                  samples: try c.decodeIfPresent([String].self, forKey: .samples) ?? [])
    }
}

public struct PlaceSummary: Codable, Sendable, Hashable {
    public var place: FilePlace
    public var count: Int
    /// The busiest folders.
    public var groups: [FileGroup]
    /// Every path, for credentials and start-up files.
    public var paths: [String]

    public init(place: FilePlace, count: Int, groups: [FileGroup] = [], paths: [String] = []) {
        self.place = place
        self.count = count
        self.groups = groups
        self.paths = paths
    }
}

/// A package the run wrote, read from the paths that changed.
public struct RunPackage: Codable, Sendable, Hashable {
    public var name: String
    public var version: String?
    public var path: String
    public var files: Int
    /// Every file it changed is gone: it was removed.
    public var removed: Bool

    public init(name: String, version: String?, path: String, files: Int, removed: Bool) {
        self.name = name
        self.version = version
        self.path = path
        self.files = files
        self.removed = removed
    }
}

public struct NetSummary: Codable, Sendable, Hashable {
    public var bytesIn: UInt64 = 0
    public var bytesOut: UInt64 = 0
    public var dests: [RunDest] = []
    public init(bytesIn: UInt64 = 0, bytesOut: UInt64 = 0, dests: [RunDest] = []) {
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.dests = dests
    }
}

public struct ProcSummary: Codable, Sendable, Hashable {
    public var count: Int = 0
    public var notable: [RunChild] = []
    public var leftRunning: [RunChild] = []
    public var tree: [RunProc] = []

    public init(count: Int = 0, notable: [RunChild] = [], leftRunning: [RunChild] = [], tree: [RunProc] = []) {
        self.count = count
        self.notable = notable
        self.leftRunning = leftRunning
        self.tree = tree
    }

    enum CodingKeys: String, CodingKey { case count, notable, leftRunning, tree }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 0
        notable = try c.decodeIfPresent([RunChild].self, forKey: .notable) ?? []
        leftRunning = try c.decodeIfPresent([RunChild].self, forKey: .leftRunning) ?? []
        tree = try c.decodeIfPresent([RunProc].self, forKey: .tree) ?? []
    }
}

public struct FileSummary: Codable, Sendable, Hashable {
    public var total: Int = 0
    public var places: [PlaceSummary] = []
    public init(total: Int = 0, places: [PlaceSummary] = []) {
        self.total = total
        self.places = places
    }
}

/// A finished command or install, written up: a receipt.
public struct Run: Codable, Sendable, Hashable, Identifiable {
    public enum Source: String, Codable, Sendable { case terminal, detected }

    public var id: UInt64
    /// `terminal` (one of Lowtide's terminals) or `detected` (anywhere else).
    public var source: Source
    public var ptyId: String?
    public var command: String
    public var cwd: String?
    /// Milliseconds since the epoch.
    public var started: UInt64
    public var ended: UInt64
    /// Set for package installs.
    public var ecosystem: Ecosystem?
    /// The worst finding (`info` when there is nothing to say).
    public var verdict: Severity
    public var findings: [RunFinding]
    public var net: NetSummary
    public var procs: ProcSummary
    public var files: FileSummary
    public var packages: [RunPackage]

    public init(id: UInt64, source: Source, ptyId: String? = nil, command: String, cwd: String? = nil, started: UInt64,
                ended: UInt64, ecosystem: Ecosystem? = nil, verdict: Severity = .info, findings: [RunFinding] = [],
                net: NetSummary = .init(), procs: ProcSummary = .init(), files: FileSummary = .init(),
                packages: [RunPackage] = []) {
        self.id = id
        self.source = source
        self.ptyId = ptyId
        self.command = command
        self.cwd = cwd
        self.started = started
        self.ended = ended
        self.ecosystem = ecosystem
        self.verdict = verdict
        self.findings = findings
        self.net = net
        self.procs = procs
        self.files = files
        self.packages = packages
    }

    enum CodingKeys: String, CodingKey {
        case id, source, ptyId, command, cwd, started, ended, ecosystem, verdict, findings, net, procs, files, packages
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UInt64.self, forKey: .id)
        source = (try? c.decode(Source.self, forKey: .source)) ?? .detected
        ptyId = try c.decodeIfPresent(String.self, forKey: .ptyId)
        command = try c.decode(String.self, forKey: .command)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        started = try c.decode(UInt64.self, forKey: .started)
        ended = try c.decode(UInt64.self, forKey: .ended)
        ecosystem = try c.decodeIfPresent(Ecosystem.self, forKey: .ecosystem)
        verdict = try c.decodeIfPresent(Severity.self, forKey: .verdict) ?? .info
        findings = try c.decodeIfPresent([RunFinding].self, forKey: .findings) ?? []
        net = try c.decodeIfPresent(NetSummary.self, forKey: .net) ?? .init()
        procs = try c.decodeIfPresent(ProcSummary.self, forKey: .procs) ?? .init()
        files = try c.decodeIfPresent(FileSummary.self, forKey: .files) ?? .init()
        packages = try c.decodeIfPresent([RunPackage].self, forKey: .packages) ?? []
    }

    public var startedAt: Date { Date(timeIntervalSince1970: Double(started) / 1000) }
    public var endedAt: Date { Date(timeIntervalSince1970: Double(ended) / 1000) }
    /// How long it took, in milliseconds.
    public var took: UInt64 { ended >= started ? ended - started : 0 }
}

/// A run in progress, for the live indicator.
public struct ActiveRun: Sendable, Hashable, Identifiable {
    public var id: UInt64
    public var source: Run.Source
    public var ptyId: String?
    public var command: String
    public var started: UInt64
    public var ecosystem: Ecosystem?
    public var processes: Int
    public var dests: Int
    public var files: Int
}

// MARK: - Wording

public enum RunWords {
    /// `42s`, `3m 05s`, `1h 04m`: a run's length.
    public static func duration(_ ms: UInt64) -> String {
        let seconds = Int((Double(ms) / 1000).rounded())
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m \(String(format: "%02d", seconds % 60))s" }
        return "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
    }

    /// The pieces of a receipt: what it reached, changed and left behind.
    public static func receiptParts(_ run: Run) -> [String] {
        var parts: [String] = []
        let dests = run.net.dests.count
        if dests > 0 {
            let sent = run.net.bytesOut > 0 ? " ↑ \(Format.bytes(run.net.bytesOut))" : ""
            parts.append(Format.count(dests, "host") + sent)
        }
        if run.files.total > 0 { parts.append("\(Format.count(run.files.total, "file")) changed") }
        let lingering = run.procs.leftRunning.count
        if lingering > 0 { parts.append("\(lingering) left running") }
        if parts.isEmpty { parts.append("touched nothing outside itself") }
        return parts
    }

    static let managers: Set<String> = ["npm", "pnpm", "yarn", "bun", "pip", "pipx", "uv", "brew", "cargo", "gem", "bundle", "go"]

    /// The tool that ran an install (`pnpm`, `pip`), or its ecosystem's name.
    public static func manager(_ run: Run) -> String {
        var tool = shortCommand(run.command).split(separator: " ").first.map(String.init) ?? ""
        if tool.hasSuffix("3") { tool.removeLast() }
        if managers.contains(tool) { return tool }
        return run.ecosystem?.label ?? "Other"
    }

    /// The same command's last run in the same folder, before this one.
    public static func previousRun(_ run: Run, in runs: [Run]) -> Run? {
        let command = shortCommand(run.command)
        return runs.first { $0.started < run.started && $0.cwd == run.cwd && shortCommand($0.command) == command }
    }

    /// `npm install left-pad`, from a long interpreter command line
    /// (`/bin/bash -p …/brew.sh upgrade jq` reads `brew upgrade jq`).
    public static func shortCommand(_ command: String) -> String {
        let words = command.split(separator: " ").map(String.init)
        let interpreters: Set<String> = ["node", "python", "python3", "bash", "sh", "zsh", "ruby"]
        // The interpreter and its own flags (`-p`, `-m`) come before the tool.
        var start = 0
        while start < words.count - 1,
              interpreters.contains(RunRules.tool(words[start])) || (start > 0 && words[start].hasPrefix("-")) {
            start += 1
        }
        var line = words.dropFirst(start).map(RunRules.tool).joined(separator: " ")
        for (script, name) in [("npm-cli.js", "npm"), ("brew.sh", "brew")] where line.hasPrefix(script) {
            let rest = line.dropFirst(script.count)
            if rest.isEmpty || rest.first == " " { line = name + rest }
        }
        return line
    }

    public static func verdictLabel(_ run: Run) -> String {
        switch run.verdict {
        case .alert: "Needs a look"
        case .notice: "Worth knowing"
        case .info: run.ecosystem == nil ? "Done" : "Clean"
        }
    }
}
