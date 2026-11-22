import LowtideKit
import SwiftUI

/// The apps on this Mac, kept while navigating: listed at once, then
/// measured. The last list is cached so the page and the sidebar's total
/// show something before the walk ends.
@Observable
final class InstalledAppsModel {
    static let shared = InstalledAppsModel()

    private(set) var apps: [InstalledApp] = []
    private(set) var scanning = false
    private(set) var scannedThisSession = false
    /// Apps still being measured.
    private(set) var measuring = 0
    private(set) var records = BrewRecords()
    /// Cask token → the Homebrew action running on it.
    private(set) var brewPending: [String: Brew.Action] = [:]
    /// App id → where its removal is ("Waiting", "Mapping", "Removing").
    private(set) var removing: [String: String] = [:]
    /// The bulk removal's line and how far it is, for the selection bar.
    private(set) var bulk: (text: String, fraction: Double)?

    private static let cacheName = "installed-apps.json"

    init() {
        if let cached = JSONStore.load([InstalledApp].self, from: Self.cacheName) { apps = cached }
        publishTotal()
    }

    var brewBusy: Bool { !brewPending.isEmpty }

    /// Bundle-id prefixes of every installed app: two apps from one
    /// developer make that developer's folders shared.
    var prefixes: [String] { apps.compactMap { $0.bundleID.flatMap(AppBundles.vendorPrefix) } }

    func app(_ id: String?) -> InstalledApp? { id.flatMap { id in apps.first { $0.id == id } } }

    func scanIfNeeded() {
        if !scannedThisSession { scan() }
    }

    func scan() {
        guard !scanning else { return }
        scanning = true
        scannedThisSession = true
        Task {
            let brew = await InstalledApps.brewApps()
            let listed = await Self.offMain { InstalledApps.list(brew: brew) }
            // Keep sizes already known while the new ones come in.
            let known = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            apps = listed.map { app in
                var app = app
                app.bytes = known[app.id]?.bytes
                app.lastUsed = known[app.id]?.lastUsed
                return app
            }
            publishTotal()
            Task { await loadRecords() }
            await measure(listed.map(\.path))
            scanning = false
            JSONStore.save(apps, to: Self.cacheName)
        }
    }

    /// Size and last use, eight apps at a time, applied a few times a second
    /// rather than once per app.
    private func measure(_ paths: [String]) async {
        measuring = paths.count
        var pending: [String: (Int64?, Date?)] = [:]
        var flushed = ContinuousClock.now
        await withTaskGroup(of: (String, Int64?, Date?).self) { group in
            var next = 0
            func add() {
                guard next < paths.count else { return }
                let path = paths[next]
                next += 1
                group.addTask {
                    let bytes = await DiskSize.measure(path)
                    return (path, bytes, InstalledApps.lastUsed(path))
                }
            }
            for _ in 0..<8 { add() }
            for await (path, bytes, used) in group {
                pending[path] = (bytes, used)
                add()
                if ContinuousClock.now - flushed > .milliseconds(250) {
                    apply(pending)
                    pending = [:]
                    flushed = .now
                }
            }
        }
        apply(pending)
        measuring = 0
    }

    private func apply(_ results: [String: (Int64?, Date?)]) {
        guard !results.isEmpty else { return }
        for index in apps.indices {
            if let (bytes, used) = results[apps[index].id] {
                apps[index].bytes = bytes
                apps[index].lastUsed = used
            }
        }
        measuring = max(0, measuring - results.count)
    }

    func loadRecords() async {
        records = await BrewRecords.load(apps: apps)
    }

    /// Drops removed apps without a rescan.
    func forget(_ ids: Set<String>) {
        apps.removeAll { ids.contains($0.id) }
        publishTotal()
        JSONStore.save(apps, to: Self.cacheName)
        for id in ids { AppUpdates.forget(id) }
        AppUpdatesModel.shared.forget(ids)
    }

    private func publishTotal() {
        SidebarBadges.shared.totals[.appsInstalled] = apps.isEmpty ? nil : apps.count
    }

