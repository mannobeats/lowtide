import LowtideKit
import SwiftUI

/// The spaces in the rail, in order (⌘1–⌘8). Each answers one question;
/// its hue is the breath of colour at the top of its pages and the rim
/// light of its hero object.
enum SpaceID: String, CaseIterable, Identifiable, Codable {
    case home, apps, cleanup, protection, network, system, developer, extensions
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .apps: "Apps"
        case .cleanup: "Cleanup"
        case .protection: "Protection"
        case .network: "Network"
        case .system: "System"
        case .developer: "Developer"
        case .extensions: "Extensions"
        }
    }

    /// The space's glyph in `Resources/glyphs` (and its hero in `Resources/heroes`).
    var glyph: String { rawValue }

    var hue: Double {
        switch self {
        case .home: 195
        case .apps: 245
        case .cleanup: 165
        case .protection: 290
        case .network: 215
        case .system: 35
        case .developer: 265
        case .extensions: 320
        }
    }

    /// Home has no sidebar; Network shows its pages as tabs so the map
    /// gets the width.
    var navigation: Navigation {
        switch self {
        case .home: .none
        case .network: .tabs
        default: .sidebar
        }
    }

    enum Navigation { case none, tabs, sidebar }

    var pages: [Page] {
        let pages = Page.allCases.filter { $0.space == self }
        guard self == .extensions else { return pages }
        // Installed extensions first, then the ones to add.
        return pages.filter { $0.group != "Available" } + pages.filter { $0.group == "Available" }
    }

    /// The sidebar's groups, in order: a heading (nil for none) and its pages.
    var groups: [(String?, [Page])] {
        var result: [(String?, [Page])] = []
        for page in pages {
            if let last = result.last, last.0 == page.group {
                result[result.count - 1].1.append(page)
            } else {
                result.append((page.group, [page]))
            }
        }
        return result
    }
}

/// Every page, in sidebar order. The rail, sidebar, ⌘K, the command bar,
/// menus and URLs (`lowtide://open/<page>`) all read this list.
enum Page: String, CaseIterable, Identifiable, Codable {
    case home
    case appsInstalled = "apps/installed", appsUpdates = "apps/updates", appsAddons = "apps/addons"
    case cleanup = "cleanup/clean", leftovers = "cleanup/leftovers", spaceLens = "cleanup/lens", duplicates = "cleanup/duplicates"
    case protectionOverview = "protection/overview", threats = "protection/threats", secrets = "protection/secrets",
         permissions = "protection/permissions", installWatch = "protection/install-watch"
    case networkLive = "network/live", packets = "network/packets", dns = "network/dns", localhost = "network/local",
         overnight = "network/overnight"
    case systemOverview = "system/silicon", processes = "system/processes", sensors = "system/sensors"
    case toolchain = "developer/toolchain", inventory = "developer/inventory", runtimes = "developer/runtimes",
         doctor = "developer/doctor", recipe = "developer/recipe"
    case sessions = "developer/sessions", snippets = "developer/snippets", history = "developer/history"
    case hosts = "developer/hosts", credentials = "developer/credentials", forwards = "developer/forwards"
    case extensionsGallery = "extensions/all", dictation = "extensions/dictation", menuBarManager = "extensions/menubar",
         widgets = "extensions/widgets", commandBar = "extensions/command-bar"

    var id: String { rawValue }

    var space: SpaceID {
        if self == .home { return .home }
        return SpaceID(rawValue: String(rawValue.split(separator: "/")[0])) ?? .home
    }

    /// The heading this page sits under in its space's sidebar.
    var group: String? {
        switch self {
        case .toolchain, .inventory, .runtimes, .doctor, .recipe: "Toolchain"
        case .sessions, .snippets, .history: "Terminal"
        case .hosts, .credentials, .forwards: "Remote"
        case .dictation, .menuBarManager, .widgets, .commandBar:
            extensionID.map { ExtensionState.isOn($0) ? "Installed" : "Available" }
        default: nil
        }
    }

    /// The extension a page belongs to.
    var extensionID: ExtensionState.ID? {
        switch self {
        case .dictation: .dictation
        case .menuBarManager: .menubar
        case .widgets: .widgets
        case .commandBar: .commandbar
        default: nil
        }
    }

