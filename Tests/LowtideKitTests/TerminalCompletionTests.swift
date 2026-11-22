import Foundation
import Testing
@testable import LowtideKit

@Suite struct TerminalCompletionTests {
    let now = 1_800_000_000_000

    func context(_ cwd: String = "/work/app") -> SuggestionContext {
        var completion = CompletionContext(cwd: cwd)
        completion.entries = [CompletionEntry(name: "src", isDirectory: true), CompletionEntry(name: "README.md", isDirectory: false),
                              CompletionEntry(name: ".env", isDirectory: false)]
        completion.executables = ["git", "gitk", "go", "grep", "pnpm"]
        completion.gitBranches = ["main", "feature/login"]
        completion.gitRemotes = ["origin"]
        completion.gitChanged = ["src/app.ts"]
        completion.packageScripts = ["dev", "build"]
        completion.packageRunner = .pnpm
        var c = SuggestionContext(completion: completion, contextKey: "local", cwd: cwd)
        c.now = now
        return c
    }

    func row(_ command: String, cwd: String = "", key: String = "local", uses: Int = 1, daysAgo: Double = 0,
             success: Int = 0, failure: Int = 0) -> CommandHistoryRow {
        CommandHistoryRow(command: command, contextKey: key, cwd: cwd, useCount: uses, successCount: success,
                          failureCount: failure, lastUsedAt: now - Int(daysAgo * 86_400_000))
    }

    @Test func parsesShellWords() {
        let line = TerminalIntelligence.parseLine("sudo FOO=1 git commit -m 'two words' ")
        #expect(line.words == ["git", "commit", "-m", "two words"])
        #expect(line.current == "" && line.currentStart == 37)
        let piped = TerminalIntelligence.parseLine("cat x | gr")
        #expect(piped.words.isEmpty && piped.current == "gr")
    }

    @Test func ranksThisFolderAboveOtherTerminals() {
        var c = context()
        c.history = [
            row("npm run lint", cwd: "/elsewhere", key: "ssh:prod", uses: 9),
            row("npm run test", cwd: "/work/app", uses: 2),
        ]
        let labels = TerminalIntelligence.suggestions(for: "npm run", context: c).map(\.label)
        #expect(labels.first == "npm run test")
        #expect(labels.contains("npm run lint"))
        let first = TerminalIntelligence.suggestions(for: "npm run", context: c).first
        #expect(first?.description.hasPrefix("2× in this folder") == true)
    }

    @Test func failingCommandsSinkAndSnippetsRise() {
        var c = context()
        c.history = [row("make deploy", failure: 3), row("make docs", success: 3)]
        c.snippets = [(name: "Deploy staging", content: "make deploy-staging")]
        let labels = TerminalIntelligence.suggestions(for: "make d", context: c).map(\.label)
        #expect(labels.contains("make deploy-staging"))
        #expect(labels.firstIndex(of: "make docs")! < labels.firstIndex(of: "make deploy")!)
        // A snippet found by its name, not its command.
        let byName = TerminalIntelligence.suggestions(for: "deploy st", context: c)
        #expect(byName.first?.kind == .snippet && byName.first?.description == "Deploy staging")
        // Multi-line snippets never become one-key completions.
        c.snippets = [(name: "Two", content: "make a\nmake b")]
        #expect(!TerminalIntelligence.suggestions(for: "make", context: c).contains { $0.kind == .snippet })
    }

    @Test func completesSubcommandsBranchesAndPaths() {
        let c = context()
        let sub = TerminalIntelligence.suggestions(for: "git sw", context: c)
        #expect(sub.first?.insertText == "git switch ")
        let branches = TerminalIntelligence.suggestions(for: "git switch ma", context: c)
        #expect(branches.first?.insertText == "git switch main ")
        let paths = TerminalIntelligence.suggestions(for: "cd s", context: c)
        #expect(paths.first?.insertText == "cd src/")
        // Dotfiles only when the dot is typed.
        #expect(!TerminalIntelligence.suggestions(for: "cat ", context: c).contains { $0.label == ".env" })
        #expect(TerminalIntelligence.suggestions(for: "cat .", context: c).contains { $0.label == ".env" })
        let options = TerminalIntelligence.suggestions(for: "git commit --am", context: c)
        #expect(options.first?.insertText == "git commit --amend ")
    }

