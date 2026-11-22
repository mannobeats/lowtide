import LowtideKit
import SwiftUI

/// The last run of each snippet: one result per target, kept while the app
/// runs so the page can show how it went after the sheet closes.
@Observable
final class SnippetRunStore {
    static let shared = SnippetRunStore()

    struct Run {
        var snippetID: String
        var started: Date
        var results: [SnippetRuns.Result]
        var finished: Bool { results.allSatisfy { $0.state != .running } }
        var succeeded: Int { results.filter { $0.state == .succeeded }.count }
    }

    private(set) var runs: [String: Run] = [:]

    func run(_ id: String) -> Run? { runs[id] }

    /// Runs a snippet everywhere picked at once, without terminals; the
    /// active terminal (when picked) gets it typed in.
    func start(_ snippet: Snippet, targets: Set<SnippetTarget>) {
        let remote = RemoteStore.shared
        let resolution = remote.resolution
        let hosts = SnippetRuns.hosts(for: targets, in: resolution)
        var results: [SnippetRuns.Result] = []
        if targets.contains(.active), SessionStore.shared.typeIntoActive(snippet.content, run: true) {
            let title = SessionStore.shared.focusedSession?.tab.title ?? "Terminal"
            results.append(SnippetRuns.Result(id: "active", title: "Active terminal", subtitle: title, state: .succeeded,
                                              output: "Typed into \(title).", started: Date(), ended: Date()))
        }
        if targets.contains(.local) {
            results.append(SnippetRuns.Result(id: "local", title: "This Mac", subtitle: "Login shell", state: .running,
                                              output: "", started: Date()))
        }
        for host in hosts {
            results.append(SnippetRuns.Result(id: host.id, title: host.name, subtitle: "\(host.username)@\(host.hostname)",
                                              state: .running, output: "", started: Date()))
        }
        runs[snippet.id] = Run(snippetID: snippet.id, started: Date(), results: results)
        let running = results.filter { $0.state == .running }
        guard !running.isEmpty else { return }
        let content = snippet.content
        Jobs.shared.start("Running \(snippet.name)", page: .snippets) { job in
            job.detail = "0 of \(running.count) done"
            // Each target lands on the main actor itself rather than passing
            // a tuple through the group (in optimized builds such tuples came
            // out uninitialized; see ToolchainModel).
            let ids = Set(running.map(\.id))
            let land = { @MainActor (id: String, state: SnippetRuns.Result.State, output: String) in
                self.finish(snippet.id, target: id, state: state, output: output)
                let done = self.runs[snippet.id]?.results.filter { ids.contains($0.id) && $0.state != .running }.count ?? 0
                job.detail = "\(done) of \(running.count) done"
                job.progress = Double(done) / Double(running.count)
            }
            await withTaskGroup(of: Void.self) { group in
                for item in running {
                    if item.id == "local" {
                        group.addTask {
                            let out = await SnippetRuns.runLocally(content)
                            await land(item.id, out.state, out.output)
                        }
                    } else if let host = hosts.first(where: { $0.id == item.id }) {
                        let endpoint = resolution.endpoint(for: host)
                        let secrets = resolution.secrets(for: host)
                        let label = host.name
                        group.addTask {
                            let out = await SnippetRuns.runRemotely(content, endpoint: endpoint, secrets: secrets, label: label)
                            await land(item.id, out.state, out.output)
                        }
                    }
                }
            }
            if let run = self.runs[snippet.id] {
                let failed = run.results.count - run.succeeded
                Toasts.shared.show(failed == 0 ? "\(snippet.name) ran on \(LowtideKitFormat.count(run.results.count, "target"))"
                                               : "\(snippet.name) failed on \(LowtideKitFormat.count(failed, "target"))",
                                   tone: failed == 0 ? .ok : .warn, action: "Show") {
                    AppModel.shared.show(.snippets)
                    SnippetRun.present(snippet, showResults: true)
                }
            }
        }
    }

    private func finish(_ snippetID: String, target: String, state: SnippetRuns.Result.State, output: String) {
        guard var run = runs[snippetID], let index = run.results.firstIndex(where: { $0.id == target }) else { return }
        run.results[index].state = state
        run.results[index].output = output
        run.results[index].ended = Date()
        runs[snippetID] = run
    }
}

enum SnippetRun {
    static func present(_ snippet: Snippet, showResults: Bool = false) {
        DevSheetHost.present { close in SnippetRunSheet(snippet: snippet, showResults: showResults, close: close) }
    }
}

/// Pick where a snippet runs, then watch each target's result come in.
private struct SnippetRunSheet: View {
    @Environment(\.palette) private var palette
    private var runs = SnippetRunStore.shared
    private var remote = RemoteStore.shared
    let snippet: Snippet
    let close: () -> Void
    @State private var targets: Set<SnippetTarget> = []
    @State private var showingResults: Bool

    init(snippet: Snippet, showResults: Bool, close: @escaping () -> Void) {
        self.snippet = snippet
        self.close = close
        _showingResults = State(initialValue: showResults && SnippetRunStore.shared.run(snippet.id) != nil)
    }

