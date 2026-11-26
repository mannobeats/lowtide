import Foundation

// The app's side of the dictation helper's JSON-lines protocol (the contract
// is at the top of Helpers/Voice/Sources/main.swift). Everything here is a
// plain value: what the page saves, what goes to the helper, what comes back.

/// What starts dictation, as the helper records it: a key with modifiers,
/// modifiers alone (side-specific, like "rightOption"), or a mouse button.
public struct VoiceShortcut: Codable, Hashable, Sendable {
    public var key: Int?
    public var button: Int?
    public var modifiers: [String]

    public init(key: Int? = nil, button: Int? = nil, modifiers: [String]) {
        self.key = key
        self.button = button
        self.modifiers = modifiers
    }

    public static let rightOption = VoiceShortcut(modifiers: ["rightOption"])
    public static let rightOptionLabel = "Right ⌥"

    /// Modifiers alone keep working through Secure Input: macOS hides key
    /// presses from shortcut listeners then, not modifier changes.
    public var modifiersOnly: Bool { key == nil && button == nil }
    public var usesFn: Bool { modifiers.contains("fn") }

    /// The F-row, which types nothing: a bare one is a fine shortcut. Kept in
    /// step with `Keys.functionKeys` in the helper, which records the press.
    static let functionKeys: Set<Int> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
    ]
    /// Keys that only move: bare, they give up nothing typed. The F-row plus
    /// the arrows, Home, End, the page keys, Forward Delete and Help. Kept in
    /// step with `Keys.implicitFn` in the helper.
    static let movingKeys: Set<Int> = functionKeys.union([123, 124, 125, 126, 115, 119, 116, 121, 117, 114])

    /// A short line for a key that gives something up, else nil: one with
    /// ⌘, ⌥ or ⌃, a mouse button, a modifier alone, or a key that only moves
    /// gives nothing up. Shift and fn don't count: ⇧A still types A.
    public func note(label: String) -> String? {
        guard let key, button == nil, !Self.movingKeys.contains(key),
              !modifiers.contains(where: ["command", "option", "control"].contains)
        else { return nil }
        return "\(label) no longer types"
    }
}

/// Listen while the shortcut is held, until it's tapped again, or either.
public enum DictationMode: String, Codable, CaseIterable, Sendable {
    case hold, toggle, auto

    public var title: String {
        switch self {
        case .hold: "Held"
        case .toggle: "Toggled"
        case .auto: "Either"
        }
    }

    public var hint: String {
        switch self {
        case .auto: "Hold while you speak, or tap to start and tap again to stop"
        case .hold: "Listens while you hold the shortcut"
        case .toggle: "Tap to start, tap again to stop"
        }
    }
}

/// An app whose dictations are never kept in history.
public struct LeftOutApp: Codable, Hashable, Sendable, Identifiable {
    public var bundleId: String
    public var name: String
    public var id: String { bundleId }

    public init(bundleId: String, name: String) {
        self.bundleId = bundleId
        self.name = name
    }
}

/// Spoken → typed ("low tide" becomes "Lowtide").
public struct Replacement: Codable, Hashable, Sendable {
    public var spoken: String
    public var typed: String

    public init(spoken: String, typed: String) {
        self.spoken = spoken
        self.typed = typed
    }
}

/// Everything the Dictation page sets. Saved as JSON; a missing key reads
/// as its default, so older saves keep working.
public struct VoicePrefs: Codable, Equatable, Sendable {
    /// System default passes over a Bluetooth input for the built-in mic.
    public var avoidBluetooth = true
    public var excluded: [LeftOutApp] = VoicePrefs.passwordManagers
    public var fillers = true
    public var history = true
    /// Days history is kept; 0 keeps it until cleared.
    public var keepDays = 30
    /// The microphone stays open between takes, so the first word isn't lost.
    public var keepReady = true
    /// ISO code, or "auto".
    public var language = "auto"
    /// A device uid, or nil for the system's input.
    public var microphone: String?
    public var mode: DictationMode = .auto
    public var model = "parakeet-v3"
    /// Apple's on-device model tidies the text.
    public var polish = false
    public var preview = true
    public var replacements: [Replacement] = []
    public var shortcut: VoiceShortcut = .rightOption
    public var shortcutLabel = VoiceShortcut.rightOptionLabel
    public var sounds = true
    /// Names and jargon to expect.
    public var vocabulary: [String] = []

