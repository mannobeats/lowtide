import AppKit
import LowtideKit
import SwiftUI
import UniformTypeIdentifiers

/// This Mac's recipe, collected once per launch (again on request), one
/// section at a time; and another Mac's, to compare with.
@Observable
final class RecipeModel {
    static let shared = RecipeModel()
    /// Types a command into a new terminal tab of Lowtide (the Terminal
    /// space wires it); without it the setup script opens in Terminal.app.
    static var runInTerminal: ((String) -> Void)?

    struct Row: Identifiable {
        var id: String
        var label: String
        /// Nil while the section is still being collected.
        var items: [RecipeItem]?
        var error: String?
    }

    private(set) var rows: [Row]?
    private(set) var recipe: MacRecipe?
    private(set) var collecting = false
    var other: MacRecipe?
    var busy: String?

    func collect() {
        guard !collecting else { return }
        collecting = true
        rows = nil
        Task {
            for await event in RecipeCollector.collect() {
                withAnimation(Motion.base) {
                    switch event {
                    case .planned(let sections):
                        rows = sections.map { Row(id: $0.id, label: $0.label) }
                    case .done(let section):
                        update(section.id) { $0.items = section.items }
                    case .failed(let id, let error):
                        update(id) { $0.error = error }
                    case .finished(var recipe):
                        recipe.settings = Self.settings()
                        self.recipe = recipe
                        // The hosts and settings sections, after what was collected.
                        let extra = recipe.allSections.dropFirst(recipe.sections.count).map { Row(id: $0.id, label: $0.label, items: $0.items) }
                        rows = (rows ?? []) + extra
                    }
                }
            }
            collecting = false
        }
    }

    private func update(_ id: String, _ change: (inout Row) -> Void) {
        guard let index = rows?.firstIndex(where: { $0.id == id }) else { return }
        change(&rows![index])
    }

    /// Lowtide's own look: the theme, and themes the person imported.
    static func settings() -> RecipeSettings {
        let bundled: Set<String> = ["situation", "paper", "graphite", "arctic", "amber", "crimson", "phosphor"]
        let store = ThemeStore.shared
        return RecipeSettings(themeId: store.choice,
                              customThemes: store.themes.filter { !bundled.contains($0.id) }.map { .init(id: $0.id, name: $0.name) })
    }

    var itemCount: Int { (rows ?? []).reduce(0) { $0 + ($1.items?.count ?? 0) } }

    // MARK: Actions

    func copyScript() {
        guard let recipe else { return }
        ToolClipboard.copy(recipe.script(), what: "Setup script")
    }

    func export() {
        guard let recipe else { return }
        let panel = NSSavePanel()
        panel.title = "Save the Mac recipe"
        panel.nameFieldStringValue = MacRecipe.fileName(recipe.machine.name)
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if !url.lastPathComponent.hasSuffix(MacRecipe.fileExtension) {
            url = url.deletingPathExtension().appendingPathExtension("lowtide-recipe.json")
        }
        do {
            try recipe.encoded().write(to: url, options: .atomic)
            Toasts.shared.show("Recipe saved", detail: Paths.tilde(url.path), action: "Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } catch {
            Toasts.shared.failure("Couldn't save the recipe", error)
        }
    }

    func compare() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Mac recipe"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let opened = try MacRecipe.decode(try Data(contentsOf: url))
            withAnimation(Motion.base) { other = opened }
        } catch {
            Toasts.shared.failure("Couldn't open \(url.lastPathComponent)", error)
        }
    }

    /// Writes a setup script for what the other Mac has and this one lacks,
    /// and runs it in a terminal, where its output and prompts belong.
    func installMissing(_ ids: Set<String>) {
        guard let other else { return }
        let script = other.script(only: ids)
        let url = Paths.cache.appending(path: "recipe-setup.command")
        do {
            try Data(script.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            if let run = Self.runInTerminal { return run(Admin.quote(url.path)) }
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                throw LowtideError.notFound("Terminal")
            }
            NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        } catch {
            Toasts.shared.failure("Couldn't start the setup", error)
        }
    }
}

