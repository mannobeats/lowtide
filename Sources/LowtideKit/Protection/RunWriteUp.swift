import Foundation

/// Turning what a run did into its receipt: files grouped by place and
/// folder, the packages it wrote, its process tree, and the findings.
/// Pure functions over what the engine collected, tested in
/// `ProtectionRunTests`.
public enum RunWriteUp {
    /// Folders kept per place, and paths kept per folder.
    static let keepGroups = 30
    static let keepSamples = 6

    /// A changed path: its place, and whether an event created it.
    public struct Change: Sendable, Hashable {
        public var place: FilePlace
        public var created: Bool
        public init(place: FilePlace, created: Bool) {
            self.place = place
            self.created = created
        }
    }

    /// Changes in each place: how many, per folder, and (for risky places)
    /// every path.
    public static func files(_ paths: [String: Change], gone: Set<String>, home: String, cwd: String?) -> FileSummary {
        struct Tally { var count = 0; var groups: [String: FileGroup] = [:]; var paths: [String] = [] }
        var byPlace: [FilePlace: Tally] = [:]
        for (path, change) in paths {
            let place = change.place
            var tally = byPlace[place] ?? Tally()
            tally.count += 1
            let name = RunRules.group(of: path, home: home, cwd: cwd, place: place)
            var group = tally.groups[name] ?? FileGroup(name: name, path: {
                switch place {
                case .project: return "\(cwd ?? home)/\(name)"
                case .system: return name
                default: return name.replacingFirst("~", with: home)
                }
            }())
            group.count += 1
            if gone.contains(path) {
                group.removed += 1
            } else if change.created {
                group.added += 1
            }
            if group.samples.count < keepSamples { group.samples.append(path) }
            tally.groups[name] = group
            if place.risky, tally.paths.count < 40 { tally.paths.append(path) }
            byPlace[place] = tally
        }
        let places = byPlace.map { place, tally in
            let groups = tally.groups.values
                .sorted { ($1.count, $0.name) < ($0.count, $1.name) }
                .prefix(keepGroups)
                .map { group -> FileGroup in
                    var sorted = group
                    sorted.samples.sort()
                    return sorted
                }
            return PlaceSummary(place: place, count: tally.count, groups: Array(groups), paths: tally.paths.sorted())
        }.sorted { $0.place < $1.place }
        return FileSummary(total: paths.count, places: places)
    }

    /// The packages an install wrote, from the paths it changed.
    /// `version` reads a plain node_modules package's own package.json.
    public static func packages(_ paths: some Collection<String>, gone: Set<String>,
                                version: (String) -> String? = nodeVersion) -> [RunPackage] {
        var byDir: [String: RunPackage] = [:]
        for path in paths {
            guard let (name, version, dir) = RunRules.package(of: path) else { continue }
            var package = byDir[dir] ?? RunPackage(name: name, version: version, path: dir, files: 0, removed: true)
            package.files += 1
            package.removed = package.removed && gone.contains(path)
            byDir[dir] = package
        }
        for (dir, package) in byDir where package.version == nil && !package.removed {
            byDir[dir]?.version = version(dir)
        }
        // pnpm links each package from its store into node_modules: one entry.
        let stored = Set(byDir.values.filter { $0.path.contains("/.pnpm/") }.map(\.name))
        let list = byDir.values
            .filter { $0.path.contains("/.pnpm/") || !stored.contains($0.name) }
            .sorted { ($0.name, $0.version ?? "") < ($1.name, $1.version ?? "") }
        return Array(list.prefix(400))
    }

