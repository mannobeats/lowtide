import LowtideKit
import SwiftUI

/// One model: what it is, and download, use or remove.
struct ModelRow: View {
    @Environment(\.palette) private var palette
    @Bindable private var dictation = Dictation.shared
    @State private var hovering = false
    let model: VoiceModelInfo
    @Binding var confirm: ConfirmRequest?

    init(model: VoiceModelInfo, confirm: Binding<ConfirmRequest?>) {
        self.model = model
        _confirm = confirm
    }

    var body: some View {
        let status = dictation.status
        let installed = dictation.installed.contains(model.id)
        let selected = dictation.prefs.model == model.id
        let download = status.download
        let fetching = download?.model == model.id && download?.error == nil
        let busy = download != nil && download?.error == nil
        let failed = download?.model == model.id ? download?.error : nil
        HStack(spacing: Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    Text(model.name).font(.ui(.sm, selected ? .medium : .regular)).foregroundStyle(palette.ink.color)
                    Text(LowtideFormat.bytes(model.bytes)).font(.ui(.xxs)).foregroundStyle(palette.ink3.color).monospacedDigit()
                    if selected && installed {
                        Image(systemName: "checkmark").font(.ui(.xxs, .bold)).foregroundStyle(palette.brand.color)
                            .accessibilityLabel("In use")
                    }
                }
                Text("\(model.languages). \(model.note)").font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                    .fixedSize(horizontal: false, vertical: true)
                if let state = stateLine(selected: selected, installed: installed) {
                    Text(state).font(.ui(.xs)).foregroundStyle(palette.brand.color).padding(.top, 2)
                }
                if let failed, !failed.isEmpty {
                    Text(failed).font(.ui(.xs)).foregroundStyle(palette.bad.color).padding(.top, 2)
                }
                if fetching, let download {
                    HStack(spacing: Space.sm) {
                        Meter(value: download.progress)
                        Text(LowtideFormat.percent(download.progress)).font(.ui(.xxs)).monospacedDigit()
                            .foregroundStyle(palette.ink3.color).frame(width: 36, alignment: .trailing)
                    }
                    .padding(.top, Space.xs)
                }
            }
            Spacer(minLength: Space.sm)
            if installed {
                IconButton("trash", help: "Move \(model.name) to the Trash") { askRemove() }
            } else if fetching {
                Button("Cancel") { dictation.cancelDownload() }.buttonStyle(.lowtide(.quiet, size: .small))
            } else {
                Button {
                    dictation.download(model.id)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.lowtide(.secondary, size: .small))
                .disabled(busy)
                .help(busy ? "One download at a time" : "Download \(LowtideFormat.bytes(model.bytes)) from Hugging Face")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background((selected ? palette.selectedBrand : hovering && installed ? palette.hover : ColorValue(r: 0, g: 0, b: 0, a: 0)).color,
                    in: .rect(cornerRadius: Radius.md))
        .contentShape(.rect(cornerRadius: Radius.md))
        .onHover { hovering = $0 }
        .onTapGesture { if installed { dictation.prefs.model = model.id } }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            if installed {
                Button("Use \(model.name)") { dictation.prefs.model = model.id }.disabled(selected)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([VoicePaths.folder(model.id)]) }
                Divider()
                Button("Move to Trash…") { askRemove() }
            } else if !fetching {
                Button("Download \(LowtideFormat.bytes(model.bytes))") { dictation.download(model.id) }.disabled(busy)
            } else {
                Button("Cancel Download") { dictation.cancelDownload() }
            }
        }
        .animation(Motion.fast, value: hovering)
        .animation(Motion.base, value: fetching)
    }

    /// Why the chosen model isn't ready yet, or that it is.
    private func stateLine(selected: Bool, installed: Bool) -> String? {
        guard selected, installed, dictation.enabled else { return nil }
        let status = dictation.status
        guard status.modelID.isEmpty || status.modelID == model.id else { return nil }
        if (status.modelState == .error || status.modelState == .loading), !status.modelMessage.isEmpty {
            return status.modelMessage
        }
        return status.modelState.title
    }

    private func askRemove() {
        confirm = ConfirmRequest(
            title: "Remove \(model.name)?",
            message: "\(model.name) (\(LowtideFormat.bytes(model.bytes))) goes to the Trash. You can put it back from there, or download it again any time.",
            confirm: "Move to Trash") { [id = model.id] in Dictation.shared.remove(id) }
    }
}

