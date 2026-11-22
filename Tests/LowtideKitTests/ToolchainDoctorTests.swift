import Foundation
import Testing
@testable import LowtideKit

@Suite struct ToolchainDoctorTests {
    /// `brew doctor` on this Mac, verbatim.
    static let brewDoctor = """
        Please note that these warnings are just used to help the Homebrew maintainers
        with debugging if you file an issue. If everything you use Homebrew for is
        working fine: please don't worry or file an issue; just ignore this. Thanks!

        Warning: The following taps are not trusted:
          stripe/stripe-cli

        Homebrew is currently ignoring formulae, casks and commands
        from these taps because tap trust is required.
        Untap them with:
          brew untap stripe/stripe-cli
        Trust specific formulae, casks and commands with:
          brew trust --formula <user>/<tap>/<formula>
          brew trust --cask <user>/<tap>/<cask>
          brew trust --command <user>/<tap>/<command>
        Whole-tap trust is broader and includes all current and future formulae,
        casks and commands from the listed taps. Trust whole taps with:
          brew trust stripe/stripe-cli
        For more information, see:
          https://docs.brew.sh/Tap-Trust

        Warning: /usr/bin occurs before /opt/homebrew/bin in your PATH.
        This means that system-provided programs will be used instead of those
        provided by Homebrew.

        The following tools exist at both paths:
          git
          git-receive-pack
          openssl

        Consider setting your PATH for example like so:
          printf '%s\\n' export\\ PATH\\=/opt/homebrew/bin:\\$PATH >> ~/.zshrc

        Warning: Broken symlinks were found:
          /opt/homebrew/share/man/man1/npm-adduser.1
          /opt/homebrew/share/man/man5/npm-shrinkwrap-json.5

        Remove them with `brew cleanup`

        """

    @Test func readsBrewDoctorWarnings() {
        let warnings = Doctor.parseBrewDoctor(Self.brewDoctor)
        #expect(warnings.count == 3)
        #expect(warnings[0].0 == "The following taps are not trusted:")
        #expect(warnings[1].0 == "/usr/bin occurs before /opt/homebrew/bin in your PATH.")
        #expect(warnings[2].1.contains("npm-shrinkwrap-json.5"))
        #expect(Doctor.suggestedCommand(warnings[0].1) == "brew untap stripe/stripe-cli")
        #expect(Doctor.suggestedCommand(warnings[2].1) == "brew cleanup")
        #expect(Doctor.suggestedCommand(warnings[1].1) == nil)
        let outcome = Doctor.brewDoctorOutcome(status: 1, output: Self.brewDoctor)
        #expect(outcome.status == .warn && outcome.summary == "3 warnings")
        #expect(Doctor.brewDoctorOutcome(status: 0, output: "Your system is ready to brew.").status == .pass)
    }

    @Test func readsBrewMissing() {
        // This Mac prints nothing; a broken one lists formula: deps.
        #expect(Doctor.parseBrewMissing("").isEmpty)
        let missing = Doctor.parseBrewMissing("ffmpeg: libvpx x265\nnode: icu4c@79\n")
        #expect(missing["ffmpeg"] == ["libvpx", "x265"])
        #expect(missing.count == 2)
    }

    @Test func findsDuplicateAndMissingPathEntries() {
        let dirs = ["/opt/homebrew/bin", "/usr/bin", "/opt/homebrew/bin", "/Users/me/.old-tool/bin"]
        let outcome = Doctor.pathEntries(dirs) { $0 != "/Users/me/.old-tool/bin" }
        #expect(outcome.status == .warn)
        #expect(outcome.issues.map(\.title) == ["Duplicate PATH entry", "PATH folder doesn't exist"])
        #expect(Doctor.pathEntries(["/usr/bin", "/bin"]) { _ in true }.status == .pass)
        // This Mac's login PATH: macOS's cryptex and pmk folders don't exist
        // and aren't the person's; a third-party /etc/paths.d leftover is.
        let real = ["/opt/homebrew/bin", "/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/local/bin",
                    "/pkg/env/global/bin", "/Library/TeX/texbin", "/Users/me/.volta/bin"]
        let mixed = Doctor.pathEntries(real, exists: { $0 == "/opt/homebrew/bin" },
                                       systemSources: ["/Library/TeX/texbin": "/etc/paths.d/TeX",
                                                       "/pkg/env/global/bin": "/etc/paths.d/10-pmk-global"])
        #expect(mixed.issues.map(\.path) == ["/Library/TeX/texbin", "/Users/me/.volta/bin"])
        #expect(mixed.issues[0].suggestion.contains("/etc/paths.d/TeX"))
    }

    @Test func checksHomebrewComesFirst() {
        #expect(Doctor.pathOrder(["/usr/bin", "/opt/homebrew/bin"]).status == .warn)
        #expect(Doctor.pathOrder(["/opt/homebrew/bin", "/usr/bin"]).status == .pass)
        #expect(Doctor.pathOrder(["/usr/bin", "/bin"]).status == .skip)
        #expect(Doctor.pathOrder(["/usr/bin", "/opt/homebrew/bin"]).issues.first?.command?.contains("/opt/homebrew/bin/brew shellenv") == true)
    }

