import Foundation

/// What macOS still keeps for apps that are gone: Privacy grants (Camera,
/// Accessibility, Full Disk Access…) and things set to start with the Mac
/// whose program no longer exists. Grants of a deleted app are inert (bound
/// to its code signature) but clutter Privacy & Security; a start-up item
/// pointing at nothing fails at every login.
public struct GoneApp: Sendable, Identifiable, Hashable {
    public struct Grant: Sendable, Hashable, Identifiable {
        public var id: String { service + (target ?? "") }
        /// The TCC name without `kTCCService`.
        public let service: String
        public let label: String
        /// Limited access (some photos, some contacts).
        public let limited: Bool
        public let modified: Date?
        /// `tccutil` resets by bundle id; a grant held by a bare path only
        /// System Settings can drop.
        public let revocable: Bool
        /// Automation: the app it may control.
        public let target: String?
    }

    public struct Startup: Sendable, Hashable, Identifiable {
        public enum Kind: String, Sendable { case agent, daemon, openAtLogin = "open at login" }
        /// The plist path, or `login:<name>` for an Open at Login item.
        public let id: String
        public let name: String
        public let kind: Kind
        public let label: String?
        public let plist: String?
        /// What it would run, gone from disk.
        public let executable: String?
        /// Root's (in /Library): moving it asks for the password.
        public var needsAdmin: Bool { plist.map { !$0.hasPrefix(Paths.home.path + "/") } ?? false }
    }

    /// The bundle id, the path, or the job's label.
    public let id: String
    public let name: String
    public let bundleID: String?
    public var grants: [Grant] = []
    public var startup: [Startup] = []
}

public struct GonePermissions: Sendable {
    public var apps: [GoneApp] = []
    /// Reading grants needs Full Disk Access.
    public var grantsReadable = false
    /// `nil` when Open at Login items weren't asked for (that needs
    /// Automation of System Events, so only when the person looks).
    public var loginItemsRead: Bool?
}

public enum LeftoverPermissions {
    /// TCC services: label and the anchor of its pane in Privacy & Security.
    static let services: [String: (label: String, pane: String)] = [
        "Camera": ("Camera", "Privacy_Camera"), "Microphone": ("Microphone", "Privacy_Microphone"),
        "ScreenCapture": ("Screen & audio recording", "Privacy_ScreenCapture"),
        "Accessibility": ("Accessibility", "Privacy_Accessibility"),
        "PostEvent": ("Send keystrokes and clicks", "Privacy_Accessibility"),
        "ListenEvent": ("Input monitoring", "Privacy_ListenEvent"),
        "SystemPolicyAllFiles": ("Full Disk Access", "Privacy_AllFiles"),
        "SystemPolicyDesktopFolder": ("Desktop folder", "Privacy_FilesAndFolders"),
        "SystemPolicyDocumentsFolder": ("Documents folder", "Privacy_FilesAndFolders"),
        "SystemPolicyDownloadsFolder": ("Downloads folder", "Privacy_FilesAndFolders"),
        "SystemPolicyNetworkVolumes": ("Network volumes", "Privacy_FilesAndFolders"),
        "SystemPolicyRemovableVolumes": ("Removable volumes", "Privacy_FilesAndFolders"),
        "SystemPolicyAppData": ("Other apps' data", "Privacy_AppData"),
        "SystemPolicyAppBundles": ("App management", "Privacy_AppBundles"),
        "AppleEvents": ("Automation", "Privacy_Automation"), "AddressBook": ("Contacts", "Privacy_Contacts"),
        "Calendar": ("Calendars", "Privacy_Calendars"), "Reminders": ("Reminders", "Privacy_Reminders"),
        "Photos": ("Photos", "Privacy_Photos"), "MediaLibrary": ("Media & Apple Music", "Privacy_Media"),
        "BluetoothAlways": ("Bluetooth", "Privacy_Bluetooth"), "DeveloperTool": ("Developer tools", "Privacy_DevTools"),
    ]

    public static func settingsURL(service: String?) -> URL {
        let anchor = service.flatMap { services[$0]?.pane } ?? "Privacy"
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    public static let loginItemsURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!

    struct Row: Decodable {
        let service: String
        let client: String
        let client_type: Int
        let auth_value: Int
        let indirect_object_identifier: String?
        let last_modified: Int?
    }

    static let query = "select service, client, client_type, auth_value, indirect_object_identifier, last_modified from access where auth_value >= 2"

    /// Rows of one TCC database, or `nil` when macOS won't let us read it.
    static func rows(_ db: String) async -> [Row]? {
        guard let out = try? await Shell.run("/usr/bin/sqlite3", ["-readonly", "-json", db, query], timeout: .seconds(20)),
              out.ok else { return nil }
        let text = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return [] }
        return try? JSONDecoder().decode([Row].self, from: Data(text.utf8))
    }

