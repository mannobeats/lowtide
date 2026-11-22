import AppKit
import LowtideKit
import SwiftUI

/// Extensions › Command bar: the shortcut and the look, Quick access, the
/// bar's own extensions, and what it learned.
struct CommandBarPage: View {
    var body: some View {
        ExtensionHeader(.commandbar) { CommandBarSettings() }
    }
}

private struct CommandBarSettings: View {
    @Environment(\.palette) private var palette
    @Bindable private var settings = BarSettings.shared
    @State private var sheet: BarExtension?
    @State private var reviewing = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            Pane("Shortcut and look") {
                Button("Open the Bar") { CommandBarPanel.shared.show() }.buttonStyle(.lowtide(.quiet, size: .small))
            } content: {
                SettingRow("Keyboard shortcut", hint: "Opens the bar over any app") {
                    ShortcutSetup {
                        Toggle("Use the keyboard shortcut", isOn: $settings.prefs.hotkeyEnabled).labelsHidden().toggleStyle(.switch)
                            .controlSize(.small).help("Use the keyboard shortcut")
                    }
                }
                Hairline(inset: Space.lg)
                SettingRow("Glass", hint: "How much of what's behind shows through") {
                    HStack(spacing: Space.sm) {
                        Text("Frosted").font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                        Slider(value: Binding(get: { Double(settings.prefs.glass) }, set: { settings.prefs.glass = Int($0) }),
                               in: 0...100, step: 5)
                            .frame(width: 180)
                            .accessibilityLabel("Glass")
                        Text("Clear").font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                        Text("\(settings.prefs.glass)%").font(.ui(.xs)).monospacedDigit().foregroundStyle(palette.ink2.color)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
                Hairline(inset: Space.lg)
                SettingRow("Compact", hint: "Only the field until you type") {
                    Toggle("Compact", isOn: $settings.prefs.compact).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
            QuickAccessPane()
            extensionsPane
            Pane("Learned") {
                SettingRow("Names and hidden rows", hint: "\(settings.prefs.aliases.count) names · \(settings.prefs.hidden.count) hidden") {
                    Button("Review…") { reviewing = true }.buttonStyle(.lowtide(.secondary, size: .small))
                }
                Hairline(inset: Space.lg)
                SettingRow("What you use most", hint: "The bar learns what you pick after typing what") {
                    Button("Forget") {
                        settings.prefs.forget()
                        settings.habits.forget()
                        Toasts.shared.show("The bar forgot what you use most")
                    }
                    .buttonStyle(.lowtide(.quiet, size: .small))
                    .disabled(settings.prefs.usage.isEmpty)
                }
            }
        }
        .sheet(item: $sheet) { BarExtensionSheet(ext: $0) }
        .sheet(isPresented: $reviewing) { RememberedSheet() }
    }

    private var extensionsPane: some View {
        let on = BarExtension.catalog.filter { settings.prefs.isOn($0.id) }.count
        return Pane("Extensions") {
            Text("\(on) of \(BarExtension.catalog.count) on").font(.ui(.xs)).monospacedDigit().foregroundStyle(palette.ink3.color)
        } content: {
            VStack(alignment: .leading, spacing: Space.lg) {
                ForEach(BarExtension.Category.allCases, id: \.self) { category in
                    VStack(alignment: .leading, spacing: Space.sm) {
                        GroupHeading(category.rawValue)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: Space.sm)], spacing: Space.sm) {
                            ForEach(BarExtension.catalog.filter { $0.category == category }) { ext in
                                ExtensionTile(ext: ext, on: settings.prefs.isOn(ext.id)) { settings.prefs.toggle(ext.id) } open: { sheet = ext }
                            }
                        }
                    }
                }
            }
            .padding([.horizontal, .bottom], Space.lg)
        }
    }
}

/// A setting: its name and a line under it on the left, the control on the right.
struct SettingRow<Control: View>: View {
    @Environment(\.palette) private var palette
    let title: String
    var hint: String?
    @ViewBuilder var control: Control

    init(_ title: String, hint: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.hint = hint
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.ui(.sm)).foregroundStyle(palette.ink.color)
                if let hint { Text(hint).font(.ui(.xs)).foregroundStyle(palette.ink3.color).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: Space.md)
            control
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
    }
}

