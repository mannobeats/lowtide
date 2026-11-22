import LowtideKit
import SwiftUI

/// What deleted apps left: their files, and the grants and start-up items
/// macOS still keeps for them. Scanned once at launch (the sidebar's
/// count) and again when the page asks.
@Observable
final class LeftoversStore {
    static let shared = LeftoversStore()

    private(set) var leftovers: [Leftover] = []
    private(set) var context = LeftoverScanner.Context()
    private(set) var scanning = false
    private(set) var scanned: Date?
    private(set) var gone: GonePermissions?
    private(set) var goneScanning = false
    var checks = Checks<String>()
    var selectedID: String?
    private var maps: [String: FootprintModel] = [:]

    static let prompt = "Lowtide needs your password to move files a deleted app installed to the Trash."

    /// Both scans, quietly: the launch run and the page's first visit.
    func refresh(quiet: Bool = true, loginItems: Bool = false) {
        scan(quiet: quiet)
        scanPermissions(loginItems: loginItems || gone?.loginItemsRead != nil)
    }

    func startIfStale() {
        if scanned.map({ Date().timeIntervalSince($0) > 300 }) ?? true { refresh() }
    }

    func scan(quiet: Bool) {
        guard !scanning else { return }
        scanning = true
        let work: @MainActor (Jobs.Job?) async -> Void = { [self] job in
            defer { scanning = false }
            let found = await LeftoverScanner.scan()
            context = found
            leftovers = found.leftovers
            maps = [:]
            checks.ids.formIntersection(Set(found.leftovers.map(\.id)))
            if let id = selectedID, !found.leftovers.contains(where: { $0.id == id }) { selectedID = nil }
            scanned = Date()
            updateBadge()
            // Containers are measured only when opened: reading inside one
            // makes macOS ask for access to other apps' data at every launch.
            let paths = found.leftovers.flatMap { leftover in LeftoverScanner.measurable(leftover).map { (leftover.id, $0) } }
            var sums: [String: Int64] = [:]
            var done = 0
            for await (index, bytes) in SizeStream.measure(paths.map(\.1), width: 8) {
                let id = paths[index].0
                sums[id, default: 0] += bytes ?? 0
                done += 1
                job?.progress = Double(done) / Double(max(paths.count, 1))
                if let at = leftovers.firstIndex(where: { $0.id == id }) { leftovers[at].bytes = sums[id] }
            }
        }
        if quiet {
            Task { await work(nil) }
        } else {
            Jobs.shared.start("Looking for leftovers", page: .leftovers) { job in await work(job) }
        }
    }

    func scanPermissions(loginItems: Bool) {
        guard !goneScanning else { return }
        goneScanning = true
        Task {
            gone = await LeftoverPermissions.scan(includeLoginItems: loginItems)
            goneScanning = false
            updateBadge()
        }
    }

    /// The sidebar counts what Leftovers would show: apps' files and gone
    /// apps' grants and start-up items; amber when one fails at login.
    func updateBadge() {
        let count = leftovers.count + (gone?.apps.count ?? 0)
        SidebarBadges.shared.counts[.leftovers] = count > 0 ? count : nil
        if gone?.apps.contains(where: { !$0.startup.isEmpty }) == true {
            SidebarBadges.shared.warning.insert(.leftovers)
        } else {
            SidebarBadges.shared.warning.remove(.leftovers)
        }
    }

    func map(for leftover: Leftover) -> FootprintModel {
        if let known = maps[leftover.id] { return known }
        let context = self.context
        let model = FootprintModel(locate: { await Footprint.locate(LeftoverScanner.subject(for: leftover, in: context)) },
                                   remove: { paths, _ in await Footprint.remove(paths, prompt: Self.prompt) })
        maps[leftover.id] = model
        return model
    }

