import LowtideKit
import SwiftUI

/// What the Cleanup space remembers between launches: the folders searched
/// for build output, and the folders Space lens and Duplicates track.
@Observable
final class CleanupSettings {
    static let shared = CleanupSettings()
    private nonisolated struct Stored: Codable, Sendable {
        var roots: [String]?
        var folders: [String]?
    }

    /// `nil` until the first visit suggests some.
    var roots: [String]? { didSet { save() } }
    /// `nil` until seeded with Downloads, Desktop, Documents…
    var folders: [String]? { didSet { save() } }

    private init() {
        let stored = JSONStore.load("cleanup.json", default: Stored())
        roots = stored.roots
        // First use: seed with Downloads, Desktop, Documents… (here, not in a
        // view's body, which mustn't change state).
        folders = stored.folders ?? Self.standardFolders
    }

    private func save() { JSONStore.save(Stored(roots: roots, folders: folders), to: "cleanup.json") }

    /// The usual folders in HOME people keep their own files in.
    static var standardFolders: [String] {
        ["Downloads", "Desktop", "Documents", "Movies", "Music", "Pictures"]
            .map { Paths.home.appending(path: $0).path }
            .filter(CleanupFS.isFolder)
    }

    var tracked: [String] { folders ?? [] }

    func track(_ path: String) {
        if !tracked.contains(path) { folders = tracked + [path] }
    }

    func untrack(_ path: String) { folders = tracked.filter { $0 != path } }

    /// The native folder picker.
    static func chooseFolder(prompt: String = "Choose") -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.directoryURL = Paths.home
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

/// One line in the activity log (Vault), for History.
enum CleanupActivity {
    static func write(_ item: String, ok: Bool, detail: String, started: Date) {
        let duration = Int(Date().timeIntervalSince(started) * 1000)
        Task.detached(priority: .background) {
            _ = try? await Vault.shared?.execute(
                "INSERT INTO activity_log (id, action, item_name, source_name, status, detail, created_at, duration_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                [UUID().uuidString, "cleanup", item, "Cleanup", ok ? "success" : "failure", detail, Vault.now(), duration])
        }
    }
}

// MARK: Caches and build files

@Observable
final class CleanupStore {
    static let shared = CleanupStore()

    enum ItemState: Equatable {
        case idle, cleaning
        case cleaned(Int64)
        case failed(String)
    }

    private(set) var items: [String: Reclaimable] = [:]
    var checks = Checks<String>()
    private(set) var states: [String: ItemState] = [:]
    private(set) var scanningCaches = false
    private(set) var scanningProjects = false
    private(set) var scannedCaches = false
    private(set) var scannedProjects = false
    private(set) var disk: (available: Int64, total: Int64)?
    private var scanJob: Jobs.Job?
    private var projectJob: Jobs.Job?

    var scanning: Bool { scanningCaches || scanningProjects }
    var cleaning: Bool { states.values.contains(.cleaning) }

    var freed: Int64 {
        states.values.reduce(0) { sum, state in if case .cleaned(let bytes) = state { sum + bytes } else { sum } }
    }

    /// Biggest first; unmeasured last.
    var all: [Reclaimable] {
        items.values.sorted { ($0.bytes ?? -1, $1.name) > ($1.bytes ?? -1, $0.name) }
    }

    /// Places not cleaned yet.
    var waiting: [Reclaimable] {
        all.filter { if case .cleaned = states[$0.id] { false } else { true } }
    }

    /// The hero's number: what can safely go.
    var safeBytes: Int64 { waiting.filter { $0.safety == .safe }.reduce(0) { $0 + ($1.bytes ?? 0) } }

    func state(_ id: String) -> ItemState { states[id] ?? .idle }

    /// The first visit, and what "Scan again" does.
    func start() {
        if !scannedCaches, !scanningCaches { scan() }
        if CleanupSettings.shared.roots == nil {
            Task { await suggestRoots() }
        } else if !scannedProjects, !scanningProjects {
            scanProjects()
        }
    }

    func rescan() {
        scan()
        scanProjects()
    }

    func refreshDisk() async {
        let home = Paths.home.path
        disk = await Task.detached { DiskSize.volume(at: home) }.value
    }

    /// First visit: project folders from the usual names and from where the
    /// terminal has been used.
    private func suggestRoots() async {
        let rows = (try? await Vault.shared?.query("SELECT DISTINCT cwd FROM command_history WHERE cwd != '' LIMIT 2000")) ?? []
        let dirs = rows.compactMap { $0.string("cwd") }
        let roots = await Task.detached { CleanupTargets.defaultRoots(recentDirs: dirs) }.value
        CleanupSettings.shared.roots = roots
        scanProjects()
    }

