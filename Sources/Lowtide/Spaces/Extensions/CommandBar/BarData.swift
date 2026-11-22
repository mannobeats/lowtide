import LowtideKit
import SwiftUI

/// What other spaces lend the command bar. Each is wired at launch by the
/// space that owns the data; until then the bar simply has none of it.
enum CommandBarHooks {
    /// Keep awake, brightness, extra brightness, microphone, sound output,
    /// colour picker (System's tools).
    static var quickControls: any QuickControls = NoQuickControls()

    /// A saved server the bar connects to in a terminal tab (Remote › Hosts).
    struct Host {
        var id: String
        var name: String
        /// `user@hostname`.
        var address: String
        var connect: @MainActor () -> Void
    }

    static var hosts: @MainActor () -> [Host] = { [] }

    /// What the network monitor sees right now (Network).
    struct WatchFacts {
        var rateIn: Double, rateOut: Double
        var todayIn: Int64, todayOut: Int64
        var alerts: Int
        var lastAlert: String?
    }

    static var watchFacts: @MainActor () -> WatchFacts? = { nil }
}

/// Everything the bar shows, loaded when it opens and kept while it's open.
/// Nothing polls while the bar is closed. Shared by the floating bar and ⌘K.
@Observable
final class BarData {
    static let shared = BarData()

    var apps: [LaunchableApp] = []
    var running: [RunningApp] = []
    var facts: MacFacts?
    var quick: QuickControlsState?
    var panes: [SettingsPane] = []
    var folders: [StandardFolders.Folder] = []
    var emoji: [Emoji] = []
    var processes: [Processes.Info] = []
    var listeners: [LocalServices.Listener] = []
    var hosts: [CommandBarHooks.Host] = []
    var watch: CommandBarHooks.WatchFacts?
    /// Bumped whenever any of the above changes, so rows rebuild once.
    private(set) var version = 0

    private var loadedOnce = false
    private var loadingEmoji = false

    /// Fresh data for an opening. The last opening's data stays until the
    /// fresh answers land, so rows never blink out and push the list around.
    func refresh() {
        running = RunningApps.list()
        hosts = CommandBarHooks.hosts()
        watch = CommandBarHooks.watchFacts()
        version += 1
        if !loadedOnce {
            loadedOnce = true
            Task.detached(priority: .userInitiated) {
                let panes = SettingsPanes.all()
                let folders = StandardFolders.all()
                await MainActor.run {
                    self.panes = panes
                    self.folders = folders
                    self.version += 1
                }
            }
        }
        Task {
            let apps = await AppIndex.shared.list()
            self.apps = apps
            self.version += 1
        }
        Task {
            let facts = await MacFacts.read()
            self.facts = facts
            self.version += 1
        }
        Task {
            let quick = await CommandBarHooks.quickControls.state()
            self.quick = quick
            self.version += 1
        }
    }

    /// The emoji catalog, built once when first wanted (and once only while it loads).
    func wantEmoji() {
        guard emoji.isEmpty, !loadingEmoji else { return }
        loadingEmoji = true
        Task.detached(priority: .userInitiated) {
            let all = EmojiCatalog.all
            await MainActor.run {
                self.emoji = all
                self.version += 1
            }
        }
    }

    /// Processes and listening ports, fresh, for the Processes view.
    func wantProcesses() {
        Task.detached(priority: .userInitiated) {
            let processes = Processes.own()
            await MainActor.run {
                self.processes = processes
                self.version += 1
            }
        }
        Task {
            let listeners = await LocalServices.list()
            self.listeners = listeners
            self.version += 1
        }
    }

    func refreshQuick() {
        Task {
            let quick = await CommandBarHooks.quickControls.state()
            self.quick = quick
            self.version += 1
        }
    }
}

/// One question and its answer.
struct AskExchange: Identifiable {
    enum State { case looking, writing, done, failed, stopped }

    let id: Int
    var question: String
    var answer = ""
    var state = State.looking
    var lookups: [(name: String, arguments: AskArguments)] = []
    var error: String?
    let startedAt = Date()
    var endedAt: Date?

    var running: Bool { state == .looking || state == .writing }
}

/// Ask's conversation, shared by every surface that shows it.
@Observable
final class AskConversation {
    static let shared = AskConversation()

    private(set) var exchanges: [AskExchange] = []
    private(set) var availability: AskEngine.Availability?
    private var conversation = UUID().uuidString
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var nextID = 1

    var running: Bool { exchanges.contains(where: \.running) }

    func checkAvailability() {
        availability = AskEngine.availability()
        if availability?.available == true { Task { await AskEngine.shared.prewarm() } }
    }

    func ask(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        stop()
        let id = nextID
        nextID += 1
        exchanges.append(AskExchange(id: id, question: question))
        let stream = AskEngine.shared.ask(question, conversation: conversation)
        tasks[id] = Task { [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { return }
                self.apply(event, to: id)
            }
            self?.tasks[id] = nil
        }
    }

    private func apply(_ event: AskEvent, to id: Int) {
        guard let at = exchanges.firstIndex(where: { $0.id == id }), exchanges[at].state != .stopped else { return }
        switch event {
        case .tool(let name, let arguments):
            exchanges[at].lookups.append((name, arguments))
        case .partial(let text):
            exchanges[at].answer = text
            exchanges[at].state = .writing
        case .done(let text):
            exchanges[at].answer = text
            exchanges[at].state = .done
            exchanges[at].endedAt = .now
        case .failed(let message):
            exchanges[at].error = message
            exchanges[at].state = .failed
            exchanges[at].endedAt = .now
        }
    }

    /// Stops following the running answer; what's written so far stays.
    func stop() {
        for index in exchanges.indices where exchanges[index].running {
            exchanges[index].state = .stopped
            exchanges[index].endedAt = .now
            tasks[exchanges[index].id]?.cancel()
            tasks[exchanges[index].id] = nil
        }
    }

    /// Asks the question an answer belongs to again.
    func again(_ id: Int) {
        if let question = exchanges.first(where: { $0.id == id })?.question { ask(question) }
    }

    /// Starts over: the model forgets the conversation.
    func reset() {
        stop()
        let old = conversation
        Task { await AskEngine.shared.reset(old) }
        conversation = UUID().uuidString
        exchanges = []
    }
}
