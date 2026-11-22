import LowtideKit
import SwiftUI

/// A run's detail views: the summary, or one of its sections in full.
enum RunView: String, Hashable { case summary, hosts, processes, files }

/// What each rule in `RunRules` and `RunWriteUp` means, and what to do.
struct RuleHelp {
    /// The section the evidence lives in.
    var look: RunView?
    var means: String
    /// The rule, named for people.
    var name: String
    var todo: String

    static let all: [String: RuleHelp] = [
        "applescript": RuleHelp(look: .processes, means: "AppleScript can drive other apps, show fake password prompts and read what they show. Package scripts have no reason to use it.", name: "AppleScript from an install", todo: "Read the command below. If you didn't expect it, remove the package and check System Settings → Privacy & Security → Automation."),
        "background": RuleHelp(means: "The command was moved to the background (or still had its terminal) when the run was written up, so it may still be doing things.", name: "Still running", todo: "Nothing, if you sent it to the background yourself."),
        "credentials": RuleHelp(look: .files, means: "Files that hold keys or tokens (SSH, cloud, registry, Git credentials) changed while the install ran. Malicious packages steal or plant credentials here.", name: "Credentials changed", todo: "Open each file and check what changed. Rotate any token you can't account for, and remove the package if it did this."),
        "cron": RuleHelp(look: .processes, means: "Scheduled jobs make something run again later, long after the install finished.", name: "Scheduled job changed", todo: "Run crontab -l in a terminal and remove any line you didn't add."),
        "decode": RuleHelp(look: .processes, means: "Decoding base64 during an install often hides a second script from anyone reading the package.", name: "Hidden data decoded", todo: "Read the command and the package's install script before you run it again."),
        "download": RuleHelp(look: .processes, means: "A download outside the package manager fetches code the registry never checked. Common for binaries (esbuild, Electron), but it is also how droppers work.", name: "Extra download", todo: "Check the address is the package's own site. If not, remove the package."),
        "executable": RuleHelp(look: .processes, means: "A file was made executable. Normal for binaries a package ships; worth knowing when the file came from an extra download.", name: "Made executable", todo: "Nothing, unless the file is somewhere unexpected."),
        "inline-code": RuleHelp(look: .processes, means: "A script ran code passed on its command line instead of from a file in the package.", name: "Inline code", todo: "Read the command below; most are harmless one-liners."),
        "keychain": RuleHelp(look: .processes, means: "The security tool reads and changes the login keychain, where passwords and tokens live. Installs have no reason to touch it.", name: "Keychain access", todo: "Remove the package, then check Keychain Access for items changed around this time."),
        "left-running": RuleHelp(look: .processes, means: "A process the install started was still running after it ended. Installs normally finish completely.", name: "Left running", todo: "Stop it below unless it is a tool you know (a build server, a daemon you asked for)."),
        "quarantine": RuleHelp(look: .processes, means: "Removing the quarantine flag stops Gatekeeper from checking a downloaded app or binary before it first runs.", name: "Gatekeeper bypass", todo: "Find the file it cleared and check where it came from. Move it to the Trash if you don't know it."),
        "service": RuleHelp(look: .processes, means: "launchctl registers a background service that starts again at login. This is how malware stays on a Mac.", name: "Background service", todo: "Look in ~/Library/LaunchAgents for a new file. Protection → Permissions lists everything that runs at login."),
        "socket": RuleHelp(look: .processes, means: "Raw sockets (nc, socat) are how reverse shells give someone else a terminal on your Mac.", name: "Raw network socket", todo: "Treat this as serious: stop the process, remove the package and check what it connected to."),
        "ssh": RuleHelp(look: .processes, means: "An SSH connection during an install can be a Git dependency, or a way to send data out.", name: "SSH connection", todo: "Check the host is a Git server you use."),
        "startup": RuleHelp(look: .files, means: "Launch agents and shell start-up files run something every time you log in or open a terminal. Installs rarely need to.", name: "Start-up changed", todo: "Open each file. Remove what you didn't add, and the package that added it."),
        "sudo": RuleHelp(look: .processes, means: "Administrator rights let a script change anything on the Mac. Few packages need them.", name: "Administrator rights", todo: "Don't type your password into a prompt you didn't expect."),
        "unexpected-host": RuleHelp(look: .hosts, means: "The install talked to hosts outside its registry. Packages with binaries fetch from their own servers; anything sending more than it received is the part to question.", name: "Outside the registry", todo: "Open Hosts to see how much went each way and which process connected."),
    ]
}

