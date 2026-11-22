import AppKit
import Carbon.HIToolbox
import LowtideKit
import SwiftUI

/// The command bar's settings, shared by the floating bar, ⌘K and the
/// Command bar page; saved as they change.
@Observable
final class BarSettings {
    static let shared = BarSettings()

    var prefs = BarPrefs.load() {
        didSet {
            guard prefs != oldValue else { return }
            prefs.save()
            if prefs.hotkey != oldValue.hotkey || prefs.hotkeyEnabled != oldValue.hotkeyEnabled { CommandBarPanel.shared.applyHotkey() }
            if prefs.glass != oldValue.glass { CommandBarPanel.shared.applyGlass() }
        }
    }

    /// What it learned you pick after typing what. Memory only.
    var habits = BarHabits()
}

/// One search everywhere: the floating command bar and ⌘K are this model
/// over the same rows, and Ask is a mode of it.
@Observable
final class CommandBarModel {
    enum Host { case panel, window }

    enum Mode {
        case search
        case actions(BarRow, index: Int)
        case confirm(BarRow, action: BarRowAction?, argument: Int?)
        case number(BarRow, saved: String)
        case slider(BarRow, level: Int, saved: String)
        case naming(BarRow, saved: String, warning: String?)
        case ask

        var isSearch: Bool { if case .search = self { true } else { false } }
        var isActions: Bool { if case .actions = self { true } else { false } }
        var isAsk: Bool { if case .ask = self { true } else { false } }
        /// The row the mode belongs to, shown as the field's chip.
        var chipRow: BarRow? {
            switch self {
            case .number(let row, _), .slider(let row, _, _), .naming(let row, _, _): row
            default: nil
            }
        }
    }

    let host: Host
    /// Puts the bar away: the panel orders out, ⌘K closes.
    var onHide: () -> Void = {}

    private(set) var query = ""
    private(set) var category: BarCategory?
    var mode: Mode = .search {
        didSet { recompute() }
    }
    private(set) var list = BarResults()
    private(set) var selectedIndex = 0
    private var selectedID: String?
    /// False while the pointer drives the selection: the list then stays put.
    private(set) var follow = true
    var message: String?
    /// The view lifts in a touch each time this changes.
    private(set) var openCount = 0
    /// Focus goes back to the field each time this changes.
    private(set) var focusToken = 0
    private(set) var chips: [BarCategory] = []
    private(set) var split: (text: String, argument: Int?) = ("", nil)

    private var typed: String?
    private var lastPointer: NSPoint?
    /// What Space turns a slider back on to, after it was turned off.
    private var resume = 100
    /// Where the next opening lands (the Colors view after a pick).
    var pendingCategory: BarCategory?
    private var baseRows: [String: [BarRow]] = [:]
    /// The emoji rows (about two thousand) and what they were built from.
    private var emojiRows: [BarRow] = []
    private var emojiShape: (Int, SkinTone) = (-1, .none)
    private var baseVersion = -1
    private var files: [FileSearch.Hit] = []
    private var fileTask: Task<Void, Never>?
    private var scriptOutput: String?
    private var scriptTask: Task<Void, Never>?
    private var scriptKey = ""

    let settings = BarSettings.shared
    let data = BarData.shared
    let conversation = AskConversation.shared

    init(host: Host) { self.host = host }

    var prefs: BarPrefs {
        get { settings.prefs }
        set { settings.prefs = newValue }
    }

    var selected: BarRow? { list.rows.indices.contains(selectedIndex) ? list.rows[selectedIndex] : nil }

    /// On screen (⌘K is whenever it exists).
    var showing: Bool { host == .window || CommandBarPanel.shared.isOpen }

    /// The compact bar, empty: only the field shows.
    var collapsed: Bool { prefs.compact && query.isEmpty && category == nil && mode.isSearch }

    // MARK: Opening and closing

    /// Fresh state at once from what's already loaded; fresh data right
    /// after the bar is on screen, so opening never waits for it.
    func opened(ask: Bool = false, question: String? = nil) {
        reset()
        if let pendingCategory {
            category = pendingCategory
            self.pendingCategory = nil
        }
        DispatchQueue.main.async { [data] in data.refresh() }
        openCount += 1
        if ask { enterAsk(question) } else { recompute() }
        focus()
    }

