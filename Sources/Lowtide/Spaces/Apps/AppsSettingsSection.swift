import LowtideKit
import SwiftUI

/// Settings › Advanced: the privileged helper (removals without a password).
struct AppsSettingsSection: View {
    @State private var state = PrivilegedHelper.state
    @State private var answering: Bool?
    @State private var error: String?

    var body: some View {
        Section {
            LabeledContent {
                switch state {
                case .on:
                    HStack(spacing: Space.sm) {
                        Label(answering == false ? "Approved, not answering" : "On", systemImage: answering == false ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(answering == false ? .orange : .green)
                            .labelStyle(.titleAndIcon)
                        Button("Turn Off") { turnOff() }
                    }
                case .approval:
                    Button("Open Login Items…") { enable() }
                case .off:
                    Button("Allow…") { enable() }
                case .unavailable:
                    Text("In the installed app only").foregroundStyle(.secondary)
                }
            } label: {
                Text("Remove apps without a password")
                Text(detail)
            }
        } header: {
            Text("Privileged helper")
        } footer: {
            if let error { Text(error).foregroundStyle(.red) }
        }
        // Approval happens in System Settings: look again on coming back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .task { refresh() }
    }

    private var detail: String {
        switch state {
        case .on: "Files an installer put in Applications or Library go to the Trash without asking. The helper answers only Lowtide."
        case .approval: "Waiting for you in System Settings › General › Login Items: switch on Lowtide."
        case .off: "Uninstalling asks for your password once per removal. Approve the helper once and it never asks."
        case .unavailable: "This is a development build; removals ask for your password."
        }
    }

    private func refresh() {
        state = PrivilegedHelper.state
        guard state == .on else {
            answering = nil
            return
        }
        Task { answering = await PrivilegedHelper.ping() }
    }

    private func enable() {
        do {
            state = try PrivilegedHelper.enable()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func turnOff() {
        Task {
            do {
                try await PrivilegedHelper.disable()
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            refresh()
        }
    }
}