    private func found(_ item: Reclaimable) {
        items[item.id] = item
        states[item.id] = .idle
        if item.preselected() { checks.ids.insert(item.id) }
    }

    private func measured(_ id: String, _ bytes: Int64?) {
        items[id]?.bytes = bytes
        // Nothing to reclaim: drop it from the plan.
        if bytes == 0 { checks.ids.remove(id) }
    }

    private func drop(projects: Bool) {
        for (id, item) in items where (item.group == .projects) == projects {
            items[id] = nil
            states[id] = nil
            checks.ids.remove(id)
        }
    }

    /// Caches, Xcode and tool data: every place listed at once, then
    /// measured in parallel, each size shown as it lands (a 30 GB store
    /// mustn't hold back the small ones).
    func scan() {
        guard !scanningCaches else { return }
        drop(projects: false)
        scanningCaches = true
        scanJob = Jobs.shared.start("Measuring caches", page: .cleanup) { [self] job in
            defer {
                scanningCaches = false
                scannedCaches = true
            }
            let places = await CleanupTargets.cachePlaces()
            places.forEach(found)
            var done = 0
            for await (index, bytes) in SizeStream.measure(places.map(\.path)) {
                measured(places[index].id, bytes)
                done += 1
                job.progress = Double(done) / Double(max(places.count, 1))
                job.detail = "\(done) of \(places.count)"
            }
        }
    }

