import CryptoKit
import Darwin
import Foundation
import Synchronization

/// One credential found on disk. Never the value: `preview` is the first
/// few characters, then dots.
public struct ExposureFinding: Codable, Sendable, Hashable, Identifiable {
    public enum Level: String, Codable, Sendable, CaseIterable, Comparable {
        case critical, high, medium, low
        var rank: Int { Self.allCases.firstIndex(of: self)! }
        public static func < (a: Level, b: Level) -> Bool { a.rank < b.rank }
    }

    /// Stable across scans: a hash of path, kind and line.
    public var id: String
    public var kind: String
    public var label: String
    public var path: String
    public var line: Int?
    public var preview: String
    public var severity: Level
    /// A known token shape, key or tool login (not a generic assignment).
    public var strong: Bool
    /// Private keys only: whether a passphrase protects it.
    public var encrypted: Bool?
    /// Looks like a test or example value.
    public var test: Bool
    public var synced: Bool
    public var inGit: Bool
    public var tracked: Bool
    public var worldReadable: Bool
    public var history: Bool
    public var ignored: Bool

    enum CodingKeys: String, CodingKey {
        case id, kind, label, path, line, preview, severity, strong, encrypted, test, synced, inGit, tracked, worldReadable,
             history, ignored
    }

    public init(id: String, kind: String, label: String, path: String, line: Int?, preview: String,
                severity: Level = .medium, strong: Bool, encrypted: Bool? = nil, test: Bool = false, synced: Bool = false,
                inGit: Bool = false, tracked: Bool = false, worldReadable: Bool = false, history: Bool = false,
                ignored: Bool = false) {
        self.id = id
        self.kind = kind
        self.label = label
        self.path = path
        self.line = line
        self.preview = preview
        self.severity = severity
        self.strong = strong
        self.encrypted = encrypted
        self.test = test
        self.synced = synced
        self.inGit = inGit
        self.tracked = tracked
        self.worldReadable = worldReadable
        self.history = history
        self.ignored = ignored
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(String.self, forKey: .kind)
        label = try c.decode(String.self, forKey: .label)
        path = try c.decode(String.self, forKey: .path)
        line = try c.decodeIfPresent(Int.self, forKey: .line)
        preview = try c.decode(String.self, forKey: .preview)
        severity = (try? c.decode(Level.self, forKey: .severity)) ?? .medium
        strong = try c.decodeIfPresent(Bool.self, forKey: .strong) ?? false
        encrypted = try c.decodeIfPresent(Bool.self, forKey: .encrypted)
        test = try c.decodeIfPresent(Bool.self, forKey: .test) ?? false
        synced = try c.decodeIfPresent(Bool.self, forKey: .synced) ?? false
        inGit = try c.decodeIfPresent(Bool.self, forKey: .inGit) ?? false
        tracked = try c.decodeIfPresent(Bool.self, forKey: .tracked) ?? false
        worldReadable = try c.decodeIfPresent(Bool.self, forKey: .worldReadable) ?? false
        history = try c.decodeIfPresent(Bool.self, forKey: .history) ?? false
        ignored = try c.decodeIfPresent(Bool.self, forKey: .ignored) ?? false
    }

    /// How serious it is, from what is true of it.
    public static func level(of f: ExposureFinding) -> Level {
        let key = f.encrypted == false
        if f.test || f.encrypted == true { return .low }
        if (f.strong && (f.synced || f.tracked)) || (key && f.worldReadable) { return .critical }
        if f.synced || f.tracked || f.history || key { return .high }
        return .medium
    }

    /// `~/code/app/.env:3`.
    public var location: String { line.map { "\(Paths.tilde(path)):\($0)" } ?? Paths.tilde(path) }
}

public struct ExposureReport: Codable, Sendable, Hashable {
    /// When it finished, ms.
    public var at: UInt64
    public var scanned: Int
    public var ms: UInt64
    public var findings: [ExposureFinding]
}

/// What a running scan reports.
public enum ExposureEvent: Sendable {
    case progress(scanned: Int, current: String)
    case finding(ExposureFinding)
}