    static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }

    // MARK: - Uninstalling

    /// Uninstalls several apps: maps each (one at a time, so the disk isn't
    /// hammered), then moves them all in one batch, so files owned by the
    /// system ask for the password once, or not at all with the helper.
    func uninstall(_ targets: [InstalledApp]) {
        let targets = targets.filter { !$0.protected && removing[$0.id] == nil }
        guard !targets.isEmpty else { return }
        for app in targets { removing[app.id] = "Waiting" }
        let title = targets.count == 1 ? "Uninstalling \(targets[0].name)" : "Uninstalling \(targets.count) apps"
        let prefixes = prefixes
        Jobs.shared.start(title, page: .appsInstalled) { job in
            defer {
                for app in targets { self.removing[app.id] = nil }
                self.bulk = nil
            }
            var requests: [AppRemover.Request] = []
            var maps: [[Footprint.Item]] = []
            for (index, app) in targets.enumerated() {
                try Task.checkCancellation()
                self.removing[app.id] = "Mapping"
                // Mapping is most of the wait; moving is the last stretch.
                self.report(job, "Mapping \(index + 1) of \(targets.count): \(app.name)", Double(index) / Double(targets.count) * 0.6)
                let items = (try? await Footprint.scan(Footprint.subject(app: app.path, prefixes: prefixes))) ?? []
                var paths = items.filter(\.preselected).map(\.path)
                if !paths.contains(app.path) { paths.insert(app.path, at: 0) }
                requests.append(AppRemover.Request(name: app.name, paths: paths, quitBundleID: app.bundleID, brewToken: app.brewToken))
                maps.append(items)
                self.removing[app.id] = "Waiting"
            }
            let report = await AppRemover.remove(requests) { step in
                Task { @MainActor in
                    if let index = step.request {
                        for (i, app) in targets.enumerated() where i <= index { self.removing[app.id] = i == index ? "Removing" : "Done" }
                    }
                    self.report(job, step.text, 0.6 + step.fraction * 0.4)
                }
            }
            var done: [InstalledApp] = []
            var failed: [(String, String)] = []
            var bytes: Int64 = 0
            for (index, outcome) in report.outcomes.enumerated() {
                let app = targets[index]
                bytes += maps[index].filter { outcome.removed.contains($0.path) }.compactMap(\.bytes).reduce(0, +)
                // Gone from disk, not "named in removed": a receipt can own the
                // vendor folder the app sits in, and that folder went instead.
                if !FileManager.default.fileExists(atPath: app.path) {
                    done.append(app)
                } else {
                    failed.append((app.name, outcome.failed.first?.reason ?? "Some files stayed; open it to see which"))
                }
            }
            self.forget(Set(done.map(\.id)))
            AppsReport.finish(done: done.count, noun: ("app", "apps"), verb: "moved to the Trash", bytes: bytes,
                              failed: failed, moved: report.moved) {
                InstalledAppsModel.shared.scan()
            }
        }
    }

    private func report(_ job: Jobs.Job, _ text: String, _ fraction: Double) {
        job.detail = text
        job.progress = fraction
        bulk = (text, fraction)
    }

    // MARK: - Homebrew

    /// Runs one Homebrew action on a cask (adopt, repair, uninstall the record).
    func brew(_ action: Brew.Action, _ cask: Cask) {
        guard brewPending[cask.token] == nil else { return }
        brewPending[cask.token] = action
        let success: String = switch action {
        case .adopt: "Homebrew adopted \(cask.name)"
        case .repair: "Reinstalled \(cask.name)"
        case .uninstall: "Homebrew removed \(cask.name)"
        case .upgrade: "Updated \(cask.name)"
        }
        Jobs.shared.start("\(action.progress.dropLast()) \(cask.name)", page: .appsInstalled, success: success) { _ in
            defer { self.brewPending[cask.token] = nil }
            try await Brew.run(action, token: cask.token)
            await self.loadRecords()
            self.scan()
        }
    }

    /// Hands apps installed by hand to Homebrew, one at a time (Homebrew has
    /// one lock); one toast for all of them.
    func adopt(_ casks: [Cask]) {
        let casks = casks.filter { brewPending[$0.token] == nil }
        guard !casks.isEmpty else { return }
        for cask in casks { brewPending[cask.token] = .adopt }
        Jobs.shared.start(casks.count == 1 ? "Adopting \(casks[0].name)" : "Adopting \(casks.count) apps", page: .appsInstalled) { job in
            var failed: [(String, String)] = []
            for (index, cask) in casks.enumerated() {
                job.detail = cask.name
                job.progress = Double(index) / Double(casks.count)
                do { try await Brew.run(.adopt, token: cask.token) } catch { failed.append((cask.name, error.localizedDescription)) }
                self.brewPending[cask.token] = nil
            }
            AppsReport.finish(done: casks.count - failed.count, noun: ("app", "apps"), verb: "adopted by Homebrew", bytes: 0, failed: failed, moved: [])
            await self.loadRecords()
            self.scan()
        }
    }
}

