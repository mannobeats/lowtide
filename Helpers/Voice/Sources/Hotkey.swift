import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// What starts dictation: a key with modifiers (⌃⌥Space), modifiers alone
/// (Right ⌥, fn), or a mouse button. Modifiers alone are told apart by side,
/// so Right ⌥ can dictate while Left ⌥ keeps typing accents.
struct Shortcut: Equatable {
    var key: Int?
    var button: Int?
    var modifiers: Set<String>

    static let fallback = Shortcut(key: nil, button: nil, modifiers: ["rightOption"])

    init(key: Int?, button: Int?, modifiers: Set<String>) {
        self.key = key
        self.button = button
        self.modifiers = modifiers
    }

    init?(_ json: Any?) {
        guard let json = json as? [String: Any] else { return nil }
        key = json["key"] as? Int
        button = json["button"] as? Int
        modifiers = Set(json["modifiers"] as? [String] ?? [])
        if key == nil && button == nil && modifiers.isEmpty { return nil }
    }

    var json: [String: Any] {
        var out: [String: Any] = ["modifiers": modifiers.sorted()]
        if let key { out["key"] = key }
        if let button { out["button"] = button }
        return out
    }

    var modifiersOnly: Bool { key == nil && button == nil }

    /// "⌃⌥ Space", "Right ⌥", "fn", "⌘ Mouse 4".
    var label: String {
        if modifiersOnly {
            return Keys.order.filter(modifiers.contains).map(Keys.sided).joined(separator: " ")
        }
        let held = Keys.generic.filter { generic in modifiers.contains { Keys.base($0) == generic } }
            .map { Keys.symbol[$0] ?? $0 }.joined()
        let main = button.map { "Mouse \($0 + 1)" } ?? key.map(Keys.name) ?? ""
        return held.isEmpty ? main : "\(held) \(main)"
    }

    /// Modifiers ignoring side, for key and mouse shortcuts.
    var generic: Set<String> { Set(modifiers.map(Keys.base)) }

    /// Carbon can hold this while Secure Input hides the event tap: a
    /// keyboard key and no fn (Carbon can't hold it). A mouse button or a
    /// modifier alone has no chord to register. A bare key is taken too:
    /// the tap already swallows it, so grabbing it changes nothing.
    var secureChord: Bool {
        guard let key, button == nil, (0...127).contains(key) else { return false }
        return !generic.contains("fn")
    }

    /// The Carbon modifier bits for this shortcut.
    var carbonModifiers: UInt32 {
        var out: UInt32 = 0
        if generic.contains("command") { out |= UInt32(cmdKey) }
        if generic.contains("option") { out |= UInt32(optionKey) }
        if generic.contains("control") { out |= UInt32(controlKey) }
        if generic.contains("shift") { out |= UInt32(shiftKey) }
        return out
    }
}

enum Keys {
    /// Device-dependent modifier bits (IOKit's NX_DEVICE…KEYMASK), plus fn.
    static let bits: [(String, UInt64)] = [
        ("leftControl", 0x0001), ("rightControl", 0x2000),
        ("leftShift", 0x0002), ("rightShift", 0x0004),
        ("leftCommand", 0x0008), ("rightCommand", 0x0010),
        ("leftOption", 0x0020), ("rightOption", 0x0040),
        ("fn", CGEventFlags.maskSecondaryFn.rawValue),
    ]
    static let order = bits.map(\.0)
    static let generic = ["control", "option", "shift", "command", "fn"]
    static let symbol = ["control": "⌃", "option": "⌥", "shift": "⇧", "command": "⌘", "fn": "fn"]

    static func base(_ name: String) -> String {
        for prefix in ["left", "right"] where name.hasPrefix(prefix) {
            return name.dropFirst(prefix.count).lowercased()
        }
        return name
    }

    static func sided(_ name: String) -> String {
        let generic = base(name)
        let symbol = symbol[generic] ?? generic
        if name.hasPrefix("left") { return "Left \(symbol)" }
        if name.hasPrefix("right") { return "Right \(symbol)" }
        return symbol
    }

    static func pressed(_ flags: CGEventFlags) -> Set<String> {
        Set(bits.filter { flags.rawValue & $0.1 != 0 }.map(\.0))
    }

    /// Function keys work alone as a shortcut.
    static let functionKeys: Set<Int> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
    /// Keys macOS marks with fn by itself (arrows, Home, End, Page Up and
    /// Down, Forward Delete, Help and the F-keys): fn on them proves nothing.
    static let implicitFn: Set<Int> = functionKeys.union([123, 124, 125, 126, 115, 119, 116, 121, 117, 114])

