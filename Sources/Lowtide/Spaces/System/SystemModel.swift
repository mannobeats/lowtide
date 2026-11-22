import AppKit
import LowtideKit
import SwiftUI

/// The live machine for every space: the latest sample, ten minutes of
/// history for charts and sparklines, the slow detail (sensors, fans,
/// battery) and, when asked, the process list.
///
/// It samples only while something needs it. A consumer says so with
/// `retain("home")` and stops with `release("home")`; pages use
/// `.systemFeed(...)`, which also pauses while their window is hidden.
@Observable
final class SystemModel {
    static let shared = SystemModel()

    /// What a consumer needs: the metrics (always), and the process table
    /// (a heavier read, every 2 s).
    struct Feeds: OptionSet, Hashable {
        let rawValue: Int
        static let metrics = Feeds(rawValue: 1)
        static let processes = Feeds(rawValue: 2)
    }

    /// Ten minutes at one sample a second.
    static let historyLength = 600
    /// A minute of each process's CPU while watching.
    static let processHistoryLength = 60

    private(set) var chip: ChipInfo?
    private(set) var latest: SystemSample?
    private(set) var samples: [SystemSample] = []
    private(set) var detail: SystemDetail?
    /// nil until the first list arrives.
    private(set) var processes: [ProcessRow]?
    private(set) var processHistory: [Int32: [Double]] = [:]

    private var reasons: [String: Feeds] = [:]
    private var metricsTask: Task<Void, Never>?
    private var processTask: Task<Void, Never>?
    private let monitor = SystemMonitor.shared

    var isSampling: Bool { metricsTask != nil }

    /// The busiest processes by CPU (needs the `.processes` feed).
    func topProcesses(_ count: Int = 5) -> [ProcessRow] {
        Array((processes ?? []).sorted { $0.cpu > $1.cpu }.prefix(count))
    }

    /// The last `count` values of one measure, oldest first.
    func series(_ value: (SystemSample) -> Double, last count: Int = historyLength) -> [Double] {
        samples.suffix(count).map(value)
    }

    // MARK: Demand

    /// Starts sampling for `reason` (idempotent per reason).
    func retain(_ reason: String, _ feeds: Feeds = .metrics) {
        reasons[reason] = feeds.union(.metrics)
        update()
    }

    func release(_ reason: String) {
        reasons[reason] = nil
        update()
    }

    private var wanted: Feeds { reasons.values.reduce(into: Feeds()) { $0.formUnion($1) } }

    private func update() {
        let wanted = wanted
        if wanted.contains(.metrics), metricsTask == nil {
            metricsTask = Task { [weak self] in await self?.runMetrics() }
        } else if !wanted.contains(.metrics), let task = metricsTask {
            task.cancel()
            metricsTask = nil
        }
        if wanted.contains(.processes), processTask == nil {
            processTask = Task { [weak self] in await self?.runProcesses() }
        } else if !wanted.contains(.processes), let task = processTask {
            task.cancel()
            processTask = nil
        }
    }

    // MARK: Loops

    private func runMetrics() async {
        if chip == nil { chip = await monitor.chip() }
        await monitor.prime()
        // A short first interval, so a page has numbers almost at once.
        try? await Task.sleep(for: .milliseconds(300))
        let clock = ContinuousClock()
        var next = clock.now
        while !Task.isCancelled {
            let update = await monitor.step()
            guard !Task.isCancelled else { break }
            apply(update)
            next = max(next.advanced(by: .seconds(1)), clock.now.advanced(by: .milliseconds(200)))
            try? await Task.sleep(until: next, clock: clock)
        }
    }

    private func apply(_ update: SystemUpdate) {
        latest = update.sample
        samples.append(update.sample)
        if samples.count > Self.historyLength { samples.removeFirst(samples.count - Self.historyLength) }
        if let detail = update.detail, detail != self.detail { self.detail = detail }
    }

    private func runProcesses() async {
        await monitor.resetProcesses()
        _ = await monitor.processList()
        try? await Task.sleep(for: .milliseconds(700))
        while !Task.isCancelled {
            let list = await monitor.processList()
            guard !Task.isCancelled else { break }
            var history: [Int32: [Double]] = [:]
            for row in list {
                history[row.pid] = Array(((processHistory[row.pid] ?? []) + [row.cpu]).suffix(Self.processHistoryLength))
            }
            processHistory = history
            processes = list
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Re-reads the process table now (after ending one).
    func refreshProcesses() {
        guard processTask != nil else { return }
        Task {
            let list = await monitor.processList()
            processes = list
        }
    }
}

extension View {
    /// Keeps the system model sampling while this view is on screen and its
    /// window is visible (not minimised, hidden or covered).
    func systemFeed(_ reason: String, _ feeds: SystemModel.Feeds = .metrics) -> some View {
        background(SystemFeedAnchor(reason: reason, feeds: feeds).frame(width: 0, height: 0))
    }
}

/// Watches its window's occlusion and holds the feed while it's visible.
private struct SystemFeedAnchor: NSViewRepresentable {
    let reason: String
    let feeds: SystemModel.Feeds

    func makeNSView(context: Context) -> FeedView { FeedView(reason: reason, feeds: feeds) }
    func updateNSView(_ view: FeedView, context: Context) {}
    static func dismantleNSView(_ view: FeedView, coordinator: ()) { view.stop() }

    final class FeedView: NSView {
        let reason: String
        let feeds: SystemModel.Feeds
        private var observer: NSObjectProtocol?
        private var holding = false

        init(reason: String, feeds: SystemModel.Feeds) {
            self.reason = reason
            self.feeds = feeds
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return stop() }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.sync() }
            }
            sync()
        }

        private func sync() {
            let visible = window?.occlusionState.contains(.visible) ?? false
            guard visible != holding else { return }
            holding = visible
            visible ? SystemModel.shared.retain(reason, feeds) : SystemModel.shared.release(reason)
        }

        func stop() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            if holding { SystemModel.shared.release(reason) }
            holding = false
        }
    }
}
