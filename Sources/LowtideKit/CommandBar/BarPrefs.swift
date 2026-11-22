import Foundation

/// How often and when a row was last run.
public struct BarUsage: Codable, Equatable, Sendable {
    public var count: Int
    public var lastUsed: Date

    public init(count: Int, lastUsed: Date) {
        self.count = count
        self.lastUsed = lastUsed
    }
}

/// A saved link, place or script ("Your shortcuts").
public struct BarLink: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case link, place, script }

    public var id: String
    public var kind: Kind
    public var name: String
    /// A URL template (`github.com/search?q={query}`), a path, or an executable.
    public var destination: String
    /// Scripts: also run when the name is typed alone.
    public var runsWithoutArgument: Bool

    public init(id: String = UUID().uuidString, kind: Kind, name: String, destination: String, runsWithoutArgument: Bool = false) {
        self.id = id
        self.kind = kind
        self.name = name
        self.destination = destination
        self.runsWithoutArgument = runsWithoutArgument
    }

    /// Needs something typed after its name before it can run.
    public var needsArgument: Bool {
        kind == .script ? !runsWithoutArgument : destination.contains("{query}")
    }

    /// "gh foo" → "foo" when the link is named "gh"; "" for the name alone;
    /// nil when the query doesn't start with the name.
    public func argument(in query: String) -> String? {
        let name = self.name.trimmingCharacters(in: .whitespaces).lowercased()
        var typed = Substring(query)
        while typed.first?.isWhitespace == true { typed = typed.dropFirst() }
        if typed.lowercased() == name { return "" }
        if typed.lowercased().hasPrefix(name + " ") { return String(typed.dropFirst(name.count + 1)) }
        return nil
    }

    /// `{query}` and `{date}` filled in; URL-encoded for links.
    public func expanded(_ argument: String, today: Date = .now) -> String {
        let encode = kind == .link
        let date = today.formatted(date: .numeric, time: .omitted)
        let value = encode ? argument.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? argument : argument
        let day = encode ? date.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? date : date
        var target = destination.replacingOccurrences(of: "{query}", with: value).replacingOccurrences(of: "{date}", with: day)
        if kind == .place { target = (target as NSString).expandingTildeInPath }
        if kind == .link, target.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*:", options: .regularExpression) == nil {
            target = "https://" + target
        }
        return target
    }
}

extension CharacterSet {
    /// Query values: everything a URL allows in a query except the
    /// separators that would split it (`&`, `=`, `+`, `#`).
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+#?/")
        return set
    }()
}

public enum SkinTone: String, Codable, CaseIterable, Sendable {
    case none = "", light, mediumLight, medium, mediumDark, dark

    /// The Fitzpatrick modifier, nil for the default yellow.
    public var modifier: String? {
        switch self {
        case .none: nil
        case .light: "\u{1F3FB}"
        case .mediumLight: "\u{1F3FC}"
        case .medium: "\u{1F3FD}"
        case .mediumDark: "\u{1F3FE}"
        case .dark: "\u{1F3FF}"
        }
    }
}

/// The command bar's settings and what it learned, in `commandbar.json`.
public struct BarPrefs: Codable, Equatable, Sendable {
    /// stableKey → the person's own name for a row.
    public var aliases: [String: String] = [:]
    /// Colours picked from the screen, newest first (max 16).
    public var colors: [String] = []
    /// Opens as just the field; results appear while typing.
    public var compact = false
    public var disabled: [BarSource] = []
    public var fileIgnores: [String] = []
    /// Folders the bar searches for files (none: no file search).
    public var fileScopes: [String] = []
    /// How much glass: 0 frosted, 100 clear.
    public var glass = 35
    /// stableKeys never shown.
    public var hidden: [String] = []
    /// The global shortcut that opens the bar.
    public var hotkey: Hotkey = .defaultBar
    public var hotkeyEnabled = true
    public var links: [BarLink] = []
    /// stableKeys in the order they were pinned (max 30): Quick access.
    public var pins: [String] = BarPrefs.defaultPins
    public var skinTone: SkinTone = .none
    /// Row id → how often and when it was last run (max 200).
    public var usage: [String: BarUsage] = [:]

    public init() {}

