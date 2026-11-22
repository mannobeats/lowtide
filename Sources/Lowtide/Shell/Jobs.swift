import SwiftUI

/// Long-running work that must survive navigation (updates, cleanups,
/// scans, installs). Pages start a job here; the status bar shows what's
/// running and its progress from anywhere.
@Observable
final class Jobs {
    static let shared = Jobs()

    @Observable
    final class Job: Identifiable {
        let id = UUID()
        let title: String
        let page: Page?
        var detail: String = ""
        var progress: Double?
        var done = false
        var failed: String?
        fileprivate var task: Task<Void, Never>?

        init(title: String, page: Page?) {
            self.title = title
            self.page = page
        }

        func cancel() { task?.cancel() }
    }

    private(set) var running: [Job] = []

    /// Runs `work` as a job. The closure updates `job.detail` and
    /// `job.progress` as it goes; a thrown error is shown as a toast.
    @discardableResult
    func start(_ title: String, page: Page? = nil, success: String? = nil,
               _ work: @escaping @MainActor (Job) async throws -> Void) -> Job {
        let job = Job(title: title, page: page)
        withAnimation(Motion.base) { running.append(job) }
        job.task = Task { @MainActor in
            do {
                try await work(job)
                job.done = true
                if let success { Toasts.shared.show(success) }
            } catch is CancellationError {
                job.failed = "Cancelled"
            } catch {
                job.failed = error.localizedDescription
                Toasts.shared.failure("\(title) failed", error)
            }
            withAnimation(Motion.base) { running.removeAll { $0.id == job.id } }
        }
        return job
    }

    func isRunning(_ title: String) -> Bool { running.contains { $0.title == title } }
}
