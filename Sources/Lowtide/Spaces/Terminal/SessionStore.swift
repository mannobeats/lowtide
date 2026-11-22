import AppKit
import Carbon.HIToolbox
import LowtideKit
import SwiftTerm
import SwiftUI

/// Every terminal session, alive across navigation: the tabs and their
/// split trees, the sessions' views and processes, and the keys that act
/// on them while the Sessions page is in front.
@Observable
final class SessionStore {
    static let shared = SessionStore()

    private(set) var workspace = TerminalWorkspace() {
        didSet { if workspace.pinnedForRestore != oldValue.pinnedForRestore { savePinned() } }
    }
    private(set) var sessions: [String: TerminalSession] = [:]
    var findOpen = false
    var findText = ""
    var findCaseSensitive = false
    private(set) var findSummary: (index: Int, total: Int)?
    /// A drag of a divider is in progress (no animation while it lasts).
    var dragging = false

    @ObservationIgnored let remote = RemoteStore.shared
    @ObservationIgnored private var keyMonitor: Any?
    private let pinnedFile = "terminal-tabs.json"

    var page: Page { AppModel.shared.page }

    init() {
        workspace.restore(JSONStore.load(pinnedFile, default: [TerminalTab]()))
        for tab in workspace.tabs { sessions[tab.id] = TerminalSession(tab: tab, store: self) }
    }

    private func savePinned() { JSONStore.save(workspace.pinnedForRestore, to: pinnedFile) }

    static func defaultShell(cwd: String? = nil) -> TabCommand {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
        return TabCommand(program: shell, args: ["-l"], cwd: cwd)
    }

    var focusedSession: TerminalSession? { workspace.focusedPane.flatMap { sessions[$0] } }

    func session(_ id: String) -> TerminalSession? { sessions[id] }

    // MARK: Opening

    private func adopt(_ tab: TerminalTab) {
        sessions[tab.id] = TerminalSession(tab: tab, store: self)
    }

    @discardableResult
    func openLocal(cwd: String? = nil, title: String = "Local", initialInput: String? = nil) -> String {
        let tab = TerminalTab(kind: .local, title: title, command: Self.defaultShell(cwd: cwd), initialInput: initialInput)
        adopt(tab)
        withAnimation(Motion.fast) { _ = workspace.add(tab) }
        return tab.id
    }

    /// An SSH session to a saved host; with a remote command (a snippet,
    /// a key change) the tab is one-shot and stays open after it.
    @discardableResult
    func openSSH(_ host: RemoteHost, title: String? = nil, args: [String]? = nil, oneShot: Bool = false) -> String? {
        let resolution = remote.resolution
        do {
            let command = try args ?? SSHCommand.interactive(resolution.endpoint(for: host))
            let tab = TerminalTab(kind: .ssh, title: title ?? host.name, command: TabCommand(program: SSHCommand.program, args: command),
                                  hostID: host.id, identityID: resolution.identity(for: host)?.id, oneShot: oneShot)
            adopt(tab)
            withAnimation(Motion.fast) { _ = workspace.add(tab) }
            return tab.id
        } catch {
            Toasts.shared.failure("Couldn't connect to \(host.name)", error)
            return nil
        }
    }

    /// Quick connect: a host that isn't saved.
    func openQuick(user: String, host: String, port: Int) throws {
        let args = try SSHCommand.interactive(SSHEndpoint(host: host, port: port, user: user))
        let tab = TerminalTab(kind: .ssh, title: "\(user)@\(host)", command: TabCommand(program: SSHCommand.program, args: args))
        adopt(tab)
        withAnimation(Motion.fast) { _ = workspace.add(tab) }
    }

    // MARK: Tabs and panes

    func select(_ id: String) {
        workspace.activeID = workspace.root(of: id)
        focusSoon()
    }

    func focusPane(_ id: String) {
        guard workspace.tab(id) != nil else { return }
        workspace.setFocus(id)
        if workspace.activeID != workspace.root(of: id) { workspace.activeID = workspace.root(of: id) }
    }

    func close(_ id: String) {
        let gone = workspace.close(id)
        dispose(gone)
        focusSoon()
    }

    func closeOthers(_ id: String) {
        dispose(workspace.closeOthers(id))
        focusSoon()
    }