    var resolution: HostResolution { remote.resolution }

    var count: Int {
        SnippetRuns.hosts(for: targets, in: resolution).count + (targets.contains(.local) ? 1 : 0)
            + (targets.contains(.active) && SessionStore.shared.activeAvailable ? 1 : 0)
    }

    var body: some View {
        DevSheet("Run “\(snippet.name)”",
                 description: showingResults ? "Each target's result as it comes in." : "Pick where it runs. Each target reports back here.",
                 width: 560) {
            Text(snippet.content)
                .font(.mono(.xs))
                .foregroundStyle(Color(nsColor: TerminalColors.current.foreground))
                .lineLimit(6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.md)
                .background(Color(nsColor: TerminalColors.current.background), in: .rect(cornerRadius: Radius.md))
            if showingResults, let run = runs.run(snippet.id) {
                SnippetResults(run: run, snippet: snippet)
            } else {
                SnippetTargetPicker(selected: $targets, includeActive: true)
            }
        } footer: {
            if showingResults {
                Button("Change targets") { showingResults = false }.buttonStyle(.quiet)
                Button("Done", action: close).buttonStyle(.primary).keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel", action: close).buttonStyle(.quiet).keyboardShortcut(.cancelAction)
                Button("Open in Tabs") { openInTabs() }
                    .buttonStyle(.secondary)
                    .disabled(count == 0)
                    .help("Run it in a terminal per target, to watch or answer prompts")
                Button {
                    SnippetRunStore.shared.start(snippet, targets: targets)
                    showingResults = true
                } label: {
                    Label("Run on \(LowtideKitFormat.count(count, "target"))", systemImage: "play.fill")
                }
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
                .disabled(count == 0)
            }
        }
        .onAppear {
            var defaults = snippet.targets
            if defaults.isEmpty { defaults.insert(SessionStore.shared.activeAvailable ? .active : .local) }
            targets = defaults
        }
    }

    /// A terminal per target, so prompts can be answered.
    private func openInTabs() {
        let store = SessionStore.shared
        if targets.contains(.active) { store.typeIntoActive(snippet.content, run: true) }
        if targets.contains(.local) { store.openLocal(title: "\(snippet.name) · Local", initialInput: snippet.content) }
        for host in SnippetRuns.hosts(for: targets, in: resolution) {
            let args = try? SSHCommand.interactive(resolution.endpoint(for: host), remoteCommand: snippet.content)
            store.openSSH(host, title: "\(snippet.name) · \(host.name)", args: args, oneShot: true)
        }
        Toasts.shared.show("Running \(snippet.name) on \(LowtideKitFormat.count(count, "target"))")
        close()
        AppModel.shared.open(.sessions)
    }
}

/// Results, one row per target, with its output a click away.
private struct SnippetResults: View {
    @Environment(\.palette) private var palette
    let run: SnippetRunStore.Run
    let snippet: Snippet

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(run.results.enumerated()), id: \.element.id) { index, result in
                if index > 0 { Hairline() }
                ResultRow(result: result, snippet: snippet)
            }
        }
        .card()
    }
}

private struct ResultRow: View {
    @Environment(\.palette) private var palette
    @State private var expanded = false
    let result: SnippetRuns.Result
    let snippet: Snippet

    var tone: Tone {
        switch result.state {
        case .running: .neutral
        case .succeeded: .ok
        case .failed, .couldNotStart: .bad
        }
    }

    var status: String {
        switch result.state {
        case .running: "Running…"
        case .succeeded: "Done"
        case .failed(let code): code.map { "Exit \($0)" } ?? "Stopped"
        case .couldNotStart(let reason): reason
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.md) {
                Group {
                    if result.state == .running {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: tone == .ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(tone.color(palette).color)
                    }
                }
                .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.title).font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color)
                    Sensitive(text: result.subtitle, font: .mono(.xxs)).foregroundStyle(palette.ink3.color).lineLimit(1)
                }
                Spacer(minLength: Space.sm)
                Text(status).font(.ui(.xs)).foregroundStyle((tone == .neutral ? palette.ink3 : tone.color(palette)).color)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 200, alignment: .trailing)
                if let duration = result.duration {
                    Text(LowtideKitFormat.duration(duration)).font(.ui(.xxs)).monospacedDigit().foregroundStyle(palette.ink4.color)
                }
                if !result.output.isEmpty {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.ink3.color)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
            }
            .padding(.horizontal, Space.lg)
            .frame(minHeight: 44)
            .contentShape(.rect)
            .onTapGesture { if !result.output.isEmpty { withAnimation(Motion.fast) { expanded.toggle() } } }
            .contextMenu {
                Button("Copy Output") {
                    Files.copy(result.output)
                }
                .disabled(result.output.isEmpty)
                if let host = RemoteStore.shared.host(result.id) {
                    Button("Open \(host.name) in a Terminal") { RemoteStore.shared.connect(host) }
                }
            }
            if expanded {
                ScrollView {
                    Text(result.output)
                        .font(.mono(.xxs))
                        .foregroundStyle(Color(nsColor: TerminalColors.current.foreground))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Space.md)
                }
                .frame(maxHeight: 220)
                .background(Color(nsColor: TerminalColors.current.background))
                .clipShape(.rect(cornerRadius: Radius.md))
                .padding(.horizontal, Space.md)
                .padding(.bottom, Space.md)
            }
        }
    }
}

