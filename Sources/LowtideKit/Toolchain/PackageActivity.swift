import Foundation

/// One recorded operation: an update, a removal, a cleanup. A row
/// of the `activity_log` table, so an imported vault keeps its history.
public struct ActivityEntry: Sendable, Identifiable, Hashable {
    public var id: String
    public var action: String
    public var itemName: String
    public var sourceName: String
    public var succeeded: Bool
    public var detail: String?
    public var createdAt: Date
    public var previousVersion: String?
    public var resultingVersion: String?
    public var duration: TimeInterval?

    public init(id: String = UUID().uuidString, action: String, itemName: String, sourceName: String,
                succeeded: Bool, detail: String? = nil, createdAt: Date = .now,
                previousVersion: String? = nil, resultingVersion: String? = nil, duration: TimeInterval? = nil) {
        self.id = id
        self.action = action
        self.itemName = itemName
        self.sourceName = sourceName
        self.succeeded = succeeded
        self.detail = detail
        self.createdAt = createdAt
        self.previousVersion = previousVersion
        self.resultingVersion = resultingVersion
        self.duration = duration
    }
}

/// The record of package operations in the vault, newest first.
public enum PackageActivity {
    public static func record(_ entry: ActivityEntry, in database: SQLiteDatabase? = Vault.shared) async throws {
        guard let database else { throw LowtideError.notFound("The vault") }
        try await database.execute(
            """
            INSERT INTO activity_log
              (id, action, item_name, source_name, status, detail, created_at,
               previous_version, resulting_version, duration_ms)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [entry.id, entry.action, entry.itemName, entry.sourceName, entry.succeeded ? "success" : "failure",
             entry.detail, Int(entry.createdAt.timeIntervalSince1970 * 1000), entry.previousVersion,
             entry.resultingVersion, entry.duration.map { Int(($0 * 1000).rounded()) }])
    }

    public static func list(limit: Int = 250, in database: SQLiteDatabase? = Vault.shared) async throws -> [ActivityEntry] {
        guard let database else { throw LowtideError.notFound("The vault") }
        return try await database.query("SELECT * FROM activity_log ORDER BY created_at DESC LIMIT ?", [limit]).compactMap { row in
            guard let id = row.string("id"), let action = row.string("action") else { return nil }
            return ActivityEntry(
                id: id, action: action, itemName: row.string("item_name") ?? "", sourceName: row.string("source_name") ?? "",
                succeeded: row.string("status") == "success", detail: row.string("detail"),
                createdAt: Date(timeIntervalSince1970: Double(row.int("created_at") ?? 0) / 1000),
                previousVersion: row.string("previous_version"), resultingVersion: row.string("resulting_version"),
                duration: row.int("duration_ms").map { Double($0) / 1000 })
        }
    }

    public static func clear(in database: SQLiteDatabase? = Vault.shared) async throws {
        guard let database else { throw LowtideError.notFound("The vault") }
        try await database.execute("DELETE FROM activity_log")
    }
}
