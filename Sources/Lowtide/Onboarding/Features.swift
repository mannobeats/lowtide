import LowtideKit
import SwiftUI

/// What Lowtide can do, as the person switches it on: in onboarding and
/// the Extensions gallery. Home is always there.
struct Feature: Identifiable {
    enum Kind: Equatable {
        case space(SpaceID)
        case `extension`(ExtensionState.ID)
    }

    let kind: Kind
    let label: String
    /// What it's for, in a few words.
    let blurb: String
    let glyph: String
    /// The macOS permissions it needs to work fully (see `Access`).
    let needs: [Access]

    var id: String {
        switch kind {
        case .space(let space): "space.\(space.rawValue)"
        case .extension(let ext): "extension.\(ext.rawValue)"
        }
    }

    var isOn: Bool {
        switch kind {
        case .space(let space): SpaceState.isOn(space)
        case .extension(let ext): ExtensionState.isOn(ext)
        }
    }

    func set(_ on: Bool) {
        switch kind {
        case .space(let space): SpaceState.set(space, on)
        case .extension(let ext): ExtensionState.set(ext, on)
        }
    }

    var defaultOn: Bool {
        switch kind {
        case .space: true
        case .extension(let ext): ext.defaultOn
        }
    }

    static let all: [Feature] = [
        // Apps reads ~/Library/Containers and replaces bundles in /Applications.
        Feature(kind: .space(.apps), label: "Apps", blurb: "Update, remove and clean up apps", glyph: "apps",
                needs: [.fullDisk, .appManagement]),
        // Cleanup scans Downloads, Desktop and Documents.
        Feature(kind: .space(.cleanup), label: "Cleanup", blurb: "Free up space and find what fills your disk", glyph: "cleanup",
                needs: [.fullDisk]),
        // Permissions reads TCC.db and lists login items through System Events;
        // canary, exposure and tripwire alerts notify while hidden.
        Feature(kind: .space(.protection), label: "Protection", blurb: "Threats, permissions, exposed secrets and decoys",
                glyph: "protection", needs: [.fullDisk, .automation, .notifications]),
        // Alerts become notifications while the window is closed.
        Feature(kind: .space(.network), label: "Network", blurb: "Every connection, live", glyph: "network", needs: [.notifications]),
        Feature(kind: .space(.system), label: "System", blurb: "Chip, memory, heat and processes", glyph: "system", needs: []),
        // Shells run as Lowtide's children, so their file access is its
        // access; a server going down notifies.
        Feature(kind: .space(.developer), label: "Developer", blurb: "Toolchain, terminal and SSH", glyph: "developer",
                needs: [.fullDisk, .notifications]),
        // Dark mode and restart through System Events, empty Trash and eject through Finder.
        Feature(kind: .extension(.commandbar), label: "Command bar", blurb: "Launch anything from anywhere", glyph: "command-bar",
                needs: [.automation]),
        Feature(kind: .extension(.widgets), label: "Menu bar widgets", blurb: "CPU, memory and network in the menu bar",
                glyph: "widgets", needs: []),
        // Names, opens and moves icons; hiding alone needs nothing.
        Feature(kind: .extension(.menubar), label: "Menu bar manager", blurb: "Hide and arrange menu bar icons, like Bartender",
                glyph: "menubar", needs: [.accessibility]),
        // The microphone, and ⌘V into the app you're in.
        Feature(kind: .extension(.dictation), label: "Dictation", blurb: "Speak, and it's typed. Recognised on this Mac",
                glyph: "dictation", needs: [.microphone, .accessibility]),
    ]

    static func of(_ ext: ExtensionState.ID) -> Feature { all.first { $0.kind == .extension(ext) }! }

    /// Fixed order, so rows don't jump as choices change.
    static let accessOrder: [Access] = [.fullDisk, .notifications, .automation, .appManagement, .accessibility, .microphone]

    /// The permissions these features need, each with who needs it.
    static func needed(_ features: [Feature]) -> [(Access, [String])] {
        accessOrder.compactMap { access in
            let by = features.filter { $0.needs.contains(access) }.map(\.label)
            return by.isEmpty ? nil : (access, by)
        }
    }
}

/// Which spaces show in the rail, chosen in onboarding. Home always shows.
enum SpaceState {
    static let changed = Notification.Name("Lowtide.spacesChanged")

    static func key(_ space: SpaceID) -> String { "space.\(space.rawValue)" }

    static func isOn(_ space: SpaceID) -> Bool {
        space == .home || space == .extensions || (UserDefaults.standard.object(forKey: key(space)) as? Bool ?? true)
    }

    static func set(_ space: SpaceID, _ on: Bool) {
        guard space != .home, space != .extensions, isOn(space) != on else { return }
        UserDefaults.standard.set(on, forKey: key(space))
        NotificationCenter.default.post(name: changed, object: nil, userInfo: ["id": space.rawValue, "on": on])
    }
}