    func reset() {
        query = ""
        category = nil
        mode = .search
        selectedID = nil
        follow = true
        message = nil
        typed = nil
        files = []
        scriptOutput = nil
    }

    func hide() { onHide() }

    func focus() { focusToken += 1 }

    // MARK: Changing what's shown

    /// Typed in the field: the best match is picked again.
    func typed(_ value: String) {
        if case .slider = mode { return }
        guard value != query else { return }
        query = value
        selectedID = nil
        follow = true
        message = nil
        if case .naming(let row, let saved, let warning) = mode, warning != nil { mode = .naming(row, saved: saved, warning: nil) }
        // Asking, naming or a number isn't a search: no scripts, no Spotlight.
        guard mode.isSearch else { return }
        searchFiles()
        runScript()
        recompute()
    }

    func setQuery(_ value: String) {
        query = value
        selectedID = nil
        follow = true
        searchFiles()
        runScript()
        recompute()
        focus()
    }

    func setCategory(_ value: BarCategory?) {
        category = value
        query = ""
        selectedID = nil
        follow = true
        if case .source(.emoji)? = value { data.wantEmoji() }
        if case .source(.processes)? = value { data.wantProcesses() }
        recompute()
        focus()
    }

    func enterAsk(_ question: String?) {
        conversation.checkAvailability()
        query = ""
        category = nil
        mode = .ask
        if let question, !question.isEmpty { conversation.ask(question) }
        focus()
    }

    /// The pointer picked a row. Only a pointer that really moved counts:
    /// a list scrolling under a still pointer must not steal the selection
    /// from the keyboard.
    func hover(_ id: String) {
        let at = NSEvent.mouseLocation
        defer { lastPointer = at }
        guard let last = lastPointer, last != at, !mode.isActions, selectedID != id else { return }
        follow = false
        selectedID = id
        resolveSelection()
    }

    /// A colour came back from the picker: the Colors view, its HEX already copied.
    func picked(_ hex: String) {
        prefs.addColor(hex)
        CommandBarPanel.shared.model.pendingCategory = .source(.colors)
        CommandBarPanel.shared.show()
    }

    // MARK: Rows and results

    private func off(_ source: BarSource) -> Bool { !prefs.isOn(source) }

    /// Rows that don't depend on the query, rebuilt when the data or the
    /// settings that shape them change.
    private func rebuildBase() {
        let p = prefs
        if emojiShape != (data.emoji.count, p.skinTone) {
            emojiShape = (data.emoji.count, p.skinTone)
            emojiRows = BarRows.emoji(data.emoji, tone: p.skinTone, self).map { $0.candidate == nil ? $0.indexed() : $0 }
        }
        baseRows = [
            "extensions": BarRows.extensions(self),
            "tools": BarRows.tools(data.quick, self),
            "system": BarRows.system(data.facts, self),
            "answers": BarRows.facts(data.facts, watch: data.watch),
            "folders": BarRows.folders(data.folders, self),
            "apps": BarRows.apps(data.apps, running: data.running, self),
            "panes": BarRows.panes(data.panes, self),
            "quit": BarRows.quit(data.running, self),
            "processes": BarRows.processes(data.processes, listeners: data.listeners, self),
            "colors": data.quick == nil ? [] : BarRows.colors(p.colors, self),
        ].mapValues { $0.map { $0.candidate == nil ? $0.indexed() : $0 } }
        baseRows["emoji"] = emojiRows
        baseVersion = data.version
    }

    private var lastShape: (SkinTone, [String], Int) = (.none, [], -1)