    public static let passwordManagers = [
        LeftOutApp(bundleId: "com.1password.1password", name: "1Password"),
        LeftOutApp(bundleId: "com.agilebits.onepassword7", name: "1Password 7"),
        LeftOutApp(bundleId: "com.bitwarden.desktop", name: "Bitwarden"),
        LeftOutApp(bundleId: "com.apple.Passwords", name: "Passwords"),
        LeftOutApp(bundleId: "com.apple.keychainaccess", name: "Keychain Access"),
    ]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = VoicePrefs()
        avoidBluetooth = try c.decodeIfPresent(Bool.self, forKey: .avoidBluetooth) ?? d.avoidBluetooth
        excluded = try c.decodeIfPresent([LeftOutApp].self, forKey: .excluded) ?? d.excluded
        fillers = try c.decodeIfPresent(Bool.self, forKey: .fillers) ?? d.fillers
        history = try c.decodeIfPresent(Bool.self, forKey: .history) ?? d.history
        keepDays = try c.decodeIfPresent(Int.self, forKey: .keepDays) ?? d.keepDays
        keepReady = try c.decodeIfPresent(Bool.self, forKey: .keepReady) ?? d.keepReady
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? d.language
        microphone = try c.decodeIfPresent(String.self, forKey: .microphone)
        mode = (try? c.decodeIfPresent(DictationMode.self, forKey: .mode)) ?? d.mode
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        polish = try c.decodeIfPresent(Bool.self, forKey: .polish) ?? d.polish
        preview = try c.decodeIfPresent(Bool.self, forKey: .preview) ?? d.preview
        replacements = try c.decodeIfPresent([Replacement].self, forKey: .replacements) ?? d.replacements
        shortcut = try c.decodeIfPresent(VoiceShortcut.self, forKey: .shortcut) ?? d.shortcut
        shortcutLabel = try c.decodeIfPresent(String.self, forKey: .shortcutLabel) ?? d.shortcutLabel
        sounds = try c.decodeIfPresent(Bool.self, forKey: .sounds) ?? d.sounds
        vocabulary = try c.decodeIfPresent([String].self, forKey: .vocabulary) ?? d.vocabulary
    }

    /// Bundle ids never kept in history.
    public var excludedIDs: Set<String> { Set(excluded.map(\.bundleId)) }

    /// The `configure` line: what the helper listens for and how. Sent first
    /// to every helper started, and again on every change.
    public func configureLine(enabled: Bool, modelsDir: URL) -> Data {
        var object: [String: Any] = [
            "type": "configure",
            "enabled": enabled,
            "shortcut": shortcutJSON,
            "mode": mode.rawValue,
            "model": model,
            "modelsDir": modelsDir.path,
            "language": language,
            "keepReady": keepReady,
            "avoidBluetooth": avoidBluetooth,
            "replacements": replacements.map { [$0.spoken, $0.typed] },
            "vocabulary": vocabulary,
            "fillers": fillers,
            "polish": polish,
            "sounds": sounds,
            "preview": preview,
        ]
        object["microphone"] = microphone ?? NSNull()
        return VoiceLine.encode(object)
    }

    private var shortcutJSON: [String: Any] {
        var out: [String: Any] = ["modifiers": shortcut.modifiers]
        if let key = shortcut.key { out["key"] = key }
        if let button = shortcut.button { out["button"] = button }
        return out
    }
}

/// One JSON line to the helper.
public enum VoiceLine {
    public static func encode(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    public static func command(_ type: String, _ fields: [String: Any] = [:]) -> Data {
        var object = fields
        object["type"] = type
        return encode(object)
    }
}

/// Where a take is.
public enum VoicePhase: String, Codable, Sendable, CaseIterable {
    /// `listening`: the microphone is opening.
    case idle, listening, recording, transcribing, done, empty, error

