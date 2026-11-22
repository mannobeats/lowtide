import AppKit

/// A regular (Dock) app that is running.
public struct RunningApp: Equatable, Sendable {
    public var pid: pid_t
    public var bundleID: String?
    public var name: String
    public var path: String?
    public var active: Bool
}

/// Running apps, and quitting, force quitting and restarting them.
@MainActor
public enum RunningApps {
    /// Every regular app that is running, except Lowtide.
    public static func list() -> [RunningApp] {
        let own = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, app.processIdentifier > 0, app.processIdentifier != own else { return nil }
            return RunningApp(pid: app.processIdentifier, bundleID: app.bundleIdentifier,
                              name: app.localizedName ?? app.bundleIdentifier ?? "PID \(app.processIdentifier)",
                              path: app.bundleURL?.path, active: app.isActive)
        }
    }

    static func app(_ pid: pid_t) throws -> NSRunningApplication {
        guard pid > 1, pid != ProcessInfo.processInfo.processIdentifier else { throw LowtideError.invalid("That app can't be quit from here.") }
        guard let app = NSRunningApplication(processIdentifier: pid) else { throw LowtideError.notFound("That app") }
        return app
    }

    /// Quits gracefully (brought forward first, so an unsaved-changes dialog
    /// shows where it can be seen), or at once with `force`.
    public static func quit(_ pid: pid_t, force: Bool) async throws {
        let app = try app(pid)
        if force {
            app.forceTerminate()
            return
        }
        app.activate()
        try? await Task.sleep(for: .milliseconds(120))
        app.terminate()
    }

    /// Quits an app, waits up to 60 s for it to exit, then opens it again.
    public static func restart(_ pid: pid_t) async throws {
        let app = try app(pid)
        guard let url = app.bundleURL else { throw LowtideError.notFound("That app") }
        try await quit(pid, force: false)
        let deadline = ContinuousClock.now + .seconds(60)
        while !app.isTerminated {
            guard ContinuousClock.now < deadline else { throw LowtideError.commandFailed("\(app.localizedName ?? "The app") didn't quit.") }
            try await Task.sleep(for: .milliseconds(250))
        }
        try await Task.sleep(for: .milliseconds(120))
        try await Opener.open(url.path)
    }
}

/// Opens apps, files, folders and links the way Finder would, and brings
/// what opened to the front.
@MainActor
public enum Opener {
    /// Since macOS 14 only the app the person just typed into may hand the
    /// front to another app. The bar's panel never makes Lowtide active, so
    /// it yields to the app about to open first; without that an app that
    /// wasn't running launched behind the window you were in.
    public static func open(_ target: String) async throws {
        let isLink = target.contains("://") || target.hasPrefix("x-apple.") || target.hasPrefix("mailto:")
        guard let url = isLink ? URL(string: target) : URL(fileURLWithPath: (target as NSString).expandingTildeInPath) else {
            throw LowtideError.invalid("“\(target)” isn't a link macOS can open.")
        }
        let workspace = NSWorkspace.shared
        let isApp = url.pathExtension == "app"
        let opener = isApp ? url : workspace.urlForApplication(toOpen: url)
        if let id = opener.flatMap({ Bundle(url: $0)?.bundleIdentifier }) {
            NSApp.yieldActivation(toApplicationWithBundleIdentifier: id)
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let app = try await isApp ? workspace.openApplication(at: url, configuration: config)
            : workspace.open(url, configuration: config)
        // Hidden (⌘H) apps stay hidden on reopen; show them.
        if app.isHidden { app.unhide() }
        app.activate()
    }

    /// Selects a file or folder in a Finder window.
    public static func reveal(_ path: String) throws {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else { throw LowtideError.notFound("That file") }
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: "com.apple.finder")
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: expanded)])
    }

    public static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
