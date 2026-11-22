import LowtideKit
import SwiftUI

/// Extensions › Dictation: how it listens, which model hears you, the words
/// to expect, history with its privacy controls, and the stats.
struct DictationPage: View {
    @Environment(\.palette) private var palette
    @Bindable private var dictation = Dictation.shared
    /// Bumped when the app comes back: permissions change in System Settings.
    @State private var tick = 0
    @State private var editingWords = false
    @State private var confirm: ConfirmRequest?

    static let about = "Hold a shortcut, speak, and your words are typed into whatever app you're in. Speech is recognised on this Mac by Parakeet or Phonon-2 on the Neural Engine, or Qwen3-ASR on the GPU, with a live preview while you talk."
    static let facts = ["Microphone and Accessibility", "Downloads a model, 0.35 to 2 GB"]

    var body: some View {
        PageScaffold(maxWidth: 820) {
            hero
        } content: {
            if dictation.enabled {
                settings
            } else {
                PrefsAbout(about: Self.about, facts: Self.facts)
            }
        }
        .confirmation($confirm)
        .sheet(isPresented: $editingWords) { WordsSheet(prefs: $dictation.prefs) }
        .onAppear {
            dictation.refreshStatus()
            dictation.loadDevices()
            Task {
                await dictation.refreshHistory()
                await dictation.refreshStats()
            }
        }
        .onDisappear { if dictation.recordingShortcut { dictation.recordShortcut(false) } }
        .onAppActivate {
            tick += 1
            dictation.refreshStatus()
        }
    }

    // MARK: Hero

    private var micAllowed: Bool { _ = tick; return Permission.microphone.state == .granted }
    private var tapAllowed: Bool { _ = tick; return dictation.status.shortcutAccess ?? (Permission.accessibility.state == .granted) }
    private var model: VoiceModelInfo? { VoiceModelInfo.named(dictation.prefs.model) }

    private var hero: some View {
        let s = heroState
        return PageHero(s.title, detail: s.detail, art: "dictation") {
            if let action = s.action {
                Button(action.0, action: action.1).buttonStyle(.primary)
            }
            if dictation.enabled {
                Button("Turn Off") { dictation.setEnabled(false) }
                    .buttonStyle(.quiet)
                    .help("Stops listening. Your settings, models and history stay for next time.")
            }
        }
    }

    /// One sentence that answers "can I dictate now?", and the one thing to do.
    private var heroState: (title: String, detail: String, action: (String, () -> Void)?) {
        let status = dictation.status
        let name = model?.name ?? "a model"
        guard dictation.enabled else {
            return ("Speak, and it's typed. On this Mac", "Nothing you say leaves it; models download once, then work offline.",
                    ("Turn On Dictation", { dictation.setEnabled(true) }))
        }
        if !status.available {
            return ("This copy of Lowtide has no dictation", "Its speech helper is missing. Install Lowtide again to bring it back.", nil)
        }
        if !micAllowed {
            return ("Allow the microphone to start", "Dictation listens only while you hold the shortcut.",
                    ("Allow Microphone", { Permission.microphone.request() }))
        }
        if !tapAllowed {
            return ("Allow Accessibility to dictate into apps", "It hears the shortcut everywhere and types where you are.",
                    ("Allow Accessibility", { Permission.accessibility.request() }))
        }
        if let download = status.download, download.error == nil {
            let named = VoiceModelInfo.named(download.model)?.name ?? download.model
            return ("Downloading \(named), \(Int((download.progress * 100).rounded()))%",
                    "It's used offline from then on.", nil)
        }
        if !dictation.installed.contains(dictation.prefs.model) {
            return ("Download a speech model to start", "\(name) suits most people: \(model?.languages ?? "") in \(LowtideFormat.bytes(model?.bytes ?? 0)).",
                    ("Download \(name)", { dictation.download(dictation.prefs.model) }))
        }
        if let holder = status.blockedBy, !dictation.prefs.shortcut.modifiersOnly {
            return ("\(holder) is blocking the shortcut", "macOS hides key presses while an app holds Secure Input.", nil)
        }
        switch status.modelState {
        case .loading:
            return ("Getting \(name) ready", status.modelMessage.isEmpty ? "A few seconds; you can already speak." : status.modelMessage, nil)
        case .error:
            return ("\(name) couldn't load", status.modelMessage, nil)
        default:
            let verb = dictation.prefs.mode == .toggle ? "Tap" : "Hold"
            return ("\(verb) \(dictation.prefs.shortcutLabel) and speak in any app", "Nothing you say leaves this Mac.", nil)
        }
    }

