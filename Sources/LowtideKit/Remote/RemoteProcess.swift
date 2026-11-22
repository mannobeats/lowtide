import Foundation

/// A child process (ssh) shared between its termination handler, a timeout
/// and whoever stops it. `Process` isn't Sendable; this box only uses its
/// thread-safe parts (`isRunning`, `terminate`, `processIdentifier`) after
/// launch, and `launched` is written once before anyone else reads it.
final class RemoteProcess: @unchecked Sendable {
    let process = Process()

    var pid: pid_t { process.processIdentifier }
    var isRunning: Bool { process.isRunning }
    func terminate() { if process.isRunning { process.terminate() } }

    struct Result: Sendable {
        var status: Int32?
        var stdout: String
        var stderr: String
        var timedOut: Bool
    }

    /// Runs to the end. Output goes to temp files, not pipes: a backgrounded
    /// ControlPersist master can hold a pipe open long after ssh exits.
    static func run(_ program: String, _ args: [String], environment: [String: String], input: Data? = nil,
                    timeout: TimeInterval, onStart: @Sendable (pid_t) -> Void = { _ in }) async -> Result {
        let fm = FileManager.default
        let stem = fm.temporaryDirectory.appending(path: "lowtide-ssh-\(UUID().uuidString)")
        let outURL = stem.appendingPathExtension("out"), errURL = stem.appendingPathExtension("err")
        fm.createFile(atPath: outURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        fm.createFile(atPath: errURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer {
            try? fm.removeItem(at: outURL)
            try? fm.removeItem(at: errURL)
        }
        guard let out = try? FileHandle(forWritingTo: outURL), let err = try? FileHandle(forWritingTo: errURL) else {
            return Result(status: nil, stdout: "", stderr: "Couldn't create temporary files", timedOut: false)
        }
        let box = RemoteProcess()
        box.process.executableURL = URL(fileURLWithPath: program)
        box.process.arguments = args
        box.process.environment = environment
        box.process.standardOutput = out
        box.process.standardError = err
        let stdin = input.map { _ in Pipe() }
        box.process.standardInput = stdin ?? FileHandle.nullDevice
        let timedOut = TimeoutFlag()
        let status: Int32? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                box.process.terminationHandler = {
                    continuation.resume(returning: $0.terminationReason == .exit ? $0.terminationStatus : nil)
                }
                do {
                    try box.process.run()
                } catch {
                    box.process.terminationHandler = nil
                    continuation.resume(returning: -127)
                    return
                }
                onStart(box.pid)
                if let stdin, let input {
                    try? stdin.fileHandleForWriting.write(contentsOf: input)
                    try? stdin.fileHandleForWriting.close()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    guard box.isRunning else { return }
                    timedOut.set()
                    box.terminate()
                }
            }
        } onCancel: {
            box.terminate()
        }
        try? out.close()
        try? err.close()
        if status == -127 { return Result(status: nil, stdout: "", stderr: "\(program) couldn't start", timedOut: false) }
        return Result(status: status, stdout: (try? String(contentsOf: outURL, encoding: .utf8)) ?? "",
                      stderr: (try? String(contentsOf: errURL, encoding: .utf8)) ?? "", timedOut: timedOut.value)
    }

    final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func set() { lock.withLock { flag = true } }
        var value: Bool { lock.withLock { flag } }
    }

    /// The environment for an ssh the app starts: the person's own, the
    /// login PATH, and no leftovers from whatever launched the app.
    static func sshEnvironment(extra: [String: String] = [:]) -> [String: String] {
        var env = Shell.environment(quiet: false)
        for key in env.keys where key.hasPrefix("SSH_ASKPASS") || key.hasPrefix("LOWTIDE_ASKPASS") || key == "DISPLAY" {
            env[key] = nil
        }
        env.merge(extra) { _, new in new }
        return env
    }
}