private struct ExtensionTile: View {
    @Environment(\.palette) private var palette
    let ext: BarExtension
    let on: Bool
    let toggle: () -> Void
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: ext.symbol).font(.system(size: 16)).foregroundStyle((on ? palette.ink2 : palette.ink4).color)
                Spacer()
                if !ext.alwaysOn {
                    Toggle(ext.name, isOn: Binding(get: { on }, set: { _ in toggle() }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
            }
            Spacer(minLength: Space.sm)
            Text(ext.name).font(.ui(.sm)).foregroundStyle((on ? palette.ink : palette.ink3).color).lineLimit(1)
        }
        .padding(10)
        .frame(height: 80)
        .background((on ? palette.surface : ColorValue(r: 0, g: 0, b: 0, a: 0)).color, in: .rect(cornerRadius: Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Radius.md)
            .strokeBorder((hovering ? palette.lineStrong : palette.line).color, style: StrokeStyle(lineWidth: 1, dash: on ? [] : [4, 3])))
        .contentShape(.rect)
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .help(ext.description)
        .contextMenu {
            Button("Settings…", action: open)
            if !ext.alwaysOn { Button(on ? "Turn Off" : "Turn On", action: toggle) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(ext.name), \(on ? "on" : "off")")
    }
}

/// What the empty bar offers first; ⌘1–9 run them as soon as it opens.
private struct QuickAccessPane: View {
    @Environment(\.palette) private var palette
    @Bindable private var settings = BarSettings.shared

    var body: some View {
        let pins = settings.prefs.pins
        Pane("Quick access", subtitle: "First on the empty bar; ⌘1–9 run them. Add anything from the bar with ⌘P") {
            if pins != BarPrefs.defaultPins {
                Button("Reset") { settings.prefs.pins = BarPrefs.defaultPins }.buttonStyle(.lowtide(.quiet, size: .small))
            }
        } content: {
            if pins.isEmpty {
                Text("Nothing yet. Select a row in the bar and press ⌘P.").font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                    .padding([.horizontal, .bottom], Space.lg)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(pins.enumerated()), id: \.element) { index, key in
                        let (name, from) = PinNames.describe(key)
                        if index > 0 { Hairline(inset: Space.lg) }
                        HStack(spacing: Space.sm) {
                            KeyCap(keys: index < 9 ? "⌘\(index + 1)" : " ").frame(width: 30, alignment: .leading)
                            Text(name).font(.ui(.sm)).foregroundStyle(palette.ink.color).lineLimit(1)
                            Spacer(minLength: Space.sm)
                            Text(from).font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                            IconButton("arrow.up", help: "Move \(name) up") { settings.prefs.movePin(key, by: -1) }.disabled(index == 0)
                            IconButton("arrow.down", help: "Move \(name) down") { settings.prefs.movePin(key, by: 1) }
                                .disabled(index == pins.count - 1)
                            IconButton("xmark", help: "Remove \(name)") { settings.prefs.togglePin(key) }
                        }
                        .padding(.horizontal, Space.lg)
                        .frame(height: 36)
                    }
                }
                .padding(.bottom, Space.xs)
            }
        }
    }
}

/// A saved row's name and where it's from, read off its key.
enum PinNames {
    static func describe(_ key: String) -> (String, String) {
        if key == "lowtide.ask" { return ("Ask about this Mac", "Lowtide") }
        if key.hasPrefix("lowtide.page:"), let page = Page(rawValue: String(key.dropFirst(10))) {
            return (page.title, page.space == .home ? "Lowtide" : "Lowtide · \(page.space.title)")
        }
        if key.hasPrefix("lowtide.action:"), let action = ActionRegistry.all.first(where: { $0.id == String(key.dropFirst(12)) }) {
            return (action.title, "Lowtide")
        }
        if key.hasPrefix("lowtide.ssh:") {
            let id = String(key.dropFirst(9))
            return (CommandBarHooks.hosts().first { $0.id == id }?.name ?? "A removed host", "SSH")
        }
        if key.hasPrefix("ext."), let ext = BarSource(rawValue: String(key.dropFirst(4))).flatMap(BarExtension.of) {
            return (ext.name, "Extension")
        }
        if key.hasPrefix("app.bundle."),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: String(key.dropFirst(11))) {
            return (FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""), "App")
        }
        if key.hasPrefix("app.") { return (URL(fileURLWithPath: String(key.dropFirst(4))).deletingPathExtension().lastPathComponent, "App") }
        if key.hasPrefix("emoji.") { return (String(key.dropFirst(6)), "Emoji") }
        if key.hasPrefix("folder.") { return (URL(fileURLWithPath: String(key.dropFirst(7))).lastPathComponent, "Folder") }
        if key.hasPrefix("link."), let link = BarSettings.shared.prefs.links.first(where: { "link.\($0.id)" == key }) {
            return (link.name, "Your shortcut")
        }
        guard let dot = key.firstIndex(of: ".") else { return (key, "") }
        return (String(key[key.index(after: dot)...]), String(key[..<dot]))
    }
}