/// Where a snippet runs: the active terminal, this Mac, all hosts, groups
/// (with their subgroups) and single hosts.
struct SnippetTargetPicker: View {
    @Environment(\.palette) private var palette
    @Binding var selected: Set<SnippetTarget>
    var includeActive = false
    private var remote = RemoteStore.shared

    init(selected: Binding<Set<SnippetTarget>>, includeActive: Bool = false) {
        _selected = selected
        self.includeActive = includeActive
    }

    private func toggle(_ target: SnippetTarget) {
        withAnimation(Motion.fast) { selected = SnippetRuns.toggle(target, in: selected) }
    }

    var body: some View {
        let hosts = remote.snapshot.hosts
        let resolution = remote.resolution
        VStack(alignment: .leading, spacing: Space.md) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.sm), GridItem(.flexible(), spacing: Space.sm)], spacing: Space.sm) {
                if includeActive {
                    let available = SessionStore.shared.activeAvailable
                    TargetTile("Active terminal", subtitle: available ? "Typed into the open tab" : "No terminal is open",
                               symbol: "dot.radiowaves.left.and.right", selected: selected.contains(.active), disabled: !available) {
                        toggle(.active)
                    }
                }
                TargetTile("Local computer", subtitle: "This Mac, in your login shell", symbol: "laptopcomputer",
                           selected: selected.contains(.local)) { toggle(.local) }
                TargetTile("All saved hosts", subtitle: LowtideKitFormat.count(hosts.count, "host"), symbol: "server.rack",
                           selected: selected.contains(.allHosts), disabled: hosts.isEmpty) { toggle(.allHosts) }
            }
            if !remote.snapshot.groups.isEmpty {
                section("Host groups") {
                    ForEach(remote.groupTree, id: \.group.id) { item in
                        let count = SnippetRuns.hosts(for: [.group(item.group.id)], in: resolution).count
                        TargetRow(item.group.name, meta: LowtideKitFormat.count(count, "host"), glyph: "folder",
                                  depth: item.depth, selected: selected.contains(.group(item.group.id))) {
                            toggle(.group(item.group.id))
                        }
                    }
                }
            }
            if !hosts.isEmpty {
                section("Individual hosts") {
                    ForEach(hosts) { host in
                        TargetRow(host.name, meta: "\(host.username)@\(host.hostname)", glyph: "server.rack", depth: 0,
                                  selected: selected.contains(.host(host.id))) { toggle(.host(host.id)) }
                    }
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            GroupHeading(title)
            VStack(spacing: 0) { content() }.card()
        }
    }
}

private struct TargetTile: View {
    @Environment(\.palette) private var palette
    @State private var hovering = false
    let title: String
    let subtitle: String
    let symbol: String
    let selected: Bool
    var disabled = false
    let action: () -> Void

    init(_ title: String, subtitle: String, symbol: String, selected: Bool, disabled: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.selected = selected
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Space.sm) {
                    Image(systemName: symbol).font(.system(size: 13)).foregroundStyle((selected ? palette.brand : palette.ink2).color)
                    Text(title).font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color)
                    Spacer(minLength: 0)
                    if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(palette.brand.color) }
                }
                Text(subtitle).font(.ui(.xs)).foregroundStyle(palette.ink3.color).lineLimit(1)
            }
            .padding(Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((selected ? palette.brandSoft : hovering ? palette.hover : palette.fill).color, in: .rect(cornerRadius: Radius.lg))
            .overlay(RoundedRectangle(cornerRadius: Radius.lg).strokeBorder((selected ? palette.brand.opacity(0.5) : palette.line).color))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct TargetRow: View {
    @Environment(\.palette) private var palette
    @State private var hovering = false
    let title: String
    let meta: String
    let glyph: String
    let depth: Int
    let selected: Bool
    let action: () -> Void

    init(_ title: String, meta: String, glyph: String, depth: Int, selected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.meta = meta
        self.glyph = glyph
        self.depth = depth
        self.selected = selected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.sm) {
                Image(systemName: glyph).font(.system(size: 12)).foregroundStyle((selected ? palette.brand : palette.ink2).color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.ui(.sm)).foregroundStyle(palette.ink.color).lineLimit(1)
                    Sensitive(text: meta, font: .mono(.xxs)).foregroundStyle(palette.ink3.color).lineLimit(1)
                }
                Spacer(minLength: Space.sm)
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle((selected ? palette.brand : palette.ink4).color)
            }
            .padding(.leading, Space.md + CGFloat(depth) * Space.lg)
            .padding(.trailing, Space.md)
            .frame(height: 44)
            .background((selected ? palette.brandSoft.opacity(0.5) : hovering ? palette.hover : ColorValue(r: 0, g: 0, b: 0, a: 0)).color)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