    public static func nodeVersion(_ dir: String) -> String? {
        guard let data = FileManager.default.contents(atPath: dir + "/package.json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["version"] as? String
    }

    /// A process the engine followed.
    public struct Seen: Sendable {
        public var comm: String
        public var ppid: Int32
        public var started: UInt64
        public var lastSeen: UInt64
        public var args: [String]
        /// `(event, package)` when it is an install script.
        public var script: (String, String?)?

        public init(comm: String, ppid: Int32, started: UInt64, lastSeen: UInt64, args: [String], script: (String, String?)?) {
            self.comm = comm
            self.ppid = ppid
            self.started = started
            self.lastSeen = lastSeen
            self.args = args
            self.script = script
        }
    }

    static func child(_ pid: Int32, _ seen: Seen) -> RunChild {
        RunChild(pid: pid, name: seen.comm, command: RunRules.displayCommand(seen.args), started: seen.started)
    }

    /// Notable children, what is still running, and the whole tree.
    /// `alive` says whether a pid still is the process that was seen.
    public static func processes(_ pids: [Int32: Seen], root: Int32, alive: (Int32, Seen) -> Bool) -> ProcSummary {
        var notable: [RunChild] = []
        var left: [RunChild] = []
        let ordered = pids.sorted { ($0.value.started, $0.key) < ($1.value.started, $1.key) }
        for (pid, seen) in ordered {
            if pid != root, let (severity, rule, reason) = RunRules.notable(seen.comm, seen.args) {
                var found = child(pid, seen)
                found.severity = severity
                found.rule = rule
                found.reason = reason
                notable.append(found)
            }
            if alive(pid, seen) {
                var found = child(pid, seen)
                if RunRules.expectedDaemon(seen.comm) {
                    found.reason = "a helper tools keep around"
                    found.severity = .info
                }
                left.append(found)
            }
        }
        // Every process in start order. A script's own children inherit its
        // environment, so only the first process of each script is named as it.
        let tree = ordered.prefix(150).map { pid, seen -> RunProc in
            let inherited = pids[seen.ppid]?.script
            let script = seen.script.flatMap { mine in
                inherited.map { $0.0 == mine.0 && $0.1 == mine.1 } == true ? nil : mine
            }
            return RunProc(pid: pid, ppid: seen.ppid, name: seen.comm, command: RunRules.displayCommand(seen.args),
                           started: seen.started, ended: alive(pid, seen) ? nil : seen.lastSeen,
                           script: script?.0, package: script?.1)
        }
        return ProcSummary(count: pids.count, notable: Array(notable.prefix(40)), leftRunning: Array(left.prefix(20)),
                           tree: Array(tree))
    }

    static func plural(_ n: Int, _ word: String) -> String { n == 1 ? "1 \(word)" : "\(n) \(word)s" }

    /// Everything worth saying, worst first.
    public static func findings(_ run: Run, rootAlive: Bool, home: String) -> [RunFinding] {
        let install = run.ecosystem != nil
        // A plain command you typed is trusted more than a package's scripts.
        func weigh(_ severity: Severity) -> Severity {
            if install || severity == .info { return severity }
            return severity == .alert ? .notice : .info
        }
        var found: [RunFinding] = []
        for summary in run.files.places {
            let rule: String, text: String
            switch summary.place {
            case .sensitive: (rule, text) = ("credentials", "Changed credentials")
            case .persistence: (rule, text) = ("startup", "Changed what runs at start-up")
            default: continue
            }
            let first = summary.paths.first.map { $0.replacingFirst(home, with: "~") } ?? ""
            let more = max(summary.paths.count - 1, 0)
            found.append(RunFinding(severity: weigh(.alert), text: "\(text): \(first)\(more > 0 ? " and \(more) more" : "")",
                                    rule: rule, evidence: summary.paths))
        }
        for child in run.procs.notable {
            guard let severity = child.severity, let reason = child.reason else { continue }
            found.append(RunFinding(severity: weigh(severity), text: "\(child.name) \(reason): \(child.command)",
                                    rule: child.rule ?? "process", evidence: [child.command]))
        }
        if let ecosystem = run.ecosystem {
            let odd = run.net.dests.filter { !$0.expected }.map(\.name)
            if !odd.isEmpty {
                let shown = odd.prefix(4).joined(separator: ", ")
                let more = odd.count > 4 ? " +\(odd.count - 4)" : ""
                found.append(RunFinding(
                    severity: ecosystem.vendorDownloads ? .info : .notice,
                    text: "Reached \(plural(odd.count, "destination")) outside \(ecosystem.registry): \(shown)\(more)",
                    rule: "unexpected-host", evidence: odd))
            }
        }
        let lingering = run.procs.leftRunning.filter { $0.severity == nil }
        if rootAlive, run.source == .terminal {
            found.append(RunFinding(severity: .info, text: "Moved to the background: it is still running", rule: "background",
                                    evidence: []))
        } else if !lingering.isEmpty {
            found.append(RunFinding(severity: weigh(.notice),
                                    text: "Left running: \(lingering.map(\.name).joined(separator: ", "))",
                                    rule: "left-running", evidence: lingering.map(\.command)))
        }
        // Stable: equal severities keep the order they were found in.
        return found.enumerated().sorted { ($1.element.severity, $0.offset) < ($0.element.severity, $1.offset) }.map(\.element)
    }

    /// Short runs that touched nothing are not worth a receipt.
    public static func worthKeeping(_ run: Run) -> Bool {
        run.ecosystem != nil || run.took >= 2000 || !run.net.dests.isEmpty || run.files.total > 0 || !run.findings.isEmpty
    }

    /// Fills in `findings` and `verdict`.
    public static func judge(_ run: inout Run, rootAlive: Bool, home: String) {
        run.findings = findings(run, rootAlive: rootAlive, home: home)
        run.verdict = run.findings.map(\.severity).max() ?? .info
    }
}
