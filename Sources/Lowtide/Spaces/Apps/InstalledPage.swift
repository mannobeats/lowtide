import LowtideKit
import SwiftUI

/// Every app on this Mac: the answer first (what can be updated, how much
/// space apps take), then the list on the left and the selected app's files
/// on the right. Uninstall removes an app and everything it left, to the Trash.
struct InstalledPage: View {
    @Environment(\.palette) private var palette
    private var model = InstalledAppsModel.shared
    private var updates = AppUpdatesModel.shared
    @State private var query = ""
    @State private var filter: Filter = Filter(rawValue: AppsLaunchView.value ?? "") ?? .all
    @State private var sort: Sort = .size
    @State private var selectedID: String?
    @State private var checks = Checks<String>()
    @State private var confirm: ConfirmRequest?
    @FocusState private var listFocused: Bool

    enum Filter: String, CaseIterable {
        case all, updates, unused, large, appStore = "appstore", homebrew, direct, adoptable, broken

        var label: String {
            switch self {
            case .all: "All apps"
            case .updates: "Can be updated"
            case .unused: "Unused for 3 months"
            case .large: "Over 1 GB"
            case .appStore: "From the App Store"
            case .homebrew: "From Homebrew"
            case .direct: "Downloaded"
            case .adoptable: "Homebrew can adopt"
            case .broken: "Broken Homebrew records"
            }
        }
    }

    enum Sort: String, CaseIterable {
        case size, used, name
        var label: String {
            switch self {
            case .size: "Largest"
            case .used: "Least used"
            case .name: "Name"
            }
        }
    }

    private var updatesByPath: [String: AppUpdate] {
        Dictionary(updates.pending.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func matches(_ app: InstalledApp, _ filter: Filter, _ updates: [String: AppUpdate]) -> Bool {
        switch filter {
        case .all: true
        case .updates: updates[app.path] != nil
        case .adoptable: model.records.adoptable(app) != nil
        // Broken records have no app left to list; they come from the catalog.
        case .broken: false
        case .unused: !app.protected && app.unused()
        case .large: (app.bytes ?? 0) >= 1_000_000_000
        case .appStore: app.source == .appStore
        case .homebrew: app.source == .homebrew
        case .direct: app.source == .direct
        }
    }

    private func count(_ filter: Filter, _ updates: [String: AppUpdate]) -> Int {
        filter == .broken ? model.records.broken.count : model.apps.filter { matches($0, filter, updates) }.count
    }

    private func visible(_ updates: [String: AppUpdate]) -> [InstalledApp] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return model.apps
            .filter { matches($0, filter, updates) }
            .filter { needle.isEmpty || "\($0.name) \($0.bundleID ?? "")".lowercased().contains(needle) }
            .sorted {
                switch sort {
                case .name: $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                case .used: ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast)
                case .size: ($0.bytes ?? -1) > ($1.bytes ?? -1)
                }
            }
    }

    var body: some View {
        let updates = updatesByPath
        let visible = visible(updates)
        let removable = visible.filter { !$0.protected }.map(\.id)
        VStack(spacing: 0) {
            hero(updates)
                .padding(.horizontal, Space.page + 4)
                .padding(.top, Space.lg)
                .padding(.bottom, Space.lg)
            SplitList(
                query: $query,
                searchPrompt: "Search apps",
                selectAll: filter == .broken || removable.isEmpty ? nil : (
                    checks.state(of: removable),
                    "\(visible.count) shown · \(LowtideFormat.bytes(visible.compactMap(\.bytes).reduce(0, +)))",
                    { checks.set(removable, on: checks.state(of: removable) != .on) }
                )
            ) {
                filters(updates)
            } list: {
                list(visible, updates: updates)
            } detail: {
                detail(updates)
            }
        }
        .onAppear {
            model.scanIfNeeded()
            listFocused = false
            if let name = AppsLaunchView.select { selectedID = model.apps.first { $0.name == name }?.id }
        }
        .onChange(of: model.apps.map(\.id)) { _, ids in
            checks.keep(Set(ids))
            if selectedID == nil, let name = AppsLaunchView.select { selectedID = model.apps.first { $0.name == name }?.id }
        }
        .confirmation($confirm)
    }

    // MARK: - Hero

