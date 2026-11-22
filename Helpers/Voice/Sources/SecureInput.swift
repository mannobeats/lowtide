import AppKit
import Carbon.HIToolbox
import IOKit

/// While an app has Secure Event Input on (a focused password field, or a
/// browser that never turned it off), macOS hides every key press from every
/// shortcut listener; changes to the modifier keys alone still come through.
/// The shortcut then does nothing and the event tap can't say why, so ask
/// who holds it.
enum SecureInput {
    /// The app holding it, or nil when no app does.
    static func holder() -> String? {
        guard IsSecureEventInputEnabled() else { return nil }
        guard let pid = holderPID() else { return "Another app" }
        if pid == getpid() || pid == getppid() { return "Lowtide" }
        return NSRunningApplication(processIdentifier: pid)?.localizedName ?? "Another app"
    }

    /// Read from the I/O Registry's console users, which macOS keeps
    /// current; this process's `CGSessionCopyCurrentDictionary` can hold an
    /// older holder and name the wrong app.
    private static func holderPID() -> pid_t? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        let users = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [[String: Any]]
        for user in users ?? [] {
            if let pid = user["kCGSSessionSecureInputPID"] as? Int { return pid_t(pid) }
        }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (session?["kCGSSessionSecureInputPID"] as? Int).map { pid_t($0) }
    }
}
