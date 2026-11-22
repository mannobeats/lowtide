import Foundation

/// One autocomplete suggestion under the prompt.
public struct TerminalSuggestion: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case argument, command, executable, history, option, path, project, snippet, subcommand
    }

    public var description: String
    /// The part of `label` that matched what was typed, for highlighting.
    public var highlight: String
    /// The whole line after accepting it.
    public var insertText: String
    public var kind: Kind
    public var label: String
    /// Changes or deletes data: review before running.
    public var risky: Bool

    public var id: String { "\(kind.rawValue):\(insertText)" }
}

/// Everything ranking looks at, gathered by the pane.
public struct SuggestionContext {
    public var completion: CompletionContext?
    /// `local`, or `ssh:<host id>`.
    public var contextKey: String
    public var cwd: String
    /// Things the app knows that the shell's folder doesn't.
    public var formulae: [String] = []
    public var hosts: [String] = []
    public var history: [CommandHistoryRow] = []
    /// The last command run in this terminal, for next-command prediction.
    public var lastCommand: String?
    /// Entries of a folder relative to the cwd; nil while loading.
    public var listDirectory: (String) -> [CompletionEntry]? = { _ in nil }
    /// Newest first.
    public var shellHistory: [String] = []
    /// Saved snippets: (name, command).
    public var snippets: [(name: String, content: String)] = []
    public var now: Int = Vault.now()

    public init(completion: CompletionContext?, contextKey: String, cwd: String) {
        self.completion = completion
        self.contextKey = contextKey
        self.cwd = cwd
    }
}

/// Ranks what to suggest for the line being typed: snippets, history (this
/// terminal and this folder first), the folder's project tasks, known
/// commands, and per-command completions from the specs. Lower rank
/// is better.
public enum TerminalIntelligence {
    static let maxSuggestions = 7

    static let catalog: [(command: String, description: String, platforms: [String]?)] = [
        ("git log --oneline --graph --decorate -20", "Recent history as a graph", nil),
        ("git pull --rebase", "Update the branch without merge commits", nil),
        ("docker system df", "Docker disk usage", nil),
        ("docker compose up -d", "Start the Compose stack", nil),
        ("kubectl get pods -A", "Every pod in the cluster", nil),
        ("sudo lsof -iTCP -sTCP:LISTEN -n -P", "What is listening on which port", nil),
        ("lsof -i :3000", "What holds port 3000", nil),
        ("df -h", "Free disk space", nil),
        ("du -sh * | sort -h", "Folder sizes, largest last", nil),
        ("ps aux | grep", "Find a process", nil),
        ("top -o cpu", "Processes by CPU", nil),
        ("tail -f", "Follow a log file", nil),
        ("grep -rn", "Search file contents", nil),
        ("find . -name", "Find files by name", nil),
        ("curl -I", "HTTP response headers", nil),
        ("curl -fsSL", "Fetch a URL, fail on HTTP errors", nil),
        ("dig +short", "Resolve DNS", nil),
        ("ping -c 4", "Is it reachable", nil),
        ("openssl s_client -connect", "Inspect a TLS endpoint", nil),
        ("chmod 600", "Owner-only file", nil),
        ("brew services list", "Homebrew background services", ["macos"]),
        ("sudo systemctl status", "Inspect a service", ["linux"]),
        ("sudo systemctl restart", "Restart a service", ["linux"]),
        ("journalctl -xeu", "Service errors", ["linux"]),
        ("sudo apt update && sudo apt upgrade", "Upgrade Debian packages", ["linux"]),
        ("free -h", "Memory usage", ["linux"]),
    ]

    static let riskPattern = #"(?:^|\s)(?:sudo\b|rm\s+-[^\n]*r[^\n]*f|dd\s+if=|mkfs\b|shutdown\b|reboot\b|chmod\s+-R\s+777\b|git\s+(?:reset\s+--hard|push\s+[^\n]*--force\b|clean\s+-[^\n]*f)|docker\s+system\s+prune)|curl[^\n|]*\|\s*(?:sh|bash)\b"#

