import Darwin
import Foundation
import os

/// The terminal sessions that are open, for the parts of the app that
/// watch what runs in them (install watch, the receipts), and the receipts
/// those parts hand back for the line under each pane.
public final class TerminalSessions: Sendable {
    public static let shared = TerminalSessions()

    /// What a session is running right now.
    public struct Foreground: Equatable, Sendable {
        public let id: String
        /// `local` or `ssh`.
        public let kind: String
        public let shell: pid_t
        /// The process group in the foreground of its terminal: one other
        /// than the shell's own is a running command.
        public let group: pid_t
    }

    /// A finished command's receipt, shown under its pane until the next
    /// one starts.
    public struct Receipt: Equatable, Sendable {
        public enum Verdict: String, Sendable { case info, notice, alert }
        public var sessionID: String
        /// Where the full receipt lives (the History page), when it has one.
        public var runID: String?
        public var command: String
        public var started: Date
        public var ended: Date
        public var verdict: Verdict
        /// "3 hosts · 12 files", or the first finding when it isn't info.
        public var summary: String

        public init(sessionID: String, runID: String?, command: String, started: Date, ended: Date, verdict: Verdict, summary: String) {
            self.sessionID = sessionID
            self.runID = runID
            self.command = command
            self.started = started
            self.ended = ended
            self.verdict = verdict
            self.summary = summary
        }
    }

    /// A command still running in a session, followed live.
    public struct Activity: Equatable, Sendable {
        public var sessionID: String
        public var command: String
        public var started: Date
        public var hosts: Int
        public var files: Int

        public init(sessionID: String, command: String, started: Date, hosts: Int, files: Int) {
            self.sessionID = sessionID
            self.command = command
            self.started = started
            self.hosts = hosts
            self.files = files
        }
    }

    private struct Session {
        var kind: String
        var shell: pid_t
        var fd: Int32
    }

    private struct State {
        var sessions: [String: Session] = [:]
        var receipts: [String: Receipt] = [:]
        var activity: [String: Activity] = [:]
        var observer: (@Sendable () -> Void)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public func register(_ id: String, kind: String, shell: pid_t, fd: Int32) {
        state.withLock { $0.sessions[id] = Session(kind: kind, shell: shell, fd: fd) }
    }

    public func unregister(_ id: String) {
        state.withLock {
            $0.sessions[id] = nil
            $0.receipts[id] = nil
            $0.activity[id] = nil
        }
        changed()
    }

    public func foregrounds() -> [Foreground] {
        state.withLock { s in
            s.sessions.compactMap { id, session in
                let group = tcgetpgrp(session.fd)
                return group > 0 ? Foreground(id: id, kind: session.kind, shell: session.shell, group: group) : nil
            }
        }
    }

    /// Whether a command (not the shell itself) holds the session's terminal.
    public func isBusy(_ id: String) -> Bool {
        state.withLock { s in
            guard let session = s.sessions[id] else { return false }
            let group = tcgetpgrp(session.fd)
            return group > 0 && group != session.shell
        }
    }

    // MARK: Receipts

    /// Called (on any thread) when a receipt or the live activity changes.
    public func observe(_ handler: @escaping @Sendable () -> Void) {
        state.withLock { $0.observer = handler }
    }

    private func changed() { state.withLock { $0.observer }?() }

    public func put(_ receipt: Receipt) {
        state.withLock {
            $0.receipts[receipt.sessionID] = receipt
            $0.activity[receipt.sessionID] = nil
        }
        changed()
    }

    public func dismiss(_ sessionID: String) {
        state.withLock { _ = $0.receipts.removeValue(forKey: sessionID) }
        changed()
    }

    public func setActivity(_ activity: [Activity]) {
        state.withLock { $0.activity = Dictionary(activity.map { ($0.sessionID, $0) }, uniquingKeysWith: { a, _ in a }) }
        changed()
    }

    public func receipt(_ sessionID: String) -> Receipt? { state.withLock { $0.receipts[sessionID] } }
    public func activity(_ sessionID: String) -> Activity? { state.withLock { $0.activity[sessionID] } }
}
