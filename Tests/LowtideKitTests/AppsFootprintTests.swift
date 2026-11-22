import Darwin
import Foundation
import Testing
@testable import LowtideKit

/// A scratch folder for one test, removed after.
final class AppsScratch {
    let url: URL
    var path: String { url.path }

    init(_ name: String = #function) {
        // realpath, not resolvingSymlinksInPath (which drops /private).
        let base = URL(fileURLWithPath: CleanupFS.realPath(FileManager.default.temporaryDirectory.path) ?? NSTemporaryDirectory())
        url = base.appending(path: "lowtide-apps-\(name.filter(\.isLetter))-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func dir(_ relative: String) -> String {
        let p = url.appending(path: relative)
        try? FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
        return p.path
    }

    @discardableResult
    func file(_ relative: String, _ text: String = "x") -> String {
        let p = url.appending(path: relative)
        try? FileManager.default.createDirectory(at: p.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: p)
        return p.path
    }

    func plist(_ relative: String, _ info: [String: Any]) {
        let p = url.appending(path: relative)
        try? FileManager.default.createDirectory(at: p.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: p)
    }
}

@Suite struct AppsBundleTests {
    @Test func readsTrimmedValuesAndDropsBlankOnes() throws {
        let s = AppsScratch()
        s.file("Blank.app/Contents/Info.plist", """
        <?xml version="1.0"?><plist version="1.0"><dict>\
        <key>CFBundleIdentifier</key><string> com.example.blank </string>\
        <key>CFBundleName</key><string>  </string>\
        <key>CFBundleVersion</key><string>412</string>\
        <key>SUFeedURL</key><string>https://example.com/appcast.xml</string>\
        </dict></plist>
        """)
        let info = try #require(AppBundles.read(s.url.appending(path: "Blank.app")))
        #expect(info.bundleID == "com.example.blank")
        #expect(info.name == nil)
        #expect(info.version == "412" && info.build == "412")
        #expect(info.feedURL == "https://example.com/appcast.xml")
    }

    /// Native Instruments' Info.plists repeat a key; macOS reads the file anyway.
    @Test func readsAPlistThatRepeatsAKey() throws {
        let s = AppsScratch()
        s.file("Dup.app/Contents/Info.plist", """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>com.native-instruments.Maschine3</string>
        <key>CFBundleShortVersionString</key><string>3.1.0 (R123)</string>
        <key>CFBundleIdentifier</key><string>com.native-instruments.Maschine3</string>
        </dict></plist>
        """)
        let info = try #require(AppBundles.read(s.url.appending(path: "Dup.app")))
        #expect(info.bundleID == "com.native-instruments.Maschine3")
        #expect(info.version == "3.1.0 (R123)")
    }

    @Test func findsAppsInVendorFoldersButNotInsideApps() {
        let s = AppsScratch()
        for app in ["Top.app/Contents/Helpers/Helper.app", "Vendor/Product/Deep.app", "Vendor/Product/Too/Far.app", ".Hidden.app"] { s.dir(app) }
        symlink(s.path + "/Top.app", s.path + "/Linked.app")
        let found = AppBundles.appPaths(depth: 2, roots: [s.url]).map { String($0.path.dropFirst(s.path.count + 1)) }
        #expect(found == [".Hidden.app", "Top.app", "Vendor/Product/Deep.app"])
    }

    @Test func findsHelpersButNotFrameworks() {
        let s = AppsScratch()
        for (path, id) in [("Top.app/Contents/MacOS/Top Desktop.app", "com.vendor.topdesktop"),
                           ("Top.app/Contents/Library/LoginItems/TopHelper.app", "com.vendor.top.helper"),
                           ("Top.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app", "org.sparkle-project.Updater")] {
            s.plist("\(path)/Contents/Info.plist", ["CFBundleIdentifier": id])
        }
        let found = AppBundles.nestedBundles(s.url.appending(path: "Top.app")).sorted { $0.name < $1.name }
        #expect(found.map(\.name) == ["Top Desktop", "TopHelper"])
        #expect(found.map(\.id) == ["com.vendor.topdesktop", "com.vendor.top.helper"])
    }

