import Foundation

/// A command run in a terminal, as the vault's `command_history` keeps it:
/// per context (local, or one SSH host) and folder.
public struct CommandHistoryRow: Equatable, Sendable {
    public var command: String
    public var contextKey: String
    public var cwd: String
    public var useCount: Int
    public var acceptCount: Int
    public var successCount: Int
    public var failureCount: Int
    /// Milliseconds since 1970.
    public var lastUsedAt: Int

    public init(command: String, contextKey: String, cwd: String = "", useCount: Int = 1, acceptCount: Int = 0,
                successCount: Int = 0, failureCount: Int = 0, lastUsedAt: Int) {
        self.command = command
        self.contextKey = contextKey
        self.cwd = cwd
        self.useCount = useCount
        self.acceptCount = acceptCount
        self.successCount = successCount
        self.failureCount = failureCount
        self.lastUsedAt = lastUsedAt
    }
}

/// The terminal's memory of commands: the vault table for ranking, and the
/// shell's own history files for order (what usually runs next).
public enum CommandHistory {
    /// Commands that carry secrets never enter history or autocomplete.
    public static func isSensitive(_ command: String) -> Bool {
        command.range(of: #"(token|secret|passw|api[_-]?key|bearer|authorization:|-p\S)"#,
                      options: [.regularExpression, .caseInsensitive]) != nil
    }

    public static func load(_ db: SQLiteDatabase? = Vault.shared) async -> [CommandHistoryRow] {
        guard let db else { return [] }
        let rows = (try? await db.query("SELECT * FROM command_history ORDER BY last_used_at DESC LIMIT 2000")) ?? []
        return rows.map {
            CommandHistoryRow(command: $0.string("command") ?? "", contextKey: $0.string("context_key") ?? "",
                              cwd: $0.string("cwd") ?? "", useCount: $0.int("use_count") ?? 1,
                              acceptCount: $0.int("accept_count") ?? 0, successCount: $0.int("success_count") ?? 0,
                              failureCount: $0.int("failure_count") ?? 0, lastUsedAt: $0.int("last_used_at") ?? 0)
        }
    }

    public static func record(_ command: String, contextKey: String, cwd: String, accepted: Bool,
                              db: SQLiteDatabase? = Vault.shared) async {
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let db, (2...2000).contains(normalized.count) else { return }
        let now = Vault.now()
        _ = try? await db.execute("""
            INSERT INTO command_history (command, context_key, cwd, use_count, accept_count, last_used_at, created_at)
            VALUES (?, ?, ?, 1, ?, ?, ?)
            ON CONFLICT(command, context_key, cwd) DO UPDATE SET
              use_count = use_count + 1,
              accept_count = accept_count + excluded.accept_count,
              last_used_at = excluded.last_used_at
            """, [normalized, contextKey, cwd, accepted ? 1 : 0, now, now])
    }

    public static func recordOutcome(_ command: String, contextKey: String, cwd: String, succeeded: Bool,
                                     db: SQLiteDatabase? = Vault.shared) async {
        guard let db else { return }
        let column = succeeded ? "success_count" : "failure_count"
        _ = try? await db.execute("UPDATE command_history SET \(column) = \(column) + 1 WHERE command = ? AND context_key = ? AND cwd = ?",
                                  [command.trimmingCharacters(in: .whitespacesAndNewlines), contextKey, cwd])
    }

    /// The same bookkeeping in memory, so a pane ranks what it just ran
    /// without reloading the table.
    public static func remember(_ rows: [CommandHistoryRow], command: String, contextKey: String, cwd: String,
                                accepted: Bool, now: Int = Vault.now()) -> [CommandHistoryRow] {
        var next = rows.first { $0.command == command && $0.contextKey == contextKey && $0.cwd == cwd }
            ?? CommandHistoryRow(command: command, contextKey: contextKey, cwd: cwd, useCount: 0, lastUsedAt: now)
        next.useCount += 1
        next.acceptCount += accepted ? 1 : 0
        next.lastUsedAt = now
        let rest = rows.filter { !($0.command == command && $0.contextKey == contextKey && $0.cwd == cwd) }
        return Array(([next] + rest).prefix(2000))
    }

    // MARK: Shell history files

    /// The newest 500 distinct commands from zsh and bash history, newest first.
    public static func shellHistory(home: URL = Paths.home) -> [String] {
        var seen = Set<String>()
        var commands: [String] = []
        for name in [".zsh_history", ".bash_history"] {
            guard let bytes = try? Data(contentsOf: home.appending(path: name)) else { continue }
            let text = String(decoding: unmetafy(bytes), as: UTF8.self).replacingOccurrences(of: "\\\n", with: " ")
            for line in text.split(separator: "\n").reversed() {
                let command = parseHistoryLine(String(line))
                guard (2...500).contains(command.count), seen.insert(command).inserted else { continue }
                commands.append(command)
                if commands.count >= 500 { return commands }
            }
        }
        return commands
    }

    /// `: 1712345678:0;git status` (zsh extended history) or a plain line.
    public static func parseHistoryLine(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix(": "), let semicolon = trimmed.firstIndex(of: ";") {
            return trimmed[trimmed.index(after: semicolon)...].trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }

    /// zsh stores non-ASCII history bytes "metafied": 0x83 followed by the
    /// byte XOR 0x20. Undo that so UTF-8 commands survive.
    public static func unmetafy(_ bytes: Data) -> Data {
        var out = Data(capacity: bytes.count)
        var iterator = bytes.makeIterator()
        while let byte = iterator.next() {
            if byte == 0x83 {
                if let next = iterator.next() { out.append(next ^ 0x20) }
            } else {
                out.append(byte)
            }
        }
        return out
    }
}
