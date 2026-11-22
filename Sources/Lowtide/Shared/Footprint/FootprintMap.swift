import LowtideKit
import SwiftUI

/// Everything one app, plug-in or deleted app put on the Mac: found,
/// measured as sizes land, chosen, and moved to the Trash. Apps → Installed,
/// Add-ons › Audio plug-ins and Cleanup → Leftovers each hand it their own
/// `locate` and removal.
@Observable
final class FootprintModel {
    struct Contents {
        var list: [Footprint.Child]?
        var selected: Set<String> = []
    }

    struct Plan {
        var paths: [String] = []
        var bytes: Int64 = 0
        var admin = 0
    }

    /// Where a removal is: what's happening, how far (0…1).
    typealias Progress = @Sendable (_ text: String, _ fraction: Double) -> Void

    private let locate: () async throws -> [Footprint.Item]
    private let removal: (_ paths: [String], _ progress: @escaping Progress) async -> Footprint.RemoveResult
    private(set) var items: [Footprint.Item] = []
    private(set) var loading = false
    private(set) var loaded = false
    private(set) var failure: String?
    /// What a running removal is doing; nil when none runs.
    private(set) var removing: String?
    var selected: Set<String> = []
    private(set) var contents: [String: Contents] = [:]
    var collapsed: Set<Footprint.Category> = []

    /// `remove` moves the chosen paths (`Footprint.remove` with the right
    /// password prompt, or `AppRemover`: quit the app first, Homebrew…).
    init(locate: @escaping () async throws -> [Footprint.Item],
         remove: @escaping (_ paths: [String], _ progress: @escaping Progress) async -> Footprint.RemoveResult) {
        self.locate = locate
        self.removal = remove
    }

    func start() {
        guard !loading, !loaded else { return }
        reload()
    }

    func reload() {
        loading = true
        failure = nil
        Task {
            let found: [Footprint.Item]
            do { found = try await locate() } catch {
                failure = error.localizedDescription
                loading = false
                return
            }
            items = found
            selected = Set(found.filter(\.preselected).map(\.path))
            contents = [:]
            loading = false
            loaded = true
            for await (index, bytes) in SizeStream.measure(found.map(\.path), width: 8) {
                if items.indices.contains(index), items[index].path == found[index].path { items[index].bytes = bytes }
            }
        }
    }

    var total: Int64 { items.reduce(0) { $0 + ($1.bytes ?? 0) } }

