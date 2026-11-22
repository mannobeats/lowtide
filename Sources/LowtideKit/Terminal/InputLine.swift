import Foundation

/// The line being typed at a shell prompt, mirrored from the keys sent to
/// the shell, so autocomplete knows what to suggest and history knows what
/// ran. When the shell changes the line in a way that can't be mirrored
/// (its own Tab completion, history recall, a paste), the line is "unknown"
/// until Enter: no suggestions, nothing recorded.
public struct InputLine: Equatable, Sendable {
    public private(set) var characters: [Character] = []
    /// The cursor, in characters.
    public private(set) var cursor = 0
    public private(set) var unknown = false
    /// The line a suggestion produced, until it's edited.
    public private(set) var accepted: String?

    public init() {}

    public var text: String { String(characters) }
    public var atEnd: Bool { cursor == characters.count }

    public enum Effect: Equatable, Sendable {
        /// Suggestions should follow the new line.
        case refresh
        /// Close any suggestions.
        case hide
        /// Enter: a command to remember (nil when it shouldn't be).
        case submitted(command: String?, accepted: Bool)
    }

    /// Application-mode cursor keys (smkx, enabled by oh-my-zsh) mapped to normal.
    static let cursorKeys: [String: String] = [
        "\u{1b}OC": "\u{1b}[C", "\u{1b}OD": "\u{1b}[D", "\u{1b}OF": "\u{1b}[F", "\u{1b}OH": "\u{1b}[H",
    ]

    static func hasUnsupportedControl(_ data: String) -> Bool {
        data.unicodeScalars.contains { $0.value == 27 || $0.value < 9 || ($0.value > 10 && $0.value < 32) }
    }

    public mutating func reset() {
        characters = []
        cursor = 0
        unknown = false
        accepted = nil
    }

    /// Feeds the bytes just sent to the shell. On the alternate screen (vim,
    /// less) nothing is a command line.
    public mutating func feed(_ raw: String, alternateScreen: Bool = false) -> Effect {
        let data = Self.cursorKeys[raw] ?? raw
        if alternateScreen {
            reset()
            return .hide
        }
        switch data {
        case "\r", "\n":
            let line = text
            let command = line.trimmingCharacters(in: .whitespaces)
            // A leading space is the shell convention for "don't remember this".
            let recordable = !command.isEmpty && !unknown && !line.hasPrefix(" ") && !CommandHistory.isSensitive(command)
            // Word completions end in a space; the command doesn't.
            let wasAccepted = accepted?.trimmingCharacters(in: .whitespaces) == command
            reset()
            return .submitted(command: recordable ? command : nil, accepted: wasAccepted)
        case "\u{7f}":
            if cursor > 0 {
                characters.remove(at: cursor - 1)
                cursor -= 1
            }
            accepted = nil
            return .refresh
        case "\u{03}":
            reset()
            return .hide
        case "\u{15}": // ^U: delete to the start
            characters.removeFirst(cursor)
            cursor = 0
            accepted = nil
            return .refresh
        case "\u{0b}": // ^K: delete to the end
            characters.removeLast(characters.count - cursor)
            accepted = nil
            return .refresh
        case "\u{17}": // ^W: delete the word before the cursor
            var before = Array(characters[..<cursor])
            while let last = before.last, last.isWhitespace { before.removeLast() }
            while let last = before.last, !last.isWhitespace { before.removeLast() }
            characters = before + characters[cursor...]
            cursor = before.count
            accepted = nil
            return .refresh
        case "\u{1b}[D", "\u{02}":
            cursor = max(0, cursor - 1)
            return .hide
        case "\u{1b}[C", "\u{06}":
            cursor = min(characters.count, cursor + 1)
            return .refresh
        case "\u{1b}[H", "\u{01}":
            cursor = 0
            return .hide
        case "\u{1b}[F", "\u{05}":
            cursor = characters.count
            return .refresh
        default:
            break
        }
        if data == "\t" || data == "\u{1b}[A" || data == "\u{1b}[B" || Self.hasUnsupportedControl(data) {
            unknown = true
            accepted = nil
            return .hide
        }
        let normalized = data.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let parts = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        if parts.count > 1 {
            characters = Array(parts.last ?? "")
            cursor = characters.count
        } else {
            let insertion = Array(normalized)
            characters.insert(contentsOf: insertion, at: cursor)
            cursor += insertion.count
        }
        accepted = nil
        return .refresh
    }

    /// Accepts a suggestion and returns the bytes to send: the rest of it
    /// when it extends the line, else ^E ^U (clear the line in bash and zsh
    /// emacs mode, wherever the cursor is) and the whole of it.
    public mutating func accept(_ insertText: String) -> String {
        let current = text
        let data = atEnd && insertText.hasPrefix(current)
            ? String(insertText.dropFirst(current.count))
            : "\u{05}\u{15}" + insertText
        characters = Array(insertText)
        cursor = characters.count
        unknown = false
        accepted = insertText
        return data
    }
}
