import LowtideKit

/// Sizes landing one by one, delivered on the main actor.
enum SizeStream {
    static func measure(_ paths: [String], width: Int = 6) -> AsyncStream<(Int, Int64?)> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                await DiskSize.measureAll(paths, width: width) { continuation.yield(($0, $1)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