    /// What is really held: the fn macOS adds to arrows and the like by
    /// itself isn't a modifier the shortcut asked for.
    static func realModifiers(key: Int, held: Set<String>) -> Set<String> {
        implicitFn.contains(key) ? held.subtracting(["fn"]) : held
    }

    /// Side-agnostic modifiers of a key event.
    static func held(_ flags: CGEventFlags) -> Set<String> {
        var out = Set<String>()
        if flags.contains(.maskControl) { out.insert("control") }
        if flags.contains(.maskAlternate) { out.insert("option") }
        if flags.contains(.maskShift) { out.insert("shift") }
        if flags.contains(.maskCommand) { out.insert("command") }
        if flags.contains(.maskSecondaryFn) { out.insert("fn") }
        return out
    }

    private static let special: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab", kVK_Delete: "Delete",
        kVK_ForwardDelete: "⌦", kVK_Escape: "Esc", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "Home", kVK_End: "End",
        kVK_PageUp: "Page Up", kVK_PageDown: "Page Down", kVK_CapsLock: "Caps Lock",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20", kVK_ANSI_KeypadEnter: "Enter",
    ]

    /// The key of each side-specific modifier, to ask whether it's still down.
    private static let sidedCodes: [String: Int] = [
        "leftControl": kVK_Control, "rightControl": kVK_RightControl,
        "leftShift": kVK_Shift, "rightShift": kVK_RightShift,
        "leftCommand": kVK_Command, "rightCommand": kVK_RightCommand,
        "leftOption": kVK_Option, "rightOption": kVK_RightOption,
    ]

    static func name(_ key: Int) -> String {
        special[key] ?? character(key)?.uppercased() ?? "Key \(key)"
    }

    /// What a key types on the current layout, without modifiers.
    static func character(_ key: Int) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        return translate(source, key, 0).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    /// `state` is UCKeyTranslate's modifier byte: 0 plain, 1 ⌘, 2 ⇧.
    private static func translate(_ source: TISInputSource, _ key: Int, _ state: UInt32) -> String? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var dead: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(
                layout, UInt16(key), UInt16(kUCKeyActionDisplay), state, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }

    // MARK: Layout map (a port of Hex's `keyboard.rs`, MIT)

    struct Layout {
        var plain: [Character: Int] = [:]
        var command: [Character: Int] = [:]
        var shift: [Character: Int] = [:]
    }

    private static let layoutLock = NSLock()
    private static var cached: Layout?

    /// Builds the map now and again whenever the input source changes (main
    /// thread: TIS isn't safe elsewhere); every lookup reads the cache.
    static func watchLayout() {
        rebuildLayout()
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { _ in rebuildLayout() }
    }

    private static func rebuildLayout() {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return }
        func collect(_ source: TISInputSource, _ state: UInt32) -> [Character: Int] {
            var codes: [Character: Int] = [:]
            for key in 0..<128 {
                guard let first = translate(source, key, state)?.first else { continue }
                // The ⇧ layer keeps its case: "A" and "!" are what it types.
                let character = state == 2 ? first : Character(first.lowercased())
                if codes[character] == nil { codes[character] = key }
            }
            return codes
        }
        var layout = Layout(plain: collect(source, 0), command: collect(source, 1), shift: collect(source, 2))
        // Russian, Hebrew, Greek…: no Latin letters on the plain layer, so ⌘V
        // would have no key. AppKit falls back to the ASCII-capable layout.
        if "abcdefghijklmnopqrstuvwxyz".contains(where: { layout.plain[$0] == nil }),
           let ascii = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        {
            for (character, key) in collect(ascii, 0) where character.isASCII && character.isLetter {
                if layout.plain[character] == nil { layout.plain[character] = key }
            }
        }
        layoutLock.lock()
        cached = layout
        layoutLock.unlock()
    }

    static var layout: Layout {
        layoutLock.lock()
        defer { layoutLock.unlock() }
        return cached ?? Layout()
    }

    /// The key that types `character`, on the ⌘ layer for a ⌘ shortcut (V
    /// for paste on Dvorak isn't where it is on QWERTY, and Dvorak-QWERTY ⌘
    /// moves it again).
    static func code(for character: Character, command: Bool) -> Int? {
        let layout = layout
        let lower = Character(character.lowercased())
        return (command ? layout.command[lower] : nil) ?? layout.plain[lower]
    }

    /// Whether the keyboard and mouse read as fully at rest: no modifier, no
    /// key, no button down. Checking the shortcut's own keys instead ended
    /// holds that were still going (a swallowed key and a modifier's key code
    /// don't read reliably), so a release counts as missed only when nothing
    /// at all is held (Hex's `recover_stale_keys`, MIT).
    static func neutral() -> Bool {
        let modifiers: CGEventFlags = [
            .maskCommand, .maskShift, .maskAlternate, .maskControl, .maskSecondaryFn,
        ]
        guard CGEventSource.flagsState(.combinedSessionState).isDisjoint(with: modifiers) else { return false }
        if (0..<128).contains(where: { CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0)) }) {
            return false
        }
        return !(0..<32).contains(where: {
            CGMouseButton(rawValue: UInt32($0)).map { CGEventSource.buttonState(.combinedSessionState, button: $0) }
                ?? false
        })
    }

    /// System Settings → Keyboard → "Press 🌐 key to": 0 is Do Nothing; nil
    /// is unset, where macOS acts on it. Anything but 0 also fires when fn
    /// is the dictation shortcut.
    static func fnUsage() -> Int? {
        let domain = "com.apple.HIToolbox" as CFString
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, domain) as? Int
    }
}

