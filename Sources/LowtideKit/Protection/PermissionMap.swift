import Foundation

/// The permission map: every app on this Mac with what macOS lets it do.
///
/// Three sources, all readable without root:
/// - privacy grants from the two TCC databases (needs Full Disk Access;
///   read with the system `sqlite3`, which inherits Lowtide's grant);
/// - background items: the launch agents and daemons in the three
///   LaunchAgents/LaunchDaemons folders, read from their plists
///   (`sfltool dumpbtm` knows more, but asks for an administrator password
///   every time it runs);
/// - the "Open at Login" list from System Events.
///
/// Each is joined to the apps actually installed, so a grant or start-up
/// item whose app is gone shows up as a leftover.
public enum PermissionMap {
    // MARK: Services

    public struct Service: Sendable {
        /// The TCC name without `kTCCService`.
        public let id: String
        public let label: String
        /// The column it counts under on the map.
        public let group: String
        /// The anchor of its pane in Privacy & Security.
        public let pane: String
    }

    public static let services: [Service] = [
        Service(id: "Camera", label: "Camera", group: "camera", pane: "Privacy_Camera"),
        Service(id: "Microphone", label: "Microphone", group: "microphone", pane: "Privacy_Microphone"),
        Service(id: "ScreenCapture", label: "Screen & audio recording", group: "screen", pane: "Privacy_ScreenCapture"),
        Service(id: "Accessibility", label: "Accessibility", group: "accessibility", pane: "Privacy_Accessibility"),
        Service(id: "PostEvent", label: "Send keystrokes and clicks", group: "accessibility", pane: "Privacy_Accessibility"),
        Service(id: "ListenEvent", label: "Input monitoring", group: "input", pane: "Privacy_ListenEvent"),
        Service(id: "SystemPolicyAllFiles", label: "Full Disk Access", group: "disk", pane: "Privacy_AllFiles"),
        Service(id: "SystemPolicyDesktopFolder", label: "Desktop folder", group: "files", pane: "Privacy_FilesAndFolders"),
        Service(id: "SystemPolicyDocumentsFolder", label: "Documents folder", group: "files", pane: "Privacy_FilesAndFolders"),
        Service(id: "SystemPolicyDownloadsFolder", label: "Downloads folder", group: "files", pane: "Privacy_FilesAndFolders"),
        Service(id: "SystemPolicyNetworkVolumes", label: "Network volumes", group: "files", pane: "Privacy_FilesAndFolders"),
        Service(id: "SystemPolicyRemovableVolumes", label: "Removable volumes", group: "files", pane: "Privacy_FilesAndFolders"),
        Service(id: "SystemPolicyAppData", label: "Other apps' data", group: "files", pane: "Privacy_AppData"),
        Service(id: "SystemPolicyAppBundles", label: "App management", group: "files", pane: "Privacy_AppBundles"),
        Service(id: "AppleEvents", label: "Automation", group: "automation", pane: "Privacy_Automation"),
        Service(id: "AddressBook", label: "Contacts", group: "personal", pane: "Privacy_Contacts"),
        Service(id: "Calendar", label: "Calendars", group: "personal", pane: "Privacy_Calendars"),
        Service(id: "Reminders", label: "Reminders", group: "personal", pane: "Privacy_Reminders"),
        Service(id: "Photos", label: "Photos", group: "personal", pane: "Privacy_Photos"),
        Service(id: "MediaLibrary", label: "Media & Apple Music", group: "personal", pane: "Privacy_Media"),
        Service(id: "BluetoothAlways", label: "Bluetooth", group: "other", pane: "Privacy_Bluetooth"),
        Service(id: "DeveloperTool", label: "Developer tools", group: "other", pane: "Privacy_DevTools"),
    ]

    public static func service(_ id: String) -> Service? { services.first { $0.id == id } }

    /// The map's columns, in reading order: (id, label, short label).
    public static let columns: [(id: String, label: String, short: String)] = [
        ("camera", "Camera", "Cam"), ("microphone", "Microphone", "Mic"), ("screen", "Screen recording", "Screen"),
        ("accessibility", "Accessibility", "Access"), ("input", "Input monitoring", "Input"),
        ("disk", "Full Disk Access", "Disk"), ("files", "Files and folders", "Files"),
        ("automation", "Automation", "Auto"), ("personal", "Contacts, calendars, photos", "People"),
    ]

    /// What can watch you or take over the Mac.
    public static let powerful: Set<String> = ["camera", "microphone", "screen", "accessibility", "input", "disk"]

