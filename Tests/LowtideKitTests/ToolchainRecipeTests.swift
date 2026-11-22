import Foundation
import Testing
@testable import LowtideKit

@Suite struct ToolchainRecipeTests {
    @Test func parsesBrewVersionsAndLeaves() {
        // `brew list --cask --versions` on this Mac.
        let casks = RecipeCollector.parseNameVersions("""
            chatgpt 26.1111.21308
            claude 5.11492.5,1403e2cf44abfb23809c8ae11238d5e9704a41c2
            tailscale-app 1.104.7
            lonely
            """)
        #expect(casks.count == 4)
        #expect(casks[1].1 == "5.11492.5,1403e2cf44abfb23809c8ae11238d5e9704a41c2")
        #expect(casks[3].0 == "lonely" && casks[3].1 == nil)
        // `brew leaves --installed-on-request` here includes a tap formula.
        let formulae = RecipeCollector.formulae(leaves: "bun\ngo\nopenssl@3\nstripe/stripe-cli/stripe\n",
                                                versions: "bun 1.4.4_1\ngo 1.27.4\nopenssl@3 3.3.1 3.5.9\nstripe 1.31.0\n")
        #expect(formulae.map(\.id) == ["brew:bun", "brew:go", "brew:openssl@3", "brew:stripe/stripe-cli/stripe"])
        #expect(formulae[2].version == "3.5.9" && formulae[3].version == "1.31.0")
    }

    @Test func parsesUVToolsGemsAndExtensions() {
        // `uv tool list` on this Mac, and with a warning and two tools.
        let uv = RecipeCollector.parseUVTools("ruff v0.17.5\n- ruff\n")
        #expect(uv == [RecipeItem(id: "uv:ruff", name: "ruff", version: "0.17.5")])
        let more = RecipeCollector.parseUVTools("warning: `uv tool list` is experimental\nblack v24.1.0\n- black\n- blackd\nruff v0.5.0\n- ruff\n")
        #expect(more.map(\.id) == ["uv:black", "uv:ruff"])
        let gems = RecipeCollector.parseGems("bundler (default: 2.5.0)\nrails (7.1.3, 7.0.8)\nnokogiri (1.16.0 arm64-darwin, default: 1.15.0)\n")
        #expect(gems.map(\.id) == ["gem:rails", "gem:nokogiri"])
        #expect(gems[0].version == "7.1.3" && gems[1].version == "1.16.0")
        let extensions = RecipeCollector.parseExtensions(kind: "code", "Biomejs.Biome@2.1.0\nrust-lang.rust-analyzer@0.3.2\n\n")
        #expect(extensions.first == RecipeItem(id: "code:biomejs.biome", name: "biomejs.biome", version: "2.1.0"))
        #expect(extensions.count == 2)
    }

    @Test func namesFiles() {
        #expect(MacRecipe.fileName("Jane's MacBook Pro") == "jane-s-macbook-pro.lowtide-recipe.json")
        #expect(MacRecipe.fileName("???") == "mac.lowtide-recipe.json")
    }

    func recipe(_ sections: [RecipeSection], name: String = "m", hosts: [RecipeHost]? = nil) -> MacRecipe {
        MacRecipe(machine: .init(name: name, os: "macOS 26.2", arch: "aarch64"), sections: sections, hosts: hosts,
                  createdAt: Date(timeIntervalSince1970: 0))
    }

    @Test func roundTripsAndReadsSavedRecipes() throws {
        let original = recipe([RecipeSection(id: "brew", label: "Homebrew formulae", items: [RecipeItem(id: "brew:fd", name: "fd", version: "10.2.0")])],
                              hosts: [RecipeHost(group: "Prod", hostname: "10.0.0.4", name: "db", port: 22, user: "deploy")])
        let decoded = try MacRecipe.decode(try original.encoded())
        #expect(decoded == original)
        // A saved file, with its theme objects.
        let saved = """
            {"format": "lowtide-recipe", "version": 1, "createdAt": 1763078400000,
             "machine": {"name": "Studio", "os": "macOS 26.1", "arch": "aarch64"},
             "sections": [{"id": "casks", "label": "Homebrew casks", "items": [{"id": "cask:ghostty", "name": "ghostty", "version": "1.2.0"}]}],
             "hosts": [{"group": null, "hostname": "box.local", "name": "box", "port": 2222, "user": "me"}],
             "settings": {"themeId": "graphite", "customThemes": [{"id": "dusk", "name": "Dusk", "format": "lowtide-theme", "colors": {"bg": "#000"}}]}}
            """
        let opened = try MacRecipe.decode(Data(saved.utf8))
        #expect(opened.machine.name == "Studio" && opened.sections.first?.items.first?.version == "1.2.0")
        #expect(opened.allSections.map(\.id) == ["casks", "ssh-hosts", "settings"])
        #expect(opened.allSections[1].items.first?.version == "me@box.local:2222")
        #expect(throws: LowtideError.self) { try MacRecipe.decode(Data(#"{"format": "lowtide-recipe", "version": 2, "sections": []}"#.utf8)) }
        #expect(throws: LowtideError.self) { try MacRecipe.decode(Data(#"{"sections": []}"#.utf8)) }
        #expect(throws: LowtideError.self) { try MacRecipe.decode(Data("brew \"git\"\n".utf8)) }
    }

