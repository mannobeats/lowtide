import AppKit
import LowtideKit
import SwiftUI

/// Developer › Port forwards: tunnels through saved hosts, started by hand
/// or with the app, with their status.
struct ForwardsPage: View {
    @Environment(\.palette) private var palette
    private var remote = RemoteStore.shared
    @State private var editing: ForwardDraft?
    @State private var selection: Set<String> = []
    @State private var anchor: String?
    @State private var confirm: ConfirmRequest?

    var running: Int { remote.snapshot.forwards.filter(remote.isRunning).count }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("Port forwards", description: remote.snapshot.forwards.isEmpty ? nil
                       : "\(LowtideKitFormat.count(remote.snapshot.forwards.count, "forward")) · \(running) running") {
                EmptyView()
            } action: {
                Button { editing = ForwardDraft() } label: { Label("New forward", systemImage: "plus") }
                    .buttonStyle(.primary)
                    .disabled(remote.snapshot.hosts.isEmpty)
                    .help(remote.snapshot.hosts.isEmpty ? "Save a host first: a forward goes through one" : "New port forward")
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await remote.load() }
        .sheet(item: $editing) { draft in ForwardSheet(draft: draft) { editing = nil } }
        .confirmation($confirm)
    }

    var selected: [PortForward] { remote.snapshot.forwards.filter { selection.contains($0.id) } }

    @ViewBuilder private var content: some View {
        if !remote.loaded {
            ScanningState(title: "Loading forwards")
        } else if let error = remote.error {
            ErrorState(message: error) { Task { await remote.load() } }
        } else if remote.snapshot.forwards.isEmpty {
            VStack(spacing: Space.lg) {
                HeroArt("developer", size: 80)
                EmptyState("No port forwards yet", symbol: "arrow.left.arrow.right",
                           message: "Reach a database or dashboard on a server as if it ran on this Mac, through one of your saved hosts.") {
                    if remote.snapshot.hosts.isEmpty {
                        Button("Add a host first") { AppModel.shared.open(.hosts) }.buttonStyle(.secondary)
                    } else {
                        Button("New forward") { editing = ForwardDraft() }.buttonStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            let list = remote.snapshot.forwards
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, forward in
                        if index > 0 { Hairline(inset: 60) }
                        ForwardRow(forward: forward, selected: selection.contains(forward.id),
                                   selectionCount: selection.contains(forward.id) ? selection.count : 1,
                                   onClick: { click(forward, in: list) },
                                   onEdit: { editing = ForwardDraft(forward) },
                                   onDelete: { ask(delete: selection.contains(forward.id) ? selected : [forward]) })
                    }
                }
                .card()
                .padding(.horizontal, Space.page + 4)
                .padding(.bottom, Space.page * 3)
                .frame(maxWidth: 1180)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
            .onDeleteCommand { ask(delete: selected) }
            .onExitCommand { selection = [] }
            .onKeyPress(.space) {
                guard !selected.isEmpty else { return .ignored }
                for forward in selected { remote.isRunning(forward) ? remote.stop(forward) : remote.start(forward) }
                return .handled
            }
            .overlay(alignment: .bottom) {
                if selection.count > 1 {
                    let runningSelected = selected.filter(remote.isRunning)
                    SelectionBar(count: selection.count, noun: "forward") { selection = [] } actions: {
                        if !runningSelected.isEmpty {
                            Button("Stop \(runningSelected.count)") { remote.stop(forwards: runningSelected) }
                                .buttonStyle(.lowtide(.secondary, size: .small))
                        }
                        Button("Delete", role: .destructive) { ask(delete: selected) }.buttonStyle(.lowtide(.destructive, size: .small))
                    }
                    .padding(.bottom, Space.xl)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(Motion.spring, value: selection.count > 1)
        }
    }

    private func click(_ forward: PortForward, in list: [PortForward]) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(forward.id) { selection.remove(forward.id) } else { selection.insert(forward.id) }
            anchor = forward.id
        } else if flags.contains(.shift), let anchor, let a = list.firstIndex(where: { $0.id == anchor }),
                  let b = list.firstIndex(where: { $0.id == forward.id }) {
            selection = Set(list[min(a, b)...max(a, b)].map(\.id))
        } else {
            selection = [forward.id]
            anchor = forward.id
        }
    }

    private func ask(delete forwards: [PortForward]) {
        guard !forwards.isEmpty else { return }
        let running = forwards.filter(remote.isRunning).count
        confirm = ConfirmRequest(
            title: forwards.count > 1 ? "Delete \(forwards.count) port forwards?" : "Delete port forward?",
            message: "Delete \(forwards.count > 1 ? LowtideKitFormat.count(forwards.count, "forward") : "“\(forwards[0].name)”")?"
                + (running > 0 ? " \(LowtideKitFormat.count(running, "running tunnel")) will be stopped." : ""),
            confirm: forwards.count > 1 ? "Delete \(forwards.count) Forwards" : "Delete Forward") {
            selection.subtract(forwards.map(\.id))
            Task { await RemoteStore.shared.delete(forwards: forwards) }
        }
    }
}

