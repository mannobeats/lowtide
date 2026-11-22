import CryptoKit
import Darwin
import Foundation

public struct DuplicateFile: Sendable, Identifiable, Hashable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let modified: Date?
}

/// Files with byte-for-byte the same content.
public struct DuplicateGroup: Sendable, Identifiable, Hashable {
    public let id: String
    /// The size of each copy.
    public let bytes: Int64
    public var files: [DuplicateFile]
    /// The space the extra copies take.
    public var wasted: Int64 { bytes * Int64(max(files.count - 1, 0)) }
}

public enum DuplicateProgress: Sendable, Equatable {
    /// Listing files: how many so far.
    case walking(files: Int)
    /// Comparing contents: bytes compared of those that might match.
    case hashing(done: Int64, total: Int64)
}

/// Finds identical files: same size, then the same first 64 KB, then the
/// same SHA-256 (CryptoKit), so only true copies end up in a group. Biggest
/// files first, so the groups that matter arrive early.
public enum DuplicateFinder {
    /// Someone else's bookkeeping (build output, dependency trees):
    /// duplicates there are expected and not the person's.
    static let skipDirs: Set<String> = ["node_modules", "Pods", "DerivedData", "__pycache__", "venv", "bower_components"]
    /// `SF_DATALESS`: the content lives in iCloud only; reading would download it.
    static let dataless: UInt32 = 0x4000_0000
    static let head = 64 * 1024

    /// Which copy a rule keeps; every other copy is selected.
    public enum KeepRule: String, Sendable, CaseIterable {
        case oldest, newest, shortest

        public var label: String {
            switch self {
            case .oldest: "Oldest"
            case .newest: "Newest"
            case .shortest: "Shortest path"
            }
        }
    }

    public static func keeper(_ files: [DuplicateFile], rule: KeepRule) -> DuplicateFile? {
        files.min { a, b in
            switch rule {
            case .shortest: (a.path.count, a.path) < (b.path.count, b.path)
            case .oldest: (a.modified ?? .distantPast) < (b.modified ?? .distantPast)
            case .newest: (a.modified ?? .distantPast) > (b.modified ?? .distantPast)
            }
        }
    }

    /// Every copy but the keeper, in every group.
    public static func extras(_ groups: [DuplicateGroup], rule: KeepRule) -> Set<String> {
        var marked: Set<String> = []
        for group in groups {
            let kept = keeper(group.files, rule: rule)?.path
            marked.formUnion(group.files.map(\.path).filter { $0 != kept })
        }
        return marked
    }

    /// Roots that exist, without ones inside another (they'd list the same
    /// files twice).
    public static func normalize(_ roots: [String]) -> [String] {
        let existing = roots.filter { $0.hasPrefix("/") && !$0.split(separator: "/").contains("..") && CleanupFS.isFolder($0) }
        return existing.filter { root in !existing.contains { $0 != root && CleanupFS.isInside(root, $0) } }
    }

    struct Found { let bytes: Int64; let path: String; let modified: Date? }

