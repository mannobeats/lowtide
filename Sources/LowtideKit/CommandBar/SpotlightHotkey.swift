import Foundation

/// Spotlight's own shortcut (⌘Space), so the command bar can take it over
/// and hand it back. macOS keeps it in `com.apple.symbolichotkeys` as
/// symbolic hotkey 64; only that entry is ever written.
public struct SpotlightHotkey: Sendable {
    public struct State: Equatable, Sendable {
        /// Spotlight still answers ⌘Space.
        public var enabled: Bool
        /// Saved, but macOS only applies it at the next log-in.
        public var needsLogout: Bool
    }

    /// The preferences domain, or a plist file's path (tests edit a copy).
    public var domain: String
    /// Whether to ask macOS to reload the shortcuts after a change.
    public var applies: Bool

    public init(domain: String = "com.apple.symbolichotkeys", applies: Bool = true) {
        self.domain = domain
        self.applies = applies
    }

    static let hotkeys = "AppleSymbolicHotKeys"
    /// "Show Spotlight search" (65 is Finder's search window; left alone).
    static let spotlight = "64"
    /// Reloads the person's preferences so the change applies without a log-out.
    static let activate = "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"
    /// Space (ASCII 32, key code 49) with ⌘: macOS's own default for entry 64.
    static let defaultParameters = [32, 49, 1_048_576]

    /// Entry 64 from a plist (`defaults export` output), if it's there.
    static func entry(_ plist: Data) -> [String: Any]? {
        let root = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any]
        return (root?[hotkeys] as? [String: Any])?[spotlight] as? [String: Any]
    }

    /// A missing entry, or one without `enabled`, is macOS's default: on.
    static func isEnabled(_ entry: [String: Any]?) -> Bool {
        switch entry?["enabled"] {
        case let on as Bool: on
        case let n as NSNumber: n.intValue != 0
        default: true
        }
    }

    /// The entry with only `enabled` changed, as a plist fragment `defaults`
    /// accepts. A shortcut the person remapped keeps its keys.
    static func fragment(_ entry: [String: Any]?, enabled: Bool) -> String {
        let value = entry?["value"] as? [String: Any]
        let parameters = (value?["parameters"] as? [NSNumber]).map { $0.map(\.intValue) }.flatMap { $0.count == 3 ? $0 : nil }
            ?? defaultParameters
        let kind = (value?["type"] as? String).flatMap { $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } ? $0 : nil }
            ?? "standard"
        let integers = parameters.map { "<integer>\($0)</integer>" }.joined()
        return "<dict><key>enabled</key><\(enabled)/><key>value</key><dict>"
            + "<key>parameters</key><array>\(integers)</array>"
            + "<key>type</key><string>\(kind)</string></dict></dict>"
    }

    func readEntry() async throws -> [String: Any]? {
        let out = try await Shell.run("/usr/bin/defaults", ["export", domain, "-"], timeout: .seconds(10))
        // A domain with nothing saved yet exports nothing: Spotlight's default.
        guard out.ok else {
            if out.stderr.contains("does not exist") { return nil }
            throw LowtideError.commandFailed("Couldn't read the keyboard shortcuts from macOS.")
        }
        return Self.entry(Data(out.stdout.utf8))
    }

    public func state() async throws -> State {
        State(enabled: Self.isEnabled(try await readEntry()), needsLogout: false)
    }

    /// `false` frees ⌘Space for the command bar; `true` gives it back.
    @discardableResult
    public func set(enabled: Bool) async throws -> State {
        let entry = try await readEntry()
        if Self.isEnabled(entry) != enabled {
            let out = try await Shell.run("/usr/bin/defaults", ["write", domain, Self.hotkeys, "-dict-add", Self.spotlight,
                                                                Self.fragment(entry, enabled: enabled)], timeout: .seconds(10))
            guard out.ok else { throw LowtideError.commandFailed("macOS didn't save Spotlight's shortcut.") }
        }
        var logout = false
        if applies {
            // Without the tool the saved change waits for the next log-in.
            logout = !FileManager.default.isExecutableFile(atPath: Self.activate)
            if !logout { logout = !((try? await Shell.run(Self.activate, ["-u"], timeout: .seconds(10)))?.ok ?? false) }
        }
        let now = Self.isEnabled(try await readEntry())
        guard now == enabled else { throw LowtideError.commandFailed("macOS didn't take the change to Spotlight's shortcut.") }
        return State(enabled: now, needsLogout: logout)
    }
}