/// What macOS allows right now, polled every second while a screen shows
/// it (the person is off in System Settings flipping switches) and again
/// when Lowtide comes back to the front. Stops once all of `wanted` are allowed.
@Observable
final class AccessWatch {
    private(set) var granted: [Access: Bool?] = [:]
    private var task: Task<Void, Never>?
    private var wanted: [Access] = []

    func start(_ wanted: [Access]) {
        self.wanted = wanted
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let status = await Access.status(self.wanted)
                self.granted = status
                if !self.wanted.isEmpty, self.wanted.allSatisfy({ status[$0] == .some(true) }) { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func refresh() {
        guard !wanted.isEmpty else { return }
        start(wanted)
    }

    func isAllowed(_ access: Access) -> Bool { granted[access] == .some(true) }
}

/// One permission: what it's for, who needs it, and its live state.
struct AccessRow: View {
    @Environment(\.palette) private var palette
    let access: Access
    let by: [String]
    let allowed: Bool
    @State private var asked = false

    var body: some View {
        HStack(alignment: .top, spacing: Space.lg) {
            Image(systemName: access.symbol)
                .font(.system(size: 17))
                .foregroundStyle((allowed ? palette.ok : palette.ink3).color)
                .frame(width: 22)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(access.title).font(.ui(.base)).foregroundStyle(palette.ink.color)
                Text(access.why).font(.ui(.sm)).foregroundStyle(palette.ink2.color).fixedSize(horizontal: false, vertical: true)
                Text(asked && !allowed ? access.hint : "For \(Self.list(by))")
                    .font(.ui(.xs)).foregroundStyle(palette.ink3.color).padding(.top, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.md)
            Group {
                if allowed {
                    Label("Allowed", systemImage: "checkmark").font(.ui(.sm)).foregroundStyle(palette.ok.color)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                } else {
                    Button(asked ? access.retry : "Allow") {
                        asked = true
                        Task { await access.request() }
                    }
                    .buttonStyle(.secondary)
                }
            }
            .frame(minWidth: 112, alignment: .trailing)
        }
        .padding(.vertical, 14)
        .animation(Motion.base, value: allowed)
    }

    /// "Storage", "Storage and Apps", "Storage, Apps and Network".
    static func list(_ items: [String]) -> String {
        items.count < 2 ? items.first ?? "" : items.dropLast().joined(separator: ", ") + " and " + items.last!
    }
}

/// The rows for a set of permissions, live.
struct AccessList: View {
    let needed: [(Access, [String])]
    @State private var watch = AccessWatch()

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(needed.enumerated()), id: \.element.0) { index, item in
                if index > 0 { Hairline() }
                AccessRow(access: item.0, by: item.1, allowed: watch.isAllowed(item.0))
            }
        }
        .onAppear { watch.start(needed.map(\.0)) }
        .onDisappear { watch.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in watch.refresh() }
    }
}

/// Switches an extension on. When it needs permissions that aren't granted
/// yet, a sheet asks for them first, and the extension turns on by itself
/// once they are (or at once with Later).
@Observable
final class ExtensionEnabler {
    var asking: Feature?
    let watch = AccessWatch()

    func enable(_ feature: Feature) {
        guard !feature.needs.isEmpty else {
            feature.set(true)
            return
        }
        Task {
            let status = await Access.status(feature.needs)
            if feature.needs.allSatisfy({ status[$0] == .some(true) }) {
                feature.set(true)
            } else {
                asking = feature
                watch.start(feature.needs)
            }
        }
    }

    func finish() {
        asking?.set(true)
        asking = nil
        watch.stop()
    }
}

struct EnableSheet: View {
    @Environment(\.palette) private var palette
    @Bindable var enabler: ExtensionEnabler

    var body: some View {
        if let feature = enabler.asking {
            let needed = Feature.needed([feature])
            let allowed = needed.allSatisfy { enabler.watch.isAllowed($0.0) }
            VStack(alignment: .leading, spacing: Space.md) {
                Text("Turn on \(feature.label)").font(.title(.lg)).foregroundStyle(palette.ink.color)
                Text("macOS asks once, now, and Lowtide keeps it for next time.").font(.ui(.sm)).foregroundStyle(palette.ink3.color)
                VStack(spacing: 0) {
                    ForEach(Array(needed.enumerated()), id: \.element.0) { index, item in
                        if index > 0 { Hairline() }
                        AccessRow(access: item.0, by: item.1, allowed: enabler.watch.isAllowed(item.0))
                    }
                }
                HStack {
                    Spacer()
                    Button("Later") { enabler.finish() }.buttonStyle(.quiet)
                }
            }
            .padding(Space.xl)
            .frame(width: 560)
            .background(palette.overlay.color)
            .task(id: allowed) {
                // Everything allowed: a beat to see it go green, then on.
                guard allowed else { return }
                try? await Task.sleep(for: .milliseconds(700))
                enabler.finish()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                enabler.watch.refresh()
            }
        }
    }
}

