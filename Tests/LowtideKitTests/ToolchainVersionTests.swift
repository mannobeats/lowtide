import Foundation
import Testing
@testable import LowtideKit

@Suite struct ToolchainVersionTests {
    func order(_ a: String, _ b: String) -> ComparisonResult { PackageVersion.compare(a, b) }

    @Test func ordersVersionsAcrossEcosystems() {
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
    }

    /// Versions this Mac's Homebrew actually reported.
    @Test func ordersRealHomebrewVersions() {
        #expect(order("0.9.152", "0.9.151") == .orderedDescending)          // cargo-nextest
        #expect(order("4.0.0_1", "4.0.0") == .orderedDescending)                // ada-url revision
        #expect(order("20260817.0", "20260722.1") == .orderedDescending)    // abseil
        #expect(order("2026-11-05", "2026-10-14") == .orderedDescending)    // ca-certificates
        #expect(order("r3222", "r3108") == .orderedDescending)              // x264
        // A cask build hash after the version: the version still decides.
        #expect(order("5.11492.5,1403e2cf44abfb23809c8ae11238d5e9704a41c2", "5.11410.0,0f2b") == .orderedDescending)
        #expect(PackageVersion.newest(["3.3.1", "3.3.2", "3.3.10"]) == "3.3.10")
    }

    @Test func measuresTheUpdateStep() {
        #expect(PackageVersion.bump(from: "0.22.1", to: "0.22.2") == .patch)
        #expect(PackageVersion.bump(from: "v0.21.0", to: "v0.23.0") == .major)
        #expect(PackageVersion.bump(from: "2.35.3", to: "2.37.3") == .minor)
        #expect(PackageVersion.bump(from: "2.35.3", to: "2.35.4") == .patch)
        #expect(PackageVersion.bump(from: "7.0.4", to: "8.0.0") == .major)
        #expect(PackageVersion.bump(from: "1.2.3_1", to: "1.2.3_2") == .other)
        #expect(PackageVersion.bump(from: "2.1.283", to: "2.1.274") == nil)
        #expect(PackageVersion.bump(from: "", to: "1.0.0") == nil)
        #expect(PackageVersion.bump(from: "9.4.3", to: "9.4.4") == .patch)       // llhttp, real
        #expect(PackageVersion.bump(from: "2.1.311", to: "2.1.325") == .patch)   // Claude Code stable → latest
    }

    @Test func spotsPrereleases() {
        #expect(PackageVersion.isPrerelease("2.0.0-beta.1"))
        #expect(PackageVersion.isPrerelease("3.15.0rc2"))
        #expect(PackageVersion.isPrerelease("v0.24.0-pre.1"))
        #expect(!PackageVersion.isPrerelease("1.1.1a"))
        #expect(!PackageVersion.isPrerelease("v0.24.0"))
    }

    @Test func finalizeDerivesOutdatedAndSortsItFirst() {
        let packages = ToolPackage.finalize([
            ToolPackage(id: "formula:zstd", name: "zstd", currentVersion: "1.5.7_1", checked: true),
            ToolPackage(id: "formula:llhttp", name: "llhttp", currentVersion: "9.4.3", latestVersion: "9.4.4", outdated: true, checked: true),
            // A rebuilt bottle: Homebrew says outdated, the versions alone can't.
            ToolPackage(id: "formula:sqlite", name: "sqlite", currentVersion: "3.54.1", latestVersion: "3.54.1", outdated: true, checked: true),
            ToolPackage(id: "npm:typescript", name: "typescript", currentVersion: "5.9.0", latestVersion: "6.0.1", checked: true),
            ToolPackage(id: "cargo:bacon", name: "bacon", currentVersion: "3.26.0", latestVersion: "3.25.0", checked: true),
        ])
        #expect(packages.map(\.name) == ["llhttp", "sqlite", "typescript", "bacon", "zstd"])
        #expect(packages[0].bump == .patch)
        #expect(packages[1].bump == .other)
        #expect(packages[2].bump == .major && packages[2].outdated)
        #expect(!packages[3].outdated && packages[3].bump == nil)
    }

    @Test func unknownIsNeverUpToDate() {
        let unknown = ToolPackage(id: "npm:x", name: "x", currentVersion: "1.0.0")
        #expect(unknown.canUpdate && !unknown.needsUpdate)
        let pinned = ToolPackage(id: "formula:x", name: "x", currentVersion: "1", latestVersion: "2", outdated: true, pinned: true, checked: true)
        #expect(!pinned.canUpdate && !pinned.needsUpdate)
    }

    @Test func packageIDsNeverBecomeFlags() throws {
        #expect(try PackageID.strip("npm:@scope/tool", prefix: "npm") == "@scope/tool")
        #expect(throws: LowtideError.self) { try PackageID.strip("npm:--global", prefix: "npm") }
        #expect(throws: LowtideError.self) { try PackageID.strip("npm:a b", prefix: "npm") }
        #expect(throws: LowtideError.self) { try PackageID.strip("cargo:x", prefix: "npm") }
        #expect(try PackageID.split("cask:ghostty") == ("cask", "ghostty"))
        #expect(throws: LowtideError.self) { try PackageID.split("formula:-v") }
    }

    @Test func createsRegistryLinks() {
        let npm = PackageDetails(source: "npm", packageID: "npm:@scope/tool")
        #expect(npm.packageType == "JavaScript package")
        #expect(npm.packageURL == "https://www.npmjs.com/package/@scope/tool")
        let cargo = PackageDetails(source: "cargo", packageID: "cargo:cargo-audit")
        #expect(cargo.packageType == "Rust crate" && cargo.packageURL == "https://crates.io/crates/cargo-audit")
    }
}