/// Uptime in nanoseconds: what event-tap timestamps and audio host times
/// both convert to.
enum Clock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    /// nil when `ticks` is too large to convert: a plain `*` would trap on
    /// overflow, and a bogus event timestamp would crash the tap's thread.
    static func nanos(ticks: UInt64) -> UInt64? {
        let (product, overflow) = ticks.multipliedReportingOverflow(by: UInt64(timebase.numer))
        return overflow ? nil : product / UInt64(max(1, timebase.denom))
    }

    /// Session-tap timestamps are nanoseconds, though some arrive as Mach
    /// ticks; take whichever reads as recent, else now.
    static func event(_ raw: UInt64) -> UInt64 {
        let now = now()
        for candidate in [raw, nanos(ticks: raw)].compactMap({ $0 })
        where candidate <= now && now - candidate < 5_000_000_000 {
            return candidate
        }
        return now
    }

    static func seconds(_ from: UInt64, _ to: UInt64) -> Double {
        to >= from ? Double(to - from) / 1e9 : -Double(from - to) / 1e9
    }
}

/// While another app holds Secure Event Input (a focused password field, or a
/// browser that never let go), macOS stops handing key presses to event taps;
/// modifier changes still arrive. Carbon hotkeys are matched before that
/// filter, so while Secure Input is on the shortcut is registered with Carbon
/// and its press and release go where the tap would have sent them (Hex's
/// `suppression/secure_input.rs`, MIT). Only then: a Carbon hotkey takes its
/// key ahead of the tap, so otherwise the tap keeps its own rules.
@MainActor
final class SecureChord {
    static let shared = SecureChord()

    private var ref: EventHotKeyRef?
    private var registered: Shortcut?
    private var held = false
    private var installed = false

    /// Set while recording a shortcut: the keys belong to the recorder, so
    /// no hotkey is registered over them.
    var listening = false

    /// On the main thread, once.
    func start() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == OSType(0x5445_5945) else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { SecureChord.shared.pressed() }
            return noErr
        }, 1, &spec, nil, nil)
        var released = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == OSType(0x5445_5945) else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { SecureChord.shared.released() }
            return noErr
        }, 1, &released, nil, nil)
        poll()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { SecureChord.shared.poll() }
        }
    }

    /// Registers (or drops) the hotkey as Secure Input comes and goes, the
    /// shortcut changes, or a recorder takes the keys.
    func poll() {
        let secure = IsSecureEventInputEnabled()
        let shortcut = Hotkey.shared.shortcut
        let wanted = secure && !listening && shortcut.secureChord ? shortcut : nil
        guard wanted != registered else { return }
        unregister()
        guard let wanted else { return }
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(wanted.key ?? 0), wanted.carbonModifiers,
            EventHotKeyID(signature: OSType(0x5445_5945), id: 1),
            GetApplicationEventTarget(), 0, &newRef)
        guard status == noErr, let newRef else {
            Log.event("secure", ["action": "refused", "shortcut": wanted.label, "status": Int(status)])
            return
        }
        ref = newRef
        registered = wanted
        Log.event("secure", ["action": "registered", "shortcut": wanted.label])
    }

    private func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        if let registered { Log.event("secure", ["action": "dropped", "shortcut": registered.label]) }
        ref = nil
        registered = nil
        // A hold that was going when it let go ends now, as Hex does.
        if held {
            held = false
            Hotkey.shared.deliver(.release, at: Clock.now())
        }
    }

    fileprivate func pressed() {
        guard !held else { return }
        held = true
        Log.event("secure", ["action": "press"])
        Hotkey.shared.deliver(.press, at: Clock.now())
    }

    fileprivate func released() {
        guard held else { return }
        held = false
        Log.event("secure", ["action": "release"])
        Hotkey.shared.deliver(.release, at: Clock.now())
    }
}

