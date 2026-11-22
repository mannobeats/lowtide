import Foundation

/// What the helper last reported, for the page, the overlay and menus.
public struct VoiceStatus: Equatable, Sendable, Encodable {
    /// This build has the helper.
    public var available = false
    public var running = false
    /// The shortcut's event tap is on (needs Accessibility); nil until it says.
    public var shortcutAccess: Bool?
    /// The app holding Secure Event Input, which hides every key press from
    /// the shortcut until it lets go.
    public var blockedBy: String?
    /// Apple's on-device model can polish text.
    public var polishAvailable = false
    /// System Settings › Keyboard › "Press 🌐 key to": 0 is Do Nothing, nil
    /// unset (macOS acts on it). Anything else also fires with fn.
    public var fnUsage: Int?
    public var phase: VoicePhase = .idle
    public var message = ""
    public var modelID = ""
    public var modelState: ModelState = .unknown
    public var modelMessage = ""
    public var download: Download?

    public struct Download: Equatable, Sendable, Encodable {
        public var model: String
        public var progress: Double
        public var error: String?

        public init(model: String, progress: Double, error: String? = nil) {
            self.model = model
            self.progress = progress
            self.error = error
        }
    }

    public init() {}

    /// Folds one helper message in; true when anything a view shows changed.
    @discardableResult
    public mutating func apply(_ message: HelperMessage) -> Bool {
        let before = self
        switch message {
        case .state(let state):
            phase = state.phase
            self.message = state.message
        case .model(let id, let state, let text):
            modelID = id
            modelState = state
            modelMessage = text
        case .download(let model, let progress, let done, let error):
            // Finished, or cancelled (an empty error): nothing to show.
            download = done || error == "" ? nil : Download(model: model, progress: progress, error: error)
        case .access(let shortcut, let polish, let fn):
            shortcutAccess = shortcut
            if let polish { polishAvailable = polish }
            if let fn { fnUsage = fn }
        case .blocked(let by):
            blockedBy = by
        default:
            break
        }
        return self != before
    }

    /// The helper ended: nothing it said about the moment still holds.
    public mutating func stopped() {
        running = false
        blockedBy = nil
        phase = .idle
        download = nil
    }

    private enum CodingKeys: String, CodingKey {
        case available, running, shortcutAccess, blockedBy, polishAvailable, fnUsage, phase, message
        case modelID = "model", modelState, modelMessage, download
    }

    /// Without `message`: while transcribing it carries the words heard so
    /// far, and the report must never hold what was said.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(available, forKey: .available)
        try c.encode(running, forKey: .running)
        try c.encode(shortcutAccess, forKey: .shortcutAccess)
        try c.encode(blockedBy, forKey: .blockedBy)
        try c.encode(polishAvailable, forKey: .polishAvailable)
        try c.encode(fnUsage, forKey: .fnUsage)
        try c.encode(phase.rawValue, forKey: .phase)
        try c.encode(modelID, forKey: .modelID)
        try c.encode(modelState.rawValue, forKey: .modelState)
        try c.encode(modelMessage, forKey: .modelMessage)
        try c.encode(download, forKey: .download)
    }
}

/// A report of how dictation is set up and what it did, to paste into an
/// issue, without a word of what was said.
public enum VoiceDiagnostics {
    public static func report(version: String, os: String, prefs: VoicePrefs, status: VoiceStatus,
                              stderr: [String], log: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let statusText = (try? encoder.encode(status)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let events = log.split(separator: "\n", omittingEmptySubsequences: true).suffix(200).joined(separator: "\n")
        return """
        Lowtide \(version) dictation report
        \(os)

        Settings: shortcut \(prefs.shortcutLabel), mode \(prefs.mode.rawValue), model \(prefs.model), \
        language \(prefs.language), microphone \(prefs.microphone == nil ? "system default" : "picked"), \
        keep ready \(prefs.keepReady), avoid Bluetooth \(prefs.avoidBluetooth), polish \(prefs.polish), \
        preview \(prefs.preview), sounds \(prefs.sounds)

        Status:
        \(statusText)

        Helper stderr (last \(VoiceHelper.errorLines) lines):
        \(stderr.joined(separator: "\n"))

        Log (last 200 events):
        \(events)

        """
    }
}
