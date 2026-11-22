import LowtideKit
import SwiftUI

/// The receipts every runs view shows (Install watch, Developer › History):
/// finished runs from the engine, and what it follows right now, polled
/// once a second only while a runs view is on screen.
@Observable
final class RunsStore {
    static let shared = RunsStore()

    private(set) var runs: [Run] = []
    private(set) var following: [ActiveRun] = []
    private(set) var loaded = false
    /// A run to show when a runs view next appears (a terminal's receipt,
    /// the overnight report).
    var focus: UInt64?
    private var watchers = 0
    private var poll: Task<Void, Never>?

    var installs: [Run] { runs.filter { $0.ecosystem != nil } }

    func reload() async {
        runs = await RunEngine.shared.list()
        following = await RunEngine.shared.following()
        loaded = true
    }

    /// A finished run arrived.
    func add(_ run: Run) {
        runs.removeAll { $0.id == run.id }
        runs.insert(run, at: 0)
        following.removeAll { $0.id == run.id }
    }

    /// A runs view appeared: keep "Following now" live while it shows.
    func watch() {
        watchers += 1
        guard poll == nil else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let now = await RunEngine.shared.following()
                if now != self.following { self.following = now }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func unwatch() {
        watchers = max(watchers - 1, 0)
        if watchers == 0 {
            poll?.cancel()
            poll = nil
        }
    }

    func clear() async {
        await RunEngine.shared.clear()
        runs = []
    }

    /// Stops a process a run left behind.
    func stop(_ child: RunChild) async {
        do {
            try await RunEngine.shared.stopLeftBehind(pid: child.pid, force: false)
            Toasts.shared.show("Stopped \(child.name)")
        } catch {
            Toasts.shared.failure("Couldn't stop \(child.name)", error)
        }
    }
}