/// Events the shortcut produces.
enum HotkeyEvent {
    case press
    case release
    /// Another key went with a modifiers-only shortcut: it was a key combo.
    case interrupted
    case escape
    /// The tap lost track (macOS disabled it, or the key's release never
    /// came): a hold in progress has ended.
    case lost
}

/// Session-wide event taps (need Accessibility) on a thread of its own,
/// so a busy main thread never makes macOS time it out. It only swallows
/// what it uses: the shortcut's own key or button, and Esc while
/// dictating. A health check every 5 s re-enables or recreates it, and a
/// change of Accessibility rebuilds it (ported from Hex's
/// `suppression/tap.rs`, MIT).
final class Hotkey: @unchecked Sendable {
    static let shared = Hotkey()
    /// Marks the keys this helper posts itself (⌘V, typing), so the tap ignores them.
    static let tag: Int64 = 0x5746_564F

    /// On the main thread, with when it happened (`Clock` nanoseconds).
    var onEvent: ((HotkeyEvent, UInt64) -> Void)?
    /// On the main thread, when `running` changes.
    var onAccess: ((Bool) -> Void)?

    private let lock = NSLock()
    private var shortcutValue = Shortcut.fallback
    private var escapeValue = false
    private var recorder: ((Shortcut) -> Void)?
    private var recordedModifiers = Set<String>()
    private var active = false
    private var runningValue = false

    // The tap thread's own.
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    /// The key tap (filters: swallows the shortcut and Esc) and the modifier
    /// tap (listen-only). Modifiers go to a passive tap as in Hex: a filtering
    /// one breaks Finder's ⌥ menu items and goes deaf to modifiers under
    /// Secure Input.
    private var taps: [(port: CFMachPort, source: CFRunLoopSource)] = []
    /// When the stale check first read the keyboard at rest during a hold.
    private var neutralSince: UInt64?
    private var trusted = false
    private var activity: NSObjectProtocol?
    /// What reached the tap since the last report, by kind (never which
    /// key): tells "nothing arrives" apart from "arrives but doesn't match".
    private var heard = (keys: 0, modifiers: 0, mouse: 0)

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Changing it lets go of whatever was held.
    var shortcut: Shortcut {
        get { locked { shortcutValue } }
        set { locked { shortcutValue = newValue; active = false } }
    }

    /// Esc is swallowed only while this is true.
    var capturingEscape: Bool {
        get { locked { escapeValue } }
        set { locked { escapeValue = newValue } }
    }

    /// A key press that came through the Carbon fallback, since the tap
    /// can't see one while Secure Input is on: taken as the tap would.
    func deliver(_ event: HotkeyEvent, at: UInt64) {
        emit(event, at)
    }

    /// A valid, enabled tap.
    var running: Bool { locked { runningValue } }

    /// The next shortcut pressed goes to `report` (main thread) instead.
    func record(_ report: @escaping (Shortcut) -> Void) {
        locked { recorder = report; recordedModifiers = [] }
    }

    func stopRecording() {
        locked { recorder = nil; recordedModifiers = [] }
    }