    /// Quick access to start with: what the app is opened for most.
    public static let defaultPins = [
        "lowtide.ask", "lowtide.page:apps/updates", "lowtide.page:network/live", "lowtide.page:developer/sessions",
        "lowtide.page:developer/hosts",
    ]
    static let maxPins = 30
    static let maxUsage = 200

    public func isOn(_ source: BarSource) -> Bool { !disabled.contains(source) }

    public mutating func record(_ id: String, now: Date = .now) {
        usage[id] = BarUsage(count: min(999, (usage[id]?.count ?? 0) + 1), lastUsed: now)
        if usage.count > Self.maxUsage {
            let oldest = usage.sorted { $0.value.lastUsed < $1.value.lastUsed }.prefix(usage.count - Self.maxUsage)
            for (key, _) in oldest { usage[key] = nil }
        }
    }

    /// Forgets one row's use, or all of it.
    public mutating func forget(_ id: String? = nil) {
        if let id { usage[id] = nil } else { usage = [:] }
    }

    public mutating func togglePin(_ key: String) {
        if let at = pins.firstIndex(of: key) {
            pins.remove(at: at)
        } else {
            pins = Array((pins + [key]).suffix(Self.maxPins))
        }
    }

    /// Moves a pin one place up (-1) or down (1).
    public mutating func movePin(_ key: String, by delta: Int) {
        guard let at = pins.firstIndex(of: key), pins.indices.contains(at + delta) else { return }
        pins.swapAt(at, at + delta)
    }

    public mutating func setAlias(_ key: String, _ alias: String) {
        let trimmed = String(alias.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        aliases[key] = trimmed.isEmpty ? nil : trimmed
    }

    public mutating func toggleHidden(_ key: String) {
        if let at = hidden.firstIndex(of: key) { hidden.remove(at: at) } else { hidden.append(key) }
    }

    public mutating func toggle(_ source: BarSource) {
        if let at = disabled.firstIndex(of: source) { disabled.remove(at: at) } else { disabled.append(source) }
    }

    public mutating func addColor(_ hex: String) {
        colors = Array(([hex] + colors.filter { $0 != hex }).prefix(16))
    }

    /// The row whose name would share a word with `alias`: a clash.
    public func aliasClash(key: String, alias: String) -> String? {
        let words = alias.lowercased().split(whereSeparator: \.isWhitespace)
        for (other, name) in aliases where other != key {
            let taken = name.lowercased().split(whereSeparator: \.isWhitespace)
            if words.contains(where: taken.contains) { return other }
        }
        return nil
    }

    // Older files may lack keys added since; every field has a default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BarPrefs()
        aliases = try c.decodeIfPresent([String: String].self, forKey: .aliases) ?? d.aliases
        colors = try c.decodeIfPresent([String].self, forKey: .colors) ?? d.colors
        compact = try c.decodeIfPresent(Bool.self, forKey: .compact) ?? d.compact
        disabled = (try? c.decodeIfPresent([BarSource].self, forKey: .disabled)) ?? d.disabled
        fileIgnores = try c.decodeIfPresent([String].self, forKey: .fileIgnores) ?? d.fileIgnores
        fileScopes = try c.decodeIfPresent([String].self, forKey: .fileScopes) ?? d.fileScopes
        glass = try c.decodeIfPresent(Int.self, forKey: .glass) ?? d.glass
        hidden = try c.decodeIfPresent([String].self, forKey: .hidden) ?? d.hidden
        hotkey = (try? c.decodeIfPresent(Hotkey.self, forKey: .hotkey)) ?? d.hotkey
        hotkeyEnabled = try c.decodeIfPresent(Bool.self, forKey: .hotkeyEnabled) ?? d.hotkeyEnabled
        links = try c.decodeIfPresent([BarLink].self, forKey: .links) ?? d.links
        pins = try c.decodeIfPresent([String].self, forKey: .pins) ?? d.pins
        skinTone = (try? c.decodeIfPresent(SkinTone.self, forKey: .skinTone)) ?? d.skinTone
        usage = try c.decodeIfPresent([String: BarUsage].self, forKey: .usage) ?? d.usage
    }

    public static let file = "commandbar.json"

    public static func load() -> BarPrefs { JSONStore.load(file, default: BarPrefs()) }

    public func save() { JSONStore.save(self, to: Self.file) }
}