    @Test func comparesTheAppPathWithTheLoginShell() {
        let tools = ["/opt/homebrew/bin": ["brew", "node"], "/Users/me/.cargo/bin": ["cargo", "bacon"],
                     "/Users/me/.bun/bin": ["bun"], "/usr/bin": ["git"]]
        let lookup: (String) -> [String] = { tools[$0] ?? [] }
        let missing = Doctor.loginPath(app: "/opt/homebrew/bin:/usr/bin:/Users/me/.cargo/bin:/Users/me/.bun/bin",
                                       login: "/opt/homebrew/bin:/usr/bin:/Users/me/.bun/bin", executables: lookup)
        #expect(missing.status == .warn)
        #expect(missing.issues.count == 1)
        #expect(missing.issues[0].detail == "bacon, cargo")
        #expect(missing.issues[0].command?.contains("export PATH=") == true)
        // The same tool somewhere the terminal does see is no problem.
        let shadow = Doctor.loginPath(app: "/opt/homebrew/bin:/Users/me/.bun/bin", login: "/opt/homebrew/bin",
                                      executables: { $0 == "/Users/me/.bun/bin" ? ["node"] : lookup($0) })
        #expect(shadow.status == .pass)
        #expect(Doctor.loginPath(app: "/usr/bin", login: nil, executables: lookup).status == .warn)
    }

    @Test func findsBrokenLinksAndCopies() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "lowtide-doctor-\(UUID())")
        let other = folder.appending(path: "other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tool = folder.appending(path: "node")
        try Data("#!/bin/sh\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        try FileManager.default.createSymbolicLink(atPath: folder.appending(path: "gone").path, withDestinationPath: "/nope/gone")
        try FileManager.default.createSymbolicLink(atPath: folder.appending(path: "ok").path, withDestinationPath: tool.path)
        let copy = other.appending(path: "node")
        try Data("#!/bin/sh\n".utf8).write(to: copy)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copy.path)

        #expect(Doctor.brokenLinks(in: folder.path).map { ($0 as NSString).lastPathComponent } == ["gone"])
        let links = Doctor.brokenLinks([folder.path, "/usr/bin"])
        #expect(links.status == .fail && links.issues.first?.fix?.id == "broken-links:\(folder.path)")
        #expect(Doctor.copiesOnPath("node", [folder.path, other.path, "/usr/bin"]).count == 2)
        // A symlink to the same file isn't a second copy.
        #expect(Doctor.copiesOnPath("ok", [folder.path]).count == 1)
    }

    @Test func checksSSHPermissions() throws {
        let ssh = FileManager.default.temporaryDirectory.appending(path: "lowtide-ssh-\(UUID())")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ssh) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh.path)
        let key = ssh.appending(path: "id_ed25519")
        try Data("-----BEGIN OPENSSH PRIVATE KEY-----\nb3Blbn\n-----END OPENSSH PRIVATE KEY-----\n".utf8).write(to: key)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: key.path)
        try Data("ssh-ed25519 AAAA me@mac\n".utf8).write(to: ssh.appending(path: "id_ed25519.pub"))
        try Data("Host *\n".utf8).write(to: ssh.appending(path: "config"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ssh.appending(path: "config").path)

        #expect(Doctor.privateSSHFiles(ssh).map(\.lastPathComponent) == ["config", "id_ed25519"])
        let open = Doctor.sshPermissions(ssh)
        #expect(open.status == .fail)
        #expect(open.issues.first?.detail.contains("id_ed25519 is 644") == true)
        #expect(open.issues.first?.detail.contains("~/.ssh is 755") == true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
        #expect(Doctor.sshPermissions(ssh).status == .pass)
    }

    @Test func findsTheShellLineToBlame() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "lowtide-home-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("# export PATH=~/.old/bin:$PATH\nexport EDITOR=vim\nexport PATH=~/.old/bin:$PATH\n".utf8)
            .write(to: home.appending(path: ".zshrc"))
        #expect(Doctor.shellSource(home.path + "/.old/bin", home: home) == home.path + "/.zshrc:3")
        #expect(Doctor.shellSource("/not/there", home: home) == nil)
    }

    @Test func ratesStartupDiskAndAgent() {
        #expect(Doctor.startupOutcome(name: "zsh", milliseconds: 180).status == .pass)
        #expect(Doctor.startupOutcome(name: "zsh", milliseconds: 650).status == .warn)
        #expect(Doctor.startupOutcome(name: "zsh", milliseconds: 1800).status == .fail)
        #expect(Doctor.diskOutcome(available: 20_000_000_000, total: 1_000_000_000_000).status == .fail)
        #expect(Doctor.diskOutcome(available: 70_000_000_000, total: 1_000_000_000_000).status == .warn)
        #expect(Doctor.diskOutcome(available: 400_000_000_000, total: 1_000_000_000_000).summary == "400 GB free of 1.0 TB")
        // `ssh-add -l` exits 0 with keys, 1 with none, 2 without an agent.
        #expect(Doctor.sshAgentOutcome(status: 0, stdout: "256 SHA256:abc me@mac (ED25519)\n").summary == "1 key loaded")
        #expect(Doctor.sshAgentOutcome(status: 1, stdout: "The agent has no identities.\n").status == .pass)
        #expect(Doctor.sshAgentOutcome(status: 2, stdout: "").status == .warn)
    }

    @Test func plansEveryCheckOnce() {
        #expect(Set(Doctor.planned.map(\.id)).count == Doctor.planned.count)
        #expect(Doctor.planned.contains { $0.id == "path-shims" } && Doctor.planned.contains { $0.id == "path-login" })
    }

    @Test func refusesUnknownFixesAndFiles() async {
        await #expect(throws: LowtideError.self) { try await Doctor.fix("rm-everything") }
        await #expect(throws: LowtideError.self) { try await Doctor.fix("broken-links:/usr/bin") }
        await #expect(throws: LowtideError.self) { try await Doctor.openInEditor("/etc/passwd:1") }
    }
}
