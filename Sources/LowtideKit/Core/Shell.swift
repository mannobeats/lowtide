import Foundation
import os

public struct CommandOutput: Sendable {
    public var stdout: String
    public var stderr: String
    public var status: Int32
    public var ok: Bool { status == 0 }
    /// What to show when it failed: stderr, else stdout.
    public var message: String {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? stdout.trimmingCharacters(in: .whitespacesAndNewlines) : text
    }
}

/// Runs the command-line tools Lowtide drives (brew, npm, launchctl…).
///
/// A Mac app is started by launchd with only `/usr/bin:/bin`, so every tool a
/// version manager installs (nvm, mise, volta, asdf) would look missing.
/// `prepare()` reads the PATH the person's login shell builds, once, at
/// launch; every command waits for it (at most 4 s).
public enum Shell {
    /// Upper bound for any tool: long enough for a large `brew upgrade`,
    /// short enough that a hidden prompt can't hang an action forever.
    public static let defaultTimeout: Duration = .seconds(20 * 60)

    private static let state = OSAllocatedUnfairLock(initialState: PathState())
    private struct PathState {
        var path: String = Shell.fallbackPath()
        var login: String?
        var ready = false
    }

    private static let readyTask = Task.detached(priority: .userInitiated) { () -> Void in
        let login = await readLoginPath()
        let path = buildPath(login: login)
        state.withLock {
            $0.path = path
            $0.login = login
            $0.ready = true
        }
        // Set from an Electron app's terminal (VS Code, Cursor): every app
        // we open would inherit it and start as plain Node.
        unsetenv("ELECTRON_RUN_AS_NODE")
        setenv("PATH", path, 1)
    }

    /// Starts reading the login shell's PATH. Call once at launch.
    public static func prepare() { _ = readyTask }

    public static func ready() async { await readyTask.value }

    /// The PATH every child process sees.
    public static var path: String { state.withLock { $0.path } }

    /// The PATH the person's own terminals get, when the login shell could be read.
    public static var loginPath: String? { state.withLock { $0.login } }

    /// The environment for a child: ours, the full PATH, and quiet tool settings.
    public static func environment(quiet: Bool = true, extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        env["ELECTRON_RUN_AS_NODE"] = nil
        if quiet { env.merge(quietEnvironment) { _, new in new } }
        env.merge(extra) { _, new in new }
        return env
    }

    /// Keeps package managers non-interactive and their output plain. No
    /// analytics for the tools run on the person's behalf either.
    static let quietEnvironment: [String: String] = [
        "NO_COLOR": "1", "TERM": "dumb", "NONINTERACTIVE": "1",
        "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1",
        "HOMEBREW_NO_ENV_HINTS": "1", "HOMEBREW_COLOR": "0",
        "npm_config_update_notifier": "false", "npm_config_fund": "false",
        "npm_config_audit": "false", "npm_config_progress": "false",
        "PIP_DISABLE_PIP_VERSION_CHECK": "1", "COMPOSER_NO_INTERACTION": "1",
        "GIT_TERMINAL_PROMPT": "0",
    ]