/// Words to expect and words to swap, edited in a sheet.
struct WordsSheet: View {
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @Binding var prefs: VoicePrefs
    @State private var words = ""
    @State private var pairs: [Replacement] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            Text("Words").font(.title(.lg))
            VStack(alignment: .leading, spacing: 6) {
                Text("Words to expect").font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color)
                Text("Names, products and jargon, separated by commas. Qwen listens for them; every model gets the spelling right through replacements.")
                    .font(.ui(.xs)).foregroundStyle(palette.ink3.color).fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $words)
                    .font(.ui(.sm))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 76)
                    .background(palette.fill.color, in: .rect(cornerRadius: Radius.md))
                    .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(palette.lineStrong.color))
                    .overlay(alignment: .topLeading) {
                        if words.isEmpty {
                            Text("Lowtide, Kubernetes, Anaïs").font(.ui(.sm)).foregroundStyle(palette.ink4.color)
                                .padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false)
                        }
                    }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Replacements").font(.ui(.sm, .medium)).foregroundStyle(palette.ink.color)
                Text("When you say the first, the second is typed.").font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach($pairs.indices, id: \.self) { index in
                            HStack(spacing: Space.sm) {
                                TextField("lowtide", text: $pairs[index].spoken).textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("Spoken")
                                Text("becomes").font(.ui(.xs)).foregroundStyle(palette.ink4.color)
                                TextField("Lowtide", text: $pairs[index].typed).textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("Typed")
                                IconButton("xmark", help: "Remove this replacement") { pairs.remove(at: index) }
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: pairs.count < 6)
                Button {
                    pairs.append(Replacement(spoken: "", typed: ""))
                } label: {
                    Label("Add a Replacement", systemImage: "plus")
                }
                .buttonStyle(.lowtide(.quiet, size: .small))
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.secondary)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.primary)
            }
        }
        .padding(Space.xl)
        .frame(width: 520)
        .onAppear {
            words = prefs.vocabulary.joined(separator: ", ")
            pairs = prefs.replacements
        }
    }

    private func save() {
        prefs.vocabulary = words.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        prefs.replacements = pairs
            .map { Replacement(spoken: $0.spoken.trimmingCharacters(in: .whitespaces), typed: $0.typed.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.spoken.isEmpty }
        dismiss()
    }
}

/// History: whether it's kept, for how long, from which apps, and what was.
struct DictationHistorySection: View {
    @Environment(\.palette) private var palette
    @Bindable private var dictation = Dictation.shared
    @Binding var confirm: ConfirmRequest?

    static let keep: [(Int, String)] = [(1, "1 day"), (7, "7 days"), (30, "30 days"), (90, "90 days"), (0, "Until cleared")]

    var body: some View {
        let kept = dictation.history.count
        PrefsGroup("History") {
            if dictation.prefs.history && kept > 0 {
                Button("Clear History…") {
                    confirm = ConfirmRequest(title: "Clear dictation history?", message: "Every dictation kept on this Mac is forgotten.",
                                             confirm: "Clear History") { Dictation.shared.forget(nil) }
                }
                .buttonStyle(.lowtide(.quiet, size: .small))
            }
        } content: {
            PrefsRow("Paste last dictation", hint: "Into the app you were in before Lowtide") {
                Button("Paste Last") { dictation.pasteLast() }
                    .buttonStyle(.lowtide(.secondary, size: .small))
                    .disabled(dictation.last == nil)
            }
            PrefsRow("Keep history", hint: "Kept on this Mac only") {
                PrefsSwitch("Keep history", isOn: Binding(get: { dictation.prefs.history }, set: { on in
                    if on || kept == 0 {
                        dictation.prefs.history = on
                    } else {
                        confirm = ConfirmRequest(
                            title: "Stop keeping history?",
                            message: "\(LowtideFormat.count(kept, "dictation")) kept on this Mac \(kept == 1 ? "is" : "are") forgotten, and new ones aren't kept. Stats keep counting.",
                            confirm: "Stop and Clear") { Dictation.shared.stopHistory() }
                    }
                }))
            }
            if dictation.prefs.history {
                PrefsRow("Keep for", hint: "Older dictations are forgotten on their own") {
                    Picker("Keep for", selection: $dictation.prefs.keepDays) {
                        ForEach(Self.keep, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                PrefsRow("Never kept from", hint: "Dictated into these, nothing is kept. Leave one out from its entry below", block: true) {
                    if !dictation.prefs.excluded.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(dictation.prefs.excluded) { app in LeftOutChip(app: app) }
                        }
                    }
                }
                HistoryList()
            }
        }
    }
}

/// An app left out of history, with a way to let it back in.
private struct LeftOutChip: View {
    @Environment(\.palette) private var palette
    let app: LeftOutApp