    // MARK: Settings

    @ViewBuilder private var settings: some View {
        let status = dictation.status
        if let holder = status.blockedBy { secureInputNotice(holder) }
        PrefsGroup {
            PrefsRow("Permissions", hint: micAllowed && tapAllowed
                     ? "Nothing you say leaves this Mac"
                     : "The microphone to hear you; Accessibility for the shortcut and to type into apps") {
                if micAllowed && tapAllowed {
                    PrefsAllowed()
                } else {
                    if !micAllowed {
                        Button("Allow Microphone") { Permission.microphone.request() }.buttonStyle(.lowtide(.secondary, size: .small))
                    }
                    if !tapAllowed {
                        Button("Allow Accessibility") { Permission.accessibility.request() }.buttonStyle(.lowtide(.secondary, size: .small))
                    }
                }
            }
        }
        shortcutGroup
        microphoneGroup
        speechGroup
        textGroup
        PrefsGroup("While you speak") {
            PrefsRow("Show words as you speak", hint: "Above the pill, two lines at most") {
                PrefsSwitch("Show words as you speak", isOn: $dictation.prefs.preview)
            }
            PrefsRow("Sounds", hint: "A soft chime when it starts listening") {
                PrefsSwitch("Sounds", isOn: $dictation.prefs.sounds)
            }
        }
        DictationHistorySection(confirm: $confirm)
        PrefsGroup("Diagnostics") {
            PrefsRow("Diagnostics", hint: "What dictation did and how long it took, never what you said") {
                Button("Reveal Log") { dictation.revealLog() }.buttonStyle(.lowtide(.secondary, size: .small))
                Button("Copy Report") { dictation.copyReport() }.buttonStyle(.lowtide(.secondary, size: .small))
            }
        }
        DictationStatsSection(confirm: $confirm)
    }

    private func secureInputNotice(_ holder: String) -> some View {
        let shortcut = dictation.prefs.shortcut
        return PrefsNotice("\(holder) is holding Secure Input",
                           message: shortcut.modifiersOnly
                           ? "macOS hides key presses from shortcuts while it does, but \(dictation.prefs.shortcutLabel) is a modifier alone, so dictation still hears it."
                           : "macOS hides key presses from every shortcut while it does, this one included. Clicking out of its password field usually ends it; quitting \(holder) always does. A modifier alone keeps working through it.") {
            if !shortcut.modifiersOnly {
                Button("Use Right ⌥ Instead") {
                    dictation.prefs.shortcut = .rightOption
                    dictation.prefs.shortcutLabel = VoiceShortcut.rightOptionLabel
                }
                .buttonStyle(.lowtide(.secondary, size: .small))
            }
        }
    }

