import AppKit
import Carbon.HIToolbox

/// A keyboard shortcut that works in every app: a key and its modifiers.
public struct Hotkey: Codable, Hashable, Sendable {
    public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1 << 0)
        public static let control = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let shift = Modifiers(rawValue: 1 << 3)
    }

    /// The virtual key code (`kVK_…`), independent of the keyboard layout.
    public var keyCode: UInt32
    public var modifiers: Modifiers

    public init(keyCode: UInt32, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// ⌥Space: free on a stock Mac (⌘Space belongs to Spotlight until it's handed over).
    public static let defaultBar = Hotkey(keyCode: UInt32(kVK_Space), modifiers: .option)
    /// Spotlight's own.
    public static let commandSpace = Hotkey(keyCode: UInt32(kVK_Space), modifiers: .command)

    /// Keys a global shortcut may end in, with their names.
    static let keys: [(UInt32, String)] = {
        let letters: [(Int, String)] = [
            (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"), (kVK_ANSI_E, "E"),
            (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"), (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"),
            (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"), (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"),
            (kVK_ANSI_P, "P"), (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"), (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"),
            (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"), (kVK_ANSI_Y, "Y"),
            (kVK_ANSI_Z, "Z"),
            (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"), (kVK_ANSI_4, "4"),
            (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"), (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"),
            (kVK_Space, "Space"),
            (kVK_F1, "F1"), (kVK_F2, "F2"), (kVK_F3, "F3"), (kVK_F4, "F4"), (kVK_F5, "F5"), (kVK_F6, "F6"),
            (kVK_F7, "F7"), (kVK_F8, "F8"), (kVK_F9, "F9"), (kVK_F10, "F10"), (kVK_F11, "F11"), (kVK_F12, "F12"),
            (kVK_F13, "F13"), (kVK_F14, "F14"), (kVK_F15, "F15"), (kVK_F16, "F16"), (kVK_F17, "F17"),
            (kVK_F18, "F18"), (kVK_F19, "F19"), (kVK_F20, "F20"),
        ]
        return letters.map { (UInt32($0.0), $0.1) }
    }()

    public var keyName: String { Self.keys.first { $0.0 == keyCode }?.1 ?? "Key \(keyCode)" }

    /// The keycaps it's drawn as, in the order macOS writes them: ["⌥", "Space"].
    public var glyphs: [String] {
        var mods = ""
        if modifiers.contains(.control) { mods += "⌃" }
        if modifiers.contains(.option) { mods += "⌥" }
        if modifiers.contains(.shift) { mods += "⇧" }
        if modifiers.contains(.command) { mods += "⌘" }
        return mods.map(String.init) + [keyName]
    }

    /// "⌥Space", "⌃⌥K".
    public var label: String { glyphs.joined() }

    /// The saved notation: "Alt+Space", "Command+Shift+K".
    public var notation: String {
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("Command") }
        if modifiers.contains(.control) { parts.append("Control") }
        if modifiers.contains(.option) { parts.append("Alt") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        return (parts + [keyName]).joined(separator: "+")
    }

    /// Reads the saved notation ("Alt+Space", "CommandOrControl+Shift+K").
    public init?(notation: String) {
        var mods: Modifiers = []
        let parts = notation.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.last, !key.isEmpty else { return nil }
        for part in parts.dropLast() {
            switch part.lowercased() {
            case "command", "cmd", "super", "meta", "commandorcontrol", "cmdorctrl": mods.insert(.command)
            case "control", "ctrl": mods.insert(.control)
            case "alt", "option", "opt": mods.insert(.option)
            case "shift": mods.insert(.shift)
            default: return nil
            }
        }
        let name = key.count == 1 ? key.uppercased() : key.prefix(1).uppercased() + key.dropFirst().lowercased()
        guard let code = Self.keys.first(where: { $0.1.caseInsensitiveCompare(name) == .orderedSame })?.0 else { return nil }
        self.init(keyCode: code, modifiers: mods)
    }

    /// A key press, when it can be a global shortcut: a key from the list,
    /// with ⌘, ⌃ or ⌥ (Shift alone would swallow capital letters).
    public init?(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        var mods: Modifiers = []
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.shift) { mods.insert(.shift) }
        guard Self.keys.contains(where: { $0.0 == UInt32(keyCode) }) else { return nil }
        self.init(keyCode: UInt32(keyCode), modifiers: mods)
    }

    /// Why this can't open the bar from every app, or nil when it can.
    public var problem: String? {
        guard !modifiers.isDisjoint(with: [.command, .control, .option]) else {
            return "Use ⌘, ⌃ or ⌥ with it, so it never types into a field."
        }
        if modifiers == .command, ["C", "V", "X", "Z", "A", "Q", "W", "H", "M", "Tab"].contains(keyName) {
            return "Every app uses ⌘\(keyName)."
        }
        if modifiers == [.command, .shift], ["3", "4", "5"].contains(keyName) {
            return "macOS uses \(label) for screenshots."
        }
        return nil
    }
}

/// Global hotkeys through Carbon's `RegisterEventHotKey`: no Accessibility
/// or Input Monitoring needed, and the key never reaches the app in front.
@MainActor
public final class GlobalHotkey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var installed = false

    private var ref: EventHotKeyRef?
    private let id: UInt32
    public private(set) var hotkey: Hotkey?

    public init(_ action: @escaping () -> Void) {
        id = Self.nextID
        Self.nextID += 1
        Self.handlers[id] = action
        Self.installHandler()
    }

    /// Registers `hotkey` in place of the current one. The new one first: a
    /// shortcut macOS refuses leaves the old one working. Throws with the
    /// reason when another app holds it.
    public func register(_ hotkey: Hotkey?) throws {
        guard hotkey != self.hotkey else { return }
        guard let hotkey else {
            unregister()
            return
        }
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(hotkey.keyCode, Self.carbon(hotkey.modifiers),
                                         EventHotKeyID(signature: OSType(0x5445_5945), id: id),  // "TEYE"
                                         GetEventDispatcherTarget(), 0, &newRef)
        guard status == noErr, let newRef else {
            throw LowtideError.denied(status == eventHotKeyExistsErr
                ? "Another app already uses \(hotkey.label)."
                : "macOS wouldn't give Lowtide \(hotkey.label) (\(status)).")
        }
        if let ref { UnregisterEventHotKey(ref) }
        ref = newRef
        self.hotkey = hotkey
    }

    public func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        hotkey = nil
    }

    static func carbon(_ m: Hotkey.Modifiers) -> UInt32 {
        var out = 0
        if m.contains(.command) { out |= cmdKey }
        if m.contains(.control) { out |= controlKey }
        if m.contains(.option) { out |= optionKey }
        if m.contains(.shift) { out |= shiftKey }
        return UInt32(out)
    }

    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let id = hotKeyID.id
            // Carbon calls this on the main thread's event loop.
            MainActor.assumeIsolated { GlobalHotkey.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