    var body: some View {
        HStack(spacing: 2) {
            Text(app.name).font(.ui(.xs)).foregroundStyle(palette.ink2.color).padding(.leading, Space.sm)
            Button {
                Dictation.shared.prefs.excluded.removeAll { $0.bundleId == app.bundleId }
            } label: {
                Image(systemName: "xmark").font(.ui(.xxs, .semibold)).foregroundStyle(palette.ink3.color).frame(width: 18, height: 18)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Keep dictations from \(app.name)")
            .accessibilityLabel("Keep dictations from \(app.name)")
        }
        .padding(.trailing, 2)
        .frame(height: 24)
        .background(palette.fill.color, in: .rect(cornerRadius: Radius.sm))
        .help(app.bundleId)
    }
}

/// What was dictated, newest first, on this Mac only.
private struct HistoryList: View {
    @Environment(\.palette) private var palette
    private var dictation = Dictation.shared
    @State private var selected: Int64?

    var body: some View {
        if !dictation.historyLoaded {
            HStack(spacing: Space.sm) {
                ProgressView().controlSize(.small)
                Text("Reading history…").font(.ui(.xs)).foregroundStyle(palette.ink3.color)
            }
            .padding(.vertical, Space.md)
        } else if dictation.history.isEmpty {
            Text("Nothing yet. Hold \(dictation.prefs.shortcutLabel) and speak in any app.")
                .font(.ui(.xs)).foregroundStyle(palette.ink3.color).padding(.vertical, Space.md)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(dictation.history) { entry in
                        HistoryRow(entry: entry, selected: selected == entry.id) { selected = entry.id }
                    }
                }
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: dictation.history.count < 5)
            .padding(.vertical, Space.xs)
            .onDeleteCommand { if let selected { Dictation.shared.forget(selected) } }
            .onCopyCommand {
                guard let entry = dictation.history.first(where: { $0.id == selected }) else { return [] }
                return [NSItemProvider(object: entry.text as NSString)]
            }
        }
    }
}

private struct HistoryRow: View {
    @Environment(\.palette) private var palette
    @State private var hovering = false
    let entry: DictationEntry
    let selected: Bool
    let select: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.text)
                    .font(.ui(.sm))
                    .foregroundStyle(palette.ink2.color)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(meta).font(.ui(.xxs)).foregroundStyle(palette.ink3.color).monospacedDigit()
            }
            HStack(spacing: 0) {
                IconButton("doc.on.doc", help: "Copy") { copy() }
                if !entry.bundleId.isEmpty {
                    IconButton("eye.slash", help: "Never keep from \(entry.app.isEmpty ? entry.bundleId : entry.app)") {
                        Dictation.shared.leaveOut(entry)
                    }
                }
                IconButton("xmark", help: "Forget") { Dictation.shared.forget(entry.id) }
            }
            .opacity(hovering || selected ? 1 : 0)
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.sm)
        .background((selected ? palette.selected : hovering ? palette.hover : ColorValue(r: 0, g: 0, b: 0, a: 0)).color,
                    in: .rect(cornerRadius: Radius.md))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(perform: select)
        .contextMenu {
            Button("Copy") { copy() }
            if !entry.bundleId.isEmpty {
                Button("Never Keep from \(entry.app.isEmpty ? entry.bundleId : entry.app)") { Dictation.shared.leaveOut(entry) }
            }
            Divider()
            Button("Forget") { Dictation.shared.forget(entry.id) }
        }
        .animation(Motion.fast, value: hovering)
    }

    private var meta: String {
        let when = entry.date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        let app = entry.app.isEmpty ? "" : " · \(entry.app)"
        return "\(when)\(app) · \(String(format: "%.1f", entry.seconds)) s in \(entry.elapsedMs) ms"
    }

    private func copy() {
        Files.copy(entry.text)
    }
}
