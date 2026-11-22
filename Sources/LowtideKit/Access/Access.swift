import AppKit
import ApplicationServices
import AVFoundation
import UserNotifications
import os

/// The macOS permissions Lowtide's spaces and extensions need, read without
/// prompting, and a way to ask for each: macOS's own prompt where one
/// exists, else the exact pane of System Settings with the drag assistant
/// beside it.
public enum Access: String, CaseIterable, Identifiable, Sendable {
    case fullDisk, notifications, automation, appManagement, accessibility, microphone

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fullDisk: "Full Disk Access"
        case .notifications: "Notifications"
        case .automation: "System Events and Finder"
        case .appManagement: "App Management"
        case .accessibility: "Accessibility"
        case .microphone: "Microphone"
        }
    }

    public var symbol: String {
        switch self {
        case .fullDisk: "externaldrive"
        case .notifications: "bell"
        case .automation: "gearshape.2"
        case .appManagement: "square.grid.2x2"
        case .accessibility: "accessibility"
        case .microphone: "mic"
        }
    }

    /// What it's for, in a sentence.
    public var why: String {
        switch self {
        case .fullDisk: "Sees every folder at once, so macOS doesn’t ask folder by folder."
        case .notifications: "Tells you about alerts while the window is closed."
        case .automation: "Switches dark mode, empties the Trash and lists what opens at login."
        case .appManagement: "Updates apps in place, without asking each time."
        case .accessibility: "Arranges menu bar icons, and lets dictation listen for its shortcut and type into any app."
        case .microphone: "Turns what you say into text, on this Mac. Nothing you say leaves it, and only the words you dictate are kept."
        }
    }

    /// Shown once asked and still not allowed.
    public var hint: String {
        switch self {
        case .fullDisk, .appManagement, .accessibility: "Drag Lowtide from the panel beside System Settings into the list."
        case .automation:
            "Say OK to the prompt for System Events, then the one for Finder. No prompt? Switch Lowtide on in System Settings › Automation."
        case .microphone: "No prompt? Switch Lowtide on in System Settings › Microphone."
        case .notifications: "No prompt? Switch Lowtide on in System Settings › Notifications."
        }
    }

    /// The button once asked, when it does more than open System Settings again.
    public var retry: String {
        switch self {
        case .automation, .microphone, .notifications: "Ask Again"
        default: "Open Again"
        }
    }

    /// Lists Lowtide has to be dragged into.
    public var isList: Bool { self == .fullDisk || self == .appManagement || self == .accessibility }

    static let bundleID = Paths.bundleID
    static let privacy = "x-apple.systempreferences:com.apple.preference.security"
    /// The Apple-event targets: dark mode, restart and login items go to
    /// System Events; empty Trash and eject go to Finder.
    static let targets = ["com.apple.systemevents", "com.apple.finder"]

    public var settingsURL: URL {
        let text = switch self {
        case .notifications: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Self.bundleID)"
        case .automation: "\(Self.privacy)?Privacy_Automation"
        case .appManagement: "\(Self.privacy)?Privacy_AppBundles"
        case .accessibility: "\(Self.privacy)?Privacy_Accessibility"
        case .microphone: "\(Self.privacy)?Privacy_Microphone"
        case .fullDisk: "\(Self.privacy)?Privacy_AllFiles"
        }
        return URL(string: text)!
    }

    /// Allowed, refused, or nil when macOS can't tell without asking.
    public func granted() async -> Bool? {
        switch self {
        case .fullDisk: Self.fullDiskAccess()
        case .notifications: await Self.notificationsAllowed()
        case .automation: await Self.automationAllowed()
        case .appManagement: await Self.appManagementAllowed()
        case .accessibility: AXIsProcessTrusted()
        case .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
    }

    /// Every permission in `only` (all when nil), read at once.
    public static func status(_ only: [Access]? = nil) async -> [Access: Bool?] {
        // Children write their own answer instead of returning a tuple
        // through the group (such tuples came out uninitialized in optimized
        // builds; see ToolchainModel).
        let out = OSAllocatedUnfairLock(initialState: [Access: Bool?]())
        await withTaskGroup(of: Void.self) { group in
            for access in only ?? allCases {
                group.addTask {
                    let granted = await access.granted()
                    out.withLock { $0[access] = .some(granted) }
                }
            }
        }
        return out.withLock { $0 }
    }

    /// Asks: macOS's prompt where there is one; for the lists, System
    /// Settings on the right pane with the drag panel beside it.
    @MainActor
    public func request() async {
        switch self {
        case .accessibility, .fullDisk, .appManagement:
            await forgetStale()
            NSWorkspace.shared.open(settingsURL)
            DragAssistant.shared.show(for: self)
        case .notifications:
            if await Self.notificationStatus() == .notDetermined {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            } else {
                NSWorkspace.shared.open(settingsURL)
            }
        case .automation:
            // Asking each target from this process is what shows macOS's
            // prompt under Lowtide's name. A refusal made earlier can only
            // be changed in System Settings.
            // One prompt after the other, System Events first.
            var refused = false
            for target in Self.targets where await AppleEvents.allowed(target, ask: true) == false { refused = true }
            if refused { NSWorkspace.shared.open(settingsURL) }
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized { await forgetStale() }
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
    }

    /// The TCC service, for the permissions whose entry can be reset.
    var service: String? {
        switch self {
        case .accessibility: "Accessibility"
        case .fullDisk: "SystemPolicyAllFiles"
        case .appManagement: "SystemPolicyAppBundles"
        case .microphone: "Microphone"
        default: nil
        }
    }

    /// Clears Lowtide's entry for a permission it doesn't have. After an
    /// update or a reinstall the entry from the old copy can still be in the
    /// list, switched on, while macOS refuses this copy: it looks allowed and
    /// isn't. Only called when the permission is known to be missing, so a
    /// working grant is never touched.
    func forgetStale() async {
        guard let service, await granted() != true else { return }
        _ = try? await Shell.run("/usr/bin/tccutil", ["reset", service, Self.bundleID], timeout: .seconds(5))
    }

    /// Full Disk Access has no prompt and no query: macOS simply refuses to
    /// open its own privacy database without it.
    static func fullDiskAccess() -> Bool {
        let home = Paths.home
        return FileManager.default.isReadableFile(atPath: home.appending(path: "Library/Application Support/com.apple.TCC/TCC.db").path)
            || (try? FileManager.default.contentsOfDirectory(atPath: home.appending(path: "Library/Safari").path)) != nil
    }

    /// Only inside an `.app`: outside one (tests, a bare binary) the
    /// framework throws instead of answering.
    static var bundled: Bool { Bundle.main.bundlePath.hasSuffix(".app") }

    static func notificationStatus() async -> UNAuthorizationStatus? {
        guard bundled else { return nil }
        return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    static func notificationsAllowed() async -> Bool? {
        guard let status = await notificationStatus() else { return nil }
        switch status {
        case .notDetermined: return false
        case .denied: return false
        default: return true
        }
    }

    /// App Management (updating apps in place) has no query either. With
    /// Full Disk Access the privacy databases say; without it, nil.
    static func appManagementAllowed() async -> Bool? {
        // macOS answers directly. The permission database is the fallback:
        // on macOS 27 App Management isn't in the system database and the
        // user's can't be opened, so reading it said "not allowed" even
        // when it was.
        if let state = TCCPreflight.state("kTCCServiceSystemPolicyAppBundles") { return state }
        let query = "select client from access where service = 'kTCCServiceSystemPolicyAppBundles' and auth_value >= 2"
        let exe = Bundle.main.executablePath ?? bundleID
        var readable = false
        for db in [Paths.home.appending(path: "Library/Application Support/com.apple.TCC/TCC.db").path,
                   "/Library/Application Support/com.apple.TCC/TCC.db"] {
            guard let out = try? await Shell.run("/usr/bin/sqlite3", ["-readonly", db, query], timeout: .seconds(5)), out.ok else { continue }
            readable = true
            if out.stdout.split(separator: "\n").contains(where: { $0 == bundleID || $0 == exe }) { return true }
        }
        return readable ? false : nil
    }

    /// Allowed only when every target is; nil while one can't be reached and
    /// nothing was refused.
    static func automationAllowed() async -> Bool? {
        var answers: [Bool?] = []
        for target in targets { answers.append(await AppleEvents.allowed(target, ask: false)) }
        if answers.contains(false) { return false }
        return answers.allSatisfy { $0 != nil } ? true : nil
    }
}

/// Apple-event permissions, without sending an event.
enum AppleEvents {
    static let notPermitted: OSStatus = -1743
    static let needsConsent: OSStatus = -1744
    static let notRunning: OSStatus = -600

    /// The last definite answer per target. macOS answers only for a running
    /// app, and System Events quits when idle: without this an allowed row
    /// would flip back to "Allow" each time it did.
    private static let known = OSAllocatedLock<[String: Bool]>(initialState: [:])
    /// When each target was last started, so one that won't start isn't
    /// launched again on every check.
    private static let started = OSAllocatedLock<[String: Date]>(initialState: [:])

    static func determine(_ bundleID: String, ask: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let desc = target.aeDesc else { return OSStatus(procNotFound) }
        return AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, ask)
    }

    /// Starts a background app (System Events) hidden and waits for it to
    /// answer; at most once a minute per app.
    static func start(_ bundleID: String, ask: Bool) async -> OSStatus {
        let recent = started.withLock { $0[bundleID].map { Date().timeIntervalSince($0) < 60 } ?? false }
        guard !recent else { return notRunning }
        started.withLock { $0[bundleID] = Date() }
        _ = try? await Shell.run("/usr/bin/open", ["-g", "-j", "-b", bundleID], timeout: .seconds(5))
        for _ in 0..<20 {
            let status = await blocking { determine(bundleID, ask: ask) }
            if status != notRunning { return status }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return notRunning
    }

    /// Whether Lowtide may send Apple events to `bundleID`. With `ask`,
    /// macOS shows its prompt if this was never answered (and waits for it).
    static func allowed(_ bundleID: String, ask: Bool) async -> Bool? {
        var status = await blocking { determine(bundleID, ask: ask) }
        if status == notRunning { status = await start(bundleID, ask: ask) }
        let answer: Bool? = switch status {
        case noErr: true
        case notPermitted, needsConsent: false
        default: nil
        }
        return known.withLock { known in
            if let answer { known[bundleID] = answer }
            return answer ?? known[bundleID]
        }
    }

    /// The check waits for the person to answer a prompt: never on the main thread.
    static func blocking<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }
}