    @Test func vendorPrefixesNeedAProduct() {
        #expect(AppBundles.vendorPrefix("com.Adobe.Photoshop") == "com.adobe")
        #expect(AppBundles.vendorPrefix("com.adobe") == nil)
        #expect(AppBundles.alnum("Pro-Q 3") == "proq3")
        #expect(AppBundles.alnum("Café 2") == "caf2")
    }

    @Test func protectsMacOSAndItself() {
        #expect(AppBundles.isProtected(URL(fileURLWithPath: "/System/Applications/Mail.app"), bundleID: "com.apple.mail"))
        #expect(AppBundles.isProtected(URL(fileURLWithPath: "/Applications/Safari.app"), bundleID: "com.apple.Safari"))
        #expect(AppBundles.isProtected(URL(fileURLWithPath: "/Applications/Lowtide.app"), bundleID: "dev.lowtide.app"))
        #expect(!AppBundles.isProtected(URL(fileURLWithPath: "/Applications/Figma.app"), bundleID: "com.figma.Desktop"))
    }

    @Test func readsTheSigningTeam() {
        let out = "Executable=/Applications/Claude.app/Contents/MacOS/Claude\nIdentifier=com.anthropic.claudefordesktop\nFormat=app bundle with Mach-O universal (x86_64 arm64)\nTeamIdentifier=Q6L2SF6YDW\nSealed Resources version=2 rules=13 files=104\n"
        #expect(AppBundles.parseTeamID(out) == "Q6L2SF6YDW")
        #expect(AppBundles.parseTeamID("Signature=adhoc\nTeamIdentifier=not set\n") == nil)
    }

    @Test func describesAnInstalledApp() {
        let s = AppsScratch()
        s.plist("Applications/Figma.app/Contents/Info.plist", ["CFBundleIdentifier": "com.figma.Desktop", "CFBundleShortVersionString": "126.1.4"])
        let app = InstalledApps.describe(s.url.appending(path: "Applications/Figma.app"), brew: ["Figma.app": "figma"])
        #expect(app.name == "Figma" && app.version == "126.1.4" && app.source == .homebrew && app.brewToken == "figma" && !app.protected)
        #expect(app.unused(now: .now))
        var used = app
        used.lastUsed = .now.addingTimeInterval(-86_400)
        #expect(!used.unused())
    }
}

@Suite struct AppsFootprintTests {
    func subject() -> Footprint.Subject {
        var s = Footprint.Subject()
        s.bundleIDs = ["com.figma.Desktop"]
        s.names = ["Figma", "Electron"]
        s.vendor = "figma"
        s.teamID = "T8RA8NE3B7"
        return s
    }

    @Test func classifiesByStrengthOfEvidence() {
        let matcher = Footprint.Matcher(subject())
        func kind(_ name: String, logs: Bool = false) -> Footprint.Confidence? { matcher.classify(name, inLogs: logs)?.0 }
        #expect(kind("com.figma.Desktop.plist") == .exact)
        #expect(kind("com.figma.Desktop.savedState") == .exact)
        #expect(kind("T8RA8NE3B7.com.figma.Desktop") == .exact)
        #expect(kind("Figma") == .likely)
        #expect(kind(".figma") == .likely)
        #expect(kind("com.figma.agent") == .likely)
        #expect(kind("T8RA8NE3B7.shared") == .shared)
        // "Electron" is too generic to claim anything.
        #expect(kind("Electron") == nil)
        #expect(kind("com.figmaclone.app") == nil)
        #expect(kind("Figma-2026-01-01.ips", logs: true) != nil)
        #expect(kind("FigmaAgent.ips", logs: true) == .likely)
        #expect(kind("FigmaAgent.ips") == nil)
    }

    @Test func claimsHelperFilesWithoutClaimingTheDeveloper() {
        var s = Footprint.Subject()
        s.bundleIDs = ["com.docker.docker"]
        s.helperIDs = ["com.electron.dockerdesktop"]
        s.names = ["Docker", "Docker Desktop"]
        let matcher = Footprint.Matcher(s)
        func kind(_ name: String) -> Footprint.Confidence? { matcher.classify(name, inLogs: false)?.0 }
        #expect(kind("com.electron.dockerdesktop.helper") == .exact)
        // `com.electron` belongs to every Electron app, not to Docker.
        #expect(kind("com.electron.slack") == nil)
        // A group container is the developer's with `group.` in front.
        #expect(kind("group.com.docker") == .likely)
        #expect(kind("Docker Desktop") == .likely)
    }

