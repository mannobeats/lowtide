import LowtideKit
import SwiftUI

/// The Apps space's hooks into the app: background work started once at
/// launch and stopped at quit, its self-test steps, and its menu commands.
enum AppsLifecycle {
    private static var checker: Task<Void, Never>?

    static func launch() {
        // The cached list gives the sidebar its total at once.
        _ = InstalledAppsModel.shared
        let updates = AppUpdatesModel.shared
        // Every few hours: the check reuses fresh results, so this is cheap
        // between real checks. A short wait first keeps launch quick.
        checker = Task {
            try? await Task.sleep(for: .seconds(20))
            while !Task.isCancelled {
                updates.check(force: false)
                try? await Task.sleep(for: .seconds(AppUpdates.fresh))
            }
        }
        StatusMenu.providers.append {
            let count = AppUpdatesModel.shared.pending.count
            guard count > 0 else { return [] }
            return [StatusMenu.Line(count == 1 ? "1 app update" : "\(count) app updates", symbol: "arrow.down.circle") {
                AppModel.shared.show(.appsUpdates)
            }]
        }
    }

    static func terminate() {
        checker?.cancel()
        checker = nil
    }

    /// Checks every app again now (menu: Check for App Updates…).
    static func checkNow() {
        AppUpdatesModel.shared.view = .apps
        AppModel.shared.show(.appsUpdates)
        AppUpdatesModel.shared.check(force: true)
    }

    static var selfTests: [SelfTest.Step] {
        [
            SelfTest.Step("apps: Applications is listed") {
                let apps = InstalledApps.list(brew: [:])
                return !apps.isEmpty && apps.allSatisfy { $0.path.hasSuffix(".app") }
            },
            SelfTest.Step("apps: Safari is protected") {
                let safari = URL(fileURLWithPath: "/Applications/Safari.app")
                return AppBundles.isProtected(safari, bundleID: AppBundles.read(safari)?.bundleID)
            },
            SelfTest.Step("apps: an app's footprint maps without removing anything") {
                guard let app = InstalledApps.list(brew: [:]).first(where: { !$0.protected }) else { return true }
                do {
                    let items = await Footprint.scan(try Footprint.subject(app: app.path, prefixes: []))
                    // The app itself, or the installer's folder it sits in.
                    let ok = items.contains { app.path == $0.path || app.path.hasPrefix($0.path + "/") }
                    if !ok { print("      \(app.path): \(items.map(\.path))") }
                    return ok
                } catch {
                    print("      \(app.path): \(error.localizedDescription)")
                    return false
                }
            },
            SelfTest.Step("apps: protected folders can't be removed") {
                !Footprint.removable("/Library/Application Support") && !Footprint.removable(Paths.home.path)
            },
            SelfTest.Step("apps: the privileged helper is bundled with its launch daemon") {
                let bundle = Bundle.main.bundleURL
                guard bundle.pathExtension == "app" else { return true }
                let fm = FileManager.default
                return fm.isExecutableFile(atPath: bundle.appending(path: "Contents/Helpers/lowtide-privileged").path)
                    && fm.fileExists(atPath: bundle.appending(path: "Contents/Library/LaunchDaemons/\(PrivilegedHelper.plistName)").path)
            },
            SelfTest.Step("apps: add-ons scan") { await Addons.scan().allSatisfy { !$0.name.isEmpty } },
        ]
    }
}

/// The Apps space's menu bar commands.
struct AppsCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("Check for App Updates…") { AppsLifecycle.checkNow() }
        }
    }
}