/// One bar extension: on or off, what it does, and its own settings.
private struct BarExtensionSheet: View {
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @Bindable private var settings = BarSettings.shared
    let ext: BarExtension

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack(spacing: Space.md) {
                Image(systemName: ext.symbol).font(.system(size: 18)).foregroundStyle(palette.ink2.color)
                    .frame(width: 40, height: 40).background(palette.fill.color, in: .rect(cornerRadius: Radius.md))
                VStack(alignment: .leading, spacing: 2) {
                    Text(ext.name).font(.title(.lg)).foregroundStyle(palette.ink.color)
                    Text(ext.description).font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                }
            }
            VStack(spacing: 0) {
                SettingRow("In the bar") {
                    if ext.alwaysOn {
                        Text("Always on").font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                    } else {
                        Toggle("\(ext.name) in the bar", isOn: Binding(get: { settings.prefs.isOn(ext.id) }, set: { _ in settings.prefs.toggle(ext.id) }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                }
            }
            .card()
            switch ext.id {
            case .files: FilesSettings()
            case .links: LinksSettings()
            case .emoji: EmojiSettings()
            case .colors: ColorSettings()
            default: EmptyView()
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.primary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.xl)
        .frame(width: 560)
        .background(palette.overlay.color)
    }
}

/// Strings, each with a remove button, and a field to add one.
private struct ListEditor: View {
    @Environment(\.palette) private var palette
    let items: [String]
    let placeholder: String
    var choose: (() -> Void)?
    let add: (String) -> Void
    let remove: (String) -> Void
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            ForEach(items, id: \.self) { item in
                HStack {
                    Text(item).font(.mono(.xs)).foregroundStyle(palette.ink2.color).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    IconButton("xmark", help: "Remove \(item)") { remove(item) }
                }
                .frame(height: 28)
            }
            HStack(spacing: Space.sm) {
                TextField(placeholder, text: $draft).textFieldStyle(.roundedBorder).onSubmit(submit)
                if let choose { Button("Choose…", action: choose).buttonStyle(.secondary) }
                Button("Add", action: submit).buttonStyle(.secondary).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func submit() {
        let value = draft.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        add(value)
        draft = ""
    }
}

private struct FilesSettings: View {
    @Environment(\.palette) private var palette
    @Bindable private var settings = BarSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Search in").font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color)
                if settings.prefs.fileScopes.isEmpty {
                    Text("No folders yet, so no files").font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                }
                ListEditor(items: settings.prefs.fileScopes.map(Paths.tilde), placeholder: "~/Documents", choose: chooseFolder) { folder in
                    if !settings.prefs.fileScopes.contains(folder) { settings.prefs.fileScopes.append(folder) }
                } remove: { shown in
                    settings.prefs.fileScopes.removeAll { Paths.tilde($0) == shown }
                }
            }
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Skip").font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color)
                Text("node_modules, .git, Pods and build folders are always skipped").font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                ListEditor(items: settings.prefs.fileIgnores, placeholder: "*.log") { pattern in
                    if !settings.prefs.fileIgnores.contains(pattern) { settings.prefs.fileIgnores.append(pattern) }
                } remove: { pattern in settings.prefs.fileIgnores.removeAll { $0 == pattern } }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Search In"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !settings.prefs.fileScopes.contains(url.path) { settings.prefs.fileScopes.append(url.path) }
    }
}

private struct LinksSettings: View {
    @Environment(\.palette) private var palette
    @Bindable private var settings = BarSettings.shared
    @State private var kind = BarLink.Kind.link
    @State private var name = ""
    @State private var destination = ""
    @State private var alone = false