    /// System Settings for a privacy service, Login Items (`login`) or Full
    /// Disk Access (`disk`).
    public static func settingsURL(_ pane: String) -> URL {
        switch pane {
        case "login": URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
        case "disk": URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        default: URL(string: "x-apple.systempreferences:com.apple.preference.security?\(service(pane)?.pane ?? "Privacy")")!
        }
    }

    // MARK: What the page gets

    public struct Grant: Sendable, Hashable {
        public var service: String
        public var label: String
        public var group: String
        /// Partial access (some photos, some contacts).
        public var limited: Bool
        /// Automation: the app it may control.
        public var target: String?
        public var modified: Date?
        /// `tccutil` can only reset grants held by a bundle id.
        public var revocable: Bool
    }

    public struct Background: Sendable, Hashable, Identifiable {
        public enum Kind: String, Sendable { case openAtLogin = "open at login", loginItem = "login item", agent, daemon }
        /// Who can switch it: Lowtide, Lowtide with your password, or only
        /// System Settings.
        public enum Control: String, Sendable { case lowtide, admin, settings }

        public var id: String
        public var name: String
        public var kind: Kind
        /// Would start with the Mac: registered, allowed and not switched off.
        public var active: Bool
        /// Registered by the app (not switched off by the app itself).
        public var enabled: Bool
        /// Allowed in System Settings → Login Items.
        public var allowed: Bool
        /// Switched off with `launchctl disable`.
        public var overridden: Bool
        public var label: String?
        public var plist: String?
        public var executable: String?
        /// What it launches is no longer on disk.
        public var missing: Bool
        public var control: Control
        /// A broken agent of yours whose plist can go to the Trash.
        public var removable: Bool
    }

    public struct Traffic: Sendable, Hashable {
        public var bytesIn: UInt64
        public var bytesOut: UInt64
        public var hosts: Int
        public var countries: [String]
        public init(bytesIn: UInt64, bytesOut: UInt64, hosts: Int, countries: [String]) {
            self.bytesIn = bytesIn
            self.bytesOut = bytesOut
            self.hosts = hosts
            self.countries = countries
        }
    }

    public struct App: Sendable, Hashable, Identifiable {
        public var key: String
        public var name: String
        public var bundleID: String?
        public var path: String?
        public var developer: String?
        public var installed: Bool
        public var apple: Bool
        public var grants: [Grant] = []
        public var background: [Background] = []
        /// The last seven days, from the network ledger.
        public var traffic: Traffic?

        public var id: String { key }
        public var startsAtLogin: Bool { background.contains(where: \.active) }
        public var powerful: Bool { grants.contains { PermissionMap.powerful.contains($0.group) } }
        /// Something it starts at login points to a file that's gone.
        public var broken: Bool { background.contains(where: \.missing) }
        /// Gone, but left a grant or a start-up item behind.
        public var leftover: Bool { !installed || broken }
        public func has(_ column: String) -> Bool { grants.contains { $0.group == column } }
    }

    public struct Snapshot: Sendable, Hashable {
        public var apps: [App]
        /// False until Lowtide has Full Disk Access.
        public var grantsReadable: Bool
        /// False when System Events access was refused (or not asked).
        public var openAtLoginReadable: Bool
        public var scannedAt: Date

        public var broken: Int { apps.filter(\.broken).count }
        public var powerful: Int { apps.filter(\.powerful).count }
        public var startAtLogin: Int { apps.filter(\.startsAtLogin).count }
    }

    // MARK: Installed apps

    struct Installed: Sendable { let name: String; let path: String }

    /// An app bundle's id and name. An app without an id is keyed by its
    /// path; one without a readable Info.plist goes by its file name.
    static func readBundle(_ path: String) -> (String, Installed)? {
        let fallback = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let info = FileManager.default.contents(atPath: path + "/Contents/Info.plist")
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        let name = (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String) ?? fallback
        return ((info?["CFBundleIdentifier"] as? String) ?? path, Installed(name: name, path: path))
    }