    /// Build folders in the project folders, each listed as it's found.
    func scanProjects() {
        guard let roots = CleanupSettings.shared.roots, !roots.isEmpty, !scanningProjects else {
            if CleanupSettings.shared.roots?.isEmpty == true { scannedProjects = true }
            return
        }
        drop(projects: true)
        scanningProjects = true
        projectJob = Jobs.shared.start("Looking for build folders", page: .cleanup) { [self] job in
            defer {
                scanningProjects = false
                scannedProjects = true
            }
            let stream = AsyncStream<Reclaimable> { continuation in
                let task = Task.detached(priority: .utility) {
                    CleanupTargets.findArtifacts(in: roots, stop: { Task.isCancelled }) { continuation.yield($0) }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
            var list: [Reclaimable] = []
            for await item in stream {
                found(item)
                list.append(item)
                job.detail = "\(list.count) found"
            }
            var done = 0
            for await (index, bytes) in SizeStream.measure(list.map(\.path)) {
                measured(list[index].id, bytes)
                done += 1
                job.progress = Double(done) / Double(max(list.count, 1))
                job.detail = "Measuring \(done) of \(list.count)"
            }
        }
    }

    /// Forgets build folders outside these project folders.
    func keep(roots: [String]) {
        for (id, item) in items where item.group == .projects && !roots.contains(where: { CleanupFS.isInside(item.path, $0) }) {
            items[id] = nil
            checks.ids.remove(id)
        }
    }

    func addRoot(_ path: String) {
        let path = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        var roots = CleanupSettings.shared.roots ?? []
        guard path.hasPrefix("/"), !roots.contains(path) else { return }
        roots.append(path)
        CleanupSettings.shared.roots = roots
        projectJob?.cancel()
        scanningProjects = false
        scanProjects()
    }

    func removeRoot(_ path: String) {
        let roots = (CleanupSettings.shared.roots ?? []).filter { $0 != path }
        CleanupSettings.shared.roots = roots
        keep(roots: roots)
    }

    /// Cleans these places one at a time: several are the same tool, and
    /// each is measured before and after.
    func clean(_ ids: [String]) {
        let targets = ids.compactMap { items[$0] }.filter { $0.bytes != 0 }
        guard !targets.isEmpty else { return }
        for item in targets { states[item.id] = .cleaning }
        Jobs.shared.start("Cleaning \(LowtideFormat.count(targets.count, "place"))", page: .cleanup) { [self] job in
            var freed: Int64 = 0
            var failures = 0
            var undo: [Trash.Moved] = []
            for (index, item) in targets.enumerated() {
                try Task.checkCancellation()
                job.detail = item.project.map { "\($0) · \(item.name)" } ?? item.name
                job.progress = Double(index) / Double(targets.count)
                let started = Date()
                do {
                    let result = try await CleanupTargets.clean(item)
                    freed += result.freed
                    undo += result.undo
                    states[item.id] = .cleaned(result.freed)
                    checks.ids.remove(item.id)
                    CleanupActivity.write(job.detail, ok: true,
                                          detail: "Freed \(LowtideFormat.bytes(result.freed))\(result.toTrash ? " · recoverable from the Trash" : "")",
                                          started: started)
                } catch {
                    failures += 1
                    states[item.id] = .failed(error.localizedDescription)
                    CleanupActivity.write(job.detail, ok: false, detail: error.localizedDescription, started: started)
                }
            }
            for item in targets where states[item.id] == .cleaning { states[item.id] = .idle }
            await refreshDisk()
            let title = failures > 0 ? "Freed \(LowtideFormat.bytes(freed)) · \(failures) failed" : "Freed \(LowtideFormat.bytes(freed))"
            if undo.isEmpty {
                Toasts.shared.show(title, tone: failures > 0 ? .warn : .ok)
            } else {
                // Only what went to the Trash comes back; tools' cleans don't.
                Toasts.shared.show(title, detail: "\(LowtideFormat.count(undo.count, "item")) went to the Trash", tone: failures > 0 ? .warn : .ok,
                                   action: "Undo") { [self] in Toasts.shared.putBack(undo) { self.rescan() } }
            }
        }
    }
}

// MARK: Downloads and installers

@Observable
final class DownloadsStore {
    static let shared = DownloadsStore()

    private(set) var items: [Download] = []
    private(set) var loading = false
    private(set) var loaded = false
    private(set) var error: String?
    private(set) var measuring = false
    var checks = Checks<String>()
    private var loadedAt: Date?

    func start() {
        if loadedAt.map({ Date().timeIntervalSince($0) > 30 }) ?? true { refresh() }
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        error = nil
        Task {
            defer { loading = false }
            do {
                let list = try await Downloads.list()
                items = list
                loaded = true
                loadedAt = Date()
                checks.ids.formIntersection(Set(list.map(\.path)))
                await measureFolders()
            } catch {
                self.error = error.localizedDescription
                loaded = true
            }
        }
    }

    private func measureFolders() async {
        let paths = Downloads.unmeasured(items)
        guard !paths.isEmpty else { return }
        measuring = true
        defer { measuring = false }
        for await (index, bytes) in SizeStream.measure(paths) {
            if let at = items.firstIndex(where: { $0.path == paths[index] }) { items[at].bytes = bytes }
        }
    }

    func forget(_ paths: [String]) {
        let gone = Set(paths)
        items.removeAll { gone.contains($0.path) }
        checks.ids.subtract(gone)
    }
}

// MARK: Docker

@Observable
final class DockerStore {
    static let shared = DockerStore()

    private(set) var inventory: DockerInventory?
    private(set) var loading = false
    private(set) var pruning: Bool?
    var checks = Checks<String>()
    private var loadedAt: Date?

    func start() {
        if loadedAt.map({ Date().timeIntervalSince($0) > 60 }) ?? true { refresh() }
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        Task {
            inventory = await Docker.inventory()
            loadedAt = Date()
            loading = false
        }
    }

    func startDocker() {
        Task {
            do {
                try await Docker.start()
                Toasts.shared.show("Starting Docker…")
                try? await Task.sleep(for: .seconds(12))
                refresh()
            } catch {
                Toasts.shared.failure("Docker didn't start", error)
            }
        }
    }

    func remove(_ kind: Docker.Kind, _ ids: [String], bytes: Int64) {
        let noun = kind.rawValue
        Jobs.shared.start("Deleting \(LowtideFormat.count(ids.count, "Docker \(noun)"))", page: .cleanup) { [self] _ in
            let result = await Docker.remove(kind, ids)
            checks.clear()
            if !result.removed.isEmpty {
                Toasts.shared.show("Deleted \(LowtideFormat.count(result.removed.count, noun))", detail: LowtideFormat.bytes(bytes))
            }
            if let first = result.failed.first {
                Toasts.shared.show("\(LowtideFormat.count(result.failed.count, noun)) stayed", detail: "\(first.0.prefix(19)): \(first.1)", tone: .bad)
            }
            loadedAt = nil
            refresh()
        }
    }

    func prune(all: Bool) {
        pruning = all
        Jobs.shared.start(all ? "Clearing the Docker build cache" : "Clearing unused Docker build cache", page: .cleanup,
                          success: all ? "Build cache cleared" : "Unused build cache cleared") { [self] _ in
            defer { pruning = nil }
            try await Docker.pruneBuildCache(all: all)
            refresh()
        }
    }
}
