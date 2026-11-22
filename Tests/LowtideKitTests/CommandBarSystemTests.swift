import Carbon.HIToolbox
import Foundation
import Testing
@testable import LowtideKit

/// Shortcuts, the Spotlight takeover, and the Mac readings behind the bar.
@Suite struct CommandBarSystemTests {
    @Test func parsesShortcutNotation() {
        #expect(Hotkey(notation: "Alt+Space") == .defaultBar)
        #expect(Hotkey(notation: "Command+Space") == .commandSpace)
        let k = Hotkey(notation: "CommandOrControl+Shift+K")
        #expect(k?.keyCode == UInt32(kVK_ANSI_K) && k?.modifiers == [.command, .shift])
        #expect(Hotkey(notation: "Control+Option+f5")?.keyName == "F5")
        #expect(Hotkey(notation: "Ctrl+1")?.keyCode == UInt32(kVK_ANSI_1))
        #expect(Hotkey(notation: "Hyper+K") == nil)
        #expect(Hotkey(notation: "Alt+Escape") == nil)
        #expect(Hotkey(notation: "") == nil)
        for hotkey in [Hotkey.defaultBar, .commandSpace, Hotkey(keyCode: UInt32(kVK_F12), modifiers: [.control, .shift])] {
            #expect(Hotkey(notation: hotkey.notation) == hotkey)
        }
    }

    @Test func drawsShortcutsTheMacWay() {
        #expect(Hotkey.defaultBar.label == "⌥Space")
        #expect(Hotkey.defaultBar.glyphs == ["⌥", "Space"])
        let all = Hotkey(keyCode: UInt32(kVK_ANSI_K), modifiers: [.command, .shift, .option, .control])
        #expect(all.label == "⌃⌥⇧⌘K")
        #expect(all.notation == "Command+Control+Alt+Shift+K")
    }

    @Test func refusesShortcutsThatWouldBreakTyping() {
        #expect(Hotkey(keyCode: UInt32(kVK_ANSI_K), modifiers: .shift).problem != nil)
        #expect(Hotkey(keyCode: UInt32(kVK_ANSI_K), modifiers: []).problem != nil)
        #expect(Hotkey(keyCode: UInt32(kVK_ANSI_C), modifiers: .command).problem != nil)
        #expect(Hotkey(keyCode: UInt32(kVK_ANSI_4), modifiers: [.command, .shift]).problem != nil)
        #expect(Hotkey(keyCode: UInt32(kVK_ANSI_C), modifiers: [.command, .option]).problem == nil)
        #expect(Hotkey.defaultBar.problem == nil)
        #expect(Hotkey.commandSpace.problem == nil)
        #expect(Hotkey(keyCode: UInt16(kVK_Escape), flags: .command) == nil)
        #expect(Hotkey(keyCode: UInt16(kVK_Space), flags: [.option, .capsLock]) == .defaultBar)
    }