    @Test func claimsAProductsVersionedFolderOnly() {
        var s = Footprint.Subject()
        s.bundleIDs = ["com.google.android.studio"]
        s.names = ["Android Studio"]
        let matcher = Footprint.Matcher(s)
        #expect(matcher.classify("AndroidStudio2025.3.4", inLogs: false)?.0 == .likely)
        #expect(matcher.classify("AndroidStudioPreview", inLogs: false) == nil)
        // Another app's crash settings aren't Android Studio's.
        #expect(matcher.classify("Studio Pro_C679CBE9-C0A9.plist", inLogs: true) == nil)
    }

    @Test func sharedPrefixesStayShared() {
        var s = subject()
        s.sharedPrefixes = ["com.figma"]
        #expect(Footprint.Matcher(s).classify("com.figma.agent", inLogs: false)?.0 == .shared)
    }

    @Test func matchesIDsOnComponentBoundaries() {
        #expect(Footprint.containsID("group.com.figma.desktop", "com.figma.desktop"))
        #expect(!Footprint.containsID("com.figma.desktopx", "com.figma.desktop"))
        #expect(Footprint.containsID("x.com.figma.desktopx", "com.figma.desktopx"))
        #expect(!Footprint.containsID("my com.figma.desktop", "com.figma.desktop"))
    }

    @Test func findsReceiptsByProductAndVendor() {
        let packages = ["com.Arturia.ARP2600V3.vst3", "com.Arturia.ARP2600V3.resources", "com.Arturia.Mini V4.vst3",
                        "com.other.ARP2600V3", "com.apple.pkg.Core"]
        var s = Footprint.Subject()
        s.names = ["ARP 2600 V3"]
        s.vendor = "Arturia"
        #expect(Footprint.matchingPackages(packages, s) == ["com.Arturia.ARP2600V3.vst3", "com.Arturia.ARP2600V3.resources"])
        var byID = Footprint.Subject()
        byID.bundleIDs = ["com.figma.Desktop"]
        #expect(Footprint.matchingPackages(["com.figma.desktop.pkg", "com.figma.desktopx"], byID) == ["com.figma.desktop.pkg"])
    }

    @Test func bringsSiblingReceiptsOfTheProductOnly() {
        let packages = ["com.synchroarts.RePitchVST3", "com.synchroarts.RePitchAU", "com.synchroarts.RePitchAAX",
                        "com.synchroarts.VocAlignUltraVST3", "com.synchroarts.VocAlignProAU", "com.synchroarts.VocAlign6.vst3",
                        "com.Arturia.ARP2600V3.vst3", "com.Arturia.ARP2600V3.resources", "com.Arturia.Mini V4.vst3",
                        "com.vendor.Plateau", "com.vendor.Plate.vst3"]
        #expect(Footprint.receiptSiblings(packages, known: "com.synchroarts.RePitchVST3")
            == ["com.synchroarts.RePitchVST3", "com.synchroarts.RePitchAU", "com.synchroarts.RePitchAAX"])
        #expect(Footprint.receiptSiblings(packages, known: "com.Arturia.ARP2600V3.vst3") == ["com.Arturia.ARP2600V3.vst3", "com.Arturia.ARP2600V3.resources"])
        // No format word, or only a vendor left: just the receipt itself.
        #expect(Footprint.receiptSiblings(packages, known: "com.vendor.Plateau") == ["com.vendor.Plateau"])
        #expect(Footprint.receiptSiblings(packages, known: "com.synchroarts.vst3").isEmpty)
        #expect(Footprint.receiptFamily("com.ni.Kontakt_AU") == "com.ni.kontakt")
    }

    @Test func spellsPathsAsTheDiskDoes() {
        // APFS is case-insensitive: a lowercase spelling must still meet the protected list.
        #expect(Footprint.onDisk("/library/application support") == "/Library/Application Support")
        #expect(!Footprint.removable(Footprint.onDisk("/library/application support")!))
        #expect(Footprint.onDisk("/var/folders") == "/private/var/folders")
        #expect(Footprint.onDisk("relative") == nil)
        let s = AppsScratch()
        s.file("real/target")
        symlink(s.path + "/real/target", s.path + "/real/link")
        #expect(Footprint.onDisk(s.path + "/real/link") == s.path + "/real/link")
    }

