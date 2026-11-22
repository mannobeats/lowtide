import Foundation
import Testing
@testable import LowtideKit

/// A scratch folder under the system temp dir, removed when the test ends.
/// Only files the test made are ever removed.
final class CleanupScratch {
    let root: String
    init(_ name: String = #function) {
        let base = CleanupFS.realPath(NSTemporaryDirectory()) ?? NSTemporaryDirectory()
        root = CleanupFS.join(base, "lowtide-cleanup-\(name.filter(\.isLetter))-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(atPath: root) }

    func path(_ relative: String) -> String { CleanupFS.join(root, relative) }

    @discardableResult
    func dir(_ relative: String) -> String {
        let p = path(relative)
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    @discardableResult
    func file(_ relative: String, _ text: String = "x", bytes: Int? = nil) -> String {
        let p = path(relative)
        dir(CleanupFS.parent(relative))
        let data = bytes.map { Data(repeating: 0x61, count: $0) } ?? Data(text.utf8)
        FileManager.default.createFile(atPath: p, contents: data)
        return p
    }

    func touch(_ relative: String, daysAgo: Double) {
        let date = Date().addingTimeInterval(-daysAgo * 86_400)
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path(relative))
    }
}

@Suite struct DiskSizeTests {
    /// `du -skx` in bytes, the reference the measurer must match.
    func du(_ path: String) async throws -> Int64 {
        let text = try await Shell.check("/usr/bin/du", ["-skx", path])
        return (Int64(text.split(separator: "\t").first ?? "0") ?? 0) * 1024
    }

    @Test func matchesDuOnATreeWithLinksAndSparseFiles() async throws {
        let s = CleanupScratch()
        for i in 0..<40 { s.file("a/b\(i % 4)/c/file\(i).bin", bytes: 1000 * (i + 1)) }
        s.file("big/one.bin", bytes: 3_000_000)
        // A hard link inside the tree: one file's blocks, counted once.
        try FileManager.default.linkItem(atPath: s.path("big/one.bin"), toPath: s.path("big/two.bin"))
        // A link is counted as a link, never followed.
        try FileManager.default.createSymbolicLink(atPath: s.path("a/link"), withDestinationPath: "/usr")
        // Sparse: 1 GB apparent, almost nothing allocated.
        let sparse = FileHandle(forWritingAtPath: s.file("sparse.img", ""))!
        try sparse.seek(toOffset: 1_000_000_000)
        try sparse.write(contentsOf: Data([1]))
        try sparse.close()

        let measured = await DiskSize.measure(s.root)
        #expect(measured == (try await du(s.root)))
        #expect(measured! < 100_000_000)
    }

    @Test func reportsEveryRootAndSingleFiles() async throws {
        let s = CleanupScratch()
        s.file("one/x.bin", bytes: 10_000)
        s.file("two/y.bin", bytes: 50_000)
        s.dir("empty")
        let roots = [s.path("one"), s.path("two"), s.path("empty")]
        let sizes = CleanupLock([Int: Int64]())
        await DiskSize.measureEach(roots, threads: 3) { index, bytes in sizes.update { $0[index] = bytes } }
        #expect(sizes.value.count == 3)
        #expect(sizes.value[2] == 0)
        #expect(sizes.value[0] == (try await du(roots[0])))
        #expect(await DiskSize.measure(s.path("two/y.bin")) == (try await du(s.path("two/y.bin"))))
        #expect(await DiskSize.measure(s.path("missing")) == nil)
    }

    @Test func stopsWhenAsked() async {
        let s = CleanupScratch()
        for i in 0..<20 { s.file("d\(i)/f", bytes: 10) }
        let reported = CleanupLock(0)
        await DiskSize.measureEach([s.root], threads: 2, stop: { true }) { _, _ in reported.value += 1 }
        #expect(reported.value == 0)
    }

    /// `LOWTIDE_REAL_DU=<folder>`: this Mac's folder against `du`, timed.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOWTIDE_REAL_DU"] != nil))
    func matchesDuOnARealFolder() async throws {
        let path = ProcessInfo.processInfo.environment["LOWTIDE_REAL_DU"]!
        let clock = ContinuousClock()
        var ours: Int64?
        let fast = await clock.measure { ours = await DiskSize.measure(path, timeout: .seconds(600)) }
        var theirs: Int64 = 0
        let slow = try await clock.measure { theirs = try await du(path) }
        print("measure \(ours ?? -1) in \(fast), du \(theirs) in \(slow)")
        // Files changing under a live folder move a few KB between the walks.
        #expect(abs((ours ?? 0) - theirs) < max(theirs / 1000, 1_000_000))
    }

    @Test func readsTheVolume() {
        let volume = DiskSize.volume(at: NSHomeDirectory())
        #expect(volume != nil && volume!.total > volume!.available && volume!.available > 0)
    }
}

@Suite struct CleanupTargetTests {
    @Test func listsOnlyPnpmStoreVersionFolders() {
        let s = CleanupScratch()
        for dir in ["v3", "v10", "v11", "vtmp", "v", "tmp"] { s.dir("store/\(dir)") }
        s.file("store/v12")
        #expect(CleanupTargets.storeVersions(s.path("store")).map(CleanupFS.name) == ["v3", "v10", "v11"])
        let pnpm = CleanupTargets.caches.first { $0.id == "pnpm" }!
        #expect(CleanupTargets.describe(pnpm, path: s.path("store")).hasPrefix("Holds v3, v10, v11: pnpm prunes"))
    }

    /// pnpm must be told the store it prunes and where to
    /// run, or a Finder-launched app (cwd `/`) fails with EROFS.
    @Test func runsPnpmOnTheMeasuredStoreOnly() {
        let store = "/Users/me/Library/pnpm/store"
        #expect(CleanupTargets.pnpmArguments(store: store, ["store", "prune"])
            == ["--dir", store, "store", "prune", "--store-dir", store])
        #expect(CleanupTargets.activeStore(reported: "\n\(store)/v10\n", store: store) == "\(store)/v10")
        #expect(CleanupTargets.activeStore(reported: "/Volumes/X/.pnpm-store/v10", store: store) == nil)
        #expect(CleanupTargets.activeStore(reported: "", store: store) == nil)
    }

    @Test func findsOnlyRealBuildFolders() {
        let s = CleanupScratch()
        s.dir("web/node_modules/react/node_modules")
        s.file("web/package.json", "{}")
        s.dir("tools/cli/target/debug")
        s.file("tools/cli/Cargo.toml", "")
        s.dir("notes/target")
        s.dir("app/.next")
        s.file("app/package.json", "{}")
        s.dir(".hidden/node_modules")
        s.file(".hidden/package.json")
        var found: [String] = []
        CleanupTargets.findArtifacts(in: [s.root]) { found.append(String($0.path.dropFirst(s.root.count + 1))) }
        #expect(found.sorted() == ["app/.next", "tools/cli/target", "web/node_modules"])
        #expect(CleanupTargets.artifactRule(s.path("notes/target")) == nil)
    }

    @Test func dropsNestedAndDuplicateRoots() {
        let s = CleanupScratch()
        s.dir("Developer/team")
        s.dir("code")
        s.dir("elsewhere/repo/.git")
        s.dir("elsewhere/repo/src")
        let roots = CleanupTargets.defaultRoots(recentDirs: [s.path("elsewhere/repo/src"), s.path("Developer/team"), "relative"],
                                                home: s.root)
        #expect(roots == [s.path("Developer"), s.path("code"), s.path("elsewhere")])
    }

    @Test func cleansOnlyUnlinkedBuildFoldersInHome() throws {
        let s = CleanupScratch()
        s.dir("home/proj/node_modules")
        s.file("home/proj/package.json")
        s.dir("home/lonely/node_modules")
        s.dir("outside/node_modules")
        s.file("outside/package.json")
        s.dir("home/linked")
        s.file("home/linked/package.json")
        try FileManager.default.createSymbolicLink(atPath: s.path("home/linked/node_modules"), withDestinationPath: s.path("home/proj/node_modules"))
        let home = s.path("home")
        #expect(CleanupTargets.validArtifact(s.path("home/proj/node_modules"), home: home) == s.path("home/proj/node_modules"))
        #expect(CleanupTargets.validArtifact(s.path("home/lonely/node_modules"), home: home) == nil)
        #expect(CleanupTargets.validArtifact(s.path("outside/node_modules"), home: home) == nil)
        #expect(CleanupTargets.validArtifact(s.path("home/linked/node_modules"), home: home) == nil)
        // A HOME reached through a link still counts as HOME.
        try FileManager.default.createSymbolicLink(atPath: s.path("home-link"), withDestinationPath: home)
        #expect(CleanupTargets.validArtifact(s.path("home-link/proj/node_modules"), home: s.path("home-link")) != nil)
    }

    @Test func preselectsSafeCachesAndStaleProjects() {
        let now = Date()
        func item(_ group: Reclaimable.Group, _ safety: Reclaimable.Safety, daysAgo: Double?) -> Reclaimable {
            Reclaimable(id: UUID().uuidString, group: group, name: "x", description: "", path: "/x", safety: safety, action: "",
                        lastActive: daysAgo.map { now.addingTimeInterval(-$0 * 86_400) })
        }
        #expect(item(.caches, .safe, daysAgo: nil).preselected(now: now))
        #expect(!item(.caches, .review, daysAgo: nil).preselected(now: now))
        #expect(item(.projects, .safe, daysAgo: 45).preselected(now: now))
        #expect(!item(.projects, .safe, daysAgo: 3).preselected(now: now))
        #expect(!item(.projects, .safe, daysAgo: nil).preselected(now: now))
        #expect(!item(.projects, .review, daysAgo: 90).preselected(now: now))
    }

    @Test func trashesAndPutsBack() async {
        let s = CleanupScratch()
        let file = s.file("keep/me.txt", "hello")
        let outcome = await Trash.move([file, s.path("missing")])
        #expect(outcome.removed == [file] && outcome.refused.isEmpty)
        #expect(!CleanupFS.exists(file))
        let stayed = await Trash.putBack(outcome.undoable).failed
        #expect(stayed.isEmpty)
        #expect(String(decoding: FileManager.default.contents(atPath: file) ?? Data(), as: UTF8.self) == "hello")
    }

    @Test func putsBackIntoAFolderThatWentToo() async throws {
        let s = CleanupScratch()
        let file = s.file("gone/inner/me.txt", "hello")
        let outcome = await Trash.move([file])
        let moved = try #require(outcome.moved.first)
        #expect(moved.original == file && moved.trashed?.contains("/.Trash/") == true && !moved.admin)
        try FileManager.default.removeItem(atPath: s.path("gone"))
        let back = await Trash.putBack(outcome.moved + [Trash.Moved(original: s.path("never"), trashed: nil)])
        #expect(back.restored == 1)
        #expect(back.failed.map(\.path) == [s.path("never")])
        #expect(CleanupFS.exists(file))
    }
}

@Suite struct DockerTests {
    let df = #"""
    {"Images":[{"ID":"sha256:a","Repository":"postgres","Tag":"16","Size":"450MB","UniqueSize":"12MB","Containers":"1","CreatedSince":"2 weeks ago"},
    {"ID":"sha256:a","Repository":"postgres","Tag":"latest","Size":"450MB","Containers":"0"},
    {"ID":"sha256:b","Repository":"<none>","Tag":"<none>","Size":"1.2GB","Containers":"0"}],
    "Containers":[{"ID":"c1","Names":"db","Image":"postgres:16","State":"exited","Status":"Exited (0) 3 days ago","Size":"8kB","RunningFor":"3 days ago"}],
    "Volumes":[{"Name":"pgdata","Driver":"local","Size":"300MB","Links":"1"},
    {"Name":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","Driver":"local","Size":"0B","Links":0}],
    "BuildCache":[{"Size":"1GB","InUse":"false"},{"Size":"500MB","InUse":"true"}]}
    """#

    @Test func readsSystemDf() {
        let inventory = Docker.parseInventory(Data(df.utf8))
        #expect(inventory.images[0].containers == 1)
        // Two tags of one image stay two rows, each removable on its own.
        #expect(inventory.images.map(\.reference) == ["postgres:16", "postgres:latest", "sha256:b"])
        #expect(inventory.images[2].dangling && inventory.images[2].bytes == 1_200_000_000)
        #expect(inventory.containers[0].state == "exited" && !inventory.containers[0].running)
        #expect(inventory.volumes[0].links == 1 && !inventory.volumes[0].anonymous)
        #expect(inventory.volumes[1].anonymous && inventory.volumes[1].links == 0)
        #expect(inventory.buildCacheBytes == 1_500_000_000 && inventory.buildCacheReclaimable == 1_000_000_000)
        #expect(inventory.unusedImageBytes == 1_650_000_000)
    }

    @Test func readsSizesAndRejectsFlags() {
        #expect(Docker.parseSize("12.5kB") == 12_500)
        #expect(Docker.parseSize("1.1GB (40%)") == 1_100_000_000)
        #expect(Docker.parseSize("0B") == 0)
        #expect(Docker.parseSize("N/A") == nil)
        #expect(Docker.validReference("sha256:abc") && Docker.validReference("postgres:16"))
        #expect(!Docker.validReference("--all") && !Docker.validReference("a;rm") && !Docker.validReference(""))
    }
}

@Suite struct DownloadsTests {
    @Test func findsInstallersByExtension() {
        #expect(Downloads.isInstaller("/x/Cubase.DMG") && Downloads.isInstaller("/x/a.pkg") && Downloads.isInstaller("/x/Xcode.xip"))
        #expect(!Downloads.isInstaller("/x/a.zip"))
        for ext in Downloads.installerExtensions { #expect(Downloads.kind(of: "/x/a.\(ext)", isDir: false) == .installer) }
        #expect(Downloads.kind(of: "/x/Old.app", isDir: true) == .installer)
        #expect(Downloads.kind(of: "/x/src.tgz", isDir: false) == .archive)
        #expect(Downloads.kind(of: "/x/Folder", isDir: true) == .folder)
        #expect(Downloads.kind(of: "/x/notes", isDir: false) == .other)
    }

    @Test func findsInstallersDeepInFoldersButNotInPackages() {
        let s = CleanupScratch()
        for file in ["Top.dmg", "Steinberg/Cubase 15.0.30 - Application/OSX/Cubase.pkg", "Tool.app/Contents/Resources/inner.dmg",
                     "web/node_modules/pkg/fixture.iso", ".hidden/secret.dmg", "a/b/c/d/e/f/deep.xip",
                     "a/b/c/d/e/f/g/too-deep.dmg", "notes.txt"] { s.file(file) }
        var found: [String] = []
        Downloads.installers(under: s.root, depth: 6, into: &found)
        #expect(found.map { String($0.dropFirst(s.root.count + 1)) }.sorted()
            == ["Steinberg/Cubase 15.0.30 - Application/OSX/Cubase.pkg", "Top.dmg", "a/b/c/d/e/f/deep.xip"])
    }

    @Test func readsSpotlightValues() {
        #expect(Downloads.parseSpotlightDate("1970-01-02 00:00:01 +0000") == Date(timeIntervalSince1970: 86_401))
        #expect(Downloads.parseSpotlightDate("2026-04-11 22:09:07 +0000") == Date(timeIntervalSince1970: 1_775_945_347))
        #expect(Downloads.parseSpotlightDate("(null)") == nil)
        #expect(Downloads.firstHost("(\n    \"https://www.a.com/x?t=1\",\n    \"https://b.com/\"\n)") == "a.com")
        #expect(Downloads.firstHost("(\"https://user@dl.example.org:443/f\")") == "dl.example.org:443")
        #expect(Downloads.firstHost("(null)") == nil)
    }

    @Test func spotsCopiesInstallersAndUnpackedArchives() {
        #expect(Downloads.original(of: "report (1).pdf") == "report.pdf")
        #expect(Downloads.original(of: "folder (12)") == "folder")
        #expect(Downloads.original(of: "mix (final).wav") == nil)
        #expect(Downloads.stem("src.tar.gz") == "src")
        let siblings: Downloads.Siblings = ["report.pdf": (false, 10), "Plugin": (true, nil)]
        let apps: Set<String> = ["figma", "googlechrome"]
        #expect(Downloads.hints(name: "report (1).pdf", kind: .document, bytes: 10, siblings: siblings, apps: apps) == [.copy])
        #expect(Downloads.hints(name: "report (1).pdf", kind: .document, bytes: 11, siblings: siblings, apps: apps).isEmpty)
        #expect(Downloads.hints(name: "Plugin.zip", kind: .archive, bytes: 1, siblings: siblings, apps: apps) == [.unpacked])
        #expect(Downloads.hints(name: "Figma-124.5.dmg", kind: .installer, bytes: nil, siblings: siblings, apps: apps) == [.installed])
        #expect(Downloads.hints(name: "googlechrome.dmg", kind: .installer, bytes: nil, siblings: siblings, apps: apps) == [.installed])
        #expect(Downloads.hints(name: "Other.dmg", kind: .installer, bytes: nil, siblings: siblings, apps: apps).isEmpty)
    }

    @Test func listsDownloadsWithHints() async throws {
        let s = CleanupScratch()
        s.file("Downloads/report.pdf", bytes: 100)
        s.file("Downloads/report (1).pdf", bytes: 100)
        s.file("Downloads/Plugin.zip", bytes: 10)
        s.dir("Downloads/Plugin")
        s.file("Downloads/.DS_Store")
        s.file("Desktop/Setup/Thing.pkg", bytes: 5)
        let items = try await Downloads.list(home: s.root)
        #expect(items.map(\.name).sorted() == ["Plugin", "Plugin.zip", "Thing.pkg", "report (1).pdf", "report.pdf"])
        #expect(items.first { $0.name == "report (1).pdf" }?.hints == [.copy])
        #expect(items.first { $0.name == "Plugin.zip" }?.hints == [.unpacked])
        #expect(items.first { $0.name == "Plugin" }?.bytes == nil)
        #expect(Downloads.unmeasured(items) == [s.path("Downloads/Plugin")])
    }
}

@Suite struct FolderScanTests {
    @Test func trashesOnlyInsideUserFolders() {
        let home = NSHomeDirectory()
        #expect(!FolderScan.trashable("\(home)/Downloads"))
        #expect(!FolderScan.trashable("\(home)/Library/Preferences"))
        #expect(!FolderScan.trashable("/Applications/Safari.app"))
        #expect(!FolderScan.trashable("\(home)/Downloads/../Documents"))
    }

    @Test func aHomeOnAnotherVolumeIsStillHome() {
        let home = "/Volumes/Data/Users/me"
        #expect(!FolderScan.allowedPlace("\(home)/Documents", home: home))
        #expect(!FolderScan.allowedPlace("\(home)/Library/Caches", home: home))
        #expect(FolderScan.allowedPlace("\(home)/Documents/notes.txt", home: home))
        #expect(FolderScan.allowedPlace("\(home)/Library/Caches/app", home: home))
        #expect(FolderScan.allowedPlace("/Volumes/Backup/old.zip", home: home))
        #expect(!FolderScan.allowedPlace("/Volumes/Backup", home: home))
    }

    @Test func listsFoldersPackagesAndHiddenFiles() throws {
        let s = CleanupScratch()
        s.file("a.txt", bytes: 5000)
        s.dir("Folder/inner")
        s.dir("Thing.app/Contents")
        s.file(".hidden")
        let entries = try FolderScan.list(s.root).sorted { $0.name < $1.name }
        #expect(entries.map(\.name) == [".hidden", "Folder", "Thing.app", "a.txt"])
        #expect(entries[0].hidden && entries[2].package && !entries[2].opens && entries[1].opens)
        #expect(entries[3].bytes! >= 5000 && entries[1].bytes == nil)
        #expect(throws: LowtideError.self) { try FolderScan.list(s.path("nope")) }
    }
}

@Suite struct DuplicateTests {
    @Test func groupsOnlyIdenticalFiles() async throws {
        let s = CleanupScratch()
        let big = Data((0..<200_000).map { UInt8($0 % 251) })
        var tail = big
        tail[199_999] ^= 0xFF
        FileManager.default.createFile(atPath: s.file("a/photo.jpg", ""), contents: big)
        FileManager.default.createFile(atPath: s.file("b/photo copy.jpg", ""), contents: big)
        // Same size and same first 64 KB, different end: not a copy.
        FileManager.default.createFile(atPath: s.file("c/almost.jpg", ""), contents: tail)
        // A hard link is one file under two names.
        try FileManager.default.linkItem(atPath: s.path("a/photo.jpg"), toPath: s.path("a/link.jpg"))
        s.file("d/small1.txt", "same text")
        s.file("d/small2.txt", "same text")
        s.file("d/other.txt", "diff text")
        s.file("d/node_modules/dep.txt", "same text")
        s.file("d/.hidden.txt", "same text")
        let groups = CleanupLock([DuplicateGroup]())
        let count = await DuplicateFinder.scan([s.root, s.path("a")], minBytes: 1, home: s.root, progress: { _ in }) { group in
            groups.update { $0.append(group) }
        }
        #expect(count == 2)
        let sets = groups.value.map { Set($0.files.map(\.name)) }
        #expect(sets.contains(["small1.txt", "small2.txt"]))
        #expect(sets.contains { $0.contains("photo copy.jpg") && $0.count == 2 && !$0.contains("almost.jpg") })
        // Biggest first.
        #expect(groups.value.first?.bytes == 200_000)
    }

    @Test func keepsOneCopyByRule() {
        let old = DuplicateFile(path: "/a/very/long/path/x.jpg", name: "x.jpg", modified: Date(timeIntervalSince1970: 100))
        let new = DuplicateFile(path: "/b/x.jpg", name: "x.jpg", modified: Date(timeIntervalSince1970: 200))
        #expect(DuplicateFinder.keeper([new, old], rule: .oldest) == old)
        #expect(DuplicateFinder.keeper([old, new], rule: .newest) == new)
        #expect(DuplicateFinder.keeper([old, new], rule: .shortest) == new)
        let group = DuplicateGroup(id: "1", bytes: 10, files: [old, new])
        #expect(DuplicateFinder.extras([group], rule: .oldest) == [new.path])
        #expect(group.wasted == 10)
    }

    @Test func dropsNestedRoots() {
        let s = CleanupScratch()
        s.dir("a/b")
        #expect(DuplicateFinder.normalize([s.path("a"), s.path("a/b"), s.path("missing"), "relative"]) == [s.path("a")])
    }
}

@Suite struct LeftoverTests {
    @Test func readsBundleIDsFromNames() {
        #expect(LeftoverScanner.bundleID("com.runnerx.app.plist") == "com.runnerx.app")
        #expect(LeftoverScanner.bundleID("com.foo.Bar.savedState") == "com.foo.Bar")
        #expect(LeftoverScanner.bundleID("com.runnerx") == "com.runnerx")
        #expect(LeftoverScanner.bundleID("com.apple.Safari.plist") == nil)
        #expect(LeftoverScanner.bundleID("Google") == nil)
        #expect(LeftoverScanner.bundleID("CrashReporter") == nil)
        #expect(LeftoverScanner.bundleID("Group Containers.x.y") == nil)
    }

    @Test func keepsWhatStillBelongsToAnApp() {
        let installed: Set<String> = ["com.eltima.folx3", "com.docker.docker"]
        let prefixes: Set<String> = ["com.eltima", "com.docker"]
        func gone(_ id: String) -> Bool { !LeftoverScanner.covered(id, installed: installed, prefixes: prefixes) }
        #expect(!gone("com.eltima.Folx3"))
        #expect(!gone("com.eltima.folx3.helper"))
        #expect(!gone("com.eltima.FolxAgent"))
        #expect(!gone("com.eltima"))
        #expect(!gone("com.crashlytics.data"))
        #expect(gone("com.runnerx.app"))
        #expect(gone("com.runnerx"))
    }

    @Test func namesSkipGenericParts() {
        #expect(LeftoverScanner.name(of: "com.runnerx.app") == "Runnerx")
        #expect(LeftoverScanner.name(of: "com.topazlabs.Topaz-Photo") == "Topaz-Photo")
        #expect(LeftoverScanner.name(of: "app") == "App")
        #expect(LeftoverScanner.name(of: "com.fabfilter.Pro-Q.3") == "Pro-Q")
    }

    @Test func foldersAnswerToAppsToolsAndVendors() {
        let claims = LeftoverScanner.Claims(
            products: ["pismo", "pluginallianceinstallationmanager", "totalmixfx", "vsx", "studio", "electron"],
            productWords: ["crispytuner"],
            names: ["ngrok", "go", "uhe", "bugsnag", "studio"])
        func claimed(_ name: String) -> Bool { LeftoverScanner.isClaimed(name, flat: AppBundles.alnum(name), claims) }
        #expect(claimed("pismo-windows"))
        #expect(claimed("Plugin Alliance"))
        #expect(claimed("RME TotalMix FX"))
        #expect(claimed("ssa_vsx_plugin"))
        #expect(claimed("CrispyAudio"))
        #expect(claimed("u-he"))
        #expect(claimed("ngrok"))
        #expect(claimed("go"))
        #expect(claimed("bugsnag-shared-com.pcloud.pcloud.macos"))
        #expect(!claimed("obs-studio"))
        #expect(!claimed("obs-studio-electron"))
        #expect(!claimed("my-electron-app"))
        // Short names only match whole.
        #expect(!claimed("gopher"))
    }

    @Test func splitsWordsAtCamelCaseAndMarks() {
        #expect(LeftoverScanner.words("CrispyAudio") == ["crispy"])
        #expect(LeftoverScanner.words("bx_crispytuner") == ["crispytuner"])
        #expect(LeftoverScanner.words("RME TotalMix FX") == ["rme", "total", "mix"])
    }

    @Test func groupsOrphanedFilesByID() {
        let s = CleanupScratch()
        s.file("Library/Preferences/com.runnerx.app.plist")
        s.file("Library/Preferences/com.runnerx.plist")
        s.dir("Library/Caches/com.runnerx.app")
        s.dir("Library/Containers/com.runnerx.app")
        s.file("Library/Preferences/com.kept.Thing.plist")
        s.file("Library/Preferences/com.apple.finder.plist")
        let (leftovers, categories) = LeftoverScanner.scanIDs(installed: ["com.kept.thing"], home: s.root)
        #expect(leftovers.count == 1)
        #expect(leftovers[0].id == "com.runnerx" && leftovers[0].name == "Runnerx" && leftovers[0].paths.count == 4)
        #expect(categories[s.path("Library/Containers/com.runnerx.app")] == .containers)
        // Containers aren't read at launch (macOS would ask every time).
        #expect(LeftoverScanner.measurable(Leftover(id: "x", name: "x", paths: [CleanupFS.join(CleanupFS.home, "Library/Containers/x"), "/tmp/y"],
                                                    modified: nil, byName: false)) == ["/tmp/y"])
    }

    @Test func findsUnclaimedSupportFoldersOnlyOnceIdle() {
        let s = CleanupScratch()
        s.file("Library/Application Support/Runnerx/state.json")
        s.touch("Library/Application Support/Runnerx/state.json", daysAgo: 30)
        s.touch("Library/Application Support/Runnerx", daysAgo: 30)
        s.file("Library/Application Support/Busy/state.json")
        s.file("Library/Application Support/Pismo Windows/x")
        s.touch("Library/Application Support/Pismo Windows/x", daysAgo: 30)
        s.touch("Library/Application Support/Pismo Windows", daysAgo: 30)
        s.dir("Library/Application Support/0123456789abcdef0123")
        let claims = LeftoverScanner.Claims(products: ["pismo"], productWords: [], names: [])
        let found = LeftoverScanner.unclaimedFolders(claims, home: s.root)
        #expect(found.map(\.name) == ["Runnerx"])
        #expect(found[0].byName && found[0].id == "~/Library/Application Support/Runnerx")
    }

    @Test func buildsTheFootprintSubject() {
        let byID = Leftover(id: "com.runnerx", name: "Runnerx", paths: ["/a"], modified: nil, byName: false)
        let byName = Leftover(id: "~/x", name: "App", paths: ["/b"], modified: nil, byName: true)
        let context = LeftoverScanner.Context(leftovers: [], categories: ["/a": .preferences], vendors: ["com.adobe"])
        let one = LeftoverScanner.subject(for: byID, in: context)
        #expect(one.bundleIDs == ["com.runnerx"] && one.names == ["Runnerx"] && one.primary.first?.category == .preferences)
        let two = LeftoverScanner.subject(for: byName, in: context)
        #expect(two.bundleIDs.isEmpty && two.names.isEmpty && two.primary.first?.category == .support)
    }

    @Test func readsRegisteredExtensions() {
        let text = "+    com.pcloud.pcloud.macos.pCloudFinderExt(1.0.0)\tA94F\t2026-11-13 06:09:44 +0000\t/Applications/pCloud Drive.app/Contents/PlugIns/pCloudFinderExt.appex\n"
            + "     io.macfuse.variant.pcloudfs.app.fsmodule.pcloudfs(1.9)\tC4A6\t2026-11-13 05:44:26 +0000\t/Applications/pCloud Drive.app/Contents/Resources/pcloudfs.fs/x.appex\n"
            + "(no matches)\n"
        let found = LeftoverScanner.registeredExtensions(text)
        #expect(found.map(\.id) == ["com.pcloud.pcloud.macos.pCloudFinderExt", "io.macfuse.variant.pcloudfs.app.fsmodule.pcloudfs"])
        #expect(found[1].path.hasSuffix("x.appex"))
    }

    @Test func goneGrantsSkipInstalledAndApple() {
        let rows = [
            LeftoverPermissions.Row(service: "kTCCServiceCamera", client: "com.gone.app", client_type: 0, auth_value: 2,
                                    indirect_object_identifier: "UNUSED", last_modified: 1_700_000_000),
            LeftoverPermissions.Row(service: "kTCCServiceMicrophone", client: "com.kept.App", client_type: 0, auth_value: 2,
                                    indirect_object_identifier: nil, last_modified: nil),
            LeftoverPermissions.Row(service: "kTCCServiceAccessibility", client: "com.apple.Terminal", client_type: 0, auth_value: 2,
                                    indirect_object_identifier: nil, last_modified: nil),
            LeftoverPermissions.Row(service: "kTCCServiceAccessibility", client: "/opt/gone/tool", client_type: 1, auth_value: 2,
                                    indirect_object_identifier: nil, last_modified: nil),
        ]
        let gone = LeftoverPermissions.goneGrants(rows, installed: ["com.kept.app"])
        #expect(Set(gone.keys) == ["com.gone.app", "/opt/gone/tool"])
        #expect(gone["com.gone.app"]?.grants.first?.label == "Camera" && gone["com.gone.app"]?.grants.first?.target == nil)
        #expect(gone["com.gone.app"]?.grants.first?.revocable == true)
        #expect(gone["/opt/gone/tool"]?.grants.first?.revocable == false)
    }

    @Test func findsBrokenLaunchAgents() throws {
        let s = CleanupScratch()
        let agents = s.dir("Library/LaunchAgents")
        func write(_ name: String, _ job: [String: Any]) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
            FileManager.default.createFile(atPath: CleanupFS.join(agents, name), contents: data)
        }
        try write("com.gone.helper.plist", ["Label": "com.gone.helper", "ProgramArguments": ["/Applications/Gone.app/Contents/MacOS/helper", "-x"]])
        try write("com.fine.helper.plist", ["Label": "com.fine.helper", "Program": "/bin/ls"])
        let broken = LeftoverPermissions.brokenJobs(home: s.root).filter { $0.plist?.hasPrefix(s.root) == true }
        #expect(broken.map(\.label) == ["com.gone.helper"])
        #expect(broken.first?.executable == "/Applications/Gone.app/Contents/MacOS/helper")
        #expect(LeftoverPermissions.vendorApp("com.docker.socket", installed: ["com.docker.docker": "Docker"]) == "com.docker.docker")
        #expect(LeftoverPermissions.vendorApp("com.apple.x.y", installed: ["com.apple.finder": "Finder"]) == nil)
    }
}
