import Foundation
import Testing
@testable import LowtideKit

/// Every package-manager parser, fed output captured from real Macs
/// (including the odd lines: several kegs, `(devel)` builds, default gems,
/// offline errors, a pkg-only cask).
@Suite struct ToolchainSourceTests {
    // MARK: Homebrew

    /// `brew list --formula --versions` on this Mac, plus a second keg line.
    static let brewList = """
        abseil 20260817.0
        ada-url 4.0.0_1
        ca-certificates 2026-11-05
        cargo-nextest 0.9.151
        icu4c@79 79.1
        llhttp 9.4.3
        openssl@3 3.3.1 3.5.9 3.4.0
        x264 r3222
        zstd 1.5.7_1
        lonely
        """

    /// `brew outdated --json=v2`, verbatim, with a tap formula added.
    static let brewOutdated = """
        {
          "formulae": [
            {
              "name": "cargo-nextest",
              "installed_versions": [
                "0.9.151"
              ],
              "current_version": "0.9.152",
              "pinned": false,
              "pinned_version": null
            },
            {
              "name": "llhttp",
              "installed_versions": [
                "9.4.3"
              ],
              "current_version": "9.4.4",
              "pinned": false,
              "pinned_version": null
            },
            {
              "name": "stripe/stripe-cli/stripe",
              "installed_versions": ["1.30.0"],
              "current_version": "1.31.0",
              "pinned": true,
              "pinned_version": "1.30.0"
            }
          ],
          "casks": [
            {"name": "claude", "installed_versions": ["5.11410.0"], "current_version": "5.11492.5"}
          ]
        }
        """

    /// `brew info --json=v2 --cask --installed`, trimmed to the fields read.
    static let brewCasks = """
        {"casks": [{"token": "claude", "version": "5.11492.5,1403e2cf44abfb23809c8ae11238d5e9704a41c2", "installed": "5.11492.5,1403e2cf44abfb23809c8ae11238d5e9704a41c2", "desc": "Anthropic's official Claude AI desktop app", "artifacts": [{"uninstall": [{"quit": ["com.anthropic.claudefordesktop"]}]}, {"app": ["Claude.app"], "target": "/Applications/Claude.app"}, {"zap": [{"trash": ["~/Library/Logs/Claude"]}]}]},
         {"token": "genoffice", "version": "0.13.18", "installed": "0.13.18", "desc": "Open-source AI office suite", "artifacts": [{"app": ["GenOffice.app"], "target": "/Applications/GenOffice.app"}, {"binary": ["/Applications/GenOffice.app/Contents/Resources/cli/genoffice"], "target": "/opt/homebrew/bin/genoffice"}]},
         {"token": "tailscale-app", "version": "1.104.7", "installed": "1.104.7", "desc": "Mesh VPN based on WireGuard", "artifacts": [{"uninstall": [{"quit": "io.tailscale.ipn.macsys"}]}, {"pkg": ["Tailscale-1.104.7-macos.pkg"]}]},
         {"token": "gcloud-cli", "version": "540.0.0", "installed": null, "desc": null, "artifacts": [{"binary": ["google-cloud-sdk/bin/gcloud"]}]}]}
        """

    @Test func readsNewestKegAndSkipsBareLines() {
        let listed = HomebrewSource.parseList(Self.brewList)
        #expect(listed.count == 9)
        #expect(listed.first { $0.0 == "openssl@3" }?.1 == "3.5.9")
        #expect(listed.first { $0.0 == "x264" }?.1 == "r3222")
        #expect(!listed.contains { $0.0 == "lonely" })
    }

    @Test func readsOutdatedWithTapNames() throws {
        let outdated = try #require(HomebrewSource.parseOutdated(Self.brewOutdated))
        #expect(outdated.formulae["cargo-nextest"]?.latest == "0.9.152")
        #expect(outdated.formulae["stripe"]?.pinned == true)
        #expect(outdated.casks["claude"]?.latest == "5.11492.5")
        #expect(HomebrewSource.parseOutdated("Error: Unknown command: outdatd") == nil)
        #expect(HomebrewSource.shortName("coder/coder/coder") == "coder")
    }

