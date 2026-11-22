import Foundation
import os

/// Port forwards that are running: one background ssh each, outliving any
/// page, stopped at quit.
public final class Tunnels: Sendable {
    public static let shared = Tunnels()

    public enum Status: Equatable, Sendable {
        /// ssh started; the forward isn't confirmed yet.
        case starting
        case running(since: Date)
        /// ssh ended on its own (sign-in failed, the port was taken, the
        /// connection dropped).
        case failed(String)
    }

    private struct Entry {
        var box: RemoteProcess
        var token: String?
        var status: Status
        var stderr: [String] = []
        var stopping = false
    }

    private let state = OSAllocatedUnfairLock<[String: Entry]>(initialState: [:])
    private let observer = OSAllocatedUnfairLock<(@Sendable (String, Status?) -> Void)?>(initialState: nil)

    /// Called on any thread whenever a forward's status changes (nil: stopped).
    public func observe(_ handler: @escaping @Sendable (String, Status?) -> Void) {
        observer.withLock { $0 = handler }
    }

    private func notify(_ id: String, _ status: Status?) {
        observer.withLock { $0 }?(id, status)
    }

    public func status(_ id: String) -> Status? { state.withLock { $0[id]?.status } }

    public var active: [String: Status] { state.withLock { $0.mapValues(\.status) } }

    /// Starts a tunnel. Saved secrets are answered through askpass; without
    /// any, ssh runs in batch mode so a password prompt nobody sees fails fast.
    public func start(_ forward: PortForward, endpoint: SSHEndpoint, secrets: [AskpassSecret], label: String) throws {
        if let existing = state.withLock({ $0[forward.id] }), existing.box.isRunning { return }
        let args = try SSHCommand.tunnel(endpoint, forward: forward, batch: secrets.isEmpty)
        var environment = RemoteProcess.sshEnvironment()
        let token: String?
        if secrets.isEmpty {
            token = nil
        } else {
            let ticket = try AskpassServer.shared.register(secrets: secrets, interactive: true, label: label)
            environment.merge(ticket.environment) { _, new in new }
            token = ticket.token
        }
        let box = RemoteProcess()
        box.process.executableURL = URL(fileURLWithPath: SSHCommand.program)
        box.process.arguments = args
        box.process.environment = environment
        box.process.standardInput = FileHandle.nullDevice
        box.process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        box.process.standardError = errors
        let id = forward.id
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
            self?.state.withLock { entries in
                entries[id]?.stderr.append(contentsOf: lines)
                if let count = entries[id]?.stderr.count, count > 20 { entries[id]?.stderr.removeFirst(count - 20) }
            }
        }
        box.process.terminationHandler = { [weak self] process in
            self?.ended(id, status: process.terminationStatus)
        }
        state.withLock { $0[id] = Entry(box: box, token: token, status: .starting) }
        do {
            try box.process.run()
        } catch {
            state.withLock { _ = $0.removeValue(forKey: id) }
            if let token { AskpassServer.shared.unregister(token) }
            throw LowtideError.commandFailed("ssh couldn't start: \(error.localizedDescription)")
        }
        if let token { AskpassServer.shared.attach(token, pid: box.pid) }
        notify(id, .starting)
        // ExitOnForwardFailure ends ssh within a moment when the forward
        // can't be set up; still running after that, it's up.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            let promoted = state.withLock { entries -> Bool in
                guard var entry = entries[id], entry.box === box, entry.box.isRunning, entry.status == .starting else { return false }
                entry.status = .running(since: Date())
                entries[id] = entry
                return true
            }
            if promoted, let status = status(id) { notify(id, status) }
        }
    }

    private func ended(_ id: String, status code: Int32) {
        let result = state.withLock { entries -> (Status?, String?) in
            guard var entry = entries[id] else { return (nil, nil) }
            let token = entry.token
            if entry.stopping {
                entries[id] = nil
                return (nil, token)
            }
            let reason = Self.reason(entry.stderr, code: code)
            entry.status = .failed(reason)
            entries[id] = entry
            return (entry.status, token)
        }
        if let token = result.1 { AskpassServer.shared.unregister(token) }
        notify(id, result.0)
    }

    /// The last thing ssh said, worded for a person when it's a known failure.
    static func reason(_ stderr: [String], code: Int32) -> String {
        let lines = stderr.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") }
        if lines.contains(where: { $0.contains("Address already in use") || $0.contains("cannot listen to port") }) {
            return "The port is already in use on this Mac"
        }
        if lines.contains(where: { $0.contains("remote port forwarding failed") }) {
            return "The host refused the remote port"
        }
        if lines.contains(where: { $0.contains("Permission denied") }) {
            return "Sign-in failed: give the host a key or a saved password"
        }
        return lines.last ?? "ssh exited with \(code)"
    }

    /// Stops a running tunnel. A deliberate stop isn't a failure.
    public func stop(_ id: String) {
        let entry = state.withLock { entries -> Entry? in
            guard var entry = entries[id] else { return nil }
            if !entry.box.isRunning {
                entries[id] = nil
                return entry
            }
            entry.stopping = true
            entries[id] = entry
            return entry
        }
        guard let entry else { return }
        if entry.box.isRunning {
            entry.box.terminate()
        } else {
            if let token = entry.token { AskpassServer.shared.unregister(token) }
            notify(id, nil)
        }
    }

    /// Forgets a failed tunnel's status.
    public func dismiss(_ id: String) {
        let removed = state.withLock { entries -> Bool in
            guard let entry = entries[id], !entry.box.isRunning else { return false }
            entries[id] = nil
            return true
        }
        if removed { notify(id, nil) }
    }

    public func stopAll() {
        for id in state.withLock({ Array($0.keys) }) { stop(id) }
    }
}
