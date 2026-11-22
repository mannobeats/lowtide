import LowtideKit
import SwiftUI

/// Saved hosts, groups, credentials, forwards and snippets, the running
/// tunnels and the Fleet's latest view, for every Developer page.
@Observable
final class RemoteStore {
    static let shared = RemoteStore()

    private(set) var snapshot = RemoteVault.Snapshot()
    private(set) var loaded = false
    private(set) var error: String?
    private(set) var forwardStatus: [String: Tunnels.Status] = [:]
    private(set) var fleet: [Fleet.Server] = []
    /// Saved host ids the Fleet watches.
    private(set) var watched: Set<String>
    /// Hosts with a probe started from the page.
    private(set) var probing: Set<String> = []

    @ObservationIgnored private var fleetLoop: Task<Void, Never>?
    private let watchedFile = "fleet-watched.json"

    init() {
        watched = Set(JSONStore.load(watchedFile, default: [String]()))
    }

    var vault: RemoteVault? { RemoteVault.shared }
    var resolution: HostResolution { HostResolution(snapshot) }

    func host(_ id: String?) -> RemoteHost? { id.flatMap { id in snapshot.hosts.first { $0.id == id } } }
    func group(_ id: String?) -> HostGroup? { id.flatMap { id in snapshot.groups.first { $0.id == id } } }
    func identity(_ id: String?) -> Identity? { id.flatMap { id in snapshot.identities.first { $0.id == id } } }

    // MARK: Loading