    static let maxLinks = 60

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            ForEach(settings.prefs.links) { link in
                HStack(spacing: Space.md) {
                    Text(link.name).font(.ui(.sm)).foregroundStyle(palette.ink.color).frame(width: 96, alignment: .leading).lineLimit(1)
                    Text(link.destination).font(.mono(.xs)).foregroundStyle(palette.ink3.color).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    IconButton("xmark", help: "Remove \(link.name)") { settings.prefs.links.removeAll { $0.id == link.id } }
                }
                .frame(height: 30)
            }
            Hairline()
            HStack(spacing: Space.sm) {
                Picker("Kind", selection: $kind) {
                    Text("Link").tag(BarLink.Kind.link)
                    Text("Folder or file").tag(BarLink.Kind.place)
                    Text("Script").tag(BarLink.Kind.script)
                }
                .labelsHidden()
                .frame(width: 140)
                TextField("Name, like gh", text: $name).textFieldStyle(.roundedBorder)
            }
            TextField(kind == .script ? "/path/to/executable" : kind == .place ? "~/Documents/Notes" : "github.com/search?q={query}",
                      text: $destination)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                if kind == .script { Toggle("Runs with nothing typed after it", isOn: $alone).toggleStyle(.checkbox).font(.ui(.xs)) }
                Spacer()
                Button("Add Shortcut", action: save).buttonStyle(.secondary)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || destination.trimmingCharacters(in: .whitespaces).isEmpty
                        || settings.prefs.links.count >= Self.maxLinks)
            }
            Text("{query} is what you type after the name; {date} is today.").font(.ui(.xs)).foregroundStyle(palette.ink3.color)
        }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces), d = destination.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !d.isEmpty, settings.prefs.links.count < Self.maxLinks else { return }
        settings.prefs.links.append(BarLink(kind: kind, name: n, destination: d, runsWithoutArgument: kind == .script && alone))
        name = ""
        destination = ""
    }
}

private struct EmojiSettings: View {
    @Bindable private var settings = BarSettings.shared

    var body: some View {
        SettingRow("Skin tone") {
            Segmented($settings.prefs.skinTone, SkinTone.allCases.map { ($0, "👋" + ($0.modifier ?? "")) })
        }
        .card()
    }
}

private struct ColorSettings: View {
    @Environment(\.palette) private var palette
    @Bindable private var settings = BarSettings.shared

    var body: some View {
        SettingRow("Recent colors", hint: "\(settings.prefs.colors.count) picked") {
            Button("Clear") { settings.prefs.colors = [] }.buttonStyle(.lowtide(.quiet, size: .small)).disabled(settings.prefs.colors.isEmpty)
        }
        .card()
    }
}

/// The names you gave rows, and the rows you hid, each to take back.
private struct RememberedSheet: View {
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @Bindable private var settings = BarSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text("Names and hidden rows").font(.title(.lg)).foregroundStyle(palette.ink.color)
            group("Names you gave", settings.prefs.aliases.sorted { $0.value < $1.value }.map { key, alias in
                (key, "“\(alias)” → \(PinNames.describe(key).0)")
            }) { settings.prefs.setAlias($0, "") }
            group("Never shown", settings.prefs.hidden.map { ($0, PinNames.describe($0).0) }) { settings.prefs.toggleHidden($0) }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.primary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.xl)
        .frame(width: 520)
        .background(palette.overlay.color)
    }

    private func group(_ title: String, _ items: [(String, String)], remove: @escaping (String) -> Void) -> some View {
        Pane(title) {
            if items.isEmpty {
                Text("None").font(.ui(.xs)).foregroundStyle(palette.ink3.color).padding([.horizontal, .bottom], Space.lg)
            } else {
                VStack(spacing: 0) {
                    ForEach(items, id: \.0) { key, label in
                        HStack {
                            Text(label).font(.ui(.sm)).foregroundStyle(palette.ink2.color).lineLimit(1)
                            Spacer()
                            IconButton("xmark", help: "Take back") { remove(key) }
                        }
                        .padding(.horizontal, Space.lg)
                        .frame(height: 32)
                    }
                }
                .padding(.bottom, Space.xs)
            }
        }
    }
}
