import Darwin
import Foundation
import Testing
@testable import LowtideKit

private func argv(_ line: String) -> [String] { line.split(separator: " ").map(String.init) }

@Suite struct ProtectionRunTests {
    @Test func spotsInstallers() {
        let cases: [(String, Ecosystem?)] = [
            ("npm install", .npm),
            ("npm i left-pad", .npm),
            ("node /opt/homebrew/lib/node_modules/npm/bin/npm-cli.js install", .npm),
            ("pnpm add react", .npm),
            ("yarn add -D vite", .npm),
            ("bun install", .npm),
            ("npm run dev", nil),
            ("npm test", nil),
            ("pnpm dlx create-vite", nil),
            ("python3 -m pip install requests", .python),
            ("pip3 install -r requirements.txt", .python),
            ("uv pip install ruff", .python),
            ("uv sync", .python),
            ("python3 manage.py runserver", nil),
            ("/bin/bash /opt/homebrew/Library/Homebrew/brew.sh install jq", .homebrew),
            ("brew upgrade", .homebrew),
            ("brew list", nil),
            ("brew update", nil),
            ("cargo install ripgrep", .cargo),
            ("cargo build", nil),
            ("gem install rails", .ruby),
            ("bundle install", .ruby),
            ("go install golang.org/x/tools/gopls@latest", .go),
            ("go get github.com/x/y", .go),
            ("go build ./...", nil),
            ("curl -fsSL https://bun.sh/install | bash", .script),
            ("wget -qO- https://x.sh | sudo sh", .script),
            ("curl https://x.dev/a.json | jq .", nil),
            ("ls -la", nil),
        ]
        for (line, want) in cases {
            #expect(RunRules.installer(argv(line)) == want, "\(line)")
        }
    }

    @Test func spotsInstallerProcesses() {
        for line in [
            "node /opt/homebrew/lib/node_modules/npm/bin/npm-cli.js install",
            "/opt/homebrew/bin/pnpm add react",
            "python3 -m pip install requests",
            "/bin/bash -p /opt/homebrew/Library/Homebrew/brew.sh install jq",
            "cargo install ripgrep",
        ] {
            #expect(RunRules.installerProcess(argv(line)) != nil, "\(line)")
        }
        // npm's own process title: one argument, padded with spaces.
        #expect(RunRules.installerProcess(["npm install left-pad is-number      "]) == .npm)
        for line in [
            "/bin/zsh -c source x && npm install left-pad",
            "bash -c curl -fsSL https://x.sh | sh",
            "node server.js install",
            "vim npm-install-notes.md",
            "node -e require('child_process').exec('npm install')",
        ] {
            #expect(RunRules.installerProcess(argv(line)) == nil, "\(line)")
        }
    }

    @Test func readsURLHosts() {
        #expect(RunRules.urlHosts("curl -fsSL 'https://Bun.sh/install' | bash") == ["bun.sh"])
        #expect(RunRules.urlHosts("registry=https://npm.corp.dev:8443/repo/") == ["npm.corp.dev"])
        #expect(RunRules.hostMatches("objects.githubusercontent.com", "githubusercontent.com"))
        #expect(!RunRules.hostMatches("evilgithub.com", "github.com"))
    }

