import Darwin
import Foundation

/// Decoy keys: fake-but-plausible credential files planted where credential
/// stealers look. Nothing can tell us *who* reads a file without root, but
/// APFS updates a file's access time on the first read after it was set
/// older than its modification time. So each decoy's atime is pushed back
/// to 1970; a poll every three seconds sees it jump to "now" when anything
/// reads it, raises an alert with the processes that started around then,
/// and pushes the atime back again.
public enum Decoys {
    public static let manifestName = "canaries.json"
    /// The access time an armed decoy carries: one day after the epoch.
    static let armedAtime: UInt64 = 86_400_000
    /// Right after planting, Spotlight and friends may look once.
    static let plantGrace: UInt64 = 30_000
    /// Re-arming after a trip changes the inode; indexers may look again.
    static let rearmGrace: UInt64 = 10_000
    public static let pollInterval: Duration = .seconds(3)
    static let maxTrips = 20
    static let maxSuspects = 8

    // MARK: The decoys

    struct Kind: Sendable {
        let id: String
        /// Relative to the home folder.
        let relative: String
        let imitates: String
        let make: @Sendable () -> String
    }

    static let kinds: [Kind] = [
        Kind(id: "aws", relative: ".aws/credentials.bak", imitates: "AWS access key", make: aws),
        Kind(id: "ssh", relative: ".ssh/id_rsa.old", imitates: "SSH private key", make: ssh),
        Kind(id: "env", relative: ".env.backup", imitates: "OpenAI, Anthropic and Stripe keys", make: env),
        Kind(id: "kube", relative: ".kube/config.old", imitates: "Kubernetes cluster token", make: kube),
        Kind(id: "docker", relative: ".docker/config.json.bak", imitates: "Docker registry login", make: docker),
        Kind(id: "netrc", relative: ".netrc.old", imitates: "netrc machine password", make: netrc),
    ]

    static let upperDigits = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    static let alnum = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
    static let b64 = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
    static let urlSafe = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    /// `length` random characters from `alphabet`.
    static func random(_ alphabet: [Character], _ length: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
    }

    static func aws() -> String {
        "[default]\naws_access_key_id = AKIA\(random(upperDigits, 16))\naws_secret_access_key = \(random(b64, 40))\nregion = us-east-1\n"
    }

    static func ssh() -> String {
        let body = Array("MIIEpAIBAAKCAQEA" + random(b64, 1576))
        let lines = stride(from: 0, to: body.count, by: 64).map { String(body[$0..<min($0 + 64, body.count)]) }
        return "-----BEGIN RSA PRIVATE KEY-----\n\(lines.joined(separator: "\n"))\n-----END RSA PRIVATE KEY-----\n"
    }

    static func env() -> String {
        "# backup before rotating\nOPENAI_API_KEY=sk-proj-\(random(urlSafe, 132))\nANTHROPIC_API_KEY=sk-ant-api03-\(random(urlSafe, 93))AA\nSTRIPE_SECRET_KEY=sk_live_\(random(alnum, 99))\n"
    }

    static func kube() -> String {
        """
        apiVersion: v1
        kind: Config
        clusters:
        - cluster:
            server: https://10.0.12.4:6443
            insecure-skip-tls-verify: true
          name: prod
        contexts:
        - context:
            cluster: prod
            user: deploy
          name: prod
        current-context: prod
        users:
        - name: deploy
          user:
            token: eyJhbGciOiJSUzI1NiIsImtpZCI6I\(random(urlSafe, 180)).\(random(urlSafe, 342))

        """
    }

    static func docker() -> String {
        let auth = Data("deploy:ghp_\(random(alnum, 36))".utf8).base64EncodedString()
        return "{\n  \"auths\": {\n    \"ghcr.io\": {\n      \"auth\": \"\(auth)\"\n    }\n  }\n}\n"
    }

    static func netrc() -> String {
        "machine api.github.com\n  login deploy-bot\n  password ghp_\(random(alnum, 36))\n"
    }

    // MARK: The manifest

    public struct Suspect: Codable, Sendable, Hashable {
        public var comm: String
        public var parent: String?
        public var path: String?
        public var pid: Int32
        public var started: UInt64
        /// An Apple system binary (listed last).
        public var system: Bool
    }