    @Test func diffsTwoMacs() {
        let here = recipe([RecipeSection(id: "brew", label: "Homebrew formulae", items: [
            RecipeItem(id: "brew:fd", name: "fd", version: "1"), RecipeItem(id: "brew:jq", name: "jq", version: "1"),
        ])])
        let other = recipe([RecipeSection(id: "brew", label: "Homebrew formulae", items: [
            RecipeItem(id: "brew:fd", name: "fd", version: "2"), RecipeItem(id: "brew:rg", name: "rg"),
        ])], hosts: [RecipeHost(group: nil, hostname: "h", name: "box", port: 22, user: "u")])
        let diff = here.diff(other)
        let brew = diff.first { $0.id == "brew" }
        #expect(brew?.missing.map(\.id) == ["brew:rg"])
        #expect(brew?.onlyHere.map(\.id) == ["brew:jq"])
        #expect(brew?.changed.first?.here == "1")
        #expect(diff.contains { $0.id == "ssh-hosts" })
        #expect(here.diff(here).isEmpty)
    }

    @Test func writesASafeScript() {
        let evil = MacRecipe(machine: .init(name: "Evil\nrm -rf ~", os: "macOS", arch: "aarch64"), sections: [
            RecipeSection(id: "brew", label: "Homebrew formulae", items: [
                RecipeItem(id: "brew:ripgrep", name: "ripgrep"), RecipeItem(id: "brew:it's", name: "it's"),
                RecipeItem(id: "brew:--force", name: "--force"), RecipeItem(id: "brew:ripgrep", name: "ripgrep"),
            ]),
            RecipeSection(id: "mas", label: "Mac App Store", items: [RecipeItem(id: "mas:497799835", name: "Xcode"), RecipeItem(id: "mas:1; rm", name: "x")]),
            RecipeSection(id: "npm", label: "npm globals", items: [RecipeItem(id: "npm:$(whoami)", name: "x")]),
            RecipeSection(id: "go", label: "Go binaries", items: [RecipeItem(id: "go:gopls", name: "gopls")]),
        ])
        let script = evil.script()
        #expect(script.contains("# Lowtide recipe from Evil rm -rf ~."))
        #expect(!script.contains("\nrm -rf"))
        #expect(script.contains("    'ripgrep' \\\n    'it'\\''s'\n  do"))
        #expect(script.components(separatedBy: "'ripgrep'").count == 2)
        #expect(!script.contains("--force"))
        #expect(script.contains("'497799835'") && !script.contains("1; rm"))
        #expect(script.contains("'$(whoami)'"))
        #expect(script.contains("Installing Homebrew"))
        #expect(script.contains("set up by hand: gopls"))
        #expect(script.hasSuffix("echo '==> Done'\n"))

        let only = evil.script(only: ["npm:$(whoami)"])
        #expect(!only.contains("brew install") && !only.contains("Installing Homebrew"))
        #expect(only.contains("npm install -g"))
        #expect(!MacRecipe.forTerminal(script).contains("#!/usr/bin/env bash"))
        #expect(MacRecipe.quote("it's") == #"'it'\''s'"#)
        #expect(MacRecipe.quote("$(rm -rf ~)") == "'$(rm -rf ~)'")
    }

    @Test func timesOutAWedgedSection() async {
        await #expect(throws: LowtideError.self) {
            try await RecipeCollector.withTimeout(.milliseconds(50)) {
                try await Task.sleep(for: .seconds(5))
                return 1
            }
        }
        let quick = try? await RecipeCollector.withTimeout(.seconds(5)) { 7 }
        #expect(quick == 7)
    }
}