/// Updates for every app, kept while navigating. The check runs in the
/// background every few hours (`AppsLifecycle`); the page reads it here.
@Observable
final class AppUpdatesModel {
    static let shared = AppUpdatesModel()

    struct Progress: Equatable {
        enum Stage { case queued, downloading, verifying, installing, done, opened, failed }
        var stage: Stage
        var fraction: Double?
        var line: String?
        var error: String?

        var busy: Bool { [.queued, .downloading, .verifying, .installing].contains(stage) }

        var label: String {
            switch stage {
            case .done: "Updated"
            case .downloading: "Downloading"
            case .failed: "Failed"
            case .installing: "Installing"
            case .opened: "Finish in the App Store"
            case .queued: "Waiting"
            case .verifying: "Checking signature"
            }
        }
    }

    enum View: String { case apps, tools }

    private(set) var scan: UpdateScan? = AppUpdates.load()
    private(set) var checking = false
    private(set) var error: String?
    private(set) var skipped: [String: String] = AppUpdates.skipped()
    private(set) var progress: [String: Progress] = [:]
    var view: View = AppsLaunchView.value == "tools" ? .tools : .apps
    /// Command-line tools with updates, set by the Toolchain space: the
    /// sidebar's count and the tab's are apps plus tools.
    var toolUpdates = 0 { didSet { publish() } }

    private var tail: Task<Void, Never>?

    init() { publish() }

    var all: [AppUpdate] { scan?.updates ?? [] }
    var pending: [AppUpdate] { all.filter { skipped[$0.id] != $0.available } }
    var skippedList: [AppUpdate] { all.filter { skipped[$0.id] == $0.available } }
    var homebrew: Bool { scan?.homebrew ?? false }

    func isSkipped(_ update: AppUpdate) -> Bool { skipped[update.id] == update.available }

    func check(force: Bool) {
        guard !checking else { return }
        checking = true
        error = nil
        Task {
            let result = await AppUpdates.check(force: force)
            scan = result
            checking = false
            publish()
        }
    }

    func toggleSkip(_ update: AppUpdate) {
        if skipped[update.id] == update.available { skipped[update.id] = nil } else { skipped[update.id] = update.available }
        AppUpdates.saveSkipped(skipped)
        publish()
    }

    func forget(_ ids: Set<String>) {
        guard var current = scan else { return }
        current.updates.removeAll { ids.contains($0.id) }
        scan = current
        publish()
    }

    /// Queues updates; they install one at a time (downloads share the
    /// connection and Homebrew has one lock). A developer's page opens
    /// instead when only one is asked for.
    func install(_ updates: [AppUpdate]) {
        for update in updates {
            if !update.installsHere(homebrew: homebrew) {
                if updates.count == 1, let page = update.homepage.flatMap(URL.init(string:)) { NSWorkspace.shared.open(page) }
                continue
            }
            if progress[update.id]?.busy == true || isSkipped(update) { continue }
            progress[update.id] = Progress(stage: .queued)
            let previous = tail
            tail = Task {
                await previous?.value
                await run(update)
            }
        }
    }

    private func run(_ update: AppUpdate) async {
        let done: Bool = await withCheckedContinuation { continuation in
            Jobs.shared.start("Updating \(update.name)", page: .appsUpdates) { job in
                defer { continuation.resume(returning: true) }
                do {
                    let outcome = try await UpdateInstaller.install(update) { event in
                        Task { @MainActor in self.apply(event, to: update.id, job: job) }
                    }
                    switch outcome {
                    case .openedStore:
                        self.progress[update.id] = Progress(stage: .opened)
                    case .updated(let version):
                        self.progress[update.id] = Progress(stage: .done)
                        self.forget([update.id])
                        Toasts.shared.show("\(update.name) updated to \(version ?? update.available)")
                    }
                } catch {
                    self.progress[update.id] = Progress(stage: .failed, error: error.localizedDescription)
                    Toasts.shared.failure("\(update.name) didn’t update", error)
                }
            }
        }
        _ = done
    }

