import Foundation

/// Privacy Mode for text: everything that identifies this Mac, its owner or
/// its network masked, for demos and screen recordings. Only what is shown
/// changes; the app keeps the real values, so open, connect and copy still
/// do the right thing.
public enum PrivacyText {
    static let maskIPv4 = "•••.•••.•••.•••"

    /// Order matters: user@host first (it may hold an address), a MAC before IPv6.
    static let rules: [(NSRegularExpression, String)] = [
        (#"[\w.+-]+@[\w-]+(?:\.[\w-]+)*"#, "•••@•••"),
        (#"\b(?:[0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}\b"#, "••:••:••:••:••:••"),
        // IPv6, with a letter or `::`, so clock times never match.
        (#"(?<![\w:])(?=[0-9a-fA-F:]*(?:[a-fA-F]|::))(?:[0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}(?:%[\w.]+)?(?![\w:])"#,
         "••••:••••::••"),
        (#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, maskIPv4),
        // Home folders name the account.
        (#"/Users/[^/\s:'"]+"#, "/Users/•••"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    static func replace(_ pattern: NSRegularExpression, in text: String, with mask: String) -> String {
        pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                         withTemplate: NSRegularExpression.escapedTemplate(for: mask))
    }

    /// Masks every identifying piece of `text`; `terms` are the names of
    /// this Mac and its owner (`identityTerms()`).
    public static func redact(_ text: String, terms: [String] = []) -> String {
        var out = text
        for (pattern, mask) in rules { out = replace(pattern, in: out, with: mask) }
        let words = terms.filter { $0.count >= 3 }.sorted { $0.count > $1.count }
        guard !words.isEmpty else { return out }
        // Longest first, so a full name wins over the first name inside it.
        let alternation = words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        guard let names = try? NSRegularExpression(pattern: "(?<![\\w])(?:\(alternation))(?![\\w])", options: .caseInsensitive) else {
            return out
        }
        return replace(names, in: out, with: "•••••")
    }

    /// Names that identify this Mac and its owner: account name, full name,
    /// the computer's names. Two-letter names would hide ordinary words.
    public static func identityTerms() async -> [String] {
        async let full = output("/usr/bin/id", ["-F"])
        async let computer = output("/usr/sbin/scutil", ["--get", "ComputerName"])
        async let local = output("/usr/sbin/scutil", ["--get", "LocalHostName"])
        async let host = output("/bin/hostname", ["-s"])
        let all = [NSUserName(), await full, await computer, await local, await host].compactMap { $0 }
        return Array(Set(all.filter { $0.count >= 3 })).sorted()
    }

    static func output(_ program: String, _ args: [String]) async -> String? {
        guard let out = try? await Shell.run(program, args, timeout: .seconds(3)), out.ok else { return nil }
        let text = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// The app's extensions, switched on and off from the Extensions gallery
/// and onboarding. Each extension reads its flag at launch and observes
/// `changed` to start or stop.
public enum ExtensionState {
    public enum ID: String, CaseIterable, Sendable {
        case dictation, menubar, widgets, commandbar

        /// Only the command bar is on until switched on: the others change
        /// the Mac noticeably (dictation downloads a model and listens, the
        /// menu bar manager rearranges the menu bar, widgets add an item to it).
        public var defaultOn: Bool { self == .commandbar }
        public var key: String { "extension.\(rawValue)" }
    }

    /// Posted after any extension is switched on or off.
    public static let changed = Notification.Name("Lowtide.extensionsChanged")

    public static func isOn(_ id: ID, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: id.key) as? Bool ?? id.defaultOn
    }

    public static func set(_ id: ID, _ on: Bool, defaults: UserDefaults = .standard) {
        guard isOn(id, defaults: defaults) != on || defaults.object(forKey: id.key) == nil else { return }
        defaults.set(on, forKey: id.key)
        NotificationCenter.default.post(name: changed, object: nil, userInfo: ["id": id.rawValue, "on": on])
    }
}