    /// Grants whose app is gone, keyed by bundle id or path.
    static func goneGrants(_ rows: [Row], installed: Set<String>) -> [String: (bundleID: String?, grants: [GoneApp.Grant])] {
        var out: [String: (String?, [GoneApp.Grant])] = [:]
        for row in rows {
            let service = row.service.hasPrefix("kTCCService") ? String(row.service.dropFirst(11)) : row.service
            let byPath = row.client_type == 1
            if byPath {
                // A tool by path: gone when the file is.
                guard row.client.hasPrefix("/"), !CleanupFS.exists(row.client) else { continue }
            } else {
                guard !row.client.hasPrefix("com.apple."), !installed.contains(row.client.lowercased()) else { continue }
            }
            let grant = GoneApp.Grant(
                service: service, label: services[service]?.label ?? service, limited: row.auth_value == 3,
                modified: row.last_modified.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                revocable: !byPath,
                target: row.indirect_object_identifier.flatMap { $0.isEmpty || $0 == "UNUSED" ? nil : $0 })
            out[row.client, default: (byPath ? nil : row.client, [])].1.append(grant)
        }
        return out
    }

    /// Launch agents and daemons whose program is gone.
    static func brokenJobs(home: String) -> [GoneApp.Startup] {
        var found: [GoneApp.Startup] = []
        for (folder, kind) in [(CleanupFS.join(home, "Library/LaunchAgents"), GoneApp.Startup.Kind.agent),
                               ("/Library/LaunchAgents", .agent), ("/Library/LaunchDaemons", .daemon)] {
            for name in CleanupFS.names(folder) where name.hasSuffix(".plist") {
                let path = CleanupFS.join(folder, name)
                guard let data = FileManager.default.contents(atPath: path),
                      let job = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let label = job["Label"] as? String else { continue }
                let program = (job["Program"] as? String) ?? (job["ProgramArguments"] as? [String])?.first
                guard let program, program.hasPrefix("/"), !CleanupFS.exists(program) else { continue }
                found.append(GoneApp.Startup(id: path, name: label, kind: kind, label: label, plist: path, executable: program))
            }
        }
        return found
    }

    /// The installed app from the same vendor as a job's label:
    /// `com.docker.socket` belongs with `com.docker.docker`.
    static func vendorApp(_ label: String, installed: [String: String]) -> String? {
        let parts = label.split(separator: ".")
        guard parts.count >= 3 else { return nil }
        let vendor = "\(parts[0]).\(parts[1])."
        guard vendor != "com.apple." else { return nil }
        return installed.keys.filter { $0.hasPrefix(vendor.lowercased()) }.sorted().first
    }

    struct LoginItem: Decodable { let name: String; let path: String? }

    static let loginItemsScript = "JSON.stringify(Application('System Events').loginItems().map(i => ({ name: i.name(), path: i.path() })))"

