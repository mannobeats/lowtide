import AppKit
import LowtideKit
import SwiftUI

/// Everything setup shows about this Mac, read here and now.
@Observable
final class MacReading {
    var chip: String?
    var cores: Int?
    var memoryTotal = ProcessInfo.processInfo.physicalMemory
    var memoryUsed: UInt64?
    /// nil while reading; (0, 0) when it couldn't be read.
    var storage: (available: Int64, total: Int64)?
    var apps: [LaunchableApp]?
    /// Apps with a connection open right now; -1 when unreadable.
    var online: Int?
    var tools: [String] = []
    var took: TimeInterval?
    private let started = Date()
    private var running = false

    var settled: Bool { chip != nil && storage != nil && apps != nil && online != nil }

    func start() {
        guard !running else { return }
        running = true
        chip = Self.sysctl("machdep.cpu.brand_string") ?? "Mac"
        cores = ProcessInfo.processInfo.processorCount
        Task {
            let facts = await MacFacts.read()
            memoryUsed = facts.memoryUsed
            storage = (facts.storageAvailable, facts.storageTotal)
            settle()
        }
        Task {
            apps = await AppIndex.shared.list()
            settle()
        }
        Task {
            online = await Self.appsOnline()
            settle()
        }
        Task.detached {
            let found = ["brew", "npm", "pnpm", "yarn", "bun", "cargo", "pip3", "uv", "gem", "go", "composer", "mise"]
                .filter(Shell.isAvailable)
            await MainActor.run { self.tools = found }
        }
    }

    private func settle() {
        if settled, took == nil { took = Date().timeIntervalSince(started) }
    }

    static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Regular apps with an internet connection open (`lsof -i`).
    static func appsOnline() async -> Int {
        guard let out = try? await Shell.run("/usr/sbin/lsof", ["-nP", "-i", "-F", "p"], timeout: .seconds(8)), out.ok else { return -1 }
        let pids = Set(out.stdout.split(separator: "\n").compactMap { $0.hasPrefix("p") ? Int32($0.dropFirst()) : nil })
        return await MainActor.run { RunningApps.list().filter { pids.contains($0.pid) }.count }
    }
}

/// The tile's own small switch: the whole tile is the control, this only
/// shows its state (in the brand colour whether or not the window is key).
private struct TileSwitch: View {
    @Environment(\.palette) private var palette
    let on: Bool

    var body: some View {
        Capsule()
            .fill((on ? palette.brand : palette.selected).color)
            .frame(width: 28, height: 16)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle().fill((on ? palette.onBrand : palette.ink3).color).frame(width: 12, height: 12).padding(2)
            }
            .animation(Motion.spring, value: on)
            .accessibilityHidden(true)
    }
}

/// A step's title and its line.
private struct StepTitle: View {
    @Environment(\.palette) private var palette
    let title: String
    let line: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(title).font(.title(.xl)).foregroundStyle(palette.ink.color)
            Text(line).font(.ui(.sm)).foregroundStyle(palette.ink3.color).frame(maxWidth: 560, alignment: .leading)
        }
    }
}

/// Tiles arrive one after another, once, as the step opens.
private struct Rise: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let index: Int
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 12)
            .onAppear { withAnimation(.easeOut(duration: 0.5).delay(0.08 + Double(index) * 0.045)) { shown = true } }
    }
}

extension View {
    fileprivate func rise(_ index: Int) -> some View { modifier(Rise(index: index)) }
}

/// A choice card, ringed in the brand when chosen.
private struct ChoiceCard: ViewModifier {
    @Environment(\.palette) private var palette
    let on: Bool

    func body(content: Content) -> some View {
        content
            .background((on ? palette.brandSoft : palette.surface).color, in: .rect(cornerRadius: Radius.lg))
            .overlay(RoundedRectangle(cornerRadius: Radius.lg).strokeBorder((on ? palette.brand : palette.line).color, lineWidth: on ? 2 : 1))
            .animation(Motion.fast, value: on)
    }
}