    private func apply(_ event: UpdateInstaller.Event, to id: String, job: Jobs.Job) {
        guard progress[id]?.busy == true else { return }
        switch event {
        case .downloading(let received, let total):
            let fraction = total.map { Double(received) / Double(max($0, 1)) }
            progress[id] = Progress(stage: .downloading, fraction: fraction)
            job.progress = fraction
            job.detail = total.map { "\(LowtideFormat.bytes(received)) of \(LowtideFormat.bytes($0))" } ?? LowtideFormat.bytes(received)
        case .verifying:
            progress[id] = Progress(stage: .verifying)
            job.detail = "Checking the signature"
            job.progress = nil
        case .installing:
            progress[id] = Progress(stage: .installing, line: progress[id]?.line)
            job.detail = "Installing"
        case .log(let line):
            progress[id] = Progress(stage: .installing, line: line)
            job.detail = line
        }
    }

    /// The sidebar's count (amber: it asks for action) and the menu bar line.
    private func publish() {
        let count = pending.count + toolUpdates
        SidebarBadges.shared.counts[.appsUpdates] = count > 0 ? count : nil
        if count > 0 { SidebarBadges.shared.warning.insert(.appsUpdates) } else { SidebarBadges.shared.warning.remove(.appsUpdates) }
    }
}

/// Add-ons and audio plug-ins, kept while navigating.
@Observable
final class AddonsModel {
    static let shared = AddonsModel()

    enum View: String { case addons, plugins }

    var view: View = AppsLaunchView.value == "plugins" ? .plugins : .addons
    private(set) var addons: [Addon]?
    private(set) var scanning = false
    private(set) var plugins: [PluginProduct] = []
    private(set) var pluginsScanned = false
    private(set) var pluginsScanning = false
    private(set) var removing: Set<String> = []
    private(set) var bulk: (text: String, fraction: Double)?

    func scan() {
        guard !scanning else { return }
        scanning = true
        Task {
            addons = await Addons.scan()
            scanning = false
        }
    }

    func scanPlugins() {
        guard !pluginsScanning else { return }
        pluginsScanning = true
        Task {
            let listed = await AudioPlugins.list()
            plugins = listed
            pluginsScanned = true
            // Sizes come in as they're measured.
            await withTaskGroup(of: (String, Int64?).self) { group in
                var next = 0
                func add() {
                    guard next < listed.count else { return }
                    let product = listed[next]
                    next += 1
                    group.addTask { (product.id, await AudioPlugins.measure(product)) }
                }
                for _ in 0..<8 { add() }
                var batch: [String: Int64?] = [:]
                for await (id, bytes) in group {
                    batch[id] = bytes
                    add()
                    if batch.count >= 24 { applySizes(batch); batch = [:] }
                }
                applySizes(batch)
            }
            pluginsScanning = false
        }
    }

    private func applySizes(_ sizes: [String: Int64?]) {
        for index in plugins.indices { if let bytes = sizes[plugins[index].id] { plugins[index].bytes = bytes } }
    }

    func remove(_ items: [Addon], label: String) {
        let items = items.filter { $0.removable && !removing.contains($0.id) }
        guard !items.isEmpty else { return }
        removing.formUnion(items.map(\.id))
        Jobs.shared.start("Removing \(LowtideFormat.count(items.count, "add-on"))", page: .appsAddons) { _ in
            defer { self.removing.subtract(items.map(\.id)) }
            let result = await Addons.remove(items)
            let done = items.filter { result.removed.contains($0.id) }
            let names = Dictionary(items.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            self.addons?.removeAll { result.removed.contains($0.id) }
            AppsReport.finish(done: done.count, noun: ("item", "items"), verb: "moved to the Trash",
                              bytes: done.compactMap(\.bytes).reduce(0, +),
                              failed: result.failed.map { (names[$0.path] ?? Paths.tilde($0.path), $0.reason) },
                              moved: result.moved) { AddonsModel.shared.scan() }
        }
    }

    /// Several plug-ins in one removal, so root-owned files ask for the
    /// password once.
    func removePlugins(_ products: [PluginProduct]) {
        let products = products.filter { !removing.contains($0.id) }
        guard !products.isEmpty else { return }
        removing.formUnion(products.map(\.id))
        let all = plugins
        Jobs.shared.start(products.count == 1 ? "Removing \(products[0].name)" : "Removing \(products.count) plug-ins", page: .appsAddons) { job in
            defer {
                self.removing.subtract(products.map(\.id))
                self.bulk = nil
            }
            var requests: [AppRemover.Request] = []
            var maps: [[Footprint.Item]] = []
            for (index, product) in products.enumerated() {
                try Task.checkCancellation()
                let text = "Mapping \(index + 1) of \(products.count): \(product.name)"
                job.detail = text
                job.progress = Double(index) / Double(products.count) * 0.8
                self.bulk = (text, job.progress ?? 0)
                let items = await Footprint.scan(AudioPlugins.subject(product, all: all))
                var paths = items.filter(\.preselected).map(\.path)
                for format in product.formats where !paths.contains(format.path) { paths.insert(format.path, at: 0) }
                requests.append(AppRemover.Request(name: product.name, paths: paths))
                maps.append(items)
            }
            self.bulk = ("Moving to the Trash", 0.85)
            // One request for all: one pass, one prompt.
            let report = await AppRemover.remove([AppRemover.Request(name: "plug-ins", paths: Array(Set(requests.flatMap(\.paths))))])
            let removed = Set(report.outcomes.flatMap(\.removed))
            var done: [PluginProduct] = []
            var bytes: Int64 = 0
            var failed: [(String, String)] = []
            for (index, product) in products.enumerated() {
                bytes += maps[index].filter { removed.contains($0.path) }.compactMap(\.bytes).reduce(0, +)
                if product.formats.allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }) { done.append(product) } else {
                    failed.append((product.name, report.outcomes.first?.failed.first?.reason ?? "Some files stayed; open it to see which"))
                }
            }
            self.forgetPlugins(Set(done.map(\.id)))
            AppsReport.finish(done: done.count, noun: ("plug-in", "plug-ins"), verb: "moved to the Trash", bytes: bytes,
                              failed: failed, moved: report.moved) { AddonsModel.shared.scanPlugins() }
        }
    }

    func forgetPlugins(_ ids: Set<String>) { plugins.removeAll { ids.contains($0.id) } }
}