    private func hero(_ updates: [String: AppUpdate]) -> some View {
        let apps = model.apps
        let bytes = apps.compactMap(\.bytes).reduce(0, +)
        let unusedBytes = apps.filter { matches($0, .unused, updates) }.compactMap(\.bytes).reduce(0, +)
        let pending = self.updates.pending.count
        let title = apps.isEmpty ? "Looking through your apps"
            : pending > 0 ? "\(LowtideFormat.count(pending, "app")) can be updated"
            : apps.count == 1 ? "Your app is up to date" : "All \(apps.count) apps are up to date"
        var detail = apps.isEmpty ? "Measuring every app in Applications and where it came from." : "\(LowtideFormat.count(apps.count, "app")) use \(LowtideFormat.bytes(bytes))"
        if !apps.isEmpty, unusedBytes > 0 { detail += " · \(LowtideFormat.bytes(unusedBytes)) of it in apps you haven’t opened in 3 months" }
        return HStack(alignment: .top) {
            PageHero(title, detail: detail, art: "apps") {
                if pending > 0 {
                    Button("Review updates") { AppModel.shared.open(.appsUpdates) }.buttonStyle(.primary)
                }
                if unusedBytes > 0, filter != .unused {
                    Button("Show unused apps") { withAnimation(Motion.base) { filter = .unused } }.buttonStyle(.secondary)
                }
            }
            IconButton("arrow.clockwise", help: model.scanning ? "Scanning…" : "Scan again") { model.scan() }
                .disabled(model.scanning)
                .rotationEffect(.degrees(model.scanning ? 360 : 0))
                .animation(model.scanning ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: model.scanning)
        }
    }

    // MARK: - Filters

    private func filters(_ updates: [String: AppUpdate]) -> some View {
        // Shown while there's something in them, or while one is chosen.
        let options = Filter.allCases.filter { option in
            switch option {
            case .updates, .adoptable, .broken: count(option, updates) > 0 || filter == option
            default: true
            }
        }
        return HStack(spacing: Space.sm) {
            Picker("Show", selection: $filter) {
                ForEach(options, id: \.self) { option in
                    Text("\(option.label) (\(count(option, updates)))").tag(option)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            Picker("Sort", selection: $sort) {
                ForEach(Sort.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .frame(width: 112)
            .disabled(filter == .broken)
        }
        .controlSize(.small)
    }

    // MARK: - List

    @ViewBuilder
    private func list(_ visible: [InstalledApp], updates: [String: AppUpdate]) -> some View {
        if filter == .broken {
            BrokenRecordsList()
        } else {
            let order = visible.filter { !$0.protected }.map(\.id)
            ZStack(alignment: .bottom) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(visible) { app in
                                row(app, update: updates[app.path], order: order).id(app.id)
                            }
                        }
                        .padding(.vertical, Space.xs)
                        .padding(.bottom, checks.isEmpty ? 0 : 56)
                    }
                    .overlay {
                        if visible.isEmpty, !model.scanning {
                            EmptyState(query.isEmpty ? "No apps here" : "No matching apps", symbol: "app.dashed",
                                       message: query.isEmpty ? "Nothing on this Mac matches this filter." : "Try another name or bundle id.")
                        } else if visible.isEmpty {
                            ScanningState(title: "Looking through Applications")
                        }
                    }
                    .focusable()
                    .focused($listFocused)
                    .focusEffectDisabled()
                    .onKeyPress(.downArrow) { move(1, in: visible, proxy) }
                    .onKeyPress(.upArrow) { move(-1, in: visible, proxy) }
                    .onKeyPress(.space) {
                        guard let id = selectedID, order.contains(id) else { return .ignored }
                        checks.toggle(id, in: order, shift: false)
                        return .handled
                    }
                    .onDeleteCommand { if let id = selectedID ?? checks.ids.first { askUninstall(checks.targets(id)) } }
                }
                if !checks.isEmpty { bulkBar() }
            }
            .animation(Motion.base, value: checks.isEmpty)
        }
    }

    private func move(_ step: Int, in visible: [InstalledApp], _ proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !visible.isEmpty else { return .ignored }
        let index = visible.firstIndex { $0.id == selectedID }.map { min(max($0 + step, 0), visible.count - 1) } ?? 0
        selectedID = visible[index].id
        proxy.scrollTo(visible[index].id)
        return .handled
    }