    /// Categories, biggest first, each with its items biggest first.
    var groups: [(category: Footprint.Category, items: [Footprint.Item], bytes: Int64)] {
        let order = Footprint.Category.allCases
        return Dictionary(grouping: items, by: \.category)
            .map { ($0.key, $0.value.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }, $0.value.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }) }
            .sorted { ($0.2, order.firstIndex(of: $1.0) ?? 99) > ($1.2, order.firstIndex(of: $0.0) ?? 99) }
    }

    /// The app bundle itself: leaving it out resets the app instead.
    var bundles: [Footprint.Item] { items.filter { $0.category == .app } }
    var resetting: Bool { !bundles.isEmpty && bundles.allSatisfy { !selected.contains($0.path) } }

    func state(_ item: Footprint.Item) -> CheckState {
        let on = selected.contains(item.path)
        if on, let inner = contents[item.path], let list = inner.list, inner.selected.count < list.count {
            return inner.selected.isEmpty ? .off : .mixed
        }
        return on ? .on : .off
    }

    func toggle(_ item: Footprint.Item, to force: Bool? = nil) {
        let on = force ?? !selected.contains(item.path)
        if on { selected.insert(item.path) } else { selected.remove(item.path) }
        if let list = contents[item.path]?.list {
            contents[item.path]?.selected = on ? Set(list.map(\.path)) : []
        }
    }

    func toggleGroup(_ items: [Footprint.Item]) {
        let target = items.contains { !selected.contains($0.path) }
        for item in items { toggle(item, to: target) }
    }

    func expand(_ item: Footprint.Item) {
        if contents[item.path] != nil {
            contents[item.path] = nil
            return
        }
        contents[item.path] = Contents()
        Task {
            do {
                let list = try await Footprint.children(item.path)
                guard contents[item.path] != nil else { return }
                contents[item.path] = Contents(list: list, selected: selected.contains(item.path) ? Set(list.map(\.path)) : [])
            } catch {
                contents[item.path] = nil
                Toasts.shared.failure("Couldn’t open \(item.name)", error)
            }
        }
    }

    func toggleChild(_ item: Footprint.Item, _ path: String) {
        guard var inner = contents[item.path], inner.list != nil else { return }
        if inner.selected.contains(path) { inner.selected.remove(path) } else { inner.selected.insert(path) }
        contents[item.path] = inner
        if inner.selected.isEmpty { selected.remove(item.path) } else { selected.insert(item.path) }
    }

    /// Reset keeps the app and removes its settings, caches and data.
    func switchReset() {
        var next = Set(items.filter(\.preselected).map(\.path))
        if !resetting { next.subtract(bundles.map(\.path)) }
        selected = next
        contents = [:]
    }

    /// What removal gets: whole items, or only the chosen parts of one.
    var plan: Plan {
        var plan = Plan()
        for item in items where selected.contains(item.path) {
            if let inner = contents[item.path], let list = inner.list, inner.selected.count < list.count {
                for child in list where inner.selected.contains(child.path) {
                    plan.paths.append(child.path)
                    plan.bytes += child.bytes ?? 0
                }
            } else {
                plan.paths.append(item.path)
                plan.bytes += item.bytes ?? 0
            }
            if item.needsAdmin { plan.admin += 1 }
        }
        return plan
    }

    /// Moves the plan to the Trash, then hands `done` what happened and the
    /// bytes that went (to say so, with Undo).
    func remove(done: @escaping (Footprint.RemoveResult, Int64) -> Void) {
        let plan = self.plan
        guard !plan.paths.isEmpty else { return }
        removing = "Moving \(LowtideFormat.count(plan.paths.count, "item")) (\(LowtideFormat.bytes(plan.bytes))) to the Trash…"
        Jobs.shared.start("Moving \(LowtideFormat.count(plan.paths.count, "item")) to the Trash", page: AppModel.shared.page) { [self] job in
            defer { removing = nil }
            let result = await removal(plan.paths) { text, fraction in
                Task { @MainActor in
                    job.detail = text
                    job.progress = fraction
                    if fraction < 1 { self.removing = text + "…" }
                }
            }
            let gone = Set(result.removed)
            var freed = items.filter { gone.contains($0.path) }.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
            for child in contents.values.flatMap({ $0.list ?? [] }) where gone.contains(child.path) { freed += child.bytes ?? 0 }
            done(result, freed)
            reload()
        }
    }
}

/// The footprint map: a two-level map (kinds, then their files, by size),
/// then each kind as a list with checkboxes, folders that open one level,
/// and a footer that says what goes and moves it to the Trash. Leaving the
/// app bundle out resets the app instead.
struct FootprintMap<Header: View>: View {
    @Environment(\.palette) private var palette
    @State private var model: FootprintModel
    /// What the button removes, e.g. "Figma and its files".
    let subject: String
    /// After a removal: what happened and the bytes that went.
    var onRemoved: (Footprint.RemoveResult, Int64) -> Void
    @ViewBuilder var header: Header
    @State private var confirm: ConfirmRequest?

