import Foundation

/// A process that talks to a local service over loopback.
public struct LocalClient: Sendable, Hashable, Identifiable {
    public var pid: Int32
    public var name: String
    /// Open connections right now.
    public var conns: Int
    /// Bytes moved over those connections (open and recently closed).
    public var bytes: Int64
    public var id: Int32 { pid }
}

/// One listening TCP service (v4 and v6 merged) and the process behind it.
public struct LocalService: Sendable, Hashable, Identifiable {
    /// `pid:port`.
    public var id: String
    public var port: UInt16
    /// Every address it listens on (`127.0.0.1`, `::1`, `0.0.0.0`, `::`…).
    public var binds: [String]
    /// Reachable from other machines (bound beyond loopback).
    public var exposed: Bool
    public var pid: Int32
    public var name: String
    public var path: String?
    public var command: String?
    public var started: Millis?
    public var cwd: String?
    public var projectRoot: String?
    public var project: String?
    public var branch: String?
    /// The framework or server it looks like (Vite, Postgres…).
    public var kind: String?
    /// Another user's process or part of macOS.
    public var system: Bool
    /// Lowtide itself.
    public var own: Bool
    public var clients: [LocalClient]
    public var conns: Int
    public var bytesIn: Int64
    public var bytesOut: Int64
    public var rateIn: Int64
    public var rateOut: Int64

    /// The project, else the process name: how services group.
    public var group: String { project ?? name }

    /// Addresses beyond loopback it accepts connections on.
    public var exposedBinds: [String] { binds.filter { !Localhost.isLoopback($0) } }

    /// Whether the port probably speaks HTTP (worth opening in a browser).
    public var httpish: Bool {
        !(system || [22, 25, 53, 3306, 5432, 5433, 6379, 11_211, 27_017, 9092, 2181].contains(port)
            || ["Postgres", "MySQL", "MariaDB", "Redis", "MongoDB"].contains(kind ?? ""))
    }
}

/// The localhost map: every TCP service listening on this Mac, the project
/// and branch it runs from, which local processes talk to it, and whether
/// it is reachable from the network.
public enum Localhost {
    static let projectMarkers = [".git", "package.json", "Cargo.toml", "pyproject.toml", "go.mod", "Gemfile", "composer.json"]

    /// Needles (lowercase) in the command line or process name, most specific first.
    static let kinds: [(String, String)] = [
        ("com.docker", "Docker"), ("vpnkit", "Docker"), ("docker", "Docker"), ("orbstack", "OrbStack"), ("vite", "Vite"),
        ("next-server", "Next.js"), ("next dev", "Next.js"), ("next start", "Next.js"), ("/next/dist", "Next.js"),
        ("nuxt", "Nuxt"), ("astro", "Astro"), ("remix", "Remix"), ("storybook", "Storybook"), ("webpack", "webpack"),
        ("wrangler", "Wrangler"), ("expo start", "Expo"), ("rails", "Rails"), ("puma", "Rails"), ("manage.py", "Django"),
        ("django", "Django"), ("uvicorn", "Uvicorn"), ("gunicorn", "Gunicorn"), ("flask", "Flask"), ("jupyter", "Jupyter"),
        ("artisan", "Laravel"), ("hugo", "Hugo"), ("postgres", "Postgres"), ("mysqld", "MySQL"), ("mariadb", "MariaDB"),
        ("redis", "Redis"), ("mongod", "MongoDB"), ("ollama", "Ollama"), ("nginx", "nginx"), ("caddy", "Caddy"),
        ("deno", "Deno"), ("bun", "Bun"), ("node", "Node"), ("python", "Python"), ("ruby", "Ruby"),
    ]

    public static func guessKind(command: String, name: String) -> String? {
        let hay = "\(name) \(command)".lowercased()
        return kinds.first { hay.contains($0.0) }?.1
    }

    public static func isLoopback(_ ip: String) -> Bool {
        ip.hasPrefix("127.") || ip == "::1" || ip == "localhost" || ip.hasPrefix("fe80::1%lo0")
    }