extension Severity {
    var findingLabel: String { self == .alert ? "Needs a look" : self == .notice ? "Worth knowing" : "Note" }
}

/// Each finding, opening to the rule that raised it, the evidence, what it
/// means and what to do.
struct RunFindings: View {
    @Environment(\.palette) private var palette
    let findings: [RunFinding]
    let onLook: (RunView) -> Void

    var body: some View {
        if !findings.isEmpty {
            Pane("Findings", subtitle: "\(findings.count)") {
                RowStack(items: findings.enumerated().map { Indexed(index: $0.offset, value: $0.element) }) { item in
                    row(item.value)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ finding: RunFinding) -> some View {
        let text = Text(finding.text)
            .font(.ui(.sm))
            .foregroundStyle((finding.severity == .info ? palette.ink2 : palette.ink).color)
            .lineLimit(2)
            .truncationMode(.tail)
            .help(finding.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
        // Receipts saved before findings named their rule.
        if let rule = finding.rule, let help = RuleHelp.all[rule] {
            ExpandRow {
                HStack(spacing: Space.sm + 2) {
                    VerdictDot(severity: finding.severity, size: 6)
                    text
                }
            } detail: {
                HStack(spacing: Space.sm) {
                    Badge(finding.severity.findingLabel, tone: finding.severity.tone)
                    Text(help.name).font(.ui(.xs, .medium)).foregroundStyle(palette.ink2.color)
                }
                if !finding.evidence.isEmpty { Evidence(finding: finding) }
                Text(help.means).foregroundStyle(palette.ink2.color).frame(maxWidth: 560, alignment: .leading)
                Text("\(Text("What to do: ").font(.ui(.xs, .medium)).foregroundStyle(palette.ink2.color))\(help.todo)")
                    .foregroundStyle(palette.ink3.color)
                    .frame(maxWidth: 560, alignment: .leading)
                if let look = help.look {
                    Button("Open \(look.rawValue.capitalized)") { onLook(look) }
                        .buttonStyle(.lowtide(.secondary, size: .small))
                }
            }
        } else {
            HStack(spacing: Space.sm + 2) {
                VerdictDot(severity: finding.severity, size: 6)
                text
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.sm)
            .frame(minHeight: 38)
        }
    }
}

/// An item with its position, for lists of plain values.
struct Indexed<Value>: Identifiable {
    let index: Int
    let value: Value
    var id: Int { index }
}

/// The paths, hosts or command line behind a finding.
private struct Evidence: View {
    @Environment(\.palette) private var palette
    let finding: RunFinding

    var body: some View {
        if finding.rule == "unexpected-host" {
            Text(finding.evidence.joined(separator: ", "))
                .font(.mono(.xxs)).foregroundStyle(palette.ink2.color).textSelection(.enabled)
        } else {
            VStack(alignment: .leading, spacing: Space.xs) {
                ForEach(Array(finding.evidence.enumerated()), id: \.offset) { _, item in
                    if item.hasPrefix("/") || item.hasPrefix("~/") {
                        PathLine(path: item)
                    } else {
                        HStack(alignment: .top, spacing: Space.sm) {
                            Text(item)
                                .font(.mono(.xxs)).foregroundStyle(palette.ink2.color)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Copy") { FileActions.copy(item, what: "Command") }
                                .buttonStyle(.lowtide(.quiet, size: .small))
                        }
                    }
                }
            }
        }
    }
}