    static let systemPaths = [
        "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin",
        "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]

    static let userRelative = [
        ".cargo/bin", ".bun/bin", ".local/bin", "go/bin", "Library/pnpm", "Library/pnpm/bin",
        ".local/share/pnpm", ".local/share/pnpm/bin", ".composer/vendor/bin",
        ".config/composer/vendor/bin",
    ]

    static func fallbackPath() -> String { buildPath(login: nil) }

    static func buildPath(login: String?) -> String {
        var entries: [String] = []
        func push(_ entry: String) {
            if !entry.isEmpty, !entries.contains(entry) { entries.append(entry) }
        }
        login?.split(separator: ":").forEach { push(String($0)) }
        systemPaths.forEach(push)
        let home = Paths.home.path
        userRelative.forEach { push(home + "/" + $0) }
        ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").forEach { push(String($0)) }
        return entries.joined(separator: ":")
    }

    /// The login shell inherits our own environment, so it builds PATH the
    /// way a new Terminal window does.
    private static func readLoginPath() async -> String? {
        let marker = "__LOWTIDE_PATH__="
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "printf '\(marker)%s' \"$PATH\""]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        let box = ProcessBox(process)
        guard (try? await box.launch(shell, timeout: .seconds(4), started: { box.startReading(out: pipe) })) != nil,
              !box.timedOut else { return nil }
        let text = await box.collected().0
        guard let range = text.range(of: marker, options: .backwards) else { return nil }
        let path = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// `/usr/bin` shims that only open the "install Command Line Tools"
    /// dialog until the tools are installed.
    static let xcodeShims: Set<String> = ["git", "python3", "pip3", "swift", "clang", "gcc", "make"]

    public static let hasDeveloperTools: Bool = FileManager.default.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/git")
        || FileManager.default.fileExists(atPath: "/Applications/Xcode.app/Contents/Developer")

    /// Full path of a program on the PATH, skipping Xcode shims that would
    /// open an install dialog.
    public static func resolve(_ program: String) -> String? {
        if program.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: program) ? program : nil
        }
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(program)"
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir), !isDir.boolValue,
                  FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            if candidate.hasPrefix("/usr/bin/"), xcodeShims.contains(program), !hasDeveloperTools { return nil }
            return candidate
        }
        return nil
    }

    public static func isAvailable(_ program: String) -> Bool { resolve(program) != nil }

    /// Runs a command to the end and returns its output. Task cancellation
    /// and the timeout both terminate the process.
    public static func run(
        _ program: String, _ arguments: [String] = [],
        timeout: Duration = defaultTimeout, quiet: Bool = true,
        environment extra: [String: String] = [:], input: Data? = nil,
        directory: URL? = nil
    ) async throws -> CommandOutput {
        await ready()
        guard let executable = resolve(program) else { throw LowtideError.toolMissing(program) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment(quiet: quiet, extra: extra)
        if let directory { process.currentDirectoryURL = directory }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let stdin = input.map { _ in Pipe() }
        process.standardInput = stdin ?? FileHandle.nullDevice
        let box = ProcessBox(process)
        let status = try await box.launch(program, timeout: timeout) {
            if let stdin, let input {
                DispatchQueue.global().async {
                    try? stdin.fileHandleForWriting.write(contentsOf: input)
                    try? stdin.fileHandleForWriting.close()
                }
            }
            box.startReading(out: out, err: err)
        }
        let (stdout, stderr) = await box.collected()
        if box.timedOut { throw LowtideError.commandFailed("\(program) timed out") }
        return CommandOutput(stdout: stdout, stderr: stderr, status: status)
    }

    /// Runs a command whose output only matters when it fails; returns stdout.
    @discardableResult
    public static func check(_ program: String, _ arguments: [String] = [], timeout: Duration = defaultTimeout) async throws -> String {
        let out = try await run(program, arguments, timeout: timeout)
        guard out.ok else { throw LowtideError.commandFailed(out.message.isEmpty ? "\(program) failed" : out.message) }
        return out.stdout
    }

    /// Runs a long operation, handing every output line (stdout and stderr,
    /// interleaved) to `onLine` as it arrives. Progress bars redraw with
    /// `\r`; only their final state is a line. The result's stdout holds the
    /// last 40 lines.
    public static func stream(
        _ program: String, _ arguments: [String],
        timeout: Duration = defaultTimeout, environment extra: [String: String] = [:],
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> CommandOutput {
        await ready()
        guard let executable = resolve(program) else { throw LowtideError.toolMissing(program) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment(extra: extra)
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let box = ProcessBox(process)
        let status = try await box.launch(program, timeout: timeout) { box.startLines(pipe, onLine: onLine) }
        let tail = await box.tailText()
        if box.timedOut { throw LowtideError.commandFailed("\(program) timed out") }
        return CommandOutput(stdout: tail, stderr: "", status: status)
    }
}

/// A running process and what it printed, shared between the reader
/// threads, the timeout and the cancellation handler. `Process` isn't
/// Sendable; every mutable field here is behind the lock.
///
/// Nothing here waits on a thread for the process: `waitUntilExit()` can
/// hang for good on a thread without a run loop after the child is gone, and
/// a blocked thread in async code starves Swift's concurrency pool. The exit
/// arrives through `terminationHandler`; pipes are read on Dispatch threads.
final class ProcessBox: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var stdout = Data(), stderr = Data()
    private var tail: [String] = []
    private var _timedOut = false
    private let readers = DispatchGroup()

    init(_ process: Process) { self.process = process }

    var timedOut: Bool { lock.withLock { _timedOut } }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    /// Starts the process, calls `started` (to begin reading its pipes) and
    /// returns its exit status. Task cancellation and `timeout` terminate it;
    /// a timeout shows in `timedOut`.
    func launch(_ name: String, timeout: Duration, started: () -> Void) async throws -> Int32 {
        try await withTaskCancellationHandler {
            let status: Int32 = try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do { try process.run() } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: LowtideError.commandFailed("\(name): \(error.localizedDescription)"))
                    return
                }
                started()
                arm(timeout: timeout)
            }
            try Task.checkCancellation()
            return status
        } onCancel: {
            terminate()
        }
    }

    private func arm(timeout: Duration) {
        let (seconds, atto) = timeout.components
        DispatchQueue.global().asyncAfter(deadline: .now() + Double(seconds) + Double(atto) / 1e18) { [self] in
            guard process.isRunning else { return }
            lock.withLock { _timedOut = true }
            process.terminate()
        }
    }

    /// Runs `body` on a Dispatch thread, counted as one of the readers.
    func read(_ body: @escaping @Sendable () -> Void) {
        readers.enter()
        DispatchQueue.global().async { [self] in
            body()
            readers.leave()
        }
    }

    /// Chunk by chunk, so what a tool printed is kept even when a daemon it
    /// started holds the pipe open past `drained()`.
    func startReading(out: Pipe, err: Pipe? = nil) {
        for (pipe, isOut) in [(out, true)] + (err.map { [($0, false)] } ?? []) {
            read { [self] in
                let handle = pipe.fileHandleForReading
                while case let chunk = handle.availableData, !chunk.isEmpty {
                    lock.withLock { if isOut { stdout.append(chunk) } else { stderr.append(chunk) } }
                }
            }
        }
    }

    /// A grandchild that keeps the pipe open (a daemon a tool started) must
    /// not hang the caller: after the process exits, wait 3 s at most.
    func drained() async {
        let once = OSAllocatedUnfairLock(initialState: false)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resume: @Sendable () -> Void = {
                if once.withLock({ done in defer { done = true }; return !done }) { continuation.resume() }
            }
            readers.notify(queue: .global(), execute: resume)
            DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: resume)
        }
    }

    func collected() async -> (String, String) {
        await drained()
        return lock.withLock { (String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self)) }
    }

    func startLines(_ pipe: Pipe, onLine: @escaping @Sendable (String) -> Void) {
        read { [self] in
            let handle = pipe.fileHandleForReading
            var buffer = Data()
            func emit(_ bytes: Data) {
                let text = String(decoding: bytes, as: UTF8.self)
                let line = (text.split(separator: "\r", omittingEmptySubsequences: true).last.map(String.init) ?? text)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { return }
                lock.withLock {
                    tail.append(line)
                    if tail.count > 40 { tail.removeFirst(tail.count - 40) }
                }
                onLine(line)
            }
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    emit(buffer[buffer.startIndex..<newline])
                    buffer.removeSubrange(buffer.startIndex...newline)
                }
            }
            if !buffer.isEmpty { emit(buffer) }
        }
    }

    func tailText() async -> String {
        await drained()
        return lock.withLock { tail.joined(separator: "\n") }
    }
}