    /// The nearest folder at or above `start` that looks like a project;
    /// never HOME itself or `/`.
    public static func projectRoot(_ start: String, home: String) -> String? {
        var dir = URL(fileURLWithPath: start).standardizedFileURL.path
        while dir != home, dir != "/", !dir.isEmpty {
            if projectMarkers.contains(where: { FileManager.default.fileExists(atPath: dir + "/" + $0) }) { return dir }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// `name` from package.json, else the folder's name.
    public static func projectName(_ root: String) -> String? {
        if let data = FileManager.default.contents(atPath: root + "/package.json"),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = json["name"] as? String, !name.isEmpty {
            return name
        }
        let folder = (root as NSString).lastPathComponent
        return folder.isEmpty ? nil : folder
    }

    /// The branch in a `.git/HEAD`, or a short hash when detached.
    public static func parseHead(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("ref:") {
            let ref = text.dropFirst(4).trimmingCharacters(in: .whitespaces)
            return ref.hasPrefix("refs/heads/") ? String(ref.dropFirst(11)) : ref
        }
        return text.count >= 7 && text.allSatisfy(\.isHexDigit) ? String(text.prefix(7)) : nil
    }

    /// The git branch for a folder: looks for `.git` upwards (a monorepo
    /// package sits below its repository), following worktree `gitdir:` files.
    public static func gitBranch(_ root: String, home: String) -> String? {
        var dir = root
        while dir != home, dir != "/", !dir.isEmpty {
            let dotGit = dir + "/.git"
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDir) {
                var gitDir = dotGit
                if !isDir.boolValue {
                    guard let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
                          let line = text.split(separator: "\n").first, line.hasPrefix("gitdir:") else { return nil }
                    let target = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
                    gitDir = target.hasPrefix("/") ? target : URL(fileURLWithPath: dir).appending(path: target).standardizedFileURL.path
                }
                return (try? String(contentsOfFile: gitDir + "/HEAD", encoding: .utf8)).flatMap(parseHead)
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// Part of macOS rather than something the person started.
    public static func systemPath(_ path: String) -> Bool {
        path.hasPrefix("/System/") || path.hasPrefix("/Library/Apple/") || (path.hasPrefix("/usr/") && !path.hasPrefix("/usr/local/"))
    }

    static func wildcard(_ ip: String, v6: Bool) -> String { ip == "*" ? (v6 ? "::" : "0.0.0.0") : ip }

    /// Every TCP service listening on this Mac, by port.
    public static func services(engine: NetworkEngine = .shared) -> [LocalService] {
        let raws = engine.localhostRaw()
        let me = getuid()
        let own = getpid()
        let home = Paths.home.path
        return raws.map { raw in
            let info = NetProcess.info(raw.pid)
            let path = raw.path ?? ProcTable.path(raw.pid)
            let name = (raw.name?.isEmpty == false ? raw.name : nil) ?? info?.name ?? "pid \(raw.pid)"
            let system = info.map { $0.uid != me } ?? true || path.map(systemPath) == true
            // cwd and arguments are only readable for our own processes anyway.
            let cwd = system ? nil : ProcTable.cwd(raw.pid)
            let command = system ? nil : NetProcess.commandLine(raw.pid)
            let root = cwd.flatMap { projectRoot($0, home: home) }
            let clients = raw.clients.values.map { client -> LocalClient in
                var client = client
                if client.name.isEmpty { client.name = NetProcess.info(client.pid)?.name ?? "pid \(client.pid)" }
                return client
            }.sorted { ($0.bytes, $1.pid) > ($1.bytes, $0.pid) }
            return LocalService(
                id: "\(raw.pid):\(raw.port)", port: raw.port, binds: raw.binds, exposed: raw.binds.contains { !isLoopback($0) },
                pid: raw.pid, name: name, path: path, command: command, started: info?.started, cwd: cwd, projectRoot: root,
                project: root.flatMap(projectName), branch: root.flatMap { gitBranch($0, home: home) },
                kind: guessKind(command: command ?? "", name: name), system: system, own: raw.pid == own, clients: clients,
                conns: raw.conns, bytesIn: raw.bytesIn, bytesOut: raw.bytesOut, rateIn: raw.rateIn, rateOut: raw.rateOut)
        }.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    public enum StopRefusal: Error, Equatable, LocalizedError {
        case notStoppable, isSelf, gone, notYours, refused
        public var errorDescription: String? {
            switch self {
            case .notStoppable: "That isn't a process that can be stopped."
            case .isSelf: "Lowtide won't stop itself."
            case .gone: "That process is gone."
            case .notYours: "That process belongs to the system or another user."
            case .refused: "The signal was refused."
            }
        }
    }

    /// Stops one of the person's own services (SIGTERM, or SIGKILL when forced).
    public static func stop(pid: Int32, force: Bool) throws(StopRefusal) {
        guard pid > 1 else { throw .notStoppable }
        guard pid != getpid() else { throw .isSelf }
        guard let info = NetProcess.info(pid) else { throw .gone }
        guard info.uid == getuid(), !(ProcTable.path(pid).map(systemPath) ?? false) else { throw .notYours }
        guard NetProcess.signal(pid, force: force) else { throw .refused }
    }

    /// "3h 12m", "4m", "12s" since a start time.
    public static func uptime(_ started: Millis?, now: Millis) -> String {
        guard let started else { return "" }
        let seconds = max(0, (now - started) / 1000)
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        return hours < 48 ? "\(hours)h \(minutes % 60)m" : "\(hours / 24)d"
    }
}

/// What the socket table says about listeners, copied out under the lock.
struct LocalRaw {
    var port: UInt16
    var pid: Int32
    var binds: [String] = []
    var name: String?
    var path: String?
    var conns = 0
    var bytesIn: Int64 = 0
    var bytesOut: Int64 = 0
    var rateIn: Int64 = 0
    var rateOut: Int64 = 0
    var clients: [Int32: LocalClient] = [:]
}

extension NetworkEngine {
    func localhostRaw() -> [LocalRaw] {
        state.withLock { state in
            var raws: [OpenKey: LocalRaw] = [:]
            func key(_ pid: Int32, _ port: UInt16) -> OpenKey { OpenKey(pid: pid, remote: String(port)) }
            for conn in state.conns.values where conn.open && conn.socket.proto == "tcp" && conn.socket.listening {
                let k = key(conn.pid, conn.socket.localPort)
                var raw = raws[k] ?? LocalRaw(port: conn.socket.localPort, pid: conn.pid)
                let bind = Localhost.wildcard(conn.socket.localIP, v6: conn.socket.v6)
                if !raw.binds.contains(bind) { raw.binds.append(bind) }
                raws[k] = raw
            }
            // A port's owner, to attribute loopback clients.
            var byPort: [UInt16: OpenKey] = [:]
            for (k, raw) in raws { byPort[raw.port] = k }
            for conn in state.conns.values
            where conn.socket.proto == "tcp" && !conn.socket.listening && Localhost.isLoopback(conn.socket.remoteIP) {
                let open = conn.open ? 1 : 0
                if var raw = raws[key(conn.pid, conn.socket.localPort)] {
                    // The service's side of an accepted connection.
                    raw.conns += open
                    raw.bytesIn += conn.bytesIn
                    raw.bytesOut += conn.bytesOut
                    raw.rateIn += conn.rateIn
                    raw.rateOut += conn.rateOut
                    raws[key(conn.pid, conn.socket.localPort)] = raw
                } else if let k = byPort[conn.socket.remotePort], k.pid != conn.pid, var raw = raws[k] {
                    var client = raw.clients[conn.pid] ?? LocalClient(pid: conn.pid, name: state.procs[conn.pid]?.name ?? "", conns: 0, bytes: 0)
                    client.conns += open
                    client.bytes += conn.bytesIn + conn.bytesOut
                    raw.clients[conn.pid] = client
                    raws[k] = raw
                }
            }
            return raws.values.map { raw in
                var raw = raw
                raw.name = state.procs[raw.pid]?.name
                raw.path = state.procs[raw.pid]?.path
                return raw
            }
        }
    }
}
