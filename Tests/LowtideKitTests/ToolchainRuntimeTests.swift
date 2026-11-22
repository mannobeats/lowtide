import Foundation
import Testing
@testable import LowtideKit

@Suite struct ToolchainRuntimeTests {
    @Test func readsRuntimeVersions() {
        // What this Mac's runtimes print, and others seen in the wild.
        #expect(Runtimes.parseVersion("v26.13.1\n") == "26.13.1")
        #expect(Runtimes.parseVersion("Python 3.9.6\n") == "3.9.6")
        #expect(Runtimes.parseVersion("go version go1.27.4 darwin/arm64\n") == "1.27.4")
        #expect(Runtimes.parseVersion("rustc 1.100.0 (0ef1bc386 2026-11-09)\n") == "1.100.0")
        #expect(Runtimes.parseVersion("ruby 2.6.10p210 (2022-04-12 revision 67958) [universal.arm64e-darwin26]") == "2.6.10p210")
        #expect(Runtimes.parseVersion("openjdk version \"21.0.2\" 2024-01-16\nOpenJDK Runtime Environment") == "21.0.2")
        #expect(Runtimes.parseVersion("PHP 8.4.1 (cli) (built: Nov 20 2025 12:00:00) (NTS)") == "8.4.1")
        #expect(Runtimes.parseVersion("deno 2.9.7 (stable, release, aarch64-apple-darwin)") == "2.9.7")
        #expect(Runtimes.parseVersion("The operation couldn’t be completed. Unable to locate a Java Runtime.") == nil)
    }

    @Test func namesWhoInstalledIt() {
        #expect(Runtimes.manager(real: "/opt/homebrew/Cellar/node/26.13.1/bin/node", path: "/opt/homebrew/bin/node") == "Homebrew")
        #expect(Runtimes.manager(real: "/Users/me/.local/state/fnm_multishells/123/bin/node", path: "/Users/me/.local/state/fnm_multishells/123/bin/node") == "fnm")
        #expect(Runtimes.manager(real: "/Users/me/.rustup/toolchains/stable/bin/rustc", path: "/Users/me/.cargo/bin/rustc") == "rustup")
        #expect(Runtimes.manager(real: "/usr/bin/python3", path: "/usr/bin/python3") == "macOS")
        #expect(Runtimes.manager(real: "/Library/Developer/CommandLineTools/usr/bin/python3", path: "/usr/bin/python3") == "macOS")
        #expect(Runtimes.manager(real: "/Users/me/bin/node", path: "/Users/me/bin/node") == "Manual install")
        #expect(Runtimes.upgradeHint("node", manager: "Homebrew", real: "/opt/homebrew/Cellar/node@22/22.1.0/bin/node") == "brew upgrade node@22")
        #expect(Runtimes.upgradeHint("node", manager: "fnm", real: "") == "fnm install {cycle} && fnm default {cycle}")
        #expect(Runtimes.upgradeHint("python", manager: "macOS", real: "") == nil)
    }

    /// endoflife.date/api/python.json and nodejs.json (first cycles), verbatim.
    static let python = #"[{"cycle":"3.15","releaseDate":"2026-10-09","eol":"2031-10-31","latest":"3.15.2","latestReleaseDate":"2026-10-25","pep":"PEP-0790","lts":false,"support":"2028-10-09"},{"cycle":"3.14","releaseDate":"2025-10-07","eol":"2030-10-31","latest":"3.14.10","latestReleaseDate":"2026-10-25","pep":"PEP-0745","lts":false,"support":"2027-10-01"},{"cycle":"3.13","releaseDate":"2024-10-07","eol":"2029-10-31","latest":"3.13.18","latestReleaseDate":"2026-10-25","pep":"PEP-0719","lts":false,"support":"2026-10-01"},{"cycle":"3.9","releaseDate":"2020-10-05","eol":"2025-10-31","latest":"3.9.25","lts":false}]"#
    static let node = #"[{"cycle":"26","releaseDate":"2026-05-05","lts":"2026-10-28","eol":"2029-04-30","latest":"26.13.1","latestReleaseDate":"2026-11-11","support":"2027-10-27","extendedSupport":false},{"cycle":"25","releaseDate":"2025-10-15","eol":"2026-06-01","latest":"25.9.0","latestReleaseDate":"2026-04-01","lts":false,"support":"2026-04-01","extendedSupport":false},{"cycle":"24","releaseDate":"2025-05-06","lts":"2025-10-28","eol":"2028-04-30","latest":"24.22.3","latestReleaseDate":"2026-11-11","support":"2026-10-20","extendedSupport":false}]"#