    /// Give each subject its own view identity (`.id`): the model is kept
    /// for the life of the view.
    init(model: FootprintModel, subject: String, onRemoved: @escaping (Footprint.RemoveResult, Int64) -> Void,
         @ViewBuilder header: () -> Header) {
        _model = State(initialValue: model)
        self.subject = subject
        self.onRemoved = onRemoved
        self.header = header()
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    header
                    content
                }
                .padding(.horizontal, Space.page)
                .padding(.vertical, Space.page)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollContentBackground(.hidden)
            if !model.items.isEmpty { footer }
        }
        .confirmation($confirm)
        .task { model.start() }
    }

    @ViewBuilder private var content: some View {
        if let failure = model.failure {
            EmptyState("Couldn’t map the files", symbol: "exclamationmark.triangle", message: failure) {
                Button("Try Again") { model.reload() }.buttonStyle(.secondary)
            }
            .frame(minHeight: 260)
        } else if model.loading, !model.loaded {
            ScanningState(title: "Finding every file it put on this Mac", detail: "Receipts, bundle ids, names and the developer’s folders")
                .frame(minHeight: 260)
        } else if model.items.isEmpty {
            EmptyState("Already gone", symbol: "checkmark.circle", message: "Nothing of it is left on disk.").frame(minHeight: 260)
        } else {
            let groups = model.groups
            VStack(alignment: .leading, spacing: Space.sm) {
                map(groups).padding(6).card()
                HStack(spacing: Space.lg) {
                    swatch(palette.brand.opacity(0.6), "Removed")
                    swatch(palette.warn.opacity(0.5), "Shared, check first")
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).strokeBorder(palette.lineStrong.color, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                            .frame(width: 8, height: 8)
                        Text("Kept")
                    }
                    Spacer()
                    Text("Click a tile to keep or remove it").foregroundStyle(palette.ink4.color)
                }
                .font(.ui(.xxs)).foregroundStyle(palette.ink3.color)
                .padding(.horizontal, Space.xs)
            }
            VStack(spacing: Space.lg) {
                ForEach(groups, id: \.category) { group in section(group) }
            }
        }
    }

    private func swatch(_ color: ColorValue, _ text: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color.color).frame(width: 8, height: 8)
            Text(text)
        }
    }

    /// Area follows √size: a 150 GB container would otherwise leave every
    /// other file an unclickable sliver. Labels keep the real sizes.
    private func map(_ groups: [(category: Footprint.Category, items: [Footprint.Item], bytes: Int64)]) -> some View {
        let total = Double(max(model.total, 1))
        func weight(_ bytes: Int64?) -> Double { max(Double(bytes ?? 0).squareRoot(), total.squareRoot() * 0.02) }
        let mapped = groups.map { group in
            FileMap.Group(id: group.category.rawValue, title: group.category.label, bytes: group.bytes,
                          cells: group.items.map { item in
                              FileMap.Cell(id: item.path, name: item.name, bytes: item.bytes, weight: weight(item.bytes), path: item.path,
                                           style: !model.selected.contains(item.path) ? .kept : item.confidence == .shared ? .shared : .removed,
                                           detail: item.reason)
                          })
        }
        return FileMap(groups: mapped, height: 232) { cell in
            if let item = model.items.first(where: { $0.path == cell.id }) { model.toggle(item) }
        }
    }

    private func section(_ group: (category: Footprint.Category, items: [Footprint.Item], bytes: Int64)) -> some View {
        let open = !model.collapsed.contains(group.category)
        let on = group.items.filter { model.selected.contains($0.path) }.count
        let label = group.category.label
        return VStack(spacing: 0) {
            HStack(spacing: Space.sm) {
                Button {
                    withAnimation(Motion.base) {
                        if open { model.collapsed.insert(group.category) } else { model.collapsed.remove(group.category) }
                    }
                } label: {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 20, height: 20).contentShape(.rect)
                }
                .buttonStyle(.plain).foregroundStyle(palette.ink3.color)
                .help(open ? "Collapse" : "Expand")
                Button { model.toggleGroup(group.items) } label: {
                    CheckMark(state: on == 0 ? .off : on == group.items.count ? .on : .mixed)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove all \(label)")
                Text(label).font(.ui(.sm, .semibold)).foregroundStyle(palette.ink.color)
                Text("\(on) of \(group.items.count)").font(.ui(.xxs)).foregroundStyle(palette.ink3.color).monospacedDigit()
                Spacer()
                Text(LowtideFormat.bytes(group.bytes)).font(.mono(.xs)).monospacedDigit().foregroundStyle(palette.ink.color)
            }
            .padding(.horizontal, Space.md)
            .frame(height: 40)
            if open {
                ForEach(group.items) { item in
                    Hairline()
                    itemRow(item)
                }
            }
        }
        .card()
    }

    private func itemRow(_ item: Footprint.Item) -> some View {
        let inner = model.contents[item.path]
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { model.expand(item) } label: {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(inner != nil ? 90 : 0)).frame(width: 20, height: 20).contentShape(.rect)
                }
                .buttonStyle(.plain).foregroundStyle(palette.ink4.color)
                .opacity(item.isDir ? 1 : 0).disabled(!item.isDir)
                .help(inner != nil ? "Collapse" : "Show contents")
                Button { model.toggle(item) } label: { CheckMark(state: model.state(item)) }
                    .buttonStyle(.plain).accessibilityLabel("Remove \(item.name)")
                FileIcon(path: item.path, size: 18)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(item.name).font(.ui(.sm)).foregroundStyle(palette.ink.color).lineLimit(1)
                        if item.hidden {
                            Image(systemName: "eye.slash").font(.system(size: 9)).foregroundStyle(palette.ink4.color)
                                .help("Hidden: Finder doesn’t show it").accessibilityLabel("Hidden")
                        }
                        if item.needsAdmin {
                            Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(palette.ink4.color)
                                .help("Belongs to the system: needs your password or the helper").accessibilityLabel("Needs your password")
                        }
                        if let label = item.confidence.label {
                            Text(label).font(.ui(.xxs))
                                .foregroundStyle((item.confidence == .shared ? palette.warn : palette.ink4).color)
                                .help(item.reason)
                        }
                    }
                    Sensitive(text: Paths.tilde(item.path), font: .mono(.xxs))
                        .foregroundStyle(palette.ink3.color).lineLimit(1).truncationMode(.middle).help(item.path)
                }
                Spacer(minLength: Space.sm)
                Clean.SizeLabel(bytes: item.bytes, measuring: item.bytes == nil).frame(width: 80, alignment: .trailing)
            }
            .padding(.leading, Space.sm).padding(.trailing, Space.lg)
            .frame(minHeight: 42)
            .contentShape(.rect)
            .onTapGesture { model.toggle(item) }
            .contextMenu { PathMenu(item.path) }
            if let inner {
                VStack(spacing: 0) {
                    if let list = inner.list {
                        ForEach(list) { child in
                            HStack(spacing: 10) {
                                Button { model.toggleChild(item, child.path) } label: {
                                    CheckMark(state: inner.selected.contains(child.path) ? .on : .off)
                                }
                                .buttonStyle(.plain).accessibilityLabel("Remove \(child.name)")
                                Image(systemName: child.isDir ? "folder" : "doc").font(.system(size: 10)).foregroundStyle(palette.ink4.color)
                                Text(child.name).font(.ui(.xs)).foregroundStyle(palette.ink2.color).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(child.bytes.map(LowtideFormat.bytes) ?? "–").font(.mono(.xxs)).monospacedDigit().foregroundStyle(palette.ink3.color)
                            }
                            .padding(.horizontal, Space.lg).frame(minHeight: 30)
                            .contentShape(.rect)
                            .onTapGesture { model.toggleChild(item, child.path) }
                            .contextMenu { PathMenu(child.path) }
                        }
                    } else {
                        HStack(spacing: Space.sm) {
                            ProgressView().controlSize(.mini)
                            Text("Measuring contents…").font(.ui(.xxs)).foregroundStyle(palette.ink3.color)
                        }
                        .padding(.horizontal, Space.lg).frame(height: 30, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .overlay(alignment: .leading) { Rectangle().fill(palette.line.color).frame(width: 1) }
                .padding(.leading, 56)
                .padding(.bottom, Space.xs)
            }
        }
    }

    private var footer: some View {
        let plan = model.plan
        return HStack(spacing: Space.md) {
            if let removing = model.removing {
                // Quitting the app, Homebrew and the move: no measure of how
                // far along, so the bar runs and the words say what happens.
                VStack(alignment: .leading, spacing: 6) {
                    Text(removing).font(.ui(.xs)).foregroundStyle(palette.ink2.color).lineLimit(1)
                    ProgressView().progressViewStyle(.linear).tint(palette.brand.color).frame(maxWidth: 280)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(LowtideFormat.bytes(plan.bytes)).font(.mono(.sm, .medium)).monospacedDigit().foregroundStyle(palette.ink.color)
                        Text("of \(LowtideFormat.bytes(model.total))").font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                    }
                    HStack(spacing: 4) {
                        Text(LowtideFormat.count(plan.paths.count, "item"))
                        if plan.admin > 0, PrivilegedHelper.state != .on {
                            Text("·")
                            Image(systemName: "lock.fill").font(.system(size: 9))
                            Text(plan.admin == 1 ? "1 needs your password ·" : "\(plan.admin) need your password ·")
                            SkipPasswordLink()
                        }
                    }
                    .font(.ui(.xxs)).foregroundStyle(palette.ink3.color).lineLimit(1).fixedSize()
                }
                .layoutPriority(1)
            }
            Spacer(minLength: Space.sm)
            if !model.bundles.isEmpty {
                Button(model.resetting ? "Remove the app too" : "Reset instead") { model.switchReset() }
                    .buttonStyle(.quiet)
                    .fixedSize()
                    .disabled(model.removing != nil)
                    .help("Reset keeps the app and removes its settings, caches and data, as if it were just installed")
            }
            Button { ask(plan) } label: {
                Label(model.removing != nil ? "Removing…" : "Move \(LowtideFormat.bytes(plan.bytes)) to Trash", systemImage: "trash")
            }
            .buttonStyle(.destructive)
            .disabled(plan.paths.isEmpty || model.removing != nil)
        }
        .padding(.horizontal, Space.page)
        .frame(height: 60)
        .background(palette.bg.color)
        .hairline(.top)
    }

    private func ask(_ plan: FootprintModel.Plan) {
        let count = LowtideFormat.count(plan.paths.count, "item")
        let resetting = model.resetting
        let what = resetting
            ? "Reset: the app stays, and \(count) of its files (\(LowtideFormat.bytes(plan.bytes))) go, as if it were just installed."
            : "Remove \(subject): \(count), \(LowtideFormat.bytes(plan.bytes))."
        let quits = model.bundles.isEmpty ? "" : " A running app is quit first."
        confirm = ConfirmRequest(
            title: resetting ? "Reset \(subject)?" : "Remove \(subject)?",
            message: what + " Everything goes to the Trash, so you can restore it until you empty it." + quits,
            confirm: "Move \(count) to Trash"
        ) { [model, onRemoved] in model.remove(done: onRemoved) }
    }
}

/// Where a removal would ask for the password: approve the helper once in
/// Login Items and it never asks again. Nothing once it's on, or in a
/// development build.
struct SkipPasswordLink: View {
    @Environment(\.palette) private var palette
    @State private var state = PrivilegedHelper.state

    var body: some View {
        Group {
            if state == .off || state == .approval {
                Button(state == .approval ? "Allow it in Login Items to stop asking" : "Stop asking for it") {
                    state = (try? PrivilegedHelper.enable()) ?? PrivilegedHelper.state
                }
                .buttonStyle(.plain)
                .font(.ui(.xxs, .medium))
                .foregroundStyle(palette.brand.color)
                .help("Approve Lowtide’ helper once in System Settings › Login Items; removals then never ask for the password")
            }
        }
        // Approval happens in System Settings: look again on coming back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state = PrivilegedHelper.state
        }
    }
}
