import AppKit
import LowtideKit
import SwiftUI

/// Dictation: hold (or tap) a shortcut, speak, and the words are typed into
/// the app you're in, recognised on this Mac. The `lowtide-voice` helper owns
/// the shortcut, the microphone, the models and the typing; this side keeps
/// it running with the page's settings, relays what it says to the overlay
/// and the page, keeps history and stats, and moves models to the Trash. No
/// audio is ever written to disk: the helper keeps it in memory until it's
/// transcribed.
@Observable
final class Dictation {
    static let shared = Dictation()
    static let enabledKey = "extension.dictation"
    /// The Extensions gallery (or an extension's page) turned one on or off.
    static let extensionsChanged = Notification.Name("Lowtide.extensionsChanged")
    private static let prefsKey = "dictation.prefs"

    /// The extension is on (the Extensions gallery or this page turns it).
    private(set) var enabled = ExtensionState.isOn(.dictation)
    var prefs: VoicePrefs {
        didSet {
            guard prefs != oldValue else { return }
            save()
            if HistoryRules(prefs) != HistoryRules(oldValue) { Task { await refreshHistory() } }
            configure()
        }
    }
    private(set) var status = VoiceStatus()
    /// What the overlay shows, as the helper last said.
    private(set) var state = VoiceState.idle
    /// The words heard so far in this take.
    private(set) var preview = ""
    /// The voice's loudness, read by the overlay's frame loop (not observed).
    let level = LevelFeed()
    private(set) var history: [DictationEntry] = []
    private(set) var historyLoaded = false
    private(set) var stats = DictationStats()
    private(set) var devices: [VoiceDevice] = []
    private(set) var installed: Set<String> = []
    private(set) var recordingShortcut = false
    @ObservationIgnored private var escMonitor: Any?
    /// The latest dictation, kept or not, for Paste and Copy last dictation.
    private(set) var last: String?

    private var helper: VoiceHelper?
    private var restarts = RestartPolicy()
    private var restartTask: Task<Void, Never>?
    /// Bumped by every state: idle follows a finished one only if none came since.
    private var turn = 0
    /// Set once a take gives text, so an error after it isn't a failure.
    private var resulted = false
    private let historyStore = DictationHistory()
    private let statsStore: DictationStatsStore

    private init() {
        let saved = UserDefaults.standard.data(forKey: Self.prefsKey)
        prefs = saved.flatMap { try? JSONDecoder().decode(VoicePrefs.self, from: $0) } ?? VoicePrefs()
        statsStore = DictationStatsStore(history: historyStore)
        status.available = VoicePaths.helper != nil
        refreshInstalled()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(prefs) { UserDefaults.standard.set(data, forKey: Self.prefsKey) }
    }

    // MARK: On and off

    /// Follows `extension.dictation`: starts the helper with the settings,
    /// or stops it and puts the overlay away.
    func sync() {
        enabled = ExtensionState.isOn(.dictation)
        if enabled {
            configure()
            Task {
                await refreshHistory()
                await refreshStats()
                if last == nil { last = await historyStore.newest() }
            }
        } else {
            restartTask?.cancel()
            restartTask = nil
            stopHelper()
            setState(.idle)
            VoiceOverlay.shared.remove()
        }
    }

    /// Turns the extension on or off, as the gallery does.
    func setEnabled(_ on: Bool) {
        ExtensionState.set(.dictation, on)
        NotificationCenter.default.post(name: Self.extensionsChanged, object: nil)
        if on, Permission.microphone.state == .unknown { Permission.microphone.request() }
    }

    func stop() {
        restartTask?.cancel()
        stopHelper()
    }

    // MARK: The helper