    /// Main thread; once.
    func start() {
        guard thread == nil else { return }
        let thread = Thread { [unowned self] in self.run() }
        thread.name = "voice-hotkey"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    private func run() {
        // A napped helper can miss the tap's deadline; idle sleep stays allowed.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Lowtide listens for the dictation shortcut")
        runLoop = CFRunLoopGetCurrent()
        trusted = AXIsProcessTrusted()
        Log.event("access", [
            "trusted": trusted, "listen": CGPreflightListenEventAccess(),
            "post": CGPreflightPostEventAccess(), "secure": IsSecureEventInputEnabled(),
        ])
        attach()
        repeatEvery(10) { [unowned self] in self.reportHeard() }
        repeatEvery(5) { [unowned self] in self.checkHealth() }
        repeatEvery(2) { [unowned self] in self.checkAccess() }
        repeatEvery(0.5) { [unowned self] in self.checkStale() }
        CFRunLoopRun()
    }

    private func repeatEvery(_ seconds: TimeInterval, _ body: @escaping () -> Void) {
        let timer = Timer(timeInterval: seconds, repeats: true) { _ in body() }
        RunLoop.current.add(timer, forMode: .common)
    }

    private func attach() {
        func mask(_ types: [CGEventType]) -> CGEventMask { types.reduce(0) { $0 | (1 << $1.rawValue) } }
        let specs: [(CGEventTapOptions, CGEventMask)] = [
            (.defaultTap, mask([.keyDown, .keyUp, .otherMouseDown, .otherMouseUp, .leftMouseDown])),
            (.listenOnly, mask([.flagsChanged])),
        ]
        for (options, events) in specs {
            guard let port = CGEvent.tapCreate(
                tap: .cgAnnotatedSessionEventTap, place: .headInsertEventTap, options: options,
                eventsOfInterest: events, callback: { _, type, event, refcon in
                    Unmanaged<Hotkey>.fromOpaque(refcon!).takeUnretainedValue().handle(type, event)
                }, userInfo: Unmanaged.passUnretained(self).toOpaque())
            else {
                detach()
                setRunning(false)
                return
            }
            let source = CFMachPortCreateRunLoopSource(nil, port, 0)!
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            taps.append((port, source))
        }
        let enabled = taps.allSatisfy { CGEvent.tapIsEnabled(tap: $0.port) }
        Log.event("tap", ["action": "create", "enabled": enabled])
        setRunning(enabled)
    }

    private func detach() {
        lost()
        for (port, source) in taps {
            CGEvent.tapEnable(tap: port, enable: false)
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            CFMachPortInvalidate(port)
        }
        taps = []
    }

    private func setRunning(_ value: Bool) {
        let changed = locked { () -> Bool in
            defer { runningValue = value }
            return runningValue != value
        }
        guard changed else { return }
        Log.event("tap", ["action": value ? "running" : "stopped"])
        DispatchQueue.main.async { self.onAccess?(value) }
    }

    /// Whatever was held no longer counts; a hold in progress ends.
    private func lost() {
        let was = locked { () -> Bool in
            defer { active = false; recordedModifiers = [] }
            return active
        }
        if was { emit(.lost, Clock.now()) }
    }

    /// macOS can disable or invalidate a tap without telling it (after
    /// sleep, Secure Input, an Accessibility change).
    private func checkHealth() {
        if taps.isEmpty || taps.contains(where: { !CFMachPortIsValid($0.port) }) {
            if !taps.isEmpty { Log.event("tap", ["action": "recreate", "reason": "invalid"]) }
            detach()
            attach()
            return
        }
        for (port, _) in taps where !CGEvent.tapIsEnabled(tap: port) {
            CGEvent.tapEnable(tap: port, enable: true)
            let enabled = CGEvent.tapIsEnabled(tap: port)
            Log.event("tap", ["action": "reenable", "reason": "health", "enabled": enabled])
            lost()
            if !enabled {
                detach()
                attach()
                return
            }
        }
        setRunning(true)
    }

    /// A tap made before Accessibility was granted (or re-granted after a
    /// rebuild of the app) never sees a key: make a new one.
    private func checkAccess() {
        let now = AXIsProcessTrusted()
        guard now != trusted else { return }
        trusted = now
        Log.event("access", ["trusted": now])
        detach()
        if now { attach() } else { setRunning(false) }
    }

    private func reportHeard() {
        let counts = locked { () -> (keys: Int, modifiers: Int, mouse: Int) in
            defer { heard = (0, 0, 0) }
            return heard
        }
        guard counts.keys + counts.modifiers + counts.mouse > 0 else { return }
        Log.event("tap", [
            "action": "heard", "keys": counts.keys, "modifiers": counts.modifiers, "mouse": counts.mouse,
            "secure": IsSecureEventInputEnabled(),
        ])
    }

    /// A hold whose release never arrived (swallowed by a system shortcut
    /// or Secure Input) ends once the keyboard has read neutral on two checks
    /// in a row; one neutral read can race a press in flight.
    private func checkStale() {
        let held = locked { active }
        guard held, Keys.neutral() else {
            neutralSince = nil
            return
        }
        let now = Clock.now()
        guard let since = neutralSince else {
            neutralSince = now
            return
        }
        guard Clock.seconds(since, now) >= 0.4 else { return }
        neutralSince = nil
        Log.event("tap", ["action": "stale-key"])
        lost()
    }

    private func emit(_ event: HotkeyEvent, _ at: UInt64) {
        Log.event("hotkey", ["kind": "\(event)"])
        DispatchQueue.main.async { self.onEvent?(event, at) }
    }

    /// The tap's callback: decides what to swallow and hands the rest to
    /// the main thread. Nothing slow happens here.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            for (port, _) in taps { CGEvent.tapEnable(tap: port, enable: true) }
            Log.event("tap", ["action": "reenable", "reason": type == .tapDisabledByTimeout ? "timeout" : "user-input"])
            lost()
            return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == Hotkey.tag { return pass }
        let at = Clock.event(event.timestamp)
        lock.lock()
        switch type {
        case .keyDown, .keyUp: heard.keys += 1
        case .flagsChanged: heard.modifiers += 1
        default: heard.mouse += 1
        }
        let (swallow, produced, recorded) = decide(type, event)
        let report = recorded == nil ? nil : recorder
        if recorded != nil { recorder = nil }
        lock.unlock()
        if let produced { emit(produced, at) }
        if let recorded, let report { DispatchQueue.main.async { report(recorded) } }
        return swallow ? nil : pass
    }

