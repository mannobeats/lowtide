import AppKit
import Darwin
import LowtideKit
import SwiftTerm
import SwiftUI

/// The terminal's NSView: SwiftTerm's view plus the few hooks a session needs.
final class LowtideTerminalView: TerminalView {
    weak var session: TerminalSession?

    override func mouseDown(with event: NSEvent) {
        session?.clicked()
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        session?.selectionSettled()
    }

    override func rightMouseDown(with event: NSEvent) {
        session?.clicked()
        guard currentMouseMode == .off || event.modifierFlags.contains(.option) else {
            super.rightMouseDown(with: event)
            return
        }
        NSMenu.popUpContextMenu(contextMenu(), with: event, for: self)
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        let copy = menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        copy.isEnabled = selectionActive
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Clear Scrollback", action: #selector(clearHistory), keyEquivalent: "")
        menu.addItem(withTitle: "Find…", action: #selector(showFind), keyEquivalent: "")
        return menu
    }

    @objc private func clearHistory() { clearScrollback() }

    // Files dropped on the terminal type their paths, as in Terminal.
    func acceptFileDrops() { registerForDraggedTypes([.fileURL]) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        session?.type(urls.map { SSHCommand.shellQuote($0.path) }.joined(separator: " ") + " ", run: false)
        window?.makeFirstResponder(self)
        return true
    }
    @objc private func showFind() { session?.store?.findOpen = true }
}

/// Moves process output from SwiftTerm's IO queue into the parser, and
/// watches it for secret prompts on the way. Every mutable field is behind
/// the lock; the session is only touched on the main actor.
nonisolated private final class ProcessBridge: LocalProcessDelegate, @unchecked Sendable {
    let feed: TerminalFeedSender
    private let lock = NSLock()
    private var watcher = PromptWatcher()
    private var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
    private var outputPending = false
    weak var session: TerminalSession?

    init(feed: TerminalFeedSender) { self.feed = feed }

    func setSize(cols: Int, rows: Int) {
        lock.withLock { size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: cols), ws_xpixel: 0, ws_ypixel: 0) }
    }

    func getWindowSize() -> winsize { lock.withLock { size } }

    func resetPrompt() { lock.withLock { watcher.clear() } }

    func inputEndsPrompt(_ text: String) -> Bool { lock.withLock { watcher.inputEnds(text) } }

    func dataReceived(slice: ArraySlice<UInt8>) {
        feed.feed(byteArray: slice)
        // Prompts are short and last: the end of the chunk is enough.
        let text = String(decoding: slice.suffix(300), as: UTF8.self)
        let (change, notify) = lock.withLock { () -> (PromptWatcher.Prompt??, Bool) in
            let change = watcher.feed(text)
            let notify = !outputPending
            outputPending = true
            return (change, notify)
        }
        if let change {
            Task { @MainActor [weak self] in self?.session?.promptChanged(change) }
        }
        if notify {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lock.withLock { self.outputPending = false }
                self.session?.outputArrived()
            }
        }
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        Task { @MainActor [weak self] in self?.session?.exited(exitCode) }
    }

    func processFailedToStart(_ source: LocalProcess, error: LocalProcessError) {
        feed.feed(text: "\r\n\u{1b}[31mThe session couldn't start: \(error)\u{1b}[0m\r\n")
        Task { @MainActor [weak self] in self?.session?.exited(nil) }
    }
}

/// One shell or ssh connection: its view, its process, and what the pane
/// knows about it (the line being typed, the folder, the suggestions).
/// Lives in the session store, so it survives navigating away.
@Observable
final class TerminalSession: NSObject, TerminalViewDelegate {
    let id: String
    let view: LowtideTerminalView
    @ObservationIgnored weak var store: SessionStore?
    @ObservationIgnored private var process: LocalProcess!
    @ObservationIgnored private var bridge: ProcessBridge
    @ObservationIgnored private var oscObservation: TerminalOscObservation?
    @ObservationIgnored private var askpassToken: String?

    var tab: TerminalTab
    private(set) var exited = false
    private(set) var cwd: String
    /// The program set a title (OSC 0/2).
    private(set) var programTitle: String?

