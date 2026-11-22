import LowtideKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings (⌘,): app-wide choices only. Extensions are set up on their own
/// pages in the Extensions space.
struct SettingsWindow: View {
    private var themes = ThemeStore.shared

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Appearance", systemImage: "paintpalette") { AppearanceSettings() }
            Tab("Permissions", systemImage: "hand.raised") { PermissionSettings() }
            Tab("Advanced", systemImage: "wrench.and.screwdriver") { AdvancedSettings() }
        }
        .frame(width: 600)
        .environment(\.palette, themes.palette)
        .preferredColorScheme(themes.colorScheme)
    }
}

private struct GeneralSettings: View {
    @State private var openAtLogin = LoginItem.isOn
    @AppStorage("showStatusItem") private var showStatusItem = true
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, on in
                        do { try LoginItem.set(on) } catch {
                            self.error = error.localizedDescription
                            openAtLogin = LoginItem.isOn
                        }
                    }
                if LoginItem.needsApproval {
                    Text("Allow Lowtide in System Settings › General › Login Items.").font(.callout).foregroundStyle(.secondary)
                }
                Toggle("Show Lowtide in the menu bar", isOn: $showStatusItem)
            } footer: {
                if let error { Text(error).foregroundStyle(.red) }
            }
            UpdateSettingsSection()
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct AppearanceSettings: View {
    @Bindable private var themes = ThemeStore.shared
    @State private var importing = false
    @State private var message: String?

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Theme", selection: $themes.choice) {
                    Text("Automatic").tag(ThemeStore.automatic)
                    Divider()
                    ForEach(themes.themes) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                HStack {
                    Text("Automatic follows your Mac: Situation in dark mode, Paper in light.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Import Theme…") { importing = true }
                }
                if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                message = "Installed \(try themes.install(url))."
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

private struct PermissionSettings: View {
    @State private var tick = 0

    var body: some View {
        Form {
            Section {
                ForEach(Permission.allCases) { permission in
                    LabeledContent {
                        HStack {
                            switch permission.state {
                            case .granted: Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            case .denied: Button("Allow…") { permission.request() }
                            case .unknown: Button("Open Settings…") { NSWorkspace.shared.open(permission.settingsURL) }
                            }
                        }
                        .labelStyle(.titleAndIcon)
                    } label: {
                        Text(permission.title)
                        Text(permission.purpose)
                    }
                }
            } footer: {
                Text("Lowtide asks for each permission when a feature first needs it. Nothing leaves your Mac.")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .id(tick)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in tick += 1 }
    }
}

private struct AdvancedSettings: View {
    var body: some View {
        Form {
            Section("Data") {
                LabeledContent("Data folder") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.data]) }
                }
                LabeledContent("Caches") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.cache]) }
                }
            }
            AdvancedSettingsSections()
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Sections other parts of the app add to Advanced (the privileged helper).
struct AdvancedSettingsSections: View {
    var body: some View {
        AppsSettingsSection()
    }
}