    @Test func refusesProtectedAndForeignPaths() {
        #expect(!Footprint.removable("/Library/Application Support"))
        #expect(!Footprint.removable("/System/Applications/Mail.app"))
        #expect(!Footprint.removable("/etc/hosts"))
        #expect(!Footprint.removable("/Library/Audio/Plug-Ins/VST3"))
        #expect(!Footprint.removable("/Library/Apple/System"))
        #expect(!Footprint.removable("/Applications/../etc"))
        #expect(!Footprint.removable("/private/var/folders"))
        #expect(Footprint.removable("/Library/Audio/Plug-Ins/VST3/Serum.vst3"))
        #expect(Footprint.removable("/Applications/Figma.app"))
        let home = Footprint.home
        #expect(Footprint.removable(home + "/.figma"))
        #expect(Footprint.removable(home + "/Library/Preferences/com.figma.Desktop.plist"))
        #expect(!Footprint.removable(home + "/Documents"))
        #expect(!Footprint.removable(home + "/Library/Preferences"))
        #expect(!Footprint.removable(home + "/.ssh/id_ed25519"))
    }

    @Test func reducesPackageFilesToOwnedRoots() {
        let s = AppsScratch()
        let vendor = s.path + "/Vendor", product = vendor + "/Product"
        s.file("Vendor/Product/Data/a.bin")
        s.file("Vendor/readme.txt")
        s.dir("Vendor/Other")
        let paths = [s.path, vendor, product, product + "/Data", product + "/Data/a.bin", vendor + "/readme.txt"]
        let roots = Footprint.packageRoots(paths, names: [])
        // Vendor holds "Other" (not ours): only our product and file.
        #expect(roots.contains(product))
        #expect(roots.contains(vendor + "/readme.txt"))
        #expect(!roots.contains(vendor))
        #expect(!roots.contains(product + "/Data"))
        // A folder named after the product is its own, whatever else is in it.
        s.file("Vendor/Product/Data/user-preset.fxp")
        #expect(Footprint.packageRoots(paths, names: ["Product"]).contains(product))
    }

    @Test func searchesAFolderAndLooksInsideAVendorsOne() {
        let s = AppsScratch()
        s.file("Support/Figma/settings.json")
        s.file("Support/com.figma.Desktop.plist")
        s.file("Support/figma-shared/Figma/x")   // a vendor folder holding the product
        s.dir("Support/Other")
        var vendor = Footprint.Subject()
        vendor.bundleIDs = ["com.figma.Desktop"]
        vendor.names = ["Figma"]
        vendor.vendor = "figmashared"
        var out: [Footprint.Item] = []
        Footprint.search(Footprint.Matcher(vendor), s.path + "/Support", .support, into: &out)
        let found = Dictionary(uniqueKeysWithValues: out.map { (String($0.path.dropFirst(s.path.count + 9)), $0.confidence) })
        #expect(found["Figma"] == .likely)
        #expect(found["com.figma.Desktop.plist"] == .exact)
        #expect(found["figma-shared/Figma"] == .likely)
        #expect(found["figma-shared"] == nil && found["Other"] == nil)
        #expect(out.allSatisfy { !$0.needsAdmin })
    }

    @Test func keepsTheStrongestEvidenceAndDropsNestedPaths() {
        let home = Footprint.home
        func item(_ path: String, _ c: Footprint.Confidence) -> Footprint.Item {
            .init(path: path, name: (path as NSString).lastPathComponent, category: .support, confidence: c, reason: "", isDir: true, needsAdmin: false, hidden: false)
        }
        let items = [item(home + "/Library/Application Support/Figma", .likely),
                     item(home + "/Library/Application Support/Figma", .installer),
                     item(home + "/Library/Application Support/Figma/Cache", .exact),
                     item("/etc/passwd", .exact)]
        let kept = Footprint.dedupe(items)
        #expect(kept.count == 1 && kept[0].confidence == .installer)
    }

