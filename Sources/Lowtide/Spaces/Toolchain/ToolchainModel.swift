import LowtideKit
import SwiftUI

/// The toolchain as the app knows it: which package managers are here,
/// what each one has installed, and what's waiting. Scans run in parallel
/// and land one manager at a time; the last results are kept on disk so a
/// launch shows them at once while the next scan runs.
@Observable
final class ToolchainModel {
    static let shared = ToolchainModel()

    struct Scan {
        var packages: [ToolPackage]?
        var error: String?
        var loading = false
        var updatedAt: Date?
    }

    /// Package managers found on this Mac, in registry order.
    private(set) var sources: [PackageSourceInfo] = []
    private(set) var sourcesLoaded = false
    private(set) var scans: [String: Scan] = [:]
    private(set) var activity: [ActivityEntry] = []
    private(set) var activityLoaded = false
    /// The package manager Inventory shows; nil for everything. Remembered,
    /// like each space's last page.
    var inventoryManager: String? = UserDefaults.standard.string(forKey: "toolchain.inventoryManager").flatMap({ $0.isEmpty ? nil : $0 }) {
        didSet { UserDefaults.standard.set(inventoryManager, forKey: "toolchain.inventoryManager") }
    }

    /// The package history sheet is open (from the Overview or ⌘K).
    var historyOpen = false

    private var scanTask: Task<Void, Never>?
    private static let cacheFile = "toolchain-scans.json"
    private static let staleAfter: TimeInterval = 10 * 60

    private struct Cached: Codable {
        var packages: [ToolPackage]
        var at: Date
    }

    // MARK: Derived

    /// Command-line tool updates waiting (outdated, not pinned). App Store
    /// apps and app casks are app updates: Apps › Updates owns them.
    var toolUpdateCount: Int { toolUpdates.count }

    var toolUpdates: [InventoryItem] {
        items.filter { $0.package.needsUpdate && $0.itemType != .app }
    }

    /// Everything installed, across managers, by name.
    var items: [InventoryItem] {
        sources.flatMap { source in (scans[source.id]?.packages ?? []).map { InventoryItem(package: $0, source: source) } }
            .sorted { $0.package.name.localizedCaseInsensitiveCompare($1.package.name) == .orderedAscending }
    }

    /// Packages whose latest version couldn't be found (offline, private).
    var uncheckedCount: Int { items.filter { !$0.package.checked && $0.itemType != .app }.count }

    var isScanning: Bool { !sourcesLoaded || scans.values.contains { $0.loading } }

    /// No answer from any manager yet (first launch, no cache).
    var isLoading: Bool { !sourcesLoaded || (scans.values.contains { $0.loading } && scans.values.allSatisfy { $0.packages == nil }) }

    var lastScan: Date? { scans.values.compactMap(\.updatedAt).max() }

    func info(_ id: String) -> PackageSourceInfo? { sources.first { $0.id == id } }

    /// A manager's installed packages, without the app casks Apps owns.
    func packages(_ sourceID: String) -> [ToolPackage]? {
        scans[sourceID]?.packages.map { $0.filter { $0.kind != .app } }
    }

    // MARK: Scanning

    /// At launch: show the last results, then check again.
    func start() {
        guard scanTask == nil, !sourcesLoaded else { return }
        let cached = JSONStore.load([String: Cached].self, from: Self.cacheFile) ?? [:]
        for (id, entry) in cached { scans[id] = Scan(packages: entry.packages, updatedAt: entry.at) }
        scan(force: false)
        Task { await loadActivity() }
    }

    /// Scans again when the results are older than ten minutes.
    func refreshIfStale() {
        guard !isScanning else { return }
        if let last = lastScan, Date().timeIntervalSince(last) < Self.staleAfter, scans.values.allSatisfy({ $0.packages != nil || $0.error != nil }) { return }
        scan(force: false)
    }

    /// The person asked to check again: registries and Homebrew's taps too.
    func refresh() {
        scan(force: true)
    }

    private func scan(force: Bool) {
        scanTask?.cancel()
        scanTask = Task {
            if force { await PackageSources.forceRefresh() }
            await Shell.ready()
            let found = await Task.detached { PackageSources.all.filter { $0.isAvailable() }.map(\.info) }.value
            guard !Task.isCancelled else { return }
            sources = found
            sourcesLoaded = true
            for id in scans.keys where !found.contains(where: { $0.id == id }) { scans[id] = nil }
            for source in found { scans[source.id, default: Scan()].loading = true }
            // Each scan lands on the main actor itself rather than passing a
            // (String, Result) through the group: in optimized builds that
            // tuple arrived uninitialized (AddressSanitizer caught it).
            await withTaskGroup(of: Void.self) { group in
                for source in found {
                    let id = source.id
                    group.addTask {
                        let result: Result<[ToolPackage], Error>
                        do { result = .success(try await PackageSources.scan(id)) } catch { result = .failure(error) }
                        await MainActor.run {
                            guard !Task.isCancelled else { return }
                            self.land(id, result)
                        }
                    }
                }
            }
            saveCache()
        }
    }

    /// Scans one manager again (after an update outside the engine).
    func rescan(_ sourceID: String) {
        scans[sourceID, default: Scan()].loading = true
        Task {
            let result: Result<[ToolPackage], Error>
            do { result = .success(try await PackageSources.scan(sourceID)) } catch { result = .failure(error) }
            land(sourceID, result)
            saveCache()
        }
    }

    private func land(_ id: String, _ result: Result<[ToolPackage], Error>) {
        withAnimation(Motion.base) {
            switch result {
            case .success(let packages):
                scans[id] = Scan(packages: packages, updatedAt: .now)
            case .failure(let error):
                // Keep what was known; say why it couldn't be refreshed.
                scans[id] = Scan(packages: scans[id]?.packages, error: error.localizedDescription, updatedAt: scans[id]?.updatedAt)
            }
        }
    }

    /// The engine rescanned after a run: use its answer.
    func apply(_ packages: [ToolPackage], for sourceID: String) {
        land(sourceID, .success(packages))
        saveCache()
    }

    private func saveCache() {
        var cache: [String: Cached] = [:]
        for (id, scan) in scans {
            if let packages = scan.packages, let at = scan.updatedAt { cache[id] = Cached(packages: packages, at: at) }
        }
        JSONStore.save(cache, to: Self.cacheFile)
    }

    // MARK: Activity

    func loadActivity() async {
        let entries = (try? await PackageActivity.list()) ?? []
        withAnimation(Motion.base) {
            activity = entries
            activityLoaded = true
        }
    }

    func record(_ entry: ActivityEntry) {
        Task {
            try? await PackageActivity.record(entry)
            await loadActivity()
        }
    }

    func clearActivity() async throws {
        try await PackageActivity.clear()
        await loadActivity()
    }
}
