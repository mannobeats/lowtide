import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Puts text into whatever has focus the way Hex does (`paste.rs`,
/// `keyboard.rs`, MIT): the clipboard marked transient, one ⌘V at once, the
/// clipboard back 500 ms later. No reading the field first and no second
/// way after: checking delayed the paste, and a fallback after a slow paste
/// put the text in twice or somewhere else. VMs and remote screens get key
/// events, and so does Chromium 155–156, which drops a fast ⌘V.
@MainActor
enum Insert {
    struct Focus {
        var pid: pid_t?
        var bundle = ""
        var name = ""
        var url: URL?
        var element: AXUIElement?
        var role: String?
        var secure = false
    }

    struct Outcome {
        /// "paste", "typed", "copied"; nil when nothing was put anywhere (a
        /// password field).
        var method: String?
        var app: String
        var bundle: String
        /// Focus moved to another app since the take began.
        var moved = false
        /// An error kind for the overlay (see `voice/mod.rs` `VoiceState`).
        var kind: String?
        var message = ""
    }

    // MARK: Focus

    /// The app and element with keyboard focus now.
    static func focus() -> Focus {
        let system = AXUIElementCreateSystemWide()
        // Setting it on the system-wide element sets it for every element.
        AXUIElementSetMessagingTimeout(system, 0.25)
        var focus = Focus()
        focus.element = element(system, kAXFocusedUIElementAttribute)
        var pid: pid_t = 0
        let app = focus.element.flatMap { AXUIElementGetPid($0, &pid) == .success ? NSRunningApplication(processIdentifier: pid) : nil }
            ?? NSWorkspace.shared.frontmostApplication
        focus.pid = app?.processIdentifier
        focus.bundle = app?.bundleIdentifier ?? ""
        focus.name = app?.localizedName ?? ""
        focus.url = app?.bundleURL
        if let element = focus.element {
            focus.role = attribute(element, kAXRoleAttribute)
            let subrole: String? = attribute(element, kAXSubroleAttribute)
            focus.secure = focus.role == kAXSecureTextFieldSubrole || subrole == kAXSecureTextFieldSubrole
        }
        return focus
    }

    // MARK: Delivering

    /// Puts `text` where focus is now (`start` is where it was when the take
    /// began, so the result can say it moved). `done` runs on the main thread.
    static func deliver(_ text: String, from start: Focus?, done: @escaping @MainActor (Outcome) -> Void) {
        let began = Clock.now()
        // The shortcut's modifiers, still held, would turn ⌘V into ⌥⌘V.
        waitForModifiers(until: began + 300_000_000) {
            let now = focus()
            var outcome = Outcome(
                app: now.name, bundle: now.bundle,
                moved: start.map { $0.pid != nil && $0.pid != now.pid } ?? false)
            @MainActor func finish() {
                Log.event("insert", [
                    "method": outcome.method ?? "none", "bundle": now.bundle,
                    "role": now.role ?? "", "moved": outcome.moved, "kind": outcome.kind ?? "",
                    "ms": Int(Clock.seconds(began, Clock.now()) * 1000),
                ])
                done(outcome)
            }
            guard AXIsProcessTrusted() else {
                Clipboard.shared.keep(text)
                outcome.method = "copied"
                outcome.kind = "permission"
                outcome.message = "Lowtide needs Accessibility to type into apps. The text is on the clipboard."
                return finish()
            }
            if now.secure {
                outcome.kind = "secure-input"
                outcome.message = "A password field has focus, so nothing was typed or kept."
                return finish()
            }
            if now.pid == nil {
                Clipboard.shared.keep(text)
                outcome.method = "copied"
                outcome.kind = "no-focus"
                outcome.message = "Nothing had a text field in focus. The text is on the clipboard."
                return finish()
            }
            // Electron with Accessibility off, games, Qt and Java apps report
            // only the window: no caret to read there.
            let field = ["AXWindow", "AXApplication", "AXSheet"].contains(now.role ?? "") ? nil : now.element
            let fitted = field.map { Text.fitted(text, after: before(caretOf: $0)) } ?? text
            let route = strategy(for: now)
            if route == .paste {
                let generation = Clipboard.shared.put(fitted)
                outcome.method = "paste"
                let specs = pasteStrokes()
                background { post(specs, gap: 15_000) } then: {
                    // Not an acknowledgment: the app reads the clipboard
                    // when it gets to the ⌘V, so the original waits.
                    later(0.5) { Clipboard.shared.restore(generation) }
                    finish()
                }
            } else {
                let perKey = route == .keys
                outcome.method = "typed"
                let specs = strokes(fitted, perKey: perKey, layout: Keys.layout)
                background { post(specs, gap: perKey ? 2_000 : 0) } then: { finish() }
            }
        }
    }

    /// ⌘ down as a modifier change, V down and up, ⌘ up, 15 ms apart: remote
    /// desktops and VMs track ⌘ from flags-changed events.
    private static func pasteStrokes() -> [Stroke] {
        let v = Keys.code(for: "v", command: true) ?? kVK_ANSI_V
        return [
            Stroke(key: kVK_Command, down: true, flags: .maskCommand),
            Stroke(key: v, down: true, flags: .maskCommand),
            Stroke(key: v, down: false, flags: .maskCommand),
            Stroke(key: kVK_Command, down: false, flags: []),
        ]
    }

    /// Up to `deadline`, until ⌘⌥⌃⇧ and fn are physically up.
    private static func waitForModifiers(until deadline: UInt64, _ then: @escaping @MainActor () -> Void) {
        let held: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]
        if CGEventSource.flagsState(.hidSystemState).intersection(held).isEmpty || Clock.now() >= deadline {
            then()
        } else {
            later(0.01) { waitForModifiers(until: deadline, then) }
        }
    }

    // MARK: Paste last

    /// For "Paste last transcript": when Lowtide itself is in front (the
    /// button in its settings), the app behind it gets the text.
    static func pasteLast(_ text: String, done: @escaping @MainActor (Outcome) -> Void) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == getppid(),
              let behind = appBehind()
        else { return deliver(text, from: nil, done: done) }
        behind.activate()
        later(0.3) { deliver(text, from: nil, done: done) }
    }

    private static func appBehind() -> NSRunningApplication? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let me = getpid(), parent = getppid()
        for window in windows where window[kCGWindowLayer as String] as? Int == 0 {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != me, pid != parent,
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular
            else { continue }
            return app
        }
        return nil
    }

    // MARK: Strategy

    enum Strategy { case paste, type, keys }

    private static let remote: Set<String> = [
        "com.utmapp.UTM", "com.vmware.fusion", "com.apple.ScreenSharing", "com.microsoft.rdc.macos",
        "com.microsoft.rdc.mac",
    ]
    private static let remotePrefixes = ["com.parallels.", "com.citrix."]

    /// VMs and remote screens: typed with real key codes where the layout
    /// has them, since the guest reads keys, not text. Chromium 155 and 156
    /// can drop a ⌘V that races its own clipboard notice (fixed in 157):
    /// typed. Everything else, terminals included: pasted, as in Hex.
    static func strategy(for focus: Focus) -> Strategy {
        if remote.contains(focus.bundle) || remotePrefixes.contains(where: focus.bundle.hasPrefix) { return .keys }
        if let url = focus.url, chromiumMajors(url).contains(where: (155...156).contains) { return .type }
        return .paste
    }

    /// `Contents/Frameworks/<Name> Framework.framework/Versions/<a.b.c.d>`:
    /// every version found, so a staged update counts too.
    nonisolated static func chromiumMajors(_ bundle: URL) -> [Int] {
        let files = FileManager.default
        let frameworks = bundle.appendingPathComponent("Contents/Frameworks")
        let names = (try? files.contentsOfDirectory(atPath: frameworks.path)) ?? []
        return names.filter { $0.hasSuffix("Framework.framework") }.flatMap { name in
            let versions = frameworks.appendingPathComponent(name).appendingPathComponent("Versions")
            return ((try? files.contentsOfDirectory(atPath: versions.path)) ?? []).compactMap(chromiumMajor)
        }
    }

    nonisolated static func chromiumMajor(_ version: String) -> Int? {
        let parts = version.split(separator: ".").map { Int($0) }
        guard parts.count == 4, !parts.contains(nil) else { return nil }
        return parts[0]
    }

    // MARK: Key events

    struct Stroke: Equatable {
        var key: Int
        var down: Bool
        var flags: CGEventFlags
        var text: [UniChar]?
    }

    /// Text as key events: up to 20 UTF-16 units each (the most one
    /// carries), never splitting a surrogate pair; a line break is
    /// Shift-Return, so chat boxes add a line instead of sending. `perKey`
    /// sends each character on its own key where the layout has one.
    nonisolated static func strokes(_ text: String, perKey: Bool, layout: Keys.Layout) -> [Stroke] {
        var out = [Stroke]()
        var units = [UniChar]()
        func flush() {
            guard !units.isEmpty else { return }
            out += [Stroke(key: 0, down: true, flags: [], text: units), Stroke(key: 0, down: false, flags: [], text: units)]
            units = []
        }
        func shifted(_ key: Int, _ text: [UniChar]?) -> [Stroke] {
            [
                Stroke(key: kVK_Shift, down: true, flags: .maskShift),
                Stroke(key: key, down: true, flags: .maskShift, text: text),
                Stroke(key: key, down: false, flags: .maskShift, text: text),
                Stroke(key: kVK_Shift, down: false, flags: []),
            ]
        }
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            if scalar == "\r" || scalar == "\n" {
                if scalar == "\r", index < scalars.count, scalars[index] == "\n" { index += 1 }
                flush()
                out += shifted(kVK_Return, nil)
                continue
            }
            let encoded = Array(String(scalar).utf16)
            guard perKey else {
                if units.count + encoded.count > 20 { flush() }
                units += encoded
                continue
            }
            let character = Character(scalar)
            if let key = layout.plain[character] {
                out += [Stroke(key: key, down: true, flags: [], text: encoded), Stroke(key: key, down: false, flags: [], text: encoded)]
            } else if let key = layout.shift[character] {
                out += shifted(key, encoded)
            } else {
                out += [Stroke(key: 0, down: true, flags: [], text: encoded), Stroke(key: 0, down: false, flags: [], text: encoded)]
            }
        }
        flush()
        return out
    }

    /// Posted at the HID tap with no event source and explicit flags, so no
    /// modifier the user holds leaks in; marked so our own tap lets them by.
    nonisolated private static func post(_ strokes: [Stroke], gap: useconds_t) {
        for (index, stroke) in strokes.enumerated() {
            if index > 0, gap > 0 { usleep(gap) }
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(stroke.key), keyDown: stroke.down)
            else { continue }
            // A real keyboard reports a modifier as flags-changed, never key down or up.
            if (54...63).contains(stroke.key) { event.type = .flagsChanged }
            event.flags = stroke.flags
            if let text = stroke.text { event.keyboardSetUnicodeString(stringLength: text.count, unicodeString: text) }
            event.setIntegerValueField(.eventSourceUserData, value: Hotkey.tag)
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: Accessibility

    /// The character before an empty selection, "" at the start or when the
    /// app doesn't say.
    private static func before(caretOf element: AXUIElement) -> String {
        guard let range = range(element), range.length == 0, range.location > 0 else { return "" }
        var wanted = CFRange(location: range.location - 1, length: 1)
        guard let parameter = AXValueCreate(.cfRange, &wanted) else { return "" }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value) == .success
        else { return "" }
        return value as? String ?? ""
    }

    private static func range(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        // Checked to be an AXValue just above.
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        // Checked to be an AXUIElement just above.
        return (value as! AXUIElement)
    }

    // MARK: Scheduling

    private static func later(_ seconds: Double, _ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { body() } }
    }

    private static func background(_ work: @escaping () -> Void, then: @escaping @MainActor () -> Void) {
        DispatchQueue.global(qos: .userInteractive).async {
            work()
            DispatchQueue.main.async { MainActor.assumeIsolated { then() } }
        }
    }
}

