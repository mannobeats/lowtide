import LowtideKit
import SwiftUI

typealias MapApp = PermissionMap.App

/// The permission map: every app with what macOS lets it do (privacy
/// grants), what it starts with the Mac (login items, launch agents and
/// daemons), and start-up items that point at something gone.
struct PermissionsPage: View {
    enum Filter: String, Hashable, CaseIterable {
        case all, login, powerful, broken
        var label: String {
            ["All", "Start at login", "Powerful", "Broken"][Self.allCases.firstIndex(of: self)!]
        }
        var title: String {
            ["Permission map", "Login items", "Powerful apps", "Broken start-up items"][
                Self.allCases.firstIndex(of: self)!]
        }
        func test(_ app: MapApp) -> Bool {
            switch self {
            case .all: true
            case .login: app.startsAtLogin
            case .powerful: app.powerful
            case .broken: app.broken
            }
        }
    }

    @Environment(\.palette) private var palette
    private var model = ProtectionModel.shared
    @State private var filter = Filter.all
    @State private var column: String?
    @State private var query = ""
    @State private var selectedKey: String?
    @State private var checks = Checks<String>()
    @State private var confirm: ConfirmRequest?

    var body: some View {
        let apps = model.permissions?.apps ?? []
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let visible = apps.filter { app in
            filter.test(app) && (column.map(app.has) ?? true)
                && (needle.isEmpty || app.name.lowercased().contains(needle)
                    || (app.bundleID ?? "").lowercased().contains(needle))
        }
        let selected = apps.first { $0.key == selectedKey }
        let picked = apps.filter { checks.has($0.key) }
        VStack(spacing: 0) {
            PageHeader(
                filter.title,
                description: model.permissions.map { summary($0.apps) }
                    ?? "Reading permissions, login items and background jobs…"
            ) {
                EmptyView()
            } action: {
                Button {
                    Task { await model.loadPermissions(force: true) }
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                        .symbolEffect(.rotate, isActive: model.permissionsLoading)
                }
                .buttonStyle(.lowtide(.quiet, size: .small))
                .disabled(model.permissionsLoading)
            }
            HStack(spacing: 0) {
                ZStack(alignment: .bottom) {
                    map(apps: apps, visible: visible)
                    SelectionBar(count: picked.count, noun: "app", clear: { checks.clear() }) {
                        bulkButtons(picked)
                    }
                }
                .animation(Motion.base, value: picked.count)
                if let selected {
                    Rectangle().fill(palette.line.color).frame(width: 1)
                    PermissionDetail(app: selected, confirm: $confirm) {
                        withAnimation(Motion.base) { selectedKey = nil }
                    }
                    .id(selected.key)
                    .frame(width: 320)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .overlay(alignment: .top) { Hairline() }
        }
        .confirmation($confirm)
        .task { await model.loadPermissions() }
    }

    private func summary(_ apps: [MapApp]) -> String {
        let broken = apps.filter(\.broken).count
        // Deleted apps get their say in Cleanup › Leftovers, not in this line.
        var parts = [
            LowtideFormat.count(apps.count, "app"),
            "\(apps.filter(\.startsAtLogin).count) open at login",
        ]
        // Without Full Disk Access the grants are unknown, not zero.
        if model.permissions?.grantsReadable == true {
            parts.insert("\(apps.filter(\.powerful).count) with powerful access", at: 1)
        }
        if broken > 0 { parts.append(LowtideFormat.count(broken, "broken start-up item")) }
        return parts.joined(separator: " · ")
    }

    // MARK: The map

    static let cell: CGFloat = 44

    /// Grant columns, only once the grants can be read: without Full Disk
    /// Access they would be columns of nothing.
    static var shownColumns: [(id: String, label: String, short: String)] {
        ProtectionModel.shared.permissions?.grantsReadable == true ? PermissionMap.columns : []
    }
    static let login: CGFloat = 52
    static let traffic: CGFloat = 72

    @ViewBuilder
    private func map(apps: [MapApp], visible: [MapApp]) -> some View {
        let order = visible.map(\.key)
        let showTraffic = apps.contains { $0.traffic != nil } && selectedKey == nil
        ScrollView {
            VStack(alignment: .leading, spacing: Space.sm) {
                if let map = model.permissions, !map.grantsReadable {
                    AccessNotice()
                }
                if model.permissions != nil {
                    HStack(spacing: Space.sm) {
                        let counts = Dictionary(
                            uniqueKeysWithValues: Filter.allCases.map { f in (f, apps.filter(f.test).count) })
                        Segmented(
                            $filter,
                            Filter.allCases.filter { ($0 != .broken || counts[.broken, default: 0] > 0) && ($0 != .powerful || model.permissions?.grantsReadable == true) }.map {
                                ($0, $0.label)
                            },
                            counts: counts)
                        Spacer(minLength: Space.md)
                        FilterField(text: $query, prompt: "Find an app")
                    }
                    .padding(.top, Space.lg)
                    .padding(.bottom, Space.xs)
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(visible) { app in
                                MapRow(
                                    app: app, checked: checks.has(app.key), selected: app.key == selectedKey,
                                    showTraffic: showTraffic,
                                    onCheck: { checks.toggle(app.key, in: order) },
                                    onSelect: {
                                        withAnimation(Motion.base) {
                                            selectedKey = selectedKey == app.key ? nil : app.key
                                        }
                                    }
                                )
                                .contextMenu {
                                    rowMenu(
                                        app, targets: checks.has(app.key) ? apps.filter { checks.has($0.key) } : [app])
                                }
                            }
                        } header: {
                            header(apps: apps, order: order, showTraffic: showTraffic)
                        }
                    }
                }
                if model.permissions == nil {
                    ScanningState(title: "Reading permissions, login items and background jobs…").frame(
                        minHeight: 300)
                } else if visible.isEmpty {
                    EmptyState(
                        "Nothing matches", symbol: "line.3.horizontal.decrease",
                        message: "Try another filter or search."
                    )
                    .frame(minHeight: 240)
                }
            }
            .padding(.horizontal, Space.page)
            .padding(.bottom, Space.page * 3)
            .frame(minWidth: 620)
        }
    }