    public struct Trip: Codable, Sendable, Hashable {
        public var suspects: [Suspect]
        /// When the file was read (its new access time), ms.
        public var t: UInt64
    }

    struct Planted: Codable, Sendable {
        /// Trips count from here; earlier reads are the grace period.
        var armedAt: UInt64
        /// A parent folder we created, removed again when empty.
        var createdDir: String?
        var id: String
        /// (device, inode) of the file we created: whatever else sits at the
        /// path later (a real key moved over it) is never armed or removed.
        var inode: [UInt64]?
        var path: String
        var plantedAt: UInt64
        var trips: [Trip]
    }

    struct Manifest: Codable, Sendable {
        var decoys: [Planted] = []
    }

    // MARK: Files

    struct FileFacts { let device: UInt64, inode: UInt64, atime: UInt64, regular: Bool }

    /// lstat: never follows a symlink and never moves the access time.
    static func facts(_ path: String) -> FileFacts? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let atime = UInt64(max(info.st_atimespec.tv_sec, 0)) * 1000 + UInt64(info.st_atimespec.tv_nsec / 1_000_000)
        return FileFacts(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), atime: atime,
                         regular: (info.st_mode & S_IFMT) == S_IFREG)
    }

    static func exists(_ path: String) -> Bool { facts(path) != nil }

    /// Pushes the access time back to 1970 so the next read moves it.
    @discardableResult
    static func arm(_ path: String) -> Bool {
        var times = [timespec(tv_sec: Int(armedAtime / 1000), tv_nsec: 0), timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT))]
        return utimensat(AT_FDCWD, path, &times, AT_SYMLINK_NOFOLLOW) == 0
    }

    /// Whether the file at `path` is still the one we planted.
    static func isOurs(_ decoy: Planted, _ path: String) -> Bool {
        guard let inode = decoy.inode, inode.count == 2, let facts = facts(path), facts.regular else { return false }
        return [facts.device, facts.inode] == inode
    }

    static func wanted(_ ids: [String]?, _ id: String) -> Bool { ids?.contains(id) ?? true }

    /// Creates one decoy; never touches a path that already exists.
    static func plantOne(home: String, kind: Kind, now: UInt64) throws -> Planted {
        let path = home + "/" + kind.relative
        let parent = (path as NSString).deletingLastPathComponent
        var createdDir: String?
        if !FileManager.default.fileExists(atPath: parent) {
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            createdDir = parent
        }
        // O_EXCL refuses existing files and symlinks alike.
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw LowtideError.commandFailed(String(cString: strerror(errno))) }
        let data = Array(kind.make().utf8)
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
        guard written == data.count else { throw LowtideError.commandFailed("couldn't write the decoy") }
        guard let facts = facts(path), arm(path) else { throw LowtideError.commandFailed("couldn't arm the decoy") }
        return Planted(armedAt: now + plantGrace, createdDir: createdDir, id: kind.id, inode: [facts.device, facts.inode],
                       path: path, plantedAt: now, trips: [])
    }

    static func plant(_ manifest: inout Manifest, home: String, ids: [String]?, now: UInt64) -> [String] {
        var errors: [String] = []
        for kind in kinds where wanted(ids, kind.id) {
            // Ours and still there, or someone else's file: leave it be.
            if exists(home + "/" + kind.relative) { continue }
            do {
                var planted = try plantOne(home: home, kind: kind, now: now)
                if let index = manifest.decoys.firstIndex(where: { $0.id == kind.id }) {
                    planted.trips = manifest.decoys[index].trips
                    planted.createdDir = planted.createdDir ?? manifest.decoys[index].createdDir
                    manifest.decoys[index] = planted
                } else {
                    manifest.decoys.append(planted)
                }
            } catch {
                errors.append("~/\(kind.relative): \(error.localizedDescription)")
            }
        }
        return errors
    }

    /// Removes only decoys in the manifest, at the path the catalog gives (a
    /// tampered manifest can't point us at anything else), and only the file
    /// we created. They go to the Trash like every removal.
    static func remove(_ manifest: inout Manifest, home: String, ids: [String]?,
                       discard: ([String]) async -> Void = { await Trash.move($0) }) async {
        var kept: [Planted] = []
        var trash: [String] = []
        var folders: [String] = []
        for decoy in manifest.decoys {
            guard wanted(ids, decoy.id) else {
                kept.append(decoy)
                continue
            }
            guard let kind = kinds.first(where: { $0.id == decoy.id }) else { continue }
            let path = home + "/" + kind.relative
            if isOurs(decoy, path) { trash.append(path) }
            if let dir = decoy.createdDir, (path as NSString).deletingLastPathComponent == dir { folders.append(dir) }
        }
        manifest.decoys = kept
        await discard(trash)
        // Only a folder we created, and only while empty.
        for dir in folders where (try? FileManager.default.contentsOfDirectory(atPath: dir))?.isEmpty == true {
            rmdir(dir)
        }
    }

    // MARK: Watching

    enum Check: Equatable { case quiet, rearm, trip }

    /// Given an armed decoy's access time: untouched, read during the grace
    /// period, or read for real.
    static func check(now: UInt64, armedAt: UInt64, atime: UInt64) -> Check {
        if atime <= armedAtime + 1000 { return .quiet }
        return now < armedAt ? .rearm : .trip
    }

    static let systemDirs = ["/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/", "/sbin/", "/bin/"]

    static func isSystem(_ path: String?) -> Bool {
        guard let path else { return false }
        return systemDirs.contains { path.hasPrefix($0) }
    }

    /// Processes that started around a read: not ours, non-system first,
    /// then nearest to the read.
    static func suspects(_ starts: [ProcessStart], own: Int32, t: UInt64) -> [Suspect] {
        let list = starts.filter { $0.pid != own }.map {
            Suspect(comm: $0.comm, parent: $0.parent, path: $0.path, pid: $0.pid, started: $0.started, system: isSystem($0.path))
        }
        let distance = { (s: Suspect) in s.started > t ? s.started - t : t - s.started }
        return Array(list.sorted { ($0.system ? 1 : 0, distance($0)) < ($1.system ? 1 : 0, distance($1)) }.prefix(maxSuspects))
    }

    /// A decoy read for real: what to tell the person.
    public struct Read: Sendable {
        public var path: String
        public var imitates: String
        public var lead: String?
    }

    /// One pass over the decoys; returns the reads and whether the manifest
    /// changed.
    static func poll(_ manifest: inout Manifest, home: String, now: UInt64,
                     find: (UInt64) -> [Suspect]) -> (changed: Bool, reads: [Read]) {
        var changed = false
        var reads: [Read] = []
        var kept: [Planted] = []
        for var decoy in manifest.decoys {
            guard let kind = kinds.first(where: { $0.id == decoy.id }) else {
                kept.append(decoy)
                continue
            }
            let path = home + "/" + kind.relative
            // Planted, then deleted: shown as missing.
            guard exists(path) else {
                kept.append(decoy)
                continue
            }
            // Someone else's file now: forget the decoy, leave the file be.
            guard isOurs(decoy, path) else {
                changed = true
                continue
            }
            guard let atime = facts(path)?.atime else {
                kept.append(decoy)
                continue
            }
            switch check(now: now, armedAt: decoy.armedAt, atime: atime) {
            case .quiet:
                kept.append(decoy)
                continue
            case .rearm:
                break
            case .trip:
                let suspects = find(atime)
                reads.append(Read(path: "~/" + kind.relative, imitates: kind.imitates, lead: suspects.first?.comm))
                decoy.trips.append(Trip(suspects: suspects, t: atime))
                if decoy.trips.count > maxTrips { decoy.trips.removeFirst(decoy.trips.count - maxTrips) }
                decoy.armedAt = now + rearmGrace
                changed = true
            }
            arm(path)
            kept.append(decoy)
        }
        manifest.decoys = kept
        return (changed, reads)
    }

    // MARK: What the page sees

    public enum State: String, Sendable {
        /// Not planted.
        case absent
        /// Planted, in its grace period.
        case arming
        case armed
        /// Planted, then deleted.
        case missing
        /// A file that isn't ours is there.
        case taken

        public var planted: Bool { self == .armed || self == .arming || self == .missing }
    }

    public struct View: Sendable, Identifiable, Hashable {
        public var id: String
        public var imitates: String
        /// `~/.aws/credentials.bak`
        public var path: String
        public var state: State
        public var armedAt: UInt64?
        public var plantedAt: UInt64?
        /// Newest first.
        public var trips: [Trip]
    }

    public struct Status: Sendable, Hashable {
        public var decoys: [View]
        /// Problems from the last plant, if any.
        public var errors: [String]

        public var planted: Int { decoys.filter(\.state.planted).count }
        public var reads: [UInt64] { decoys.flatMap { $0.trips.map(\.t) } }
        public func reads(since: UInt64) -> Int { reads.filter { $0 >= since }.count }
    }

    static func status(_ manifest: Manifest, home: String, now: UInt64, errors: [String]) -> Status {
        let views = kinds.map { kind -> View in
            let ours = manifest.decoys.first { $0.id == kind.id }
            let path = home + "/" + kind.relative
            let state: State
            switch (ours, exists(path)) {
            case (nil, false): state = .absent
            case (nil, true): state = .taken
            case (.some, false): state = .missing
            case (.some(let d), true) where !isOurs(d, path): state = .taken
            case (.some(let d), true) where now < d.armedAt: state = .arming
            case (.some, true): state = .armed
            }
            return View(id: kind.id, imitates: kind.imitates, path: "~/" + kind.relative, state: state,
                        armedAt: ours?.armedAt, plantedAt: ours?.plantedAt, trips: ours?.trips.reversed() ?? [])
        }
        return Status(decoys: views, errors: errors)
    }
}

