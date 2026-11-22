import LowtideKit
import SwiftUI

/// The Dictation extension's hooks: the helper runs while the extension is
/// on (`extension.dictation`) and stops at quit; actions, menu commands,
/// lines in the menu bar icon's menu, and self-tests.
enum DictationLifecycle {
    @MainActor private static var observer: NSObjectProtocol?

    static func launch() {
        observer = NotificationCenter.default.addObserver(forName: Dictation.extensionsChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if UserDefaults.standard.bool(forKey: Dictation.enabledKey) != Dictation.shared.enabled { Dictation.shared.sync() }
            }
        }
        StatusMenu.providers.append {
            let dictation = Dictation.shared
            guard dictation.enabled else { return [] }
            let has = dictation.last != nil
            return [
                StatusMenu.Line("Paste Last Dictation", symbol: "doc.on.clipboard", action: has ? { dictation.pasteLast() } : nil),
                StatusMenu.Line("Copy Last Dictation", symbol: "doc.on.doc", action: has ? { dictation.copyLast() } : nil),
            ]
        }
        Dictation.shared.sync()
    }

    static func terminate() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        Dictation.shared.stop()
    }

    static var actions: [AppAction] {
        let dictation = Dictation.shared
        let live = dictation.state.phase == .recording || dictation.state.phase == .listening
        return [
            AppAction(id: "dictation.start", title: live ? "Stop Dictation" : "Start Dictation",
                      subtitle: dictation.enabled ? "Into the app you were in" : "Turn on Dictation first",
                      symbol: "mic", glyph: "dictation", keywords: "voice speak talk transcribe dictate", space: .extensions,
                      // The words go into the app you were in; only turning it on needs the window.
                      opensWindow: !dictation.enabled) {
                dictation.toggle()
            },
            AppAction(id: "dictation.paste-last", title: "Paste Last Dictation", subtitle: "Into the app behind Lowtide",
                      symbol: "doc.on.clipboard", keywords: "voice transcript again repeat", space: .extensions, opensWindow: false) {
                dictation.pasteLast()
            },
            AppAction(id: "dictation.copy-last", title: "Copy Last Dictation", subtitle: "To the clipboard",
                      symbol: "doc.on.doc", keywords: "voice transcript clipboard", space: .extensions, opensWindow: false) {
                if dictation.last == nil {
                    Toasts.shared.show("Nothing has been dictated yet", tone: .warn)
                } else {
                    dictation.copyLast()
                    Toasts.shared.show("Copied the last dictation")
                }
            },
        ]
    }

    static var selfTests: [SelfTest.Step] {
        [
            SelfTest.Step("the dictation helper ships with the bundles it reads") {
                guard let helper = VoicePaths.helper else { return true }
                let folder = helper.deletingLastPathComponent()
                let bundles = ["mlx-swift_Cmlx.bundle", "swift-transformers_Hub.bundle", "FluidAudio_FluidAudio.bundle"]
                guard bundles.allSatisfy({ FileManager.default.fileExists(atPath: folder.appending(path: $0).path) }) else { return false }
                return try await Shell.run(helper.path, ["--self-test"], timeout: .seconds(20)).stdout.contains("ok")
            },
            SelfTest.Step("dictation history keeps its rules") {
                let folder = FileManager.default.temporaryDirectory.appending(path: "lowtide-selftest-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: folder) }
                let history = DictationHistory(url: folder.appending(path: "h.json"))
                let rules = HistoryRules(keepDays: 1, excluded: ["com.apple.Passwords"])
                await history.remember(DictationResult(text: "kept", bundleId: "com.apple.Notes"), rules: rules)
                await history.remember(DictationResult(text: "never", bundleId: "com.apple.Passwords"), rules: rules)
                return await history.load().map(\.text) == ["kept"]
            },
            SelfTest.Step("every overlay error says what happened") {
                ["no-model", "model-loading", "mic", "permission", "secure-input", "no-focus", "helper"].allSatisfy {
                    HUDLabel.of(VoiceState(phase: .error, kind: $0))?.text != "Something went wrong"
                }
            },
        ]
    }
}

struct DictationCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            let dictation = Dictation.shared
            Divider()
            Button("Dictate with Lowtide") { dictation.toggle() }
                .disabled(!dictation.enabled)
            Button("Paste Last Dictation") { dictation.pasteLast() }
                .disabled(!dictation.enabled || dictation.last == nil)
            Button("Copy Last Dictation") { dictation.copyLast() }
                .disabled(dictation.last == nil)
        }
    }
}