    @Test func separatesAppsFromCommandLineCasks() throws {
        let casks = try #require(HomebrewSource.parseCasks(Self.brewCasks))
        #expect(casks.map(\.token) == ["claude", "genoffice", "tailscale-app", "gcloud-cli"])
        #expect(casks[0].isApp && casks[0].installed == "5.11492.5")
        #expect(casks[1].isApp)
        #expect(!casks[2].isApp)
        #expect(!casks[3].isApp && casks[3].installed == nil)
    }

    @Test func mergesAHomebrewScan() throws {
        let outdated = try #require(HomebrewSource.parseOutdated(Self.brewOutdated))
        let packages = ToolPackage.finalize(try HomebrewSource.merge(
            list: Self.brewList, casks: Self.brewCasks, pinned: "zstd\n", outdated: outdated))
        let nextest = try #require(packages.first { $0.id == "formula:cargo-nextest" })
        #expect(nextest.outdated && nextest.latestVersion == "0.9.152" && nextest.bump == .patch && nextest.checked)
        #expect(packages.first { $0.id == "formula:zstd" }?.pinned == true)
        let claude = try #require(packages.first { $0.id == "cask:claude" })
        #expect(claude.kind == .app && claude.outdated && claude.currentVersion == "5.11492.5")
        #expect(packages.first { $0.id == "cask:gcloud-cli" }?.kind == .tool)
        #expect(packages.first { $0.id == "cask:gcloud-cli" }?.currentVersion == "540.0.0")
        #expect(packages.prefix(3).allSatisfy { $0.outdated })
    }