    @Test func offersProjectTasksAndCommands() {
        let c = context()
        let tasks = TerminalIntelligence.suggestions(for: "pnpm d", context: c)
        #expect(tasks.contains { $0.insertText == "pnpm dev" || $0.insertText == "pnpm dev " })
        let commands = TerminalIntelligence.suggestions(for: "gi", context: c)
        #expect(commands.contains { $0.kind == .executable && $0.label == "gitk" })
        // One letter shows nothing unless it starts what usually runs next.
        #expect(TerminalIntelligence.suggestions(for: "g", context: c).isEmpty)
        var next = c
        next.shellHistory = ["git push", "git commit -m x", "git push", "git commit -m y"]
        next.lastCommand = "git commit -m x"
        let predicted = TerminalIntelligence.suggestions(for: "g", context: next)
        #expect(predicted.first?.label == "git push" && predicted.first?.description == "Usually runs next")
    }

    @Test func flagsRiskyCommands() {
        #expect(TerminalIntelligence.isRisky("sudo rm -rf /tmp/x"))
        #expect(TerminalIntelligence.isRisky("git push origin main --force"))
        #expect(TerminalIntelligence.isRisky("curl -fsSL https://x.sh | sh"))
        #expect(!TerminalIntelligence.isRisky("git push origin main"))
        #expect(!TerminalIntelligence.isRisky("rm notes.txt"))
    }

    @Test func shellEscapesOnlyWhenNeeded() {
        #expect(TerminalIntelligence.shellEscape("src/app.ts") == "src/app.ts")
        #expect(TerminalIntelligence.shellEscape("My File") == "'My File'")
        #expect(TerminalIntelligence.shellEscape("it's") == "'it'\\''s'")
    }

    @Test func dedupesAndCapsAtSeven() {
        var c = context()
        c.history = (0..<20).map { row("echo \($0)") } + [row("echo 1", cwd: "/work/app")]
        let list = TerminalIntelligence.suggestions(for: "echo", context: c)
        #expect(list.count == 7)
        #expect(Set(list.map(\.insertText)).count == list.count)
        #expect(list.first?.label == "echo 1")
    }

    @Test func specsLoad() {
        #expect(CompletionSpecs.all.count == 44)
        #expect(CompletionSpecs.all["git"]?.subcommand("push")?.positional == [.remotes, .branches])
        #expect(CompletionSpecs.wrappers.contains("sudo"))
    }
}

@Suite struct TerminalInputLineTests {
    @Test func mirrorsTypingAndRecordsOnEnter() {
        var line = InputLine()
        _ = line.feed("git stat")
        _ = line.feed("\u{7f}")
        #expect(line.text == "git sta")
        _ = line.feed("\u{1b}[D")
        _ = line.feed("x")
        #expect(line.text == "git stxa" && line.cursor == 7)
        _ = line.feed("\u{05}")
        #expect(line.atEnd)
        #expect(line.feed("\r") == .submitted(command: "git stxa", accepted: false))
        #expect(line.text.isEmpty)
    }

    @Test func forgetsWhatItCannotMirror() {
        var line = InputLine()
        _ = line.feed("git ch")
        #expect(line.feed("\t") == .hide)
        #expect(line.unknown)
        #expect(line.feed("\r") == .submitted(command: nil, accepted: false))
        _ = line.feed(" secret-thing")
        #expect(line.feed("\r") == .submitted(command: nil, accepted: false))
        _ = line.feed("export API_KEY=abc")
        #expect(line.feed("\r") == .submitted(command: nil, accepted: false))
        _ = line.feed("ls")
        #expect(line.feed("ls", alternateScreen: true) == .hide && line.text.isEmpty)
    }

    @Test func editsWordsAndLines() {
        var line = InputLine()
        _ = line.feed("docker compose up")
        _ = line.feed("\u{17}")
        #expect(line.text == "docker compose ")
        _ = line.feed("\u{01}")
        _ = line.feed("\u{0b}")
        #expect(line.text.isEmpty)
        _ = line.feed("a\nb")
        #expect(line.text == "b")
    }

    @Test func acceptsSuggestionsInPlaceOrByRetyping() {
        var line = InputLine()
        _ = line.feed("git sw")
        #expect(line.accept("git switch ") == "itch ")
        #expect(line.feed("\r") == .submitted(command: "git switch", accepted: true))
        _ = line.feed("gti")
        #expect(line.accept("git") == "\u{05}\u{15}git")
    }

    @Test func watchesForSecretPrompts() {
        var watcher = PromptWatcher()
        #expect(watcher.feed("[sudo] password for me: ") == .some(.password))
        #expect(watcher.feed("") == nil)
        let ended = watcher.inputEnds("\r")
        #expect(ended)
        #expect(watcher.current == nil)
        #expect(watcher.feed("Enter passphrase for key '/Users/me/.ssh/id_ed25519': ") == .some(.passphrase))
        #expect(watcher.feed("\r\n\u{1b}[1mme@mac\u{1b}[0m ~ % ") == .some(nil))
        #expect(watcher.feed("Password: ") == .some(.password))
        #expect(watcher.feed("ls\r\n") == .some(nil))
    }
}