/// The first screen: this Mac described in one sentence, each fact landing
/// as it's read. Nothing here is a timer pretending to read.
struct WelcomeStep: View {
    @Environment(\.palette) private var palette
    let reading: MacReading

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            Spacer(minLength: 40)
            sentence
                .font(.system(size: 36, weight: .medium))
                .tracking(-0.4)
                .foregroundStyle(palette.ink3.color)
                .frame(maxWidth: 760, alignment: .leading)
                .animation(.easeOut(duration: 0.5), value: reading.settled)
                .contentTransition(.numericText())
            Text(reading.took.map { "Read on this Mac in \(Self.duration($0)). Nothing was sent anywhere." } ?? " ")
                .font(.ui(.sm)).foregroundStyle(palette.ink3.color)
                .opacity(reading.took == nil ? 0 : 1)
                .animation(.easeOut(duration: 0.6).delay(0.3), value: reading.took != nil)
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        seconds < 1 ? "\(max(1, Int(seconds * 1000))) milliseconds" : String(format: "%.1f seconds", seconds)
    }

    /// Facts in ink, the words around them quieter.
    private var sentence: Text {
        guard let chip = reading.chip else { return Text("Reading this Mac") }
        var out = AttributedString()
        func plain(_ s: String) { out += AttributedString(s) }
        // A value never breaks across lines: its unit stays with it.
        func fact(_ s: String) {
            var run = AttributedString(s.replacingOccurrences(of: " ", with: "\u{00a0}"))
            run.foregroundColor = palette.ink.color
            out += run
        }
        plain("This Mac runs \(chip.first.map { "AEIOU".contains($0) } == true ? "an" : "a") ")
        fact(chip)
        plain(" with ")
        fact("\(reading.cores ?? 0)")
        plain(" cores and ")
        // Memory the way macOS counts it (binary GB): "32 GB", not 34.4.
        let gib = 1_073_741_824.0
        fact("\(Int((Double(reading.memoryTotal) / gib).rounded())) GB")
        plain(" of memory")
        if let used = reading.memoryUsed {
            plain(", ")
            fact(String(format: "%.1f GB", Double(used) / gib))
            plain(" of it in use. ")
        } else {
            plain(". ")
        }
        if let storage = reading.storage, storage.total > 0 {
            fact(LowtideKitFormat.bytes(storage.available))
            plain(" of its ")
            fact(LowtideKitFormat.bytes(storage.total))
            plain(" disk is free, ")
        }
        if let apps = reading.apps {
            fact("\(apps.count)")
            plain(" apps are installed")
            if let online = reading.online, online >= 0 {
                plain(" and ")
                fact("\(online)")
                plain(online == 1 ? " is online right now." : " are online right now.")
            } else if reading.online != nil {
                plain(".")
            }
        }
        return Text(out)
    }
}

struct UsesStep: View {
    @Environment(\.palette) private var palette
    let progress: SetupProgress

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            StepTitle(title: "What do you use this Mac for?",
                      line: "Pick any that fit. They decide what's switched on to start with; you can change all of it later.")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.md), GridItem(.flexible(), spacing: Space.md)], spacing: Space.md) {
                ForEach(Array(Profile.all.enumerated()), id: \.element.id) { index, profile in
                    let on = progress.picked.contains(profile.id)
                    Button { progress.pick(profile.id) } label: {
                        HStack(alignment: .top, spacing: Space.lg) {
                            NavIcon(profile.glyph, filled: on, size: 20).foregroundStyle((on ? palette.brand : palette.ink3).color)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(profile.label).font(.ui(.base)).foregroundStyle(palette.ink.color)
                                Text(profile.line).font(.ui(.sm)).foregroundStyle(palette.ink2.color)
                                Text(profile.features.compactMap { id in Feature.all.first { $0.id == id }?.label }.joined(separator: "   "))
                                    .font(.ui(.xs)).foregroundStyle(palette.ink3.color).padding(.top, Space.sm)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.brand.color)
                                .opacity(on ? 1 : 0)
                        }
                        .padding(Space.xl)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .modifier(ChoiceCard(on: on))
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .rise(index)
                }
            }
            .frame(maxWidth: 760)
        }
    }
}

struct FeaturesStep: View {
    @Environment(\.palette) private var palette
    let progress: SetupProgress
    let reading: MacReading