    /// Open at Login items. Asks macOS for Automation of System Events.
    static func loginItems() async -> [LoginItem]? {
        guard let out = try? await Shell.run("/usr/bin/osascript", ["-l", "JavaScript", "-e", loginItemsScript], timeout: .seconds(20)),
              out.ok else { return nil }
        return try? JSONDecoder().decode([LoginItem].self, from: Data(out.stdout.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
    }

    /// Every gone app with a grant or a broken start-up item.
    public static func scan(includeLoginItems: Bool) async -> GonePermissions {
        let home = CleanupFS.home
        async let user = rows(CleanupFS.join(home, "Library/Application Support/com.apple.TCC/TCC.db"))
        async let system = rows("/Library/Application Support/com.apple.TCC/TCC.db")
        async let logins: [LoginItem]? = includeLoginItems ? loginItems() : nil
        let installed = await Task.detached(priority: .utility) { () -> [String: String] in
            var ids: [String: String] = [:]
            for path in await InstalledBundles.appPaths(everywhere: true) {
                guard let info = AppBundles.read(path: path), let id = info.bundleID else { continue }
                ids[id.lowercased()] = info.displayName ?? info.name ?? (CleanupFS.name(path) as NSString).deletingPathExtension
            }
            return ids
        }.value
        let (userRows, systemRows, loginList) = await (user, system, logins)
        var result = GonePermissions(grantsReadable: userRows != nil || systemRows != nil,
                                     loginItemsRead: includeLoginItems ? loginList != nil : nil)
        var apps: [String: GoneApp] = [:]
        for (key, entry) in goneGrants((userRows ?? []) + (systemRows ?? []), installed: Set(installed.keys)) {
            let name = entry.bundleID ?? CleanupFS.name(key)
            apps[key, default: GoneApp(id: key, name: name, bundleID: entry.bundleID)].grants += entry.grants
        }
        for job in brokenJobs(home: home) {
            let owner = job.label.flatMap { vendorApp($0, installed: installed) }
            let key = owner ?? job.label ?? job.id
            apps[key, default: GoneApp(id: key, name: owner.flatMap { installed[$0] } ?? job.name, bundleID: owner)].startup.append(job)
        }
        for item in loginList ?? [] {
            let path = item.path.flatMap { $0.isEmpty || $0 == "missing value" ? nil : $0 }
            guard path.map({ !CleanupFS.exists($0) }) ?? true else { continue }
            let key = path ?? "login:\(item.name)"
            apps[key, default: GoneApp(id: key, name: item.name, bundleID: nil)].startup.append(
                GoneApp.Startup(id: "login:\(item.name)", name: item.name, kind: .openAtLogin, label: nil, plist: nil, executable: path))
        }
        result.apps = apps.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return result
    }

    // MARK: Actions

    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    /// Clears a gone app's grant (`service`, or "All"). `tccutil` refuses a
    /// bundle id Launch Services can't find, which is every deleted app, so
    /// an empty stand-in bundle with that id is registered for a moment,
    /// the grant reset, and the stand-in removed again.
    public static func revoke(service: String, bundleID: String) async throws {
        guard Paths.safeID(bundleID) != nil, service == "All" || services[service] != nil else {
            throw LowtideError.invalid("That grant has an unusual name; remove it in System Settings.")
        }
        // Not under a temp folder: Launch Services ignores bundles there.
        let app = Paths.cache.appending(path: "stubs/\(bundleID).app")
        let contents = app.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        let info = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>\(bundleID)</string>
        <key>CFBundleName</key><string>Lowtide stand-in</string>
        <key>CFBundlePackageType</key><string>APPL</string>
        <key>CFBundleExecutable</key><string>stub</string>
        </dict></plist>
        """
        try Data(info.utf8).write(to: contents.appending(path: "Info.plist"))
        try Data("#!/bin/sh\n".utf8).write(to: contents.appending(path: "MacOS/stub"))
        _ = try? await Shell.run(lsregister, ["-f", "-R", app.path], timeout: .seconds(30))
        var failure: Error? = LowtideError.commandFailed("Launch Services didn't pick up the stand-in")
        // Registration lands a moment later.
        for _ in 0..<8 {
            do {
                try await Shell.check("/usr/bin/tccutil", ["reset", service, bundleID], timeout: .seconds(20))
                failure = nil
                break
            } catch {
                failure = error
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        _ = try? await Shell.run(lsregister, ["-u", app.path], timeout: .seconds(30))
        // Our own stand-in, made a moment ago: not the person's file.
        try? FileManager.default.removeItem(at: app)
        if let failure { throw failure }
    }

    /// Stops broken start-up items and moves their plists to the Trash
    /// (yours in-process, so Undo works; /Library's with one password
    /// prompt). Open at Login items leave the list through System Events.
    public static func remove(_ items: [GoneApp.Startup]) async -> Footprint.RemoveResult {
        var result = Footprint.RemoveResult()
        let uid = CleanupFS.uid
        for item in items where item.kind == .openAtLogin {
            let name = item.name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            do {
                try await Shell.check("/usr/bin/osascript", ["-e", "tell application \"System Events\" to delete login item \"\(name)\""],
                                      timeout: .seconds(20))
                result.removed.append(item.id)
            } catch {
                result.failed.append(Trash.Refusal(path: item.id, reason: error.localizedDescription))
            }
        }
        let jobs = items.filter { $0.kind != .openAtLogin && $0.plist != nil }
        for job in jobs where !job.needsAdmin {
            if let label = job.label.flatMap(Paths.safeID) {
                _ = try? await Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"], timeout: .seconds(20))
            }
        }
        let own = jobs.filter { !$0.needsAdmin }.compactMap(\.plist)
        var outcome = await Trash.move(own)
        outcome.add(await Trash.moveAsAdmin(jobs.filter(\.needsAdmin).compactMap(\.plist),
                                            prompt: "Lowtide needs your password to move start-up items of deleted apps to the Trash."))
        result.removed += outcome.removed
        result.undo += outcome.undoable
        result.failed += outcome.refused
        return result
    }
}