private struct ForwardRow: View {
    @Environment(\.palette) private var palette
    @State private var hovering = false
    let forward: PortForward
    let selected: Bool
    let selectionCount: Int
    let onClick: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var remote: RemoteStore { RemoteStore.shared }

    var kindLabel: String {
        switch forward.kind {
        case .local: "Local"
        case .remote: "Remote"
        case .dynamic: "SOCKS proxy"
        }
    }

    var body: some View {
        let status = remote.forwardStatus[forward.id]
        let running = remote.isRunning(forward)
        HStack(spacing: Space.md) {
            DevGlyphTile("forwards", live: running)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.sm) {
                    Text(forward.name).font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color).lineLimit(1)
                    switch status {
                    case .running?: Badge("Running", tone: .ok)
                    case .starting?: Badge("Starting", tone: .neutral)
                    case .failed?: Badge("Stopped", tone: .bad)
                    case nil: EmptyView()
                    }
                    if forward.autoStart { Badge("Starts with the app") }
                }
                HStack(spacing: 0) {
                    Text("\(kindLabel)\(remote.host(forward.hostID).map { " via \($0.name)" } ?? " · host missing") · ")
                    Sensitive(text: forward.route, font: .mono(.xxs))
                }
                .font(.ui(.xs))
                .foregroundStyle(palette.ink3.color)
                .lineLimit(1)
                if case .failed(let reason)? = status {
                    Text(reason).font(.ui(.xs)).foregroundStyle(palette.bad.color).lineLimit(2).textSelection(.enabled)
                }
            }
            Spacer(minLength: Space.md)
            if hovering { IconButton("trash", help: "Delete", action: onDelete) }
            Button(running ? "Stop" : "Start") { running ? remote.stop(forward) : remote.start(forward) }
                .buttonStyle(.lowtide(.secondary, size: .small))
                .frame(width: 64)
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, 8)
        .frame(minHeight: 54)
        .background((selected ? palette.selectedBrand : hovering ? palette.hover : ColorValue(r: 0, g: 0, b: 0, a: 0)).color)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: onEdit)
        .onTapGesture(perform: onClick)
        .contextMenu {
            Button(running ? "Stop" : "Start") { running ? remote.stop(forward) : remote.start(forward) }
            Button("Edit…", action: onEdit)
            Button(forward.autoStart ? "Don't Start with Lowtide" : "Start with Lowtide") {
                var next = forward
                next.autoStart.toggle()
                Task { await remote.save(next) }
            }
            if forward.kind != .remote {
                Button("Copy Local Address") {
                    Files.copy("\(forward.bindHost?.isEmpty == false ? forward.bindHost! : "127.0.0.1"):\(forward.bindPort)")
                }
            }
            Divider()
            Button(selectionCount > 1 ? "Delete \(selectionCount) Forwards…" : "Delete…", role: .destructive, action: onDelete)
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ForwardDraft: Identifiable {
    var id = UUID()
    var forward: PortForward?
    var name = ""
    var hostID = ""
    var kind: PortForward.Kind = .local
    var bindHost = "127.0.0.1"
    var bindPort = "8080"
    var targetHost = "127.0.0.1"
    var targetPort = "80"
    var autoStart = false

    init(_ forward: PortForward? = nil) {
        self.forward = forward
        guard let forward else { return }
        name = forward.name
        hostID = forward.hostID
        kind = forward.kind
        bindHost = forward.bindHost ?? ""
        bindPort = String(forward.bindPort)
        targetHost = forward.targetHost ?? "127.0.0.1"
        targetPort = forward.targetPort.map(String.init) ?? ""
        autoStart = forward.autoStart
    }
}

private struct ForwardSheet: View {
    @Environment(\.palette) private var palette
    @State var draft: ForwardDraft
    @State private var problem: String?
    let close: () -> Void
    private var remote: RemoteStore { RemoteStore.shared }

    init(draft: ForwardDraft, close: @escaping () -> Void) {
        _draft = State(initialValue: draft)
        self.close = close
    }

    var hint: String {
        switch draft.kind {
        case .local: "A port on this Mac reaches a port on the far side."
        case .remote: "A port on the host reaches a port on this Mac."
        case .dynamic: "Apps on this Mac browse through the host."
        }
    }

    var body: some View {
        DevSheet(draft.forward == nil ? "New port forward" : "Edit port forward", description: "A tunnel through one of your saved hosts.") {
            DevField("Name") { TextField("Production database", text: $draft.name).devField() }
            DevField("Through host") {
                Picker("Through host", selection: $draft.hostID) {
                    Text("Pick a host…").tag("")
                    ForEach(remote.snapshot.hosts) { host in Text(host.name).tag(host.id) }
                }
                .labelsHidden()
            }
            DevField("Kind", hint: hint) {
                Segmented($draft.kind, [(.local, "Local"), (.remote, "Remote"), (.dynamic, "SOCKS proxy")])
            }
            HStack(alignment: .top, spacing: Space.sm) {
                DevField(draft.kind == .remote ? "Host side address" : "Bind address") {
                    TextField("127.0.0.1", text: $draft.bindHost).devField()
                }
                DevField("Port") { TextField("8080", text: $draft.bindPort).devField() }.frame(width: 100)
            }
            if draft.kind != .dynamic {
                HStack(alignment: .top, spacing: Space.sm) {
                    DevField(draft.kind == .remote ? "To, on this Mac" : "To, from the host") {
                        TextField("127.0.0.1", text: $draft.targetHost).devField()
                    }
                    DevField("Port") { TextField("80", text: $draft.targetPort).devField() }.frame(width: 100)
                }
            }
            Toggle("Start when Lowtide opens", isOn: $draft.autoStart).toggleStyle(.checkbox).font(.ui(.sm))
            if let problem { Text(problem).font(.ui(.xs)).foregroundStyle(palette.bad.color) }
        } footer: {
            Button("Cancel", action: close).buttonStyle(.quiet).keyboardShortcut(.cancelAction)
            Button("Save forward", action: save).buttonStyle(.primary).keyboardShortcut(.defaultAction)
        }
    }

    private func save() {
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !draft.hostID.isEmpty else { problem = "Name and host are required."; return }
        guard let bind = Int(draft.bindPort.trimmingCharacters(in: .whitespaces)), SSHCommand.validPort(bind) else {
            problem = "Ports must be between 1 and 65535."
            return
        }
        var target: Int?
        if draft.kind != .dynamic {
            guard let port = Int(draft.targetPort.trimmingCharacters(in: .whitespaces)), SSHCommand.validPort(port) else {
                problem = "Ports must be between 1 and 65535."
                return
            }
            target = port
        }
        for value in [draft.bindHost, draft.targetHost] where value.contains(where: { $0.isWhitespace || $0 == "@" }) || value.hasPrefix("-") {
            problem = "Addresses can't contain spaces or start with a dash."
            return
        }
        var forward = draft.forward ?? PortForward(name: name, hostID: draft.hostID, kind: draft.kind, bindPort: bind)
        let wasRunning = draft.forward.map(remote.isRunning) ?? false
        forward.name = name
        forward.hostID = draft.hostID
        forward.kind = draft.kind
        forward.bindHost = draft.bindHost.trimmingCharacters(in: .whitespaces)
        forward.bindPort = bind
        forward.targetHost = draft.kind == .dynamic ? nil : draft.targetHost.trimmingCharacters(in: .whitespaces)
        forward.targetPort = target
        forward.autoStart = draft.autoStart
        Task {
            guard await remote.save(forward) else { return }
            // A running tunnel picks up the change by restarting.
            if wasRunning {
                remote.stop(forward)
                try? await Task.sleep(for: .milliseconds(400))
                remote.start(forward)
            }
            Toasts.shared.show("Saved \(name)")
            close()
        }
    }
}