/// Developer › Toolchain › Mac recipe: everything this Mac runs, as a file
/// to keep or a script that sets up another Mac; and how another Mac's
/// recipe differs.
struct RecipePage: View {
    @Environment(\.palette) private var palette
    private var model = RecipeModel.shared
    @State private var confirm: ConfirmRequest?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("Mac recipe", description: description) {
                EmptyView()
            } action: {
                IconButton("arrow.clockwise", help: "Collect again") { model.collect() }.disabled(model.collecting)
                Button("Compare With…", systemImage: "arrow.left.arrow.right") { model.compare() }
                    .buttonStyle(.secondary).disabled(model.recipe == nil || model.collecting).fixedSize()
                Button("Copy Setup Script", systemImage: "doc.on.doc") { model.copyScript() }
                    .buttonStyle(.secondary).disabled(model.recipe == nil || model.collecting).fixedSize()
                Button("Export Recipe", systemImage: "square.and.arrow.up") { model.export() }
                    .buttonStyle(.primary).disabled(model.recipe == nil || model.collecting).fixedSize()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    if let other = model.other, let recipe = model.recipe {
                        DiffView(here: recipe, other: other) { ids in
                            confirm = ConfirmRequest(
                                title: "Install \(LowtideFormat.count(ids.count, "missing item"))?",
                                message: "Terminal opens and runs the setup script for what \(other.machine.name) has and this Mac doesn't. Anything already installed is skipped.",
                                confirm: "Open in Terminal", destructive: false) { model.installMissing(ids) }
                        }
                    } else if let rows = model.rows {
                        Pane("This Mac", subtitle: "\(LowtideFormat.count(rows.count, "section")) · \(LowtideFormat.count(model.itemCount, "item"))") {
                            // Sections with nothing in them read as one line, not a list of zeros.
                            let empty = rows.filter { $0.items?.isEmpty == true && $0.error == nil }
                            VStack(spacing: 0) {
                                ForEach(rows.filter { row in !empty.contains { $0.id == row.id } }) { row in
                                    Hairline()
                                    SectionRow(row: row)
                                }
                                if !empty.isEmpty {
                                    Hairline()
                                    Text("Nothing in \(ToolchainPage.list(empty.map(\.label), limit: 6))")
                                        .font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, Space.lg).frame(height: 36)
                                }
                            }
                        }
                    } else {
                        ScanningState(title: "Collecting this Mac's recipe").frame(height: 320)
                    }
                }
                .padding(.horizontal, Space.page + 4)
                .padding(.top, Space.xs)
                .padding(.bottom, Space.xxl)
            }
        }
        .onAppear { if model.rows == nil, !model.collecting { model.collect() } }
        .confirmation($confirm)
    }

    private var description: String? {
        guard let recipe = model.recipe else { return model.collecting ? "Collecting this Mac's recipe…" : nil }
        let suffix = model.collecting ? "collecting again…" : "collected \(LowtideFormat.ago(recipe.created))"
        return "\(recipe.machine.name) · \(recipe.machine.os) · \(recipe.machine.arch) · \(suffix)"
    }
}

private struct SectionRow: View {
    @Environment(\.palette) private var palette
    let row: RecipeModel.Row
    @State private var open = false

    var body: some View {
        VStack(spacing: 0) {
            Button { if row.items != nil { open.toggle() } } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.ink4.color)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .opacity(row.items == nil ? 0 : 1)
                    Text(row.label).font(.ui(.sm)).foregroundStyle(palette.ink.color)
                    Spacer()
                    meta
                }
                .padding(.horizontal, Space.lg)
                .frame(height: 40)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .toolRowHover()
            .accessibilityAddTraits(open ? .isSelected : [])
            if open, let items = row.items { grid(items) }
        }
        .animation(Motion.base, value: open)
    }

    @ViewBuilder
    private var meta: some View {
        if let error = row.error {
            Text("Failed").font(.ui(.xs)).foregroundStyle(palette.bad.color).help(error)
        } else if let items = row.items {
            Text(items.count.formatted()).font(.ui(.xs)).foregroundStyle(palette.ink3.color).monospacedDigit()
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Collecting…").font(.ui(.xs)).foregroundStyle(palette.brand.color)
            }
        }
    }

    @ViewBuilder
    private func grid(_ items: [RecipeItem]) -> some View {
        if items.isEmpty {
            Text("Nothing installed").font(.ui(.xs)).foregroundStyle(palette.ink4.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 40).padding(.bottom, Space.md)
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.xl), count: 3), spacing: 0) {
                ForEach(items) { item in
                    HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                        Text(item.name).font(.ui(.xs)).foregroundStyle(palette.ink2.color).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: Space.xs)
                        if let version = item.version {
                            // SSH hosts carry user names and addresses.
                            Group {
                                if row.id == "ssh-hosts" { Sensitive(text: version, font: .mono(.xxs)) } else { Text(version).font(.mono(.xxs)) }
                            }
                            .foregroundStyle(palette.ink4.color).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: 110, alignment: .trailing)
                        }
                    }
                    .frame(height: 24)
                    .hairline(.bottom)
                    .help(item.version.map { "\(item.name) \($0)" } ?? item.name)
                    .textSelection(.enabled)
                }
            }
            .padding(.leading, 40).padding(.trailing, Space.lg).padding(.bottom, Space.md)
            .transition(.opacity)
        }
    }
}