    func forget(_ ids: [String]) {
        let gone = Set(ids)
        leftovers.removeAll { gone.contains($0.id) }
        checks.ids.subtract(gone)
        for id in ids { maps[id] = nil }
        if let id = selectedID, gone.contains(id) { selectedID = nil }
        updateBadge()
    }

    /// Several leftovers in one removal, so root-owned files ask for the
    /// password once. Each is gone when its own files are.
    func remove(_ list: [Leftover]) {
        Jobs.shared.start("Removing \(LowtideFormat.count(list.count, "leftover"))", page: .leftovers) { [self] job in
            var plans: [(Leftover, [Footprint.Item])] = []
            for (index, leftover) in list.enumerated() {
                try Task.checkCancellation()
                job.detail = "Mapping \(leftover.name)"
                job.progress = Double(index) / Double(list.count) * 0.8
                plans.append((leftover, await Footprint.locate(LeftoverScanner.subject(for: leftover, in: context))))
            }
            var paths: [String] = []
            for (leftover, items) in plans {
                for path in leftover.paths + items.filter(\.preselected).map(\.path) where !paths.contains(path) { paths.append(path) }
            }
            job.detail = "Moving to the Trash"
            job.progress = 0.85
            let result = await Footprint.remove(paths, prompt: Self.prompt)
            let removed = Set(result.removed)
            let done = plans.filter { leftover, _ in leftover.paths.allSatisfy { removed.contains($0) || !CleanupFS.exists($0) } }.map(\.0)
            let bytes = plans.filter { done.map(\.id).contains($0.0.id) }.reduce(Int64(0)) { $0 + ($1.0.bytes ?? 0) }
            forget(done.map(\.id))
            let stayed = list.filter { leftover in !done.contains { $0.id == leftover.id } }
            Clean.Removal.report(moved: result.removed.count, bytes: bytes,
                                 refused: stayed.map { ($0.name, "some files stayed, open it to see which") },
                                 undo: result.undo, restored: { [self] in scan(quiet: true) })
        }
    }

    // MARK: Permissions

    func revoke(_ app: GoneApp) {
        guard let id = app.bundleID else { return }
        Jobs.shared.start("Removing \(app.name)'s grants", page: .leftovers, success: "Removed \(app.name)'s grants") { [self] _ in
            try await LeftoverPermissions.revoke(service: "All", bundleID: id)
            scanPermissions(loginItems: gone?.loginItemsRead != nil)
        }
    }

    func removeStartup(_ items: [GoneApp.Startup]) {
        Jobs.shared.start("Removing \(LowtideFormat.count(items.count, "start-up item"))", page: .leftovers) { [self] _ in
            let result = await LeftoverPermissions.remove(items)
            Clean.Removal.report(moved: result.removed.count, bytes: 0, refused: result.failed.map { (Clean.tilde($0.path), $0.reason) },
                                 undo: result.undo, restored: { [self] in scanPermissions(loginItems: false) })
            scanPermissions(loginItems: gone?.loginItemsRead != nil)
        }
    }

    /// Every grant that can be reset and every broken start-up item, with
    /// one password prompt for those in /Library.
    func cleanAll() {
        let apps = gone?.apps ?? []
        Jobs.shared.start("Cleaning up after deleted apps", page: .leftovers) { [self] job in
            var failures = 0
            for (index, app) in apps.enumerated() where app.grants.contains(where: \.revocable) {
                job.detail = app.name
                job.progress = Double(index) / Double(max(apps.count, 1))
                if let id = app.bundleID {
                    do { try await LeftoverPermissions.revoke(service: "All", bundleID: id) } catch { failures += 1 }
                }
            }
            let startup = apps.flatMap(\.startup)
            var result = Footprint.RemoveResult()
            if !startup.isEmpty { result = await LeftoverPermissions.remove(startup) }
            failures += result.failed.count
            Toasts.shared.show(failures == 0 ? "Cleaned up after \(LowtideFormat.count(apps.count, "deleted app"))"
                               : "\(failures) couldn't be removed here", detail: failures > 0 ? "Open Privacy & Security for those." : nil,
                               tone: failures > 0 ? .warn : .ok)
            scanPermissions(loginItems: gone?.loginItemsRead != nil)
        }
    }
}

