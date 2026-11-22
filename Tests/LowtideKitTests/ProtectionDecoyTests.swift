import Darwin
import Foundation
import Testing
@testable import LowtideKit

@Suite struct ProtectionDecoyTests {
    @Test func contentsLookReal() throws {
        let aws = Decoys.aws()
        let key = String(aws.split(separator: "\n")[1].dropFirst("aws_access_key_id = ".count))
        #expect(key.hasPrefix("AKIA") && key.count == 20)
        #expect(key.allSatisfy { Decoys.upperDigits.contains($0) })
        #expect(aws != Decoys.aws())
        let ssh = Decoys.ssh()
        #expect(ssh.hasPrefix("-----BEGIN RSA PRIVATE KEY-----\nMIIE"))
        #expect(ssh.split(separator: "\n").allSatisfy { $0.count <= 64 || $0.hasPrefix("-----") })
        let env = Decoys.env()
        for prefix in ["OPENAI_API_KEY=sk-proj-", "ANTHROPIC_API_KEY=sk-ant-", "STRIPE_SECRET_KEY=sk_live_"] {
            #expect(env.contains(prefix), "\(prefix)")
        }
        #expect((try? JSONSerialization.jsonObject(with: Data(Decoys.docker().utf8))) != nil)
        #expect(Decoys.kube().contains("    token: eyJ"))
        #expect(Decoys.netrc().contains("password ghp_"))
        #expect(Set(Decoys.kinds.map(\.id)).count == 6)
    }

    @Test func detectsTrips() {
        let armed: UInt64 = 1_700_000_000_000
        #expect(Decoys.check(now: armed + 5, armedAt: armed, atime: Decoys.armedAtime) == .quiet)
        #expect(Decoys.check(now: armed - 5, armedAt: armed, atime: armed - 6) == .rearm)
        #expect(Decoys.check(now: armed + 5, armedAt: armed, atime: armed + 4) == .trip)
    }

    @Test func ranksSuspects() {
        func start(_ pid: Int32, _ path: String, _ started: UInt64) -> ProcessStart {
            ProcessStart(pid: pid, comm: "p\(pid)", path: path, parent: nil, started: started)
        }
        let list = Decoys.suspects([
            start(1, "/usr/bin/cat", 1000), start(2, "/tmp/stealer", 900),
            start(3, "/Applications/Me.app/me", 1000), start(4, "/Users/x/.local/bin/tool", 990),
        ], own: 3, t: 1000)
        #expect(list.map(\.pid) == [4, 2, 1])
        #expect(list[2].system)
    }

