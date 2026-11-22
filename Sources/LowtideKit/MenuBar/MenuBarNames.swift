import Foundation

/// What a menu bar icon is called and which glyph stands in for it, from the
/// item's own Accessibility attributes, never from the process that draws it.
/// On macOS 27 one process, MenuBarAgent, draws every system icon, and on
/// macOS 26 Control Center owns them; named after the owner they all read
/// "macOS" or "Control Center".
public enum MenuBarNames {
    /// System owners: their icons are named by their identifiers.
    public static let systemOwners: Set<String> = [
        "com.apple.MenuBarAgent", "com.apple.controlcenter", "com.apple.systemuiserver",
    ]
    /// The owner every system icon is filed under, so keys are the same on
    /// macOS 26 (Control Center) and 27 (MenuBarAgent).
    public static let systemOwner = "com.apple.controlcenter"
    static let extraPrefix = "com.apple.menuextra."

    /// System icons by the tail of their identifier (`com.apple.menuextra.<tail>`,
    /// lowercased, without dashes or dots): the short name and an SF Symbol.
    public static let system: [(tail: String, name: String, symbol: String)] = [
        ("wifi", "Wi‑Fi", "wifi"),
        ("battery", "Battery", "battery.75percent"),
        ("clock", "Clock", "clock"),
        ("controlcenter", "Control Center", "switch.2"),
        ("bluetooth", "Bluetooth", "dot.radiowaves.left.and.right"),
        ("sound", "Sound", "speaker.wave.2"),
        ("volume", "Sound", "speaker.wave.2"),
        ("focusmode", "Focus", "moon"),
        ("focus", "Focus", "moon"),
        ("donotdisturb", "Focus", "moon"),
        ("spotlight", "Spotlight", "magnifyingglass"),
        ("siri", "Siri", "waveform.circle"),
        ("nowplaying", "Now Playing", "play.circle"),
        ("display", "Display", "display"),
        ("screenmirroring", "Screen Mirroring", "rectangle.on.rectangle"),
        ("airplay", "Screen Mirroring", "rectangle.on.rectangle"),
        ("keyboardbrightness", "Keyboard Brightness", "sun.max"),
        ("textinput", "Input Sources", "keyboard"),
        ("keyboard", "Input Sources", "keyboard"),
        ("timemachine", "Time Machine", "clock.arrow.circlepath"),
        ("vpn", "VPN", "network"),
        ("user", "Fast User Switching", "person.crop.circle"),
        ("fastuserswitching", "Fast User Switching", "person.crop.circle"),
        ("accessibility", "Accessibility Shortcuts", "accessibility"),
        ("hearing", "Hearing", "ear"),
        ("airdrop", "AirDrop", "antenna.radiowaves.left.and.right"),
        ("stagemanager", "Stage Manager", "squares.leading.rectangle"),
        ("audiovideo", "Audio and Video", "mic"),
        ("gamemode", "Game Mode", "gamecontroller"),
        ("weather", "Weather", "cloud.sun"),
        ("screencapture", "Screen Recording", "record.circle"),
        ("screenrecording", "Screen Recording", "record.circle"),
        ("mic", "Microphone", "mic"),
        ("location", "Location", "location"),
        ("script", "Scripts", "scroll"),
        ("scripts", "Scripts", "scroll"),
    ]

    /// Stands in for a system icon with no glyph of its own.
    public static let fallbackSymbol = "menubar.rectangle"

    public static func isSystem(bundleId: String) -> Bool { systemOwners.contains(bundleId) }

    /// `com.apple.menuextra.now-playing` → `nowplaying`.
    static func tail(_ identifier: String) -> String? {
        let lower = identifier.lowercased()
        guard lower.hasPrefix(extraPrefix) else { return nil }
        return lower.dropFirst(extraPrefix.count).filter { $0.isLetter || $0.isNumber }
    }

    static func known(_ identifier: String) -> (name: String, symbol: String)? {
        guard let tail = tail(identifier), !tail.isEmpty else { return nil }
        if let exact = system.first(where: { $0.tail == tail }) { return (exact.name, exact.symbol) }
        // Longest match first: "keyboardbrightness" before "keyboard".
        return system.filter { tail.hasPrefix($0.tail) }.max { $0.tail.count < $1.tail.count }.map { ($0.name, $0.symbol) }
    }

    /// The first clause: "Wi‑Fi, connected, 3 bars" reads "Wi‑Fi".
    static func clause(_ text: String) -> String {
        text.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    /// An icon's short name. System icons by their identifier, then by what
    /// they say about themselves; other apps' by what the item says, else the
    /// app's own name.
    public static func name(identifier: String, label: String, app: String, system: Bool) -> String {
        if let known = known(identifier) { return known.name }
        let said = clause(label)
        if !said.isEmpty { return said }
        if system {
            if let tail = tail(identifier), !tail.isEmpty { return tail.prefix(1).uppercased() + tail.dropFirst() }
            return "System icon"
        }
        return app.isEmpty ? "Menu bar icon" : app
    }

    public static func name(_ item: MenuBarItem) -> String {
        name(identifier: item.identifier, label: item.label, app: item.app, system: item.system)
    }

    /// The glyph for a system icon, by its identifier; nil for other apps'.
    public static func symbol(identifier: String, system: Bool) -> String? {
        if let known = known(identifier) { return known.symbol }
        return system ? fallbackSymbol : nil
    }

    /// The identifier inside a key (`owner#identifier`), for pins that only
    /// kept their key.
    public static func identifier(inKey key: String) -> String {
        key.split(separator: "#", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
    }

    /// The key an item is known by across launches and moves: its owner, and
    /// its identifier, else its description, else its place among the
    /// owner's items. A second item with the same token gets its place added.
    /// Titles are left out: they change ("99+", the time).
    public static func key(owner: String, identifier: String, label: String, index: Int, taken: Set<String>) -> String {
        let token = !identifier.isEmpty ? identifier : clause(label)
        let base = "\(owner)#\(token.isEmpty ? String(index) : token)"
        return taken.contains(base) ? "\(base)#\(index)" : base
    }
}