    private func header(apps: [MapApp], order: [String], showTraffic: Bool) -> some View {
        let all = !order.isEmpty && order.allSatisfy(checks.has)
        return HStack(alignment: .bottom, spacing: 0) {
            Checkbox(checks.state(of: order), label: "Select all") { checks.set(order, on: !all) }
            .frame(width: 26)
            Text("App").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, Space.sm)
                .padding(.bottom, 5)
            ForEach(PermissionsPage.shownColumns, id: \.id) { col in
                let count = apps.filter { $0.has(col.id) }.count
                let on = column == col.id
                Button {
                    withAnimation(Motion.fast) { column = on ? nil : col.id }
                } label: {
                    VStack(spacing: 1) {
                        Text(count > 0 ? "\(count)" : "–").font(.ui(.xxs, .semibold)).monospacedDigit()
                        Text(col.short)
                    }
                    .foregroundStyle((on ? palette.ink : palette.ink3).color)
                    .frame(width: Self.cell - 2, height: 34)
                    .background(
                        (on ? palette.selected : ColorValue(r: 0, g: 0, b: 0, a: 0)).color,
                        in: .rect(cornerRadius: Radius.sm)
                    )
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .frame(width: Self.cell)
                .help("\(col.label): \(count) apps. Click to show only them.")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Text("Login").frame(width: Self.login).padding(.bottom, 5)
            if showTraffic {
                Text("7 days").frame(width: Self.traffic, alignment: .trailing).padding(.bottom, 5)
            }
        }
        .font(.ui(.xxs))
        .foregroundStyle(palette.ink3.color)
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.xs)
        .background(palette.bg.color)
        .overlay(alignment: .bottom) { Hairline() }
    }

    // MARK: Actions

    @ViewBuilder
    private func bulkButtons(_ apps: [MapApp]) -> some View {
        let kinds = PermissionBulk.allCases.filter { !$0.plan(apps).steps.isEmpty }
        if kinds.isEmpty {
            Text("macOS only lets System Settings remove these.").font(.ui(.xs)).foregroundStyle(
                palette.ink3.color)
        }
        if PermissionBulk.revoke.plan(apps).skipped > 0 {
            Button("System Settings") {
                let service = apps.flatMap(\.grants).first { !$0.revocable }?.service ?? "login"
                NSWorkspace.shared.open(PermissionMap.settingsURL(service))
            }
            .buttonStyle(.lowtide(.quiet, size: .small))
        }
        ForEach(kinds, id: \.self) { kind in
            Button(kind.label) { ask(kind, apps) }
                .buttonStyle(.lowtide(kind == .trash ? .destructive : .secondary, size: .small))
        }
    }

