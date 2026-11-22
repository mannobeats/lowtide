import Foundation

/// Where an installed release line stands in its support cycle.
public enum RuntimeStanding: String, Sendable, Codable {
    /// Its line no longer gets security fixes.
    case eol
    /// Supported line, but a newer patch in the same line exists.
    case behind
    case current
    case unknown
}

/// A language runtime on this Mac: which version runs, who installed it,
/// what else is shadowed on PATH, and its support cycle.
public struct LanguageRuntime: Sendable, Identifiable, Hashable, Codable {
    public var id: String
    public var name: String
    public var command: String
    public var version: String
    public var path: String
    /// What installed the active copy: Homebrew, fnm, rustup, macOS…
    public var manager: String
    /// Other executables of the same name later on PATH, never run.
    public var shadowed: [String]
    public var cycle: String?
    /// Newest release in the installed line.
    public var cycleLatest: String?
    /// Newest release overall.
    public var latest: String?
    /// `YYYY-MM-DD` the installed line stops getting fixes.
    public var eol: String?
    public var lts: Bool
    public var standing: RuntimeStanding
    /// The command that moves this runtime forward with its own manager.
    public var upgradeHint: String?
}

public enum Runtimes {
    struct Definition: Sendable {
        var id: String
        var name: String
        var command: String
        var versionArguments: [String]
        /// Product slug on endoflife.date.
        var lifecycle: String?
    }

    static let definitions: [Definition] = [
        Definition(id: "node", name: "Node.js", command: "node", versionArguments: ["--version"], lifecycle: "nodejs"),
        Definition(id: "python", name: "Python", command: "python3", versionArguments: ["--version"], lifecycle: "python"),
        Definition(id: "ruby", name: "Ruby", command: "ruby", versionArguments: ["--version"], lifecycle: "ruby"),
        Definition(id: "go", name: "Go", command: "go", versionArguments: ["version"], lifecycle: "go"),
        Definition(id: "rust", name: "Rust", command: "rustc", versionArguments: ["--version"], lifecycle: "rust"),
        Definition(id: "php", name: "PHP", command: "php", versionArguments: ["--version"], lifecycle: "php"),
        Definition(id: "deno", name: "Deno", command: "deno", versionArguments: ["--version"], lifecycle: "deno"),
        Definition(id: "bun", name: "Bun", command: "bun", versionArguments: ["--version"], lifecycle: "bun"),
        Definition(id: "java", name: "Java", command: "java", versionArguments: ["-version"], lifecycle: nil),
    ]

