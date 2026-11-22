import Foundation

/// Downloads that can be large: no overall time limit, only a stall limit,
/// HTTPS only, and the same plain user agent as every other request.
public enum LargeDownload {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = HTTP.session.configuration.httpAdditionalHeaders
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 24 * 3600
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// Fetches `url` into `file`, reporting bytes received (and the total
    /// when known) about five times a second.
    public static func fetch(_ url: URL, to file: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        let watcher = TaskWatcher()
        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                if let (received, total) = watcher.counts() { progress(received, total) }
            }
        }
        defer { ticker.cancel() }
        let (temporary, response) = try await session.download(from: url, delegate: watcher)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), http.url?.scheme == "https" else {
            throw LowtideError.commandFailed("The download failed (\((response as? HTTPURLResponse)?.statusCode ?? 0))")
        }
        try FileManager.default.moveItem(at: temporary, to: file)
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
        progress(size, size)
    }

    /// Holds the running task so its byte counts can be read. The task is
    /// set once by URLSession and only read after; the lock guards both.
    final class TaskWatcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionTask?

        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            lock.withLock { self.task = task }
        }

        /// Refuses a redirect to plain HTTP.
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            request.url?.scheme == "https" ? request : nil
        }

        func counts() -> (Int64, Int64?)? {
            lock.withLock {
                guard let task else { return nil }
                let total = task.countOfBytesExpectedToReceive
                return (task.countOfBytesReceived, total > 0 ? total : nil)
            }
        }
    }
}