/// Leftovers: what deleted apps left, as files (with the footprint map of
/// each) and as permissions and start-up items.
struct LeftoversPage: View {
    enum Tab: String { case files, permissions }

    @Environment(\.palette) private var palette
    var store = LeftoversStore.shared
    @AppStorage("leftovers.tab") private var asked: Tab?
    @State private var chose = false

    var body: some View {
        // Opened from the sidebar: land where there's something to clean.
        let tab = asked ?? (store.leftovers.isEmpty && !(store.gone?.apps.isEmpty ?? true) ? .permissions : .files)
        let tabs = Segmented(Binding(get: { tab }, set: { asked = $0 }),
                             [(.files, "Files"), (.permissions, "Permissions & start-up items")],
                             counts: [.files: store.leftovers.count, .permissions: store.gone?.apps.count ?? 0])
        Group {
            switch tab {
            case .files: LeftoverFiles(store: store, tabs: tabs)
            case .permissions: LeftoverPermissionsView(store: store, tabs: tabs)
            }
        }
        .task { store.startIfStale() }
    }
}

private struct LeftoverFiles<Tabs: View>: View {
    enum Sort: Hashable { case size, recent, name }

    @Environment(\.palette) private var palette
    @Bindable var store: LeftoversStore
    let tabs: Tabs
    @State private var query = ""
    @State private var sort: Sort = .size
    @State private var confirm: ConfirmRequest?