    func closePane(_ id: String) {
        withAnimation(Motion.fast) { dispose(workspace.closePane(id)) }
        focusSoon()
    }

    private func dispose(_ ids: [String]) {
        for id in ids {
            sessions[id]?.close()
            sessions[id]?.view.removeFromSuperview()
            sessions[id] = nil
        }
        if workspace.tabs.isEmpty { findOpen = false }
    }

    func duplicate(_ id: String) {
        guard let copy = workspace.duplicate(id), let tab = workspace.tab(copy) else { return }
        adopt(tab)
        focusSoon()
    }

    func rename(_ id: String, to title: String) { workspace.rename(id, to: title) }
    func togglePin(_ id: String) { workspace.togglePin(id) }
    func moveTab(_ id: String, to target: String) { workspace.moveTab(id, to: target) }

    /// A new session beside a pane: a shell in the same folder, or another
    /// connection to the same host.
    func split(_ id: String? = nil, axis: PaneLayout.Axis) {
        guard let source = (id ?? workspace.focusedPane).flatMap({ workspace.tab($0) }) else {
            openLocal()
            return
        }
        let pane: TerminalTab
        if source.kind == .ssh, !source.oneShot {
            pane = TerminalTab(kind: .ssh, title: source.title, command: source.command, hostID: source.hostID,
                               identityID: source.identityID)
        } else {
            pane = TerminalTab(kind: .local, title: "Local", command: Self.defaultShell(cwd: sessions[source.id]?.currentDirectory()))
        }
        adopt(pane)
        withAnimation(Motion.spring) {
            if workspace.split(source.id, axis: axis, with: pane) == nil { sessions[pane.id] = nil }
        }
        focusSoon()
    }

    func toggleZoom() {
        guard let root = workspace.activeID else { return }
        withAnimation(Motion.spring) { workspace.toggleZoom(root) }
        focusSoon()
    }

    func equalize() {
        guard let root = workspace.activeID else { return }
        withAnimation(Motion.spring) { workspace.equalize(root) }
    }

    func setRatio(_ root: String, path: String, ratio: Double) { workspace.setRatio(root, path: path, ratio: ratio) }

    func swap(_ a: String, _ b: String) {
        withAnimation(Motion.spring) { workspace.swapPanes(a, b) }
    }

    func cycle(_ delta: Int) {
        workspace.cycle(delta)
        focusSoon()
    }

    func sessionExited(_ id: String) { workspace.markExited(id) }