/// The one toast that ends a removal: `3 apps moved to the Trash · 1.2 GB`
/// with Undo, or what failed and why.
enum AppsReport {
    /// The last removal, until it's put back: the toast goes after a few
    /// seconds, ⌘K's "Put Back Last Removal" stays.
    @MainActor static var last: (title: String, moved: [Trash.Moved], afterUndo: (() -> Void)?)?

    static func putBackLast() {
        guard let last else { return }
        self.last = nil
        Toasts.shared.putBack(last.moved) { last.afterUndo?() }
    }

    /// After a footprint map's removal.
    static func finish(_ result: Footprint.RemoveResult, bytes: Int64, afterUndo: (() -> Void)? = nil) {
        finish(done: result.removed.count, noun: ("item", "items"), verb: "moved to the Trash", bytes: bytes,
               failed: result.failed.map { (Paths.tilde($0.path), $0.reason) }, moved: result.undo, afterUndo: afterUndo)
    }

    static func finish(done: Int, noun: (String, String), verb: String, bytes: Int64, failed: [(String, String)],
                       moved: [Trash.Moved], afterUndo: (() -> Void)? = nil) {
        let size = bytes > 0 ? " · \(LowtideFormat.bytes(bytes))" : ""
        let undoable = moved.contains { $0.trashed != nil }
        if undoable { last = ("\(LowtideFormat.count(done, noun.0, noun.1)) \(verb)", moved, afterUndo) }
        let undo: (() -> Void)? = undoable ? { putBackLast() } : nil
        guard let first = failed.first else {
            if done > 0 {
                Toasts.shared.show("\(LowtideFormat.count(done, noun.0, noun.1)) \(verb)\(size)", action: undo == nil ? nil : "Undo", perform: undo)
            }
            return
        }
        let more = failed.count > 1 ? " and \(failed.count - 1) more" : ""
        let title = done > 0 ? "\(done) \(verb), \(failed.count) failed" : "Nothing was \(verb)"
        // macOS guards other apps' data until Lowtide has Full Disk Access.
        if failed.contains(where: { $0.1.contains("Full Disk Access") }) {
            Toasts.shared.show(title, detail: "\(first.0): \(first.1)\(more)", tone: .bad, action: "Open Settings") {
                NSWorkspace.shared.open(Permission.fullDiskAccess.settingsURL)
            }
        } else {
            Toasts.shared.show(title, detail: "\(first.0): \(first.1)\(more)", tone: .bad, action: undo == nil ? nil : "Undo", perform: undo)
        }
    }
}

/// `--apps-view tools|plugins|unused|broken` opens a page on one view
/// (snapshots and tests).
/// `--apps-select <name>` picks an app or plug-in by name.
enum AppsLaunchView {
    static let value = argument("--apps-view")
    static let select = argument("--apps-select")

    private static func argument(_ flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        return args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    }
}