    static func walk(_ roots: [String], minBytes: Int64, home: String, stop: () -> Bool,
                     progress: (DuplicateProgress) -> Void) -> [Found] {
        let library = CleanupFS.join(home, "Library")
        var seen: Set<String> = []
        var files: [Found] = []
        var stack: [(String, dev_t)] = roots.compactMap { root in
            var info = stat()
            return stat(root, &info) == 0 ? (root, info.st_dev) : nil
        }
        var count = 0
        var lastReport = Date()
        while let (dir, device) = stack.popLast() {
            if stop() { return [] }
            for name in CleanupFS.names(dir) where !name.hasPrefix(".") {
                let path = CleanupFS.join(dir, name)
                guard let info = CleanupFS.info(path) else { continue }
                let type = info.st_mode & S_IFMT
                if type == S_IFLNK { continue }
                if type == S_IFDIR {
                    let buildOutput = name == "target" && CleanupFS.exists(CleanupFS.join(dir, "Cargo.toml"))
                    if !skipDirs.contains(name), !buildOutput, !FolderScan.isPackage(path), path != library, info.st_dev == device {
                        stack.append((path, device))
                    }
                    continue
                }
                count += 1
                if count % 500 == 0, Date().timeIntervalSince(lastReport) >= 0.2 {
                    lastReport = Date()
                    progress(.walking(files: count))
                }
                // Hard links are one file under two names, not a duplicate.
                if type == S_IFREG, Int64(info.st_size) >= max(minBytes, 1), info.st_flags & dataless == 0,
                   seen.insert("\(info.st_dev):\(info.st_ino)").inserted {
                    files.append(Found(bytes: Int64(info.st_size), path: path,
                                       modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))))
                }
            }
        }
        progress(.walking(files: count))
        return files
    }

    /// SHA-256 of a file, or of its first `limit` bytes. `nil` when
    /// unreadable or stopped mid-file (a 50 GB file would hold Stop).
    static func hash(_ path: String, limit: Int?, stop: () -> Bool) -> SHA256.Digest? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var hasher = SHA256()
        let size = 1 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        var left = limit ?? Int.max
        while left > 0 {
            if stop() { return nil }
            let got = read(fd, buffer, min(size, left))
            if got < 0 { return nil }
            if got == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: got))
            left -= got
        }
        return hasher.finalize()
    }

    /// Hashes `files` in parallel and groups them by digest; groups of one go.
    static func group(_ files: [Found], limit: Int?, stop: @escaping @Sendable () -> Bool) -> [[Found]] {
        let digests = CleanupLock([SHA256.Digest?](repeating: nil, count: files.count))
        let paths = files.map(\.path)
        DispatchQueue.concurrentPerform(iterations: files.count) { index in
            let digest = hash(paths[index], limit: limit, stop: stop)
            digests.update { $0[index] = digest }
        }
        var groups: [SHA256.Digest: [Found]] = [:]
        for (index, digest) in digests.value.enumerated() {
            if let digest { groups[digest, default: []].append(files[index]) }
        }
        return groups.values.filter { $0.count > 1 }
    }

    /// Streams groups of identical files under `roots`; returns how many.
    /// Blocks the calling thread: use `scan`.
    static func find(_ roots: [String], minBytes: Int64, home: String, stop: @escaping @Sendable () -> Bool,
                     progress: (DuplicateProgress) -> Void, onGroup: (DuplicateGroup) -> Void) -> Int {
        var bySize: [Int64: [Found]] = [:]
        for file in walk(roots, minBytes: minBytes, home: home, stop: stop, progress: progress) {
            bySize[file.bytes, default: []].append(file)
        }
        let candidates = bySize.filter { $0.value.count > 1 }.sorted { $0.key > $1.key }
        let total = candidates.reduce(Int64(0)) { $0 + $1.key * Int64($1.value.count) }
        var done: Int64 = 0
        var count = 0
        var lastReport = Date()
        for (bytes, files) in candidates {
            if stop() { break }
            let small = bytes <= Int64(head)
            for heads in group(files, limit: head, stop: stop) {
                for same in small ? [heads] : group(heads, limit: nil, stop: stop) where !stop() {
                    count += 1
                    onGroup(DuplicateGroup(id: "\(bytes)-\(count)", bytes: bytes,
                                           files: same.map { DuplicateFile(path: $0.path, name: CleanupFS.name($0.path), modified: $0.modified) }))
                }
            }
            done += bytes * Int64(files.count)
            // Thousands of small candidates finish a second; a few updates
            // a second is plenty.
            if Date().timeIntervalSince(lastReport) >= 0.2 {
                lastReport = Date()
                progress(.hashing(done: done, total: total))
            }
        }
        progress(.hashing(done: done, total: total))
        return count
    }

    /// `find` on its own thread. Cancelling the task stops it within a
    /// chunk of reading.
    public static func scan(_ roots: [String], minBytes: Int64, home: String = Paths.home.path,
                            progress: @escaping @Sendable (DuplicateProgress) -> Void,
                            onGroup: @escaping @Sendable (DuplicateGroup) -> Void) async -> Int {
        let stopped = CleanupLock(false)
        let roots = normalize(roots)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
                Thread.detachNewThread {
                    let count = find(roots, minBytes: minBytes, home: home, stop: { stopped.value },
                                     progress: progress, onGroup: onGroup)
                    continuation.resume(returning: count)
                }
            }
        } onCancel: {
            stopped.value = true
        }
    }
}
