import Foundation

/// The dictation helper process (`lowtide-voice`): the shortcut, the microphone,
/// the models and the typing live there, so a model crash can't take the app
/// with it and the models' memory is freed when it quits. This side starts
/// it, writes JSON lines to its stdin and hands each line it prints to
/// `onMessage`, in order, on the reader's queue.
///
/// `@unchecked Sendable`: every mutable field is read and written under
/// `lock`, and the pipes' handlers only touch them through it.
public final class VoiceHelper: @unchecked Sendable {
    public typealias MessageHandler = @Sendable (HelperMessage) -> Void
    public typealias ExitHandler = @Sendable (_ pid: Int32, _ status: Int32) -> Void

    private let executable: URL
    private let arguments: [String]
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var errorTail: [String] = []
    private let onMessage: MessageHandler
    private let onExit: ExitHandler
    /// The helper's last words on stderr, for the diagnostics report.
    public static let errorLines = 100

    public init(executable: URL, arguments: [String] = [], onMessage: @escaping MessageHandler,
                onExit: @escaping ExitHandler) {
        self.executable = executable
        self.arguments = arguments
        self.onMessage = onMessage
        self.onExit = onExit
    }

    public var isRunning: Bool {
        lock.withLock { process?.isRunning ?? false }
    }

    public var pid: Int32? {
        lock.withLock { process.flatMap { $0.isRunning ? $0.processIdentifier : nil } }
    }

    public var stderrTail: [String] { lock.withLock { errorTail } }

    /// Starts the helper if it isn't running and writes `first` (the
    /// settings) before anything else, whatever asked for it: without them
    /// it has no shortcut, no model and nowhere to put downloads. True when
    /// a new process started.
    @discardableResult
    public func start(first: Data) throws -> Bool {
        try lock.withLock {
            if process?.isRunning == true { return false }
            // A write to a helper that just died must fail, not end the app.
            signal(SIGPIPE, SIG_IGN)
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr

            let lines = PipeLines()
            let onMessage = self.onMessage
            stdout.fileHandleForReading.readabilityHandler = { handle in
                for line in lines.read(handle) {
                    if let message = HelperMessage.parse(line) { onMessage(message) }
                }
            }
            let errors = PipeLines()
            stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let lines = errors.read(handle)
                guard let self, !lines.isEmpty else { return }
                self.lock.withLock {
                    self.errorTail.append(contentsOf: lines)
                    if self.errorTail.count > Self.errorLines {
                        self.errorTail.removeFirst(self.errorTail.count - Self.errorLines)
                    }
                }
            }
            let onExit = self.onExit
            process.terminationHandler = { ended in
                onExit(ended.processIdentifier, ended.terminationStatus)
            }
            try process.run()
            // Known before the first write: if it dies right away, its exit
            // counts as this helper's, and the restart policy runs.
            self.process = process
            let handle = stdin.fileHandleForWriting
            self.input = handle
            try handle.write(contentsOf: first)
            return true
        }
    }

    /// Writes one line; throws when the helper isn't running.
    public func send(_ line: Data) throws {
        try lock.withLock {
            guard let input, process?.isRunning == true else {
                throw LowtideError.commandFailed("Dictation isn't running.")
            }
            try input.write(contentsOf: line)
        }
    }

    /// Ends the helper: its input closes (it quits on its own when it
    /// does), then it's told to stop, then made to.
    public func stop() {
        let ending: Process? = lock.withLock {
            let ending = process
            try? input?.close()
            input = nil
            process = nil
            return ending
        }
        guard let ending, ending.isRunning else { return }
        ending.terminate()
        let pid = ending.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            if ending.isRunning { kill(pid, SIGKILL) }
        }
    }

    /// Whether `pid` is the helper this object runs now (a newer one may
    /// have taken its place).
    public func isCurrent(_ pid: Int32) -> Bool {
        lock.withLock { process?.processIdentifier == pid }
    }

    /// Forgets a helper that ended on its own, so the next start makes a new one.
    public func ended(_ pid: Int32) {
        lock.withLock {
            guard process?.processIdentifier == pid else { return }
            try? input?.close()
            input = nil
            process = nil
        }
    }
}

/// A pipe's lines as they arrive. `@unchecked Sendable`: a handle calls its
/// readability handler one chunk at a time, and the lock covers the rest.
private final class PipeLines: @unchecked Sendable {
    private let lock = NSLock()
    private var splitter = LineSplitter()

    /// The whole lines in what's waiting; at the end of the pipe, what's left.
    func read(_ handle: FileHandle) -> [String] {
        let chunk = handle.availableData
        return lock.withLock {
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return splitter.finish()
            }
            return splitter.append(chunk)
        }
    }
}

/// When to start a helper that ended unexpectedly again: at once, three
/// times a minute; after that once a minute, never given up on until
/// dictation is turned off.
public struct RestartPolicy: Sendable {
    private var recent: [Date] = []
    public static let window: TimeInterval = 60
    public static let burst = 3

    public init() {}

    /// The wait before the next start, and whether it's the slow one.
    public mutating func next(now: Date = Date()) -> (wait: Duration, slow: Bool) {
        recent.removeAll { now.timeIntervalSince($0) >= Self.window }
        if recent.count >= Self.burst {
            recent.removeAll()
            return (.seconds(60), true)
        }
        recent.append(now)
        return (.seconds(1), false)
    }

    public mutating func reset() { recent.removeAll() }
}
