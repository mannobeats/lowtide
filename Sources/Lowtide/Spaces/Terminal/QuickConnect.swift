import LowtideKit
import SwiftUI

/// Quick connect (⇧⌘K): an SSH session to a host that isn't saved.
enum QuickConnect {
    static func present() {
        DevSheetHost.present { close in QuickConnectSheet(close: close) }
    }
}

private struct QuickConnectSheet: View {
    @Environment(\.palette) private var palette
    @State private var target = ""
    @State private var problem: String?
    @FocusState private var focused: Bool
    let close: () -> Void

    var body: some View {
        DevSheet("Quick connect", description: "Open an SSH session without saving the host.", width: 400) {
            DevField("Address", hint: problem ?? "For example root@1.2.3.4 or ubuntu@server.example.com:2222") {
                TextField("user@host[:port]", text: $target)
                    .devField()
                    .font(.mono(.sm))
                    .focused($focused)
                    .onSubmit(connect)
                    .onChange(of: target) { _, _ in problem = nil }
            }
        } footer: {
            Button("Cancel", action: close).buttonStyle(.quiet).keyboardShortcut(.cancelAction)
            Button("Connect", action: connect).buttonStyle(.primary).keyboardShortcut(.defaultAction)
                .disabled(target.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .onAppear { focused = true }
    }

    private func connect() {
        guard let parsed = SSHCommand.parseTarget(target) else {
            problem = "Couldn't read that address. Use user@host or user@host:port."
            return
        }
        guard !parsed.user.isEmpty else {
            problem = "Include a username: user@host."
            return
        }
        do {
            try SessionStore.shared.openQuick(user: parsed.user, host: parsed.host, port: parsed.port)
            AppModel.shared.open(.sessions)
            close()
        } catch {
            problem = error.localizedDescription
        }
    }
}
