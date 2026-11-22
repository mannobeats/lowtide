import Foundation
import Testing
@testable import LowtideKit

@Suite struct AppsVersionTests {
    @Test func ordersVersionsAcrossSchemes() {
        func order(_ a: String, _ b: String) -> ComparisonResult { AppVersion.compare(a, b) }
        #expect(order("1.10.0", "1.9.9") == .orderedDescending)
        #expect(order("v0.23.0", "v0.21.0") == .orderedDescending)
        #expect(order("1.2.3", "1.2.3") == .orderedSame)
        #expect(order("1.2", "1.2.0") == .orderedSame)
        #expect(order("2.0.0-rc.2", "2.0.0") == .orderedAscending)
        #expect(order("2.0.0-rc.12", "2.0.0-rc.2") == .orderedDescending)
        #expect(order("1.2.3_2", "1.2.3_1") == .orderedDescending)
        #expect(order("1.2.3_1", "1.2.3") == .orderedDescending)
        #expect(order("4.5,123", "4.5,99") == .orderedDescending)
        #expect(order("1.0.0+build.5", "1.0.0") == .orderedSame)
        #expect(order("7.1.0.beta1", "7.1.0") == .orderedAscending)
        #expect(order("2.0.0rc1", "2.0.0") == .orderedAscending)
        #expect(order("2.0.0rc1", "1.9.9") == .orderedDescending)
        #expect(order("1.0a1", "1.0") == .orderedAscending)
        #expect(order("1.1.1a", "1.1.1") == .orderedDescending)
        #expect(order("1.1.1b", "1.1.1a") == .orderedDescending)
        // Sparkle build numbers and App Store versions as they come.
        #expect(AppVersion.isNewer("69", than: "68"))
        #expect(!AppVersion.isNewer("26.1111.21308", than: "26.1111.21308"))
        #expect(AppVersion.isNewer("5.11492.5", than: "5.9999.0"))
    }

    @Test func keepsYearAndPlainVersionsApart() {
        #expect(AppVersion.comparable("26.924.51851", "26.924.22138"))
        #expect(AppVersion.comparable("2025.2.1", "2024.3"))
        #expect(!AppVersion.comparable("2025.2", "9.1"))
        #expect(!AppVersion.comparable("latest", "1.0"))
    }

    @Test func aLongLastPartIsABuildNotARelease() {
        #expect(AppVersion.onlyAddsBuild("7.2.2.88465", to: "7.2.2"))
        #expect(AppVersion.onlyAddsBuild("2.12.0.3157", to: "2.12.0"))
        #expect(!AppVersion.onlyAddsBuild("1.0.1", to: "1.0"))
        #expect(!AppVersion.onlyAddsBuild("26.1.7.5419", to: "26.1.6.5406"))
    }

    @Test func showsCaskVersionsWithoutTheBuild() {
        #expect(AppVersion.display("5.11492.5,1403e2cf44abfb23809c8ae11238d5e9704a41c2") == "5.11492.5")
        #expect(AppVersion.display("160.0") == "160.0")
        #expect(AppVersion.major("158.0b5") == "158")
    }
}

