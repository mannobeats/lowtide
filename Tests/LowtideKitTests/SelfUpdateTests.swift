import Foundation
import Testing
@testable import LowtideKit

/// Lowtide's own updates, from GitHub's release JSON.
@Suite struct SelfUpdateTests {
    private func json(tag: String = "v1.2.0", name: String? = "Lowtide 1.2.0", draft: Bool = false, prerelease: Bool = false,
                      assets: [String] = ["Lowtide-1.2.0.dmg", "Lowtide-1.2.0.zip"]) -> Data {
        let list = assets.map {
            #"{"name":"\#($0)","browser_download_url":"https://github.com/o/lowtide/releases/download/\#(tag)/\#($0)"}"#
        }.joined(separator: ",")
        let title = name.map { #""\#($0)""# } ?? "null"
        return Data(#"""
        {"tag_name":"\#(tag)","name":\#(title),"body":"- Fixes","html_url":"https://github.com/o/lowtide/releases/tag/\#(tag)",
         "draft":\#(draft),"prerelease":\#(prerelease),"published_at":"2026-11-21T12:00:00Z","assets":[\#(list)]}
        """#.utf8)
    }

    @Test func readsAPublishedRelease() throws {
        let release = try #require(SelfUpdate.release(from: json()))
        #expect(release.version == "1.2.0")
        #expect(release.title == "Lowtide 1.2.0")
        #expect(release.notes == "- Fixes")
        #expect(release.archive?.lastPathComponent == "Lowtide-1.2.0.zip")
        #expect(release.diskImage?.lastPathComponent == "Lowtide-1.2.0.dmg")
        #expect(release.page.absoluteString.hasSuffix("/releases/tag/v1.2.0"))
        #expect(release.published != nil)
    }

    @Test func neverOffersDraftsPreReleasesOrEmptyReleases() {
        #expect(SelfUpdate.release(from: json(draft: true)) == nil)
        #expect(SelfUpdate.release(from: json(prerelease: true)) == nil)
        #expect(SelfUpdate.release(from: json(assets: ["notes.txt"])) == nil)
        #expect(SelfUpdate.release(from: Data("not json".utf8)) == nil)
    }

    @Test func aReleaseWithOnlyADiskImageOpensItInstead() throws {
        let release = try #require(SelfUpdate.release(from: json(assets: ["Lowtide-1.2.0.dmg"])))
        #expect(release.archive == nil && release.diskImage != nil)
    }

    @Test func namesAnUntitledReleaseByItsVersion() throws {
        let release = try #require(SelfUpdate.release(from: json(tag: "2.0.0", name: nil)))
        #expect(release.version == "2.0.0" && release.title == "Lowtide 2.0.0")
    }

    @Test func comparesVersionsTheWayReleasesAreTagged() {
        #expect(AppVersion.isNewer("1.2.0", than: "1.1.9"))
        #expect(AppVersion.isNewer("1.10.0", than: "1.9.0"))
        #expect(!AppVersion.isNewer("1.2.0", than: "1.2.0"))
        #expect(!AppVersion.isNewer("1.1.0", than: "1.2.0"))
    }

    @Test func anUnsignedBundleHasNoTeam() {
        // The test runner's own bundle isn't a Developer ID app.
        #expect(SelfUpdate.team(of: URL(fileURLWithPath: "/nonexistent.app")) == nil)
    }
}
