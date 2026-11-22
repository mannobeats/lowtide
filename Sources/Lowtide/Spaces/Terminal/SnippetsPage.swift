import LowtideKit
import SwiftUI

/// Developer › Snippets: saved commands, run on any host or terminal.
struct SnippetsPage: View {
    @Environment(\.palette) private var palette
    private var remote = RemoteStore.shared
    private var runs = SnippetRunStore.shared
    @State private var editing: SnippetDraft?
    @State private var confirm: ConfirmRequest?
    @State private var filter = ""
    @State private var selection: String?

    var snippets: [Snippet] {
        let all = remote.snapshot.snippets
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { "\($0.name) \($0.content) \($0.tags ?? "")".lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("Snippets", description: remote.snapshot.snippets.isEmpty ? nil
                       : LowtideKitFormat.count(remote.snapshot.snippets.count, "snippet")) {
                EmptyView()
            } action: {
                if remote.snapshot.snippets.count > 6 { FilterField(text: $filter, prompt: "Filter snippets") }
                Button { editing = SnippetDraft() } label: { Label("New snippet", systemImage: "plus") }
                    .buttonStyle(.primary)
            }
            content
        }
        .task { await remote.load() }
        .sheet(item: $editing) { draft in SnippetEditor(draft: draft) { editing = nil } }
        .confirmation($confirm)
    }

    @ViewBuilder private var content: some View {
        if !remote.loaded {
            ScanningState(title: "Loading snippets")
        } else if let error = remote.error {
            ErrorState(message: error) { Task { await remote.load() } }
        } else if remote.snapshot.snippets.isEmpty {
            VStack(spacing: Space.lg) {
                HeroArt("empty", size: 80)
                EmptyState("No snippets yet", symbol: "doc.text",
                           message: "Save the shell commands you keep retyping, then run them on any host.") {
                    Button("Add your first snippet") { editing = SnippetDraft() }.buttonStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    let list = snippets
                    if list.isEmpty {
                        Text("No snippet matches “\(filter)”.").font(.ui(.sm)).foregroundStyle(palette.ink3.color)
                            .frame(maxWidth: .infinity).padding(Space.xl)
                    }
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, snippet in
                        if index > 0 { Hairline(inset: 60) }
                        SnippetRow(snippet: snippet, selected: selection == snippet.id, lastRun: runs.run(snippet.id),
                                   onSelect: { selection = snippet.id },
                                   onEdit: { editing = SnippetDraft(snippet) },
                                   onDelete: { ask(delete: snippet) })
                    }
                }
                .card()
                .padding(.horizontal, Space.page + 4)
                .padding(.bottom, Space.page * 2)
                .frame(maxWidth: 1180)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
            .onDeleteCommand { if let snippet = remote.snapshot.snippets.first(where: { $0.id == selection }) { ask(delete: snippet) } }
            .onKeyPress(.return) {
                guard let snippet = remote.snapshot.snippets.first(where: { $0.id == selection }) else { return .ignored }
                SnippetRun.present(snippet)
                return .handled
            }
        }
    }

    private func ask(delete snippet: Snippet) {
        confirm = ConfirmRequest(title: "Delete snippet?", message: "Delete “\(snippet.name)” and its saved targets?",
                                 confirm: "Delete Snippet") {
            Task { await RemoteStore.shared.delete(snippet) }
        }
    }
}

private struct SnippetRow: View {
    @Environment(\.palette) private var palette
    @State private var hovering = false
    let snippet: Snippet
    let selected: Bool
    let lastRun: SnippetRunStore.Run?
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var summary: String { SnippetRuns.summary(snippet.targets, in: RemoteStore.shared.resolution) }