    /// Every runtime found, in a fixed order, inspected in parallel.
    public static func all() async -> [LanguageRuntime] {
        await Shell.ready()
        return await withTaskGroup(of: (Int, LanguageRuntime?).self) { group in
            for (index, definition) in definitions.enumerated() {
                group.addTask { (index, await inspect(definition)) }
            }
            var found: [(Int, LanguageRuntime)] = []
            for await (index, runtime) in group { if let runtime { found.append((index, runtime)) } }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    static func inspect(_ definition: Definition) async -> LanguageRuntime? {
        guard let path = Shell.resolve(definition.command) else { return nil }
        // macOS ships `/usr/bin/java` as a stub that offers to install a JDK.
        if definition.id == "java", path.hasPrefix("/usr/bin"), !(await hasSystemJDK()) { return nil }
        async let cycles = lifecycle(definition.lifecycle)
        guard let out = try? await Shell.run(definition.command, definition.versionArguments, timeout: .seconds(20)), out.ok,
              let version = parseVersion(out.stdout + "\n" + out.stderr) else { return nil }
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let manager = manager(real: real, path: path)
        var runtime = LanguageRuntime(
            id: definition.id, name: definition.name, command: definition.command, version: version, path: path,
            manager: manager, shadowed: shadowed(definition.command, active: path, pathList: Shell.path),
            lts: false, standing: .unknown, upgradeHint: upgradeHint(definition.id, manager: manager, real: real))
        if let cycles = await cycles { applyLifecycle(&runtime, cycles: cycles, today: today()) }
        // Version managers install a release line; stay on the one in use.
        runtime.upgradeHint = runtime.upgradeHint?.replacingOccurrences(of: "{cycle}", with: runtime.cycle ?? "--lts")
        return runtime
    }

    static func lifecycle(_ product: String?) async -> [ReleaseCycle]? {
        guard let product else { return nil }
        return await Lifecycles.shared.cycles(product)
    }

    static func hasSystemJDK() async -> Bool {
        (try? await Shell.run("/usr/libexec/java_home", [], timeout: .seconds(10)))?.ok ?? false
    }

    /// The first dotted number in the output: `v26.1.0`, `Python 3.14.7`,
    /// `go version go1.27.1 darwin/arm64`, `openjdk version "21.0.2"`.
    static func parseVersion(_ output: String) -> String? {
        for raw in output.split(whereSeparator: { $0.isWhitespace || $0 == "\"" }) {
            let token = raw.drop { !($0.isASCII && $0.isNumber) }
            let parts = token.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count >= 2, let first = parts.first, !first.isEmpty,
                  first.allSatisfy({ $0.isASCII && $0.isNumber }), parts[1].first?.isNumber == true else { continue }
            let trimmed = String(token).reversed().drop { !($0.isLetter || $0.isNumber) }
            return String(trimmed.reversed())
        }
        return nil
    }

    static let managerRules: [(String, String)] = [
        ("/fnm", "fnm"), ("/.nvm/", "nvm"), ("/.volta/", "Volta"), ("/mise/", "mise"), ("/.asdf/", "asdf"),
        ("/.pyenv/", "pyenv"), ("/.rbenv/", "rbenv"), ("/.rustup/", "rustup"), ("/.cargo/bin/", "rustup"),
        ("/.bun/", "Bun installer"), ("/.deno/", "Deno installer"), ("/uv/python/", "uv"),
        ("/opt/homebrew/", "Homebrew"), ("/usr/local/Cellar/", "Homebrew"),
        ("/Library/Java/JavaVirtualMachines/", "JDK installer"), ("/Android Studio.app/", "Android Studio"),
        ("/Library/Frameworks/Python.framework/", "python.org installer"),
    ]

    static func manager(real: String, path: String) -> String {
        if let rule = managerRules.first(where: { real.contains($0.0) || path.contains($0.0) }) { return rule.1 }
        return real.hasPrefix("/usr/bin") || real.hasPrefix("/Library/Developer") ? "macOS" : "Manual install"
    }

    static func upgradeHint(_ id: String, manager: String, real: String) -> String? {
        switch manager {
        case "Homebrew":
            // `/opt/homebrew/Cellar/node@22/22.1.0/bin/node` → `node@22`.
            guard let range = real.range(of: "/Cellar/"),
                  let formula = real[range.upperBound...].split(separator: "/").first else { return nil }
            return "brew upgrade \(formula)"
        case "fnm": return "fnm install {cycle} && fnm default {cycle}"
        case "nvm": return "nvm install {cycle} --reinstall-packages-from=current"
        case "Volta": return "volta install \(id)"
        case "mise": return "mise upgrade \(id)"
        case "asdf": return "asdf install \(id) latest"
        case "pyenv": return "pyenv install 3 && pyenv global 3"
        case "rbenv": return "rbenv install -l"
        case "rustup": return "rustup update"
        case "Bun installer": return "bun upgrade"
        case "Deno installer": return "deno upgrade"
        case "uv": return "uv python upgrade"
        default: return nil
        }
    }

    /// Other copies later on PATH: a different `node` some script or editor
    /// with a shorter PATH would pick up instead.
    static func shadowed(_ command: String, active: String, pathList: String) -> [String] {
        var seen = [URL(fileURLWithPath: active).resolvingSymlinksInPath().path]
        var shadowed: [String] = []
        for directory in pathList.split(separator: ":") {
            let candidate = "\(directory)/\(command)"
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue,
                  FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            let real = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
            if !seen.contains(real) {
                seen.append(real)
                shadowed.append(candidate)
            }
        }
        return shadowed
    }

    /// Finds the release line the installed version belongs to (the longest
    /// cycle whose segments prefix the version: `3.14` for `3.14.7`, `26`
    /// for `26.1.0`) and rates it against today's date.
    static func applyLifecycle(_ runtime: inout LanguageRuntime, cycles: [ReleaseCycle], today: String) {
        runtime.latest = cycles.first?.latest
        let segments = runtime.version.split(separator: ".").map(String.init)
        let matching = cycles.filter { cycle in
            let parts = cycle.cycle.split(separator: ".").map(String.init)
            return parts.count <= segments.count && zip(parts, segments).allSatisfy { $0 == $1 }
        }
        guard let cycle = matching.max(by: { $0.cycle.split(separator: ".").count < $1.cycle.split(separator: ".").count }) else { return }
        runtime.cycle = cycle.cycle
        runtime.cycleLatest = cycle.latest
        runtime.lts = switch cycle.lts {
        case .flag(let flag): flag
        case .date(let date): date <= today
        case nil: false
        }
        var ended = false
        switch cycle.eol {
        case .flag(let flag): ended = flag
        case .date(let date):
            runtime.eol = date
            ended = date <= today
        case nil: break
        }
        let behind = cycle.latest.map { PackageVersion.isNewer($0, than: runtime.version) } ?? false
        runtime.standing = ended ? .eol : behind ? .behind : .current
    }

    /// Today's UTC date as `YYYY-MM-DD`.
    static func today(_ date: Date = .now) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// One release line on endoflife.date.
public struct ReleaseCycle: Sendable, Hashable {
    /// A date (`2027-04-30`) or a plain yes/no, as the API gives either.
    public enum Mark: Sendable, Hashable {
        case flag(Bool)
        case date(String)
    }

    public var cycle: String
    public var latest: String?
    public var lts: Mark?
    public var eol: Mark?

    /// Reads the API's answer; cycles and versions can be numbers or strings.
    static func parse(_ data: Data) -> [ReleaseCycle]? {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        func text(_ value: Any?) -> String? {
            switch value {
            case let string as String: string
            case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID(): number.stringValue
            default: nil
            }
        }
        func mark(_ value: Any?) -> Mark? {
            if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return .flag(number.boolValue) }
            return (value as? String).map(Mark.date)
        }
        return list.compactMap { item in
            guard let cycle = text(item["cycle"]) else { return nil }
            return ReleaseCycle(cycle: cycle, latest: text(item["latest"]), lts: mark(item["lts"]), eol: mark(item["eol"]))
        }
    }
}

/// endoflife.date release cycles, cached for six hours. An update check:
/// only the product name leaves the Mac.
actor Lifecycles {
    static let shared = Lifecycles()
    private var cache: [String: (at: Date, cycles: [ReleaseCycle])] = [:]

    func cycles(_ product: String) async -> [ReleaseCycle]? {
        if let hit = cache[product], Date().timeIntervalSince(hit.at) < 6 * 3600 { return hit.cycles }
        guard let data = try? await LatestVersions.get("https://endoflife.date/api/\(product).json"),
              let cycles = ReleaseCycle.parse(data) else { return nil }
        cache[product] = (Date(), cycles)
        return cycles
    }
}