    private var visible: [Leftover] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return store.leftovers
            .filter { needle.isEmpty || "\($0.name) \($0.id)".lowercased().contains(needle) }
            .sorted { a, b in
                switch sort {
                case .name: a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                case .recent: (a.modified ?? .distantPast) > (b.modified ?? .distantPast)
                case .size: (a.bytes ?? 0) > (b.bytes ?? 0)
                }
            }
    }

    var body: some View {
        let visible = self.visible
        let order = visible.map(\.id)
        let total = store.leftovers.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
        let description = store.scanned == nil ? "Looking for files of apps that are gone"
            : store.leftovers.isEmpty ? "No files left by deleted apps"
            : "\(LowtideFormat.count(store.leftovers.count, "deleted app")) left \(LowtideFormat.bytes(total)) behind"
        VStack(spacing: 0) {
            PageHeader("Leftovers", description: description) { tabs } action: {
                IconButton("arrow.clockwise", help: "Scan again") { store.refresh(quiet: false) }.disabled(store.scanning)
            }
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    VStack(spacing: Space.sm) {
                        HStack {
                            FilterField(text: $query, prompt: "Search leftovers or bundle ids")
                            Spacer(minLength: 0)
                        }
                        HStack {
                            Segmented($sort, [(.size, "Largest"), (.recent, "Recent"), (.name, "Name")])
                            Spacer()
                        }
                    }
                    .padding(.horizontal, Space.md).padding(.top, Space.md).padding(.bottom, Space.sm)
                    if !visible.isEmpty {
                        Clean.SelectAll(state: store.checks.state(of: order),
                                        text: "\(visible.count) shown · \(LowtideFormat.bytes(visible.map(\.bytes).reduce(Int64(0)) { $0 + ($1 ?? 0) }))",
                                        onChange: { store.checks.set(order, on: $0) })
                            .hairline(.top)
                    }
                    list(visible, order: order)
                    let chosen = visible.filter { store.checks.has($0.id) }
                    if !chosen.isEmpty {
                        HStack(spacing: Space.sm) {
                            Text("\(LowtideFormat.count(chosen.count, "leftover")) selected").font(.ui(.xs, .medium)).foregroundStyle(palette.ink.color)
                            Spacer()
                            Button("Clear") { store.checks.clear() }.buttonStyle(.lowtide(.quiet, size: .small))
                            Button("Remove") { confirm = request(chosen) }.buttonStyle(.lowtide(.destructive, size: .small))
                        }
                        .padding(.horizontal, Space.md).frame(height: 42)
                        .hairline(.top)
                    }
                }
                .frame(width: 340)
                .hairline(.trailing)
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .hairline(.top)
        }
        .confirmation($confirm)
        .modifier(Clean.Keys(space: nil, delete: {
            let chosen = visible.filter { store.checks.has($0.id) }
            if !chosen.isEmpty { confirm = request(chosen) }
        }))
    }

    @ViewBuilder
    private func list(_ visible: [Leftover], order: [String]) -> some View {
        if store.scanned == nil {
            ScanningState(title: "Comparing your Library with the apps you have")
        } else if visible.isEmpty {
            EmptyState("Nothing left behind", symbol: "checkmark.circle",
                       message: query.isEmpty ? "Every settings file and cache belongs to an app that's still here." : "Nothing matches.")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visible) { leftover in
                        Clean.CheckRow(checked: store.checks.has(leftover.id), selected: store.selectedID == leftover.id,
                                       label: "Select \(leftover.name)",
                                       onCheck: { store.checks.toggle(leftover.id, in: order) },
                                       onSelect: { store.selectedID = leftover.id }) {
                            Clean.Tile(glyph: "leftovers", size: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(leftover.name).font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color).lineLimit(1)
                                Text("\(Text(leftover.id).font(.mono(.xxs)))\(leftover.modified.map { " · " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "")")
                                    .font(.ui(.xxs)).foregroundStyle(palette.ink3.color).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: Space.xs)
                            // Unmeasured: only a sandbox container, sized once opened.
                            Clean.SizeLabel(bytes: leftover.bytes).frame(width: 64, alignment: .trailing)
                        } menu: {
                            Button(leftover.byName ? "Copy Path" : "Copy Bundle ID") { Files.copy(leftover.byName ? leftover.paths[0] : leftover.id) }
                            Button("Show in Finder") { Files.reveal(leftover.paths) }
                            Divider()
                            let targets = store.checks.targets(leftover.id, in: order)
                            Button(targets.count > 1 ? "Remove \(targets.count) Leftovers…" : "Remove…", role: .destructive) {
                                confirm = request(store.leftovers.filter { targets.contains($0.id) })
                            }
                        }
                        Hairline(inset: 42)
                    }
                }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let leftover = store.leftovers.first(where: { $0.id == store.selectedID }) {
            let map = store.map(for: leftover)
            FootprintMap(model: map, subject: "what \(leftover.name) left", onRemoved: { result, bytes in
                Clean.Removal.report(moved: result.removed.count, bytes: bytes, refused: result.failed.map { (Clean.tilde($0.path), $0.reason) },
                                     undo: result.undo, restored: { map.reload() })
                if leftover.paths.allSatisfy({ result.removed.contains($0) || !CleanupFS.exists($0) }) { store.forget([leftover.id]) }
            }) {
                HStack(alignment: .top, spacing: Space.lg) {
                    Clean.Tile(glyph: "leftovers", size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(leftover.name).font(.title(.lg)).foregroundStyle(palette.ink.color).lineLimit(1)
                        Text(leftover.id).font(.mono(.xxs)).foregroundStyle(palette.ink3.color).textSelection(.enabled)
                        Text(leftover.byName
                             ? "No app, plug-in or tool on this Mac goes by this name, and nothing has changed in it for a week."
                             : "The app is gone; these files were named after it.")
                            .font(.ui(.xs)).foregroundStyle(palette.ink3.color).padding(.top, 4)
                    }
                }
            }
            .id(leftover.id)
        } else {
            EmptyState("Select a leftover", symbol: "sidebar.left",
                       message: "Pick one to see everything the deleted app left: settings, caches, containers, logs and web data, found by its bundle id and name.")
        }
    }

    private func request(_ list: [Leftover]) -> ConfirmRequest {
        let names = list.prefix(3).map(\.name).formatted(.list(type: .and)) + (list.count > 3 ? " and \(list.count - 3) more" : "")
        return ConfirmRequest(
            title: list.count == 1 ? "Remove what \(list[0].name) left?" : "Remove \(list.count) leftovers?",
            message: "\(names), with \(list.count == 1 ? "its" : "their") settings, caches and support files (\(LowtideFormat.bytes(list.map(\.bytes).reduce(Int64(0)) { $0 + ($1 ?? 0) })) and more found by name). Everything goes to the Trash, so you can restore it until you empty it; files shared with other products are kept.",
            confirm: "Move to Trash") { store.remove(list) }
    }
}

