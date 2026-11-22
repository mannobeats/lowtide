import AppKit
import LowtideKit
import SwiftUI

/// First launch: this Mac in one sentence, what it's used for, which spaces
/// and extensions to switch on, the look, the command bar's shortcut, what
/// macOS must allow, and ready. Drawn over the main window, edge to edge
/// (its rail previews the rail being chosen), never as a second window.
/// Shown once; Run setup again (⌘K, the Extensions actions) shows it later.
enum OnboardingWindow {
    static let doneKey = "onboarded"

    /// Shows setup on the first launch only. The app delegate calls this at launch.
    static func showIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: doneKey) || ProcessInfo.processInfo.arguments.contains("--onboarding") else { return }
        guard !ProcessInfo.processInfo.arguments.contains("--selftest") else { return }
        show()
    }

    static func show() {
        // After launch has finished: setting this while SwiftUI was still
        // building the scene kept the main window from being created.
        Task { @MainActor in
            // Wait for the main window (up to 5 s), then cover it.
            for _ in 0..<50 where !NSApp.windows.contains(where: { $0.identifier?.rawValue == "main" }) {
                try? await Task.sleep(for: .milliseconds(100))
            }
            withAnimation(Motion.base) { AppModel.shared.onboarding = true }
            WindowRouter.showMain()
        }
    }

    static func close() {
        if SetupProgress.preview == nil { UserDefaults.standard.set(true, forKey: doneKey) }
        withAnimation(Motion.base) { AppModel.shared.onboarding = false }
    }
}

/// Setup over the whole main window, on the window's own material.
struct OnboardingLayer: View {
    private var themes = ThemeStore.shared

    var body: some View {
        OnboardingView(done: OnboardingWindow.close)
            .environment(\.spaceHue, SpaceID.home.hue)
            .background {
                ZStack {
                    VisualEffectBackground()
                    themes.palette.panel.opacity(0.62).color
                }
                .ignoresSafeArea()
            }
            .transition(.opacity)
    }
}

/// Setup's steps, in order. Some are skipped: the command bar's when it's
/// off, Allow when nothing chosen needs anything.
enum SetupStep: String, CaseIterable {
    case mac, uses, features, look, bar, allow, ready

    var label: String {
        switch self {
        case .mac: "Your Mac"
        case .uses: "Uses"
        case .features: "Features"
        case .look: "Look"
        case .bar: "Command bar"
        case .allow: "Allow"
        case .ready: "Ready"
        }
    }
}

/// What the person uses the Mac for, and what that switches on.
struct Profile: Identifiable {
    let id: String
    let label: String
    let line: String
    let glyph: String
    let features: [String]

    static let all = [
        Profile(id: "everyday", label: "Everyday", line: "Browsing, mail, photos and documents", glyph: "home",
                features: ["space.apps", "space.cleanup", "space.system", "extension.commandbar"]),
        Profile(id: "creative", label: "Creative work", line: "Big files, heavy apps, long exports", glyph: "appearance",
                features: ["space.apps", "space.cleanup", "space.system", "extension.widgets", "extension.commandbar"]),
        Profile(id: "code", label: "Writing code", line: "Terminals, toolchains and servers", glyph: "developer",
                features: ["space.developer", "space.system", "space.network", "space.apps", "extension.commandbar"]),
        Profile(id: "privacy", label: "Privacy first", line: "Who connects, and who can see what", glyph: "protection",
                features: ["space.protection", "space.network"]),
    ]
}

/// Setup so far, saved as it goes: quitting, or macOS relaunching the app
/// for a permission, resumes on the same step.
@Observable
final class SetupProgress {
    var at: SetupStep { didSet { save(at.rawValue, "onboarding.step") } }
    var picked: [String] { didSet { save(picked, "onboarding.picked") } }
    /// Nothing is chosen until the person says what the Mac is for.
    var chosen: [String: Bool]? { didSet { save(chosen, "onboarding.chosen") } }

    /// `--onboarding <step>` (snapshots) opens on a step and saves nothing.
    static let preview: SetupStep? = {
        let args = ProcessInfo.processInfo.arguments
        guard let at = args.firstIndex(of: "--onboarding") else { return nil }
        return args.indices.contains(at + 1) ? SetupStep(rawValue: args[at + 1]) ?? .mac : .mac
    }()

