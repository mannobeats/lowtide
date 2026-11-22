import LowtideKit
import SwiftUI

/// Audio plug-ins as products (one Serum, whatever its formats), and the
/// selected one's every format, preset, content library and receipt.
struct AudioPluginsView: View {
    @Environment(\.palette) private var palette
    private var model = AddonsModel.shared
    @State private var query = ""
    @State private var format = "all"
    @State private var sort: Sort = .size
    @State private var selectedID: String?
    @State private var checks = Checks<String>()
    @State private var confirm: ConfirmRequest?

    enum Sort: String, CaseIterable {
        case size, vendor, name
        var label: String {
            switch self {
            case .size: "Largest"
            case .vendor: "Vendor"
            case .name: "Name"
            }
        }
    }

    private var visible: [PluginProduct] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return model.plugins
            .filter { format == "all" || $0.formats.contains { $0.format == format } }
            .filter { needle.isEmpty || "\($0.name) \($0.vendor ?? "")".lowercased().contains(needle) }
            .sorted {
                switch sort {
                case .name: $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                case .vendor: ($0.vendor ?? "~", $0.name) < ($1.vendor ?? "~", $1.name)
                case .size: ($0.bytes ?? -1) > ($1.bytes ?? -1)
                }
            }
    }

    var body: some View {
        let visible = visible
        let order = visible.map(\.id)
        SplitList(
            query: $query, searchPrompt: "Search plug-ins or vendors",
            selectAll: visible.isEmpty ? nil : (checks.state(of: order),
                                                "\(visible.count) shown · \(LowtideFormat.bytes(visible.compactMap(\.bytes).reduce(0, +)))",
                                                { checks.set(order, on: checks.state(of: order) != .on) })
        ) {
            HStack(spacing: Space.sm) {
                Picker("Format", selection: $format) {
                    Text("All formats (\(model.plugins.count))").tag("all")
                    ForEach(PluginProduct.formatOrder, id: \.self) { name in
                        let count = model.plugins.filter { $0.formats.contains { $0.format == name } }.count
                        if count > 0 { Text("\(name) (\(count))").tag(name) }
                    }
                }
                .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                Picker("Sort", selection: $sort) { ForEach(Sort.allCases, id: \.self) { Text($0.label).tag($0) } }
                    .labelsHidden().frame(width: 112)
            }
            .controlSize(.small)
        } list: {
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visible) { plugin in row(plugin, order: order) }
                    }
                    .padding(.vertical, Space.xs)
                    .padding(.bottom, checks.isEmpty ? 0 : 56)
                }
                .overlay {
                    if !model.pluginsScanned {
                        ScanningState(title: "Looking through the plug-in folders")
                    } else if visible.isEmpty {
                        EmptyState(model.plugins.isEmpty ? "No audio plug-ins" : "No matching plug-ins", symbol: "waveform",
                                   message: model.plugins.isEmpty ? "Nothing in the AU, VST, VST3, CLAP, AAX or LV2 folders." : "Try another name or vendor.")
                    }
                }
                if !checks.isEmpty {
                    SelectionBar(count: checks.count, noun: "plug-in",
                                 status: model.bulk?.text ?? LowtideFormat.bytes(model.plugins.filter { checks.has($0.id) }.compactMap(\.bytes).reduce(0, +)),
                                 progress: model.bulk?.fraction, working: model.bulk != nil, clear: { checks.clear() }) {
                        Button("Remove") { ask(Array(checks.ids)) }.buttonStyle(.lowtide(.destructive, size: .small)).disabled(model.bulk != nil)
                    }
                    .padding(Space.sm)
                }
            }
            .animation(Motion.base, value: checks.isEmpty)
            .onDeleteCommand { if let id = selectedID { ask(checks.targets(id)) } }
        } detail: {
            if let plugin = model.plugins.first(where: { $0.id == selectedID }) {
                FootprintMap(
                    model: FootprintModel(
                        locate: { [all = model.plugins] in await Footprint.locate(AudioPlugins.subject(plugin, all: all)) },
                        remove: { paths, progress in
                            await AppRemover.remove(AppRemover.Request(name: plugin.name, paths: paths), progress: progress)
                        }),
                    subject: "\(plugin.name) and its files",
                    onRemoved: { result, bytes in
                        AppsReport.finish(result, bytes: bytes) { InstalledAppsModel.shared.scan() }
                        guard plugin.formats.allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }) else { return }
                        model.forgetPlugins([plugin.id])
                        if selectedID == plugin.id { selectedID = nil }
                    }
                ) {
                    PluginHeader(plugin: plugin)
                }
                .id(plugin.id)
            } else {
                EmptyState("Select a plug-in", symbol: "waveform",
                           message: "Pick a plug-in to map every format, preset, content library and installer file it left, wherever they are.")
            }
        }
        .onChange(of: model.plugins.map(\.id)) { _, ids in
            checks.keep(Set(ids))
            if selectedID == nil, let name = AppsLaunchView.select { selectedID = model.plugins.first { $0.name == name }?.id }
        }
        .confirmation($confirm)
    }

    private func row(_ plugin: PluginProduct, order: [String]) -> some View {
        let targets = checks.targets(plugin.id)
        return SplitRow(checked: checks.has(plugin.id), checkLabel: "Select \(plugin.name)", selected: selectedID == plugin.id,
                            dimmed: model.removing.contains(plugin.id),
                            onCheck: { checks.toggle(plugin.id, in: order) }, onSelect: { selectedID = plugin.id }) {
            VStack(alignment: .leading, spacing: 3) {
                Text(plugin.name).font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color).lineLimit(1)
                HStack(spacing: 6) {
                    Text(plugin.vendor ?? "Unknown vendor").font(.ui(.xxs)).foregroundStyle(palette.ink3.color).lineLimit(1)
                    FormatChips(plugin: plugin).fixedSize().layoutPriority(1)
                }
            }
            Spacer(minLength: Space.xs)
            if let bytes = plugin.bytes {
                Text(LowtideFormat.bytes(bytes)).font(.mono(.xs)).monospacedDigit().foregroundStyle(palette.ink2.color)
            } else {
                Text("…").font(.mono(.xs)).foregroundStyle(palette.ink4.color).help("Measuring")
            }
        }
        .contextMenu {
            ForEach(plugin.formats, id: \.path) { format in
                Button("Show \(format.format) in Finder\(format.user ? " (user)" : "")") {
                    Files.reveal([format.path])
                }
            }
            Button("Copy Name") {
                Files.copy(plugin.name)
            }
            Divider()
            Button(targets.count > 1 ? "Remove \(targets.count) Plug-ins…" : "Remove…", role: .destructive) { ask(targets) }
        }
    }

    private func ask(_ ids: [String]) {
        let plugins = model.plugins.filter { ids.contains($0.id) }
        guard !plugins.isEmpty else { return }
        confirm = ConfirmRequest(
            title: plugins.count == 1 ? "Remove \(plugins[0].name)?" : "Remove \(plugins.count) plug-ins?",
            message: "\(appsNames(plugins.map(\.name))), with \(plugins.count == 1 ? "its" : "their") formats, presets and support files. "
                + "Everything goes to the Trash, so you can restore it until you empty it. Files shared with the vendor’s other products are kept.",
            confirm: "Move to Trash"
        ) {
            model.removePlugins(plugins)
        }
    }
}