    @ViewBuilder
    private func rowMenu(_ app: MapApp, targets: [MapApp]) -> some View {
        let scope = targets.count > 1 ? " (\(targets.count) apps)" : ""
        let findable =
            app.installed && app.path != nil ? app.path : app.background.compactMap(\.plist).first
        Button("Reveal in Finder") { if let findable { FileActions.reveal(findable) } }.disabled(
            findable == nil)
        Button("Open App") { if let path = app.path { FileActions.open(path) } }
            .disabled(!(app.installed && app.path?.hasSuffix(".app") == true))
        if let id = app.bundleID {
            Button("Copy Bundle ID") { FileActions.copy(id, what: "Bundle ID") }
        }
        if let findable { Button("Copy Path") { FileActions.copy(findable) } }
        Divider()
        ForEach([PermissionBulk.revoke, .stop], id: \.self) { kind in
            Button(kind.label + scope + "…") { ask(kind, targets) }.disabled(
                kind.plan(targets).steps.isEmpty)
        }
        if !PermissionBulk.trash.plan(targets).steps.isEmpty {
            Button(PermissionBulk.trash.label + scope + "…", role: .destructive) { ask(.trash, targets) }
        }
        Divider()
        Button("Open in System Settings") {
            NSWorkspace.shared.open(PermissionMap.settingsURL(app.grants.first?.service ?? "login"))
        }
    }

    private func ask(_ kind: PermissionBulk, _ apps: [MapApp]) {
        confirm = ConfirmRequest(
            title: kind.label, message: kind.describe(apps) + " " + kind.note, confirm: kind.confirm,
            destructive: kind != .stop
        ) {
            run(kind, apps)
        }
    }

    /// One kind of action over apps, one step at a time (launchctl and
    /// tccutil don't like a crowd), as a job that survives navigation.
    private func run(_ kind: PermissionBulk, _ apps: [MapApp]) {
        let names = apps.count == 1 ? apps[0].name : LowtideFormat.count(apps.count, "app")
        Jobs.shared.start("\(kind.label): \(names)", page: .permissions) { job in
            var done = 0
            var failed: [String] = []
            for (index, app) in apps.enumerated() {
                job.detail = "\(index + 1) of \(apps.count): \(app.name)"
                job.progress = Double(index) / Double(apps.count)
                do {
                    for step in kind.plan([app]).steps { try await step.run() }
                    done += 1
                } catch {
                    failed.append("\(app.name): \(error.localizedDescription)")
                }
            }
            checks.clear()
            await ProtectionModel.shared.loadPermissions(force: true)
            if failed.isEmpty {
                Toasts.shared.show("\(LowtideFormat.count(done, "app")) \(kind.verb)")
            } else {
                Toasts.shared.show(
                    "\(done) of \(apps.count) \(kind.verb)", detail: failed.joined(separator: "\n"),
                    tone: .bad)
            }
        }
    }
}

/// What can be done to a set of apps, and what it can't do.
enum PermissionBulk: CaseIterable, Hashable {
    case revoke, stop, trash

    struct Step {
        let run: () async throws -> Void
    }

    var label: String {
        self == .revoke
            ? "Remove Permissions" : self == .stop ? "Stop at Login" : "Move Broken Agents to Trash"
    }
    var confirm: String {
        self == .revoke ? "Remove Permissions" : self == .stop ? "Stop at Login" : "Move to Trash"
    }
    var verb: String {
        self == .revoke
            ? "had permissions removed"
            : self == .stop ? "stopped at login" : "had broken agents moved to the Trash"
    }
    var note: String {
        switch self {
        case .revoke: "The apps will ask again the next time they need them."
        case .stop: "Stopped agents can be allowed again from the app's panel."
        case .trash: "Their plists go to the Trash; put them back from there to undo."
        }
    }

    /// The steps for these apps, and how many items it can't change here.
    func plan(_ apps: [MapApp]) -> (steps: [Step], skipped: Int) {
        var steps: [Step] = []
        var skipped = 0
        for app in apps {
            switch self {
            case .revoke:
                // One reset per service clears every Automation target too.
                // A deleted app gets one reset for everything: each costs a
                // stand-in bundle.
                let revocable = app.grants.filter(\.revocable)
                let services =
                    app.installed || revocable.isEmpty
                    ? Array(Set(revocable.map(\.service))).sorted() : ["All"]
                for service in services {
                    steps.append(
                        Step { try await PermissionActions.shared.revoke(key: app.key, service: service) })
                }
                skipped += app.grants.filter { !$0.revocable }.count
            case .stop:
                for item in app.background where item.active {
                    // Daemons ask for a password each; Login Items only in Settings.
                    if item.control == .lowtide {
                        steps.append(
                            Step { try await PermissionActions.shared.setStartup(id: item.id, on: false) })
                    } else {
                        skipped += 1
                    }
                }
            case .trash:
                for item in app.background where item.removable {
                    steps.append(Step { try await PermissionActions.shared.trashLeftover(id: item.id) })
                }
            }
        }
        return (steps, skipped)
    }