/// How another Mac's recipe differs: what's missing here, different
/// versions, and what only this Mac has.
private struct DiffView: View {
    @Environment(\.palette) private var palette
    let here: MacRecipe
    let other: MacRecipe
    let install: (Set<String>) -> Void

    var body: some View {
        let diffs = here.diff(other)
        let missing = diffs.reduce(0) { $0 + $1.missing.count }
        let onlyHere = diffs.reduce(0) { $0 + $1.onlyHere.count }
        let changed = diffs.reduce(0) { $0 + $1.changed.count }
        VStack(alignment: .leading, spacing: Space.xl) {
            HStack(spacing: Space.md) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("Compared with \(other.machine.name)").font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color)
                        Text("· \(other.machine.os) · collected \(LowtideFormat.ago(other.created))").font(.ui(.sm)).foregroundStyle(palette.ink3.color)
                    }
                    .lineLimit(1)
                    Text("\(missing) missing here · \(onlyHere) only here · \(LowtideFormat.count(changed, "different version"))")
                        .font(.ui(.xs)).foregroundStyle(palette.ink3.color).monospacedDigit()
                }
                Spacer()
                Button("Install Missing", systemImage: "terminal") {
                    install(Set(diffs.flatMap { $0.missing.map(\.id) }))
                }
                .buttonStyle(.primary)
                .disabled(missing == 0)
                IconButton("xmark", help: "Stop comparing") { withAnimation(Motion.base) { RecipeModel.shared.other = nil } }
            }
            .padding(.horizontal, Space.lg).padding(.vertical, Space.md)
            .card()
            if diffs.isEmpty {
                Text("Both Macs run the same things.").font(.ui(.sm)).foregroundStyle(palette.ink3.color)
            }
            ForEach(diffs) { diff in
                Pane(diff.label, subtitle: [diff.missing.isEmpty ? nil : "\(diff.missing.count) missing",
                                            diff.onlyHere.isEmpty ? nil : "\(diff.onlyHere.count) only here",
                                            diff.changed.isEmpty ? nil : "\(diff.changed.count) different"]
                    .compactMap { $0 }.joined(separator: " · ")) {
                    VStack(spacing: 0) {
                        ForEach(diff.missing) { item in line("Missing here", .warn, item.name, item.version) }
                        ForEach(diff.changed, id: \.item.id) { change in
                            line("Different", .neutral, change.item.name, "\(change.here) here, \(change.item.version ?? "") there")
                        }
                        ForEach(diff.onlyHere) { item in line("Only here", nil, item.name, item.version) }
                    }
                }
            }
        }
    }

    private func line(_ what: String, _ tone: Tone?, _ name: String, _ versions: String?) -> some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(spacing: Space.md) {
                Text(what).font(.ui(.xs))
                    .foregroundStyle((tone == .warn ? palette.warn : tone == .neutral ? palette.ink2 : palette.ink4).color)
                    .frame(width: 112, alignment: .leading)
                Text(name).font(.ui(.sm)).foregroundStyle(palette.ink.color).lineLimit(1)
                Spacer()
                if let versions {
                    Group {
                        if versions.contains("@") { Sensitive(text: versions) } else { Text(versions).font(.mono(.xs)) }
                    }
                    .foregroundStyle(palette.ink3.color).lineLimit(1)
                }
            }
            .padding(.horizontal, Space.lg)
            .frame(height: 36)
            .textSelection(.enabled)
        }
    }
}
