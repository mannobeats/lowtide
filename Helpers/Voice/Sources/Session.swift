import AppKit
import AVFoundation

/// What the app configures (see `voice/mod.rs` `Settings`).
struct Settings {
    /// Off, the helper only downloads models: no shortcut, no microphone.
    var enabled = true
    var shortcut = Shortcut.fallback
    /// "hold" (push to talk), "toggle", or "auto": a quick tap toggles, a
    /// longer press is push to talk.
    var mode = "auto"
    var model: ModelID?
    var modelsDir: URL
    /// ISO code, or nil to detect.
    var language: String?
    var microphone: String?
    /// The stream stays open between takes, for the pre-roll.
    var keepReady = true
    /// System default passes over a Bluetooth input for the built-in mic.
    var avoidBluetooth = true
    var replacements: [(String, String)] = []
    /// Names and jargon to expect.
    var vocabulary: [String] = []
    var fillers = true
    var polish = false
    var sounds = true
    var preview = true

    init?(_ json: [String: Any]) {
        guard let dir = json["modelsDir"] as? String, !dir.isEmpty else { return nil }
        modelsDir = URL(fileURLWithPath: dir, isDirectory: true)
        enabled = json["enabled"] as? Bool ?? true
        shortcut = Shortcut(json["shortcut"]) ?? .fallback
        mode = json["mode"] as? String ?? "auto"
        model = (json["model"] as? String).flatMap(ModelID.init(rawValue:))
        language = (json["language"] as? String).flatMap { $0 == "auto" || $0.isEmpty ? nil : $0 }
        microphone = (json["microphone"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        keepReady = json["keepReady"] as? Bool ?? true
        avoidBluetooth = json["avoidBluetooth"] as? Bool ?? true
        replacements = (json["replacements"] as? [[String]] ?? []).compactMap { pair in
            pair.count == 2 ? (pair[0], pair[1]) : nil
        }
        vocabulary = json["vocabulary"] as? [String] ?? []
        fillers = json["fillers"] as? Bool ?? true
        polish = json["polish"] as? Bool ?? false
        sounds = json["sounds"] as? Bool ?? true
        preview = json["preview"] as? Bool ?? true
    }
}

/// Shortcut → microphone → live preview → final pass → cleanup → into the
/// app. One take records at a time; finished takes queue and go in, in
/// order, while the next one records. Runs on the main thread; the
/// microphone, the tap and the models work on their own.
@MainActor
final class Session {
    static let shared = Session()

    /// The take being recorded.
    private final class Take {
        let pressedAt: UInt64
        /// Recording goes on after the key is let go (toggle, or a quick tap).
        var latched: Bool
        /// Where the text was headed when the take began.
        var focus = Insert.Focus()
        /// The microphone is delivering.
        var ready = false
        /// Let go before the microphone was ready.
        var releasedAt: UInt64?
        /// Waiting for the tail after the release.
        var ending = false
        var cancelled = false
        var preview = ""

        init(pressedAt: UInt64, latched: Bool) {
            self.pressedAt = pressedAt
            self.latched = latched
        }
    }

    /// A take recorded and waiting to be transcribed and put in.
    private struct Job {
        let id: Int
        let samples: [Float]
        let focus: Insert.Focus
        let settings: Settings
        let preview: String
    }

    private var settings: Settings?
    /// Settings that arrived mid-take, applied once it ends.
    private var deferred: Settings?
    private let mic = Microphone()

    private var take: Take?
    /// A press during the previous take's tail, started once it's done.
    private var nextPress: UInt64?
    /// Its release (or loss), also in the tail: replayed on the new take,
    /// which would otherwise record until the next press.
    private var nextRelease: (event: HotkeyEvent, at: UInt64)?
    /// An error from a queued take, hidden while a later one recorded:
    /// shown once that one ends, unless it has a result of its own.
    private var hiddenError: (message: String, extra: [String: Any])?
    private var jobs: [Job] = []
    private var working = false
    private var jobCount = 0
    /// Jobs up to this id were cancelled with Esc.
    private var cancelledThrough = 0

    /// Who holds Secure Event Input, as last told to the app.
    private var blocker: String?
    private var blockerTimer: Timer?

    private var engine: Engine?
    private var engineID: ModelID?
    private var loading: Task<Void, Never>?
    private var unload: Timer?

    private var previewTimer: Timer?
    private var previewBusy = false

    private var download: (id: ModelID, task: Task<Void, Never>)?

    /// Unused this long, the model leaves memory; the next dictation loads
    /// it again while you speak.
    private static let keepLoaded: TimeInterval = 30 * 60
    /// Shorter than this, a hold was a slip of the finger.
    private static let shortest = 0.3
    /// In "auto", a press let go sooner than this was a tap: keep listening.
    private static let tapLimit = 0.35
    /// A take forgotten in toggle mode ends here, rather than holding audio
    /// in memory without end.
    private static let longest: TimeInterval = 10 * 60

    init() {
        Keys.watchLayout()
        Hotkey.shared.onEvent = { [weak self] event, at in
            MainActor.assumeIsolated { self?.hotkey(event, at) }
        }
        Hotkey.shared.onAccess = { [weak self] _ in
            MainActor.assumeIsolated { self?.sendAccess() }
        }
        mic.onLevel = { level in Output.send(["type": "level", "value": Double(level)]) }
    }

    // MARK: Messages

    func handle(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "configure":
            guard let next = Settings(message) else { return }
            if take != nil {
                deferred = next
            } else {
                configure(next)
            }
        case "download":
            if let id = (message["model"] as? String).flatMap(ModelID.init(rawValue:)) { fetch(id) }
        case "cancel-download":
            download?.task.cancel()
        case "record-shortcut":
            Hotkey.shared.start()
            Hotkey.shared.record { shortcut in
                Output.send(["type": "shortcut", "shortcut": shortcut.json, "label": shortcut.label])
            }
        case "stop-recording-shortcut":
            Hotkey.shared.stopRecording()
        case "devices":
            let fallback = Devices.defaultUID()
            Output.send([
                "type": "devices",
                "devices": Devices.all().map {
                    ["uid": $0.uid, "name": $0.name, "isDefault": $0.uid == fallback] as [String: Any]
                },
            ])
        case "status":
            sendAccess()
        case "toggle":
            let now = Clock.now()
            if let take {
                if !take.ending { finish(take, at: now) }
            } else {
                begin(at: now, latched: true)
            }
        case "cancel":
            hotkey(.escape, Clock.now())
        case "paste-last":
            guard let text = message["text"] as? String, !text.isEmpty else { return }
            Insert.pasteLast(text) { [weak self] outcome in self?.report(outcome, text: text) }
        default:
            break
        }
    }

    private func sendAccess() {
        Output.send([
            "type": "access", "shortcut": Hotkey.shared.running, "polish": Text.polishAvailable,
            "fnUsage": Keys.fnUsage() ?? NSNull(),
        ])
    }

    private func configure(_ next: Settings) {
        let before = settings
        settings = next
        Log.event("config", [
            "enabled": next.enabled, "shortcut": next.shortcut.label, "mode": next.mode,
            "model": next.model?.rawValue ?? "",
            "installed": next.model.map { Models.installed($0, in: next.modelsDir) } ?? false,
        ])
        mic.configure(
            device: next.microphone, avoidBluetooth: next.avoidBluetooth,
            keepOpen: next.enabled && next.keepReady)
        guard next.enabled else { return }
        if before?.shortcut != next.shortcut {
            Hotkey.shared.shortcut = next.shortcut
        }
        Hotkey.shared.start()
        watchSecureInput()
        if next.sounds { Chime.prepare() }
        if next.model != engineID || (engine == nil && loading == nil) {
            prepare()
        }
        sendAccess()
    }

    /// Tells the app when Secure Event Input starts or stops hiding the
    /// shortcut, once a second: the key press itself never reaches us then.
    private func watchSecureInput() {
        guard blockerTimer == nil else { return }
        blockerTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let holder = SecureInput.holder()
                guard holder != self.blocker else { return }
                self.blocker = holder
                Output.send(["type": "blocked", "by": holder ?? ""])
            }
        }
    }

    // MARK: Model

    /// Loads the chosen model if it's on disk; keeps it until another is
    /// chosen or it sits unused.
    private func prepare() {
        guard let settings else { return }
        engine = nil
        loading?.cancel()
        loading = nil
        engineID = settings.model
        guard let id = settings.model else { return }
        guard Models.installed(id, in: settings.modelsDir) else {
            Output.send(["type": "model", "model": id.rawValue, "state": "missing"])
            return
        }
        Output.send([
            "type": "model", "model": id.rawValue, "state": "loading",
            // Phonon-2's first load, once per Mac, sits here for a minute or two.
            "message": id == .phonon2 ? "Loading… The first time readies it for the Neural Engine: a minute or two." : "",
        ])
        let dir = settings.modelsDir
        loading = Task { [weak self] in
            do {
                let engine = try await Models.load(id, from: dir)
                guard let self, self.engineID == id else { return }
                self.engine = engine
                self.loading = nil
                self.keepWarm()
                Output.send(["type": "model", "model": id.rawValue, "state": "ready"])
            } catch {
                guard let self, self.engineID == id else { return }
                self.loading = nil
                Output.send([
                    "type": "model", "model": id.rawValue, "state": "error",
                    "message": error.localizedDescription,
                ])
            }
        }
    }

    private func keepWarm() {
        unload?.invalidate()
        unload = Timer.scheduledTimer(withTimeInterval: Session.keepLoaded, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.take == nil, self.jobs.isEmpty, let id = self.engineID else { return }
                self.engine = nil
                Output.send(["type": "model", "model": id.rawValue, "state": "asleep"])
            }
        }
    }

    private func fetch(_ id: ModelID) {
        guard let settings, download == nil else { return }
        let dir = settings.modelsDir
        let task = Task { [weak self] in
            let ticker = Ticker()
            do {
                try await Models.download(id, into: dir) { progress in
                    // A tick per half percent is plenty for a progress bar.
                    guard ticker.due(progress) else { return }
                    Output.send(["type": "download", "model": id.rawValue, "progress": progress, "done": false])
                }
                Output.send(["type": "download", "model": id.rawValue, "progress": 1.0, "done": true])
                self?.download = nil
                if self?.settings?.model == id { self?.prepare() }
            } catch {
                let message = error is CancellationError || (error as? URLError)?.code == .cancelled
                    ? "" : error.localizedDescription
                Output.send([
                    "type": "download", "model": id.rawValue, "progress": 0.0, "done": false, "error": message,
                ])
                self?.download = nil
            }
        }
        download = (id, task)
    }

    // MARK: Shortcut

    private func hotkey(_ event: HotkeyEvent, _ at: UInt64) {
        let mode = settings?.mode ?? "auto"
        switch event {
        case .press:
            if let take {
                if take.ending {
                    nextPress = at
                    nextRelease = nil
                } else if take.latched {
                    finish(take, at: at)
                }
            } else {
                begin(at: at, latched: mode == "toggle")
            }
        case .release:
            guard let take else { return }
            if take.ending, nextPress != nil { nextRelease = (event, at) }
            guard !take.latched, !take.ending else { return }
            if mode == "auto" && Clock.seconds(take.pressedAt, at) < Session.tapLimit {
                take.latched = true
            } else if mode != "toggle" {
                finish(take, at: at)
            }
        case .lost:
            // The release never came (or the tap was down): end the hold.
            guard let take else { return }
            if take.ending, nextPress != nil { nextRelease = (event, at) }
            guard !take.latched, !take.ending else { return }
            finish(take, at: at)
        case .interrupted:
            // Right ⌥ + E typed an accent: that was never meant as dictation.
            guard let take, !take.latched, !take.ending, Clock.seconds(take.pressedAt, at) < 0.6 else { return }
            cancel(take, quietly: true)
        case .escape:
            if let take {
                if take.ending { take.cancelled = true } else { cancel(take, quietly: false) }
            } else if !jobs.isEmpty {
                cancelledThrough = jobCount
                Hotkey.shared.capturingEscape = false
                Output.state("idle", "Cancelled")
            }
        }
    }

    // MARK: Recording

    private func begin(at press: UInt64, latched: Bool) {
        guard let settings, settings.enabled else {
            Log.event("take", ["action": "skipped", "reason": settings == nil ? "unconfigured" : "disabled"])
            return
        }
        guard let id = settings.model, Models.installed(id, in: settings.modelsDir) else {
            fail("no-model", "Pick and download a model in Lowtide → Extensions → Dictation.",
                 action: settings.model == nil ? "open-settings" : "download-model")
            return
        }
        guard AXIsProcessTrusted() else {
            fail("permission", "Allow Accessibility for Lowtide so dictation can type into apps.",
                 action: "allow-accessibility")
            return
        }
        if engine == nil && loading == nil { prepare() }
        let take = Take(pressedAt: press, latched: latched)
        self.take = take
        Hotkey.shared.capturingEscape = true
        emitState()
        defer {
            // After the microphone is on its way: these can take a moment.
            Clipboard.shared.prepare()
            take.focus = Insert.focus()
        }
        mic.begin(at: press) { [weak self] failure in
            guard let self else { return }
            guard self.take === take else {
                // Cancelled while it opened. A newer take already has the
                // microphone: ending it here would end that one.
                if self.take == nil { self.mic.end(at: nil) { _ in } }
                return
            }
            if let failure {
                self.take = nil
                Hotkey.shared.capturingEscape = !self.jobs.isEmpty
                let allowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                self.fail("mic", allowed ? failure : "Lowtide isn't allowed to use the microphone.",
                          action: allowed ? "open-settings" : "allow-microphone")
                self.afterTake()
                return
            }
            take.ready = true
            Log.event("take", ["action": "ready", "ms": Int(Clock.seconds(press, Clock.now()) * 1000)])
            // The chime, cut from what's transcribed: it played over the start.
            if settings.sounds, let at = Chime.play() {
                self.mic.exclude(from: at, to: at + UInt64(Chime.audible * 1e9))
            }
            self.emitState()
            if let released = take.releasedAt {
                self.finish(take, at: released)
                return
            }
            Timer.scheduledTimer(withTimeInterval: Session.longest, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let take = self.take, take.pressedAt == press, !take.ending else { return }
                    Log.event("take", ["action": "limit", "seconds": Session.longest])
                    self.finish(take, at: Clock.now())
                }
            }
            if settings.preview {
                self.previewTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tickPreview() }
                }
            }
        }
    }

    /// The words so far, re-read from the audio while there's time: the
    /// whole take while it's short, its last stretch once it's long. Not
    /// while an earlier take is being transcribed: that one comes first.
    private func tickPreview() {
        guard let take, take.ready, !take.ending, !previewBusy, !working, let engine, let settings else { return }
        let seconds = mic.seconds
        guard seconds > 0.5 else { return }
        let long = seconds > 30
        let audio = mic.snapshot(last: long ? 20 : nil)
        previewBusy = true
        let language = settings.language
        let context = settings.vocabulary.joined(separator: ", ")
        Task { [weak self] in
            let text = (try? await engine.transcribe(audio, language: language, context: context)) ?? ""
            guard let self else { return }
            self.previewBusy = false
            let shown = (long ? "… " : "") + text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard self.take === take, !take.ending, !text.isEmpty, shown != take.preview,
                  !Text.echoes(text, vocabulary: settings.vocabulary) else { return }
            take.preview = shown
            Output.send(["type": "preview", "text": shown])
        }
    }

    private func finish(_ take: Take, at release: UInt64) {
        guard self.take === take, !take.ending else { return }
        guard take.ready else {
            take.releasedAt = release
            return
        }
        take.ending = true
        previewTimer?.invalidate()
        previewTimer = nil
        let held = Clock.seconds(take.pressedAt, release)
        if !take.latched && held < Session.shortest {
            cancel(take, quietly: true)
            return
        }
        if take.releasedAt != nil {
            // Let go before the microphone had anything to give.
            mic.end(at: nil) { _ in }
            self.take = nil
            fail("mic", "The microphone was still starting. Hold a moment longer, or turn on Keep microphone ready.",
                 action: "open-settings")
            afterTake()
            return
        }
        mic.end(at: release) { [weak self] samples in
            guard let self else { return }
            self.take = nil
            let seconds = Double(samples.count) / Microphone.rate
            Log.event("take", ["action": "end", "heldMs": Int(held * 1000), "seconds": seconds])
            if take.cancelled {
                if self.jobs.isEmpty { Output.state("idle", "Cancelled") }
            } else if Audio.dead(samples) {
                self.mic.reopen()
                self.terminal("empty", "The microphone sent no sound. Check it in Extensions → Dictation.")
            } else if seconds < Session.shortest || Audio.silent(samples) {
                // Nothing said: the pill just goes, as in Hex.
                Log.event("take", ["action": "silent"])
                self.terminal("idle", "")
            } else if let settings = self.settings {
                self.jobCount += 1
                self.jobs.append(Job(
                    id: self.jobCount, samples: samples, focus: take.focus, settings: settings,
                    preview: take.preview))
            }
            self.afterTake()
            self.work()
            self.emitState()
        }
    }

    private func cancel(_ take: Take, quietly: Bool) {
        previewTimer?.invalidate()
        previewTimer = nil
        mic.end(at: nil) { _ in }
        self.take = nil
        if jobs.isEmpty {
            Output.state("idle", quietly ? "" : "Cancelled")
        }
        afterTake()
        emitState()
    }

    /// Between takes: settings held back, a press made during the tail.
    private func afterTake() {
        Hotkey.shared.capturingEscape = !jobs.isEmpty
        if let deferred {
            self.deferred = nil
            configure(deferred)
        }
        if let press = nextPress {
            let release = nextRelease
            nextPress = nil
            nextRelease = nil
            begin(at: press, latched: settings?.mode == "toggle")
            if let release { hotkey(release.event, release.at) }
        }
    }

    // MARK: Transcribing

    /// The oldest take, transcribed and put in; then the next.
    private func work() {
        guard !working, let job = jobs.first else { return }
        working = true
        Hotkey.shared.capturingEscape = true
        let pending = loading
        Task { [weak self] in
            await pending?.value
            guard let self else { return }
            await self.run(job)
            self.jobs.removeFirst()
            self.working = false
            Hotkey.shared.capturingEscape = self.take != nil || !self.jobs.isEmpty
            self.work()
            self.emitState()
        }
    }

    private func run(_ job: Job) async {
        let settings = job.settings
        let began = Date()
        guard job.id > cancelledThrough else { return }
        guard let engine else {
            fail("model-loading", "The model couldn't load. See Extensions → Dictation.", action: "open-settings")
            return
        }
        do {
            var raw = try await engine.transcribe(
                job.samples, language: settings.language, context: settings.vocabulary.joined(separator: ", "))
            if Text.echoes(raw, vocabulary: settings.vocabulary) {
                Log.event("transcribed", ["action": "dropped-echo"])
                raw = ""
            }
            var text = Text.clean(raw, removeFillers: settings.fillers, replacements: settings.replacements)
            if settings.polish && !text.isEmpty {
                text = await Text.polish(text, vocabulary: settings.vocabulary)
            }
            let transcribed = Date()
            guard job.id > cancelledThrough else { return }
            guard !text.isEmpty else {
                terminal("idle", "")
                return
            }
            let outcome = await withCheckedContinuation { continuation in
                Insert.deliver(text, from: job.focus) { continuation.resume(returning: $0) }
            }
            Log.event("transcribed", [
                "model": settings.model?.rawValue ?? "", "seconds": Double(job.samples.count) / Microphone.rate,
                "transcribeMs": Int(transcribed.timeIntervalSince(began) * 1000),
            ])
            Output.send([
                "type": "result", "text": text, "raw": raw, "app": outcome.app, "bundleId": outcome.bundle,
                "model": settings.model?.rawValue ?? "", "seconds": Double(job.samples.count) / Microphone.rate,
                "elapsedMs": Int(Date().timeIntervalSince(began) * 1000),
                "typed": outcome.method != nil && outcome.method != "copied",
                "secure": outcome.kind == "secure-input" && outcome.method == nil,
                "method": outcome.method ?? "",
            ])
            report(outcome, text: text)
        } catch {
            fail("model-loading", error.localizedDescription, action: "open-settings")
        }
    }

    /// How the text went in, for the overlay.
    private func report(_ outcome: Insert.Outcome, text: String) {
        if let kind = outcome.kind {
            let action: String? = switch kind {
            case "permission": "allow-accessibility"
            case "secure-input" where outcome.method == nil: nil
            default: "paste-last"
            }
            var extra: [String: Any] = ["text": text, "app": outcome.app]
            if let method = outcome.method { extra["method"] = method }
            fail(kind, outcome.message, action: action, extra: extra)
            return
        }
        var message = outcome.message
        if message.isEmpty, outcome.moved, !outcome.app.isEmpty { message = "Went to \(outcome.app)" }
        terminal("done", message, ["method": outcome.method ?? "copied", "app": outcome.app, "text": text])
    }

    // MARK: State

    /// What the overlay should show while something's under way.
    private func emitState() {
        if let take {
            let message = engine == nil ? "Loading the model…" : ""
            Output.state(take.ready ? "recording" : "listening", message, queued(jobs.count))
        } else if let hidden = hiddenError {
            hiddenError = nil
            Output.state("error", hidden.message, hidden.extra.merging(queued(jobs.count)) { _, new in new })
        } else if let job = jobs.first(where: { $0.id > cancelledThrough }) {
            Output.state("transcribing", job.preview, queued(jobs.count - 1))
        }
    }

    private func queued(_ count: Int) -> [String: Any] {
        count > 0 ? ["queued": count] : [:]
    }

    /// done, empty or error. Not while a take records: its pill stays up,
    /// and the result is still kept; an error waits for the take to end.
    private func terminal(_ phase: String, _ message: String, _ extra: [String: Any] = [:]) {
        keepWarm()
        guard take == nil else {
            Log.event("state-hidden", ["phase": phase, "kind": extra["kind"] ?? ""])
            if phase == "error" { hiddenError = (message, extra) }
            return
        }
        // The ended take's own result: it stands over an older error.
        hiddenError = nil
        Output.state(phase, message, extra.merging(queued(max(0, jobs.count - 1))) { _, new in new })
    }

    private func fail(_ kind: String, _ message: String, action: String?, extra: [String: Any] = [:]) {
        var extra = extra
        extra["kind"] = kind
        if let action { extra["action"] = action }
        Log.event("error", ["kind": kind])
        terminal("error", message, extra)
    }
}

/// Lets a progress callback speak up only every half percent.
private final class Ticker: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1.0

    func due(_ progress: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard progress - last >= 0.005 || progress >= 1 else { return false }
        last = progress
        return true
    }
}
