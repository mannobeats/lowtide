import LowtideKit
import SwiftUI

/// Runs on the left as a timeline, the selected one written up on the
/// right. Install watch shows installs only (with tool and folder filters);
/// History shows every command and leads to Install watch for installs.
struct RunsBrowser<Intro: View>: View {
    enum Show: String, Hashable { case all, installs, flagged }

    @Environment(\.palette) private var palette
    @AppStorage private var show: Show
    @State private var query = ""
    @State private var tool = ""
    @State private var folder = ""
    @State private var picked: UInt64?
    let runs: [Run]
    let active: [ActiveRun]
    var installsOnly = false
    let emptyTitle: String
    let emptyMessage: String
    @ViewBuilder var intro: Intro

    init(runs: [Run], active: [ActiveRun], installsOnly: Bool = false, emptyTitle: String, emptyMessage: String,
         @ViewBuilder intro: () -> Intro) {
        self.runs = runs
        self.active = active
        self.installsOnly = installsOnly
        self.emptyTitle = emptyTitle
        self.emptyMessage = emptyMessage
        self.intro = intro()
        // Each browser keeps its own view (All or Flagged).
        _show = AppStorage(wrappedValue: .all, installsOnly ? "installwatch.show" : "history.show")
    }

    private func matches(_ run: Run, show: Show, needle: String) -> Bool {
        if show == .installs, run.ecosystem == nil { return false }
        if show == .flagged, run.verdict == .info { return false }
        if !tool.isEmpty, RunWords.manager(run) != tool { return false }
        if !folder.isEmpty, run.cwd != folder { return false }
        return needle.isEmpty || run.command.lowercased().contains(needle)
    }

    var body: some View {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = runs.filter { matches($0, show: show, needle: needle) }
        let selected = shown.first { $0.id == picked } ?? shown.first
        if runs.isEmpty, active.isEmpty {
            ScrollView {
                VStack(spacing: Space.lg) {
                    EmptyState(emptyTitle, symbol: "clock.arrow.circlepath", message: emptyMessage)
                        .frame(minHeight: 260)
                    intro.frame(maxWidth: 560)
                }
                .padding(.horizontal, Space.page + 4)
                .padding(.bottom, Space.xxl)
                .frame(maxWidth: .infinity)
            }
            .overlay(alignment: .top) { Hairline() }
        } else {
            HSplitView {
                VStack(spacing: 0) {
                    filters
                    Hairline()
                    timeline(shown, selected: selected?.id)
                }
                .frame(minWidth: 250, idealWidth: 330, maxWidth: 460)
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.xl) {
                        Following(active: active)
                        if let selected {
                            RunDetail(run: selected, runs: runs).id(selected.id)
                        }
                        intro
                    }
                    .padding(Space.page)
                    .frame(maxWidth: 900, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minWidth: 380, maxWidth: .infinity)
            }
            .overlay(alignment: .top) { Hairline() }
            .onAppear {
                RunsStore.shared.watch()
                takeFocus()
            }
            .onChange(of: RunsStore.shared.focus) { takeFocus() }
            .onDisappear { RunsStore.shared.unwatch() }
        }
    }

    /// Selects the run something asked to show, clearing filters that hide it.
    private func takeFocus() {
        guard let id = RunsStore.shared.focus, runs.contains(where: { $0.id == id }) else { return }
        RunsStore.shared.focus = nil
        (query, tool, folder, show) = ("", "", "", .all)
        picked = id
    }

    private func count(_ value: Show) -> Int { runs.filter { matches($0, show: value, needle: "") }.count }

    private var filters: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            FilterField(text: $query, prompt: "Filter commands")
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: Space.xs) {
                Segmented($show, installsOnly ? [(.all, "All"), (.flagged, "Flagged")] : [(.all, "All"), (.flagged, "Flagged")],
                          counts: [.all: count(.all), .flagged: count(.flagged)])
                if !installsOnly {
                    Button {
                        AppModel.shared.open(.installWatch)
                    } label: {
                        HStack(spacing: 5) {
                            NavIcon("install-watch", size: 13)
                            Text("Installs")
                            Text(count(.installs).formatted()).monospacedDigit().foregroundStyle(palette.ink4.color)
                        }
                    }
                    .buttonStyle(.lowtide(.quiet, size: .small))
                    .help("Installs are followed in Protection → Install watch")
                }
            }
            if installsOnly { installFilters }
        }
        .padding(Space.md)
    }

    /// Each value with how many runs have it, most first.
    private func tally(_ values: [String]) -> [(String, Int)] {
        Dictionary(values.map { ($0, 1) }, uniquingKeysWith: +).sorted { ($1.1, $0.0) < ($0.1, $1.0) }
    }

    /// Which tool, which project folder. Shown only when there is more
    /// than one to choose from.
    @ViewBuilder private var installFilters: some View {
        let tools = tally(runs.map(RunWords.manager))
        let folders = tally(runs.compactMap(\.cwd))
        if tools.count > 1 || folders.count > 1 {
            HStack(spacing: Space.sm) {
                if tools.count > 1 {
                    Picker("Tool", selection: $tool) {
                        Text("Any tool").tag("")
                        ForEach(tools, id: \.0) { Text("\($0.0) (\($0.1))").tag($0.0) }
                    }
                }
                if folders.count > 1 {
                    Picker("Folder", selection: $folder) {
                        Text("Any folder").tag("")
                        ForEach(folders, id: \.0) { Text("\($0.0) (\($0.1))").tag($0.0) }
                    }
                }
            }
            .labelsHidden()
            .controlSize(.small)
        }
    }

    /// Runs grouped by day, newest first as they arrive.
    private func timeline(_ shown: [Run], selected: UInt64?) -> some View {
        let days = Self.days(shown)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(days, id: \.0) { day, list in
                        Section {
                            ForEach(list) { run in
                                RunRow(run: run, selected: run.id == selected) { picked = run.id }
                                    .id(run.id)
                            }
                        } header: {
                            Text(day).font(.ui(.xs, .semibold)).foregroundStyle(palette.ink3.color)
                                .padding(.horizontal, Space.md).padding(.top, Space.md).padding(.bottom, Space.xs)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(palette.bg.color)
                        }
                    }
                }
                .padding(.horizontal, Space.sm)
                .padding(.bottom, Space.sm)
                if shown.isEmpty {
                    EmptyState("Nothing matches", symbol: "line.3.horizontal.decrease", message: "Try another filter or search.")
                        .frame(minHeight: 200)
                }
            }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { move(1, in: shown, from: selected, proxy: proxy) }
            .onKeyPress(.upArrow) { move(-1, in: shown, from: selected, proxy: proxy) }
        }
    }

    private func move(_ step: Int, in shown: [Run], from selected: UInt64?, proxy: ScrollViewProxy) -> KeyPress.Result {
        guard let index = shown.firstIndex(where: { $0.id == selected }) else { return .ignored }
        let next = min(max(index + step, 0), shown.count - 1)
        picked = shown[next].id
        proxy.scrollTo(shown[next].id)
        return .handled
    }

    /// "Today", "Yesterday", then "Mon 3 Nov": the timeline's day headings.
    static func days(_ runs: [Run]) -> [(String, [Run])] {
        let calendar = Calendar.current
        var days: [(String, [Run])] = []
        for run in runs {
            let date = run.startedAt
            let day = calendar.isDateInToday(date) ? "Today" : calendar.isDateInYesterday(date) ? "Yesterday"
                : date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            if days.last?.0 == day { days[days.count - 1].1.append(run) } else { days.append((day, [run])) }
        }
        return days
    }
}