    /// Gives the focused pane the keyboard once it's on screen.
    func focusSoon() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(30))
            guard let self, self.page == .sessions, NSApp.keyWindow?.attachedSheet == nil else { return }
            self.focusedSession?.focus()
        }
    }

    /// Text into the terminal in front (snippets), optionally run.
    @discardableResult
    func typeIntoActive(_ text: String, run: Bool) -> Bool {
        guard let session = focusedSession, !session.exited else { return false }
        session.type(text, run: run)
        return true
    }

    var activeAvailable: Bool { focusedSession.map { !$0.exited } ?? false }

    // MARK: Find

    func find(next: Bool = true) {
        guard let view = focusedSession?.view, !findText.isEmpty else {
            findSummary = nil
            return
        }
        let options = SearchOptions(caseSensitive: findCaseSensitive)
        _ = next ? view.findNext(findText, options: options) : view.findPrevious(findText, options: options)
        let summary = view.searchMatchSummary(findText, options: options)
        findSummary = (summary.index, summary.total)
    }

    func closeFind() {
        findOpen = false
        findSummary = nil
        focusedSession?.view.clearSearch()
        focusSoon()
    }

    // MARK: Appearance

    func applyColors() {
        let colors = TerminalColors.current
        for session in sessions.values { session.applyColors(colors) }
    }

    func applySettings() {
        let settings = TerminalSettings.shared
        for session in sessions.values { session.applySettings(settings) }
    }

    /// Repaints the sessions when the theme or the settings change.
    func followAppearance() {
        followColors()
        followSettings()
    }

    private func followColors() {
        withObservationTracking {
            _ = ThemeStore.shared.current
        } onChange: {
            Task { @MainActor in
                SessionStore.shared.applyColors()
                SessionStore.shared.followColors()
            }
        }
    }

    private func followSettings() {
        withObservationTracking {
            let s = TerminalSettings.shared
            _ = (s.fontSize, s.cursor, s.cursorBlink, s.optionAsMeta, s.autocomplete)
        } onChange: {
            Task { @MainActor in
                SessionStore.shared.applySettings()
                SessionStore.shared.followSettings()
            }
        }
    }

    func terminateAll() {
        for session in sessions.values { session.close() }
    }

    // MARK: Keys

    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            SessionStore.shared.handle(event) ? nil : event
        }
    }

    func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Keys while the Sessions page is in front. Returns true when it took the key.
    private func handle(_ event: NSEvent) -> Bool {
        guard page == .sessions, let window = event.window, window.identifier?.rawValue == "main" || window.title == "Lowtide",
              window.attachedSheet == nil, !AppModel.shared.paletteOpen else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let code = Int(event.keyCode)
        let terminalFocused = window.firstResponder is LowtideTerminalView
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if terminalFocused, let session = focusedSession {
            if !session.suggestions.isEmpty, flags.isDisjoint(with: [.command, .control, .option]) {
                switch code {
                case kVK_Escape:
                    session.hideSuggestions()
                    return true
                case kVK_DownArrow where flags.isEmpty:
                    session.moveSelection(1)
                    return true
                case kVK_UpArrow where flags.isEmpty:
                    session.moveSelection(-1)
                    return true
                case kVK_Tab where flags.isEmpty && session.selectedExtendsLine,
                     kVK_RightArrow where flags.isEmpty && session.lineAtEnd:
                    if session.suggestions.indices.contains(session.selectedSuggestion) {
                        session.accept(session.suggestions[session.selectedSuggestion])
                        return true
                    }
                default:
                    break
                }
            }
            if session.exited, (code == kVK_Return || code == kVK_ANSI_KeypadEnter), flags.isDisjoint(with: [.command, .control]) {
                closePane(session.id)
                return true
            }
            if session.credentialPickerOpen, code == kVK_Escape, flags.isEmpty {
                session.credentialPickerOpen = false
                return true
            }
        }
        if findOpen, code == kVK_Escape, flags.isEmpty {
            closeFind()
            return true
        }
        guard flags.contains(.command) else {
            if flags == [.control], code == kVK_Tab { cycle(1); return true }
            if flags == [.control, .shift], code == kVK_Tab { cycle(-1); return true }
            return false
        }
        let arrows: [Int: PaneLayout.Direction] = [kVK_LeftArrow: .left, kVK_RightArrow: .right, kVK_UpArrow: .up, kVK_DownArrow: .down]
        if let direction = arrows[code] {
            switch flags {
            case [.command, .option]: workspace.focus(direction); focusSoon()
            case [.command, .option, .shift]: withAnimation(Motion.spring) { workspace.move(direction) }
            case [.command, .shift]: withAnimation(Motion.fast) { workspace.resize(direction) }
            default: return false
            }
            return true
        }
        switch (flags, code, key) {
        case ([.command], _, "w"):
            guard let id = workspace.focusedPane else { return false }
            closePane(id)
        case ([.command], _, "d"): split(axis: .row)
        case ([.command, .shift], _, "d"): split(axis: .column)
        case ([.command, .shift], kVK_Return, _): toggleZoom()
        case ([.command], kVK_Return, _): window.toggleFullScreen(nil)
        case ([.command, .option], kVK_ANSI_Equal, _): equalize()
        case ([.command, .shift], kVK_ANSI_RightBracket, _): cycle(1)
        case ([.command, .shift], kVK_ANSI_LeftBracket, _): cycle(-1)
        case ([.command], _, "f"):
            guard !workspace.tabs.isEmpty else { return false }
            findOpen = true
        case ([.command], _, "g"): find(next: true)
        case ([.command, .shift], _, "g"): find(next: false)
        case ([.command], kVK_ANSI_Equal, _), ([.command, .shift], kVK_ANSI_Equal, _): TerminalSettings.shared.bigger()
        case ([.command], kVK_ANSI_Minus, _): TerminalSettings.shared.smaller()
        case ([.command], kVK_ANSI_0, _): TerminalSettings.shared.actualSize()
        case ([.command, .shift], _, "p"):
            guard let session = focusedSession, !session.exited else { return false }
            session.credentialPickerOpen.toggle()
        default:
            return false
        }
        return true
    }
}
