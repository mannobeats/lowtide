import AppKit
import LowtideKit
import SwiftUI

/// The CommandBar extension's hooks: background work started at launch (only while
/// the extension is on) and stopped at quit, its actions, self-tests and menu commands.
enum CommandBarLifecycle {
    private static var observer: NSObjectProtocol?

    static func launch() {
        if ExtensionState.isOn(.commandbar) { CommandBarPanel.shared.start() }
        observer = NotificationCenter.default.addObserver(forName: ExtensionState.changed, object: nil, queue: .main) { note in
            guard note.userInfo?["id"] as? String == ExtensionState.ID.commandbar.rawValue else { return }
            MainActor.assumeIsolated {
                if ExtensionState.isOn(.commandbar) { CommandBarPanel.shared.start() } else { CommandBarPanel.shared.stop() }
            }
        }
        // `--bar` and `--ask [question]` open it at launch (snapshots).
        let args = ProcessInfo.processInfo.arguments
        if SetupProgress.preview != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { OnboardingWindow.show() } }
        CommandBarPanel.shared.pinned = args.contains("--bar") || args.contains("--ask")
        if let at = args.firstIndex(of: "--ask") {
            let question = args.indices.contains(at + 1) && !args[at + 1].hasPrefix("--") ? args[at + 1] : nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { CommandBarPanel.shared.show(ask: true, question: question) }
        } else if let at = args.firstIndex(of: "--bar") {
            let query = args.indices.contains(at + 1) && !args[at + 1].hasPrefix("--") ? args[at + 1] : nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                CommandBarPanel.shared.show()
                if let query { CommandBarPanel.shared.model.typed(query) }
            }
        }
    }

    static func terminate() async {
        await CommandBarPanel.shared.terminate()
    }

    static var actions: [AppAction] {
        [
            AppAction(id: "commandbar.open", title: "Open the command bar",
                      subtitle: BarSettings.shared.prefs.hotkeyEnabled ? "From any app with \(BarSettings.shared.prefs.hotkey.label)" : nil,
                      symbol: "command", glyph: "command-bar", keywords: "launcher spotlight search anywhere", space: .extensions) {
                CommandBarPanel.shared.show(over: NSApp.keyWindow)
            },
            AppAction(id: "ask", title: "Ask about this Mac", subtitle: "Answered on this Mac by Apple Intelligence",
                      symbol: "sparkles", glyph: "ask", keywords: "question ai assistant apple intelligence") { Ask.open() },
            AppAction(id: "setup", title: "Run setup again", subtitle: "Welcome, spaces, extensions and permissions",
                      symbol: "wand.and.stars", glyph: "setup", keywords: "onboarding welcome features permissions") {
                OnboardingWindow.show()
            },
        ]
    }

    static var selfTests: [SelfTest.Step] {
        [
            SelfTest.Step("the command bar finds a page") {
                let model = CommandBarModel(host: .window)
                model.setQuery("pkts")
                return model.list.rows.first?.id == "lowtide.page:\(Page.packets.rawValue)"
            },
            SelfTest.Step("the command bar calculates") {
                let model = CommandBarModel(host: .window)
                model.setQuery("2+2*3")
                return model.list.rows.first.map { $0.answer && $0.title == "8" } ?? false
            },
            SelfTest.Step("every command bar symbol exists") {
                let model = CommandBarModel(host: .window)
                BarData.shared.facts = MacFacts()
                model.recompute()
                var symbols = BarExtension.catalog.map(\.symbol)
                symbols += BarRows.system(MacFacts(), model).compactMap { if case .symbol(let s, _) = $0.icon { s } else { nil } }
                symbols += BarRows.facts(MacFacts(), watch: nil).compactMap { if case .symbol(let s, _) = $0.icon { s } else { nil } }
                symbols += ["eyedropper", "cup.and.saucer", "cup.and.saucer.fill", "sun.max", "sun.max.fill", "mic", "mic.slash", "headphones",
                            "server.rack", "cpu", "terminal", "link", "folder", "gearshape", "pin", "pin.slash", "pencil", "eye.slash",
                            "clock.arrow.circlepath", "arrow.up", "arrow.down", "xmark.octagon", "arrow.clockwise.circle", "stop",
                            "arrow.up.forward.square", "equal", "calendar", "paintpalette", "face.smiling", "macwindow", "return"]
                return symbols.allSatisfy { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }
            },
            SelfTest.Step("Ask answers from this Mac") {
                await AskTools.run("disk_space", AskArguments()).hasPrefix("Startup disk")
            },
        ]
    }
}

/// Ask: a mode of the command bar, here as its own entry point (the
/// command bar's Ask chip, ⌘J).
enum Ask {
    static func open(_ question: String? = nil) {
        CommandBarPanel.shared.show(ask: true, question: question, over: mainWindow)
    }

    static func toggle() {
        let panel = CommandBarPanel.shared
        if panel.isOpen, panel.model.mode.isAsk { panel.hide() } else { open() }
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == "main" && $0.isVisible }
    }
}

struct CommandBarCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Ask About This Mac…") { Ask.toggle() }
                .keyboardShortcut("j")
            Button("Show Command Bar") { CommandBarPanel.shared.show(over: NSApp.keyWindow) }
            Divider()
        }
    }
}