/// Exposed secrets: credentials left in files on this Mac (`.env` files,
/// private keys, tool configs, shell histories). Everything stays local:
/// raw values never leave `SecretDetector`, only a masked preview is
/// stored or shown.
public actor Exposure {
    public static let shared = Exposure()

    static let maxBytes = 2 * 1024 * 1024
    static let maxDepth = 6
    /// A history with the same token pasted a hundred times is one problem.
    static let perFile = 50
    public static let storeName = "exposure.json"

    struct Store: Codable {
        var last: ExposureReport?
        var ignored: Set<String> = []
    }

    private var store: Store
    private let home: String
    /// `home` with symlinks resolved: FSEvents reports real paths
    /// (`/private/tmp/…` for `/tmp/…`), the report keeps `home`'s spelling.
    private let realHome: String
    private let file: URL
    /// Bumped to stop a running scan (a new scan bumps it too).
    private let generation = Generation()

    /// A counter that can be shared with the detached sweep.
    final class Generation: Sendable {
        let value = Atomic<UInt64>(0)
        func bump() -> UInt64 { value.add(1, ordering: .relaxed).newValue }
        var current: UInt64 { value.load(ordering: .relaxed) }
    }

    public init(home: String = Paths.home.path, file: URL = JSONStore.url(Exposure.storeName)) {
        self.home = home
        realHome = realpath(home, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? home
        self.file = file
        store = (try? Data(contentsOf: file)).flatMap { try? JSONStore.decoder.decode(Store.self, from: $0) } ?? Store()
    }

    private func save() { JSONStore.write(store, to: file) }

    // MARK: Walking

    struct FileHits: Sendable {
        let path: String
        let history: Bool
        let worldReadable: Bool
        let hits: [SecretHit]
    }

    /// Reads one candidate file (none over 2 MB, none that is only an
    /// iCloud placeholder).
    static func examine(_ path: String, source: SecretSource) -> FileHits? {
        var info = stat()
        guard stat(path, &info) == 0, info.st_size <= maxBytes else { return nil }
        // SF_DATALESS: reading a File Provider placeholder would download it.
        if info.st_flags & 0x4000_0000 != 0 { return nil }
        let worldReadable = info.st_mode & 0o044 != 0
        let hits: [SecretHit]
        if source == .bundle {
            hits = [SecretHit(kind: "certificate-bundle", label: "Certificate bundle", line: nil, preview: "PKCS#12",
                              strong: true, encrypted: true, test: false)]
        } else {
            guard let data = FileManager.default.contents(atPath: path) else { return nil }
            hits = Array(SecretDetector.detect(String(decoding: data, as: UTF8.self), source: source).prefix(perFile))
        }
        return FileHits(path: path, history: source == .history, worldReadable: worldReadable, hits: hits)
    }

    /// Walks HOME (plus iCloud Drive and cloud storage under Library) and
    /// reads every candidate. nil when cancelled.
    static func sweep(home: String, cancelled: () -> Bool,
                      progress: (Int, String) -> Void) -> (scanned: Int, files: [FileHits])? {
        let library = home + "/Library"
        var stack: [(String, Int)] = [(library + "/CloudStorage", 0), (library + "/Mobile Documents", 0), (home, 0)]
        var scanned = 0
        var files: [FileHits] = []
        var last = ContinuousClock.now
        while let (dir, depth) = stack.popLast() {
            if cancelled() { return nil }
            if ContinuousClock.now - last >= .milliseconds(120) {
                progress(scanned, dir)
                last = .now
            }
            guard let handle = opendir(dir) else { continue }
            defer { closedir(handle) }
            let parent = (dir as NSString).lastPathComponent
            while let entry = readdir(handle) {
                let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                    String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
                }
                if name == "." || name == ".." { continue }
                let path = dir + "/" + name
                switch Int32(entry.pointee.d_type) {
                case DT_DIR:
                    if depth < maxDepth, path != library, !SecretDetector.skipped(name, parent: parent) {
                        stack.append((path, depth + 1))
                    }
                case DT_REG:
                    guard let source = SecretDetector.classify(path, home: home), let file = examine(path, source: source)
                    else { continue }
                    scanned += 1
                    if !file.hits.isEmpty { files.append(file) }
                default:
                    continue
                }
            }
        }
        progress(scanned, home)
        return (scanned, files)
    }

    // MARK: Findings

    /// (inside a git work tree, tracked by it). Git runs only when a `.git`
    /// sits above the file, so the developer tools prompt never appears for
    /// nothing.
    static func gitStatus(_ path: String) async -> (inGit: Bool, tracked: Bool) {
        var dir = (path as NSString).deletingLastPathComponent
        var inGit = false
        while dir.count > 1 {
            if FileManager.default.fileExists(atPath: dir + "/.git") {
                inGit = true
                break
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        guard inGit, Shell.isAvailable("git") else { return (inGit, false) }
        let folder = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let out = try? await Shell.run("git", ["-C", folder, "ls-files", "--error-unmatch", "--", name], timeout: .seconds(5))
        return (true, out?.ok ?? false)
    }

    static func findingID(path: String, kind: String, line: Int?) -> String {
        let digest = SHA256.hash(data: Data("\(path)\0\(kind)\0\(line ?? 0)".utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func sort(_ findings: inout [ExposureFinding]) {
        findings.sort { ($0.severity.rank, $0.path, $0.line ?? -1) < ($1.severity.rank, $1.path, $1.line ?? -1) }
    }

    static func findings(for file: FileHits, home: String) async -> [ExposureFinding] {
        guard !file.hits.isEmpty else { return [] }
        let git = await gitStatus(file.path)
        let synced = SecretDetector.synced.contains { file.path.hasPrefix(home + "/" + $0 + "/") }
        let testPath = file.path.split(separator: "/").contains { SecretDetector.testDirs.contains(String($0)) }
        return file.hits.map { hit in
            var finding = ExposureFinding(
                id: findingID(path: file.path, kind: hit.kind, line: hit.line), kind: hit.kind, label: hit.label,
                path: file.path, line: hit.line, preview: hit.preview, strong: hit.strong, encrypted: hit.encrypted,
                test: hit.test || testPath, synced: synced, inGit: git.inGit, tracked: git.tracked,
                worldReadable: file.worldReadable, history: file.history)
            finding.severity = ExposureFinding.level(of: finding)
            return finding
        }
    }

    private func marked(_ finding: ExposureFinding) -> ExposureFinding {
        var copy = finding
        copy.ignored = store.ignored.contains(finding.id)
        return copy
    }

    // MARK: Commands

    /// The last completed scan (masked previews only).
    public func last() -> ExposureReport? {
        guard var report = store.last else { return nil }
        report.findings = report.findings.map(marked)
        return report
    }

    /// Scans for exposed secrets, streaming findings. Returns the report,
    /// or nil when stopped. Critical findings new since the last scan are
    /// counted in `freshCritical`.
    public func scan(onEvent: @escaping @Sendable (ExposureEvent) -> Void) async -> (report: ExposureReport, freshCritical: Int)? {
        let mine = generation.bump()
        let started = ContinuousClock.now
        let home = self.home
        let generation = self.generation
        let swept = await Task.detached(priority: .utility) {
            Self.sweep(home: home, cancelled: { generation.current != mine }) { scanned, dir in
                onEvent(.progress(scanned: scanned, current: dir))
            }
        }.value
        guard let swept else { return nil }
        var findings: [ExposureFinding] = []
        for file in swept.files {
            if generation.current != mine { return nil }
            for finding in await Self.findings(for: file, home: home) {
                onEvent(.finding(marked(finding)))
                findings.append(finding)
            }
        }
        Self.sort(&findings)
        let before = Set((store.last?.findings ?? []).filter { $0.severity == .critical }.map(\.id))
        let fresh = findings.filter { $0.severity == .critical && !before.contains($0.id) && !store.ignored.contains($0.id) }.count
        let elapsed = ContinuousClock.now - started
        let ms = UInt64(elapsed.components.seconds) * 1000 + UInt64(elapsed.components.attoseconds / 1_000_000_000_000_000)
        store.last = ExposureReport(at: Clock.now, scanned: swept.scanned, ms: ms, findings: findings)
        save()
        return (last()!, fresh)
    }

    public nonisolated func cancel() { _ = generation.bump() }

    private func reported(_ path: String) -> Bool { store.last?.findings.contains { $0.path == path } ?? false }

    static func notReported() -> LowtideError { .invalid("Not a finding from the last scan. Scan again.") }

    /// A watcher's path in the report's spelling of the home folder.
    func reported(spelling path: String) -> String {
        guard realHome != home, let rest = RunRules.under(path, realHome) else { return path }
        return home + "/" + rest
    }

    /// Re-reads one file and replaces its findings in the last report.
    public func refresh(_ changed: String) async {
        let path = reported(spelling: changed)
        guard store.last != nil else { return }
        var fresh: [ExposureFinding] = []
        if let source = SecretDetector.classify(path, home: home), let file = Self.examine(path, source: source) {
            fresh = await Self.findings(for: file, home: home)
        }
        guard var report = store.last else { return }
        let old = report.findings.filter { $0.path == path }
        guard old != fresh else { return }
        report.findings.removeAll { $0.path == path }
        report.findings.append(contentsOf: fresh)
        Self.sort(&report.findings)
        store.last = report
        save()
    }

    /// Folders that hold a reported file: watching them keeps the report
    /// true as files are edited, fixed or deleted.
    public func watchedFolders() -> [String] {
        Array(Set((store.last?.findings ?? []).map { ($0.path as NSString).deletingLastPathComponent })).sorted()
    }

    /// Whether a changed path belongs in the report (reported, or a new
    /// candidate in a watched folder).
    public func matters(_ changed: String) -> Bool {
        let path = reported(spelling: changed)
        return reported(path) || SecretDetector.classify(path, home: home) != nil
    }

    /// `chmod 600` on a file from the last report.
    public func fixPermissions(_ path: String) throws {
        guard var report = store.last, reported(path) else { throw Self.notReported() }
        guard chmod(path, 0o600) == 0 else { throw LowtideError.commandFailed(String(cString: strerror(errno))) }
        for index in report.findings.indices where report.findings[index].path == path {
            report.findings[index].worldReadable = false
            report.findings[index].severity = ExposureFinding.level(of: report.findings[index])
        }
        Self.sort(&report.findings)
        store.last = report
        save()
    }

    public func ignore(_ id: String, _ ignored: Bool) {
        if ignored { store.ignored.insert(id) } else { store.ignored.remove(id) }
        save()
    }

    /// Opens a reported file in the default text editor (`open -t`), so a
    /// key or certificate is never imported by a double-click handler.
    public func open(_ path: String) async throws {
        guard reported(path) else { throw Self.notReported() }
        try await Shell.check("/usr/bin/open", ["-t", path])
    }

    /// Removes reported lines from a shell history. No copy is kept: a
    /// backup would be the very secret the person asked to remove. The
    /// rewrite goes through a temp file and a rename, so the history is
    /// never half-written. Returns how many lines went.
    public func forgetHistory(_ path: String, lines: [Int]) async throws -> Int {
        let wanted = (store.last?.findings ?? []).filter { $0.path == path && $0.history }.compactMap { f -> (Int, String, String)? in
            guard let line = f.line, lines.contains(line) else { return nil }
            return (line, f.kind, f.preview)
        }
        guard !wanted.isEmpty else { throw Self.notReported() }
        // A symlinked history (a dotfiles repo) is rewritten where it lives.
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var info = stat()
        guard stat(target, &info) == 0 else { throw LowtideError.notFound(Paths.tilde(path)) }
        let mode = info.st_mode & 0o777
        // The shell keeps appending: read as late as possible, and give up
        // if the file grew before the rename.
        guard let data = FileManager.default.contents(atPath: target) else { throw LowtideError.notFound(Paths.tilde(path)) }
        let bytes = Array(data)
        let current = Self.stillThere(bytes, wanted)
        guard !current.isEmpty else {
            throw LowtideError.invalid("The history changed since the last scan. Scan again first.")
        }
        let (kept, removed) = Self.forgetLines(bytes, current)
        let temp = target + ".lowtide-tmp"
        guard FileManager.default.createFile(atPath: temp, contents: Data(kept), attributes: [.posixPermissions: Int(mode)])
        else { throw LowtideError.commandFailed("Couldn't write next to \(Paths.tilde(path))") }
        var now = stat()
        guard stat(target, &now) == 0, now.st_size == off_t(bytes.count) else {
            unlink(temp)
            throw LowtideError.invalid("The history changed while it was being edited. Try again.")
        }
        guard rename(temp, target) == 0 else {
            unlink(temp)
            throw LowtideError.commandFailed(String(cString: strerror(errno)))
        }
        await refresh(path)
        return removed
    }

    /// The reported lines that, re-read now, still hold a secret of the same
    /// kind and masked preview (line numbers from an old scan go stale when
    /// the shell trims its history).
    static func stillThere(_ bytes: [UInt8], _ wanted: [(Int, String, String)]) -> Set<Int> {
        let hits = SecretDetector.detect(String(decoding: bytes, as: UTF8.self), source: .history)
        return Set(wanted.filter { line, kind, preview in
            hits.contains { $0.line == line && $0.kind == kind && $0.preview == preview }
        }.map(\.0))
    }

    /// Removes whole history entries containing `lines` (1-based). A zsh
    /// entry spanning several lines (each but the last ending in `\`) goes
    /// as a whole.
    static func forgetLines(_ bytes: [UInt8], _ lines: Set<Int>) -> ([UInt8], Int) {
        let rows = bytes.split(separator: 10, omittingEmptySubsequences: false)
        func continues(_ row: ArraySlice<UInt8>) -> Bool {
            let trimmed = row.last == 13 ? row.dropLast() : row
            return trimmed.last == 92
        }
        var drop = [Bool](repeating: false, count: rows.count)
        for line in lines {
            let index = line - 1
            guard index >= 0, index < rows.count else { continue }
            var start = index
            while start > 0, continues(rows[start - 1]) { start -= 1 }
            var end = index
            while end + 1 < rows.count, continues(rows[end]) { end += 1 }
            for i in start...end { drop[i] = true }
        }
        let kept = zip(rows, drop).filter { !$0.1 }.map(\.0)
        return (Array(kept.joined(separator: [10])), drop.filter { $0 }.count)
    }
}
