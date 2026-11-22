import AppKit
import LowtideKit
import SwiftUI

/// The command bar's shortcut: a recorder, and ⌘Space taken from
/// Spotlight (or given back). On the Command bar page and in onboarding.
struct ShortcutSetup<Trailing: View>: View {
    @Environment(\.palette) private var palette
    @ViewBuilder var trailing: Trailing
    /// Trailing on a settings row, leading in setup.
    var alignment: HorizontalAlignment = .trailing
    private var settings = BarSettings.shared
    private var panel = CommandBarPanel.shared
    @State private var offering = false
    @State private var problem: String?

    init(alignment: HorizontalAlignment = .trailing, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.alignment = alignment
        self.trailing = trailing()
    }

    private var hotkey: Hotkey { settings.prefs.hotkey }
    private var taken: Bool { hotkey == .commandSpace }

    var body: some View {
        VStack(alignment: alignment, spacing: 6) {
            HStack(spacing: Space.sm) {
                ShortcutRecorder(hotkey: hotkey, disabled: panel.changingSpotlight) { choose($0) } onProblem: { problem = $0 }
                if hotkey != .defaultBar {
                    Button("Reset") { choose(.defaultBar) }
                        .buttonStyle(.lowtide(.quiet, size: .small))
                        .disabled(panel.changingSpotlight)
                        .help("Back to \(Hotkey.defaultBar.label)")
                }
                trailing
            }
            spotlightLine
            if let status = problem ?? panel.hotkeyProblem {
                Text(status).font(.ui(.xs)).foregroundStyle(palette.bad.color)
            } else if let note = panel.spotlightNote {
                Text(note).font(.ui(.xs)).foregroundStyle(palette.ink3.color)
            }
        }
        .task { await panel.readSpotlight() }
    }

    @ViewBuilder private var spotlightLine: some View {
        if let spotlight = panel.spotlight {
            HStack(spacing: Space.xs) {
                if spotlight.enabled, taken || offering {
                    Text(taken ? "Spotlight also answers ⌘Space" : "Take ⌘Space from Spotlight? You can give it back here.")
                    action("Replace Spotlight", strong: true) { take() }
                    if !taken { action("Cancel") { offering = false } }
                } else if spotlight.enabled {
                    Text("⌘Space opens Spotlight")
                    action("Use ⌘Space") { offering = true }
                } else if taken {
                    Text("⌘Space opens Lowtide, not Spotlight")
                    action("Give It Back") { giveBack(.defaultBar) }
                } else {
                    Text("Spotlight doesn’t use ⌘Space")
                    action("Use ⌘Space") { take() }
                }
            }
            .font(.ui(.xs))
            .foregroundStyle(palette.ink3.color)
        }
    }

    private func action(_ title: String, strong: Bool = false, _ run: @escaping () -> Void) -> some View {
        Button(title, action: run)
            .buttonStyle(.lowtide(strong ? .secondary : .quiet, size: .small))
            .disabled(panel.changingSpotlight)
    }

    private func choose(_ next: Hotkey) {
        problem = nil
        guard next != hotkey else { return }
        if next == .commandSpace {
            take()
        } else if taken, panel.spotlight?.enabled == false {
            giveBack(next)
        } else {
            settings.prefs.hotkey = next
        }
    }

    private func take() {
        Task {
            do {
                try await panel.takeSpotlight()
                offering = false
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func giveBack(_ next: Hotkey) {
        Task {
            do { try await panel.giveBackSpotlight(next: next) } catch { problem = error.localizedDescription }
        }
    }
}

/// Click, press the keys, done. Esc keeps what it was. Records before the
/// app sees the keys, so they don't also run what they're bound to.
struct ShortcutRecorder: View {
    @Environment(\.palette) private var palette
    let hotkey: Hotkey
    var disabled = false
    let onChange: (Hotkey) -> Void
    var onProblem: (String?) -> Void = { _ in }
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            HStack(spacing: 3) {
                if recording {
                    Text("Press keys…").font(.ui(.sm)).foregroundStyle(palette.ink3.color)
                } else {
                    ForEach(Array(hotkey.glyphs.enumerated()), id: \.offset) { KeyCap(keys: $0.element) }
                }
            }
            .padding(.horizontal, Space.sm)
            .frame(minWidth: 96, minHeight: 28)
            .background(palette.fill.color, in: .rect(cornerRadius: Radius.md))
            .overlay(RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder((recording ? palette.brand : palette.line).color, lineWidth: recording ? 1.5 : 1))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help("Click, then press the shortcut you want · Esc cancels")
        .accessibilityLabel("Shortcut \(hotkey.label)")
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        onProblem(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let code = event.keyCode, flags = event.modifierFlags
            // Local monitors run on the main thread.
            MainActor.assumeIsolated { record(code, flags) }
            return nil
        }
    }

    private func record(_ code: UInt16, _ flags: NSEvent.ModifierFlags) {
        if Int(code) == 53 { // Escape
            stop()
            return
        }
        guard let next = Hotkey(keyCode: code, flags: flags) else { return }
        if let problem = next.problem {
            onProblem(problem)
            return
        }
        stop()
        onChange(next)
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
