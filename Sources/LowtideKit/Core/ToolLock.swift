import Foundation

/// One lock per tool (`brew`, `npm`, `simctl`…), shared by Apps, Cleanup
/// and Toolchain. Tools keep global state (Homebrew's lock files, npm's
/// global prefix), so two runs of the same one must never overlap, whichever
/// space started them; different tools run side by side.
public actor ToolLock {
    public static let shared = ToolLock()

    private var held: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    /// Waits until nothing else holds `key`, then holds it.
    public func acquire(_ key: String) async {
        guard held.contains(key) else {
            held.insert(key)
            return
        }
        await withCheckedContinuation { waiters[key, default: []].append($0) }
    }

    /// Holds `key` only if it's free right now.
    public func tryAcquire(_ key: String) -> Bool {
        guard !held.contains(key) else { return false }
        held.insert(key)
        return true
    }

    /// Hands the lock to the next waiter, or frees it.
    public func release(_ key: String) {
        if var queue = waiters[key], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[key] = queue.isEmpty ? nil : queue
            next.resume()
        } else {
            held.remove(key)
        }
    }

    public func isHeld(_ key: String) -> Bool { held.contains(key) }

    /// Runs `body` holding `key`.
    public nonisolated func with<T: Sendable>(_ key: String, _ body: @Sendable () async throws -> T) async rethrows -> T {
        await acquire(key)
        do {
            let value = try await body()
            await release(key)
            return value
        } catch {
            await release(key)
            throw error
        }
    }
}
