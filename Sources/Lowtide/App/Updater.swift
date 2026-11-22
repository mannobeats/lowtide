import AppKit
import LowtideKit
import SwiftUI

/// Lowtide's own updates (`SelfUpdate`): checked once a day while it runs,
/// unless that's turned off in Settings › General, and on demand from the
/// app menu. A new version is offered, never installed unasked; installing
/// replaces the app in place and relaunches it.
@Observable
final class Updater {
    static let shared = Updater()
    static let autoKey = "updates.automatic"
    private static let lastKey = "updates.lastCheck"
    private static let skippedKey = "updates.skipped"
    private static let interval: TimeInterval = 24 * 60 * 60

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(SelfUpdate.Release)
        /// Downloading and checking the new copy, 0…1.
        case installing(Double)
        case failed(String)
    }

    private(set) var state: State = .idle
    var automatic: Bool {
        didSet { UserDefaults.standard.set(automatic, forKey: Self.autoKey) }
    }
    private(set) var lastCheck: Date?
    private var loop: Task<Void, Never>?

    var available: SelfUpdate.Release? {
        if case .available(let release) = state { return release }
        return nil
    }

    private init() {
        automatic = UserDefaults.standard.object(forKey: Self.autoKey) as? Bool ?? true
        lastCheck = UserDefaults.standard.object(forKey: Self.lastKey) as? Date
    }

    /// At launch: a check when the last one is a day old, then every few hours
    /// whether one is due.
    func launch() {
        guard loop == nil, SelfUpdate.feed != nil else { return }
        loop = Task {
            try? await Task.sleep(for: .seconds(20))
            while !Task.isCancelled {
                if automatic, Date().timeIntervalSince(lastCheck ?? .distantPast) >= Self.interval {
                    await check(quietly: true)
                }
                try? await Task.sleep(for: .seconds(4 * 60 * 60))
            }
        }
    }

    /// Asks GitHub for the latest release. Quietly, a version the person chose
    /// to skip isn't offered again, and only a new one is announced.
    func check(quietly: Bool = false) async {
        guard let feed = SelfUpdate.feed else { return }
        if case .installing = state { return }
        state = .checking
        do {
            let found = try await SelfUpdate.check(feed: feed, installed: SelfUpdate.currentVersion)
            lastCheck = Date()
            UserDefaults.standard.set(lastCheck, forKey: Self.lastKey)
            guard let found else {
                state = .upToDate
                if !quietly { Toasts.shared.show("Lowtide is up to date", detail: "Version \(SelfUpdate.currentVersion)", tone: .neutral) }
                return
            }
            state = .available(found)
            if quietly && UserDefaults.standard.string(forKey: Self.skippedKey) == found.version { return }
            Toasts.shared.show("Lowtide \(found.version) is available", detail: "You have \(SelfUpdate.currentVersion).",
                               action: "Update") { [weak self] in self?.install() }
            if quietly { Notify.post("Lowtide \(found.version) is available", ["Open Lowtide › Check for Updates to install it."]) }
        } catch {
            state = quietly ? .idle : .failed(error.localizedDescription)
            if !quietly { Toasts.shared.failure("Couldn't check for updates", error) }
        }
    }

    /// Not offered again by the daily check (a manual check still shows it).
    func skip() {
        guard let release = available else { return }
        UserDefaults.standard.set(release.version, forKey: Self.skippedKey)
        state = .idle
    }

    /// Installs the available release and relaunches. A copy that can't
    /// replace itself (not signed with a Developer ID, or somewhere it can't
    /// write) opens the release's download instead.
    func install() {
        guard let release = available else { return }
        guard SelfUpdate.canInstall, let team = SelfUpdate.runningTeam, release.archive != nil else {
            NSWorkspace.shared.open(release.diskImage ?? release.page)
            return
        }
        state = .installing(0)
        let installed = Bundle.main.bundleURL
        Task {
            do {
                let app = try await SelfUpdate.install(release, over: installed, team: team) { fraction in
                    Task { @MainActor in
                        if case .installing = Updater.shared.state { Updater.shared.state = .installing(fraction) }
                    }
                }
                relaunch(app)
            } catch {
                state = .available(release)
                Toasts.shared.failure("The update didn't install", error)
            }
        }
    }

    /// Opens the new copy once this one has quit.
    private func relaunch(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, app.path]
        try? process.run()
        NSApp.terminate(nil)
    }
}

/// Settings › General › Updates.
struct UpdateSettingsSection: View {
    @Bindable private var updater = Updater.shared

    var body: some View {
        Section("Updates") {
            Toggle("Check for updates automatically", isOn: $updater.automatic)
            LabeledContent("Version \(SelfUpdate.currentVersion)") {
                switch updater.state {
                case .checking:
                    ProgressView().controlSize(.small)
                case .installing(let fraction):
                    ProgressView(value: fraction).frame(width: 120)
                case .available(let release):
                    HStack {
                        Button("Release Notes") { NSWorkspace.shared.open(release.page) }
                        Button("Update to \(release.version)") { updater.install() }.buttonStyle(.borderedProminent)
                    }
                default:
                    Button("Check Now") { Task { await updater.check() } }
                }
            }
            if let status { Text(status).font(.callout).foregroundStyle(.secondary) }
        }
    }

    private var status: String? {
        switch updater.state {
        case .upToDate: "Lowtide is up to date."
        case .failed(let message): message
        case .available where !SelfUpdate.canInstall:
            "This copy can't replace itself (it isn't a signed release, or its folder isn't writable): Update opens the download."
        default: updater.lastCheck.map { "Last checked \($0.formatted(.relative(presentation: .named)))." }
        }
    }
}

/// "Check for Updates…" in the app menu, under About.
struct UpdateCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Task { await Updater.shared.check() } }
                .disabled(SelfUpdate.feed == nil)
        }
    }
}
