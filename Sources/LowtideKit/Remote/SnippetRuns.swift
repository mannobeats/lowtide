import Foundation

/// Where a snippet goes and what came back from each place.
public enum SnippetRuns {
    /// The saved hosts a set of targets reaches: all, or the chosen hosts
    /// plus every host in the chosen groups and their subgroups.
    public static func hosts(for targets: Set<SnippetTarget>, in resolution: HostResolution) -> [RemoteHost] {
        if targets.contains(.allHosts) { return resolution.hosts }
        var ids = Set<String>(), groups = Set<String>()
        for target in targets {
            switch target {
            case .host(let id): ids.insert(id)
            case .group(let id): groups.insert(id)
            default: break
            }
        }
        let inGroups = Set(resolution.hosts(inGroups: groups).map(\.id))
        return resolution.hosts.filter { ids.contains($0.id) || inGroups.contains($0.id) }
    }

    /// "Local · 3 hosts", or what to do when nothing is saved.
    public static func summary(_ targets: Set<SnippetTarget>, in resolution: HostResolution) -> String {
        var labels: [String] = []
        if targets.contains(.local) { labels.append("Local") }
        if targets.contains(.allHosts) {
            labels.append("All hosts (\(resolution.hosts.count))")
        } else {
            let count = hosts(for: targets, in: resolution).count
            if count > 0 { labels.append(Format.count(count, "host")) }
        }
        return labels.isEmpty ? "Choose targets when running" : labels.joined(separator: " · ")
    }

    /// Picking all hosts clears single hosts and groups, and the other way round.
    public static func toggle(_ target: SnippetTarget, in selected: Set<SnippetTarget>) -> Set<SnippetTarget> {
        var next = selected
        if next.contains(target) {
            next.remove(target)
            return next
        }
        next.insert(target)
        switch target {
        case .allHosts:
            next = next.filter { if case .host = $0 { false } else if case .group = $0 { false } else { true } }
        case .host, .group:
            next.remove(.allHosts)
        default:
            break
        }
        return next
    }

    /// One target's run.
    public struct Result: Equatable, Sendable, Identifiable {
        public enum State: Equatable, Sendable {
            case running
            case succeeded
            case failed(Int32?)
            case couldNotStart(String)
        }

        public var id: String
        public var title: String
        public var subtitle: String
        public var state: State
        public var output: String
        public var started: Date
        public var ended: Date?

        public var duration: TimeInterval? { ended.map { $0.timeIntervalSince(started) } }

        public init(id: String, title: String, subtitle: String, state: State, output: String, started: Date, ended: Date? = nil) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.state = state
            self.output = output
            self.started = started
            self.ended = ended
        }
    }

    static let outputLimit = 64_000

    static func trim(_ text: String) -> String {
        text.count > outputLimit ? "…" + String(text.suffix(outputLimit)) : text
    }

    /// Runs on this Mac in the login shell, without a terminal.
    public static func runLocally(_ command: String, timeout: TimeInterval = 600) async -> (state: Result.State, output: String) {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
        let result = await RemoteProcess.run(shell, ["-l", "-c", command], environment: Shell.environment(quiet: false),
                                             timeout: timeout)
        return (state(result), trim(join(result)))
    }

    /// Runs on a saved host without a terminal. Saved secrets answer
    /// through askpass; any other prompt shows in the app.
    public static func runRemotely(_ command: String, endpoint: SSHEndpoint, secrets: [AskpassSecret], label: String,
                                   timeout: TimeInterval = 600) async -> (state: Result.State, output: String) {
        var environment = RemoteProcess.sshEnvironment()
        let ticket: String?
        let args: [String]
        do {
            args = try SSHCommand.run(endpoint, command: command, batch: secrets.isEmpty)
            if secrets.isEmpty {
                ticket = nil
            } else {
                let registered = try AskpassServer.shared.register(secrets: secrets, interactive: true, label: label)
                environment.merge(registered.environment) { _, new in new }
                ticket = registered.token
            }
        } catch {
            return (.couldNotStart(error.localizedDescription), "")
        }
        defer { if let ticket { AskpassServer.shared.unregister(ticket) } }
        let result = await RemoteProcess.run(SSHCommand.program, args, environment: environment, timeout: timeout) { pid in
            if let ticket { AskpassServer.shared.attach(ticket, pid: pid) }
        }
        // 255 is ssh's own failure (couldn't connect or sign in).
        if result.status == 255, result.stdout.isEmpty {
            let reason = result.stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "ssh failed"
            return (.couldNotStart(reason), trim(result.stderr))
        }
        return (state(result), trim(join(result)))
    }

    static func state(_ result: RemoteProcess.Result) -> Result.State {
        if result.timedOut { return .failed(nil) }
        return result.status == 0 ? .succeeded : .failed(result.status)
    }

    static func join(_ result: RemoteProcess.Result) -> String {
        let err = result.stderr.split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("Warning: Permanently added") }.joined(separator: "\n")
        let out = result.stdout.trimmingCharacters(in: .newlines)
        if err.isEmpty { return out }
        return out.isEmpty ? err : out + "\n" + err
    }
}