    func describe(_ apps: [MapApp]) -> String {
        let (steps, skipped) = plan(apps)
        let what =
            switch self {
            case .revoke: LowtideFormat.count(steps.count, "permission")
            case .stop: LowtideFormat.count(steps.count, "start-up item")
            case .trash: LowtideFormat.count(steps.count, "broken agent")
            }
        let rest =
            skipped > 0
            ? " \(skipped) more can only be changed in System Settings or one at a time with your password."
            : ""
        return "\(what) across \(LowtideFormat.count(apps.count, "app")).\(rest)"
    }
}

private struct MapRow: View {
    @Environment(\.palette) private var palette
    @State private var hovering = false
    let app: MapApp
    let checked: Bool
    let selected: Bool
    let showTraffic: Bool
    let onCheck: () -> Void
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Checkbox(checked, label: "Select \(app.name)", toggle: onCheck).frame(width: 26)
            HStack(spacing: Space.sm) {
                if let path = app.path {
                    FileIcon(path: path, size: 16)
                } else {
                    Image(systemName: "app.dashed").font(.system(size: 13)).foregroundStyle(
                        palette.ink4.color
                    ).frame(width: 16)
                }
                name.lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, Space.sm)
            ForEach(PermissionsPage.shownColumns, id: \.id) { column in
                cell(on: app.has(column.id), strong: PermissionMap.powerful.contains(column.id))
                    .frame(width: PermissionsPage.cell)
            }
            loginCell.frame(width: PermissionsPage.login)
            if showTraffic {
                let total = (app.traffic?.bytesIn ?? 0) + (app.traffic?.bytesOut ?? 0)
                Text(total > 0 ? LowtideFormat.bytes(total) : "").font(.mono(.xxs)).monospacedDigit()
                    .foregroundStyle(palette.ink3.color).frame(
                        width: PermissionsPage.traffic, alignment: .trailing)
            }
        }
        .font(.ui(.sm))
        .padding(.horizontal, Space.md)
        .frame(height: 34)
        .background(
            (selected
                ? palette.selected
                : checked
                    ? palette.selectedBrand.opacity(0.5)
                    : hovering ? palette.hover : ColorValue(r: 0, g: 0, b: 0, a: 0)).color,
            in: .rect(cornerRadius: Radius.md)
        )
        .contentShape(.rect)
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder private var name: some View {
        if app.broken {
            Text(
                "\(Text(app.name).foregroundStyle(palette.bad.color))\(Text(" · broken start-up item").font(.ui(.xs)).foregroundStyle(palette.ink3.color))"
            )
        } else if !app.installed {
            // Gone, with grants macOS keeps: inert, so quiet.
            Text(
                "\(Text(app.name).foregroundStyle(palette.ink3.color))\(Text(" · app is gone").font(.ui(.xs)).foregroundStyle(palette.ink4.color))"
            )
        } else {
            Text(app.name).foregroundStyle(palette.ink.color)
        }
    }

    @ViewBuilder
    private func cell(on: Bool, strong: Bool) -> some View {
        if on {
            // A filled dot: granted. Powerful grants read a step louder.
            Circle().fill((strong ? palette.ink : palette.ink3).color).frame(width: 8, height: 8)
        } else {
            Rectangle().fill(palette.lineStrong.color).frame(width: 8, height: 1)
        }
    }

    @ViewBuilder private var loginCell: some View {
        let active = app.background.filter(\.active).count
        if app.background.isEmpty {
            Rectangle().fill(palette.lineStrong.color).frame(width: 8, height: 1)
        } else if active == 0 {
            // Registered but switched off: an outline.
            Circle().strokeBorder(palette.ink3.color, lineWidth: 1).frame(width: 8, height: 8).help(
                "Registered, switched off")
        } else {
            Text(active > 1 ? "\(active)×" : "On").font(.ui(.xs)).monospacedDigit().foregroundStyle(
                palette.ink.color)
        }
    }
}

/// Privacy grants need Full Disk Access to read.
private struct AccessNotice: View {
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: Space.md) {
            Image(systemName: "lock.shield").foregroundStyle(palette.warn.color)
            Text(
                "Privacy permissions are hidden until Lowtide has Full Disk Access. Start-up items are shown either way."
            )
            .font(.ui(.sm)).foregroundStyle(palette.ink2.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Open Full Disk Access") { NSWorkspace.shared.open(PermissionMap.settingsURL("disk")) }
                .buttonStyle(.lowtide(.secondary, size: .small))
            Button("Rescan") { Task { await ProtectionModel.shared.loadPermissions(force: true) } }
                .buttonStyle(.lowtide(.quiet, size: .small))
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .card()
        .padding(.top, Space.lg)
    }
}