    private var shortcutGroup: some View {
        let recording = dictation.recordingShortcut
        // macOS acts on the Globe key too unless it's set to Do Nothing.
        let globeClash = dictation.prefs.shortcut.usesFn && dictation.status.shortcutAccess != nil && dictation.status.fnUsage != 0
        return PrefsGroup("Shortcut") {
            PrefsRow("Shortcut", hint: recording
                     ? "Press a key with ⌘, ⌥, ⌃ or fn, a function key, a modifier alone (like Right ⌥ or fn), or a mouse button. Esc cancels"
                     : "Works in every app. Esc cancels while you speak") {
                if recording {
                    RecordingLabel()
                    Button("Cancel") { dictation.recordShortcut(false) }.buttonStyle(.lowtide(.quiet, size: .small))
                } else {
                    KeyCap(keys: dictation.prefs.shortcutLabel)
                    Button("Change") { dictation.recordShortcut(true) }
                        .buttonStyle(.lowtide(.secondary, size: .small))
                        .disabled(!dictation.status.running)
                        .help(dictation.status.running ? "Record a new shortcut" : "Dictation is starting")
                }
            }
            if globeClash {
                PrefsNotice("macOS also acts on the 🌐 key",
                            message: "In System Settings › Keyboard, set “Press 🌐 key to” to Do Nothing, or it opens the emoji picker over your words.",
                            inset: true) {
                    Button("Open Keyboard Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                    }
                    .buttonStyle(.lowtide(.secondary, size: .small))
                }
            }
            PrefsRow("Listen while", hint: dictation.prefs.mode.hint) {
                Segmented($dictation.prefs.mode, DictationMode.allCases.map { ($0, $0.title) })
            }
        }
    }

    private var microphoneGroup: some View {
        PrefsGroup("Microphone") {
            PrefsRow("Microphone") {
                Picker("Microphone", selection: $dictation.prefs.microphone) {
                    Text("System default").tag(String?.none)
                    if !dictation.devices.isEmpty { Divider() }
                    ForEach(dictation.devices) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                    // A saved microphone that isn't plugged in keeps its place.
                    if let picked = dictation.prefs.microphone, !dictation.devices.contains(where: { $0.uid == picked }) {
                        Text("Not connected").tag(String?.some(picked))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            if dictation.prefs.microphone == nil {
                PrefsRow("Avoid Bluetooth microphone",
                         hint: "Uses this Mac's own when a headset is the default: clearer, and it starts at once") {
                    PrefsSwitch("Avoid Bluetooth microphone", isOn: $dictation.prefs.avoidBluetooth)
                }
            }
            PrefsRow("Keep microphone ready", hint: dictation.prefs.keepReady
                     ? "Your first word is never cut off. macOS shows its orange dot; only the last second is held, in memory"
                     : "Opens on the shortcut, so the first moment can be lost") {
                PrefsSwitch("Keep microphone ready", isOn: $dictation.prefs.keepReady)
            }
        }
    }

    private var speechGroup: some View {
        PrefsGroup("Speech") {
            PrefsRow("Model", block: true) {
                VStack(spacing: Space.xxs) {
                    ForEach(VoiceModelInfo.all) { model in
                        ModelRow(model: model, confirm: $confirm)
                    }
                }
                Text("Downloaded from Hugging Face when you ask, then used offline. Parakeet and Phonon run on the Neural Engine, Qwen on the GPU.")
                    .font(.ui(.xxs))
                    .foregroundStyle(palette.ink4.color)
            }
            PrefsRow("Language", hint: "Detect works for most; pick one when you only ever speak it") {
                Picker("Language", selection: $dictation.prefs.language) {
                    ForEach(Self.languages, id: \.0) { code, name in
                        Text(name).tag(code)
                        if code == "auto" { Divider() }
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    private var textGroup: some View {
        let prefs = dictation.prefs
        let polish = dictation.status.polishAvailable
        return PrefsGroup("Text") {
            PrefsRow("Words", hint: prefs.vocabulary.count + prefs.replacements.count > 0
                     ? "\(prefs.vocabulary.count) to expect, \(prefs.replacements.count) replaced"
                     : "Names and jargon, and how to spell them") {
                Button("Edit…") { editingWords = true }.buttonStyle(.lowtide(.secondary, size: .small))
            }
            PrefsRow("Remove filler words", hint: "um, uh, euh, hmm") {
                PrefsSwitch("Remove filler words", isOn: $dictation.prefs.fillers)
            }
            PrefsRow("Polish with Apple Intelligence", hint: polish
                     ? "Fixes misheard words and punctuation; adds about a second"
                     : "Needs Apple Intelligence turned on") {
                PrefsSwitch("Polish with Apple Intelligence", isOn: Binding(
                    get: { dictation.prefs.polish && polish }, set: { dictation.prefs.polish = $0 }))
                    .disabled(!polish)
            }
        }
    }

    /// Parakeet's 25 languages and Qwen's most spoken ones.
    static let languages: [(String, String)] = [
        ("auto", "Detect"), ("en", "English"), ("fr", "French"), ("de", "German"), ("es", "Spanish"),
        ("it", "Italian"), ("pt", "Portuguese"), ("nl", "Dutch"), ("pl", "Polish"), ("ru", "Russian"),
        ("uk", "Ukrainian"), ("sv", "Swedish"), ("da", "Danish"), ("fi", "Finnish"), ("el", "Greek"),
        ("zh", "Chinese (Qwen)"), ("ja", "Japanese (Qwen)"), ("ko", "Korean (Qwen)"), ("ar", "Arabic (Qwen)"),
        ("hi", "Hindi (Qwen)"),
    ]
}

/// "Press your shortcut…", breathing while the helper waits for it.
private struct RecordingLabel: View {
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        Text("Press your shortcut…")
            .font(.ui(.xs, .medium))
            .foregroundStyle(palette.brand.color)
            .opacity(dim ? 0.45 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever()) { dim = true }
            }
    }
}
