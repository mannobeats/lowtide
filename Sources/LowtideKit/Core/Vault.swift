import Foundation

/// The vault: hosts, groups, identities, forwards, snippets, command history
/// and the activity log, in `vault.db`. Append a migration; never edit one.
public enum Vault {
    public static let migrations: [String] = [
        #"""
        CREATE TABLE IF NOT EXISTS identities (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            kind TEXT NOT NULL CHECK (kind IN ('ssh_key', 'password')),
            username TEXT,
            key_path TEXT,
            public_key TEXT,
            has_passphrase INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS hosts (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            hostname TEXT NOT NULL,
            port INTEGER NOT NULL DEFAULT 22,
            username TEXT NOT NULL,
            identity_id TEXT REFERENCES identities(id) ON DELETE SET NULL,
            jump_host_id TEXT REFERENCES hosts(id) ON DELETE SET NULL,
            color TEXT,
            tags TEXT,
            notes TEXT,
            last_connected_at INTEGER,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_hosts_name ON hosts(name);
        CREATE INDEX IF NOT EXISTS idx_hosts_last_connected ON hosts(last_connected_at DESC);
"""#,
        #"""
        -- Groups: nested via parent_id. We deliberately omit ON DELETE clauses on
        -- the inline REFERENCES so that this migration can run regardless of
        -- `PRAGMA foreign_keys`. Cascade behavior is enforced at the app layer.
        CREATE TABLE IF NOT EXISTS groups (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            parent_id TEXT,
            color TEXT,
            identity_id TEXT,
            jump_host_id TEXT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        );

        -- SQLite forbids ADD COLUMN with a REFERENCES clause when foreign_keys is
        -- ON, so this is a plain TEXT column. Linkage is still enforced when we
        -- read joins in the frontend.
        ALTER TABLE hosts ADD COLUMN group_id TEXT;

        CREATE TABLE IF NOT EXISTS port_forwards (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            host_id TEXT NOT NULL,
            kind TEXT NOT NULL CHECK (kind IN ('local', 'remote', 'dynamic')),
            bind_host TEXT,
            bind_port INTEGER NOT NULL,
            target_host TEXT,
            target_port INTEGER,
            auto_start INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_port_forwards_host ON port_forwards(host_id);

        CREATE TABLE IF NOT EXISTS snippets (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            content TEXT NOT NULL,
            tags TEXT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_snippets_name ON snippets(name);
"""#,
        #"""
        CREATE TABLE IF NOT EXISTS command_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            command TEXT NOT NULL,
            context_key TEXT NOT NULL,
            cwd TEXT NOT NULL DEFAULT '',
            use_count INTEGER NOT NULL DEFAULT 1,
            accept_count INTEGER NOT NULL DEFAULT 0,
            success_count INTEGER NOT NULL DEFAULT 0,
            failure_count INTEGER NOT NULL DEFAULT 0,
            last_used_at INTEGER NOT NULL,
            created_at INTEGER NOT NULL,
            UNIQUE(command, context_key, cwd)
        );

        CREATE INDEX IF NOT EXISTS idx_command_history_context
            ON command_history(context_key, last_used_at DESC);

        CREATE INDEX IF NOT EXISTS idx_command_history_command
            ON command_history(command);
"""#,
        #"""
        CREATE TABLE IF NOT EXISTS snippet_targets (
            snippet_id TEXT NOT NULL,
            target_type TEXT NOT NULL CHECK (target_type IN ('local', 'host', 'group', 'all_hosts')),
            target_id TEXT NOT NULL DEFAULT '',
            PRIMARY KEY (snippet_id, target_type, target_id)
        );

        CREATE INDEX IF NOT EXISTS idx_snippet_targets_snippet
            ON snippet_targets(snippet_id);
"""#,
        #"""
        CREATE TABLE IF NOT EXISTS activity_log (
            id TEXT PRIMARY KEY,
            action TEXT NOT NULL,
            item_name TEXT NOT NULL,
            source_name TEXT NOT NULL,
            status TEXT NOT NULL CHECK (status IN ('success', 'failure')),
            detail TEXT,
            created_at INTEGER NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_activity_log_created_at
            ON activity_log(created_at DESC);
"""#,
        #"""
        ALTER TABLE activity_log ADD COLUMN previous_version TEXT;
        ALTER TABLE activity_log ADD COLUMN resulting_version TEXT;
        ALTER TABLE activity_log ADD COLUMN duration_ms INTEGER;
"""#,
    ]

    public static let url = Paths.data.appending(path: "vault.db")

    /// The one shared connection, opened on first use.
    public static let shared: SQLiteDatabase? = {
        do { return try SQLiteDatabase(url: url, migrations: migrations) } catch {
            Log.store.fault("vault unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }()

    public static func now() -> Int { Int(Date().timeIntervalSince1970 * 1000) }
}