    @Test func offersNameOnlyDotFoldersWithoutPreselectingThem() {
        let home = Footprint.home
        func item(_ path: String, _ c: Footprint.Confidence) -> Footprint.Item {
            .init(path: path, name: (path as NSString).lastPathComponent, category: .hidden, confidence: c, reason: "", isDir: true, needsAdmin: false, hidden: true)
        }
        // `~/.claude` is Claude Code's, not the Claude app's.
        #expect(Footprint.cliShared(item(home + "/.claude", .likely), home: home).confidence == .shared)
        #expect(Footprint.cliShared(item(home + "/.local/share/claude", .likely), home: home).confidence == .shared)
        #expect(Footprint.cliShared(item(home + "/.vscode", .exact), home: home).confidence == .exact)
        #expect(Footprint.cliShared(item(home + "/Library/Logs/Claude", .likely), home: home).confidence == .likely)
    }

    @Test func sortsReceiptPathsIntoCategories() {
        #expect(Footprint.category(of: "/Applications/Serum.app") == .app)
        #expect(Footprint.category(of: "/Library/Audio/Plug-Ins/VST3/Serum.vst3") == .plugins)
        #expect(Footprint.category(of: "/Library/LaunchDaemons/com.x.helper.plist") == .launch)
        #expect(Footprint.category(of: "/usr/local/bin/x") == .helpers)
        #expect(Footprint.category(of: "/Library/Xfer/Serum Presets") == .support)
    }

    @Test func listsAFoldersChildrenLargestFirst() async throws {
        let home = Footprint.home
        let base = home + "/Library/Caches/lowtide-tests-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: base + "/big", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        try Data(count: 200_000).write(to: URL(fileURLWithPath: base + "/big/a"))
        try Data(count: 10).write(to: URL(fileURLWithPath: base + "/small"))
        let children = try await Footprint.children(base)
        #expect(children.map(\.name) == ["big", "small"])
        #expect(children[0].isDir && (children[0].bytes ?? 0) >= 200_000)
        await #expect(throws: LowtideError.self) { try await Footprint.children("/Library") }
    }
}

@Suite struct AppsDiskUsageTests {
    @Test func countsAllocatedBytesOnceForHardLinks() async throws {
        let s = AppsScratch()
        try Data(count: 100_000).write(to: s.url.appending(path: "a"))
        try FileManager.default.createDirectory(at: s.url.appending(path: "d/e"), withIntermediateDirectories: true)
        try Data(count: 50_000).write(to: s.url.appending(path: "d/e/b"))
        link(s.path + "/a", s.path + "/d/a-link")
        symlink("/usr/bin", s.path + "/d/bin")
        var a = stat(), b = stat()
        lstat(s.path + "/a", &a)
        lstat(s.path + "/d/e/b", &b)
        var l = stat()
        lstat(s.path + "/d/bin", &l)
        let expected = Int64(a.st_blocks) * 512 + Int64(b.st_blocks) * 512 + Int64(l.st_blocks) * 512
        #expect(await DiskSize.measure(s.path) == expected)
        #expect(await DiskSize.measure(s.path + "/a") == Int64(a.st_blocks) * 512)
        #expect(await DiskSize.measure(s.path + "/missing") == nil)
    }

    @Test func measuresSeveralInOrder() async {
        let s = AppsScratch()
        s.file("x", String(repeating: "x", count: 9000))
        let sizes = await DiskSize.measure([s.path + "/x", s.path + "/none", s.path])
        #expect(sizes[0] != nil && sizes[1] == nil && sizes[2] == sizes[0])
    }
}

@Suite struct AppsRemoverTests {
    @Test func movesRootFilesInOneScript() {
        let plan = Trash.adminScript(["/Library/LaunchDaemons/com.x.helper.plist", "/Library/X/it's.txt", "/Library/Y/it's.txt",
                                      "/Library/LaunchAgents/com.x.agent.plist"], uid: 501, gid: 20)
        #expect(plan.destinations.count == 4)
        #expect(Set(plan.destinations).count == 4)
        #expect(plan.script.contains("/bin/launchctl bootout gui/501 '/Library/LaunchAgents/com.x.agent.plist' 2>/dev/null; /bin/mv -f "))
        #expect(plan.script.hasPrefix("/bin/launchctl bootout system '/Library/LaunchDaemons/com.x.helper.plist' 2>/dev/null; /bin/mv -f "))
        #expect(plan.script.contains("'/Library/X/it'\\''s.txt'"))
        #expect(plan.script.contains("/usr/sbin/chown -R 501:20 "))
        #expect(plan.destinations.allSatisfy { $0.hasPrefix(Paths.home.path + "/.Trash/") })
    }