    func recompute() {
        let shape = (prefs.skinTone, prefs.colors, data.version)
        if shape != lastShape {
            lastShape = shape
            rebuildBase()
        }
        let base = baseRows
        let ours = BarRows.lowtide(self, query: query, hosts: data.hosts)
        let links = BarRows.links(prefs.links, query: query, self)
        let catalog = (base["extensions"] ?? []) + ours + (base["tools"] ?? []) + (base["system"] ?? []) + (base["answers"] ?? [])
            + links + (base["folders"] ?? []) + (base["apps"] ?? []) + (base["panes"] ?? [])
        let tools = base["tools"] ?? []
        let byCategory: [BarCategory: [BarRow]] = [
            .source(.answers): base["answers"] ?? [], .source(.apps): base["apps"] ?? [],
            .source(.awake): tools.filter { $0.source == .awake }, .source(.colors): base["colors"] ?? [],
            .source(.display): tools.filter { $0.source == .display }, .source(.emoji): base["emoji"] ?? [],
            .source(.files): BarRows.files(files, self), .source(.folders): base["folders"] ?? [], .source(.links): links,
            .source(.macSettings): base["panes"] ?? [], .source(.processes): base["processes"] ?? [], .source(.quit): base["quit"] ?? [],
            .source(.sound): tools.filter { $0.source == .sound }, .source(.system): base["system"] ?? [], .tools: tools,
            .source(.lowtide): ours,
        ]
        if query.hasPrefix(":") || prefs.pins.contains(where: { $0.hasPrefix("emoji.") }) { data.wantEmoji() }

        split = BarSearch.splitNumber(query, rows: catalog)
        var pools = BarPools()
        pools.catalog = catalog
        pools.emoji = base["emoji"] ?? []
        pools.quit = base["quit"] ?? []
        pools.files = category == nil && !off(.files) ? BarRows.files(files, self) : []
        if category == nil, !off(.calculator), !query.hasPrefix(":") {
            pools.answer = Answers.answer(query).map(BarRows.answer)
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.count > 3, !trimmed.contains(" "), let url = Answers.webAddress(trimmed) { pools.url = BarRows.url(url, self) }
        if let scriptOutput, !scriptOutput.isEmpty { pools.script = BarRows.scriptAnswer(scriptOutput) }

        let active = category.map { (label: $0.label, rows: byCategory[$0] ?? []) }
        var found = BarSearch(prefs: prefs, habits: settings.habits).results(split.text, category: active, pools: pools)
        // "awake 90": the row that takes the number goes first.
        if split.argument != nil {
            found.rows = found.rows.filter { $0.number != nil } + found.rows.filter { $0.number == nil }
        }
        list = found
        // Emoji and processes load when their view opens, so their chips
        // can't wait for rows.
        let lazy: Set<BarCategory> = [.source(.emoji), .source(.processes)]
        chips = BarCategory.chips.filter { chip in
            if lazy.contains(chip), case .source(let source) = chip { return prefs.isOn(source) }
            return (byCategory[chip] ?? []).contains { prefs.isOn($0.source) }
        }
        resolveSelection()
    }

    /// A row that just left the list (hidden, quit) hands the selection to
    /// its neighbour instead of sending it back to the top.
    private func resolveSelection() {
        if let id = selectedID, let at = list.rows.firstIndex(where: { $0.id == id }) {
            selectedIndex = at
        } else {
            selectedIndex = selectedID == nil ? 0 : max(0, min(selectedIndex, list.rows.count - 1))
        }
    }

    private func searchFiles() {
        fileTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespaces)
        let browsingOther = category != nil && category != .source(.files)
        guard text.count >= 2, !text.hasPrefix(":"), !browsingOther, !off(.files), !prefs.fileScopes.isEmpty else {
            if !files.isEmpty { files = [] }
            return
        }
        let scopes = prefs.fileScopes, ignores = prefs.fileIgnores
        fileTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let hits = await FileSearch.search(text, scopes: scopes, ignores: ignores)
            guard !Task.isCancelled, let self, self.query.trimmingCharacters(in: .whitespaces) == text else { return }
            self.files = hits
            self.recompute()
        }
    }

    /// The script named at the start of the query, run as you type.
    private func runScript() {
        let matches = prefs.links.filter { $0.kind == .script }.compactMap { link -> (BarLink, String)? in
            guard let arg = link.argument(in: query), !arg.isEmpty || link.runsWithoutArgument else { return nil }
            return (link, arg)
        }.sorted { $0.0.name.count > $1.0.name.count }
        guard !off(.links), let (link, arg) = matches.first else {
            scriptTask?.cancel()
            scriptKey = ""
            scriptOutput = nil
            return
        }
        let key = "\(link.id)|\(arg)"
        guard key != scriptKey else { return }
        scriptKey = key
        scriptTask?.cancel()
        scriptTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let result = await UserScript.run(link.destination, argument: arg.isEmpty ? nil : arg)
            guard !Task.isCancelled, let self, self.scriptKey == key else { return }
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            self.scriptOutput = output.isEmpty ? (result.ok ? nil : "Couldn't run this file") : output
            self.recompute()
        }
    }

    // MARK: Running things

    static let notPinnable: Set<BarSource> = [.quit, .files, .processes, .calculator]
    static let notNameable: Set<BarSource> = [.files, .processes, .calculator]

    /// Rows that open a view are always there to pin and name.
    func pinnable(_ row: BarRow) -> Bool { row.keepsOpen || !Self.notPinnable.contains(row.source) }
    func nameable(_ row: BarRow) -> Bool { row.keepsOpen || !Self.notNameable.contains(row.source) }

    /// The row's own ⌘K actions, then pin, name, hide and forget.
    func actions(for row: BarRow) -> [BarRowAction] {
        var actions = row.actions
        if let path = row.path, !actions.contains(where: { $0.id == "reveal" }) { actions.append(BarRows.reveal(path)) }
        let key = row.stableKey
        if pinnable(row) {
            let at = prefs.pins.firstIndex(of: key)
            actions.append(BarRowAction(id: "pin", title: at == nil ? "Add to Quick access" : "Remove from Quick access",
                                        symbol: at == nil ? "pin" : "pin.slash") { [weak self] in self?.prefs.togglePin(key) })
            if let at, at > 0 {
                actions.append(BarRowAction(id: "pinUp", title: "Move up in Quick access", symbol: "arrow.up") { [weak self] in
                    self?.prefs.movePin(key, by: -1)
                })
            }
            if let at, at < prefs.pins.count - 1 {
                actions.append(BarRowAction(id: "pinDown", title: "Move down in Quick access", symbol: "arrow.down") { [weak self] in
                    self?.prefs.movePin(key, by: 1)
                })
            }
        }
        if nameable(row) {
            actions.append(BarRowAction(id: "name", title: prefs.aliases[key] == nil ? "Give it your own name" : "Change the name it answers to",
                                        symbol: "pencil") {})
        }
        actions.append(BarRowAction(id: "hide", title: "Never show this", symbol: "eye.slash") { [weak self] in self?.prefs.toggleHidden(key) })
        if row.counts, prefs.usage[row.id] != nil {
            let id = row.id
            actions.append(BarRowAction(id: "forget", title: "Forget how often I use this", symbol: "clock.arrow.circlepath") { [weak self] in
                self?.prefs.forget(id)
            })
        }
        return actions
    }

    private func count(_ row: BarRow) {
        if row.counts {
            prefs.record(row.id)
            settings.habits.learn(typed ?? split.text, id: row.id)
        }
        typed = nil
    }

    private func execute(_ row: BarRow, _ argument: Int?) {
        count(row)
        if !row.keepsOpen { hide() }
        // Lowtide's own rows open its window. macOS lets an app come forward
        // only while it handles the person's key or click, so the window is
        // brought forward now: from the task below it would open behind.
        if row.opensWindow, !row.keepsOpen, host == .panel { WindowRouter.showMain() }
        Task { await perform { try await row.run(argument) } }
    }

    /// Runs work, and brings a failure back into view: the bar may already
    /// be hidden when it fails.
    private func perform(_ work: @MainActor () async throws -> Void) async {
        do { try await work() } catch {
            // ⌘K in the window is gone by now, with its model: a toast says it.
            guard host == .panel else { Toasts.shared.failure("Couldn't do that", error); return }
            message = error.localizedDescription
            if !CommandBarPanel.shared.isOpen { CommandBarPanel.shared.show(keeping: true) }
        }
    }

    /// Moves a slider and applies the level at once; the card follows.
    func slide(_ row: BarRow, to level: Int, saved: String) {
        let next = min(100, max(0, level))
        if next > 0 { resume = next }
        mode = .slider(row, level: next, saved: saved)
        Task { await perform { try await row.slider?.apply(next) } }
    }

    func run(_ row: BarRow?, argument: Int? = nil) {
        let argument = argument ?? split.argument
        guard let row else {
            if !query.isEmpty { setQuery("") }
            return
        }
        if let slider = row.slider, argument == nil {
            // Opening it turns it on, at the level it had when it was last on.
            count(row)
            let saved = query
            query = ""
            message = nil
            slide(row, to: slider.level > 0 ? slider.level : resume, saved: saved)
            focus()
            return
        }
        if row.number != nil, argument == nil {
            let saved = query
            query = ""
            mode = .number(row, saved: saved)
            focus()
            return
        }
        if row.confirm != nil {
            mode = .confirm(row, action: nil, argument: argument)
            return
        }
        execute(row, argument)
    }

    /// Pinning moves the row to the top of the empty bar. The view and the
    /// cursor stay put: it lands on the row that took its place.
    private func stayInPlace() {
        follow = false
        guard query.isEmpty, category == nil else { return }
        let rows = list.rows
        let next = rows.indices.contains(selectedIndex + 1) ? rows[selectedIndex + 1] : rows.indices.contains(selectedIndex - 1)
            ? rows[selectedIndex - 1] : nil
        selectedID = next?.id
    }

    func runAction(_ row: BarRow, _ action: BarRowAction) {
        if action.id == "name" {
            let saved = query
            query = prefs.aliases[row.stableKey] ?? ""
            mode = .naming(row, saved: saved, warning: nil)
            focus()
            return
        }
        if action.confirm != nil {
            mode = .confirm(row, action: action, argument: nil)
            return
        }
        if action.id == "pin" { stayInPlace() } else { follow = false }
        mode = .search
        Task { await perform { try await action.run() } }
        focus()
    }

    func confirm() {
        guard case .confirm(let row, let action, let argument) = mode else { return }
        mode = .search
        if let action {
            hide()
            Task { await perform { try await action.run() } }
        } else {
            execute(row, argument)
        }
    }

    func cancelMode() {
        mode = .search
        focus()
    }

    private func back(_ restore: String) {
        mode = .search
        query = restore
        recompute()
        focus()
    }

    // MARK: Keys

    private func move(_ delta: Int) {
        let n = list.rows.count
        guard n > 0 else { return }
        follow = true
        selectedIndex = ((selectedIndex + delta) % n + n) % n
        selectedID = list.rows[selectedIndex].id
    }

    private func moveCategory(_ delta: Int) {
        let ids: [BarCategory?] = [nil] + chips.map(Optional.some)
        let at = ids.firstIndex { $0 == category } ?? 0
        setCategory(ids[((at + delta) % ids.count + ids.count) % ids.count])
    }

    /// Tab: the calculator's result, a row's title, or Ask.
    private func complete() {
        guard let row = selected else {
            enterAsk(query.isEmpty ? nil : query)
            return
        }
        if row.id == "lowtide.ask.query" || row.id == "lowtide.ask" || query.isEmpty {
            enterAsk(row.id == "lowtide.ask.query" ? query : nil)
        } else if let reuse = row.reuse {
            setQuery(reuse)
        } else if !row.answer {
            typed = typed ?? query
            setQuery(query.hasPrefix(":") ? ":\(row.title)" : row.title)
        }
    }

    func escape() {
        switch mode {
        case .actions, .confirm:
            cancelMode()
        case .number(_, let saved):
            back(saved)
        case .slider(_, _, let saved):
            // The list shows the level it was left at.
            data.refreshQuick()
            back(saved)
        case .naming(let row, let saved, _):
            query = saved
            mode = .actions(row, index: 0)
        case .ask:
            if conversation.running {
                conversation.stop()
            } else if !query.isEmpty {
                query = ""
            } else {
                mode = .search
                focus()
            }
        case .search:
            if !query.isEmpty {
                setQuery("")
            } else if category != nil {
                setCategory(nil)
            } else {
                hide()
            }
        }
    }

    func enter() {
        switch mode {
        case .actions(let row, let index):
            let actions = actions(for: row)
            if actions.indices.contains(index) { runAction(row, actions[index]) }
        case .confirm:
            confirm()
        case .slider:
            hide()
        case .number(let row, _):
            guard let value = Int(query.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)),
                  query.count <= 5, let range = row.number else {
                message = "Type a number"
                return
            }
            mode = .search
            execute(row, min(max(value, range.lowerBound), range.upperBound))
        case .naming(let row, let saved, _):
            let name = query.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, prefs.aliasClash(key: row.stableKey, alias: name) != nil {
                mode = .naming(row, saved: saved, warning: "Another row already answers to that")
                return
            }
            prefs.setAlias(row.stableKey, name)
            back(saved)
        case .ask:
            let question = query
            query = ""
            conversation.ask(question)
        case .search:
            run(selected)
        }
    }

    /// Keys the bar answers itself, before the field sees them. True when handled.
    func handle(_ event: NSEvent) -> Bool {
        if let editor = event.window?.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let control = flags.contains(.control) && !command
        let key = Int(event.keyCode)
        let letter = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if case .slider(let row, let level, let saved) = mode, !command, !control {
            let step = flags.contains(.option) ? 1 : 5
            switch key {
            case kVK_LeftArrow, kVK_DownArrow:
                slide(row, to: level - step, saved: saved)
                return true
            case kVK_RightArrow, kVK_UpArrow:
                slide(row, to: level + step, saved: saved)
                return true
            case kVK_Space:
                slide(row, to: level > 0 ? 0 : resume, saved: saved)
                return true
            default: break
            }
        }

        let up = key == kVK_UpArrow || (control && letter == "p")
        let down = key == kVK_DownArrow || (control && letter == "n")
        if (up || down) && !mode.isAsk {
            if case .actions(let row, let index) = mode {
                let n = actions(for: row).count
                mode = .actions(row, index: ((index + (up ? -1 : 1)) % n + n) % n)
            } else {
                move(up ? -1 : 1)
            }
            return true
        }
        if key == kVK_Escape {
            escape()
            return true
        }
        if key == kVK_Return || key == kVK_ANSI_KeypadEnter, !command {
            enter()
            return true
        }
        if command { return commandKey(letter, key: key) }

        let chip = category != nil || mode.chipRow != nil || mode.isAsk
        if key == kVK_Delete, query.isEmpty, chip, !event.isARepeat {
            escape()
            return true
        }
        if key == kVK_Tab {
            if mode.isSearch {
                complete()
                return true
            }
            if mode.isAsk, query.isEmpty {
                mode = .search
                focus()
                return true
            }
        }
        if key == kVK_LeftArrow || key == kVK_RightArrow, query.isEmpty, mode.isSearch {
            moveCategory(key == kVK_LeftArrow ? -1 : 1)
            return true
        }
        if case .confirm = mode { mode = .search }
        return false
    }

    /// ⌘1–9 run a row, ⌘K actions, ⌘P pin, ⌘↩ reveal, ⌘, settings, ⌘J Ask.
    private func commandKey(_ letter: String, key: Int) -> Bool {
        if let n = Int(letter), (1...9).contains(n), !mode.isAsk {
            run(list.rows.indices.contains(n - 1) ? list.rows[n - 1] : nil)
            return true
        }
        switch letter {
        case "k":
            if case .actions = mode {
                mode = .search
            } else if let row = selected, !row.answer, mode.isSearch {
                mode = .actions(row, index: 0)
            }
            return true
        case "p":
            if let row = selected, pinnable(row), mode.isSearch {
                stayInPlace()
                prefs.togglePin(row.stableKey)
            }
            return true
        case "j":
            if mode.isAsk { mode = .search; focus() } else { enterAsk(query.isEmpty ? nil : query) }
            return true
        case ".":
            conversation.stop()
            return true
        case "n" where mode.isAsk:
            conversation.reset()
            return true
        case ",":
            hide()
            WindowRouter.showSettings()
            return true
        default:
            break
        }
        if key == kVK_Return, let path = selected?.path {
            hide()
            try? Opener.reveal(path)
            return true
        }
        // ⌘Q, ⌘W, ⌘H and ⌘M never reach the app from the floating bar.
        return host == .panel && ["q", "w", "h", "m"].contains(letter)
    }

    // MARK: Words

    var placeholder: String {
        switch mode {
        case .number(let row, _): row.number.map { "\($0.lowerBound) to \($0.upperBound)" } ?? "A number"
        case .slider: "← → to adjust"
        case .naming: "The name you call it"
        case .ask: "What happened on this Mac today?"
        default: category.map { "Search \($0.label.lowercased())…" } ?? "Search apps, Lowtide and your Mac…"
        }
    }

    var chipLabel: String? {
        if mode.isAsk { return "Ask" }
        return mode.chipRow?.title ?? category?.label
    }

    /// What Return does right now, for the footer.
    var primaryLabel: String? {
        switch mode {
        case .actions: return "Run action"
        case .slider: return "Done"
        case .ask: return conversation.running ? nil : "Ask"
        case .search:
            guard let row = selected else { return nil }
            if row.answer || row.copy != nil { return "Copy" }
            if row.keepsOpen { return "Open" }
            switch row.source {
            case .apps: return "Open Application"
            case .folders, .files: return "Open"
            default: return "Run"
            }
        default: return nil
        }
    }
}