    /// The `CFBundleIdentifier` of an app bundle on disk.
    static func bundleID(of path: String) -> String? {
        guard path.hasSuffix(".app") else { return nil }
        return FileManager.default.contents(atPath: path + "/Contents/Info.plist")
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }?["CFBundleIdentifier"]
            as? String
    }

    /// The apps in `dir` and its folders, `depth` levels down: vendors keep
    /// theirs in subfolders. Never looks inside an app.
    static func apps(under dir: String, depth: Int, into out: inout [String]) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        for name in names {
            let path = dir + "/" + name
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
            if name.hasSuffix(".app") {
                out.append(path)
            } else if depth > 0 {
                apps(under: path, depth: depth - 1, into: &out)
            }
        }
    }

    /// Every app bundle on the Mac, once per path (Spotlight adds to the
    /// walk: it can be off for a volume).
    static func installedApps(home: String) async -> [String: Installed] {
        var paths: [String] = []
        for root in ["/Applications", home + "/Applications", "/System/Applications"] {
            apps(under: root, depth: 2, into: &paths)
        }
        if let out = try? await Shell.run("/usr/bin/mdfind", ["-0", "kMDItemContentType == 'com.apple.application-bundle'"],
                                          timeout: .seconds(20)) {
            paths += out.stdout.split(separator: "\0").map(String.init)
        }
        var result: [String: Installed] = [:]
        for path in Set(paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }) where path.hasSuffix(".app") {
            if let (id, app) = readBundle(path), result[id] == nil || app.path < result[id]!.path { result[id] = app }
        }
        return result
    }

    /// The `.app` that contains a path, if any.
    public static func enclosingApp(_ path: String) -> String? {
        if let range = path.range(of: ".app/") { return String(path[..<range.lowerBound]) + ".app" }
        return path.hasSuffix(".app") ? path : nil
    }

    // MARK: Privacy grants

    struct Row: Sendable {
        let service: String
        let client: String
        let clientType: Int
        let authValue: Int
        let target: String?
        let modified: Int?
    }

    static let tccQuery = "select service, client, client_type, auth_value, indirect_object_identifier, last_modified "
        + "from access where auth_value >= 2"

    /// Rows from one TCC database, or nil when macOS won't let us read it.
    static func tccRows(_ db: String) async -> [Row]? {
        guard let out = try? await Shell.run("/usr/bin/sqlite3", ["-readonly", "-json", db, tccQuery], timeout: .seconds(10)),
              out.ok else { return nil }
        return parseRows(out.stdout)
    }

    static func parseRows(_ json: String) -> [Row]? {
        let text = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return [] }
        guard let list = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [[String: Any]] else { return nil }
        return list.compactMap { row in
            guard let service = row["service"] as? String, let client = row["client"] as? String else { return nil }
            return Row(service: service, client: client, clientType: (row["client_type"] as? Int) ?? 0,
                       authValue: (row["auth_value"] as? Int) ?? 0, target: row["indirect_object_identifier"] as? String,
                       modified: row["last_modified"] as? Int)
        }
    }

    // MARK: Background items

    struct Record: Sendable {
        let kind: Background.Kind
        let label: String
        let plist: String
        let executable: String?
        let disabled: Bool
    }

    /// Launch agents and daemons from their folders. Everything here is
    /// readable without a password.
    static func launchdRecords(home: String) -> [Record] {
        let folders: [(String, Background.Kind)] = [
            (home + "/Library/LaunchAgents", .agent), ("/Library/LaunchAgents", .agent), ("/Library/LaunchDaemons", .daemon),
        ]
        var records: [Record] = []
        for (folder, kind) in folders {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
            for name in names.sorted() where name.hasSuffix(".plist") {
                let path = folder + "/" + name
                guard let data = FileManager.default.contents(atPath: path),
                      let job = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let label = job["Label"] as? String else { continue }
                let executable = (job["Program"] as? String) ?? (job["ProgramArguments"] as? [String])?.first
                records.append(Record(kind: kind, label: label, plist: path, executable: executable,
                                      disabled: (job["Disabled"] as? Bool) ?? false))
            }
        }
        return records
    }

    /// Labels switched off with `launchctl disable`, from `print-disabled`.
    static func parseDisabled(_ text: String) -> Set<String> {
        Set(text.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasSuffix("=> disabled") || trimmed.hasSuffix("=> true") else { return nil }
            let parts = trimmed.split(separator: "\"", omittingEmptySubsequences: false)
            return parts.count > 1 ? String(parts[1]) : nil
        })
    }

    static func disabledLabels(_ domain: String) async -> Set<String> {
        guard let out = try? await Shell.run("/bin/launchctl", ["print-disabled", domain], timeout: .seconds(10)) else { return [] }
        return parseDisabled(out.stdout)
    }

    /// A record as the map shows it, and the app it belongs with.
    static func background(_ record: Record, home: String, disabledGUI: Set<String>,
                           disabledSystem: Set<String>) -> (item: Background, appPath: String?) {
        // A relative program name (`sh`) is found on the PATH; only an
        // absolute one can be missing.
        let executable = record.executable.flatMap { $0.hasPrefix("/") ? $0 : nil }
        let target = executable ?? record.plist
        let missing = !FileManager.default.fileExists(atPath: target)
        let overridden = (record.kind == .daemon ? disabledSystem : disabledGUI).contains(record.label)
        let removable = missing && record.plist.hasPrefix(home + "/Library/LaunchAgents/")
            && FileManager.default.fileExists(atPath: record.plist)
        let item = Background(
            id: record.plist, name: record.label, kind: record.kind, active: !record.disabled && !overridden,
            enabled: !record.disabled, allowed: true, overridden: overridden, label: record.label, plist: record.plist,
            executable: executable, missing: missing, control: record.kind == .daemon ? .admin : .lowtide, removable: removable)
        return (item, enclosingApp(target))
    }

    struct LoginItem: Sendable { let name: String; let path: String? }

    static let loginItemsScript = "JSON.stringify(Application('System Events').loginItems()"
        + ".map(i => ({ name: i.name(), path: i.path() })))"

    static func openAtLogin() async -> [LoginItem]? {
        guard let out = try? await Shell.run("/usr/bin/osascript", ["-l", "JavaScript", "-e", loginItemsScript],
                                             timeout: .seconds(15)), out.ok,
              let list = (try? JSONSerialization.jsonObject(with: Data(out.stdout.utf8))) as? [[String: Any]]
        else { return nil }
        return list.compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            let path = (item["path"] as? String).flatMap { $0.isEmpty || $0 == "missing value" ? nil : $0 }
            return LoginItem(name: name, path: path)
        }
    }

    // MARK: Putting it together

    struct Builder {
        let installed: [String: Installed]
        /// App path → bundle id, for items that only know a path.
        let byPath: [String: String]
        var apps: [String: App] = [:]

        init(installed: [String: Installed]) {
            self.installed = installed
            byPath = Dictionary(installed.map { ($0.value.path, $0.key) }, uniquingKeysWith: { a, _ in a })
        }

        /// The key of the entry for a bundle id, a bare path, or a
        /// standalone job, created on first use.
        mutating func entry(bundleID: String?, path: String?, name: String) -> String {
            // Only a real bundle names an id: a bare tool's path is not one.
            let fromPath = path.flatMap { byPath[$0] ?? PermissionMap.bundleID(of: $0) }
            let id = bundleID ?? fromPath
            let key = id ?? path ?? name
            guard apps[key] == nil else { return key }
            let found = id.flatMap { installed[$0] }
            let apple = id?.hasPrefix("com.apple.") ?? false
            let onDisk = path.map { FileManager.default.fileExists(atPath: $0) } ?? false
            // A gone app is only known by its bundle id; its last part alone
            // ("app", "desktop") says nothing.
            let shown = found?.name ?? (apple ? nil : id) ?? name
            apps[key] = App(key: key, name: shown, bundleID: id, path: found?.path ?? path, developer: apple ? "Apple" : nil,
                            // Apple's own tools live in places Spotlight doesn't index.
                            installed: found != nil || onDisk || apple, apple: apple)
            return key
        }
    }

    /// The installed app from the same vendor as a helper's launchd label:
    /// `com.docker.socket` belongs with `com.docker.docker`.
    static func vendorApp(_ label: String, installed: some Collection<String>) -> String? {
        let parts = label.split(separator: ".")
        guard parts.count > 2 else { return nil }
        let vendor = "\(parts[0]).\(parts[1])."
        guard vendor != "com.apple." else { return nil }
        return installed.filter { $0.hasPrefix(vendor) }.sorted().first
    }

    static func addGrants(_ builder: inout Builder, _ rows: [Row]) {
        for row in rows {
            let id = row.service.hasPrefix("kTCCService") ? String(row.service.dropFirst(11)) : row.service
            let known = service(id)
            let byPath = row.clientType == 1
            let name = byPath ? (row.client as NSString).lastPathComponent
                : String(row.client.split(separator: ".").last ?? Substring(row.client))
            let key = byPath
                ? builder.entry(bundleID: nil, path: enclosingApp(row.client) ?? row.client, name: name)
                : builder.entry(bundleID: row.client, path: nil, name: name)
            // `tccutil` works by bundle id (deleted apps through a stand-in);
            // grants held by a bare path only System Settings can drop.
            let revocable = !byPath && builder.apps[key]?.bundleID != nil
            builder.apps[key]?.grants.append(Grant(
                service: id, label: known?.label ?? id, group: known?.group ?? "other", limited: row.authValue == 3,
                target: row.target.flatMap { $0.isEmpty || $0 == "UNUSED" ? nil : $0 },
                modified: row.modified.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil },
                revocable: revocable))
        }
    }

    /// Reads the map. `loginItems` asks System Events for the Open at Login
    /// list (macOS asks once to allow that); `traffic` names last week's
    /// traffic per app when the network monitor can.
    public static func scan(home: String = Paths.home.path, loginItems: Bool,
                            traffic: (@Sendable (String) async -> Traffic?)? = nil) async -> Snapshot {
        let uid = RunProcessTable.currentUID
        async let installed = installedApps(home: home)
        async let userRows = tccRows(home + "/Library/Application Support/com.apple.TCC/TCC.db")
        async let systemRows = tccRows("/Library/Application Support/com.apple.TCC/TCC.db")
        async let login = loginItems ? openAtLogin() : nil
        async let disabledGUI = disabledLabels("gui/\(uid)")
        async let disabledSystem = disabledLabels("system")
        let records = launchdRecords(home: home)

        let apps = await installed
        var builder = Builder(installed: apps)
        let user = await userRows, system = await systemRows
        addGrants(&builder, user ?? [])
        addGrants(&builder, system ?? [])

        let gui = await disabledGUI, sys = await disabledSystem
        for record in records {
            let (item, appPath) = background(record, home: home, disabledGUI: gui, disabledSystem: sys)
            let key = appPath == nil ? vendorApp(record.label, installed: apps.keys) : nil
            let standalone = key == nil && appPath == nil
            let entry = builder.entry(bundleID: key, path: appPath, name: item.name)
            // A helper with no app: it exists if what it runs does.
            if standalone { builder.apps[entry]?.installed = !item.missing }
            if item.missing, let appPath, !FileManager.default.fileExists(atPath: appPath) {
                builder.apps[entry]?.installed = false
            }
            builder.apps[entry]?.background.append(item)
        }

        let loginList = await login
        for item in loginList ?? [] {
            let missing = item.path.map { !FileManager.default.fileExists(atPath: $0) } ?? true
            let entry = builder.entry(bundleID: nil, path: item.path, name: item.name)
            if missing { builder.apps[entry]?.installed = false }
            builder.apps[entry]?.background.append(Background(
                id: "login:\(item.name)", name: item.name, kind: .openAtLogin, active: !missing, enabled: true, allowed: true,
                overridden: false, label: nil, plist: nil, executable: item.path, missing: missing, control: .lowtide,
                removable: false))
        }

        var list = Array(builder.apps.values)
        if let traffic {
            for index in list.indices { list[index].traffic = await traffic(list[index].name) }
        }
        list.sort { ($0.name.lowercased(), $0.key) < ($1.name.lowercased(), $1.key) }
        return Snapshot(apps: list, grantsReadable: user != nil || system != nil, openAtLoginReadable: loginList != nil,
                        scannedAt: .now)
    }
}