    func runtime(_ version: String) -> LanguageRuntime {
        LanguageRuntime(id: "python", name: "Python", command: "python3", version: version, path: "", manager: "",
                        shadowed: [], lts: false, standing: .unknown)
    }

    @Test func ratesTheInstalledReleaseLine() throws {
        let cycles = try #require(ReleaseCycle.parse(Data(Self.python.utf8)))
        #expect(cycles.count == 4)

        var current = runtime("3.14.10")
        Runtimes.applyLifecycle(&current, cycles: cycles, today: "2026-11-14")
        #expect(current.standing == .current && current.cycle == "3.14" && current.eol == "2030-10-31")

        var behind = runtime("3.13.2")
        Runtimes.applyLifecycle(&behind, cycles: cycles, today: "2026-11-14")
        #expect(behind.standing == .behind && behind.cycleLatest == "3.13.18" && behind.latest == "3.15.2")

        // This Mac's Xcode Python 3.9.6: its line ended in 2025.
        var ended = runtime("3.9.6")
        Runtimes.applyLifecycle(&ended, cycles: cycles, today: "2026-11-14")
        #expect(ended.standing == .eol)

        var unknown = runtime("2.7.18")
        Runtimes.applyLifecycle(&unknown, cycles: cycles, today: "2026-11-14")
        #expect(unknown.standing == .unknown && unknown.cycle == nil)
    }

    @Test func readsLTSDates() throws {
        let cycles = try #require(ReleaseCycle.parse(Data(Self.node.utf8)))
        var node = runtime("26.13.1")
        Runtimes.applyLifecycle(&node, cycles: cycles, today: "2026-11-14")
        #expect(node.lts && node.standing == .current && node.cycle == "26")
        var early = runtime("26.1.0")
        Runtimes.applyLifecycle(&early, cycles: cycles, today: "2026-10-01")
        #expect(!early.lts && early.standing == .behind)
        var odd = runtime("25.9.0")
        Runtimes.applyLifecycle(&odd, cycles: cycles, today: "2026-11-14")
        #expect(odd.standing == .eol)
        // Numbers and booleans where strings are usual.
        let mixed = try #require(ReleaseCycle.parse(Data(#"[{"cycle": 8, "latest": "8.0.4", "eol": false, "lts": true}]"#.utf8)))
        #expect(mixed.first == ReleaseCycle(cycle: "8", latest: "8.0.4", lts: .flag(true), eol: .flag(false)))
    }

    @Test func formatsToday() {
        #expect(Runtimes.today(Date(timeIntervalSince1970: 1_763_078_400)) == "2025-11-14")
        #expect(Runtimes.today().count == 10)
    }

    @Test func findsShadowedCopies() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "lowtide-rt-\(UUID())")
        let a = root.appending(path: "a"), b = root.appending(path: "b"), c = root.appending(path: "c")
        for folder in [a, b, c] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in [a, b] {
            try Data("#!/bin/sh\n".utf8).write(to: folder.appending(path: "node"))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.appending(path: "node").path)
        }
        try FileManager.default.createSymbolicLink(atPath: c.appending(path: "node").path, withDestinationPath: a.appending(path: "node").path)
        let shadowed = Runtimes.shadowed("node", active: a.appending(path: "node").path, pathList: "\(a.path):\(c.path):\(b.path)")
        #expect(shadowed == [b.appending(path: "node").path])
    }
}
