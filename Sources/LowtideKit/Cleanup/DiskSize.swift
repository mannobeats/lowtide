import Darwin
import Foundation

/// Sizes on disk as `du -x` counts them: allocated blocks (sparse files by
/// what they really hold, APFS clones in full), never following links,
/// never crossing onto another disk, a hard-linked file counted once (in
/// full, even when its other links live outside the tree, as `du` does).
public enum DiskSize {
    /// Measures every folder in `roots` at once on `threads` threads that
    /// share one queue of directories, so one giant tree (a pnpm store,
    /// Caches) is split across all of them instead of one walker holding it.
    /// Calls `done(index, bytes)` as each root finishes; returns early once
    /// `stop` says so (unfinished roots are never reported). Blocks the
    /// calling thread: only `measureEach` calls it, on a thread of its own.
    static func measureTrees(
        _ roots: [String], threads: Int,
        stop: @escaping @Sendable () -> Bool = { false },
        done: @escaping @Sendable (Int, Int64) -> Void
    ) {
        guard !roots.isEmpty else { return }
        let walk = TreeWalk(roots: roots, stop: stop, done: done)
        let group = DispatchGroup()
        for _ in 0..<max(1, threads) {
            group.enter()
            let thread = Thread {
                walk.work()
                group.leave()
            }
            thread.stackSize = 1 << 20
            thread.qualityOfService = .utility
            thread.start()
        }
        // Waits on the caller's own thread (`measureEach` starts one), never
        // on Swift's concurrency pool.
        group.wait()
    }

    /// `measureTrees` off the caller's thread, for async code.
    public static func measureEach(
        _ roots: [String], threads: Int = 8,
        stop: @escaping @Sendable () -> Bool = { false },
        done: @escaping @Sendable (Int, Int64) -> Void
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                measureTrees(roots, threads: threads, stop: stop, done: done)
                continuation.resume()
            }
        }
    }

    /// One path's size; `nil` when it can't be read or the walk ran past
    /// `timeout` (or the task was cancelled). Folders use a few threads:
    /// callers usually measure several paths at once.
    public static func measure(_ path: String, timeout: Duration = .seconds(120)) async -> Int64? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        if (info.st_mode & S_IFMT) != S_IFDIR { return Int64(info.st_blocks) * 512 }
        let deadline = ContinuousClock.now + timeout
        let result = CleanupLock<Int64?>(nil)
        let cancelled = CleanupLock(false)
        await withTaskCancellationHandler {
            await measureEach([path], threads: 4, stop: {
                cancelled.value || ContinuousClock.now > deadline
            }, done: { _, bytes in result.value = bytes })
        } onCancel: {
            cancelled.value = true
        }
        return result.value
    }

    /// Several paths, at most `width` at a time, each reported as it lands.
    public static func measureAll(
        _ paths: [String], width: Int = 6,
        onMeasured: @escaping @Sendable (Int, Int64?) -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func add() {
                guard next < paths.count else { return }
                let index = next
                next += 1
                group.addTask { onMeasured(index, await measure(paths[index])) }
            }
            for _ in 0..<min(width, paths.count) { add() }
            while await group.next() != nil { add() }
        }
    }

    /// Several paths, at most `width` at a time, in input order.
    public static func measure(_ paths: [String], width: Int = 8) async -> [Int64?] {
        let sizes = CleanupLock([Int64?](repeating: nil, count: paths.count))
        await measureAll(paths, width: width) { index, bytes in sizes.update { $0[index] = bytes } }
        return sizes.value
    }

    /// Free and total bytes of the volume holding `path`, as Finder counts
    /// them: free "for important usage" includes what macOS purges on demand
    /// (caches, local snapshots), which `df` reports as used.
    public static func volume(at path: String) -> (available: Int64, total: Int64)? {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        let values = try? url.resourceValues(forKeys: keys)
        var fs = statfs()
        let fallback: (Int64, Int64)? = statfs(path, &fs) == 0
            ? (Int64(fs.f_bavail) * Int64(fs.f_bsize), Int64(fs.f_blocks) * Int64(fs.f_bsize)) : nil
        guard let available = values?.volumeAvailableCapacityForImportantUsage ?? fallback?.0,
              let total = (values?.volumeTotalCapacity).map(Int64.init) ?? fallback?.1 else { return nil }
        return (available, total)
    }
}

