import Foundation

/// Watches a session's output for a password or passphrase prompt (sudo,
/// ssh, git, gpg, mysql…) on the last line, so the pane can offer a saved
/// credential, and withdraws the offer as soon as anything else is printed.
public struct PromptWatcher: Sendable {
    public enum Prompt: Equatable, Sendable {
        case password
        case passphrase
    }

    private var tail = ""
    public private(set) var current: Prompt?

    public init() {}

    static let ansi = try! NSRegularExpression(pattern: "\u{1b}\\[[0-9;?]*[A-Za-z]|\u{1b}\\][^\u{07}\u{1b}]*(\u{07}|\u{1b}\\\\)")
    static let secret = try! NSRegularExpression(pattern: #"(pass(word|phrase|code)|\bpin\b)[^\r\n]*:\s*$"#, options: .caseInsensitive)
    static let passphrase = try! NSRegularExpression(pattern: "enter passphrase for", options: .caseInsensitive)

    /// Feeds decoded output; returns the prompt state when it changed.
    public mutating func feed(_ chunk: String) -> Prompt?? {
        tail = String((tail + chunk).suffix(300))
        let plain = Self.ansi.stringByReplacingMatches(in: tail, range: NSRange(tail.startIndex..., in: tail), withTemplate: "")
        // `\r\n` is one Character, so split on any newline.
        let lastLine = plain.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).last
            .map { String($0).replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) } ?? ""
        let range = NSRange(lastLine.startIndex..., in: lastLine)
        let next: Prompt?
        if Self.secret.firstMatch(in: lastLine, range: range) != nil {
            next = Self.passphrase.firstMatch(in: lastLine, range: range) != nil ? .passphrase : .password
        } else if current != nil, chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            next = current
        } else {
            next = nil
        }
        guard next != current else { return nil }
        current = next
        return .some(next)
    }

    /// Enter, ^C or ^D ends a prompt one way or another.
    public mutating func inputEnds(_ data: String) -> Bool {
        guard current != nil, data.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\u{03}" || $0 == "\u{04}" }) else {
            return false
        }
        clear()
        return true
    }

    public mutating func clear() {
        tail = ""
        current = nil
    }
}