    /// Under `lock`.
    private func decide(_ type: CGEventType, _ event: CGEvent) -> (Bool, HotkeyEvent?, Shortcut?) {
        if recorder != nil { return record(type, event) }
        let shortcut = shortcutValue
        switch type {
        case .flagsChanged:
            guard shortcut.modifiersOnly else { return (false, nil, nil) }
            let now = Keys.pressed(event.flags) == shortcut.modifiers
            guard now != active else { return (false, nil, nil) }
            active = now
            return (false, now ? .press : .release, nil)
        case .keyDown, .keyUp:
            let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if key == kVK_Escape && escapeValue {
                return (true, type == .keyDown ? .escape : nil, nil)
            }
            if shortcut.modifiersOnly {
                return (false, type == .keyDown && active ? .interrupted : nil, nil)
            }
            guard key == shortcut.key, Keys.realModifiers(key: key, held: Keys.held(event.flags)) == shortcut.generic else {
                // The shortcut's key let go after its modifiers.
                if type == .keyUp && key == shortcut.key && active {
                    active = false
                    return (true, .release, nil)
                }
                return (false, nil, nil)
            }
            if type == .keyDown {
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 && !active {
                    active = true
                    return (true, .press, nil)
                }
            } else if active {
                active = false
                return (true, .release, nil)
            }
            return (true, nil, nil)
        case .otherMouseDown, .otherMouseUp:
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            guard button == shortcut.button, Keys.held(event.flags) == shortcut.generic else {
                return (false, nil, nil)
            }
            if type == .otherMouseDown, !active {
                active = true
                return (true, .press, nil)
            } else if type == .otherMouseUp, active {
                active = false
                return (true, .release, nil)
            }
            return (true, nil, nil)
        case .leftMouseDown:
            return (false, shortcut.modifiersOnly && active ? .interrupted : nil, nil)
        default:
            return (false, nil, nil)
        }
    }

    /// Recording a new shortcut: a key (with what's held) ends it at once;
    /// modifiers alone end it when all are let go, as the most held together.
    private func record(_ type: CGEventType, _ event: CGEvent) -> (Bool, HotkeyEvent?, Shortcut?) {
        var done: Shortcut?
        switch type {
        case .flagsChanged:
            let pressed = Keys.pressed(event.flags)
            if pressed.isEmpty, !recordedModifiers.isEmpty {
                done = Shortcut(key: nil, button: nil, modifiers: recordedModifiers)
            } else if pressed.count >= recordedModifiers.count {
                recordedModifiers = pressed
            }
        case .keyDown:
            let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
            // Esc cancels (it passes through to Lowtide); every other key can
            // be a shortcut, bare ones included. The page warns when a bare
            // key gives up the character it types.
            guard key != kVK_Escape else { return (false, nil, nil) }
            let held = Keys.realModifiers(key: key, held: Keys.held(event.flags))
            done = Shortcut(key: key, button: nil, modifiers: held)
        case .otherMouseDown:
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            done = Shortcut(key: nil, button: button, modifiers: Keys.held(event.flags))
        case .leftMouseDown:
            return (false, nil, nil)
        default:
            break
        }
        if done != nil { recordedModifiers = [] }
        return (type != .flagsChanged, nil, done)
    }
}