    /// Starts the helper if needed (configured as it starts); one already
    /// running hears of the change.
    private func configure() {
        guard enabled || helper?.isRunning == true else { return }
        do {
            if try !ensureHelper() { try helper?.send(configureLine()) }
        } catch {
            Log.voice.error("configure failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func configureLine() -> Data {
        prefs.configureLine(enabled: enabled, modelsDir: VoicePaths.models)
    }

    /// True when a new helper started (it got the settings first).
    @discardableResult
    private func ensureHelper() throws -> Bool {
        guard let executable = VoicePaths.helper else {
            throw LowtideError.notFound("Dictation in this build")
        }
        if helper == nil {
            helper = VoiceHelper(
                executable: executable,
                onMessage: { message in
                    DispatchQueue.main.async { MainActor.assumeIsolated { Dictation.shared.handle(message) } }
                },
                onExit: { pid, code in
                    DispatchQueue.main.async { MainActor.assumeIsolated { Dictation.shared.helperEnded(pid, code) } }
                })
        }
        let started = try helper?.start(first: configureLine()) ?? false
        if started {
            status.running = true
            Log.voice.info("helper started")
        }
        return started
    }

    /// Sends a command, starting the helper for it if need be.
    private func send(_ line: Data) throws {
        try ensureHelper()
        try helper?.send(line)
    }

    private func stopHelper() {
        helper?.stop()
        status.stopped()
    }

    private func helperEnded(_ pid: Int32, _ code: Int32) {
        guard let helper, helper.isCurrent(pid) else { return }
        helper.ended(pid)
        let busy = status.phase != .idle
        status.stopped()
        Log.voice.error("helper ended with \(code, privacy: .public)")
        // Mid-dictation, say so; otherwise just reset the overlay.
        setState(busy ? VoiceState(phase: .error, message: "Dictation stopped unexpectedly. It's starting again.",
                                   kind: "helper") : .idle)
        guard enabled else { return }
        let (wait, slow) = restarts.next()
        if slow {
            status.modelState = .error
            status.modelMessage = "Dictation stopped unexpectedly. Trying again in a minute."
        }
        restartTask?.cancel()
        restartTask = Task {
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, self.enabled else { return }
            self.configure()
        }
    }

    // MARK: What the helper says

    private func handle(_ message: HelperMessage) {
        switch message {
        case .state(let next):
            switch next.phase {
            case .listening: resulted = false
            case .empty: Task { await statsStore.change { $0.empty += 1 }; await refreshStats() }
            // A password field refusing the text still gave a result.
            case .error where !resulted: Task { await statsStore.change { $0.failed += 1 }; await refreshStats() }
            default: break
            }
            setState(next)
        case .level(let value):
            level.value = value
        case .preview(let text):
            preview = text
        case .result(let result):
            resulted = true
            if !result.text.isEmpty { last = result.text }
            Task {
                await statsStore.count(result)
                if prefs.history { await historyStore.remember(result, rules: HistoryRules(prefs)) }
                await refreshHistory()
                await refreshStats()
            }
        case .download(_, _, let done, _):
            status.apply(message)
            if done { refreshInstalled() }
        case .shortcut(let shortcut, let label):
            guard recordingShortcut else { return }
            recordShortcut(false)
            prefs.shortcut = shortcut
            prefs.shortcutLabel = label
        case .devices(let list):
            devices = list
        default:
            status.apply(message)
        }
    }

    /// Records a state; a finished one is followed by idle once it's been
    /// shown, unless another state came first.
    private func setState(_ next: VoiceState) {
        turn += 1
        let mine = turn
        // A new take starts with no words.
        if next.phase == .listening || (next.phase == .recording && state.phase != .recording) { preview = "" }
        if next.phase != .recording { level.value = 0 }
        state = next
        status.phase = next.phase
        status.message = next.message
        VoiceOverlay.shared.update()
        if let wait = next.shownFor {
            Task {
                try? await Task.sleep(for: wait)
                if self.turn == mine { self.setState(.idle) }
            }
        }
    }

    // MARK: Actions

    /// Starts or finishes a dictation without the shortcut.
    func toggle() {
        guard enabled else {
            Toasts.shared.show("Turn on Dictation first", detail: "Extensions › Dictation", tone: .warn)
            AppModel.shared.show(.dictation)
            return
        }
        do { try send(VoiceLine.command("toggle")) } catch { Toasts.shared.failure("Dictation didn't start", error) }
    }

    /// Puts the latest dictation into the app in front, or the one behind
    /// Lowtide when Lowtide is in front.
    func pasteLast() {
        guard let last else {
            Toasts.shared.show("Nothing has been dictated yet", tone: .warn)
            return
        }
        do { try send(VoiceLine.command("paste-last", ["text": last])) } catch {
            Toasts.shared.failure("Couldn't paste", error)
        }
    }

    /// The latest dictation on the clipboard, for when it didn't land where
    /// it should.
    func copyLast() {
        guard let last else { return }
        Files.copy(last)
    }

    /// An error's action, clicked on the overlay or the page.
    func run(_ action: VoiceAction) {
        switch action {
        case .openSettings, .downloadModel: AppModel.shared.show(.dictation)
        case .allowAccessibility: Permission.accessibility.request()
        case .allowMicrophone: Permission.microphone.request()
        case .pasteLast: pasteLast()
        }
    }

    /// Asks for the shortcut's access state and anything else that may have
    /// changed while the page was away.
    func refreshStatus() {
        guard enabled else { return }
        try? helper?.send(VoiceLine.command("status"))
        refreshInstalled()
    }

    func loadDevices() {
        guard enabled else { return }
        try? send(VoiceLine.command("devices"))
    }

    func recordShortcut(_ on: Bool) {
        recordingShortcut = on
        escMonitor.map(NSEvent.removeMonitor)
        escMonitor = nil
        do { try send(VoiceLine.command(on ? "record-shortcut" : "stop-recording-shortcut")) } catch {
            recordingShortcut = false
            Toasts.shared.failure("Couldn't record a shortcut", error)
            return
        }
        // Esc cancels, as in every shortcut field on the Mac (the helper lets it through).
        guard on else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { Dictation.shared.recordShortcut(false) }
            return nil
        }
    }

    // MARK: Models

    func refreshInstalled() {
        installed = Set(VoiceModelInfo.all.map(\.id).filter { VoicePaths.installed($0) })
    }

    func download(_ id: String) {
        prefs.model = id
        status.download = VoiceStatus.Download(model: id, progress: 0)
        do { try send(VoiceLine.command("download", ["model": id])) } catch {
            status.download = nil
            Toasts.shared.failure("The download didn't start", error)
        }
    }

    func cancelDownload() {
        try? helper?.send(VoiceLine.command("cancel-download"))
    }

    /// Moves a downloaded model to the Trash; the helper lets go of it.
    func remove(_ id: String) {
        let folder = VoicePaths.folder(id)
        Task {
            let refused = await Trash.move([folder.path]).refused
            refreshInstalled()
            if let refusal = refused.first {
                Toasts.shared.show("Couldn't move it to the Trash", detail: refusal.reason, tone: .bad)
                return
            }
            configure()
            let name = VoiceModelInfo.named(id)?.name ?? id
            Toasts.shared.show("Moved \(name) to the Trash", action: "Show in Trash") {
                NSWorkspace.shared.open(Paths.home.appending(path: ".Trash"))
            }
        }
    }

    // MARK: History and stats

    func refreshHistory() async {
        history = await historyStore.tidy(HistoryRules(prefs))
        historyLoaded = true
    }

    func refreshStats() async {
        stats = await statsStore.load()
    }

    /// Forgets one entry, or all of them.
    func forget(_ id: Int64?) {
        Task {
            await historyStore.forget(id)
            await refreshHistory()
        }
    }

    /// Stops keeping history and forgets what was kept. Stats keep counting.
    func stopHistory() {
        prefs.history = false
        forget(nil)
    }

    func leaveOut(_ entry: DictationEntry) {
        guard !entry.bundleId.isEmpty, !prefs.excludedIDs.contains(entry.bundleId) else { return }
        prefs.excluded.append(LeftOutApp(bundleId: entry.bundleId, name: entry.app.isEmpty ? entry.bundleId : entry.app))
    }

    func resetStats() {
        Task {
            await statsStore.reset()
            await refreshStats()
        }
    }

    // MARK: Diagnostics

    func revealLog() {
        let log = VoicePaths.log
        if FileManager.default.fileExists(atPath: log.path) {
            NSWorkspace.shared.activateFileViewerSelecting([log])
        } else {
            let folder = log.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
    }

    func copyReport() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let log = (try? String(contentsOf: VoicePaths.log, encoding: .utf8)) ?? ""
        let report = VoiceDiagnostics.report(
            version: version, os: ProcessInfo.processInfo.operatingSystemVersionString, prefs: prefs, status: status,
            stderr: helper?.stderrTail ?? [], log: log)
        Files.copy(report)
        Toasts.shared.show("Copied the dictation report", detail: "It holds settings and timings, never what you said.")
    }
}

/// The voice's loudness, written ~30 times a second and read by the
/// overlay's frame loop: kept out of observation so it never re-renders views.
final class LevelFeed {
    var value = 0.0
}