    @Test func splitsWhatThePersonOwnsFromWhatRootDoes() {
        let s = AppsScratch()
        let mine = s.file("mine")
        #expect(!Trash.needsAdmin(mine))
        #expect(Trash.needsAdmin("/usr/bin/true"))
    }

    @Test func refusesProtectedPathsAndPutsTrashedFilesBack() async throws {
        let home = Footprint.home
        let dir = home + "/Library/Caches/lowtide-remover-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/leftover.plist"
        try Data("x".utf8).write(to: URL(fileURLWithPath: file))
        let report = await AppRemover.remove([AppRemover.Request(name: "Test", paths: [file, "/Library/Application Support", "/nonexistent"])])
        let outcome = try #require(report.outcomes.first)
        #expect(outcome.removed == [file])
        #expect(outcome.failed.map(\.path) == ["/Library/Application Support"])
        #expect(!FileManager.default.fileExists(atPath: file))
        let trashed = try #require(report.moved.first?.trashed)
        #expect(trashed.contains("/.Trash/"))
        let back = await Trash.putBack(report.moved)
        #expect(back.restored == 1 && back.failed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file))
    }
}

@Suite struct AppsAddonTests {
    @Test func localizesChromeNames() {
        let s = AppsScratch()
        s.file("_locales/en/messages.json", #"{"appName": {"message": "Claude"}}"#)
        #expect(Addons.localized("__MSG_APPNAME__", version: s.path, manifest: ["default_locale": "en"]) == "Claude")
        #expect(Addons.localized("Plain", version: s.path, manifest: [:]) == "Plain")
        #expect(Addons.localized("__MSG_missing__", version: s.path, manifest: [:]) == "__MSG_missing__")
    }

    @Test func matchesExtensionsIgnoringCase() {
        #expect(Addons.hasExtension("/x/Flurry.SAVER", ["saver", "qtz"]))
        #expect(!Addons.hasExtension("/x/a.zip", ["saver", "qtz"]))
    }

    @Test func readsChromeProfiles() {
        let s = AppsScratch()
        let root = "Library/Application Support/Google/Chrome"
        s.file("\(root)/Local State", #"{"profile":{"info_cache":{"Default":{"name":"Work"},"Profile 1":{"name":"Home"}}}}"#)
        s.file("\(root)/Default/Extensions/abc/1.0_0/manifest.json", #"{"name":"__MSG_n__","version":"1.0","default_locale":"en","icons":{"16":"i16.png","128":"/i128.png"}}"#)
        s.file("\(root)/Default/Extensions/abc/1.0_0/_locales/en/messages.json", #"{"n":{"message":"Grammar"}}"#)
        s.file("\(root)/Default/Extensions/abc/1.0_0/i128.png", "png")
        s.file("\(root)/Profile 1/Extensions/def/2.1_0/manifest.json", #"{"name":"Dark Reader","version":"2.1"}"#)
        s.dir("\(root)/Profile 1/Extensions/empty")
        var out: [Addon] = []
        Addons.chromium(home: s.path, into: &out)
        let byName = Dictionary(uniqueKeysWithValues: out.map { ($0.name, $0) })
        #expect(out.count == 2)
        #expect(byName["Grammar"]?.source == "Google Chrome · Work")
        #expect(byName["Grammar"]?.icon?.hasSuffix("1.0_0/i128.png") == true)
        #expect(byName["Dark Reader"]?.source == "Google Chrome · Home" && byName["Dark Reader"]?.version == "2.1")
        #expect(byName["Grammar"]?.browser?.bundleIDs == ["com.google.Chrome"])
    }

    @Test func readsFirefoxProfilesWithoutMozillasOwn() {
        let s = AppsScratch()
        let ext = s.file("Library/Application Support/Firefox/Profiles/x1y2.default-release/extensions/ublock@x.xpi")
        let json = #"{"addons":[{"location":"app-profile","signedState":2,"path":"\#(ext)","version":"1.60","defaultLocale":{"name":"uBlock Origin"}},{"location":"app-profile","signedState":3,"path":"\#(ext)","defaultLocale":{"name":"New Tab"}},{"location":"app-system-defaults","path":"\#(ext)","defaultLocale":{"name":"Screenshots"}}]}"#
        s.file("Library/Application Support/Firefox/Profiles/x1y2.default-release/extensions.json", json)
        var out: [Addon] = []
        Addons.firefox(home: s.path, into: &out)
        #expect(out.map(\.name) == ["uBlock Origin"])
        #expect(out.first?.source == "Firefox · default-release")
    }

    @Test func readsBundlesInLibraryFolders() {
        let s = AppsScratch()
        s.plist("Library/Screen Savers/Aerial.saver/Contents/Info.plist", ["CFBundleName": "Aerial", "CFBundleShortVersionString": "3.4"])
        s.dir("Library/Screen Savers/notes")
        var out: [Addon] = []
        Addons.bundles(home: s.path, into: &out)
        let mine = out.filter { $0.id.hasPrefix(s.path) }
        #expect(mine.map(\.name) == ["Aerial"] && mine.first?.version == "3.4" && mine.first?.kind == .screensaver)
        #expect(mine.first?.source == "For you")
    }

    @Test func readsPluginkitOutput() {
        // `pluginkit -mAv -p com.apple.widgetkit-extension`, as it prints.
        let out = "     com.apple.PeopleViewService.PeopleWidget-macOS(1.0)\tD9F5FF8E-4FD2-59E2-921D-C131E5417F2E\t2026-11-12 15:42:39 +0000\t/System/Library/CoreServices/PeopleViewService.app/Contents/PlugIns/PeopleWidget-macOS.appex\n+    com.tinyspeck.slackmacgap.widget(4.41)\tABCD\t2026-11-12 15:42:39 +0000\t/Applications/Slack.app/Contents/PlugIns/SlackWidget.appex\n"
        #expect(Addons.registeredPaths(out) == ["/Applications/Slack.app/Contents/PlugIns/SlackWidget.appex"])
    }
}

@Suite struct AppsPluginTests {
    @Test func takesTheVendorFromReverseDNSOnly() {
        #expect(AudioPlugins.vendorFromID("com.arturia.Pigments") == "Arturia")
        #expect(AudioPlugins.vendorFromID("jp.co.roland.zenology") == "Roland")
        #expect(AudioPlugins.vendorFromID("Maschine 3.vst3") == nil)
    }

    func found(_ name: String, _ format: String, _ path: String, _ vendor: String?) -> AudioPlugins.Found {
        .init(stem: name, format: PluginFormat(format: format, path: path, user: false, bundleID: nil, version: "1.0"), vendor: vendor)
    }

    @Test func keepsOneVendorHoweverEachFormatSpellsIt() {
        let products = AudioPlugins.group([found("Relay", "AU", "/a/Relay.component", "Waves"),
                                           found("Relay", "VST3", "/a/Relay.vst3", "WavesAudio"),
                                           found("Relay", "VST3", "/b/Relay.vst3", "Other")])
        #expect(products.count == 2)
        #expect(products.first { $0.vendor == "Waves" }?.formats.count == 2)
    }

    @Test func groupsFormatsIntoProducts() {
        let products = AudioPlugins.group([found("Serum", "VST3", "/a/Serum.vst3", "Xfer Records"),
                                           found("Serum", "AU", "/a/Serum.component", nil),
                                           found("Pro-Q 3", "VST3", "/a/Pro-Q 3.vst3", "FabFilter"),
                                           found("Reverb", "VST3", "/a/Reverb.vst3", "VendorA"),
                                           found("Reverb", "VST3", "/b/Reverb.vst3", "VendorB")])
        let serum = products.first { $0.name == "Serum" }
        #expect(serum?.formats.count == 2 && serum?.vendor == "Xfer Records")
        #expect(serum?.formatNames == ["AU", "VST3"])
        #expect(products.filter { $0.name == "Reverb" }.count == 2)
    }

    @Test func scansPluginFoldersAndVendorGroupings() {
        let s = AppsScratch()
        s.plist("Library/Audio/Plug-Ins/Components/Pigments.component/Contents/Info.plist",
                ["CFBundleIdentifier": "com.arturia.Pigments", "AudioComponents": [["name": "Arturia: Pigments"]]])
        s.plist("Library/Audio/Plug-Ins/VST/Arturia/Pigments.vst/Contents/Info.plist", ["CFBundleIdentifier": "com.arturia.pigments.vst"])
        let mine = AudioPlugins.group(AudioPlugins.scan(home: s.path).filter { $0.format.path.hasPrefix(s.path) })
        #expect(mine.count == 1)
        #expect(mine.first?.vendor == "Arturia" && mine.first?.formatNames == ["AU", "VST"])
        #expect(mine.first?.formats.allSatisfy(\.user) == true)
    }
}

@Suite struct AppsHelperTests {
    @Test func speaksOneLineOverAUnixSocket() async throws {
        let path = "/tmp/lowtide-helper-\(UUID().uuidString.prefix(6)).sock"
        defer { unlink(path) }
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            let bytes = Array(path.utf8)
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        #expect(bound == 0)
        listen(server, 1)
        let thread = Thread {
            let client = accept(server, nil, nil)
            var buffer = [UInt8](repeating: 0, count: 1024)
            let n = read(client, &buffer, buffer.count)
            let request = String(decoding: buffer[0..<max(n, 0)], as: UTF8.self)
            let answer = request.contains("\"ping\"") ? "{\"ok\":true}\n{\"ignored\":1}\n" : "{\"ok\":false}\n"
            _ = answer.withCString { write(client, $0, strlen($0)) }
            close(client)
            close(server)
        }
        thread.start()
        let reply = PrivilegedHelper.exchange(Data("{\"op\":\"ping\"}\n".utf8), path: path, timeout: 5)
        let json = try #require(reply.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(json["ok"] as? Bool == true)
        #expect(PrivilegedHelper.exchange(Data("x\n".utf8), path: "/tmp/lowtide-no-such.sock", timeout: 1) == nil)
    }

    @Test func isUnavailableOutsideAnAppBundle() {
        #expect(PrivilegedHelper.state == .unavailable)
    }
}

@Suite(.serialized) struct AppsUninstallFlowTests {
    /// A throwaway app in ~/Applications with leftovers where apps leave
    /// them: mapped, moved to the Trash in one batch, then put back.
    @Test func mapsRemovesAndPutsBackAnApp() async throws {
        let home = Footprint.home
        let id = "dev.lowtide.test.dummy\(UUID().uuidString.prefix(6).lowercased())"
        let name = "LowtideDummy\(id.suffix(6))"
        let app = home + "/Applications/\(name).app"
        let fm = FileManager.default
        try fm.createDirectory(atPath: app + "/Contents/MacOS", withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundleShortVersionString": "1.0"],
                                           format: .xml, options: 0).write(to: URL(fileURLWithPath: app + "/Contents/Info.plist"))
        let prefs = home + "/Library/Preferences/\(id).plist"
        let support = home + "/Library/Application Support/\(name)"
        let caches = home + "/Library/Caches/\(id)"
        try Data("x".utf8).write(to: URL(fileURLWithPath: prefs))
        try fm.createDirectory(atPath: support + "/Data", withIntermediateDirectories: true)
        try Data(count: 5000).write(to: URL(fileURLWithPath: support + "/Data/db"))
        try fm.createDirectory(atPath: caches, withIntermediateDirectories: true)
        let all = [app, prefs, support, caches]
        defer { for path in all { try? fm.removeItem(atPath: path) } }

        let subject = try await Footprint.subject(app: app, prefixes: [])
        let items = await Footprint.scan(subject)
        let found = Dictionary(uniqueKeysWithValues: items.map { ($0.path, $0.confidence) })
        #expect(found[app] == .primary)
        #expect(found[prefs] == .exact)
        #expect(found[caches] == .exact)
        #expect(found[support] == .likely)
        #expect(items.first { $0.path == support }?.bytes ?? 0 >= 5000)

        let paths = items.filter(\.preselected).map(\.path)
        let report = await AppRemover.remove([AppRemover.Request(name: name, paths: paths, quitBundleID: nil)])
        #expect(Set(report.outcomes[0].removed).isSuperset(of: all))
        #expect(all.allSatisfy { !fm.fileExists(atPath: $0) })
        #expect(report.moved.allSatisfy { $0.trashed?.contains("/.Trash/") == true })

        let back = await Trash.putBack(report.moved)
        #expect(back.failed.isEmpty)
        #expect(all.allSatisfy { fm.fileExists(atPath: $0) })
    }
}