/// Each extension as the gallery shows it.
struct ExtensionEntry: Identifiable {
    let id: ExtensionState.ID
    let page: Page
    /// Its glass object, from the same family as the spaces'.
    let art: String
    let tagline: String
    /// What it does, for the gallery before it's installed.
    let about: String
    /// What it needs and what it downloads.
    let facts: [String]

    var feature: Feature { Feature.of(id) }

    /// The gallery and the sidebar, in order.
    static let catalog: [ExtensionEntry] = [
        ExtensionEntry(id: .dictation, page: .dictation, art: "dictation", tagline: "Speak, and it's typed. On this Mac",
                       about: "Hold a shortcut, speak, and your words are typed into whatever app you're in. Speech is recognised on this Mac, on the Neural Engine or the GPU, with a live preview while you talk.",
                       facts: ["Microphone and Accessibility", "Downloads a model, 0.35 to 2 GB"]),
        ExtensionEntry(id: .menubar, page: .menuBarManager, art: "menubar", tagline: "A tidy menu bar, like Bartender",
                       about: "Hide the menu bar icons you rarely need behind a chevron, open them from a bar underneath, and drag them into the order you want. An optional Island under the notch holds favourites and live stats.",
                       facts: MenuBarManagerPage.facts),
        ExtensionEntry(id: .widgets, page: .widgets, art: "widgets", tagline: "Your Mac's vitals in the menu bar",
                       about: "CPU, GPU, memory, network, disk, battery, temperature and fans as live values, bars, charts or rings next to the clock, with a panel of details a click away.",
                       facts: ["No permissions"]),
        ExtensionEntry(id: .commandbar, page: .commandBar, art: "command-bar", tagline: "Launch anything from anywhere",
                       about: "One shortcut from anywhere opens a bar that launches apps, finds files, runs actions and calculates, with extensions for the tools you use, and answers questions about this Mac on it.",
                       facts: ["System Events and Finder for some actions"]),
    ]

    static func of(_ id: ExtensionState.ID) -> ExtensionEntry { catalog.first { $0.id == id }! }
}

/// Watches the extensions' on/off state for views.
@Observable
final class ExtensionStates {
    static let shared = ExtensionStates()
    private(set) var on: [ExtensionState.ID: Bool] = [:]
    private var observer: NSObjectProtocol?

    private init() {
        read()
        observer = NotificationCenter.default.addObserver(forName: ExtensionState.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }
    }

    private func read() {
        on = Dictionary(uniqueKeysWithValues: ExtensionState.ID.allCases.map { ($0, ExtensionState.isOn($0)) })
    }

    func isOn(_ id: ExtensionState.ID) -> Bool { on[id] ?? id.defaultOn }
}

/// The top of an extension's page: its glass object, name and line,
/// whether it's installed, and Install or Turn off. Until it's installed
/// the page says what it does; after, the page's own settings follow.
struct ExtensionHeader<Content: View>: View {
    @Environment(\.palette) private var palette
    let entry: ExtensionEntry
    @ViewBuilder var content: Content
    @State private var enabler = ExtensionEnabler()
    private var states = ExtensionStates.shared

    init(_ id: ExtensionState.ID, @ViewBuilder content: () -> Content) {
        entry = ExtensionEntry.of(id)
        self.content = content()
    }

    var body: some View {
        let installed = states.isOn(entry.id)
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xxl) {
                HStack(spacing: Space.xl) {
                    HeroArt(entry.art, size: 72)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.feature.label).font(.title(.xl)).foregroundStyle(palette.ink.color)
                        Text(entry.tagline).font(.ui(.sm)).foregroundStyle(palette.ink2.color)
                        Text(installed ? "Installed" : "Not installed").font(.ui(.xs))
                            .foregroundStyle((installed ? palette.ok : palette.ink3).color)
                    }
                    Spacer(minLength: Space.md)
                    if installed {
                        // Its settings are kept for when it's installed again.
                        Button("Turn Off") { entry.feature.set(false) }.buttonStyle(.quiet)
                    } else {
                        Button("Install") { enabler.enable(entry.feature) }.buttonStyle(.primary)
                    }
                }
                if installed {
                    content.transition(.opacity)
                } else {
                    VStack(alignment: .leading, spacing: Space.md) {
                        Text(entry.about).font(.ui(.sm)).foregroundStyle(palette.ink2.color).lineSpacing(3)
                            .frame(maxWidth: 560, alignment: .leading)
                        Text(entry.facts.joined(separator: " · ")).font(.ui(.xs)).foregroundStyle(palette.ink3.color)
                    }
                }
            }
            .padding(.horizontal, Space.page + 4)
            .padding(.top, Space.xxl)
            .padding(.bottom, Space.page * 2)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
            .animation(Motion.base, value: installed)
        }
        .scrollContentBackground(.hidden)
        .sheet(item: $enabler.asking) { _ in EnableSheet(enabler: enabler) }
    }
}
