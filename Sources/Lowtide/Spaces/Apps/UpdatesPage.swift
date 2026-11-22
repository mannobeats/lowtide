import LowtideKit
import SwiftUI

/// Mac apps and command-line tools with newer versions: one Updates page,
/// two views. Apps are grouped by where the update comes from; each row
/// opens to what's new and how it installs.
struct UpdatesPage: View {
    @Environment(\.palette) private var palette
    @Bindable private var model = AppUpdatesModel.shared
    @State private var search = ""
    @State private var group: Group = .all
    @State private var openID: String?
    @State private var checks = Checks<String>()

    enum Group: String, CaseIterable {
        case all, developer, homebrew, appStore, skipped

        var label: String {
            switch self {
            case .all: "All"
            case .developer: "From the developer"
            case .homebrew: "Homebrew"
            case .appStore: "App Store"
            case .skipped: "Skipped"
            }
        }

        var short: String {
            switch self {
            case .developer: "Developer"
            default: label
            }
        }

        static func of(_ method: AppUpdate.Method) -> Group {
            switch method {
            case .appStore: .appStore
            case .cask, .homebrew: .homebrew
            case .electron, .sparkle, .vendor: .developer
            }
        }

        static let order: [Group] = [.developer, .homebrew, .appStore, .skipped]
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("Updates", description: description) {
                Segmented($model.view, [(.apps, "Apps"), (.tools, "Command-line tools")],
                          counts: [.apps: model.pending.count, .tools: model.toolUpdates])
            } action: {
                if model.view == .apps {
                    IconButton("arrow.clockwise", help: model.checking ? "Checking…" : "Check for updates again") { model.check(force: true) }
                        .disabled(model.checking)
                    let updatable = updatable(visible)
                    if !updatable.isEmpty {
                        Button("Update all") { model.install(updatable) }.buttonStyle(.primary)
                    }
                }
            }
            if model.view == .tools {
                ScrollView {
                    ToolUpdatesSection()
                        .padding(.horizontal, Space.page + 4)
                        .padding(.vertical, Space.lg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .hairline(.top)
            } else {
                apps
            }
        }
        .onAppear { if model.scan == nil { model.check(force: false) } }
    }

    private var description: String? {
        guard model.view == .apps, let scan = model.scan else { return nil }
        return "\(LowtideFormat.count(model.pending.count, "update")) · \(scan.checked) of \(scan.apps) apps checked \(LowtideFormat.ago(scan.checkedAt))"
    }

    private func groupOf(_ update: AppUpdate) -> Group { model.isSkipped(update) ? .skipped : Group.of(update.method) }

    private var visible: [AppUpdate] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        let pool = group == .skipped ? model.skippedList : model.pending
        return pool
            .filter { group == .all || groupOf($0) == group }
            .filter { needle.isEmpty || $0.name.lowercased().contains(needle) }
            .sorted { (Group.order.firstIndex(of: groupOf($0)) ?? 0) < (Group.order.firstIndex(of: groupOf($1)) ?? 0) }
    }

    /// Skipped versions stay skipped, a catalog cask needs Homebrew, and a
    /// developer's page is opened by hand.
    private func updatable(_ list: [AppUpdate]) -> [AppUpdate] {
        list.filter { !model.isSkipped($0) && $0.installsHere(homebrew: model.homebrew) && model.progress[$0.id]?.busy != true }
    }

    private func count(_ group: Group) -> Int {
        group == .skipped ? model.skippedList.count : model.pending.filter { Group.of($0.method) == group }.count
    }

    @ViewBuilder private var apps: some View {
        let visible = visible
        VStack(spacing: 0) {
            if model.scan != nil, !model.all.isEmpty {
                PageToolbar {
                    // A source with nothing waiting is noise, unless it's the one open.
                    Segmented($group, [(Group.all, "All")] + Group.order.filter { count($0) > 0 || $0 == group }.map { ($0, $0.short) },
                              counts: Dictionary(uniqueKeysWithValues: ([Group.all] + Group.order).map { ($0, $0 == .all ? model.pending.count : count($0)) }))
                } trailing: {
                    FilterField(text: $search, prompt: "Search updates")
                    if visible.count > 1 {
                        HStack(spacing: 6) {
                            Checkbox(checks.state(of: visible.map(\.id)), label: "Select all") {
                                checks.set(visible.map(\.id), on: checks.state(of: visible.map(\.id)) != .on)
                            }
                            Text("Select all").font(.ui(.xs)).foregroundStyle(palette.ink2.color)
                        }
                    }
                }
                .padding(.horizontal, Space.page + 4)
                .padding(.vertical, Space.sm)
                .hairline(.bottom)
            }
            ZStack(alignment: .bottom) {
                ScrollView {
                    content(visible)
                        .padding(.horizontal, Space.page + 4)
                        .padding(.top, Space.xl)
                        .padding(.bottom, checks.isEmpty ? Space.page : 72)
                        .frame(maxWidth: 1180)
                        .frame(maxWidth: .infinity)
                }
                .scrollContentBackground(.hidden)
                if !checks.isEmpty {
                    let selected = model.all.filter { checks.has($0.id) }
                    SelectionBar(count: checks.count, noun: "update", clear: { checks.clear() }) {
                        Button("Update") {
                            model.install(selected)
                            checks.clear()
                        }
                        .buttonStyle(.lowtide(.primary, size: .small))
                    }
                    .frame(maxWidth: 560)
                    .padding(Space.sm)
                }
            }
            .animation(Motion.base, value: checks.isEmpty)
        }
        .onChange(of: model.all.map(\.id)) { _, ids in checks.keep(Set(ids)) }
    }

