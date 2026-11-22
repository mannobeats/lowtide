import AppKit

/// Shell commands run as root after macOS's own password prompt, from inside
/// Lowtide. In-process the prompt names Lowtide and macOS keeps the
/// authorization for five minutes, so a run of removals asks once (through a
/// separate `osascript` it asked every time).
public enum Admin {
    public enum Refused: Error, Sendable, Equatable {
        case cancelled
        case failed(String)
        public var message: String {
            switch self {
            case .cancelled: "Password prompt cancelled"
            case .failed(let text): text
            }
        }
    }

    /// Runs `command` with `/bin/sh` as root. `prompt` is the line macOS
    /// shows above the password field.
    @MainActor
    public static func run(_ command: String, prompt: String) async -> Result<Void, Refused> {
        let source = "do shell script \"\(escape(command))\" with prompt \"\(escape(prompt))\" with administrator privileges"
        guard let script = NSAppleScript(source: source) else { return .failure(.failed("AppleScript isn't available")) }
        var error: NSDictionary?
        // NSAppleScript is main-thread only; yield first so the UI shows
        // its pending state before the modal prompt appears.
        await Task.yield()
        if script.executeAndReturnError(&error).descriptorType != 0, error == nil { return .success(()) }
        let code = (error?[NSAppleScript.errorNumber] as? Int) ?? 0
        if code == -128 { return .failure(.cancelled) }
        return .failure(.failed((error?[NSAppleScript.errorMessage] as? String) ?? "error \(code)"))
    }

    /// Inside an AppleScript string literal: backslashes and quotes escaped.
    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// One argument for `/bin/sh`, single-quoted.
    public static func quote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