/// The planted decoys and their watcher: one poll every three seconds,
/// and only while something is planted.
public actor DecoyWatch {
    public static let shared = DecoyWatch()

    private var manifest: Decoys.Manifest
    private let home: String
    private let file: URL
    private var loop: Task<Void, Never>?
    private var onRead: (@Sendable (Decoys.Read) -> Void)?
    private var onChange: (@Sendable (Decoys.Status) -> Void)?

    public init(home: String = Paths.home.path, file: URL = JSONStore.url(Decoys.manifestName)) {
        self.home = home
        self.file = file
        manifest = (try? Data(contentsOf: file)).flatMap { try? JSONStore.decoder.decode(Decoys.Manifest.self, from: $0) }
            ?? Decoys.Manifest()
    }

    /// Starts polling; `read` hears every real read, `change` every new status.
    public func start(read: @escaping @Sendable (Decoys.Read) -> Void, change: @escaping @Sendable (Decoys.Status) -> Void) {
        onRead = read
        onChange = change
        resume()
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    private func resume() {
        guard loop == nil, onRead != nil, !manifest.decoys.isEmpty else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Decoys.pollInterval)
                guard let self, await self.tick() else { return }
            }
        }
    }

    /// One pass; false once nothing is planted (the loop ends).
    private func tick() -> Bool {
        guard !manifest.decoys.isEmpty else {
            loop = nil
            return false
        }
        let own = getpid()
        let result = Decoys.poll(&manifest, home: home, now: Clock.now) { t in
            Decoys.suspects(RunProcessTable.starts(from: t > 60_000 ? t - 60_000 : 0, to: t + 5000), own: own, t: t)
        }
        if result.changed {
            save()
            onChange?(status())
        }
        for read in result.reads { onRead?(read) }
        return true
    }

    private func save() { JSONStore.write(manifest, to: file) }

    public func status(errors: [String] = []) -> Decoys.Status {
        Decoys.status(manifest, home: home, now: Clock.now, errors: errors)
    }

    public func plant(ids: [String]? = nil) -> Decoys.Status {
        let errors = Decoys.plant(&manifest, home: home, ids: ids, now: Clock.now)
        save()
        resume()
        return status(errors: errors)
    }

    public func remove(ids: [String]? = nil) async -> Decoys.Status {
        var copy = manifest
        await Decoys.remove(&copy, home: home, ids: ids)
        manifest = copy
        save()
        return status()
    }

    public func clearHistory() -> Decoys.Status {
        for index in manifest.decoys.indices { manifest.decoys[index].trips.removeAll() }
        save()
        return status()
    }
}