    var body: some View {
        let chosen = progress.effective
        let count = Feature.all.filter { chosen[$0.id] == true }.count
        VStack(alignment: .leading, spacing: Space.xl) {
            StepTitle(title: "Choose what Lowtide does",
                      line: "\(count) of \(Feature.all.count) on. Each space you switch on joins the sidebar; extensions live in the menu bar and everywhere.")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.md), count: 4), spacing: Space.md) {
                ForEach(Array(Feature.all.enumerated()), id: \.element.id) { index, feature in
                    let on = chosen[feature.id] == true
                    Button { progress.toggle(feature) } label: {
                        VStack(alignment: .leading, spacing: Space.sm) {
                            HStack(alignment: .top, spacing: 10) {
                                NavIcon(feature.glyph, filled: on, size: 16).foregroundStyle((on ? palette.brand : palette.ink3).color)
                                Text(feature.label).font(.ui(.sm)).foregroundStyle((on ? palette.ink : palette.ink2).color)
                                Spacer(minLength: 0)
                                TileSwitch(on: on)
                            }
                            Text(feature.blurb).font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: Space.md)
                            preview(feature).font(.ui(.xs)).foregroundStyle((on ? palette.ink2 : palette.ink3).color)
                        }
                        .padding(Space.lg)
                        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .modifier(ChoiceCard(on: on))
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .rise(index)
                }
            }
        }
    }

    /// What each feature adds, shown with this Mac's own numbers.
    @ViewBuilder private func preview(_ feature: Feature) -> some View {
        switch feature.kind {
        case .space(.apps):
            if let apps = reading.apps {
                HStack(spacing: 3) {
                    ForEach(apps.prefix(6), id: \.path) { FileIcon(path: $0.path, size: 18) }
                    Text("+\(max(0, apps.count - 6))").monospacedDigit().padding(.leading, 2)
                }
            } else {
                Text("Every app on this Mac")
            }
        case .space(.cleanup):
            if let storage = reading.storage, storage.total > 0 {
                VStack(alignment: .leading, spacing: 5) {
                    Meter(value: Double(storage.total - storage.available) / Double(storage.total), tone: .neutral, height: 4)
                    Text("\(LowtideKitFormat.bytes(storage.available)) free of \(LowtideKitFormat.bytes(storage.total))").monospacedDigit()
                }
            } else {
                Text("Your disk, folder by folder")
            }
        case .space(.protection): Text("Who can use your camera, mic and files")
        case .space(.network):
            if let online = reading.online, online >= 0 { Text("\(online) \(online == 1 ? "app" : "apps") online now").monospacedDigit() } else {
                Text("Every app’s connections")
            }
        case .space(.system):
            Text(reading.memoryUsed.map { "\(LowtideKitFormat.bytes($0)) of memory in use" } ?? reading.chip ?? "…").monospacedDigit()
        case .space(.developer):
            Text(reading.tools.isEmpty ? "Terminal, SSH and your toolchain" : "\(reading.tools.prefix(3).joined(separator: ", ")) found")
        case .extension(.commandbar):
            HStack(spacing: 3) {
                ForEach(Array(BarSettings.shared.prefs.hotkey.glyphs.enumerated()), id: \.offset) { KeyCap(keys: $0.element) }
                Text("from any app").padding(.leading, 2)
            }
        case .extension(.widgets):
            Text(reading.memoryUsed.map { "CPU · \(LowtideKitFormat.bytes($0)) · network" } ?? "CPU · memory · network").font(.mono(.xxs))
        case .extension(.menubar): Text("Hidden icons a click away")
        case .extension(.dictation): Text("Hold a key, speak, it’s typed")
        default: EmptyView()
        }
    }
}

/// The themes, picked here and kept in Settings › Appearance.
struct LookStep: View {
    @Environment(\.palette) private var palette
    @Bindable private var themes = ThemeStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            StepTitle(title: "Pick a look", line: "Automatic follows your Mac: Situation in dark mode, Paper in light. Switch any time in Settings.")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Space.md)], alignment: .leading, spacing: Space.md) {
                swatch(ThemeStore.automatic, "Automatic", palettes: [Palette.fallback], index: 0)
                ForEach(Array(themes.themes.enumerated()), id: \.element.id) { index, theme in
                    swatch(theme.id, theme.name, palettes: Palette(theme).map { [$0] } ?? [], index: index + 1)
                }
            }
            .frame(maxWidth: 820)
        }
    }

    private func swatch(_ id: String, _ name: String, palettes: [Palette], index: Int) -> some View {
        let selected = themes.choice == id
        let p = palettes.first ?? palette
        return Button { withAnimation(Motion.base) { themes.choice = id } } label: {
            VStack(alignment: .leading, spacing: Space.sm) {
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: Radius.md).fill(p.bg.color)
                    VStack(alignment: .leading, spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(p.ink.color).frame(width: 56, height: 6)
                        RoundedRectangle(cornerRadius: 2).fill(p.ink3.color).frame(width: 36, height: 5)
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 2).fill(p.brand.color).frame(width: 28, height: 8)
                            RoundedRectangle(cornerRadius: 2).fill(p.surface.color).frame(width: 18, height: 8)
                        }
                    }
                    .padding(10)
                }
                .frame(height: 72)
                HStack(spacing: 5) {
                    Text(name).font(.ui(.xs)).foregroundStyle((selected ? palette.ink : palette.ink3).color)
                    if selected { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(palette.brand.color) }
                }
                .padding(.horizontal, 2)
            }
            .padding(6)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .modifier(ChoiceCard(on: selected))
        .rise(index)
    }
}