    @Test func readsTheManifest() throws {
        let json = #"""
        {"decoys":[{"armedAt":5,"createdDir":null,"id":"aws","inode":[16777232,123],"path":"/h/.aws/credentials.bak",
        "plantedAt":1,"trips":[{"suspects":[{"comm":"cat","parent":"zsh","path":"/bin/cat","pid":9,"started":4,"system":true}],"t":6}]}]}
        """#
        let manifest = try JSONStore.decoder.decode(Decoys.Manifest.self, from: Data(json.utf8))
        #expect(manifest.decoys[0].inode == [16_777_232, 123] && manifest.decoys[0].trips[0].suspects[0].comm == "cat")
    }

    @Test func plantsTripsAndRemovesInATempHome() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "lowtide-decoys-\(UUID())").resolvingSymlinksInPath().path
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home + "/.ssh", withIntermediateDirectories: true)
        // Someone else's file: must survive untouched.
        try Data("mine".utf8).write(to: URL(fileURLWithPath: home + "/.netrc.old"))
        var manifest = Decoys.Manifest()

        let errors = Decoys.plant(&manifest, home: home, ids: nil, now: 0)
        #expect(errors.isEmpty)
        #expect(manifest.decoys.count == 5)
        let aws = home + "/.aws/credentials.bak"
        let mode = { (path: String) -> mode_t in
            var info = stat()
            stat(path, &info)
            return info.st_mode & 0o777
        }
        #expect(mode(aws) == 0o600 && mode(home + "/.aws") == 0o700)
        #expect(Decoys.facts(aws)?.atime == Decoys.armedAtime)

        let now = Decoys.plantGrace + 1
        #expect(Decoys.poll(&manifest, home: home, now: now) { _ in [] }.changed == false)
        _ = FileManager.default.contents(atPath: aws)
        let read = try #require(Decoys.facts(aws)?.atime)
        #expect(read > Decoys.armedAtime, "APFS should move atime on read")
        let result = Decoys.poll(&manifest, home: home, now: Clock.now) { _ in [] }
        #expect(result.changed && result.reads.map(\.path) == ["~/.aws/credentials.bak"])
        #expect(manifest.decoys.first { $0.id == "aws" }?.trips.count == 1)
        #expect(Decoys.facts(aws)?.atime == Decoys.armedAtime, "re-armed")

        var view = Decoys.status(manifest, home: home, now: Clock.now, errors: [])
        let state = { (id: String) in view.decoys.first { $0.id == id }!.state }
        #expect(state("netrc") == .taken && state("aws") == .arming && view.planted == 5)
        #expect(view.reads.count == 1)

        // A real key moved over a decoy (`mv id_rsa id_rsa.old`), and a decoy
        // from a manifest that predates inodes: neither is ever touched.
        let key = home + "/.ssh/id_rsa.old"
        try Data("real".utf8).write(to: URL(fileURLWithPath: home + "/.ssh/id_rsa"))
        rename(home + "/.ssh/id_rsa", key)
        let kube = home + "/.kube/config.old"
        manifest.decoys[manifest.decoys.firstIndex { $0.id == "kube" }!].inode = nil
        view = Decoys.status(manifest, home: home, now: Clock.now, errors: [])
        #expect(state("ssh") == .taken && state("kube") == .taken)
        #expect(Decoys.poll(&manifest, home: home, now: Clock.now) { _ in [] }.changed)
        #expect(!manifest.decoys.contains { $0.id == "ssh" || $0.id == "kube" })
        var old = Decoys.Manifest(decoys: [Decoys.Planted(armedAt: 0, createdDir: nil, id: "kube", inode: nil, path: kube,
                                                          plantedAt: 0, trips: [])])
        await Decoys.remove(&old, home: home, ids: nil) { paths in paths.forEach { unlink($0) } }
        #expect(FileManager.default.fileExists(atPath: kube))

        // Deleted after planting: missing, and planting again restores it.
        unlink(home + "/.env.backup")
        view = Decoys.status(manifest, home: home, now: Clock.now, errors: [])
        #expect(state("env") == .missing)
        _ = Decoys.plant(&manifest, home: home, ids: ["env"], now: Clock.now)
        #expect(FileManager.default.fileExists(atPath: home + "/.env.backup"))

        await Decoys.remove(&manifest, home: home, ids: nil) { paths in paths.forEach { unlink($0) } }
        #expect(manifest.decoys.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: aws) && !FileManager.default.fileExists(atPath: home + "/.aws"))
        #expect(try String(contentsOfFile: key, encoding: .utf8) == "real")
        #expect(try String(contentsOfFile: home + "/.netrc.old", encoding: .utf8) == "mine")
    }
}

@Suite struct ProtectionPermissionTests {
    @Test func readsDisabledLabels() {
        let text = """
        disabled services = {
        \t"com.apple.ftpd" => disabled
        \t"homebrew.mxcl.mysql" => enabled
        \t"com.docker.socket" => true
        \t"com.x.y" => false
        }
        """
        #expect(PermissionMap.parseDisabled(text) == ["com.apple.ftpd", "com.docker.socket"])
    }

    @Test func readsTCCRows() throws {
        let json = #"[{"service":"kTCCServiceCamera","client":"us.zoom.xos","client_type":0,"auth_value":2,"indirect_object_identifier":"UNUSED","last_modified":1700000000},{"service":"kTCCServiceAccessibility","client":"/usr/local/bin/tool","client_type":1,"auth_value":2,"indirect_object_identifier":null,"last_modified":null},{"service":"kTCCServicePhotos","client":"com.gone.app","client_type":0,"auth_value":3}]"#
        let rows = try #require(PermissionMap.parseRows(json))
        #expect(rows.count == 3 && rows[1].clientType == 1 && rows[2].authValue == 3)
        #expect(PermissionMap.parseRows("")?.isEmpty == true)
        #expect(PermissionMap.parseRows("Error: unable to open database") == nil)

        let installed = ["us.zoom.xos": PermissionMap.Installed(name: "zoom.us", path: "/Applications/zoom.us.app")]
        var builder = PermissionMap.Builder(installed: installed)
        PermissionMap.addGrants(&builder, rows)
        let zoom = try #require(builder.apps["us.zoom.xos"])
        #expect(zoom.name == "zoom.us" && zoom.installed && zoom.grants[0].label == "Camera" && zoom.grants[0].target == nil)
        #expect(zoom.grants[0].revocable && zoom.powerful)
        let tool = try #require(builder.apps["/usr/local/bin/tool"])
        #expect(tool.grants[0].revocable == false && tool.name == "tool")
        // A gone app keeps its bundle id as its name.
        let gone = try #require(builder.apps["com.gone.app"])
        #expect(gone.name == "com.gone.app" && !gone.installed && gone.grants[0].limited)
    }

    @Test func readsLaunchAgents() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "lowtide-perm-\(UUID())").resolvingSymlinksInPath().path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let agents = home + "/Library/LaunchAgents"
        try FileManager.default.createDirectory(atPath: agents, withIntermediateDirectories: true)
        func plist(_ name: String, _ job: [String: Any]) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
            try data.write(to: URL(fileURLWithPath: agents + "/" + name))
        }
        try plist("com.gone.helper.plist", ["Label": "com.gone.helper", "ProgramArguments": ["/Applications/Gone.app/Contents/MacOS/helper"]])
        try plist("com.x.sync.plist", ["Label": "com.x.sync", "Program": "/bin/sh", "Disabled": true])
        try plist("broken.plist", ["Program": "/bin/sh"])
        try Data("not a plist".utf8).write(to: URL(fileURLWithPath: agents + "/junk.plist"))
        let records = PermissionMap.launchdRecords(home: home).filter { $0.plist.hasPrefix(home) }
        #expect(records.map(\.label) == ["com.gone.helper", "com.x.sync"])

        let (gone, app) = PermissionMap.background(records[0], home: home, disabledGUI: [], disabledSystem: [])
        #expect(gone.missing && gone.removable && gone.active && gone.control == .lowtide && gone.kind == .agent)
        #expect(app == "/Applications/Gone.app")
        let (sync, _) = PermissionMap.background(records[1], home: home, disabledGUI: ["com.x.sync"], disabledSystem: [])
        #expect(!sync.missing && !sync.active && sync.overridden && !sync.enabled && !sync.removable)
    }

    @Test func joinsHelpersToTheirApps() {
        #expect(PermissionMap.vendorApp("com.docker.socket", installed: ["com.docker.docker", "com.x.y"]) == "com.docker.docker")
        #expect(PermissionMap.vendorApp("com.apple.x.y", installed: ["com.apple.Safari"]) == nil)
        #expect(PermissionMap.vendorApp("homebrew.mxcl", installed: ["homebrew.x"]) == nil)
        #expect(PermissionMap.enclosingApp("/Applications/Foo.app/Contents/MacOS/foo") == "/Applications/Foo.app")
        #expect(PermissionMap.enclosingApp("/Applications/Foo.app") == "/Applications/Foo.app")
        #expect(PermissionMap.enclosingApp("/usr/local/bin/x") == nil)
    }

    @Test func rejectsOddLabels() {
        #expect((try? PermissionActions.safeLabel("homebrew.mxcl.mysql")) == "homebrew.mxcl.mysql")
        #expect((try? PermissionActions.safeLabel("x; rm -rf /")) == nil)
        #expect((try? PermissionActions.safeLabel("a\"b")) == nil)
        #expect((try? PermissionActions.safeLabel(nil)) == nil)
    }

    @Test func readsLooseBundles() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "lowtide-bundle-\(UUID())").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/Twice.app/Contents", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: dir + "/Bare.app/Contents", withIntermediateDirectories: true)
        try Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleName</key><string>Twice 3</string><key>CFBundleIdentifier</key><string>com.example.twice</string></dict></plist>".utf8)
            .write(to: URL(fileURLWithPath: dir + "/Twice.app/Contents/Info.plist"))
        try Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict></dict></plist>".utf8)
            .write(to: URL(fileURLWithPath: dir + "/Bare.app/Contents/Info.plist"))
        let twice = try #require(PermissionMap.readBundle(dir + "/Twice.app"))
        #expect(twice.0 == "com.example.twice" && twice.1.name == "Twice 3")
        let bare = try #require(PermissionMap.readBundle(dir + "/Bare.app"))
        #expect(bare.0.hasSuffix("Bare.app") && bare.1.name == "Bare")
        var found: [String] = []
        PermissionMap.apps(under: dir, depth: 1, into: &found)
        #expect(found.count == 2)
    }

    @Test func gathersLocalThreats() {
        var install = Run(id: 3, source: .terminal, command: "pnpm add colors-kit", started: Clock.now, ended: Clock.now,
                          ecosystem: .npm, verdict: .alert)
        install.findings = [RunFinding(severity: .alert, text: "Changed what runs at start-up", rule: "startup", evidence: [])]
        let quiet = Run(id: 4, source: .terminal, command: "npm i", started: Clock.now, ended: Clock.now, ecosystem: .npm)
        let old = Run(id: 5, source: .terminal, command: "npm i x", started: 1000, ended: 2000, ecosystem: .npm, verdict: .alert)
        let secret = ExposureFinding(id: "s", kind: "github-token", label: "GitHub token", path: "/h/.env", line: 2,
                                     preview: "ghp_••••", severity: .critical, strong: true, synced: true)
        let report = ExposureReport(at: 0, scanned: 1, ms: 1, findings: [secret])
        let found = ThreatFinding.local(runs: [install, quiet, old], decoys: nil, exposure: report, permissions: nil)
        #expect(found.map(\.kind) == [.install, .secret])
        #expect(found[0].detail == "Changed what runs at start-up" && found[0].runID == 3)
        #expect(ThreatFinding.level(70) == .high && ThreatFinding.level(35) == .medium && ThreatFinding.level(5) == .low)
    }
}