@Suite struct TerminalContextTests {
    @Test func readsMakeTargetsNotAssignments() {
        let makefile = ".PHONY: build\nCC := clang\nbuild: deps\n\tcargo build\ntest lint:\n%.o: %.c\n"
        #expect(CompletionContext.parseMakeTargets(makefile) == ["build", "test", "lint"])
    }

    @Test func readsJustRecipes() {
        let justfile = "set shell := [\"zsh\"]\nversion := \"1\"\n# comment\ndev port=\"3000\":\n  echo\n@fmt:\n  x\n[private]\nhelper:\n"
        #expect(CompletionContext.parseJustRecipes(justfile) == ["dev", "fmt", "helper"])
    }

    @Test func readsComposeServices() {
        let compose = "name: app\nservices:\n  web:\n    image: x\n    ports:\n      - 80\n  db:\n    image: y\nvolumes:\n  data:\n"
        #expect(CompletionContext.parseComposeServices(compose) == ["web", "db"])
    }

    @Test func readsSSHHostsWithoutPatterns() {
        let config = "Host *\n  AddKeysToAgent yes\nHost prod staging\n  User me\nhost *.internal\n"
        #expect(CompletionContext.parseSSHHosts(config) == ["prod", "staging"])
    }

    @Test func readsGitState() {
        #expect(CompletionContext.parsePorcelain(" M src/app.tsx\nR  old.rs -> new.rs\n?? notes.md\n") == ["src/app.tsx", "new.rs", "notes.md"])
        #expect(CompletionContext.parseBranches("main\norigin/main\norigin/feature\norigin\nHEAD\n") == ["main", "feature"])
    }

    @Test func readsShellHistory() throws {
        #expect(CommandHistory.parseHistoryLine(": 1712345678:0;git status") == "git status")
        #expect(CommandHistory.parseHistoryLine("  ls -la ") == "ls -la")
        // "é" is 0xC3 0xA9; zsh metafies 0xA9 as 0x83 0x89.
        #expect(CommandHistory.unmetafy(Data([0x61, 0xC3, 0x83, 0x89])) == Data([0x61, 0xC3, 0xA9]))
        let home = FileManager.default.temporaryDirectory.appending(path: "lowtide-hist-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        var bytes = Data(": 1:0;git pull\n: 2:0;echo caf".utf8)
        bytes.append(contentsOf: [0xC3, 0x83, 0x89])
        bytes.append(Data("\n: 3:0;git pull\n: 4:0;x\n".utf8))
        try bytes.write(to: home.appending(path: ".zsh_history"))
        #expect(CommandHistory.shellHistory(home: home) == ["git pull", "echo café"])
    }

    @Test func keepsHistoryInTheVault() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "lowtide-\(UUID()).db")
        let db = try SQLiteDatabase(url: url, migrations: Vault.migrations)
        await CommandHistory.record("git status", contextKey: "local", cwd: "/a", accepted: false, db: db)
        await CommandHistory.record("git status", contextKey: "local", cwd: "/a", accepted: true, db: db)
        await CommandHistory.record("x", contextKey: "local", cwd: "/a", accepted: false, db: db)
        await CommandHistory.recordOutcome("git status", contextKey: "local", cwd: "/a", succeeded: false, db: db)
        let rows = await CommandHistory.load(db)
        #expect(rows.count == 1)
        #expect(rows.first?.useCount == 2 && rows.first?.acceptCount == 1 && rows.first?.failureCount == 1)
        let remembered = CommandHistory.remember(rows, command: "git status", contextKey: "local", cwd: "/a", accepted: true)
        #expect(remembered.count == 1 && remembered[0].useCount == 3)
        #expect(CommandHistory.isSensitive("curl -H 'Authorization: Bearer x'") && CommandHistory.isSensitive("mysql -pSecret"))
        #expect(!CommandHistory.isSensitive("git status"))
    }

    @Test func listsFolders() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "lowtide-ls-\(UUID())")
        try FileManager.default.createDirectory(at: dir.appending(path: "b-folder"), withIntermediateDirectories: true)
        try Data().write(to: dir.appending(path: "a-file"))
        defer { try? FileManager.default.removeItem(at: dir) }
        let entries = CompletionContext.listDirectory(cwd: dir.path, "")
        #expect(entries == [CompletionEntry(name: "b-folder", isDirectory: true), CompletionEntry(name: "a-file", isDirectory: false)])
        #expect(CompletionContext.listDirectory(cwd: "/", dir.path + "/").count == 2)
    }
}