    var body: some View {
        HStack(spacing: Space.md) {
            DevGlyphTile("snippets")
            VStack(alignment: .leading, spacing: 2) {
                Text(snippet.name).font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color).lineLimit(1)
                Text(snippet.content.split(separator: "\n").first.map(String.init) ?? "")
                    .font(.mono(.xxs)).foregroundStyle(palette.ink3.color).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: Space.md)
            if hovering || selected {
                HStack(spacing: Space.xs) {
                    Button { SnippetRun.present(snippet) } label: { Label("Run…", systemImage: "play.fill") }
                        .buttonStyle(.lowtide(.secondary, size: .small))
                    IconButton("trash", help: "Delete", action: onDelete)
                }
                .transition(.opacity)
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(summary).font(.ui(.xs)).foregroundStyle(palette.ink3.color).lineLimit(1)
                    if let lastRun { lastRunLine(lastRun) }
                }
                .frame(maxWidth: 220, alignment: .trailing)
            }
        }
        .padding(.horizontal, Space.lg)
        .frame(minHeight: 52)
        .background((selected ? palette.selected : hovering ? palette.hover : ColorValue(r: 0, g: 0, b: 0, a: 0)).color)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .animation(Motion.fast, value: hovering)
        .onTapGesture(count: 2, perform: onEdit)
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button("Run…") { SnippetRun.present(snippet) }
            if lastRun != nil { Button("Show Last Results") { SnippetRun.present(snippet, showResults: true) } }
            Button("Insert Without Running") { insert() }
            Button("Edit…", action: onEdit)
            Button("Copy Command") {
                Files.copy(snippet.content)
            }
            Divider()
            Button("Delete…", role: .destructive, action: onDelete)
        }
    }

    private func lastRunLine(_ run: SnippetRunStore.Run) -> some View {
        let failed = run.results.count - run.succeeded
        let text = !run.finished ? "Running…"
            : failed == 0 ? "Last run: all \(run.results.count) succeeded" : "Last run: \(failed) of \(run.results.count) failed"
        return Button { SnippetRun.present(snippet, showResults: true) } label: {
            Text(text).font(.ui(.xxs)).foregroundStyle((failed > 0 && run.finished ? palette.warn : palette.ink4).color)
        }
        .buttonStyle(.plain)
        .help("Show the results")
    }

    private func insert() {
        if SessionStore.shared.typeIntoActive(snippet.content, run: false) {
            AppModel.shared.open(.sessions)
            Toasts.shared.show("Inserted \(snippet.name)")
        } else {
            Toasts.shared.show("Open a terminal tab first", tone: .warn, action: "New Terminal") { TerminalActions.newTerminal() }
        }
    }
}

/// A snippet being written.
struct SnippetDraft: Identifiable {
    var id = UUID()
    var snippet: Snippet?
    var name = ""
    var tags = ""
    var content = ""
    var targets: Set<SnippetTarget> = []

    init(_ snippet: Snippet? = nil) {
        self.snippet = snippet
        name = snippet?.name ?? ""
        tags = snippet?.tags ?? ""
        content = snippet?.content ?? ""
        targets = snippet?.targets ?? []
    }
}

private struct SnippetEditor: View {
    @Environment(\.palette) private var palette
    @State var draft: SnippetDraft
    @State private var saving = false
    let close: () -> Void

    var valid: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty && !draft.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        DevSheet(draft.snippet == nil ? "New snippet" : "Edit snippet",
                 description: "Saved on this Mac. Run it on any host or open terminal.", width: 560) {
            DevField("Name") {
                TextField("Tail the nginx access log", text: $draft.name).devField()
            }
            DevField("Tags", hint: "Separate tags with commas.") {
                TextField("nginx, prod", text: $draft.tags).devField()
            }
            DevField("Command", hint: "Sent exactly as written. Running it always asks where.") {
                TextEditor(text: $draft.content)
                    .font(.mono(.xs))
                    .scrollContentBackground(.hidden)
                    .padding(Space.sm)
                    .frame(height: 160)
                    .background(palette.fill.color, in: .rect(cornerRadius: Radius.md))
                    .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(palette.line.color))
            }
            DevField("Run on", hint: "Picked for you each time you run it. You can change them before it runs.") {
                SnippetTargetPicker(selected: $draft.targets)
            }
        } footer: {
            Button("Cancel", action: close).buttonStyle(.quiet).keyboardShortcut(.cancelAction)
            Button("Save snippet", action: save).buttonStyle(.primary).keyboardShortcut(.defaultAction)
                .disabled(!valid || saving)
        }
    }

    private func save() {
        saving = true
        var snippet = draft.snippet ?? Snippet(name: "", content: "")
        snippet.name = draft.name.trimmingCharacters(in: .whitespaces)
        snippet.content = draft.content
        let tags = draft.tags.trimmingCharacters(in: .whitespaces)
        snippet.tags = tags.isEmpty ? nil : tags
        snippet.targets = draft.targets.filter { $0 != .active }
        Task {
            if await RemoteStore.shared.save(snippet) {
                Toasts.shared.show("Saved \(snippet.name)")
                close()
            }
            saving = false
        }
    }
}