    // Autocomplete
    private(set) var suggestions: [TerminalSuggestion] = []
    var selectedSuggestion = 0
    private(set) var ghost: (text: String, frame: CGRect)?
    @ObservationIgnored private var line = InputLine()
    @ObservationIgnored private var completion: CompletionContext?
    @ObservationIgnored private var history: [CommandHistoryRow] = []
    @ObservationIgnored private var shellHistory: [String] = []
    @ObservationIgnored private var lastCommand: String?
    @ObservationIgnored private var pendingCommand: (command: String, cwd: String)?
    @ObservationIgnored private var directoryCache: [String: [CompletionEntry]?] = [:]
    @ObservationIgnored private var contextTask: Task<Void, Never>?
    @ObservationIgnored private var resizeTask: Task<Void, Never>?
    @ObservationIgnored private var lastSize = (cols: 0, rows: 0)
    @ObservationIgnored private let startedAt = Date()

    // Credentials
    private(set) var secretPrompt: PromptWatcher.Prompt?
    var credentialPickerOpen = false

    var contextKey: String { tab.kind == .local ? "local" : "ssh:\(tab.hostID ?? tab.title)" }
    var isLocal: Bool { tab.kind == .local }
    var pid: pid_t { process?.shellPid ?? 0 }

    init(tab: TerminalTab, store: SessionStore) {
        id = tab.id
        self.tab = tab
        self.store = store
        cwd = tab.command?.cwd ?? Paths.home.path
        let settings = TerminalSettings.shared
        var options = TerminalOptions()
        options.scrollback = settings.scrollback
        options.cursorStyle = settings.cursorStyle
        options.termName = "xterm-256color"
        view = LowtideTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 400), font: settings.font, options: options)
        bridge = ProcessBridge(feed: view.feedSender)
        super.init()
        view.session = self
        view.terminalDelegate = self
        view.optionAsMetaKey = settings.optionAsMeta
        view.resolvesLinksAgainstShellDirectory = tab.kind == .local
        view.linkHighlightMode = .hoverWithModifier
        view.scrollerStyle = .overlay
        view.acceptFileDrops()
        bridge.session = self
        process = LocalProcess(delegate: bridge, dispatchQueue: DispatchQueue(label: "terminal.\(tab.id)"))
        applyColors(TerminalColors.current)
        oscObservation = view.observeOscEvents { [weak self] event in
            guard event.code == 133 else { return }
            let payload = String(decoding: event.payload, as: UTF8.self)
            guard payload.hasPrefix("D") else { return }
            let code = Int32(payload.split(separator: ";").dropFirst().first ?? "0") ?? 0
            Task { @MainActor [weak self] in self?.commandFinished(code) }
        }
    }

    // MARK: Lifecycle

    /// Starts the process once the view has its real size.
    func start() {
        guard process.shellPid == 0, !exited else { return }
        let command = tab.command ?? SessionStore.defaultShell()
        var env = Self.environment()
        if tab.kind == .ssh, let host = store?.remote.host(tab.hostID) {
            let secrets = store?.remote.resolution.secrets(for: host) ?? []
            if !secrets.isEmpty, let ticket = try? AskpassServer.shared.register(secrets: secrets, interactive: true, label: host.name) {
                env.merge(ticket.environment) { _, new in new }
                askpassToken = ticket.token
            }
        }
        let isShell = tab.command == nil || (command.program.hasSuffix("sh") && command.args == ["-l"])
        let execName = isShell ? "-" + (command.program as NSString).lastPathComponent : nil
        let args = isShell ? [] : command.args
        let directory = command.cwd.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? Paths.home.path
        cwd = directory
        process.startProcess(executable: command.program, args: args,
                             environment: env.map { "\($0.key)=\($0.value)" }, execName: execName,
                             currentDirectory: directory)
        let pid = process.shellPid
        if pid > 0 {
            if let askpassToken { AskpassServer.shared.attach(askpassToken, pid: pid) }
            TerminalSessions.shared.register(id, kind: tab.kind.rawValue, shell: pid, fd: process.childfd)
        }
        if let input = tab.initialInput {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                self?.type(input, run: true)
            }
        }
        Task { await loadHistory() }
        if isLocal { refreshContext(cwd) }
    }

    /// The environment of every session: the person's own, a full PATH,
    /// UTF-8 and true colour, without what leaked into this app from
    /// whatever launched it.
    static func environment() -> [String: String] {
        var env = Shell.environment(quiet: false)
        let leakedPrefixes = ["npm_config_", "npm_package_", "npm_lifecycle_", "npm_node_", "NPM_CONFIG_", "PNPM_", "pnpm_",
                              "YARN_", "BERRY_", "COREPACK_", "VSCODE_", "ITERM_", "DYLD_", "LD_", "SSH_ASKPASS", "LOWTIDE_",
                              "__CF", "XPC_"]
        let leaked: Set<String> = ["INIT_CWD", "_", "TERM_SESSION_ID", "TERM_PROGRAM_VERSION", "LC_TERMINAL", "LC_TERMINAL_VERSION",
                                   "SHLVL", "OLDPWD", "PWD", "COLORFGBG", "ELECTRON_RUN_AS_NODE", "NO_COLOR"]
        for key in env.keys where leaked.contains(key) || leakedPrefixes.contains(where: key.hasPrefix) { env[key] = nil }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Lowtide"
        env["THELOWTIDE_TERMINAL"] = "1"
        if env["LANG"] == nil || env["LANG"]?.contains("UTF-8") == false {
            let id = Locale.current.identifier.replacingOccurrences(of: "-", with: "_")
            env["LANG"] = (id.contains("_") ? id : "en_US") + ".UTF-8"
        }
        return env
    }

    /// Ends the process: a hangup first (shells ignore SIGTERM), then a kill.
    func close() {
        contextTask?.cancel()
        resizeTask?.cancel()
        if let askpassToken { AskpassServer.shared.unregister(askpassToken) }
        askpassToken = nil
        TerminalSessions.shared.unregister(id)
        oscObservation = nil
        let pid = process.shellPid
        guard pid > 0, !exited else { return }
        kill(pid, SIGHUP)
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }

    func exited(_ code: Int32?) {
        guard !exited else { return }
        exited = true
        if let askpassToken { AskpassServer.shared.unregister(askpassToken) }
        askpassToken = nil
        TerminalSessions.shared.unregister(id)
        hideSuggestions()
        secretPrompt = nil
        credentialPickerOpen = false
        view.feed(text: "\r\n\u{1b}[2m[process exited\(code.map { " with \($0)" } ?? "") — press Return to close]\u{1b}[0m\r\n")
        store?.sessionExited(id)
    }

    // MARK: Appearance

    func applyColors(_ colors: TerminalColors) {
        view.nativeBackgroundColor = colors.background
        view.nativeForegroundColor = colors.foreground
        view.caretColor = colors.cursor
        view.caretTextColor = colors.cursorText
        view.selectedTextBackgroundColor = colors.selection
        view.selectedTextForegroundColor = colors.selectionText
        view.installColors(colors.ansi)
        view.layer?.backgroundColor = colors.background.cgColor
    }

    func applySettings(_ settings: TerminalSettings) {
        if view.font.pointSize != settings.font.pointSize { view.font = settings.font }
        view.setCursorStyle(settings.cursorStyle)
        view.optionAsMetaKey = settings.optionAsMeta
        if !settings.autocomplete { hideSuggestions() }
    }

    // MARK: Input

    /// Types text into the session as if it was typed, optionally with Return.
    func type(_ text: String, run: Bool) {
        guard !exited else { return }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r")
        send(normalized)
        // Return on its own, as a key: the line is recorded and the next one tracked.
        if run { send("\r") }
    }

    private func send(_ text: String) {
        let bytes = Array(text.utf8)
        process.send(data: bytes[...])
        track(text)
    }

    /// Autocomplete and history bookkeeping, after the shell has the keys.
    private func track(_ data: String) {
        if secretPrompt != nil {
            if bridge.inputEndsPrompt(data) {
                secretPrompt = nil
                credentialPickerOpen = false
            }
            return
        }
        let alternate = view.terminalContentSnapshot(region: .rows(0..<0))?.inputState.isAlternateBuffer == true
        switch line.feed(data, alternateScreen: alternate) {
        case .refresh:
            refreshSuggestions()
        case .hide:
            hideSuggestions()
        case .submitted(let command, let accepted):
            hideSuggestions()
            if let command {
                let key = contextKey, folder = cwd
                history = CommandHistory.remember(history, command: command, contextKey: key, cwd: folder, accepted: accepted)
                shellHistory = [command] + shellHistory.filter { $0 != command }.prefix(999)
                pendingCommand = (command, folder)
                lastCommand = command
                Task { await CommandHistory.record(command, contextKey: key, cwd: folder, accepted: accepted) }
            }
            if isLocal {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(180))
                    self?.followShellFolder()
                }
            }
        }
    }

    func commandFinished(_ code: Int32) {
        guard let pending = pendingCommand else { return }
        pendingCommand = nil
        let key = contextKey
        Task { await CommandHistory.recordOutcome(pending.command, contextKey: key, cwd: pending.cwd, succeeded: code == 0) }
    }

    // MARK: Folder context

    private func loadHistory() async {
        async let rows = CommandHistory.load()
        async let shell = Task.detached { CommandHistory.shellHistory() }.value
        history = await rows
        shellHistory = await shell
    }

    /// The shell's own working folder, read from the process (no lsof).
    static func workingDirectory(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    func currentDirectory() -> String { Self.workingDirectory(of: pid) ?? cwd }

    private func followShellFolder() {
        guard isLocal, let folder = Self.workingDirectory(of: pid) else { return }
        if folder != cwd || completion == nil { refreshContext(folder) }
    }

    private func refreshContext(_ folder: String) {
        cwd = folder
        directoryCache = [:]
        contextTask?.cancel()
        contextTask = Task { [weak self] in
            let context = await CompletionContext.load(cwd: folder)
            guard !Task.isCancelled, let self else { return }
            self.completion = context
            self.cwd = context.cwd
            if !self.line.text.isEmpty { self.refreshSuggestions() }
        }
    }

    // MARK: Suggestions

    private func suggestionContext() -> SuggestionContext {
        var context = SuggestionContext(completion: isLocal ? completion : nil, contextKey: contextKey, cwd: cwd)
        context.history = history
        context.shellHistory = shellHistory
        context.lastCommand = lastCommand
        context.hosts = store?.remote.snapshot.hosts.map(\.hostname) ?? []
        context.snippets = store?.remote.snapshot.snippets.map { (name: $0.name, content: $0.content) } ?? []
        context.listDirectory = { [weak self] dir in self?.listDirectory(dir) }
        return context
    }

    private func listDirectory(_ dir: String) -> [CompletionEntry]? {
        if let cached = directoryCache[dir] { return cached }
        if directoryCache.count > 200 { directoryCache = [:] }
        directoryCache[dir] = .some(nil)
        let folder = cwd
        Task { [weak self] in
            let entries = await Task.detached { CompletionContext.listDirectory(cwd: folder, dir) }.value
            guard let self else { return }
            self.directoryCache[dir] = .some(entries)
            self.refreshSuggestions()
        }
        return nil
    }

    private func refreshSuggestions() {
        guard TerminalSettings.shared.autocomplete, !line.unknown, !exited else {
            hideSuggestions()
            return
        }
        let next = TerminalIntelligence.suggestions(for: line.text, context: suggestionContext())
        if next.isEmpty && suggestions.isEmpty { return }
        suggestions = next
        selectedSuggestion = 0
        updateGhost()
    }

    func hideSuggestions() {
        if !suggestions.isEmpty { suggestions = [] }
        selectedSuggestion = 0
        if ghost != nil { ghost = nil }
    }

    func moveSelection(_ step: Int) {
        guard !suggestions.isEmpty else { return }
        selectedSuggestion = (selectedSuggestion + step + suggestions.count) % suggestions.count
        updateGhost()
    }

    /// Fish-style ghost text: the rest of the selected suggestion after the
    /// cursor. Skipped when the shell already draws its own
    /// (zsh-autosuggestions) or the cursor is mid-line.
    func updateGhost() {
        guard suggestions.indices.contains(selectedSuggestion) else {
            ghost = nil
            return
        }
        let insert = suggestions[selectedSuggestion].insertText
        let typed = line.text
        guard line.atEnd, insert.hasPrefix(typed), insert.count > typed.count,
              let cursor = view.terminalContentSnapshot(region: .rows(0..<0)),
              let snapshot = view.terminalContentSnapshot(region: .rows(cursor.cursorRow..<(cursor.cursorRow + 1))) else {
            ghost = nil
            return
        }
        let after = snapshot.rows.first.map { String($0.text.dropFirst(cursor.cursorColumn)) } ?? ""
        guard after.trimmingCharacters(in: .whitespaces).isEmpty else {
            ghost = nil
            return
        }
        ghost = (String(insert.dropFirst(typed.count)), view.caretFrame)
    }

    func accept(_ suggestion: TerminalSuggestion) {
        guard !exited else { return }
        let data = line.accept(suggestion.insertText)
        hideSuggestions()
        process.send(data: Array(data.utf8)[...])
        focus()
        // A completed word leads straight into the next: `git ` → its
        // subcommands, `src/` → the folder's contents.
        if suggestion.insertText.hasSuffix(" ") || suggestion.insertText.hasSuffix("/") {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(30))
                self?.refreshSuggestions()
            }
        }
    }

    /// True when the selected suggestion extends what was typed (Tab accepts
    /// only then, so the shell's own Tab completion keeps working).
    var selectedExtendsLine: Bool {
        suggestions.indices.contains(selectedSuggestion) && line.atEnd
            && suggestions[selectedSuggestion].insertText.hasPrefix(line.text)
    }

    var lineAtEnd: Bool { line.atEnd }

    // MARK: Output

    func outputArrived() {
        if ghost != nil { updateGhost() }
    }

    func promptChanged(_ prompt: PromptWatcher.Prompt?) {
        guard !exited else { return }
        secretPrompt = prompt
        if prompt == nil {
            credentialPickerOpen = false
        } else if preferredCredential(for: prompt) != nil {
            // Only an obviously matching credential is offered at once; the
            // full list stays behind ⇧⌘P so remote output can't fish for it.
            credentialPickerOpen = true
        }
    }

    /// The tab's own credential, when it answers this kind of prompt.
    func preferredCredential(for prompt: PromptWatcher.Prompt?) -> String? {
        guard let prompt, let identity = store?.remote.identity(tab.identityID ?? store?.remote.host(tab.hostID)?.identityID) else {
            return nil
        }
        switch (prompt, identity.kind) {
        case (.passphrase, .sshKey) where identity.hasPassphrase: return Identity.passphraseAccount(identity.id)
        case (.password, .password): return Identity.passwordAccount(identity.id)
        default: return nil
        }
    }

    /// Types a saved credential: Keychain → PTY, inside the app.
    func sendSecret(_ account: String) -> Bool {
        guard secretPrompt != nil, account.hasPrefix("identity:"), let secret = Keychain.get(account) else { return false }
        process.send(data: Array((secret + "\r").utf8)[...])
        bridge.resetPrompt()
        secretPrompt = nil
        credentialPickerOpen = false
        focus()
        return true
    }

    // MARK: Focus

    func focus() {
        guard let window = view.window else { return }
        if window.firstResponder !== view { window.makeFirstResponder(view) }
    }

    func clicked() { store?.focusPane(id) }

    func selectionSettled() {
        guard TerminalSettings.shared.copyOnSelect, view.selectionActive, let text = view.getSelection(), !text.isEmpty else { return }
        Files.copy(text)
    }

    // MARK: TerminalViewDelegate

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard newCols > 1, newRows > 1 else { return }
        bridge.setSize(cols: newCols, rows: newRows)
        if process.shellPid == 0 {
            lastSize = (newCols, newRows)
            return
        }
        // While the shell starts, a size change goes through at once (zsh's
        // first prompt pads to the width it was given); after that it waits
        // for the end of a drag so prompt themes don't redraw on every step.
        let settling = Date().timeIntervalSince(startedAt) < 1.5
        resizeTask?.cancel()
        resizeTask = Task { @MainActor [weak self] in
            if !settling { try? await Task.sleep(for: .milliseconds(90)) }
            guard let self, !Task.isCancelled, (newCols, newRows) != self.lastSize else { return }
            self.lastSize = (newCols, newRows)
            var size = winsize(ws_row: UInt16(newRows), ws_col: UInt16(newCols), ws_xpixel: 0, ws_ypixel: 0)
            _ = self.process.updateWindowSize(&size)
        }
        if ghost != nil { updateGhost() }
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        programTitle = title.isEmpty ? nil : title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard isLocal, let directory else { return }
        let path = URL(string: directory).map(\.path) ?? directory
        if !path.isEmpty, path != cwd { refreshContext(path) }
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        process.send(data: data)
        track(String(decoding: data, as: UTF8.self))
    }

    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    /// OSC 52 may copy to the clipboard; nothing in the terminal may read it back.
    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        Files.copy(text)
    }

    func clipboardRead(source: TerminalView) -> Data? { nil }

    func bell(source: TerminalView) {
        if store?.page != .sessions || view.window?.isKeyWindow != true { NSApp.requestUserAttention(.informationalRequest) }
    }
}