    var title: String {
        switch self {
        case .home: "Home"
        case .appsInstalled: "Installed"
        case .appsUpdates: "Updates"
        case .appsAddons: "Add-ons"
        case .cleanup: "Cleanup"
        case .leftovers: "Leftovers"
        case .spaceLens: "Space lens"
        case .duplicates: "Duplicates"
        case .protectionOverview: "Overview"
        case .threats: "Threats"
        case .secrets: "Secrets"
        case .permissions: "Permissions"
        case .installWatch: "Install watch"
        case .networkLive: "Live"
        case .packets: "Packets"
        case .dns: "DNS"
        case .localhost: "Localhost"
        case .overnight: "Overnight report"
        case .systemOverview: "Silicon"
        case .processes: "Processes"
        case .sensors: "Sensors and fans"
        case .toolchain: "Overview"
        case .inventory: "Inventory"
        case .runtimes: "Runtimes"
        case .doctor: "Doctor"
        case .recipe: "Mac recipe"
        case .sessions: "Sessions"
        case .snippets: "Snippets"
        case .history: "History"
        case .hosts: "Hosts"
        case .credentials: "Credentials"
        case .forwards: "Port forwards"
        case .extensionsGallery: "All extensions"
        case .dictation: "Dictation"
        case .menuBarManager: "Menu bar manager"
        case .widgets: "Menu bar widgets"
        case .commandBar: "Command bar"
        }
    }

    /// The page's glyph in `Resources/glyphs` (Lowtide's own set).
    var glyph: String {
        switch self {
        case .home: "home"
        case .appsInstalled: "installed"
        case .appsUpdates: "updates"
        case .appsAddons: "addons"
        case .cleanup: "cleanup-caches"
        case .leftovers: "leftovers"
        case .spaceLens: "space-lens"
        case .duplicates: "duplicates"
        case .protectionOverview: "protection"
        case .threats: "threats"
        case .secrets: "secrets"
        case .permissions: "permissions"
        case .installWatch: "install-watch"
        case .networkLive: "live"
        case .packets: "packets"
        case .dns: "dns"
        case .localhost: "localhost"
        case .overnight: "overnight"
        case .systemOverview: "silicon"
        case .processes: "processes"
        case .sensors: "sensors"
        case .toolchain: "toolchain"
        case .inventory: "inventory"
        case .runtimes: "runtimes"
        case .doctor: "doctor"
        case .recipe: "recipe"
        case .sessions: "sessions"
        case .snippets: "snippets"
        case .history: "history"
        case .hosts: "hosts"
        case .credentials: "credentials"
        case .forwards: "forwards"
        case .extensionsGallery: "extensions"
        case .dictation: "dictation"
        case .menuBarManager: "menubar"
        case .widgets: "widgets"
        case .commandBar: "command-bar"
        }
    }

    /// Extra words ⌘K and the command bar match.
    var keywords: String {
        switch self {
        case .home: "overview today summary"
        case .appsInstalled: "applications uninstall remove homebrew casks library"
        case .appsUpdates: "upgrade outdated brew npm cli tools command-line"
        case .appsAddons: "plugins audio vst au extensions"
        case .cleanup: "caches build files downloads installers dmg free space docker"
        case .leftovers: "uninstalled remnants orphans"
        case .spaceLens: "disk usage treemap big folders storage"
        case .duplicates: "same files copies"
        case .protectionOverview: "security status"
        case .threats: "malware suspicious score"
        case .secrets: "exposed tokens keys decoy canary leaks env"
        case .permissions: "privacy tcc login items full disk access camera"
        case .installWatch: "tripwire install script curl receipts"
        case .networkLive: "connections map world traffic"
        case .packets: "capture pcap wireshark"
        case .dns: "lookups domains queries"
        case .localhost: "ports listening dev servers local"
        case .overnight: "night shift away while asleep briefing"
        case .systemOverview: "cpu gpu power watts frequency"
        case .processes: "activity monitor kill top"
        case .sensors: "temperature fans thermals"
        case .toolchain: "packages managers health"
        case .inventory: "npm pnpm cargo gem pipx go bun composer brew"
        case .runtimes: "node python ruby java go rust versions"
        case .doctor: "path diagnostics broken"
        case .recipe: "setup new mac restore brewfile"
        case .sessions: "shell tabs split terminal"
        case .snippets: "commands saved scripts run"
        case .history: "commands receipts runs"
        case .hosts: "ssh servers groups fleet"
        case .credentials: "ssh keys identities passwords"
        case .forwards: "tunnel port forward"
        case .extensionsGallery: "extensions add-ons"
        case .dictation: "voice speech transcribe speak"
        case .menuBarManager: "hide icons notch island"
        case .widgets: "menu bar stats cpu memory network"
        case .commandBar: "launcher spotlight hotkey ask"
        }
    }
}