    public var isLive: Bool { self == .recording || self == .transcribing }
}

/// What an error offers to fix it, on the overlay and the page.
public enum VoiceAction: String, Codable, Sendable, CaseIterable {
    case openSettings = "open-settings"
    case allowAccessibility = "allow-accessibility"
    case allowMicrophone = "allow-microphone"
    case downloadModel = "download-model"
    case pasteLast = "paste-last"

    public var title: String {
        switch self {
        case .allowAccessibility: "Allow Accessibility"
        case .allowMicrophone: "Allow Microphone"
        case .downloadModel: "Download a model"
        case .openSettings: "Open Settings"
        case .pasteLast: "Paste last"
        }
    }
}

/// One `state` from the helper. Done, empty and error are followed by idle
/// once they've been shown.
public struct VoiceState: Equatable, Sendable {
    public var phase: VoicePhase
    public var message: String
    /// On done: "paste", "accessibility", "typed" or "copied".
    public var method: String?
    /// On done (and errors after a take): the app the text went to.
    public var app: String?
    public var text: String?
    /// On error: no-model, model-loading, mic, permission, secure-input,
    /// no-focus, or helper (it stopped).
    public var kind: String?
    public var action: VoiceAction?
    /// Takes waiting behind this one.
    public var queued: Int

    public init(phase: VoicePhase, message: String = "", method: String? = nil, app: String? = nil,
                text: String? = nil, kind: String? = nil, action: VoiceAction? = nil, queued: Int = 0) {
        self.phase = phase
        self.message = message
        self.method = method
        self.app = app
        self.text = text
        self.kind = kind
        self.action = action
        self.queued = queued
    }

    public static let idle = VoiceState(phase: .idle)

    /// How long a finished state stays before idle follows it.
    public var shownFor: Duration? {
        switch phase {
        case .done: .milliseconds(1600)
        case .empty: .milliseconds(2400)
        case .error: .seconds(5)
        default: nil
        }
    }