/// The clipboard around a paste: what was there is read at the press (off
/// the main thread), the transcript goes up marked transient, and the
/// original comes back 500 ms after ⌘V unless something else changed the
/// clipboard meanwhile. Takes back to back keep the very first original.
@MainActor
final class Clipboard {
    static let shared = Clipboard()
    typealias Items = [[(NSPasteboard.PasteboardType, Data)]]

    private let board = NSPasteboard.general
    private var prepared: (change: Int, items: Items)?
    private var generation = 0
    private var original: Items?
    private var lastChange: Int?

    /// At the press, so the paste needn't wait for a slow clipboard.
    func prepare() {
        let change = board.changeCount
        guard prepared?.change != change else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let items = Clipboard.read(NSPasteboard.general)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if self.board.changeCount == change { self.prepared = (change, items) }
                }
            }
        }
    }

    /// Puts `text` up for one paste; returns the generation to restore.
    func put(_ text: String) -> Int {
        let previousChange = board.changeCount
        let previous = prepared?.change == previousChange ? prepared?.items ?? [] : Clipboard.read(board)
        prepared = nil
        write(text, transient: true)
        generation += 1
        // Still our own last transcript: the original from before it stays.
        if lastChange != previousChange { original = previous }
        lastChange = board.changeCount
        return generation
    }

    func restore(_ generation: Int) {
        guard generation == self.generation else { return }
        defer {
            original = nil
            lastChange = nil
        }
        guard board.changeCount == lastChange else { return }
        let items = original ?? []
        board.clearContents()
        guard !items.isEmpty else { return }
        board.writeObjects(items.map { pairs in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            return item
        })
    }

    /// Leaves `text` on the clipboard for the user; nothing comes back.
    func keep(_ text: String) {
        generation += 1
        original = nil
        lastChange = nil
        write(text, transient: false)
    }

    private func write(_ text: String, transient: Bool) {
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if transient {
            // nspasteboard.org markers: not the user's own copy, don't keep it.
            item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
            item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        }
        board.writeObjects([item])
    }

    /// Every item and type, except promises (they make the owner produce a
    /// file) and the `dyn.` types macOS derives itself, which it makes again
    /// (Hex's `SYSTEM_TRANSLATED_FLAVOR`). No time limit: a cut-off read put
    /// back half a copied image.
    nonisolated static func read(_ board: NSPasteboard) -> Items {
        let started = Clock.now()
        var out: Items = []
        var skipped = 0
        for item in board.pasteboardItems ?? [] {
            var pairs: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                let name = type.rawValue
                if name.contains("promise") || name.contains("Promise") || name.hasPrefix("dyn.") {
                    skipped += 1
                    continue
                }
                if let data = item.data(forType: type) { pairs.append((type, data)) }
            }
            out.append(pairs)
        }
        Log.event("clipboard", [
            "action": "snapshot", "items": out.count, "skipped": skipped,
            "ms": Int(Clock.seconds(started, Clock.now()) * 1000),
        ])
        return out
    }
}