    private func save(_ value: Any?, _ key: String) {
        guard Self.preview == nil else { return }
        UserDefaults.standard.set(value, forKey: key)
    }

    init() {
        if let preview = Self.preview {
            at = preview
            picked = []
            chosen = nil
            pick("code")
            return
        }
        at = UserDefaults.standard.string(forKey: "onboarding.step").flatMap(SetupStep.init) ?? .mac
        picked = UserDefaults.standard.stringArray(forKey: "onboarding.picked") ?? []
        chosen = UserDefaults.standard.dictionary(forKey: "onboarding.chosen") as? [String: Bool]
    }

    static var defaults: [String: Bool] { Dictionary(uniqueKeysWithValues: Feature.all.map { ($0.id, $0.defaultOn) }) }

    var effective: [String: Bool] { chosen ?? Self.defaults }
    var on: [Feature] { Feature.all.filter { effective[$0.id] == true } }

    func pick(_ id: String) {
        picked = picked.contains(id) ? picked.filter { $0 != id } : picked + [id]
        let features = Set(Profile.all.filter { picked.contains($0.id) }.flatMap(\.features))
        chosen = picked.isEmpty ? nil : Dictionary(uniqueKeysWithValues: Feature.all.map { ($0.id, features.contains($0.id)) })
    }

    func toggle(_ feature: Feature) {
        var next = effective
        next[feature.id] = !(next[feature.id] ?? false)
        chosen = next
    }

    func clear() {
        guard Self.preview == nil else { return }
        for key in ["onboarding.step", "onboarding.picked", "onboarding.chosen"] { UserDefaults.standard.removeObject(forKey: key) }
    }
}

struct OnboardingView: View {
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress = SetupProgress()
    @State private var reading = MacReading()
    @State private var resumed = false
    @State private var forward = true
    @State private var allowed = AccessWatch()
    let done: () -> Void

    private var steps: [SetupStep] {
        let needed = Feature.needed(progress.on)
        return SetupStep.allCases.filter { step in
            switch step {
            case .bar: progress.effective["extension.commandbar"] == true
            case .allow: !needed.isEmpty
            default: true
            }
        }
    }

    private var index: Int { steps.firstIndex(of: progress.at) ?? 0 }