    private func row(_ app: InstalledApp, update: AppUpdate?, order: [String]) -> some View {
        let targets = checks.targets(app.id)
        let stage = model.removing[app.id]
        return SplitRow(
            checked: app.protected ? nil : checks.has(app.id),
            checkLabel: "Select \(app.name)",
            selected: selectedID == app.id,
            dimmed: stage != nil,
            onCheck: { checks.toggle(app.id, in: order) },
            onSelect: {
                selectedID = app.id
                listFocused = true
            }
        ) {
            AppsIcon(path: app.path, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(app.name).font(.ui(.sm, .medium)).foregroundStyle((app.protected ? palette.ink3 : palette.ink).color).lineLimit(1)
                    if app.protected {
                        Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(palette.ink4.color).help("Part of macOS")
                    }
                }
                HStack(spacing: 0) {
                    if let update {
                        Text("Update to \(update.available)").foregroundStyle(palette.warn.color)
                    } else {
                        Text(appsLastOpened(app.lastUsed).capitalizedFirst)
                    }
                    Text(" · \(app.source.label)")
                }
                .font(.ui(.xxs)).foregroundStyle(palette.ink3.color).lineLimit(1)
            }
            Spacer(minLength: Space.xs)
            if let stage {
                HStack(spacing: 4) {
                    if stage != "Waiting" && stage != "Done" { ProgressView().controlSize(.mini) }
                    Text(stage == "Done" ? "Removed" : stage).font(.ui(.xxs))
                }
                .foregroundStyle(palette.ink3.color)
            } else if let bytes = app.bytes {
                Text(LowtideFormat.bytes(bytes)).font(.mono(.xs)).monospacedDigit().foregroundStyle(palette.ink2.color)
            } else {
                Text("…").font(.mono(.xs)).foregroundStyle(palette.ink4.color).help("Measuring")
            }
        }
        .contextMenu {
            if let update {
                Button("Update to \(update.available)") { AppModel.shared.open(.appsUpdates) }
                Divider()
            }
            Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: app.path)) }
            PathMenu(app.path)
            if let cask = model.records.adoptable(app) {
                Button("Let Homebrew Adopt It") { model.adopt([cask]) }.disabled(model.brewBusy)
            }
            if !app.protected {
                Divider()
                Button(targets.count > 1 ? "Uninstall \(targets.count) Apps…" : "Uninstall…", role: .destructive) { askUninstall(targets) }
            }
        }
    }

    private func bulkBar() -> some View {
        let checked = model.apps.filter { checks.has($0.id) }
        let adoptable = checked.compactMap { model.records.adoptable($0) }
        let working = model.bulk != nil
        return SelectionBar(
            count: checks.count, noun: "app",
            status: model.bulk?.text ?? LowtideFormat.bytes(checked.compactMap(\.bytes).reduce(0, +)),
            progress: model.bulk?.fraction, working: working,
            clear: { checks.clear() }
        ) {
            if !adoptable.isEmpty {
                Button {
                    model.adopt(adoptable)
                    checks.clear()
                } label: {
                    Label("Adopt \(adoptable.count)", systemImage: "shippingbox")
                }
                .buttonStyle(.lowtide(.secondary, size: .small))
                .disabled(model.brewBusy)
                .help("Let Homebrew keep them up to date. They aren’t reinstalled.")
            }
            Button("Uninstall") { askUninstall(Array(checks.ids)) }
                .buttonStyle(.lowtide(.destructive, size: .small))
                .disabled(working)
        }
        .padding(Space.sm)
    }

    private func askUninstall(_ ids: [String]) {
        let apps = model.apps.filter { ids.contains($0.id) && !$0.protected }
        guard !apps.isEmpty else { return }
        confirm = ConfirmRequest(
            title: apps.count == 1 ? "Uninstall \(apps[0].name)?" : "Uninstall \(apps.count) apps?",
            message: "\(appsNames(apps.map(\.name))), with \(apps.count == 1 ? "its" : "their") settings, caches and support files. "
                + "Everything goes to the Trash, so you can restore it until you empty it. Running apps are quit first; files shared with other products are kept.",
            confirm: "Move to Trash"
        ) {
            // The checks stay while it runs: the bar shows how far it is, and
            // what's gone drops out of them as it goes.
            model.uninstall(apps)
            if let id = selectedID, ids.contains(id) { selectedID = nil }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private func detail(_ updates: [String: AppUpdate]) -> some View {
        if filter == .broken {
            EmptyState("Broken Homebrew records", symbol: "shippingbox",
                       message: "Homebrew still lists these apps, but their bundle is gone from Applications. Pick one to reinstall it, or remove the record.")
        } else if let app = model.app(selectedID) {
            if app.protected {
                EmptyState("\(app.name) is part of macOS", symbol: "lock",
                           message: "Apps that ship with macOS are protected by the system.")
            } else {
                FootprintMap(
                    model: FootprintModel(
                        locate: { [prefixes = model.prefixes] in
                            try await Footprint.locate(Footprint.subject(app: app.path, prefixes: prefixes))
                        },
                        remove: { paths, progress in
                            await AppRemover.remove(AppRemover.Request(name: app.name, paths: paths, quitBundleID: app.bundleID,
                                                                       brewToken: paths.contains(app.path) ? app.brewToken : nil),
                                                    progress: progress)
                        }),
                    subject: "\(app.name) and its files",
                    onRemoved: { result, bytes in
                        AppsReport.finish(result, bytes: bytes) { InstalledAppsModel.shared.scan() }
                        guard !FileManager.default.fileExists(atPath: app.path) else { return }
                        model.forget([app.id])
                        // Another app may have been picked meanwhile.
                        if selectedID == app.id { selectedID = nil }
                    }
                ) {
                    AppHeader(app: app, update: updates[app.path], adoptable: model.records.adoptable(app))
                }
                .id(app.id)
            }
        } else {
            EmptyState("Select an app", symbol: "app.badge",
                       message: "Pick an app to see its version, where it came from and every file it put on this Mac, including hidden ones. Uninstall removes them all.")
        }
    }
}

/// The selected app: icon, name, version, where it came from, and what
/// can be done besides removing it.
private struct AppHeader: View {
    @Environment(\.palette) private var palette
    private var model = InstalledAppsModel.shared
    let app: InstalledApp
    let update: AppUpdate?
    let adoptable: Cask?

    init(app: InstalledApp, update: AppUpdate?, adoptable: Cask?) {
        self.app = app
        self.update = update
        self.adoptable = adoptable
    }

    var body: some View {
        HStack(alignment: .top, spacing: Space.lg) {
            AppsIcon(path: app.path, size: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(.title(.lg)).foregroundStyle(palette.ink.color).lineLimit(1).textSelection(.enabled)
                HStack(spacing: 0) {
                    if let version = app.version { Text(version).font(.mono(.xs)); Text(" · ") }
                    Text(app.source.label)
                    if let bytes = app.bytes { Text(" · "); Text(LowtideFormat.bytes(bytes)).font(.mono(.xs)).monospacedDigit() }
                }
                .font(.ui(.xs)).foregroundStyle(palette.ink3.color).lineLimit(1)
                HStack(spacing: 0) {
                    Text(appsLastOpened(app.lastUsed).capitalizedFirst).foregroundStyle(palette.ink3.color)
                    if let id = app.bundleID { Text(" · "); Text(id).font(.mono(.xxs)).textSelection(.enabled) }
                }
                .font(.ui(.xxs)).foregroundStyle(palette.ink4.color).lineLimit(1)
                if update != nil || adoptable != nil {
                    HStack(spacing: 6) {
                        if let update {
                            Button("Update to \(update.available)") { AppModel.shared.open(.appsUpdates) }
                                .buttonStyle(.lowtide(.primary, size: .small))
                        }
                        if let adoptable {
                            Button {
                                model.adopt([adoptable])
                            } label: {
                                Label(model.brewPending[adoptable.token] != nil ? "Adopting…" : "Adopt", systemImage: "shippingbox")
                            }
                            .buttonStyle(.lowtide(.secondary, size: .small))
                            .disabled(model.brewBusy)
                            .help("Let Homebrew keep it up to date. It isn’t reinstalled.")
                        }
                    }
                    .padding(.top, Space.sm)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private extension String {
    /// `opened 3 days ago` → `Opened 3 days ago`.
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