    func load() async {
        guard let vault else {
            error = "The vault couldn't be opened."
            loaded = true
            return
        }
        do {
            let next = try await vault.load()
            if next != snapshot { snapshot = next }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
        syncFleet()
    }

    /// Runs a vault change, reloads, and says what failed.
    private func change(_ failure: String, _ body: (RemoteVault) async throws -> Void) async -> Bool {
        guard let vault else {
            Toasts.shared.show(failure, detail: "The vault couldn't be opened.", tone: .bad)
            return false
        }
        do {
            try await body(vault)
            await load()
            return true
        } catch {
            Toasts.shared.failure(failure, error)
            await load()
            return false
        }
    }

    // MARK: Hosts

    @discardableResult
    func save(_ host: RemoteHost) async -> Bool {
        await change("Couldn't save \(host.name)") { try await $0.save(host) }
    }

    func delete(hosts: [RemoteHost]) async {
        var deleted = 0
        for host in hosts {
            let ok = await change("Couldn't delete \(host.name)") { vault in
                for forward in try await vault.deleteHost(host.id) { Tunnels.shared.stop(forward) }
            }
            if ok { deleted += 1 }
        }
        watched.subtract(hosts.map(\.id))
        saveWatched()
        if deleted > 0 { Toasts.shared.show(hosts.count == 1 ? "Deleted \(hosts[0].name)" : "Deleted \(LowtideKitFormat.count(deleted, "host"))") }
    }

    func touch(_ host: RemoteHost) async {
        try? await vault?.touchHost(host.id)
        await load()
    }

    // MARK: Groups

    @discardableResult
    func save(_ group: HostGroup) async -> Bool {
        await change("Couldn't save \(group.name)") { try await $0.save(group) }
    }

    func delete(_ group: HostGroup) async {
        if await change("Couldn't delete \(group.name)", { try await $0.deleteGroup(group.id) }) {
            Toasts.shared.show("Deleted \(group.name)")
        }
    }

    /// Every group's place in the tree, for pickers: (group, depth).
    var groupTree: [(group: HostGroup, depth: Int)] {
        var out: [(HostGroup, Int)] = []
        var seen = Set<String>()
        func walk(_ parent: String?, _ depth: Int) {
            for group in snapshot.groups where group.parentID == parent && seen.insert(group.id).inserted {
                out.append((group, depth))
                walk(group.id, depth + 1)
            }
        }
        walk(nil, 0)
        // Orphans and loops still show, at the top level.
        for group in snapshot.groups where !seen.contains(group.id) { out.append((group, 0)) }
        return out.map { (group: $0.0, depth: $0.1) }
    }

    /// A group and everything under it (a group can't move inside itself).
    func descendants(of id: String) -> Set<String> {
        var result: Set<String> = [id]
        var changed = true
        while changed {
            changed = false
            for group in snapshot.groups where group.parentID.map(result.contains) == true && !result.contains(group.id) {
                result.insert(group.id)
                changed = true
            }
        }
        return result
    }

    // MARK: Credentials

    @discardableResult
    func create(_ identity: Identity, secret: String?) async -> Bool {
        await change("Couldn't save \(identity.name)") { try await $0.create(identity, secret: secret) }
    }

    /// Removes a credential; with `files`, its key files go to the Trash too.
    func delete(_ identity: Identity, files: Bool) async {
        let removed = await change("Couldn't remove \(identity.name)") { try await $0.deleteIdentity(identity.id) }
        guard removed else { return }
        if files, let path = identity.keyPath {
            do {
                try await SSHKeys.trash(path)
                Toasts.shared.show("Moved the key files to the Trash", detail: Paths.tilde(SSHCommand.expandHome(path)))
            } catch {
                Toasts.shared.failure("The credential is gone, but its key files stayed", error)
            }
        } else {
            Toasts.shared.show("Removed \(identity.name)", detail: identity.keyPath.map { "Its key files are still in \(Paths.tilde(SSHCommand.expandHome($0)))" })
        }
    }

    // MARK: Forwards

    @discardableResult
    func save(_ forward: PortForward) async -> Bool {
        await change("Couldn't save \(forward.name)") { try await $0.save(forward) }
    }

    func delete(forwards: [PortForward]) async {
        var deleted = 0
        for forward in forwards {
            Tunnels.shared.stop(forward.id)
            if await change("Couldn't delete \(forward.name)", { try await $0.deleteForward(forward.id) }) { deleted += 1 }
        }
        if deleted > 0 {
            Toasts.shared.show(forwards.count == 1 ? "Deleted \(forwards[0].name)" : "Deleted \(LowtideKitFormat.count(deleted, "forward"))")
        }
    }

    func isRunning(_ forward: PortForward) -> Bool {
        switch forwardStatus[forward.id] {
        case .starting, .running: true
        default: false
        }
    }

    func start(_ forward: PortForward, quiet: Bool = false) {
        guard !isRunning(forward) else { return }
        guard let host = host(forward.hostID) else {
            if !quiet { Toasts.shared.show("Couldn't start \(forward.name)", detail: "Its host no longer exists.", tone: .bad) }
            return
        }
        let resolution = resolution
        do {
            try Tunnels.shared.start(forward, endpoint: resolution.endpoint(for: host), secrets: resolution.secrets(for: host),
                                     label: forward.name)
        } catch {
            if !quiet { Toasts.shared.failure("Couldn't start \(forward.name)", error) }
        }
    }

    func stop(_ forward: PortForward) { Tunnels.shared.stop(forward.id) }

    func stop(forwards: [PortForward]) {
        for forward in forwards { Tunnels.shared.stop(forward.id) }
    }

    /// The tunnels' own thread reports here.
    func tunnelChanged(_ id: String, _ status: Tunnels.Status?) {
        let previous = forwardStatus[id]
        forwardStatus[id] = status
        if case .failed(let reason)? = status, let forward = snapshot.forwards.first(where: { $0.id == id }) {
            // Said once, when it happens; the row keeps saying it.
            if case .failed? = previous {} else { Toasts.shared.show("\(forward.name) stopped", detail: reason, tone: .warn) }
        }
        updateStatusLine()
    }

    /// Starts the forwards marked to start with the app.
    func autoStart() async {
        if !loaded { await load() }
        for forward in snapshot.forwards where forward.autoStart { start(forward, quiet: true) }
    }

    private func updateStatusLine() {
        let running = forwardStatus.values.filter { if case .running = $0 { true } else { false } }.count
        StatusLine.shared.set("forwards", running > 0 ? "\(LowtideKitFormat.count(running, "forward")) running" : nil, tone: .ok)
        SidebarBadges.shared.totals[.forwards] = running > 0 ? running : nil
    }

    // MARK: Snippets

    @discardableResult
    func save(_ snippet: Snippet) async -> Bool {
        await change("Couldn't save \(snippet.name)") { try await $0.save(snippet) }
    }

    func delete(_ snippet: Snippet) async {
        if await change("Couldn't delete \(snippet.name)", { try await $0.deleteSnippet(snippet.id) }) {
            Toasts.shared.show("Deleted \(snippet.name)")
        }
    }

    // MARK: Connecting

    /// Opens an SSH session to a saved host in front.
    func connect(_ host: RemoteHost) {
        SessionStore.shared.openSSH(host)
        AppModel.shared.show(.sessions)
        Task { await touch(host) }
    }

    func isConnected(_ host: RemoteHost) -> Bool {
        SessionStore.shared.workspace.tabs.contains { $0.hostID == host.id && !$0.closed }
    }

    // MARK: Fleet

    func toggleWatch(_ host: RemoteHost) {
        if watched.contains(host.id) { watched.remove(host.id) } else { watched.insert(host.id) }
        saveWatched()
        syncFleet()
    }

    private func saveWatched() { JSONStore.save(watched.sorted(), to: watchedFile) }

    private func target(_ host: RemoteHost) -> Fleet.Target {
        let resolution = resolution
        return Fleet.Target(id: host.id, name: host.name, endpoint: resolution.endpoint(for: host),
                            secrets: resolution.secrets(for: host))
    }

    /// Keeps the monitor's list in step with the saved hosts and the picks.
    func syncFleet() {
        let targets = snapshot.hosts.filter { watched.contains($0.id) }.map(target)
        Task {
            await FleetMonitor.shared.watch(targets)
            await refreshFleet()
        }
    }

    func refreshFleet() async {
        let status = await FleetMonitor.shared.status()
        if status != fleet { fleet = status }
        let troubled = status.filter { $0.state == .unreachable || $0.state == .needsKey }.count
        SidebarBadges.shared.counts[.hosts] = troubled > 0 ? troubled : nil
        if troubled > 0 { SidebarBadges.shared.warning.insert(.hosts) } else { SidebarBadges.shared.warning.remove(.hosts) }
    }

    func probe(_ host: RemoteHost) async {
        probing.insert(host.id)
        _ = await FleetMonitor.shared.probe(target(host))
        probing.remove(host.id)
        await refreshFleet()
    }

    /// Polls the monitor: often while a Fleet view is open, rarely otherwise.
    func startFleetPolling() {
        guard fleetLoop == nil else { return }
        fleetLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshFleet()
                let fast = AppModel.shared.page == .hosts
                try? await Task.sleep(for: .seconds(fast ? 5 : 30))
            }
        }
    }

    func stopFleetPolling() {
        fleetLoop?.cancel()
        fleetLoop = nil
    }
}