    var body: some View {
        HStack(spacing: 0) {
            SetupRail(on: progress.on)
            VStack(spacing: 0) {
                header
                ZStack {
                    stepBody
                        .id(progress.at)
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .opacity.combined(with: .offset(x: forward ? 24 : -24)),
                            removal: .opacity.combined(with: .offset(x: forward ? -16 : 16))))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
                footer
            }
            .background(palette.bg.color, in: .rect(cornerRadius: Radius.sheet))
            .overlay(RoundedRectangle(cornerRadius: Radius.sheet).strokeBorder(palette.line.color))
            .padding(8)
        }
        .background(VisualEffectBackground().ignoresSafeArea())
        .background(StepKeys(next: next, back: back))
        .onAppear {
            resumed = progress.at != .mac && SetupProgress.preview == nil
            if !steps.contains(progress.at) { progress.at = .mac }
            reading.start()
        }
    }

    private var header: some View {
        HStack(spacing: Space.xl) {
            ForEach(Array(steps.enumerated()), id: \.element) { i, step in
                Button(step.label) { go(i) }
                    .buttonStyle(.plain)
                    .font(.ui(.xs))
                    .foregroundStyle((i == index ? palette.ink : i < index ? palette.ink3 : palette.ink4).color)
                    .disabled(i > index)
                    .accessibilityAddTraits(i == index ? .isSelected : [])
            }
        }
        .frame(height: 48)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var stepBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if resumed {
                    Text("Welcome back. Setup picks up where you left off.").font(.ui(.sm)).foregroundStyle(palette.ink3.color)
                        .padding(.bottom, Space.xl)
                }
                switch progress.at {
                case .mac: WelcomeStep(reading: reading)
                case .uses: UsesStep(progress: progress)
                case .features: FeaturesStep(progress: progress, reading: reading)
                case .look: LookStep()
                case .bar: BarStep()
                case .allow: AllowStep(needed: Feature.needed(progress.on), watch: allowed)
                case .ready: ReadyStep(on: progress.on)
                }
            }
            .padding(.horizontal, 64)
            .padding(.top, Space.page)
            .padding(.bottom, Space.xxl)
            .frame(maxWidth: .infinity, minHeight: 520, alignment: progress.at == .mac ? .leading : .topLeading)
        }
        .scrollIndicators(.automatic)
    }

    private var footer: some View {
        let needed = Feature.needed(progress.on)
        let allAllowed = needed.allSatisfy { allowed.isAllowed($0.0) }
        let primary = switch progress.at {
        case .mac: "Set Up Lowtide"
        case .ready: "Open Lowtide"
        case .allow where !allAllowed: "Continue Without"
        default: "Continue"
        }
        return HStack(spacing: Space.sm) {
            if progress.at != .ready {
                Button("Skip Setup") { finish(SetupProgress.defaults) }.buttonStyle(.quiet)
            }
            Spacer()
            if index > 0 { Button("Back", action: back).buttonStyle(.quiet) }
            Button(action: next) {
                HStack(spacing: 6) {
                    Text(primary)
                    Text("⏎").opacity(0.7)
                }
            }
            .buttonStyle(.lowtide(.primary, size: .large))
        }
        .padding(.horizontal, 64)
        .frame(height: 64)
        .hairline(.top)
    }

    private func go(_ to: Int) {
        guard steps.indices.contains(to) else { return }
        if progress.at == .uses, to > index, progress.chosen == nil {
            // Nothing picked: start from the defaults, then switch off below.
            progress.chosen = SetupProgress.defaults
        }
        forward = to > index
        resumed = false
        withAnimation(Motion.slow) { progress.at = steps[to] }
    }

    private func next() {
        if index == steps.count - 1 { finish(progress.effective) } else { go(index + 1) }
    }

    private func back() { go(index - 1) }

    private func finish(_ choice: [String: Bool]) {
        guard SetupProgress.preview == nil else { return done() }
        for feature in Feature.all { feature.set(choice[feature.id] ?? feature.defaultOn) }
        progress.clear()
        AppModel.shared.open(Page.home)
        done()
    }
}

/// ⏎ or → continues, ← goes back. App shortcuts are held back while setup
/// is up; a shortcut recorder or a text field owns its keys.
private struct StepKeys: NSViewRepresentable {
    let next: () -> Void
    let back: () -> Void

    func makeNSView(context: Context) -> KeyView { KeyView() }

    func updateNSView(_ view: KeyView, context: Context) {
        view.next = next
        view.back = back
    }

    final class KeyView: NSView {
        var next: () -> Void = {}
        var back: () -> Void = {}
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let code = Int(event.keyCode)
                let typing = event.window?.firstResponder is NSTextView
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let self, event.window === self.window, !typing,
                          event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
                    switch code {
                    case 36, 76, 124: self.next()
                    case 123: self.back()
                    default: return false
                    }
                    return true
                }
                return handled ? nil : event
            }
        }

        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            super.removeFromSuperview()
        }
    }
}

/// The app's rail as it will be: Home, then each space as it's chosen.
private struct SetupRail: View {
    @Environment(\.palette) private var palette
    let on: [Feature]

    var body: some View {
        let spaces = SpaceID.allCases.filter { space in
            space == .home || space == .extensions || on.contains { $0.kind == .space(space) }
        }
        VStack(spacing: 4) {
            Color.clear.frame(height: 40)
            Logo(size: 28).padding(.bottom, Space.md)
            ForEach(spaces, id: \.self) { space in
                VStack(spacing: 2) {
                    NavIcon(space.glyph, filled: space == .home, size: 20)
                        .foregroundStyle((space == .home ? palette.ink : palette.ink3).color)
                        .frame(width: 44, height: 28)
                        .background((space == .home ? palette.selected : ColorValue(r: 0, g: 0, b: 0, a: 0)).color,
                                    in: .rect(cornerRadius: Radius.md))
                    Text(space.title).font(.system(size: 10)).foregroundStyle(palette.ink3.color)
                }
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            Spacer()
            NavIcon("settings", size: 20).foregroundStyle(palette.ink3.color).padding(.bottom, Space.md)
        }
        .frame(width: 72)
        .animation(Motion.spring, value: spaces)
        .accessibilityHidden(true)
    }
}