    @Test func readsFormulaDetails() throws {
        let item = try #require(JSONValue.object("""
            {"desc": "Next-generation test runner for Rust", "homepage": "https://nexte.st/", "license": "Apache-2.0",
             "versions": {"stable": "0.9.152", "head": "HEAD", "bottle": true},
             "dependencies": ["openssl@3", "zlib"], "build_dependencies": ["rust"], "caveats": "  \\n"}
            """))
        let details = HomebrewSource.details(item, cask: false, name: "cargo-nextest", packageID: "formula:cargo-nextest")
        #expect(details.packageType == "Homebrew Formula")
        #expect(details.dependencies == ["openssl@3", "rust", "zlib"])
        #expect(details.availableVersions == ["0.9.152", "HEAD"])
        #expect(details.caveats == nil)
        #expect(details.packageURL == "https://formulae.brew.sh/formula/cargo-nextest")
        let license = try #require(JSONValue.object(#"{"license": {"any_of": ["MIT", "Apache-2.0"]}}"#))
        #expect(JSONValue.display(license["license"]) == "any_of: MIT, Apache-2.0")
        let cask = try #require(JSONValue.object(#"{"artifacts": [{"uninstall": []}, {"app": ["Claude.app"], "target": "/Applications/Claude.app"}]}"#))
        #expect(HomebrewSource.caskInstallPath(cask) == "/Applications/Claude.app")
    }

    // MARK: npm, pnpm, Bun

    /// `npm ls -g --depth=0 --json` on this Mac (npm 12.2.2).
    static let npmList = """
        {
          "name": "lib",
          "dependencies": {
            "npm": {
              "version": "12.2.2",
              "overridden": false
            },
            "@anthropic-ai/sandbox-runtime": { "version": "0.4.1", "overridden": false },
            "linked-tool": { "resolved": "file:../../Projects/linked-tool" }
          }
        }
        """

    @Test func readsNPMGlobals() throws {
        let listed = try #require(NPMSource.parseList(Self.npmList))
        #expect(listed.map(\.0) == ["@anthropic-ai/sandbox-runtime", "linked-tool", "npm"])
        #expect(listed[1].1 == "")
        #expect(NPMSource.parseList("npm ERR! code ELSPROBLEMS") == nil)
    }

    @Test func tellsOutdatedFromUnknown() {
        // Nothing outdated (this Mac): checked and current.
        #expect(NodeOutdated.parse("{}") == [:])
        let latest = NodeOutdated.parse(#"{"npm": {"current": "12.2.2", "wanted": "12.2.2", "latest": "12.3.0", "dependent": "global", "location": "/opt/homebrew/lib/node_modules/npm"}}"#)
        #expect(latest?["npm"] == "12.3.0")
        // Offline: npm prints an error object. That is
        // "unknown", not "nothing outdated".
        let offline = """
            {
              "error": {
                "code": "ENOTFOUND",
                "summary": "request to https://registry.npmjs.org/npm failed, reason: getaddrinfo ENOTFOUND registry.npmjs.org",
                "detail": "This is a problem related to network connectivity."
              }
            }
            """
        #expect(NodeOutdated.parse(offline) == nil)
        #expect(NodeOutdated.parse("") == nil)
        let packages = NodeOutdated.apply(prefix: "npm", [("npm", "12.2.2")], outdated: offline)
        #expect(packages.first?.checked == false)
    }

    /// `pnpm ls -g --depth=0 --json` on this Mac (pnpm 12.18, nothing installed), and with packages.
    @Test func readsPNPMGlobals() throws {
        let empty = """
            [
              {
                "path": "/Users/me/Library/pnpm/global/v11",
                "private": true,
                "dependencies": {}
              }
            ]
            """
        #expect(try #require(PNPMSource.parseList(empty)).isEmpty)
        let some = #"[{"path": "/Users/me/Library/pnpm/global/5", "dependencies": {"vercel": {"from": "vercel", "version": "48.2.0", "resolved": "https://registry.npmjs.org/vercel/-/vercel-48.2.0.tgz"}, "@biomejs/biome": {"version": "2.3.1"}}}]"#
        #expect(try #require(PNPMSource.parseList(some)).map(\.0) == ["@biomejs/biome", "vercel"])
        // Its setup error is plain text, not JSON: surfaced, not an empty list.
        #expect(PNPMSource.parseList("ERR_PNPM_NO_GLOBAL_BIN_DIR  Unable to find the global bin directory\n\nRun \"pnpm setup\" to create it automatically") == nil)
    }

    @Test func keepsPrivateBunPackagesOffPublicNPM() {
        let dependencies = ["typescript": "^5.9.0", "@acme/cli": "^1.0.0", "@types/node": "^24", "tool": "github:me/tool",
                            "local": "file:../local"]
        #expect(BunSource.publicNames(dependencies, config: "") == ["@acme/cli", "@types/node", "typescript"])
        #expect(BunSource.publicNames(dependencies, config: "@acme:registry=https://npm.acme.dev/") == ["@types/node", "typescript"])
        #expect(BunSource.publicNames(dependencies, config: "[install.scopes]\nacme = { url = \"https://npm.acme.dev\" }") == ["@types/node", "typescript"])
        #expect(BunSource.publicNames(dependencies, config: "registry=https://npm.acme.dev/").isEmpty)
        #expect(BunSource.publicNames(dependencies, config: "registry=https://registry.npmjs.org/").count == 3)
    }

    // MARK: Cargo

    /// `~/.cargo/.crates2.json` on this Mac (trimmed), plus a git install.
    static let crates2 = """
        {"installs":{"bacon 3.26.0 (registry+https://github.com/rust-lang/crates.io-index)":{"version_req":null,"bins":["bacon"],"features":[],"all_features":false,"no_default_features":false,"profile":"release","target":"aarch64-apple-darwin","rustc":"rustc 1.100.0 (0ef1bc386 2026-11-09)\\nbinary: rustc\\n"},
        "cargo-edit 0.13.14 (registry+https://github.com/rust-lang/crates.io-index)":{"version_req":null,"bins":["cargo-add","cargo-rm","cargo-set-version","cargo-upgrade"],"features":["vendored-openssl"],"all_features":false,"no_default_features":true},
        "ripgrep 15.1.0 (sparse+https://index.crates.io/)":{"bins":["rg"],"features":[],"all_features":true,"no_default_features":false},
        "mytool 0.1.0 (git+https://github.com/me/mytool#abc1234)":{}}}
        """

    @Test func readsCargoInstallRecords() throws {
        let installs = CargoSource.parseInstalls(Self.crates2)
        #expect(installs.map(\.name) == ["bacon", "cargo-edit", "mytool", "ripgrep"])
        #expect(installs[0].registry && installs[0].version == "3.26.0")
        #expect(installs[1].binaries.count == 4)
        #expect(!installs[2].registry)
        #expect(installs[3].registry)
        #expect(try CargoSource.reinstallArguments(installs[1]) == ["install", "cargo-edit", "--features", "vendored-openssl", "--no-default-features"])
        #expect(try CargoSource.reinstallArguments(installs[3]) == ["install", "ripgrep", "--all-features"])
        #expect(throws: LowtideError.self) { try CargoSource.reinstallArguments(installs[2]) }
        #expect(CargoSource.parseInstalls("not json").isEmpty)
    }

    @Test func readsTheCratesSparseIndex() {
        // Real lines from index.crates.io/ba/co/bacon (deps trimmed), plus a yanked and a prerelease.
        let index = """
            {"name":"bacon","vers":"3.24.0","deps":[],"cksum":"x","features":{},"yanked":false}
            {"name":"bacon","vers":"3.25.0","deps":[],"cksum":"x","features":{},"yanked":false}
            {"name":"bacon","vers":"3.26.0","deps":[],"cksum":"x","features":{},"yanked":false}
            {"name":"bacon","vers":"3.27.0","deps":[],"cksum":"x","features":{},"yanked":true}
            {"name":"bacon","vers":"4.0.0-alpha.1","deps":[],"cksum":"x","features":{},"yanked":false}
            """
        #expect(LatestVersions.newestCrate(index) == "3.26.0")
        #expect(LatestVersions.crateIndexPath("bacon") == "ba/co/bacon")
        #expect(LatestVersions.crateIndexPath("rg") == "2/rg")
        #expect(LatestVersions.crateIndexPath("Syn") == "3/s/syn")
        #expect(LatestVersions.crateIndexPath("a") == "1/a")
    }

    // MARK: Go

    /// `go version -m` on two Go binaries Homebrew installed on this Mac, and a `go install`ed one.
    static let goBuildInfo = """
        /opt/homebrew/bin/gh: go1.27.4
        \tpath\tgithub.com/cli/cli/v2/cmd/gh
        \tmod\tgithub.com/cli/cli/v2\t(devel)\t
        \tdep\tcharm.land/bubbles/v2\tv2.2.1\th1:Fq1+qm5hV6GkvzLQDhCBpXXE5tLgvh1PRriCLwSvIQU=
        \tdep\tcharm.land/glamour/v2\tv2.0.2-0.20261015065741-010543cac1a0\th1:pnfN6r+BBGd0G4aRPGu28RjUZlh1Fg1ZtC4BCqyO2Zg=
        \tbuild\t-buildmode=exe
        /Users/me/go/bin/golangci-lint: go1.23.0
        \tpath\tgithub.com/golangci/golangci-lint/cmd/golangci-lint
        \tmod\tgithub.com/golangci/golangci-lint\tv1.61.0\th1:x=
        \tdep\tgithub.com/a/b\tv1.0.0
        /Users/me/go/bin/gopls: go1.23.0
        \tpath\tgolang.org/x/tools/gopls
        \tmod\tgolang.org/x/tools/gopls\tv0.16.2\th1:y=
        /bin/ls: could not read Go build info from /bin/ls: not a Go executable
        """

    @Test func readsGoBuildInfo() {
        let binaries = GoSource.parseBuildInfo(Self.goBuildInfo)
        #expect(binaries.map(\.name) == ["gh", "golangci-lint", "gopls"])
        #expect(binaries[0].version == "(devel)" && !binaries[0].isReleased)
        #expect(binaries[1].package == "github.com/golangci/golangci-lint/cmd/golangci-lint")
        #expect(binaries[1].module == "github.com/golangci/golangci-lint" && binaries[1].version == "v1.61.0")
        #expect(binaries[2].isReleased)
    }

    @Test func keepsPrivateGoModulesPrivate() {
        let patterns = ["github.com/acme/*", "*.corp.dev"]
        #expect(GoSource.excluded(patterns, module: "github.com/acme/tool/cmd/x"))
        #expect(GoSource.excluded(patterns, module: "git.corp.dev/team/thing"))
        #expect(!GoSource.excluded(patterns, module: "github.com/golangci/golangci-lint"))
        #expect(!GoSource.excluded(patterns, module: "github.com/acme"))
        #expect(GoSource.excluded(["github.com/[ab]cme"], module: "github.com/acme"))
        // `go env GOPROXY GONOPROXY` on this Mac: the default proxy, nothing private.
        #expect(GoSource.parseProxyExclusions("https://proxy.golang.org,direct\n\n") == [])
        #expect(GoSource.parseProxyExclusions("https://proxy.golang.org,direct\ngithub.com/acme/*,*.corp.dev\n") == patterns)
        #expect(GoSource.parseProxyExclusions("https://goproxy.acme.dev\n\n") == nil)
        #expect(GoSource.parseProxyExclusions("off\n") == nil)
        #expect(LatestVersions.goModuleEscape("github.com/BurntSushi/toml") == "github.com/!burnt!sushi/toml")
    }

    // MARK: RubyGems, pipx, Composer, App Store, standalone

    /// `gem list --local` from this Mac's Ruby 2.6 (trimmed), with odd lines added.
    static let gemList = """
        bigdecimal (default: 1.4.1)
        bundler (default: 1.17.2)
        CFPropertyList (2.3.6)
        did_you_mean (1.3.0)
        nokogiri (1.13.8)
        nokogiri-arm (1.16.0 arm64-darwin, default: 1.15.0)
        rake (13.2.1, 12.3.3, default: 13.0.6)

        *** LOCAL GEMS ***
        """

    @Test func readsGems() {
        let gems = GemSource.parseList(Self.gemList)
        #expect(gems.count == 7)
        #expect(gems.first { $0.0 == "bundler" }?.1 == "1.17.2")
        #expect(gems.first { $0.0 == "rake" }?.1 == "13.2.1")
        // The platform is dropped: "1.16.0 arm64-darwin" reads "1.16.0".
        #expect(gems.first { $0.0 == "nokogiri-arm" }?.1 == "1.16.0")
        let outdated = GemSource.parseOutdated("rdoc (7.0.4 < 8.0.0)\nnokogiri (1.13.8 < 1.18.10)\nWARNING: noise\n")
        #expect(outdated == ["rdoc": "8.0.0", "nokogiri": "1.18.10"])
    }

    @Test func readsPipxVenvs() throws {
        let json = """
            {"pipx_spec_version": "0.1", "venvs": {
              "black": {"metadata": {"main_package": {"package": "black", "package_version": "24.1.0", "package_or_url": "black", "apps": ["black", "blackd"]}, "python_version": "Python 3.12.2"}},
              "httpie": {"metadata": {"main_package": {"package": "httpie", "package_version": "3.2.4", "package_or_url": "httpie==3.2.4"}}},
              "mytool": {"metadata": {"main_package": {"package": "mytool", "package_version": "0.0.1", "package_or_url": "git+https://github.com/me/mytool"}}},
              "local-thing": {"metadata": {"main_package": {"package": "local_thing", "package_version": "1.0", "package_or_url": "./local-thing"}}}
            }}
            """
        let venvs = try #require(PipxSource.parseList(json))
        #expect(venvs.map(\.name) == ["black", "httpie", "local-thing", "mytool"])
        #expect(!venvs[0].local && venvs[0].version == "24.1.0")
        #expect(!venvs[1].local)
        #expect(venvs[2].local && venvs[2].distribution == "local_thing")
        #expect(venvs[3].local)
        #expect(ToolConfig.customRegistry("[global]\nindex-url = https://pypi.acme.dev/simple\n", keys: ["index-url"], public: "pypi.org"))
        #expect(!ToolConfig.customRegistry("[global]\ntimeout = 60\n", keys: ["index-url"], public: "pypi.org"))
    }

    @Test func readsComposerGlobals() throws {
        let show = #"{"installed": [{"name": "laravel/installer", "direct-dependency": true, "homepage": "https://laravel.com", "source": "https://github.com/laravel/installer/tree/v5.8.3", "version": "v5.8.3", "description": "Laravel application installer.", "abandoned": false}, {"name": "symfony/console", "version": "v7.2.1", "description": "Eases the creation of beautiful and testable command line interfaces"}]}"#
        let entries = try #require(ComposerSource.parseShow(show))
        #expect(entries.map(\.name) == ["laravel/installer", "symfony/console"])
        let outdated = try #require(ComposerSource.parseShow(#"{"installed": [{"name": "laravel/installer", "version": "v5.8.3", "latest": "v5.9.0", "latest-status": "semver-safe-update"}]}"#))
        #expect(outdated.first?.latest == "v5.9.0")
        #expect(ComposerSource.isEmptyGlobal("Changed current directory to /Users/me/.composer\n\n  [InvalidArgumentException]\n  could not find a composer.json file in /Users/me/.composer"))
    }

    @Test func readsAppStoreApps() {
        let list = """
            497799835  Xcode                 (16.2)
            1352778147 Bitwarden             (2025.1.0)
            1475387142 Tailscale (Mac App)   (1.78.1)
              409183694  Keynote  (14.3)
            """
        let apps = MacAppStoreSource.parseList(list)
        #expect(apps.map(\.id) == ["497799835", "1352778147", "1475387142", "409183694"])
        #expect(apps[2].name == "Tailscale (Mac App)" && apps[2].version == "1.78.1")
        let outdated = MacAppStoreSource.parseOutdated("497799835 Xcode (16.1 -> 16.2)\n409183694 Keynote (14.2 -> 14.3)\nnoise\n")
        #expect(outdated == ["497799835": "16.2", "409183694": "14.3"])
    }

    @Test func readsStandaloneVersions() {
        // `--version` of the tools on this Mac, and others seen in the wild.
        #expect(StandaloneSource.parseVersion("2.1.325 (Claude Code)\n", "") == "2.1.325")
        #expect(StandaloneSource.parseVersion("codex-cli 0.169.0\n", "") == "0.169.0")
        #expect(StandaloneSource.parseVersion("uv 0.13.8 (Homebrew 2026-11-12 aarch64-apple-darwin)\n", "") == "0.13.8")
        #expect(StandaloneSource.parseVersion("deno 2.9.7 (stable, release, aarch64-apple-darwin)\nv8 14.0\n", "") == "2.9.7")
        #expect(StandaloneSource.parseVersion("1.4.4\n", "") == "1.4.4")
        #expect(StandaloneSource.parseVersion("", "opencode v0.15.3") == "0.15.3")
        #expect(StandaloneSource.parseVersion("usage: tool", "") == "unknown")
        #expect(StandaloneSource.isSelfManaged(real: "/Users/me/.local/share/claude/versions/2.1.325"))
        #expect(!StandaloneSource.isSelfManaged(real: "/opt/homebrew/Cellar/uv/0.13.8/bin/uv"))
        #expect(!StandaloneSource.isSelfManaged(real: "/Users/me/.npm-global/lib/node_modules/@openai/codex/bin/codex.js"))
    }

    // MARK: Registries and metadata

    @Test func readsRegistryMetadata() throws {
        var npm = PackageDetails(source: "npm", packageID: "npm:typescript")
        PackageMetadata.apply(source: "npm", json: try #require(JSONValue.object("""
            {"name": "typescript", "version": "5.9.3", "description": "TypeScript is a language for application scale JavaScript development",
             "homepage": "https://www.typescriptlang.org/", "license": "Apache-2.0",
             "repository": {"type": "git", "url": "git+https://github.com/microsoft/TypeScript.git"}, "dependencies": {}}
            """)), to: &npm)
        #expect(npm.repository == "https://github.com/microsoft/TypeScript")
        #expect(npm.availableVersions == ["5.9.3"] && npm.license == "Apache-2.0")

        var go = PackageDetails(source: "go", packageID: "go:golang.org/x/tools/gopls")
        // proxy.golang.org/golang.org/x/tools/gopls/@latest, verbatim.
        PackageMetadata.apply(source: "go", json: try #require(JSONValue.object(#"{"Version":"v0.24.0","Time":"2026-10-14T17:42:10Z","Origin":{"VCS":"git","URL":"https://go.googlesource.com/tools","Subdir":"gopls","Hash":"1f9922d1dcc5836d5c5bcb552c8fed230f885372","Ref":"refs/tags/gopls/v0.24.0"}}"#)), to: &go)
        #expect(go.availableVersions == ["v0.24.0"] && go.repository == "https://go.googlesource.com/tools")
        #expect(go.latestReleaseDate == "2026-10-14T17:42:10Z")

        var pypi = PackageDetails(source: "pipx", packageID: "pipx:ruff")
        PackageMetadata.apply(source: "pipx", json: try #require(JSONValue.object("""
            {"info": {"summary": "An extremely fast Python linter", "home_page": "", "license": "", "license_expression": "MIT",
             "project_urls": {"Documentation": "https://docs.astral.sh/ruff/", "Repository": "https://github.com/astral-sh/ruff"},
             "version": "0.17.5"}, "releases": {"0.17.5": [{"upload_time_iso_8601": "2026-11-06T18:00:00.000000Z"}]}}
            """)), to: &pypi)
        #expect(pypi.homepage == nil && pypi.license == "MIT")
        #expect(pypi.repository == "https://github.com/astral-sh/ruff" && pypi.documentation == "https://docs.astral.sh/ruff/")
        #expect(pypi.latestReleaseDate == "2026-11-06T18:00:00.000000Z")
    }

    @Test func picksTheLineThatExplainsAFailure() {
        #expect(ToolCommand.failureLine("==> Upgrading 1 outdated package\nError: Cannot install under Rosetta\nlater noise") == "Cannot install under Rosetta")
        #expect(ToolCommand.failureLine("only line") == "only line")
        #expect(ToolCommand.failureLine("npm ERR! code EACCES\nnpm ERR! path /usr/local/lib") == "npm ERR! path /usr/local/lib")
        #expect(ToolCommand.failureLine("") == nil)
    }

    @Test func everySourceHasAMark() {
        let marks = Set(PackageSources.all.map(\.info.icon))
        for mark in marks {
            #expect(FileManager.default.fileExists(atPath: AppResources.url("sources/\(mark).svg").path), "missing \(mark)")
        }
        #expect(Set(PackageSources.all.map(\.info.id)).count == PackageSources.all.count)
    }
}