    @Test func placesPaths() {
        let home = "/Users/a", cwd = "/Volumes/Dev/app"
        let place = { (path: String) in RunRules.place(of: path, home: home, cwd: cwd) }
        #expect(place("/Users/a/.ssh/authorized_keys") == .sensitive)
        #expect(place("/Users/a/.aws/credentials") == .sensitive)
        #expect(place("/Users/a/Library/Keychains/login.keychain-db") == .sensitive)
        #expect(place("/Users/a/.zshrc") == .persistence)
        #expect(place("/Users/a/Library/LaunchAgents/com.x.plist") == .persistence)
        #expect(place("/Library/LaunchDaemons/com.x.plist") == .persistence)
        #expect(place("/Volumes/Dev/app/node_modules/x/index.js") == .project)
        #expect(place("/Volumes/Dev/application/x") == nil)
        #expect(place("/Users/a/.npm/_cacache/x") == .cache)
        #expect(place("/Users/a/Library/Application Support/Slack/x") == nil)
        #expect(place("/Users/a/code/other/x") == .home)
        #expect(place("/opt/homebrew/Cellar/jq/1.7/bin/jq") == .system)
        #expect(place("/private/var/folders/x") == nil)
        #expect(place("/Users/a/.zsh_history") == nil)
        #expect(place("/Users/a/code/.DS_Store") == nil)
        #expect(place("/Users/a/Library/Application Support/dev.lowtide.app/runs.json") == nil)
        #expect(RunRules.group(of: "/Volumes/Dev/app/node_modules/x/index.js", home: home, cwd: cwd, place: .project)
            == "node_modules/x")
        #expect(RunRules.group(of: "/Users/a/.npm/_cacache/x/y", home: home, cwd: cwd, place: .cache) == "~/.npm/_cacache")
        #expect(RunRules.group(of: "/Users/a/.zshrc", home: home, cwd: cwd, place: .persistence) == "~/.zshrc")
        #expect(RunRules.group(of: "/opt/homebrew/Cellar/jq/1.7", home: home, cwd: cwd, place: .system) == "/opt/homebrew")
    }

    @Test func namesPackages() {
        let cases: [(String, (String, String?, String)?)] = [
            ("/p/node_modules/.pnpm/@types+node@22.1.0_x@1/node_modules/@types/node/a.d.ts",
             ("@types/node", "22.1.0", "/p/node_modules/.pnpm/@types+node@22.1.0_x@1")),
            ("/p/node_modules/.pnpm/esbuild@0.21.5/node_modules/esbuild/install.js",
             ("esbuild", "0.21.5", "/p/node_modules/.pnpm/esbuild@0.21.5")),
            ("/p/node_modules/.pnpm/lock.yaml", nil),
            ("/p/node_modules/react/index.js", ("react", nil, "/p/node_modules/react")),
            ("/p/node_modules/a/node_modules/@scope/b/x.js", ("@scope/b", nil, "/p/node_modules/a/node_modules/@scope/b")),
            ("/p/node_modules/.bin/tsc", nil),
            ("/v/lib/python3.12/site-packages/requests-2.32.3.dist-info/RECORD",
             ("requests", "2.32.3", "/v/lib/python3.12/site-packages/requests-2.32.3.dist-info")),
            ("/v/lib/python3.12/site-packages/requests/api.py", nil),
            ("/opt/homebrew/Cellar/jq/1.7.1/bin/jq", ("jq", "1.7.1", "/opt/homebrew/Cellar/jq/1.7.1")),
            ("/opt/homebrew/Caskroom/firefox/133.0/Firefox.app", ("firefox", "133.0", "/opt/homebrew/Caskroom/firefox/133.0")),
            ("/Users/a/.cargo/registry/src/index.crates.io-6f17d22bba15001f/serde-1.0.210/src/lib.rs",
             ("serde", "1.0.210", "/Users/a/.cargo/registry/src/index.crates.io-6f17d22bba15001f/serde-1.0.210")),
            ("/Users/a/go/pkg/mod/golang.org/x/tools@v0.24.0/go.mod",
             ("golang.org/x/tools", "v0.24.0", "/Users/a/go/pkg/mod/golang.org/x/tools@v0.24.0")),
            ("/Users/a/go/pkg/mod/cache/download/x", nil),
            ("/opt/homebrew/lib/ruby/gems/3.3.0/gems/rake-13.2.1/lib/rake.rb",
             ("rake", "13.2.1", "/opt/homebrew/lib/ruby/gems/3.3.0/gems/rake-13.2.1")),
            ("/Users/a/code/readme.md", nil),
        ]
        for (path, want) in cases {
            let got = RunRules.package(of: path)
            #expect(got?.name == want?.0 && got?.version == want?.1 && got?.dir == want?.2, "\(path)")
        }
    }

    @Test func namesInstallScripts() {
        let env = argv("PATH=/bin npm_lifecycle_event=postinstall npm_package_name=esbuild npm_package_version=0.21.5")
        let npm = RunRules.script(of: argv("sh -c node install.js"), env: env)
        #expect(npm?.0 == "postinstall" && npm?.1 == "esbuild@0.21.5")
        let cargo = RunRules.script(of: ["/p/target/release/build/ring-1a2b3c/build-script-build"], env: [])
        #expect(cargo?.0 == "build script" && cargo?.1 == "ring")
        #expect(RunRules.script(of: argv("node index.js"), env: ["PATH=/bin"]) == nil)
        #expect(RunRules.script(of: argv("node x"), env: ["npm_lifecycle_event="]) == nil)
    }

    @Test func flagsChildrenAndHidesSecrets() {
        #expect(RunRules.notable("xattr", argv("xattr -d com.apple.quarantine /tmp/x"))?.0 == .alert)
        #expect(RunRules.notable("xattr", argv("xattr -l /tmp/x")) == nil)
        #expect(RunRules.notable("curl", argv("curl https://x"))?.0 == .notice)
        #expect(RunRules.notable("launchctl", argv("launchctl load x.plist"))?.1 == "service")
        #expect(RunRules.notable("node", argv("node -e 1 "))?.1 == "inline-code")
        #expect(RunRules.notable("node", argv("node build.js")) == nil)
        #expect(RunRules.notable("ls", ["ls"]) == nil)
        #expect(RunRules.displayCommand(argv("deploy --token abc API_KEY=zzz --verbose")) == "deploy --token ••• API_KEY=••• --verbose")
        #expect(RunRules.displayCommand(["curl", "-H", "Authorization: Bearer abc123", "https://api.x"])
            == "curl -H Authorization: ••• https://api.x")
        #expect(RunRules.displayCommand(["curl", "-u", "me:hunter2", "x"]) == "curl -u me:••• x")
        #expect(RunRules.displayCommand(["mysql", "-proot1", "db"]) == "mysql -p••• db")
        #expect(RunRules.displayCommand(["git", "clone", "https://me:hunter2@github.com/a/b"])
            == "git clone https://me:•••@github.com/a/b")
        let token = "ghp_" + String(repeating: "aB3d", count: 9)
        #expect(RunRules.displayCommand(["gh", "auth", "login", token]) == "gh auth login •••")
        #expect(RunRules.displayCommand(argv("git push -u origin main")) == "git push -u origin main")
        #expect(RunRules.displayCommand([String(repeating: "x", count: 300)]).count == 241)
    }

    private func run(_ ecosystem: Ecosystem?) -> Run {
        Run(id: 1, source: .terminal, command: "npm install", started: 0, ended: 5000, ecosystem: ecosystem)
    }

    @Test func weighsFindings() {
        var install = run(.npm)
        install.files.places.append(PlaceSummary(place: .persistence, count: 1,
                                                 paths: ["/Users/a/Library/LaunchAgents/com.evil.plist"]))
        install.net.dests.append(RunDest(ip: "203.0.113.9", host: "paste.example", country: "XX", bytesIn: 10,
                                         bytesOut: 90_000, apps: ["node"], ports: [443]))
        let found = RunWriteUp.findings(install, rootAlive: false, home: "/Users/a")
        #expect(found[0].severity == .alert && found[0].rule == "startup")
        #expect(found[0].text == "Changed what runs at start-up: ~/Library/LaunchAgents/com.evil.plist")
        #expect(found.contains { $0.evidence == ["paste.example"] && $0.text.contains("outside npm registry") })

        // The same start-up change from a command you typed is a notice.
        var typed = install
        typed.ecosystem = nil
        let mine = RunWriteUp.findings(typed, rootAlive: false, home: "/Users/a")
        #expect(mine[0].severity == .notice)
        #expect(!mine.contains { $0.text.contains("paste.example") })

        // Homebrew fetches from vendors: only a note.
        var brew = install
        brew.ecosystem = .homebrew
        brew.files = .init()
        #expect(RunWriteUp.findings(brew, rootAlive: false, home: "/Users/a").first?.severity == .info)

        // What it left running, unless it is still in the foreground.
        var lingering = run(nil)
        lingering.procs.leftRunning = [RunChild(pid: 9, name: "server", command: "node server.js")]
        #expect(RunWriteUp.findings(lingering, rootAlive: false, home: "/").first?.rule == "left-running")
        #expect(RunWriteUp.findings(lingering, rootAlive: true, home: "/").first?.rule == "background")
        var judged = install
        RunWriteUp.judge(&judged, rootAlive: false, home: "/Users/a")
        #expect(judged.verdict == .alert)
    }

    @Test func readsReceiptsSavedBefore() throws {
        let saved = #"{"place":"project","count":3,"groups":[["node_modules/x",3]],"paths":[]}"#
        let summary = try JSONDecoder().decode(PlaceSummary.self, from: Data(saved.utf8))
        #expect(summary.groups[0].name == "node_modules/x" && summary.groups[0].count == 3 && summary.groups[0].path.isEmpty)
        // A receipt from before trees, ports and packages.
        let old = #"""
        {"id":7,"source":"terminal","ptyId":"p","command":"npm i x","cwd":"~/a","started":1,"ended":9,"ecosystem":"npm",
         "verdict":"notice","findings":[{"severity":"notice","text":"x"}],"net":{"bytesIn":1,"bytesOut":2,
         "dests":[{"ip":"1.2.3.4","host":null,"org":null,"country":null,"bytesIn":1,"bytesOut":2,"expected":false,"apps":["node"]}]},
         "procs":{"count":2,"notable":[],"leftRunning":[{"pid":3,"name":"n","command":"n","reason":null,"severity":null}]},
         "files":{"total":0,"places":[]}}
        """#
        let run = try JSONDecoder().decode(Run.self, from: Data(old.utf8))
        #expect(run.ecosystem == .npm && run.findings[0].rule == nil && run.findings[0].evidence.isEmpty)
        #expect(run.net.dests[0].ports.isEmpty && run.procs.tree.isEmpty && run.packages.isEmpty)
        #expect(run.procs.leftRunning[0].started == nil)
        // Round trip.
        let again = try JSONDecoder().decode(Run.self, from: try JSONEncoder().encode(run))
        #expect(again == run)
    }

    @Test func keepsOnlyMeaningfulRuns() {
        var quick = run(nil)
        quick.ended = 300
        #expect(!RunWriteUp.worthKeeping(quick))
        #expect(RunWriteUp.worthKeeping(run(.npm)))
        #expect(RunRules.shortForAlert("node /opt/homebrew/lib/node_modules/npm/bin/npm-cli.js install left-pad")
            == "npm install left-pad")
        #expect(RunWords.shortCommand("/bin/bash -p /opt/homebrew/Library/Homebrew/brew.sh upgrade jq") == "brew upgrade jq")
        #expect(RunWords.shortCommand("node /x/npm-cli.js install") == "npm install")
        #expect(RunWords.shortCommand("python3 -m pip install x") == "pip install x")
        #expect(RunWords.duration(42_000) == "42s" && RunWords.duration(185_000) == "3m 05s"
            && RunWords.duration(3_840_000) == "1h 04m")
    }

    @Test func wordsForReceipts() {
        var a = run(.python)
        a.command = "/usr/bin/python3 -m pip3 install x"
        #expect(RunWords.manager(a) == "pip")
        a.command = "weird-tool install"
        #expect(RunWords.manager(a) == "Python")
        #expect(RunWords.receiptParts(run(nil)) == ["touched nothing outside itself"])
        var b = run(.npm)
        b.net = NetSummary(bytesOut: 2000, dests: [RunDest(ip: "1.1.1.1")])
        b.files.total = 3
        #expect(RunWords.receiptParts(b) == ["1 host ↑ 2.0 KB", "3 files changed"])
        var earlier = run(.npm)
        earlier.id = 0
        b.started = 10
        #expect(RunWords.previousRun(b, in: [b, earlier])?.id == 0)
        #expect(RunWords.verdictLabel(run(.npm)) == "Clean" && RunWords.verdictLabel(run(nil)) == "Done")
    }

    @Test func groupsFilesAndPackages() {
        let home = "/Users/a", cwd = "/w/app"
        var paths: [String: RunWriteUp.Change] = [:]
        for i in 0..<10 { paths["/w/app/node_modules/react/f\(i).js"] = .init(place: .project, created: true) }
        paths["/w/app/node_modules/react/package.json"] = .init(place: .project, created: false)
        paths["/w/app/node_modules/left-pad/index.js"] = .init(place: .project, created: true)
        paths["/Users/a/.zshrc"] = .init(place: .persistence, created: false)
        let gone: Set<String> = ["/w/app/node_modules/left-pad/index.js"]
        let files = RunWriteUp.files(paths, gone: gone, home: home, cwd: cwd)
        #expect(files.total == 13)
        #expect(files.places.map(\.place) == [.persistence, .project])
        let project = files.places[1]
        #expect(project.groups.map(\.name) == ["node_modules/react", "node_modules/left-pad"])
        #expect(project.groups[0].count == 11 && project.groups[0].added == 10 && project.groups[0].samples.count == 6)
        #expect(project.groups[0].path == "/w/app/node_modules/react")
        #expect(project.groups[1].removed == 1)
        #expect(files.places[0].paths == ["/Users/a/.zshrc"] && files.places[0].groups[0].path == "/Users/a/.zshrc")

        let packages = RunWriteUp.packages(paths.keys, gone: gone) { $0.hasSuffix("react") ? "19.0.0" : nil }
        #expect(packages.map(\.name) == ["left-pad", "react"])
        #expect(packages[0].removed && packages[0].version == nil)
        #expect(packages[1].version == "19.0.0" && packages[1].files == 11)

        // pnpm's store copy stands for the linked one.
        let pnpm = RunWriteUp.packages(["/w/node_modules/.pnpm/react@19.0.0/node_modules/react/a.js",
                                        "/w/node_modules/react/a.js"], gone: []) { _ in nil }
        #expect(pnpm.count == 1 && pnpm[0].version == "19.0.0")
    }

    @Test func buildsTheProcessTree() {
        let script: (String, String?) = ("postinstall", "esbuild@0.21.5")
        let pids: [Int32: RunWriteUp.Seen] = [
            10: .init(comm: "npm", ppid: 1, started: 100, lastSeen: 900, args: ["npm", "install"], script: nil),
            11: .init(comm: "sh", ppid: 10, started: 200, lastSeen: 400, args: ["sh", "-c", "node install.js"], script: script),
            12: .init(comm: "node", ppid: 11, started: 210, lastSeen: 390, args: ["node", "install.js"], script: script),
            13: .init(comm: "curl", ppid: 12, started: 300, lastSeen: 350, args: ["curl", "https://x"], script: script),
            14: .init(comm: "esbuild", ppid: 12, started: 320, lastSeen: 900, args: ["esbuild", "--service"], script: script),
        ]
        let summary = RunWriteUp.processes(pids, root: 10) { pid, _ in pid == 14 }
        #expect(summary.count == 5)
        #expect(summary.tree.map(\.pid) == [10, 11, 12, 13, 14])
        // Only the first process of a script is named as it.
        #expect(summary.tree.map(\.script) == [nil, "postinstall", nil, nil, nil])
        #expect(summary.tree[1].package == "esbuild@0.21.5")
        #expect(summary.tree[4].ended == nil && summary.tree[3].ended == 350)
        #expect(summary.notable.map(\.name) == ["curl"])
        #expect(summary.leftRunning.map(\.name) == ["esbuild"] && summary.leftRunning[0].severity == .info)
    }

    @Test func parsesProcargs() {
        var bytes: [UInt8] = [2, 0, 0, 0]
        bytes += Array("/bin/ls\0\0\0\0ls\0-la\0HOME=/x\0\0".utf8)
        let parsed = ProcTable.parseProcargs(bytes)
        #expect(parsed?.args == ["ls", "-la"] && parsed?.env == ["HOME=/x"])
        #expect(ProcTable.parseProcargs([1, 0]) == nil)
    }

    @Test func readsOwnProcess() throws {
        let me = getpid()
        let info = try #require(RunProcessTable.info(me))
        #expect(info.pid == me && info.ppid > 0 && info.started > 1_600_000_000_000)
        #expect(ProcTable.pids().contains(me))
        #expect(ProcTable.cwd(me)?.hasPrefix("/") == true)
        #expect(ProcTable.arguments(me)?.isEmpty == false)
        #expect(ProcTable.path(me)?.hasPrefix("/") == true)
        let table = RunProcessTable.refresh()
        #expect(table[me] != nil && RunProcessTable.descends(me, from: info.ppid, in: table))
    }

    @Test func readsSocketPeers() throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(listener) }
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                                  sin_port: 0, sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, length) == 0 && getsockname(listener, $0, &length) == 0 }
        }
        try #require(bound && listen(listener, 1) == 0)
        let port = UInt16(bigEndian: address.sin_port)
        let client = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(client) }
        let connected = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try #require(connected == 0)
        let peers = RunProcessTable.peers(getpid())
        #expect(peers.contains { $0.port == port && $0.ip == "127.0.0.1" && $0.loopback })
    }

    /// Follows a real installer started outside any terminal: a `pip` script
    /// that writes into its project and makes a file executable.
    @Test(.timeLimit(.minutes(1))) func followsAnInstallerEndToEnd() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "lowtide-run-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appending(path: "project"), bin = root.appending(path: "bin")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let pip = bin.appending(path: "pip")
        try Data("#!/bin/sh\nsleep 1\nmkdir -p site-packages/demo-1.0.dist-info\necho x > site-packages/demo-1.0.dist-info/RECORD\necho y > tool\nchmod +x tool\nsleep 1\n".utf8)
            .write(to: pip)
        chmod(pip.path, 0o755)

        let engine = RunEngine(file: root.appending(path: "runs.json"), home: root.appending(path: "home").path)
        let finished = AsyncStream<Run>.makeStream()
        await engine.start(sources: RunSources(), finished: { finished.continuation.yield($0) }, alert: { _ in })
        try await Task.sleep(for: .seconds(1))
        let process = Process()
        process.executableURL = pip
        process.arguments = ["install", "demo"]
        process.currentDirectoryURL = project
        try process.run()

        var receipt: Run?
        for await run in finished.stream where run.command.contains("pip install demo") {
            receipt = run
            break
        }
        await engine.stop()
        let run = try #require(receipt)
        #expect(run.source == .detected && run.ecosystem == .python)
        #expect(run.cwd == URL(fileURLWithPath: project.path).standardizedFileURL.path.replacingOccurrences(of: "/var/", with: "/private/var/"))
        // Short-lived helpers (mkdir, chmod) can slip between samples; the
        // sleeps can't.
        #expect(run.procs.count >= 2 && run.procs.tree.contains { $0.name == "sleep" })
        #expect(run.files.places.contains { $0.place == .project })
        #expect(run.packages.contains { $0.name == "demo" && $0.version == "1.0" })
        #expect(await engine.list(installsOnly: true).first?.id == run.id)
        // Saved, and read back by the next engine.
        #expect(await RunEngine(file: root.appending(path: "runs.json")).list().first?.id == run.id)
    }
}