/// `AU VST3 AAX`, each in a small outlined chip.
private struct FormatChips: View {
    @Environment(\.palette) private var palette
    let plugin: PluginProduct
    var body: some View {
        HStack(spacing: 3) {
            ForEach(plugin.formatNames, id: \.self) { name in
                Text(name).font(.mono(.xxs)).foregroundStyle(palette.ink3.color)
                    .padding(.horizontal, 4).frame(height: 15)
                    .overlay(RoundedRectangle(cornerRadius: Radius.sm - 2).strokeBorder(palette.line.color))
            }
        }
    }
}

private struct PluginHeader: View {
    @Environment(\.palette) private var palette
    let plugin: PluginProduct
    var body: some View {
        HStack(alignment: .top, spacing: Space.lg) {
            Image(systemName: "waveform").font(.system(size: 22)).foregroundStyle(palette.ink2.color)
                .frame(width: 56, height: 56).background(palette.fill.color, in: .rect(cornerRadius: Radius.lg))
            VStack(alignment: .leading, spacing: 4) {
                Text(plugin.name).font(.title(.lg)).foregroundStyle(palette.ink.color).lineLimit(1).textSelection(.enabled)
                HStack(spacing: 0) {
                    Text(plugin.vendor ?? "Unknown vendor")
                    if let version = plugin.version { Text(" · "); Text(version).font(.mono(.xs)) }
                }
                .font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                FormatChips(plugin: plugin).padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
    }
}