    @ViewBuilder
    private func content(_ visible: [AppUpdate]) -> some View {
        if model.scan == nil {
            if let error = model.error {
                ErrorState(message: error) { model.check(force: true) }.frame(minHeight: 360)
            } else {
                ScanningState(title: "Checking your apps with the App Store, their developers and Homebrew").frame(minHeight: 360)
            }
        } else if visible.isEmpty {
            if !search.isEmpty || group != .all {
                EmptyState("No matching updates", symbol: "magnifyingglass", message: "Try another name, or show every source.").frame(minHeight: 360)
            } else if let scan = model.scan {
                VStack(spacing: Space.md) {
                    HeroArt("apps", size: 80)
                    Text("Everything is up to date").font(.ui(.base, .semibold)).foregroundStyle(palette.ink.color)
                    Text("Checked \(scan.checked) of \(scan.apps) apps with the App Store, their developers and Homebrew \(LowtideFormat.ago(scan.checkedAt)).")
                        .font(.ui(.sm)).foregroundStyle(palette.ink3.color).multilineTextAlignment(.center).frame(maxWidth: 380)
                    Button(model.checking ? "Checking…" : "Check again") { model.check(force: true) }
                        .buttonStyle(.secondary).disabled(model.checking).padding(.top, Space.xs)
                }
                .frame(maxWidth: .infinity, minHeight: 360)
            }
        } else {
            VStack(spacing: Space.xl) {
                ForEach(Group.order, id: \.self) { source in
                    let list = visible.filter { groupOf($0) == source }
                    if !list.isEmpty {
                        Pane(source.label) {
                            Text("\(list.count)").font(.ui(.xs)).monospacedDigit().foregroundStyle(palette.ink3.color)
                        } content: {
                            VStack(spacing: 0) {
                                ForEach(list) { update in
                                    UpdateRow(update: update, checked: checks.has(update.id), open: openID == update.id,
                                              targets: checks.targets(update.id).compactMap { id in model.all.first { $0.id == id } },
                                              onCheck: { checks.toggle(update.id, in: visible.map(\.id)) },
                                              onToggle: { withAnimation(Motion.base) { openID = openID == update.id ? nil : update.id } })
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// One app's update: icon, name, the version step or the install's
/// progress, its size and its own action; opens to the detail.
private struct UpdateRow: View {
    @Environment(\.palette) private var palette
    private var model = AppUpdatesModel.shared
    let update: AppUpdate
    let checked: Bool
    let open: Bool
    /// What the menu's Update acts on: the selection when checked.
    let targets: [AppUpdate]
    let onCheck: () -> Void
    let onToggle: () -> Void
    @State private var hovering = false

    init(update: AppUpdate, checked: Bool, open: Bool, targets: [AppUpdate], onCheck: @escaping () -> Void, onToggle: @escaping () -> Void) {
        self.update = update
        self.checked = checked
        self.open = open
        self.targets = targets
        self.onCheck = onCheck
        self.onToggle = onToggle
    }

    var body: some View {
        let progress = model.progress[update.id]
        VStack(spacing: 0) {
            Hairline()
            HStack(spacing: Space.md) {
                Checkbox(checked, label: "Select \(update.name)", toggle: onCheck)
                AppsIcon(path: update.id, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(update.name).font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color).lineLimit(1)
                    if let progress { ProgressLine(progress: progress) } else { AppsVersionStep(from: update.installed, to: update.available) }
                }
                Spacer(minLength: Space.sm)
                Text(update.size.map(LowtideFormat.bytes) ?? "").font(.mono(.xxs)).monospacedDigit().foregroundStyle(palette.ink3.color)
                    .frame(width: 70, alignment: .trailing)
                action(progress).frame(width: 104, alignment: .trailing)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(palette.ink4.color)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .padding(.horizontal, Space.lg)
            .frame(minHeight: 52)
            .background((hovering ? palette.hover : ColorValue(r: 0, g: 0, b: 0, a: 0)).color)
            .contentShape(.rect)
            .onTapGesture(perform: onToggle)
            .onHover { hovering = $0 }
            .contextMenu {
                Button(targets.count > 1 ? "Update \(targets.count) Apps" : "Update") { model.install(targets) }
                Button(model.isSkipped(update) ? "Don’t Skip" : "Skip This Version") { model.toggleSkip(update) }
                Divider()
                PathMenu(update.id)
            }
            if open { UpdateDetail(update: update).transition(.opacity) }
        }
    }

    /// The row's own action: update here, or hand off where it can't be.
    @ViewBuilder private func action(_ progress: AppUpdatesModel.Progress?) -> some View {
        if progress?.stage == .done {
            EmptyView()
        } else if !update.installsHere(homebrew: model.homebrew) {
            Button {
                if let page = update.homepage.flatMap(URL.init(string:)) { NSWorkspace.shared.open(page) }
            } label: {
                Label(update.method == .vendor ? "Download" : "Website", systemImage: "arrow.up.right")
            }
            .buttonStyle(.lowtide(.secondary, size: .small))
            .help(update.method == .vendor ? "This developer publishes updates on their website" : "Homebrew isn’t installed")
            .disabled(update.homepage == nil)
        } else {
            Button(update.method == .appStore ? "App Store" : "Update") { model.install([update]) }
                .buttonStyle(.lowtide(.secondary, size: .small))
                .disabled(progress?.busy == true || model.isSkipped(update))
        }
    }
}

/// Where an install is: the stage, and a bar while it runs.
private struct ProgressLine: View {
    @Environment(\.palette) private var palette
    let progress: AppUpdatesModel.Progress

    var body: some View {
        HStack(spacing: Space.sm) {
            Text(progress.label).font(.ui(.xxs))
                .foregroundStyle((progress.stage == .failed ? palette.bad : progress.stage == .done ? palette.ok : palette.ink2).color)
            if progress.busy {
                if let fraction = progress.fraction {
                    Meter(value: fraction, height: 3).frame(maxWidth: 160)
                } else {
                    ProgressView().progressViewStyle(.linear).controlSize(.mini).tint(palette.brand.color).frame(maxWidth: 160)
                }
            }
        }
    }
}

/// Opened under its row: what's new, the facts, and the quieter actions.
private struct UpdateDetail: View {
    @Environment(\.palette) private var palette
    private var model = AppUpdatesModel.shared
    let update: AppUpdate

    init(update: AppUpdate) { self.update = update }

    var body: some View {
        let progress = model.progress[update.id]
        HStack(alignment: .top, spacing: Space.xl) {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("What’s new").font(.ui(.xs, .semibold)).foregroundStyle(palette.ink2.color)
                if let notes = update.notes {
                    ScrollView {
                        Text(notes).font(.ui(.sm)).foregroundStyle(palette.ink2.color).lineSpacing(3)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 190)
                } else {
                    Text("The developer didn’t publish notes with this release.").font(.ui(.sm)).foregroundStyle(palette.ink3.color)
                }
                if let link = (update.notesURL ?? update.homepage).flatMap(URL.init(string:)) {
                    Button { NSWorkspace.shared.open(link) } label: {
                        Label(update.notesURL != nil ? "Full release notes" : "Developer’s website", systemImage: "arrow.up.right")
                    }
                    .buttonStyle(.plain).font(.ui(.xs)).foregroundStyle(palette.brand.color)
                }
                if let error = progress?.error {
                    Text(error).font(.ui(.xs)).foregroundStyle(palette.bad.color).textSelection(.enabled)
                }
                if let line = progress?.line {
                    Text(line).font(.mono(.xxs)).foregroundStyle(palette.ink3.color).lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: Space.sm) {
                VStack(spacing: 0) {
                    if let size = update.size { fact("Download", LowtideFormat.bytes(size)) }
                    if let date = released { fact("Released", date) }
                    fact("Found through", update.method.label)
                }
                Text(update.howItUpdates(homebrew: model.homebrew)).font(.ui(.xxs)).foregroundStyle(palette.ink3.color)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Button(model.isSkipped(update) ? "Don’t skip" : "Skip this version") { model.toggleSkip(update) }
                        .buttonStyle(.lowtide(.secondary, size: .small))
                    Button("Show in Finder") { Files.reveal([update.id]) }
                        .buttonStyle(.lowtide(.quiet, size: .small))
                }
            }
            .frame(width: 250, alignment: .leading)
        }
        .padding(.leading, 70)
        .padding(.trailing, Space.lg)
        .padding(.vertical, Space.lg)
        .background(palette.bg.opacity(0.5).color)
    }

    private func fact(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).foregroundStyle(palette.ink3.color)
            Spacer()
            Text(value).foregroundStyle(palette.ink.color)
        }
        .font(.ui(.xs))
        .frame(height: 24)
    }

    /// The release date in the person's style, or as the feed wrote it.
    private var released: String? {
        guard let text = update.released else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let rss = DateFormatter()
        rss.locale = Locale(identifier: "en_US_POSIX")
        rss.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let date = iso.date(from: text) ?? ISO8601DateFormatter().date(from: text) ?? rss.date(from: text)
        return date?.formatted(date: .abbreviated, time: .omitted) ?? text
    }
}