private struct LeftoverPermissionsView<Tabs: View>: View {
    @Environment(\.palette) private var palette
    let store: LeftoversStore
    let tabs: Tabs
    @State private var confirm: ConfirmRequest?

    var body: some View {
        let apps = store.gone?.apps ?? []
        let broken = apps.flatMap(\.startup).count
        let description = store.gone == nil ? "Reading Privacy & Security and start-up items"
            : apps.isEmpty ? (store.gone?.grantsReadable == false ? "No start-up items left by deleted apps" : "No permissions or start-up items left by deleted apps")
            : "\(LowtideFormat.count(apps.count, "deleted app")) still \(apps.count == 1 ? "has" : "have") permissions or start-up items" + (broken > 0 ? ", \(broken) failing at login" : "")
        VStack(spacing: 0) {
            PageHeader("Leftovers", description: description) { tabs } action: {
                if !apps.isEmpty {
                    Button("Clean up all") {
                        confirm = ConfirmRequest(
                            title: "Clean up after \(LowtideFormat.count(apps.count, "deleted app"))?",
                            message: "Their Privacy grants are reset and their broken start-up items move to the Trash. Items in /Library ask for your password once. Grants held by a path stay: only System Settings removes those.",
                            confirm: "Clean Up") { store.cleanAll() }
                    }
                    .buttonStyle(.primary)
                }
                IconButton("arrow.clockwise", help: "Scan again") { store.scanPermissions(loginItems: store.gone?.loginItemsRead != nil) }
                    .disabled(store.goneScanning)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    notes
                    if store.gone == nil {
                        ScanningState(title: "Reading Privacy & Security and start-up items").frame(minHeight: 260)
                    } else if apps.isEmpty {
                        EmptyState("Nothing left behind", symbol: "checkmark.circle",
                                   message: store.gone?.grantsReadable == false
                                       ? "No deleted app starts with your Mac. Their Privacy grants show here once Full Disk Access is allowed."
                                       : "No deleted app still has a permission or starts with your Mac.").frame(minHeight: 260)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(apps) { app in
                                row(app)
                                if app.id != apps.last?.id { Hairline(inset: 56) }
                            }
                        }
                        .card()
                    }
                }
                .padding(.horizontal, Space.page + 4).padding(.top, Space.xs).padding(.bottom, Space.page * 2)
                .frame(maxWidth: 1180, alignment: .leading).frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
        }
        .confirmation($confirm)
    }

    @ViewBuilder private var notes: some View {
        if let gone = store.gone {
            if !gone.grantsReadable {
                HStack(spacing: Space.md) {
                    Image(systemName: "lock.shield").foregroundStyle(palette.warn.color)
                    Text("Allow Full Disk Access to see the Privacy grants deleted apps left behind.")
                        .font(.ui(.sm)).foregroundStyle(palette.ink2.color)
                    Spacer()
                    Button("Open Settings") { NSWorkspace.shared.open(Permission.fullDiskAccess.settingsURL) }
                        .buttonStyle(.lowtide(.secondary, size: .small))
                }
                .card(padding: Space.md)
            }
            if gone.loginItemsRead == nil {
                HStack(spacing: Space.md) {
                    Text("Open at Login items aren't checked yet: macOS asks before Lowtide can read them.")
                        .font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                    Button("Check Them") { store.scanPermissions(loginItems: true) }.buttonStyle(.lowtide(.quiet, size: .small))
                }
            } else if gone.loginItemsRead == false {
                Text("Open at Login items couldn't be read. Allow Lowtide to control System Events in Privacy & Security → Automation.")
                    .font(.ui(.xs)).foregroundStyle(palette.ink3.color)
            }
        }
    }

    private func row(_ app: GoneApp) -> some View {
        let revocable = app.grants.contains(where: \.revocable)
        return HStack(alignment: .top, spacing: Space.md) {
            Clean.Tile(glyph: "leftovers", size: 30)
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name).font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color).lineLimit(1)
                    if let id = app.bundleID, id != app.name {
                        Text(id).font(.mono(.xxs)).foregroundStyle(palette.ink3.color).textSelection(.enabled)
                    }
                }
                if !app.grants.isEmpty {
                    FlowLayout(spacing: 4) {
                        ForEach(app.grants) { grant in
                            Badge(grant.target.map { "\(grant.label): \($0)" } ?? grant.label + (grant.limited ? " (limited)" : ""))
                                .help(grant.revocable ? "Granted \(grant.modified.map { Clean.relative($0) } ?? "")" : "Held by a path: only System Settings removes it")
                        }
                    }
                }
                ForEach(app.startup) { item in
                    HStack(spacing: 6) {
                        Badge(item.kind == .openAtLogin ? "Opens at login" : item.kind == .daemon ? "Launch daemon" : "Launch agent", tone: .warn)
                        Text("runs \(Clean.tilde(item.executable ?? item.name)), which is gone")
                            .font(.ui(.xs)).foregroundStyle(palette.ink3.color).lineLimit(1).truncationMode(.middle)
                        if item.needsAdmin { Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(palette.ink4.color).help("Needs your password") }
                    }
                    .contextMenu {
                        if let plist = item.plist { PathMenu(plist) }
                    }
                }
            }
            Spacer(minLength: Space.md)
            HStack(spacing: 6) {
                if !app.startup.isEmpty {
                    Button("Remove start-up items") {
                        confirm = ConfirmRequest(
                            title: "Remove \(app.name)'s start-up items?",
                            message: "They stop and their files move to the Trash, so you can put them back."
                                + (app.startup.contains(where: \.needsAdmin) ? " macOS asks for your password for the ones in /Library." : ""),
                            confirm: "Move to Trash") { store.removeStartup(app.startup) }
                    }
                    .buttonStyle(.lowtide(.secondary, size: .small))
                }
                if revocable {
                    Button("Reset grants") {
                        confirm = ConfirmRequest(
                            title: "Reset \(app.name)'s permissions?",
                            message: "Its \(LowtideFormat.count(app.grants.filter(\.revocable).count, "grant")) leave Privacy & Security, as if you'd clicked − in System Settings.",
                            confirm: "Reset") { store.revoke(app) }
                    }
                    .buttonStyle(.lowtide(.secondary, size: .small))
                } else if !app.grants.isEmpty {
                    Button("Open Privacy & Security") {
                        NSWorkspace.shared.open(LeftoverPermissions.settingsURL(service: app.grants.first?.service))
                    }
                    .buttonStyle(.lowtide(.quiet, size: .small))
                }
            }
        }
        .padding(.horizontal, Space.lg).padding(.vertical, Space.md)
        .contextMenu {
            if let id = app.bundleID { Button("Copy Bundle ID") { Files.copy(id) } }
            Button("Open Privacy & Security") { NSWorkspace.shared.open(LeftoverPermissions.settingsURL(service: app.grants.first?.service)) }
            if !app.startup.isEmpty { Button("Open Login Items Settings") { NSWorkspace.shared.open(LeftoverPermissions.loginItemsURL) } }
        }
    }
}