    /// Reads what the overlay can use; anything else is dropped, and empty
    /// strings count as absent.
    init(json s: [String: Any]) {
        func str(_ key: String) -> String? {
            (s[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        phase = (s["phase"] as? String).flatMap(VoicePhase.init(rawValue:)) ?? .idle
        message = str("message") ?? ""
        method = str("method")
        app = str("app")
        text = str("text")
        kind = str("kind")
        action = str("action").flatMap(VoiceAction.init(rawValue:))
        queued = (s["queued"] as? NSNumber)?.intValue ?? 0
    }
}

/// A finished dictation as the helper reports it.
public struct DictationResult: Equatable, Sendable {
    public var text: String
    public var raw: String
    public var app: String
    public var bundleId: String
    public var model: String
    public var seconds: Double
    public var elapsedMs: Int
    /// It went in (pasted, typed or set), rather than only copied.
    public var typed: Bool
    /// A password field refused it: never kept.
    public var secure: Bool
    public var method: String

    public init(text: String, raw: String = "", app: String = "", bundleId: String = "", model: String = "",
                seconds: Double = 0, elapsedMs: Int = 0, typed: Bool = true, secure: Bool = false, method: String = "") {
        self.text = text
        self.raw = raw
        self.app = app
        self.bundleId = bundleId
        self.model = model
        self.seconds = seconds
        self.elapsedMs = elapsedMs
        self.typed = typed
        self.secure = secure
        self.method = method
    }
}

/// A microphone.
public struct VoiceDevice: Equatable, Hashable, Sendable, Identifiable {
    public var uid: String
    public var name: String
    public var isDefault: Bool
    public var id: String { uid }

    public init(uid: String, name: String, isDefault: Bool) {
        self.uid = uid
        self.name = name
        self.isDefault = isDefault
    }
}

/// The chosen model's state as the helper reports it.
public enum ModelState: String, Sendable {
    case unknown = "", missing, loading, ready, asleep, error

    public var title: String? {
        switch self {
        case .asleep: "Resting; wakes as you speak"
        case .error: "Couldn't load"
        case .loading: "Loading…"
        case .missing: "Not downloaded"
        case .ready: "Ready"
        case .unknown: nil
        }
    }
}

/// One line from the helper.
public enum HelperMessage: Equatable, Sendable {
    case state(VoiceState)
    case level(Double)
    case preview(String)
    case result(DictationResult)
    case model(id: String, state: ModelState, message: String)
    /// `error` "" is a cancel; nil while it runs.
    case download(model: String, progress: Double, done: Bool, error: String?)
    /// `fnUsage` is .some(nil) when the helper says it's unset.
    case access(shortcut: Bool?, polish: Bool?, fnUsage: Int??)
    case shortcut(VoiceShortcut, label: String)
    case devices([VoiceDevice])

    /// Parses one line; nil for anything that isn't a message we know.
    public static func parse(_ line: String) -> HelperMessage? {
        guard let data = line.data(using: .utf8),
              let s = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = s["type"] as? String
        else { return nil }
        func str(_ key: String) -> String { s[key] as? String ?? "" }
        func num(_ key: String) -> Double { (s[key] as? NSNumber)?.doubleValue ?? 0 }
        func bool(_ key: String) -> Bool? { (s[key] as? NSNumber).map(\.boolValue) }
        switch type {
        case "state":
            return .state(VoiceState(json: s))
        case "level":
            return .level(min(max(num("value"), 0), 1))
        case "preview":
            return .preview(str("text"))
        case "result":
            return .result(DictationResult(
                text: str("text"), raw: str("raw"), app: str("app"), bundleId: str("bundleId"),
                model: str("model"), seconds: num("seconds"), elapsedMs: Int(num("elapsedMs")),
                typed: bool("typed") ?? true, secure: bool("secure") ?? false, method: str("method")))
        case "model":
            return .model(id: str("model"), state: ModelState(rawValue: str("state")) ?? .unknown, message: str("message"))
        case "download":
            return .download(model: str("model"), progress: num("progress"), done: bool("done") ?? false,
                             error: s["error"] == nil ? nil : str("error"))
        case "access":
            let fn: Int?? = s.keys.contains("fnUsage") ? .some((s["fnUsage"] as? NSNumber)?.intValue) : .none
            return .access(shortcut: bool("shortcut"), polish: bool("polish"), fnUsage: fn)
        case "shortcut":
            guard let raw = s["shortcut"] as? [String: Any] else { return nil }
            let shortcut = VoiceShortcut(
                key: (raw["key"] as? NSNumber)?.intValue, button: (raw["button"] as? NSNumber)?.intValue,
                modifiers: raw["modifiers"] as? [String] ?? [])
            return .shortcut(shortcut, label: str("label"))
        case "devices":
            let list = s["devices"] as? [[String: Any]] ?? []
            return .devices(list.map {
                VoiceDevice(uid: $0["uid"] as? String ?? "", name: $0["name"] as? String ?? "",
                            isDefault: ($0["isDefault"] as? NSNumber)?.boolValue ?? false)
            })
        default:
            return nil
        }
    }
}

/// Splits a pipe's bytes into lines. A line that isn't UTF-8 is read
/// lossily: stopping there would leave stderr undrained (the helper blocks
/// once the pipe fills) or stdout taken for a dead helper.
public struct LineSplitter: Sendable {
    private var pending = Data()

    public init() {}

    public mutating func append(_ chunk: Data) -> [String] {
        pending.append(chunk)
        var lines: [String] = []
        while let end = pending.firstIndex(of: 0x0A) {
            var line = pending[pending.startIndex..<end]
            if line.last == 0x0D { line = line.dropLast() }
            lines.append(String(decoding: line, as: UTF8.self))
            pending.removeSubrange(pending.startIndex...end)
        }
        return lines
    }

    /// What's left when the pipe closes without a final newline.
    public mutating func finish() -> [String] {
        defer { pending.removeAll() }
        return pending.isEmpty ? [] : [String(decoding: pending, as: UTF8.self)]
    }
}