/// A value shared between threads, behind a lock.
final class CleanupLock<Value>: @unchecked Sendable {
    // Every access goes through `lock`.
    private var _value: Value
    private let lock = NSLock()
    init(_ value: Value) { _value = value }
    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
    func update<T>(_ change: (inout Value) -> T) -> T { lock.withLock { change(&_value) } }
}

/// The shared state of one `measureTrees` call: the queue of folders still
/// to read, and per root its bytes so far and how many of its folders are
/// queued or being read (the root is measured when that reaches zero).
private final class TreeWalk: @unchecked Sendable {
    // Every mutable field is guarded by `condition`.
    private struct Job { let root: Int; let path: String; let device: dev_t }
    private let condition = NSCondition()
    private var queue: [Job] = []
    private var bytes: [Int64]
    private var pending: [Int]
    private var busy = 0
    /// Per root, the inodes of hard-linked files already counted. Only files
    /// with more than one link are remembered (pnpm's node_modules: all).
    private var linked: [Set<UInt64>]
    private let stop: @Sendable () -> Bool
    private let done: @Sendable (Int, Int64) -> Void

    init(roots: [String], stop: @escaping @Sendable () -> Bool, done: @escaping @Sendable (Int, Int64) -> Void) {
        self.stop = stop
        self.done = done
        bytes = Array(repeating: 0, count: roots.count)
        pending = Array(repeating: 1, count: roots.count)
        linked = Array(repeating: [], count: roots.count)
        for (index, root) in roots.enumerated() {
            var info = stat()
            let device = stat(root, &info) == 0 ? info.st_dev : 0
            queue.append(Job(root: index, path: root, device: device))
        }
    }

    func work() {
        while let job = next() {
            var total: Int64 = 0
            var found: [Job] = []
            var links: [(UInt64, Int64)] = []
            read(job, total: &total, found: &found, links: &links)
            var finished: (Int, Int64)?
            condition.lock()
            for (inode, blocks) in links where linked[job.root].insert(inode).inserted { total += blocks }
            bytes[job.root] += total
            pending[job.root] += found.count
            if !found.isEmpty {
                queue.append(contentsOf: found)
                condition.broadcast()
            }
            pending[job.root] -= 1
            if pending[job.root] == 0 { finished = (job.root, bytes[job.root]) }
            busy -= 1
            if busy == 0, queue.isEmpty { condition.broadcast() }
            condition.unlock()
            if let finished { done(finished.0, finished.1) }
        }
    }

    private func next() -> Job? {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if stop() {
                condition.broadcast()
                return nil
            }
            if let job = queue.popLast() {
                busy += 1
                return job
            }
            if busy == 0 {
                condition.broadcast()
                return nil
            }
            _ = condition.wait(until: Date().addingTimeInterval(0.1))
        }
    }

    private func read(_ job: Job, total: inout Int64, found: inout [Job], links: inout [(UInt64, Int64)]) {
        guard let dir = opendir(job.path) else { return }
        defer { closedir(dir) }
        let fd = dirfd(dir)
        let prefix = job.path.hasSuffix("/") ? job.path : job.path + "/"
        var info = stat()
        while let entry = readdir(dir) {
            let skip = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 3) { name in
                    name[0] == 0x2E && (name[1] == 0 || (name[1] == 0x2E && name[2] == 0))
                }
            }
            if skip { continue }
            let ok = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { name in
                    fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0
                }
            }
            guard ok else { continue }
            if (info.st_mode & S_IFMT) == S_IFDIR {
                guard info.st_dev == job.device else { continue }
                let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                found.append(Job(root: job.root, path: prefix + name, device: job.device))
            } else if info.st_nlink > 1 {
                links.append((info.st_ino, Int64(info.st_blocks) * 512))
            } else {
                total += Int64(info.st_blocks) * 512
            }
        }
    }
}