@Suite struct AppsFeedTests {
    static let appcast = #"""
    <?xml version="1.0"?>
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
      <item>
        <title>2.1</title>
        <sparkle:version>210</sparkle:version>
        <sparkle:shortVersionString>2.1</sparkle:shortVersionString>
        <pubDate>Mon, 01 Sep 2026 10:00:00 +0000</pubDate>
        <description><![CDATA[<ul><li>Faster</li><li>Fixes &amp; more</li></ul>]]></description>
        <enclosure url="https://example.com/App-2.1.zip" length="1000" type="application/octet-stream"/>
      </item>
      <item>
        <sparkle:version>300</sparkle:version>
        <sparkle:channel>beta</sparkle:channel>
        <enclosure url="https://example.com/App-3.0b.zip"/>
      </item>
      <item>
        <sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion>
        <enclosure url="https://example.com/App-4.zip" sparkle:version="400"/>
      </item>
      <item>
        <sparkle:version>500</sparkle:version>
        <sparkle:informationalUpdate><sparkle:belowVersion>200</sparkle:belowVersion></sparkle:informationalUpdate>
      </item>
      <item>
        <enclosure url="https://example.com/App-2.0.zip" sparkle:version="200" sparkle:shortVersionString="2.0"/>
      </item>
    </channel>
    </rss>
    """#

    @Test func readsTheNewestStableAppcastItem() throws {
        let release = try #require(UpdateFeeds.appcast(Data(Self.appcast.utf8), os: "26.0"))
        #expect(release.build == "210")
        #expect(release.version == "2.1")
        #expect(release.size == 1000)
        #expect(release.url == "https://example.com/App-2.1.zip")
        #expect(release.notes == "• Faster\n• Fixes & more")
        #expect(release.released == "Mon, 01 Sep 2026 10:00:00 +0000")
    }

    /// Capso's real appcast (attributes split over lines, an EdDSA signature).
    @Test func readsARealAppcast() throws {
        let xml = #"""
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
          <channel>
            <title>Capso Updates</title>
            <link>https://lzhgus.github.io/Capso/appcast.xml</link>
            <description>Open-source screenshot and screen recording for macOS</description>
            <item>
              <title>Version 1.2.8</title>
              <pubDate>Mon, 09 Nov 2026 06:47:32 +0000</pubDate>
              <sparkle:version>69</sparkle:version>
              <sparkle:shortVersionString>1.2.8</sparkle:shortVersionString>
              <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
              <enclosure
                url="https://github.com/lzhgus/Capso/releases/download/v1.2.8/Capso-1.2.8.dmg"
                type="application/octet-stream"
                sparkle:edSignature="fp0aGdMcRfdgh1uRER+/NVYi1erFbgJR1gjRRvZWfjQkeQvRaoXW+svveZcFGGeodah4643E/H5yfkYXc9BSCg=="
                length="10432003"
              />
            </item>
          </channel>
        </rss>
        """#
        let release = try #require(UpdateFeeds.appcast(Data(xml.utf8), os: "26.1.0"))
        #expect(release.build == "69" && release.version == "1.2.8" && release.size == 10_432_003)
        #expect(release.url?.hasSuffix("Capso-1.2.8.dmg") == true)
        #expect(release.notes == nil)
        // Too old a macOS for the only item: nothing to offer.
        #expect(UpdateFeeds.appcast(Data(xml.utf8), os: "14.6") == nil)
        #expect(UpdateFeeds.appcast(Data("not xml".utf8), os: "26.0") == nil)
    }

    @Test func findsElectronFeeds() {
        #expect(UpdateFeeds.electronFeed("owner: ferdium\nrepo: ferdium-app\nprovider: github\n")
            == "https://github.com/ferdium/ferdium-app/releases/latest/download/latest-mac.yml")
        #expect(UpdateFeeds.electronFeed("provider: generic\nurl: https://cdn.example.com/app\nchannel: latest\n")
            == "https://cdn.example.com/app/latest-mac.yml")
        #expect(UpdateFeeds.electronFeed("provider: s3\nbucket: b\nendpoint: https://r2.example.com\nacl: null\n")
            == "https://r2.example.com/b/latest-mac.yml")
        #expect(UpdateFeeds.electronFeed("provider: spaces\nname: n\nregion: nyc3\n") == "https://n.nyc3.digitaloceanspaces.com/latest-mac.yml")
        // Real app-update.yml files from installed apps.
        #expect(UpdateFeeds.electronFeed("provider: generic\nurl: https://cdn1.genspark.ai/user-upload-image/client/genoffice-company\nchannel: latest\nupdaterCacheDirName: '@genofficeshell-updater'\n")
            == "https://cdn1.genspark.ai/user-upload-image/client/genoffice-company/latest-mac.yml")
        #expect(UpdateFeeds.electronFeed("provider: generic\nurl: https://d3u5mvp65igwle.cloudfront.net/sd-connect-releases/latest\nupdaterCacheDirName: complete-access-hub-updater\n")
            == "https://d3u5mvp65igwle.cloudfront.net/sd-connect-releases/latest/latest-mac.yml")
        #expect(UpdateFeeds.electronFeed("provider: bitbucket\n") == nil)
    }

    @Test func picksThisMacsElectronDownload() throws {
        let yml = "version: 7.2.3\nfiles:\n  - url: App-7.2.3-x64.zip\n    sha512: aaa\n    size: 10\n  - url: App-7.2.3-arm64.zip\n    sha512: bbb\n    size: 20\n  - url: App-7.2.3-arm64.dmg\n    size: 30\npath: App-7.2.3-x64.zip\nreleaseDate: '2026-09-07T16:08:17.118Z'\n"
        let arm = try #require(UpdateFeeds.electronRelease(yml, feedURL: "https://cdn.example.com/app/latest-mac.yml", arch: "arm64"))
        #expect(arm.version == "7.2.3")
        #expect(arm.url == "https://cdn.example.com/app/App-7.2.3-arm64.zip")
        #expect(arm.sha512 == "bbb" && arm.size == 20)
        #expect(arm.released == "2026-09-07T16:08:17.118Z")
        let intel = try #require(UpdateFeeds.electronRelease(yml, feedURL: "https://cdn.example.com/app/latest-mac.yml", arch: "x64"))
        #expect(intel.url == "https://cdn.example.com/app/App-7.2.3-x64.zip" && intel.sha512 == "aaa")
        // Only the other architecture: no download to offer.
        let other = try #require(UpdateFeeds.electronRelease("version: 1.0\nfiles:\n  - url: A-x64.zip\n", feedURL: "https://x/latest-mac.yml", arch: "arm64"))
        #expect(other.url == nil)
        // A universal build named neither way still fits.
        let universal = try #require(UpdateFeeds.electronRelease("version: 2.0\nfiles:\n  - url: https://dl.example.com/A-2.0-mac.zip\n", feedURL: "https://x/latest-mac.yml", arch: "arm64"))
        #expect(universal.url == "https://dl.example.com/A-2.0-mac.zip")
    }

    @Test func readsTheAppStoreLookup() throws {
        let json = #"{"resultCount":1,"results":[{"version":"16.1","trackId":497799835,"releaseNotes":"Fixes","fileSizeBytes":"123","currentVersionReleaseDate":"2026-09-01T00:00:00Z"}]}"#
        let (release, id) = try #require(UpdateFeeds.storeRelease(Data(json.utf8)))
        #expect(release.version == "16.1" && id == 497_799_835 && release.size == 123 && release.notes == "Fixes")
        #expect(UpdateFeeds.storeRelease(Data(#"{"resultCount":0,"results":[]}"#.utf8)) == nil)
    }

    @Test func turnsReleaseNotesIntoText() {
        #expect(UpdateFeeds.htmlToText("<h2>New</h2><p>Faster&nbsp;sync</p><p>Fixes</p>") == "New\n\nFaster sync\n\nFixes")
        #expect(UpdateFeeds.htmlToText("<p>One</p>\n\n<p>Two</p>") == "One\n\nTwo")
        #expect(UpdateFeeds.htmlToText("Tom &amp; Jerry&rsquo;s <b>tea</b>") == "Tom & Jerry’s tea")
        #expect(UpdateFeeds.htmlToText("broken <tag") == "broken")
    }

    @Test func readsVendorPages() {
        let json = #"""
        {"downloads":[
          {"urls":{"Mac OS X":[{"product":"davinci-resolve","major":21,"minor":1,"releaseNum":0,"beta":255}]}},
          {"urls":{"Mac OS X":[{"product":"davinci-resolve","major":21,"minor":1,"releaseNum":1,"beta":255}],"Windows":[]}},
          {"urls":{"Mac OS X":[{"product":"davinci-resolve","major":22,"minor":0,"releaseNum":0,"beta":2}]}},
          {"urls":{"Mac OS X":[{"product":"fairlight-live","major":9,"minor":0,"releaseNum":0,"beta":255}]}}
        ]}
        """#
        #expect(UpdateVendor.blackmagic(Data(json.utf8)) == "21.1.1")
        #expect(UpdateVendor.blackmagic(Data("{}".utf8)) == nil)
        let flow = #"<div class="x">SoundFlow</div><div class="font-semibold text-xl">SoundFlow 6.2.4</div><div>Published July 7</div><div class="font-semibold text-xl">SoundFlow 6.2.1</div>"#
        #expect(UpdateVendor.soundflow(flow) == "6.2.4")
        #expect(UpdateVendor.soundflow(">SoundFlow rocks") == nil)
        #expect(UpdateVendor.totalmix(#"<a href="https://rme-audio.de/downloads/tmfx_203_1991_mac.zip"><a href="https://rme-audio.de/downloads/tmfx_mac_199.zip">"#) == "2.03")
        #expect(UpdateVendor.totalmix(#"<a href="tmfx_mac_199.zip">"#) == nil)
        #expect(UpdateVendor.forID("com.blackmagic-design.DaVinciResolve") != nil)
        #expect(UpdateVendor.forID("com.example.other") == nil)
    }
}

@Suite struct AppsCaskTests {
    /// Entries as formulae.brew.sh serves them (trimmed).
    static let catalog = #"""
    [
     {"token":"claude","name":["Claude"],"desc":"Anthropic's official Claude AI desktop app","homepage":"https://claude.com/download","version":"5.11492.5,1403e2cf44abfb23809c8ae11238d5e9704a41c2","auto_updates":true,"deprecated":false,"disabled":false,
      "artifacts":[{"uninstall":[{"quit":["com.anthropic.claudefordesktop","com.anthropic.claudefordesktop.helper"]}]},{"app":["Claude.app"],"target":"/Applications/Claude.app"},{"zap":[{"trash":["~/Library/Application Support/Claude","~/Library/Preferences/com.anthropic.claudefordesktop.plist"]}]}]},
     {"token":"alex313031-thorium","name":["Thorium"],"desc":null,"homepage":"https://thorium.rocks/","version":"M130.0.6723.174","auto_updates":null,"deprecated":false,"disabled":false,
      "artifacts":[{"app":["Thorium.app",{"target":"Thorium Browser.app"}],"target":"/Applications/Thorium Browser.app"}]},
     {"token":"fl-studio","name":["FL Studio"],"desc":"Digital audio workstation","homepage":"https://www.image-line.com/","version":"26.1.7.5419","auto_updates":true,"deprecated":false,"disabled":false,
      "artifacts":[{"pkg":["Install FL Studio.pkg"]},{"uninstall":[{"pkgutil":"com.image-line.pkg.flstudio"}]},{"zap":[{"trash":["~/Library/Caches/com.image-line.flstudio"]}]}]},
     {"token":"old-thing","name":["Old"],"homepage":"https://x","version":"latest","disabled":true,"artifacts":[{"app":["Old.app"]}]}
    ]
    """#

    @Test func readsTheCatalog() throws {
        let catalog = try CaskCatalog.parse(Data(Self.catalog.utf8))
        #expect(catalog.all.count == 4)
        let claude = try #require(catalog.byName["claude.app"]?.first)
        #expect(claude.version == "5.11492.5" && claude.autoUpdates && claude.name == "Claude")
        #expect(claude.mentions.contains("\"quit\":[\"com.anthropic.claudefordesktop\""))
        #expect(claude.mentions.contains("~/library/preferences/com.anthropic.claudefordesktop.plist"))
        // A renamed app is known by the name it's installed under.
        #expect(catalog.byName["thorium browser.app"]?.first?.token == "alex313031-thorium")
        #expect(catalog.byName["thorium.app"] == nil)
        let studio = try #require(catalog.all.first { $0.token == "fl-studio" })
        #expect(studio.pkg && studio.appNames.isEmpty)
        #expect(catalog.all.first { $0.token == "old-thing" }?.unversioned == true)
    }

    @Test func validatesTokens() {
        #expect(CaskCatalog.validToken("visual-studio-code@insiders"))
        #expect(CaskCatalog.validToken("1password"))
        #expect(!CaskCatalog.validToken("../../bad"))
        #expect(!CaskCatalog.validToken("--force"))
        #expect(!CaskCatalog.validToken("a b"))
        #expect(!CaskCatalog.validToken(""))
    }

    @Test func readsHomebrewsInstalledCasks() {
        // `brew list --cask --versions` on this Mac.
        let out = "chatgpt 26.1111.21308\nclaude 5.11492.5,1403e2cf44abfb23809c8ae11238d5e9704a41c2\ngenoffice 0.13.18\nlocalsend 1.18.2\ntailscale-app 1.104.7\n"
        let installed = BrewRecords.parseInstalled(out)
        #expect(installed.count == 5 && installed["tailscale-app"] == "1.104.7")
        // `brew info --json=v2 --cask --installed`, trimmed.
        let info = #"{"formulae":[],"casks":[{"token":"localsend","artifacts":[{"app":["LocalSend.app"],"target":"/Applications/LocalSend.app"},{"zap":[{"trash":["~/Library/Preferences/org.localsend.localsendApp.plist"]}]}]},{"token":"tailscale-app","artifacts":[{"app":["Tailscale.app"]}]}]}"#
        #expect(InstalledApps.parseBrewApps(Data(info.utf8)) == ["LocalSend.app": "localsend", "Tailscale.app": "tailscale-app"])
        #expect(InstalledApps.parseBrewApps(Data("not json".utf8)).isEmpty)
    }

    @Test func findsAdoptableAppsAndBrokenRecords() throws {
        let catalog = try CaskCatalog.parse(Data(Self.catalog.utf8))
        let records = BrewRecords.make(
            catalog: catalog,
            installed: ["alex313031-thorium": "M130"],
            apps: ["claude.app": false, "old.app": false],
            homebrew: true
        )
        #expect(records.adoptable["claude.app"]?.token == "claude")
        // Disabled casks aren't offered.
        #expect(records.adoptable["old.app"] == nil)
        #expect(records.broken.map(\.token) == ["alex313031-thorium"])
        let app = InstalledApp(name: "Claude", bundleID: "com.anthropic.claudefordesktop", version: "1.0", path: "/Applications/Claude.app",
                               source: .direct, brewToken: nil, protected: false)
        #expect(records.adoptable(app)?.token == "claude")
        var store = app
        store.source = .appStore
        #expect(records.adoptable(store) == nil)
        // An App Store copy isn't adoptable at all.
        let fromStore = BrewRecords.make(catalog: catalog, installed: [:], apps: ["claude.app": true], homebrew: true)
        #expect(fromStore.adoptable.isEmpty)
    }

    @Test func reportsBrewsReason() {
        #expect(Brew.failure("==> Downloading\nError: Cask 'x' is unavailable\n") == "Cask 'x' is unavailable")
        #expect(Brew.failure("one\ntwo") == "two")
        #expect(Brew.arguments(.repair) == ["reinstall", "--cask"])
        #expect(Brew.arguments(.adopt) == ["install", "--cask", "--adopt"])
    }
}

@Suite struct AppsUpdateMatchTests {
    func local(_ name: String, _ id: String, _ version: String) -> AppUpdates.Local {
        .init(path: "/Applications/\(name).app", name: name, bundleID: id, version: version, build: version, feed: nil, fromStore: false, brewToken: nil)
    }

    func cask(_ token: String, _ version: String, _ mentions: String = "", pkg: Bool = false, names: [String] = []) -> Cask {
        Cask(token: token, name: token, desc: nil, homepage: "", version: version, autoUpdates: false, appNames: names,
             mentions: mentions, pkg: pkg, disabled: false, unversioned: false)
    }

    @Test func picksTheCaskThatUpdatesAnApp() {
        let firefox = [cask("firefox", "157.0.1", names: ["Firefox.app"]), cask("firefox@beta", "158.0b5", names: ["Firefox.app"]),
                       cask("firefox@esr", "140.17.0", names: ["Firefox.app"])]
        let fl = cask("fl-studio", "26.1.7.5419", "~/library/caches/com.image-line.flstudio", pkg: true)
        let converter = cask("wondershare-uniconverter", "17.6.0", "\"quit\":\"com.google.chrome\"")
        let catalog = CaskCatalog(firefox + [fl, converter])
        func token(_ app: AppUpdates.Local) -> String? { AppUpdates.caskOf(app, catalog)?.token }
        #expect(token(local("Firefox", "org.mozilla.firefox", "157.0")) == "firefox")
        #expect(token(local("Firefox", "org.mozilla.firefox", "140.15.0")) == "firefox@esr")
        #expect(token(local("Firefox", "org.mozilla.firefox", "152.0")) == "firefox")
        // Named by bundle id: a package, and the app's file isn't the cask's.
        #expect(token(local("FL Studio 2026", "com.image-line.flstudio", "26.1.6.5406")) == "fl-studio")
        // Only mentioned by a cask for something else.
        #expect(token(local("Google Chrome", "com.google.chrome", "155.0")) == nil)
        // An uninstaller isn't the app.
        #expect(token(local("Remove FL Studio", "com.image-line.flstudio", "1.0")) == nil)
    }

    @Test func uninstallersAreNotTheApp() {
        #expect(AppUpdates.isUninstaller("Remove Soundtoys"))
        #expect(AppUpdates.isUninstaller("Melodyne Uninstaller"))
        #expect(AppUpdates.isUninstaller("Uninstall Resolve"))
        #expect(!AppUpdates.isUninstaller("Soundtoys Effect Rack"))
    }

    @Test func rejectsACaskForAnotherVendorsApp() {
        let logos = cask("logos", "53.1", #"{"uninstall":[{"quit":["com.logos.logos"]}]}"#)
        #expect(!AppUpdates.sameApp(logos, bundleID: "com.audio.logos"))
        #expect(AppUpdates.sameApp(logos, bundleID: "com.logos.desktop"))
        #expect(AppUpdates.sameApp(cask("logos", "53.1"), bundleID: "com.audio.logos"))
    }

    @Test func namesIDsOnBoundaries() {
        let c = cask("x", "1", #"{"zap":[{"trash":["~/library/caches/com.image-line.flstudio","~/library/preferences/com.vendor.app.plist"]}]}"#)
        #expect(AppUpdates.namesID(c, "com.image-line.flstudio"))
        #expect(AppUpdates.namesID(c, "com.vendor.app"))
        #expect(!AppUpdates.namesID(c, "image-line.flstudio"))
        #expect(!AppUpdates.namesID(c, "com.vendor.ap"))
    }

    @Test func comparesACaskWithTheInstalledApp() throws {
        let app = local("Zoom", "us.zoom.xos", "7.2.2")
        let found = try #require(AppUpdates.fromCask(app, cask("zoom", "7.2.2.88465"), .cask))
        #expect(!found.newer)
        #expect(try #require(AppUpdates.fromCask(app, cask("zoom", "7.3.0"), .cask)).newer)
        #expect(AppUpdates.fromCask(app, cask("zoom", "2026.1"), .cask) == nil)
    }

    @Test func describesHowEachUpdateInstalls() {
        var update = AppUpdate(id: "/Applications/A.app", name: "A", installed: "1", available: "2", method: .cask)
        #expect(update.installsHere(homebrew: true))
        #expect(!update.installsHere(homebrew: false))
        update.method = .vendor
        #expect(!update.installsHere(homebrew: true))
        #expect(update.howItUpdates(homebrew: true).contains("website"))
    }

    @Test func savesAndReadsAScan() throws {
        let scan = UpdateScan(updates: [AppUpdate(id: "/Applications/A.app", name: "A", installed: "1", available: "2", method: .sparkle)],
                              apps: 3, checked: 2, checkedAt: Date(timeIntervalSince1970: 1_700_000_000), homebrew: true)
        let data = try JSONStore.encoder.encode(scan)
        let back = try JSONStore.decoder.decode(UpdateScan.self, from: data)
        #expect(back.updates.first?.method == .sparkle && back.checkedAt == scan.checkedAt && back.apps == 3)
    }
}

extension AppUpdate {
    init(id: String, name: String, installed: String, available: String, method: Method) {
        self.init(id: id, name: name, bundleID: nil, installed: installed, available: available, method: method, notes: nil,
                  notesURL: nil, size: nil, released: nil, download: nil, sha512: nil, cask: nil, storeID: nil, homepage: nil)
    }
}