/// The bar's shortcut, set and tried here, so it works the moment setup ends.
struct BarStep: View {
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            StepTitle(title: "Your command bar",
                      line: "One shortcut opens it over any app: apps, files, settings, quick answers, and questions about this Mac.")
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: Space.xl) {
                    Text("Shortcut").font(.ui(.sm)).foregroundStyle(palette.ink.color).frame(width: 112, alignment: .leading).padding(.top, 5)
                    ShortcutSetup(alignment: .leading)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, Space.lg)
                .hairline(.top)
                .rise(0)
                HStack(spacing: Space.xl) {
                    Text("Try it").font(.ui(.sm)).foregroundStyle(palette.ink.color).frame(width: 112, alignment: .leading)
                    Button("Open the Bar") {
                        if !ExtensionState.isOn(.commandbar) { CommandBarPanel.shared.start() }
                        CommandBarPanel.shared.show()
                    }
                    .buttonStyle(.secondary)
                    HStack(spacing: 4) {
                        Text("or press")
                        ForEach(Array(BarSettings.shared.prefs.hotkey.glyphs.enumerated()), id: \.offset) { KeyCap(keys: $0.element) }
                        Text("in any app")
                    }
                    .font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, Space.lg)
                .hairline(.top)
                .rise(1)
            }
            .frame(maxWidth: 760)
        }
        .onAppear {
            // The shortcut works while setup runs, so it can be tried.
            CommandBarPanel.shared.start()
        }
    }
}

struct AllowStep: View {
    let needed: [(Access, [String])]
    let watch: AccessWatch

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            StepTitle(title: "Allow what your choices need",
                      line: "Allow them once, here, and macOS won’t stop you later to ask. Nothing leaves this Mac.")
            VStack(spacing: 0) {
                ForEach(Array(needed.enumerated()), id: \.element.0) { index, item in
                    if index > 0 { Hairline() }
                    AccessRow(access: item.0, by: item.1, allowed: watch.isAllowed(item.0)).rise(index)
                }
            }
            .frame(maxWidth: 760)
        }
        .onAppear { watch.start(needed.map(\.0)) }
        .onDisappear { watch.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in watch.refresh() }
    }
}

struct ReadyStep: View {
    @Environment(\.palette) private var palette
    let on: [Feature]
    @State private var openAtLogin = LoginItem.isOn
    @State private var problem: String?

    var body: some View {
        let spaces = on.filter { if case .space = $0.kind { true } else { false } }
        VStack(alignment: .leading, spacing: Space.xl) {
            StepTitle(title: "Ready to watch this Mac",
                      line: "Home and \(spaces.count) \(spaces.count == 1 ? "space" : "spaces") in your sidebar. Run setup again from ⌘K any time.")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.xxl), GridItem(.flexible(), spacing: Space.xxl)], spacing: 0) {
                ForEach(Array(on.enumerated()), id: \.element.id) { index, feature in
                    HStack(alignment: .top, spacing: Space.md) {
                        NavIcon(feature.glyph, size: 16).foregroundStyle(palette.brand.color).padding(.top, 1)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(feature.label).font(.ui(.sm)).foregroundStyle(palette.ink.color)
                            Text(feature.blurb).font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, Space.md)
                    .hairline(.top)
                    .rise(index)
                }
            }
            .frame(maxWidth: 760)
            HStack(spacing: Space.lg) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open at login").font(.ui(.base)).foregroundStyle(palette.ink.color)
                    Text(LoginItem.needsApproval ? "Waiting for your approval in Login Items."
                        : "Starts in the menu bar, window closed, and keeps watching.")
                        .font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                    if let problem { Text(problem).font(.ui(.xs)).foregroundStyle(palette.bad.color) }
                }
                Spacer()
                if LoginItem.needsApproval {
                    Button("Login Items") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                    }
                    .buttonStyle(.secondary)
                }
                Toggle("Open at login", isOn: $openAtLogin).labelsHidden().toggleStyle(.switch)
                    .onChange(of: openAtLogin) { _, on in
                        do { try LoginItem.set(on) } catch {
                            problem = error.localizedDescription
                            openAtLogin = LoginItem.isOn
                        }
                    }
            }
            .padding(.top, Space.lg)
            .hairline(.top)
            .frame(maxWidth: 760)
        }
    }
}