    public static func isRisky(_ command: String) -> Bool {
        command.range(of: riskPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: Matching

    static func fuzzyScore(_ value: String, _ rawQuery: String) -> Double {
        let candidate = value.lowercased()
        let query = rawQuery.lowercased().trimmingCharacters(in: .whitespaces)
        if candidate.hasPrefix(query) { return 0 }
        if let direct = candidate.range(of: query) {
            return 45 + Double(candidate.distance(from: candidate.startIndex, to: direct.lowerBound))
        }
        let queryTokens = query.split(whereSeparator: \.isWhitespace)
        let candidateTokens = candidate.split(whereSeparator: \.isWhitespace)
        var tokenIndex = 0
        var gap = 0
        for token in queryTokens {
            guard let found = candidateTokens.indices.first(where: { $0 >= tokenIndex && candidateTokens[$0].hasPrefix(token) }) else {
                return query.contains(" ") ? .infinity : subsequenceScore(candidate, query)
            }
            gap += found - tokenIndex
            tokenIndex = found + 1
        }
        return 20 + Double(gap * 4) + Double(max(0, candidateTokens.count - queryTokens.count))
    }

    static func subsequenceScore(_ candidate: String, _ query: String) -> Double {
        let c = Array(candidate), q = Array(query)
        var qi = 0, gaps = 0, previous = -1
        var index = 0
        while index < c.count && qi < q.count {
            if c[index] == q[qi] {
                if previous >= 0 { gaps += index - previous - 1 }
                previous = index
                qi += 1
            }
            index += 1
        }
        return qi == q.count ? 120 + Double(gaps) : .infinity
    }

    static func shellEscape(_ value: String) -> String {
        let safe = !value.isEmpty && value.unicodeScalars.allSatisfy {
            ($0.isASCII && (CharacterSet.alphanumerics.contains($0))) || "_./@%+=:,~-".unicodeScalars.contains($0)
        }
        return safe ? value : "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Parsing the line

    struct ParsedLine: Equatable {
        /// The word under the cursor, unquoted.
        var current: String
        /// Where it starts in the raw input, in characters.
        var currentStart: Int
        /// Finished words of the command being typed (after `&&`, `|`, `;`).
        var words: [String]
    }

    /// Splits the line into shell words, honouring quotes and separators.
    static func parseLine(_ input: String) -> ParsedLine {
        var words: [String] = []
        var buffer = ""
        var quote: Character?
        var start = 0
        for (index, ch) in input.enumerated() {
            if let q = quote {
                if ch == q { quote = nil } else { buffer.append(ch) }
                continue
            }
            switch ch {
            case "\"", "'":
                quote = ch
            case " ", "\t":
                if !buffer.isEmpty { words.append(buffer) }
                buffer = ""
                start = index + 1
            case "|", "&", ";":
                words = []
                buffer = ""
                start = index + 1
            default:
                buffer.append(ch)
            }
        }
        while let first = words.first,
              CompletionSpecs.wrappers.contains(first) || first.range(of: #"^[A-Za-z_]\w*="#, options: .regularExpression) != nil {
            words.removeFirst()
        }
        return ParsedLine(current: buffer, currentStart: start, words: words)
    }

    // MARK: Frequency and next-command models

    /// How often each command prefix (`git`, `git switch`, `git switch main`) ran.
    static func prefixCounts(_ history: [CommandHistoryRow], _ shell: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        func add(_ command: String, _ weight: Int) {
            let words = parseLine(command + " ").words.prefix(3)
            for length in stride(from: 1, through: words.count, by: 1) {
                counts[words.prefix(length).joined(separator: " "), default: 0] += weight
            }
        }
        for row in history { add(row.command, row.useCount) }
        for command in shell { add(command, 1) }
        return counts
    }

    /// What usually follows each command, read from the shell's ordered history (newest first).
    static func transitions(_ shell: [String]) -> [String: [String: Int]] {
        var map: [String: [String: Int]] = [:]
        guard shell.count > 1 else { return map }
        for index in 0..<(shell.count - 1) {
            let previous = shell[index + 1], next = shell[index]
            if previous == next { continue }
            map[previous, default: [:]][next, default: 0] += 1
        }
        return map
    }

    // MARK: Suggestions

    struct Ranked {
        var suggestion: TerminalSuggestion
        var rank: Double
    }

    static func lineSuggestion(_ input: String, _ query: String, _ command: String, _ description: String,
                               _ kind: TerminalSuggestion.Kind, _ adjustment: Double, match matchValue: String? = nil) -> Ranked? {
        if command == input { return nil }
        let match = fuzzyScore(matchValue ?? command, query)
        guard match.isFinite else { return nil }
        let label = command.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? command
        return Ranked(suggestion: TerminalSuggestion(description: description, highlight: query, insertText: command,
                                                     kind: kind, label: label, risky: isRisky(command)),
                      rank: match + adjustment)
    }

    static func historyAdjustment(_ item: CommandHistoryRow, _ context: SuggestionContext) -> Double {
        let sameContext = item.contextKey == context.contextKey
        let sameDirectory = !context.cwd.isEmpty && item.cwd == context.cwd
        let ageDays = max(0, Double(context.now - item.lastUsedAt) / 86_400_000)
        let recency = max(0, 28 - log2(ageDays + 1) * 7)
        let usage = min(28, log2(Double(item.useCount) + 1) * 7)
        let accepted = min(16, log2(Double(item.acceptCount) + 1) * 5)
        let failing: Double = item.failureCount > item.successCount ? 12 : 0
        return failing - recency - usage - accepted - (sameContext ? 42 : 0) - (sameDirectory ? 28 : 0)
    }

    static func shortAgo(_ ms: Int, now: Int) -> String {
        let minutes = (now - ms) / 60_000
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    static func historyLabel(_ item: CommandHistoryRow, _ context: SuggestionContext) -> String {
        let place = !context.cwd.isEmpty && item.cwd == context.cwd ? "this folder"
            : item.contextKey == context.contextKey ? "this terminal" : "all terminals"
        return "\(item.useCount)× in \(place) · \(shortAgo(item.lastUsedAt, now: context.now))"
    }

    /// Whole-line candidates: snippets, history, project tasks, known commands.
    static func lineSuggestions(_ input: String, _ context: SuggestionContext, prefixOnly: Bool,
                                followers: [String: Int]?) -> [Ranked] {
        let query = input.trimmingCharacters(in: .whitespaces)
        var out: [Ranked] = []
        func push(_ candidate: Ranked?) {
            guard var candidate, !(prefixOnly && !candidate.suggestion.insertText.hasPrefix(input)) else { return }
            if let followed = followers?[candidate.suggestion.insertText] {
                candidate.rank -= min(45, log2(Double(followed) + 1) * 18)
                if candidate.suggestion.description.isEmpty { candidate.suggestion.description = "Usually runs next" }
            }
            out.append(candidate)
        }
        // A multi-line snippet would run every line but the last immediately.
        for snippet in context.snippets where !snippet.content.contains("\n") {
            push(lineSuggestion(input, query, snippet.content, snippet.name, .snippet, -70,
                                match: "\(snippet.name) \(snippet.content)"))
        }
        for item in context.history {
            push(lineSuggestion(input, query, item.command, historyLabel(item, context), .history,
                                historyAdjustment(item, context)))
        }
        for (index, command) in context.shellHistory.enumerated() {
            push(lineSuggestion(input, query, command, "", .history, -35 + min(25, Double(index) / 20)))
        }
        if !prefixOnly {
            for task in projectTasks(context.completion) {
                push(lineSuggestion(input, query, task.command, task.description, .project, -5))
            }
            let platform = context.completion?.platform
            for entry in catalog {
                let elsewhere = entry.platforms.map { platforms in platform.map { !platforms.contains($0) } ?? false } ?? false
                // Known commands only on a real word match, never a scattered one.
                if let candidate = lineSuggestion(input, query, entry.command, entry.description, .command, elsewhere ? 55 : 20),
                   candidate.rank < 100 {
                    push(candidate)
                }
            }
        }
        return out
    }

    /// This folder's tasks as runnable lines: `pnpm dev`, `make build`, `just fmt`.
    static func projectTasks(_ completion: CompletionContext?) -> [(command: String, description: String)] {
        guard let completion else { return [] }
        let runner = switch completion.packageRunner ?? .npm {
        case .bun: "bun run"
        case .npm: "npm run"
        case .pnpm: "pnpm"
        case .yarn: "yarn"
        }
        return completion.packageScripts.map { ("\(runner) \(shellEscape($0))", "package.json script") }
            + completion.makeTargets.map { ("make \($0)", "Makefile target") }
            + completion.justRecipes.map { ("just \($0)", "just recipe") }
    }

    struct Candidate {
        var description: String
        var kind: TerminalSuggestion.Kind
        /// Folders keep the cursor inside the word so the next level completes.
        var open = false
        var value: String
    }

    static func generatorLabel(_ generator: CompletionSpec.Generator) -> (String, TerminalSuggestion.Kind) {
        switch generator {
        case .branches: ("Branch", .project)
        case .changed: ("Changed", .project)
        case .formulae: ("Installed", .argument)
        case .hosts: ("Host", .argument)
        case .just: ("just recipe", .project)
        case .make: ("make target", .project)
        case .remotes: ("Remote", .project)
        case .scripts: ("Script", .project)
        case .services: ("Compose service", .project)
        case .paths, .dirs: ("", .argument)
        }
    }

    static func generatorValues(_ generator: CompletionSpec.Generator, _ context: SuggestionContext) -> [String] {
        let c = context.completion
        switch generator {
        case .branches: return c?.gitBranches ?? []
        case .changed: return c?.gitChanged ?? []
        case .formulae: return context.formulae
        case .hosts:
            var seen = Set<String>()
            return ((c?.sshHosts ?? []) + context.hosts).filter { seen.insert($0).inserted }
        case .just: return c?.justRecipes ?? []
        case .make: return c?.makeTargets ?? []
        case .remotes: return c?.gitRemotes ?? []
        case .scripts: return c?.packageScripts ?? []
        case .services: return c?.composeServices ?? []
        case .paths, .dirs: return []
        }
    }

    /// Files and folders for the word being typed, at any depth (`src/lib/`).
    static func pathCandidates(_ current: String, dirsOnly: Bool, _ context: SuggestionContext) -> [Candidate] {
        let slash = current.lastIndex(of: "/")
        let dir = slash.map { String(current[...$0]) } ?? ""
        let name = (slash.map { String(current[current.index(after: $0)...]) } ?? current).lowercased()
        let entries = dir.isEmpty ? context.completion?.entries : context.listDirectory(dir)
        return (entries ?? [])
            .filter { (!dirsOnly || $0.isDirectory) && (name.hasPrefix(".") || !$0.name.hasPrefix(".")) }
            .filter { $0.name.lowercased().hasPrefix(name) }
            .prefix(60)
            .map { Candidate(description: $0.isDirectory ? "Folder" : "File", kind: .path, open: $0.isDirectory,
                             value: dir + $0.name + ($0.isDirectory ? "/" : "")) }
    }

    /// Walks the spec along the finished words: `git stash` → the stash spec.
    static func resolveSpec(_ words: [String]) -> (path: [String], positional: Int, spec: CompletionSpec)? {
        guard let first = words.first, var spec = CompletionSpecs.all[first] else { return nil }
        var path = [first]
        var positional = 0
        for word in words.dropFirst() where !word.hasPrefix("-") {
            if positional == 0, let next = spec.subcommand(word) {
                spec = next
                path.append(word)
            } else {
                positional += 1
            }
        }
        return (path, positional, spec)
    }

    static func specCandidates(_ parsed: ParsedLine, _ context: SuggestionContext) -> (candidates: [Candidate], path: [String])? {
        guard let resolved = resolveSpec(parsed.words) else { return nil }
        if parsed.current.hasPrefix("-") {
            return (resolved.spec.options.map { Candidate(description: $0.1, kind: .option, value: $0.0) }, resolved.path)
        }
        var candidates: [Candidate] = []
        if resolved.positional == 0 {
            for (value, sub) in resolved.spec.subcommands {
                candidates.append(Candidate(description: sub.description ?? "", kind: .subcommand, value: value))
            }
        }
        for generator in resolved.spec.generators(at: resolved.positional) {
            if generator == .paths || generator == .dirs {
                // Remote shells have no local folder to list.
                if context.completion != nil {
                    candidates += pathCandidates(parsed.current, dirsOnly: generator == .dirs, context)
                }
                continue
            }
            let (description, kind) = generatorLabel(generator)
            candidates += generatorValues(generator, context).map { Candidate(description: description, kind: kind, value: $0) }
        }
        return (candidates, resolved.path)
    }

    static func kindBase(_ kind: TerminalSuggestion.Kind) -> Double {
        switch kind {
        case .option: 12
        case .path: 4
        case .project: -2
        default: 0
        }
    }

    /// Completes the word under the cursor from the command's spec.
    static func wordSuggestions(_ input: String, _ parsed: ParsedLine, _ context: SuggestionContext,
                                counts: () -> [String: Int]) -> [Ranked] {
        guard let result = specCandidates(parsed, context) else { return [] }
        let counts = counts()
        let typed = parsed.current.lowercased()
        let before = String(input.prefix(parsed.currentStart))
        var seen = Set<String>()
        var out: [Ranked] = []
        for (order, candidate) in result.candidates.enumerated() {
            guard candidate.value != parsed.current, seen.insert(candidate.value).inserted else { continue }
            let lower = candidate.value.lowercased()
            var match = Double.infinity
            if lower.hasPrefix(typed) {
                match = 0
            } else if typed.count >= 2, candidate.kind != .path {
                match = subsequenceScore(lower, typed) - 60
            }
            guard match.isFinite else { continue }
            let used = counts[(result.path + [candidate.value]).prefix(3).joined(separator: " ")] ?? 0
            let insertText = before + shellEscape(candidate.value) + (candidate.open ? "" : " ")
            let rank = -60 + match + kindBase(candidate.kind) + Double(min(order, 30)) * 0.2
                - min(40, log2(Double(used) + 1) * 12)
            out.append(Ranked(suggestion: TerminalSuggestion(description: candidate.description, highlight: parsed.current,
                                                             insertText: insertText, kind: candidate.kind,
                                                             label: candidate.value, risky: isRisky(insertText)),
                              rank: rank))
        }
        return out
    }

    /// Command names while the first word is typed.
    static func commandSuggestions(_ input: String, _ parsed: ParsedLine, _ context: SuggestionContext,
                                   counts: () -> [String: Int]) -> [Ranked] {
        let typed = parsed.current
        guard parsed.words.isEmpty, typed.count >= 2, let completion = context.completion else { return [] }
        let counts = counts()
        let before = String(input.prefix(parsed.currentStart))
        return completion.executables.lazy.filter { $0.hasPrefix(typed) && $0 != typed }.prefix(200).map { name in
            Ranked(suggestion: TerminalSuggestion(description: CompletionSpecs.all[name]?.description ?? "", highlight: typed,
                                                  insertText: before + name + " ", kind: .executable, label: name, risky: false),
                   rank: 25 + Double(name.count) * 0.5 - min(60, log2(Double(counts[name] ?? 0) + 1) * 14))
        }
    }

    static func finish(_ suggestions: [Ranked]) -> [TerminalSuggestion] {
        var best: [String: Ranked] = [:]
        var order: [String] = []
        for item in suggestions {
            let key = String(item.suggestion.insertText.reversed().drop { $0.isWhitespace }.reversed())
            if let current = best[key] {
                if item.rank < current.rank { best[key] = item }
            } else {
                best[key] = item
                order.append(key)
            }
        }
        return order.compactMap { best[$0] }
            .sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.suggestion.label.count < $1.suggestion.label.count }
            .prefix(maxSuggestions).map(\.suggestion)
    }

    /// Suggestions for the line typed so far, best first (at most seven).
    public static func suggestions(for input: String, context: SuggestionContext) -> [TerminalSuggestion] {
        if input.contains("\n") { return [] }
        let query = input.trimmingCharacters(in: .whitespaces)
        let parsed = parseLine(input)
        var cachedCounts: [String: Int]?
        let counts = {
            if let cachedCounts { return cachedCounts }
            let value = prefixCounts(context.history, context.shellHistory)
            cachedCounts = value
            return value
        }
        let words = wordSuggestions(input, parsed, context, counts: counts)
        // Once a known command is being given arguments, only history lines
        // that continue exactly what was typed compete with the spec's completions.
        let inArguments = !parsed.words.isEmpty && CompletionSpecs.all[parsed.words[0]] != nil
        let followers = context.lastCommand.flatMap { transitions(context.shellHistory)[$0] }
        if query.count < 2 && words.isEmpty {
            // One letter is enough when it starts what usually runs next.
            guard query.count == 1, let followers, followers.keys.contains(where: { $0.hasPrefix(query) }) else { return [] }
        }
        return finish(words + commandSuggestions(input, parsed, context, counts: counts)
            + lineSuggestions(input, context, prefixOnly: inArguments, followers: followers))
    }
}