private struct RunRow: View {
    @Environment(\.palette) private var palette
    @State private var hovering = false
    let run: Run
    let selected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: Space.sm + 2) {
                VerdictDot(severity: run.verdict).padding(.top, 6).accessibilityLabel(RunWords.verdictLabel(run))
                VStack(alignment: .leading, spacing: 1) {
                    Text(RunWords.shortCommand(run.command)).font(.mono(.xs)).foregroundStyle(palette.ink.color).lineLimit(1)
                    Text(RunWords.receiptParts(run).joined(separator: " · ")).font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                        .lineLimit(1)
                }
                Spacer(minLength: Space.xs)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(run.startedAt.timeOfDay)
                    Text(RunWords.duration(run.took))
                }
                .font(.ui(.xs)).monospacedDigit().foregroundStyle(palette.ink4.color)
            }
            .padding(.horizontal, Space.sm + 2)
            .padding(.vertical, Space.sm)
            .background((selected ? palette.selected : hovering ? palette.hover : ColorValue(r: 0, g: 0, b: 0, a: 0)).color,
                        in: .rect(cornerRadius: Radius.md))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button("Copy Command") { FileActions.copy(run.command, what: "Command") }
            if let cwd = run.cwd { Button("Show Folder in Finder") { FileActions.reveal(cwd) } }
        }
    }
}

/// Commands being followed right now.
private struct Following: View {
    @Environment(\.palette) private var palette
    let active: [ActiveRun]

    var body: some View {
        if !active.isEmpty {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("Following now").font(.ui(.xs, .semibold)).foregroundStyle(palette.ink2.color)
                    ForEach(active) { run in
                        HStack(spacing: Space.sm + 2) {
                            ProgressView().controlSize(.mini)
                            Text(RunWords.shortCommand(run.command)).font(.mono(.xs)).foregroundStyle(palette.ink.color)
                                .lineLimit(1)
                            Spacer(minLength: Space.sm)
                            let elapsed = UInt64(max(context.date.timeIntervalSince1970 * 1000 - Double(run.started), 0))
                            Text("\(RunWords.duration(elapsed)) · \(LowtideFormat.count(run.dests, "host")) · \(LowtideFormat.count(run.files, "file"))")
                                .font(.ui(.xs)).monospacedDigit().foregroundStyle(palette.ink3.color)
                        }
                    }
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.md)
                .background(palette.brandSoft.color, in: .rect(cornerRadius: Radius.lg))
            }
        }
    }
}
