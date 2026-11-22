import AppKit

/// The fixed set of things the bar may do to the Mac. Nothing runs on its
/// own; the bar confirms the consequential ones (empty the Trash, restart,
/// shut down, log out) first. Typed text never reaches a shell.
public enum SystemAction: String, CaseIterable, Sendable {
    case darkMode, lockScreen, displayOff, screenSaver, ejectDisks, hiddenFiles, desktopIcons, emptyTrash
    case sleep, restart, shutDown, logOut, wifi, volume, soundMute

    /// Runs it; `value` is the level for `volume` (0–100).
    public func run(value: Int? = nil) async throws {
        switch self {
        case .darkMode:
            try await Self.osascript("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")
        case .lockScreen:
            if !Self.lockNow() { try await Shell.check("/usr/bin/open", ["-a", "ScreenSaverEngine"]) }
        case .displayOff:
            try await Shell.check("/usr/bin/pmset", ["displaysleepnow"])
        case .screenSaver:
            try await Shell.check("/usr/bin/open", ["-a", "ScreenSaverEngine"])
        case .ejectDisks:
            try await Self.osascript("tell application \"Finder\" to eject (every disk whose ejectable is true)")
        case .hiddenFiles:
            try await Self.flipFinder("AppleShowAllFiles", default: false)
        case .desktopIcons:
            try await Self.flipFinder("CreateDesktop", default: true)
        case .emptyTrash:
            try await Self.osascript("tell application \"Finder\" to empty trash")
        case .sleep:
            try await Shell.check("/usr/bin/pmset", ["sleepnow"])
        case .restart:
            try await Self.osascript("tell application \"System Events\" to restart")
        case .shutDown:
            try await Self.osascript("tell application \"System Events\" to shut down")
        case .logOut:
            try await Self.osascript("tell application \"System Events\" to log out")
        case .wifi:
            guard let device = await MacFacts.wifiDevice() else { throw LowtideError.notFound("Wi-Fi") }
            let on = await MacFacts.wifiPower() ?? false
            try await Shell.check("/usr/sbin/networksetup", ["-setairportpower", device, on ? "off" : "on"])
        case .volume:
            guard let level = value, (0...100).contains(level) else { throw LowtideError.invalid("Volume goes from 0 to 100.") }
            try await Self.osascript("set volume output volume \(level)")
        case .soundMute:
            try await Self.osascript("set volume output muted not (output muted of (get volume settings))")
        }
    }

    static func osascript(_ script: String) async throws {
        try await Shell.check("/usr/bin/osascript", ["-e", script], timeout: .seconds(30))
    }

    /// Locks the screen through the private login framework.
    static func lockNow() -> Bool {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
              let symbol = dlsym(handle, "SACLockScreenImmediate") else { return false }
        typealias Lock = @convention(c) () -> Int32
        return unsafeBitCast(symbol, to: Lock.self)() == 0
    }

    /// Flips a Finder boolean preference and restarts Finder.
    static func flipFinder(_ key: String, default value: Bool) async throws {
        let now = MacFacts.finderFlag(key) ?? value
        try await Shell.check("/usr/bin/defaults", ["write", "com.apple.finder", key, "-bool", now ? "false" : "true"])
        try await Shell.check("/usr/bin/killall", ["Finder"])
    }
}