/// Changing what the map shows, only for what the last scan showed (so the
/// page can't reset anything it wasn't shown).
public actor PermissionActions {
    public static let shared = PermissionActions()

    private var last: PermissionMap.Snapshot?
    /// The privileged helper's launchd switch, when one is installed: (on,
    /// label) → done, or nil to fall back to the password prompt.
    private var privilegedLaunchd: (@Sendable (Bool, String) async -> Bool?)?

    public func remember(_ snapshot: PermissionMap.Snapshot) { last = snapshot }
    public func setPrivilegedLaunchd(_ hook: (@Sendable (Bool, String) async -> Bool?)?) { privilegedLaunchd = hook }

    static func refused(_ message: String) -> LowtideError { .invalid(message) }

    /// Resets one grant (or `All` of an app's), as the ✕ in System
    /// Settings would.
    public func revoke(key: String, service: String) async throws {
        guard let app = last?.apps.first(where: { $0.key == key }) else {
            throw Self.refused("That app isn't on the map any more. Rescan and try again.")
        }
        guard app.grants.contains(where: { (service == "All" || $0.service == service) && $0.revocable }) else {
            throw Self.refused("macOS can only remove this one in System Settings.")
        }
        guard let bundleID = app.bundleID else { throw Self.refused("No bundle id to reset.") }
        if app.installed {
            try await Shell.check("/usr/bin/tccutil", ["reset", service, bundleID], timeout: .seconds(20))
        } else {
            try await Self.resetGone(service: service, bundleID: bundleID)
        }
    }

    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/"
        + "LaunchServices.framework/Support/lsregister"

    /// `tccutil` refuses a bundle id Launch Services can't find, which is
    /// every deleted app. So register an empty stand-in bundle with that id
    /// for a moment, reset, and remove the stand-in again. The reset is
    /// keyed by the id, so it clears exactly the grants the deleted app left.
    public static func resetGone(service: String, bundleID: String) async throws {
        guard Paths.safeID(bundleID) != nil else { throw refused("That app has an unusual id; use System Settings.") }
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
        _ = try? await Shell.run(lsregister, ["-f", "-R", app.path])
        // Registration lands a moment later.
        var failure: Error = refused("Launch Services didn't pick up the stand-in.")
        var done = false
        for _ in 0..<8 where !done {
            do {
                try await Shell.check("/usr/bin/tccutil", ["reset", service, bundleID], timeout: .seconds(20))
                done = true
            } catch {
                failure = error
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        _ = try? await Shell.run(lsregister, ["-u", app.path])
        // Our own throwaway bundle in our cache, not the person's data.
        try? FileManager.default.removeItem(at: app)
        if !done { throw failure }
    }

    private func item(_ id: String) throws -> PermissionMap.Background {
        guard let item = last?.apps.flatMap(\.background).first(where: { $0.id == id }) else {
            throw Self.refused("That item isn't on the map any more. Rescan and try again.")
        }
        return item
    }

    static func safeLabel(_ label: String?) throws -> String {
        guard let label, let safe = Paths.safeID(label) else {
            throw refused("That job has an unusual name; switch it in System Settings.")
        }
        return safe
    }

    /// Stops or restores something that starts with the Mac.
    /// - Launch agents: `launchctl disable` in your session (no password).
    /// - Launch daemons: the same in the system domain, through the
    ///   privileged helper or after macOS asks for your password.
    /// - Open at Login apps: removed from the list through System Events.
    public func setStartup(id: String, on: Bool) async throws {
        let item = try item(id)
        switch (item.kind, item.control) {
        case (.openAtLogin, _):
            guard !on else { throw Self.refused("Add it back from System Settings → Login Items.") }
            let name = item.name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            try await Shell.check("/usr/bin/osascript", ["-e", "tell application \"System Events\" to delete login item \"\(name)\""],
                                  timeout: .seconds(20))
        case (_, .lowtide):
            let label = try Self.safeLabel(item.label)
            let domain = "gui/\(RunProcessTable.currentUID)"
            if on {
                try await Shell.check("/bin/launchctl", ["enable", "\(domain)/\(label)"])
                // Already loaded is fine.
                if let plist = item.plist { _ = try? await Shell.run("/bin/launchctl", ["bootstrap", domain, plist]) }
            } else {
                // Not running is fine.
                _ = try? await Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
                try await Shell.check("/bin/launchctl", ["disable", "\(domain)/\(label)"])
            }
        case (_, .admin):
            let label = try Self.safeLabel(item.label)
            if let done = await privilegedLaunchd?(on, label) {
                if !done { throw LowtideError.commandFailed("launchctl couldn't change \(label)") }
                return
            }
            let command = on ? "/bin/launchctl enable system/\(label)"
                : "/bin/launchctl bootout system/\(label) 2>/dev/null; /bin/launchctl disable system/\(label)"
            let result = await Admin.run(command, prompt: "Lowtide wants to \(on ? "allow" : "stop") \(label).")
            if case .failure(let refused) = result { throw LowtideError.commandFailed(refused.message) }
        case (_, .settings):
            throw Self.refused("Only System Settings → Login Items can switch this one.")
        }
    }

    /// Cleans up a start-up agent of yours whose program is gone: unloads
    /// it and moves its plist to the Trash (put it back from there to undo).
    public func trashLeftover(id: String) async throws {
        let item = try item(id)
        guard item.removable, let plist = item.plist else {
            throw Self.refused("Only a broken agent in your LaunchAgents folder can be moved to the Trash here.")
        }
        if let label = try? Self.safeLabel(item.label) {
            _ = try? await Shell.run("/bin/launchctl", ["bootout", "gui/\(RunProcessTable.currentUID)/\(label)"])
        }
        if let refusal = await Trash.move([plist]).refused.first { throw LowtideError.denied(refusal.reason) }
    }
}