    /// Trimmed from `defaults export com.apple.symbolichotkeys -` on macOS 15.
    static let sample = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
    \t<key>AppleSymbolicHotKeys</key>
    \t<dict>
    \t\t<key>60</key>
    \t\t<dict>
    \t\t\t<key>enabled</key>
    \t\t\t<true/>
    \t\t</dict>
    \t\t<key>64</key>
    \t\t<dict>
    \t\t\t<key>enabled</key>
    \t\t\t<false/>
    \t\t\t<key>value</key>
    \t\t\t<dict>
    \t\t\t\t<key>parameters</key>
    \t\t\t\t<array>
    \t\t\t\t\t<integer>32</integer>
    \t\t\t\t\t<integer>49</integer>
    \t\t\t\t\t<integer>1048576</integer>
    \t\t\t\t</array>
    \t\t\t\t<key>type</key>
    \t\t\t\t<string>standard</string>
    \t\t\t</dict>
    \t\t</dict>
    \t\t<key>65</key>
    \t\t<dict>
    \t\t\t<key>enabled</key>
    \t\t\t<integer>1</integer>
    \t\t</dict>
    \t</dict>
    </dict>
    </plist>
    """

    @Test func readsSpotlightsEntry() {
        #expect(!SpotlightHotkey.isEnabled(SpotlightHotkey.entry(Data(Self.sample.utf8))))
        let empty = #"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>AppleSymbolicHotKeys</key><dict/></dict></plist>"#
        #expect(SpotlightHotkey.isEnabled(SpotlightHotkey.entry(Data(empty.utf8))))
        #expect(SpotlightHotkey.isEnabled(SpotlightHotkey.entry(Data("not a plist".utf8))))
        let off = Self.sample.replacingOccurrences(of: "<false/>", with: "<integer>0</integer>")
        #expect(!SpotlightHotkey.isEnabled(SpotlightHotkey.entry(Data(off.utf8))))
        let on = Self.sample.replacingOccurrences(of: "<false/>", with: "<integer>1</integer>")
        #expect(SpotlightHotkey.isEnabled(SpotlightHotkey.entry(Data(on.utf8))))
    }

    @Test func fragmentKeepsARemappedShortcut() {
        let remapped = Self.sample.replacingOccurrences(of: "1048576", with: "262144")
        #expect(SpotlightHotkey.fragment(SpotlightHotkey.entry(Data(remapped.utf8)), enabled: true)
            == "<dict><key>enabled</key><true/><key>value</key><dict><key>parameters</key><array><integer>32</integer>"
            + "<integer>49</integer><integer>262144</integer></array><key>type</key><string>standard</string></dict></dict>")
        let fragment = SpotlightHotkey.fragment(nil, enabled: false)
        #expect(fragment.hasPrefix("<dict><key>enabled</key><false/>"))
        #expect(fragment.contains("<integer>1048576</integer>"))
    }

    /// The whole takeover and hand-back, through `defaults`, on a copy.
    @Test func takesAndGivesBackCommandSpaceOnACopy() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "lowtide-hotkeys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let remapped = Self.sample.replacingOccurrences(of: "<false/>", with: "<true/>")
            .replacingOccurrences(of: "1048576", with: "262144")
        let file = folder.appending(path: "symbolichotkeys.plist")
        try Data(remapped.utf8).write(to: file)
        let copy = SpotlightHotkey(domain: file.path, applies: false)

        #expect(try await copy.state().enabled)
        let taken = try await copy.set(enabled: false)
        #expect(!taken.enabled && !taken.needsLogout)
        #expect(try await copy.state().enabled == false)
        try await copy.set(enabled: true)
        #expect(try await copy.state().enabled)

        // Only entry 64 changed; the remapped keys and the other entries survive.
        let after = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any]
        let hotkeys = after?["AppleSymbolicHotKeys"] as? [String: Any]
        #expect(hotkeys?.keys.sorted() == ["60", "64", "65"])
        let params = ((hotkeys?["64"] as? [String: Any])?["value"] as? [String: Any])?["parameters"] as? [Int]
        #expect(params == [32, 49, 262_144])
    }

    @Test func parsesBatteryMemoryWifiAndVolume() {
        let charging = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=1)\t87%; charging; 0:40 remaining present: true\n"
        #expect(MacFacts.parseBattery(charging) == MacFacts.Battery(percent: 87, charging: true, onPower: true))
        let full = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=7471203)\t100%; charged; 0:00 remaining present: true\n"
        #expect(MacFacts.parseBattery(full) == MacFacts.Battery(percent: 100, charging: false, onPower: true))
        let low = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t5%; discharging; 0:10 remaining\n"
        #expect(MacFacts.parseBattery(low)?.charging == false)
        #expect(MacFacts.parseBattery("Now drawing from 'AC Power'\n") == nil)

        let vm = """
        Mach Virtual Memory Statistics: (page size of 16384 bytes)
        Pages free:                                   295512.
        Pages wired down:                             273259.
        Pages purgeable:                               10928.
        "Translation faults":                     1047185770.
        Anonymous pages:                              473926.
        Pages stored in compressor:                  1056823.
        Pages occupied by compressor:                 588166.
        """
        #expect(MacFacts.parseVMStat(vm) == UInt64(473_926 - 10_928 + 273_259 + 588_166) * 16384)
        #expect(MacFacts.parseVMStat("garbage") == nil)

        let ports = "\nHardware Port: Ethernet Adapter (en4)\nDevice: en4\nEthernet Address: 4a:db\n\nHardware Port: Wi-Fi\nDevice: en0\n"
        #expect(MacFacts.parseWifiDevice(ports) == "en0")
        #expect(MacFacts.parseWifiDevice("Hardware Port: Ethernet\nDevice: en4\n") == nil)

        #expect(MacFacts.parseVolume("output volume:31, input volume:50, alert volume:100, output muted:false\n") == (31, false))
        #expect(MacFacts.parseVolume("output volume:42, input volume:31, alert volume:100, output muted:true") == (42, true))
        #expect(MacFacts.parseVolume("missing value") == (0, false))
    }

    @Test func killTreeGoesChildrenFirst() {
        let order = Processes.treeOrder(10, [(10, 1), (11, 10), (12, 11), (13, 10), (20, 1)])
        #expect(order.last == 10)
        #expect(!order.contains(20))
        let at = { (p: pid_t) in order.firstIndex(of: p)! }
        #expect(at(12) < at(11) && at(11) < at(10) && at(13) < at(10))
    }

    @Test func killReachesOnlyOwnProcesses() {
        let owned = [Processes.Info(pid: 10, ppid: 1, uid: 501, name: "node", path: nil),
                     Processes.Info(pid: 11, ppid: 10, uid: 501, name: "esbuild", path: nil),
                     Processes.Info(pid: 12, ppid: 1, uid: 501, name: "node", path: nil)]
        #expect(Processes.targets(10, .term, owned: owned) == [10])
        #expect(Processes.targets(10, .all, owned: owned).sorted() == [10, 12])
        #expect(Processes.targets(10, .tree, owned: owned) == [11, 10])
        #expect(Processes.targets(99, .kill, owned: owned).isEmpty)
        #expect(throws: LowtideError.self) { try Processes.kill(1, mode: .term) }
        #expect(throws: LowtideError.self) { try Processes.kill(getpid(), mode: .term) }
    }

    @Test func listsThisMachinesProcesses() {
        let own = Processes.own()
        #expect(!own.isEmpty)
        #expect(!own.contains { $0.pid == getpid() })
        #expect(Processes.info(getpid())?.uid == getuid())
    }

    @Test func spotlightQueryNeedsEveryWordAndEscapes() {
        #expect(FileSearch.query(" a ") == nil)
        #expect(FileSearch.query("tax 2024") == #"kMDItemFSName == "*tax*"cd && kMDItemFSName == "*2024*"cd"#)
        #expect(FileSearch.query(#"a*b "q" c?\"#)
            == #"kMDItemFSName == "*a\*b*"cd && kMDItemFSName == "*\"q\"*"cd && kMDItemFSName == "*c\?\\*"cd"#)
    }

    @Test func fileFilterDropsHiddenPackagesAndIgnores() {
        let scope = "/Users/me/Documents"
        let user = ["*.log", "build", ".tmp"]
        let keep = { (p: String) in FileSearch.keep(p, scope: scope, ignores: user) }
        #expect(keep("/Users/me/Documents/report.pdf"))
        #expect(keep("/Users/me/Documents/Deck.key"))
        #expect(keep("/Users/me/Documents/Tools/Thing.app"))
        #expect(!keep("/Users/me/Documents/.secret/a.txt"))
        #expect(!keep("/Users/me/Documents/.env"))
        #expect(!keep("/Users/me/Documents/Thing.app/Contents/Info.plist"))
        #expect(!keep("/Users/me/Documents/Lib.photoslibrary/x.jpg"))
        #expect(!keep("/Users/me/Documents/web/node_modules/x/index.js"))
        #expect(!keep("/Users/me/Documents/web/vendor/x.php"))
        #expect(!keep("/Users/me/Documents/server.log"))
        #expect(!keep("/Users/me/Documents/cache.TMP"))
        #expect(!keep("/Users/me/Documents/app/build/out.js"))
        #expect(keep("/Users/me/Documents/buildings.txt"))
        #expect(!keep("/Users/other/report.pdf"))
        #expect(!keep("/Users/me/DocumentsOld/report.pdf"))
        #expect(!keep(scope))
    }

    @Test func fileHitsAreDeduplicatedSortedAndCapped() {
        let raw = ["/Volumes/X/b.txt", "/Volumes/X/A.txt", "/Volumes/X/b.txt"].map { (scope: "/Volumes/X", path: $0) }
        let hits = FileSearch.hits(raw, ignores: [])
        #expect(hits.map(\.name) == ["A.txt", "b.txt"])
        #expect(hits[0].parent == "/Volumes/X")
        let many = (0..<500).map { (scope: "/Volumes/X", path: "/Volumes/X/f\($0).txt") }
        #expect(FileSearch.hits(many, ignores: []).count == 200)
    }

    @Test func scopesExpandHome() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "lowtide-home-\(UUID().uuidString)")
        for folder in ["Documents", "Library", ".hidden", "Code"] {
            try FileManager.default.createDirectory(at: home.appending(path: folder), withIntermediateDirectories: true)
        }
        try Data().write(to: home.appending(path: "file.txt"))
        defer { try? FileManager.default.removeItem(at: home) }
        let scopes = FileSearch.resolveScopes([home.path, "/nope/nothing", "relative", home.path + "/Code"], home: home.path)
        #expect(scopes == [home.path + "/Code", home.path + "/Documents"])
    }

    @Test func runsScriptsWithoutAShell() async {
        let echo = await UserScript.run("/bin/echo", argument: "hi there; rm -rf /")
        #expect(echo == UserScript.Result(ok: true, output: "hi there; rm -rf /"))
        #expect(await UserScript.run("/etc/hosts", argument: nil).output == "Not an executable file")
        #expect(await UserScript.run("relative/tool", argument: nil).ok == false)
        let failing = await UserScript.run("/bin/ls", argument: "/definitely/not/here")
        #expect(!failing.ok && failing.output.contains("No such file"))
        let slow = await UserScript.run("/bin/sleep", argument: "30")
        #expect(slow.output == "Timed out")
    }

    @Test func settingsSearchTermsAreDeduplicatedAndBounded() {
        let root: [String: Any] = [
            "Main": ["localizableStrings": [
                ["title": "Appearance", "index": "dark, Dark , theme, appearance"],
                ["title": "Long", "index": String(repeating: "x", count: 41)],
            ]],
        ]
        #expect(SettingsPanes.searchTerms(root) == ["Appearance", "dark", "theme", "Long"])
    }

    @Test func readsThisMacsSettingsPanes() {
        let panes = SettingsPanes.all()
        #expect(panes.count > 10)
        #expect(panes.contains { $0.name == "Wi-Fi" })
        #expect(panes.allSatisfy { $0.keywords.count <= 160 })
    }

    @Test func keepsOnlyAppsPeopleOpen() {
        #expect(AppIndex.launchable("/Applications/Safari.app"))
        #expect(AppIndex.launchable("/System/Applications/Utilities/Terminal.app"))
        #expect(!AppIndex.launchable("/Applications/Slack.app/Contents/Frameworks/Slack Helper.app"))
        #expect(!AppIndex.launchable("/Users/me/code/x/target/release/bundle/macos/X.app"))
        #expect(!AppIndex.launchable("/Users/me/.Trash/Old.app"))
        let app = { (path: String) in LaunchableApp(name: "X", path: path, bundleID: "x", fileName: "X") }
        #expect(AppIndex.better(app("/Applications/X.app"), than: app("/Volumes/Backup/X.app")))
        #expect(!AppIndex.better(app("/Users/me/Downloads/old/X.app"), than: app("/Applications/Tools/X.app")))
    }

    @Test func findsThisMacsApps() async {
        let apps = await AppIndex.shared.list()
        #expect(apps.contains { $0.bundleID == "com.apple.finder" || $0.bundleID == "com.apple.Safari" })
        #expect(Set(apps.map(\.bundleID)).count == apps.count)
    }

    @Test func emojiCatalogIsSane() {
        let list = EmojiCatalog.all
        #expect(list.count > 1000)
        #expect(list[0].char == "😂" && list[0].name == "face with tears of joy")
        #expect(list[1].char == "❤\u{FE0F}")
        let fire = list.first { $0.char == "🔥" }
        #expect(fire?.keywords.contains("fire") == true && fire?.tones == false)
        var seen = Set<String>()
        for e in list {
            let canonical = e.char.replacingOccurrences(of: "\u{FE0F}", with: "")
            #expect(seen.insert(canonical).inserted, "duplicate \(e.char)")
            #expect(canonical.unicodeScalars.count == 1)
            #expect(!e.name.isEmpty && e.name == e.name.lowercased())
        }
        let has = { (s: String) in list.contains { $0.char == s } }
        #expect(!has("\u{1F3FB}") && !has("\u{1F9B0}"))
        #expect(has("☀\u{FE0F}") && has("⚡") && !has("☀"))
        let thumbs = list.first { $0.char == "👍" }
        #expect(thumbs?.tones == true && thumbs?.toned(.dark) == "👍\u{1F3FF}")
        #expect(list.first { $0.char == "👪" }?.tones == false)
        let popular = Set(EmojiCatalog.popular.split(whereSeparator: \.isWhitespace)).count
        let rest = list[popular...]
        #expect(zip(rest, rest.dropFirst()).allSatisfy { $0.name <= $1.name })
    }

    @Test func standardFoldersExist() {
        let folders = StandardFolders.all()
        #expect(folders.contains { $0.name == "Home" })
        #expect(folders.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func privacyMasksWhatIdentifies() {
        let cases: [(String, String)] = [
            ("en0 192.168.0.157 gw 192.168.0.1", "en0 •••.•••.•••.••• gw •••.•••.•••.•••"),
            ("16:24:59 claude", "16:24:59 claude"),
            ("fe80::1%en0 up", "••••:••••::•• up"),
            ("2606:4700:4700::1111", "••••:••••::••"),
            ("root@203.0.113.7", "•••@•••"),
            ("me@example.com", "•••@•••"),
            ("/Users/jane/Library", "/Users/•••/Library"),
            ("a4:83:e7:12:9c:0f", "••:••:••:••:••:••"),
            ("v1.64.0", "v1.64.0"),
        ]
        for (input, want) in cases { #expect(PrivacyText.redact(input) == want, "\(input)") }
        #expect(PrivacyText.redact("Jane Doe's MacBook and Jane", terms: ["Jane Doe", "Jane", "JD"]) == "•••••'s MacBook and •••••")
        #expect(PrivacyText.redact("Janet", terms: ["Jane"]) == "Janet")
    }

    @Test func extensionStateDefaultsAndNotifies() async {
        let defaults = UserDefaults(suiteName: "lowtide-test-\(UUID().uuidString)")!
        #expect(ExtensionState.isOn(.commandbar, defaults: defaults))
        #expect(!ExtensionState.isOn(.widgets, defaults: defaults))
        #expect(!ExtensionState.isOn(.dictation, defaults: defaults))
        #expect(!ExtensionState.isOn(.menubar, defaults: defaults))
        let seen = Mutex<[String]>([])
        let observer = NotificationCenter.default.addObserver(forName: ExtensionState.changed, object: nil, queue: nil) { note in
            let id = note.userInfo?["id"] as? String ?? ""
            seen.withLock { $0.append(id) }
        }
        ExtensionState.set(.dictation, true, defaults: defaults)
        ExtensionState.set(.dictation, true, defaults: defaults)
        ExtensionState.set(.commandbar, false, defaults: defaults)
        NotificationCenter.default.removeObserver(observer)
        #expect(ExtensionState.isOn(.dictation, defaults: defaults))
        #expect(!ExtensionState.isOn(.commandbar, defaults: defaults))
        #expect(defaults.object(forKey: "extension.dictation") as? Bool == true)
        #expect(seen.withLock { $0 } == ["dictation", "commandbar"])
    }
}

import Synchronization
