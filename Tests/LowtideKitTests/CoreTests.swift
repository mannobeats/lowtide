import Foundation
import Testing
@testable import LowtideKit

@Suite struct CoreTests {
    @Test func fuzzyMatchesInOrder() {
        #expect(Fuzzy.score("pkt", "Packets") != nil)
        #expect(Fuzzy.score("xyz", "Packets") == nil)
        #expect(Fuzzy.score("net", "Network")! > Fuzzy.score("net", "Open Internet")!)
    }

    @Test func formatsBytes() {
        #expect(Format.bytes(999) == "999 B")
        #expect(Format.bytes(3_700_000_000) == "3.7 GB")
        #expect(Format.bytes(227_100_000) == "227 MB")
    }

    @Test func quotesShellArguments() {
        #expect(Admin.quote("it's") == "'it'\\''s'")
        #expect(Admin.escape(#"/bin/mv '/A "b"\c' x"#) == #"/bin/mv '/A \"b\"\\c' x"#)
    }

    @Test func runsCommands() async throws {
        let out = try await Shell.run("/bin/echo", ["hello"])
        #expect(out.stdout == "hello\n" && out.ok)
        let stream = try await Shell.stream("/bin/sh", ["-c", "echo a; echo b 1>&2; printf 'x\\ry'"]) { _ in }
        #expect(stream.stdout.split(separator: "\n") == ["a", "b", "y"])
    }

    @Test func commandsEndOnTimeoutAndDontWaitForAGrandchild() async throws {
        let clock = ContinuousClock()
        // A daemon the tool started keeps the pipe open after the tool exits.
        var out: CommandOutput?
        let held = try await clock.measure { out = try await Shell.run("/bin/sh", ["-c", "echo up; sleep 30 & exit 3"]) }
        #expect(out?.status == 3 && out?.stdout == "up\n")
        #expect(held < .seconds(10))
        await #expect(throws: LowtideError.self) { try await Shell.run("/bin/sleep", ["30"], timeout: .seconds(1)) }
        let task = Task { try await Shell.run("/bin/sleep", ["30"]) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let cancelled = try await clock.measure { _ = try? await task.value }
        #expect(cancelled < .seconds(5))
    }

    @Test func readsLinesUpToALimit() async {
        let some = await LineReader.lines("/usr/bin/yes", ["line"], limit: 3, timeout: .seconds(5))
        #expect(some.lines == ["line", "line", "line"] && some.truncated && !some.timedOut)
        let slow = await LineReader.lines("/bin/sleep", ["30"], timeout: .milliseconds(300))
        #expect(slow.timedOut && slow.lines.isEmpty)
        let missing = await LineReader.lines("/nonexistent/tool", [], timeout: .seconds(1))
        #expect(missing.status == nil)
    }

    @Test func sqliteMigratesAndQueries() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "lowtide-\(UUID()).db")
        let db = try SQLiteDatabase(url: url, migrations: Vault.migrations)
        try await db.execute("INSERT INTO snippets (id, name, content, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
                             ["a", "List", "ls -la", 1, 1])
        let rows = try await db.query("SELECT * FROM snippets")
        #expect(rows.first?.string("content") == "ls -la")
    }

    /// macOS answers permission questions directly (App Management can't be
    /// read from the permission database on macOS 27).
    @Test func preflightAnswersForPermissions() {
        #expect(TCCPreflight.state("kTCCServiceSystemPolicyAppBundles") != nil)
        #expect(TCCPreflight.state("kTCCServiceSystemPolicyAllFiles") != nil)
    }
}
