import LowtideKit
import SwiftUI

/// Every package install on the Mac, followed from start to finish: what it
/// reached, spawned, changed and left behind.
struct InstallWatchPage: View {
    private var store = RunsStore.shared

    var body: some View {
        let list = store.installs
        let following = store.following.filter { $0.ecosystem != nil }
        VStack(spacing: 0) {
            PageHeader("Install watch", description: description(list, following))
            RunsBrowser(runs: list, active: following, installsOnly: true, emptyTitle: "Watching, nothing installed yet",
                        emptyMessage: "Install a package from any terminal and it is followed from start to finish.") {
                HowInstallWatchWorks()
            }
        }
    }

    private func description(_ list: [Run], _ following: [ActiveRun]) -> String? {
        guard store.loaded else { return "Reading followed installs…" }
        let alerts = list.filter { $0.verdict == .alert }.count
        let notices = list.filter { $0.verdict == .notice }.count
        return [
            "\(LowtideFormat.count(list.count, "install")) followed",
            alerts > 0 ? "\(alerts) need a look" : nil,
            notices > 0 ? "\(notices) worth knowing" : nil,
            following.isEmpty ? nil : "\(following.count) running now",
        ].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct HowInstallWatchWorks: View {
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs + 2) {
            Text("How Install watch works").font(.ui(.xs, .semibold)).foregroundStyle(palette.ink2.color)
            Text("Every npm, pnpm, yarn, bun, pip, uv, Homebrew, Cargo, RubyGems and Go install on this Mac is followed, in any terminal, along with \(Text("curl … | sh").font(.mono(.xxs))) in Lowtide's own. You get an alert when an install's scripts change your credentials or what runs at start-up, touch the keychain, remove Gatekeeper's quarantine, or open raw sockets.")
            Text("It also notes destinations outside the package registry and anything left running. Downloads from the registry itself are expected.")
        }
        .font(.ui(.xs))
        .foregroundStyle(palette.ink3.color)
        .frame(maxWidth: 560, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}
