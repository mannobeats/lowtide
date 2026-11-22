import Foundation
import Testing
@testable import LowtideKit

/// Matching, ranking and the lists the bar shows (rank.ts, bar-results.ts).
@Suite struct CommandBarRankingTests {
    func row(_ id: String, _ title: String, source: BarSource = .lowtide, keywords: [String] = [], group: String? = nil,
             counts: Bool = true, number: ClosedRange<Int>? = nil) -> BarRow {
        var row = BarRow(id: id, source: source, title: title, keywords: keywords, icon: .glyph("home")) { _ in }
        row.group = group
        row.counts = counts
        row.number = number
        return row.indexed()
    }

    func ids(_ results: BarResults) -> [String] { results.rows.map(\.id) }

    @Test func foldsCaseAccentsWidthAndSpaces() {
        #expect(Ranking.fold("  Café   CRÈME ") == "cafe creme")
        #expect(Ranking.fold("ＡＢＣ") == "abc")
        #expect(Ranking.fold("soft\u{AD}hyphen") == "softhyphen")
    }

    @Test func everyWordMustMatch() {
        let c = Ranking.Candidate(title: "Network live", keywords: ["connections map"])
        #expect(Ranking.textMatch("net live", c) != nil)
        #expect(Ranking.textMatch("net nope", c) == nil)
        #expect(Ranking.textMatch("network live", c)?.tier == 5)
        #expect(Ranking.textMatch("netw", c)?.tier == 4)
        #expect(Ranking.textMatch("live", c)?.tier == 3)
        #expect(Ranking.textMatch("connections map", c)?.tier == 2)
        #expect(Ranking.textMatch("map live", c)?.tier == 1)
    }

    @Test func toleratesOneTypoInLongerWords() {
        let c = Ranking.Candidate(title: "Terminal", keywords: [])
        #expect(Ranking.textMatch("termnal", c) != nil)  // a letter dropped
        #expect(Ranking.textMatch("temrinal", c) != nil)  // neighbours swapped
        #expect(Ranking.textMatch("trml", c) != nil)  // letters in order
        #expect(Ranking.textMatch("tx", c) == nil)  // too short for fuzzy
        #expect(Ranking.textMatch("123", Ranking.Candidate(title: "PID 1234", keywords: [])) != nil)
        #expect(Ranking.textMatch("124", Ranking.Candidate(title: "PID 1234", keywords: [])) == nil)
    }

    @Test func frecencyFavoursRecentUse() {
        let now = Date()
        let recent = BarUsage(count: 3, lastUsed: now.addingTimeInterval(-60))
        let old = BarUsage(count: 3, lastUsed: now.addingTimeInterval(-30 * 86_400))
        #expect(Ranking.usageBoost(recent, now: now) == 36)
        #expect(Ranking.usageBoost(old, now: now) == 6)
        #expect(Ranking.usageBoost(BarUsage(count: 999, lastUsed: now), now: now) == 480)
        #expect(Ranking.usageBoost(nil) == 0)
    }

    @Test func aliasesWinOutright() {
        #expect(Ranking.aliasHit("gh", "gh github") == 2400)
        #expect(Ranking.aliasHit("git", "github") == 1100)
        #expect(Ranking.aliasHit("x", nil) == 0)
        var prefs = BarPrefs()
        prefs.aliases["b"] = "zz"
        let search = BarSearch(prefs: prefs)
        let results = search.search("zz", poolsOf([row("a", "Zz top"), row("b", "Something else")]))
        #expect(ids(results).first == "b")
    }

    @Test func habitsLearnWhatFollowsATypedPrefix() {
        var habits = BarHabits()
        habits.learn("ter", id: "app.terminal")
        habits.learn("ter", id: "app.terminal")
        let (boost, exact) = habits.boost("ter", id: "app.terminal")
        #expect(exact && boost > 0)
        // A longer query still gets the boost, but no longer outranks better matches.
        #expect(habits.boost("term", id: "app.terminal").exact == false)
        #expect(habits.boost("term", id: "app.terminal").boost > 0)
        #expect(habits.boost("ter", id: "other").boost == 0)
        let pools = poolsOf([row("lowtide.sessions", "Terminal sessions"), row("app.terminal", "Terminal", source: .apps)])
        let ranked = BarSearch(prefs: BarPrefs(), habits: habits).search("ter", pools)
        #expect(ids(ranked).first == "app.terminal")
        habits.forget()
        #expect(habits.boost("ter", id: "app.terminal").boost == 0)
    }

    @Test func highlightsWordStartsFirst() {
        #expect(Ranking.highlights("Restart the Mac", "start") == [2..<7])
        #expect(Ranking.highlights("Show hidden files", "hid fi") == [5..<8, 12..<14])
        #expect(Ranking.highlights("Mac start", "start") == [4..<9])
        #expect(Ranking.highlights("Abc", "") == [])
    }

    func poolsOf(_ catalog: [BarRow], emoji: [BarRow] = [], quit: [BarRow] = []) -> BarPools {
        var pools = BarPools()
        pools.catalog = catalog
        pools.emoji = emoji
        pools.quit = quit
        return pools
    }

    @Test func emptyBarShowsQuickAccessThenSuggestionsThenGroups() {
        var prefs = BarPrefs()
        prefs.pins = ["lowtide.page:apps/updates", "emoji.🔥", "gone"]
        let catalog = [
            row("lowtide.ask", "Ask", group: "Lowtide"),
            row("lowtide.page:apps/updates", "Updates", group: "Lowtide · Apps"),
            row("action.darkMode", "Switch to dark", source: .system, group: "System"),
            row("action.sleep", "Sleep", source: .system, group: "System"),
        ]
        let fire = row("emoji.🔥", "fire", source: .emoji)
        let results = BarSearch(prefs: prefs).results("", category: nil, pools: poolsOf(catalog, emoji: [fire]))
        #expect(ids(results) == ["lowtide.page:apps/updates", "emoji.🔥", "lowtide.ask", "action.darkMode", "action.sleep"])
        #expect(results.headings == [0: "Quick access", 2: "Suggestions", 4: "System"])
        #expect(results.quickCount == 2)
    }

    @Test func mostUsedComesBeforeSuggestions() {
        var prefs = BarPrefs()
        prefs.pins = []
        prefs.record("action.sleep")
        let catalog = [row("lowtide.ask", "Ask"), row("action.sleep", "Sleep", source: .system)]
        let results = BarSearch(prefs: prefs).results(" ", category: nil, pools: poolsOf(catalog))
        #expect(ids(results) == ["action.sleep", "lowtide.ask"])
        #expect(results.headings == [0: "Most used", 1: "Suggestions"])
        #expect(results.quickCount == 0)
    }

    @Test func hiddenAndSwitchedOffRowsStayOut() {
        var prefs = BarPrefs()
        prefs.hidden = ["a"]
        prefs.disabled = [.system]
        let pools = poolsOf([row("a", "Alpha"), row("b", "Alpha two", source: .system), row("c", "Alpha three")])
        #expect(ids(BarSearch(prefs: prefs).search("alpha", pools)) == ["c"])
    }

    @Test func capsEachSourceAndTheWholeList() {
        let apps = (0..<9).map { row("app.\($0)", "Test app \($0)", source: .apps) }
        let pages = (0..<9).map { row("page.\($0)", "Test page \($0)") }
        #expect(BarSearch(prefs: BarPrefs()).search("test", poolsOf(apps)).rows.count == 5)
        let mixed = BarSearch(prefs: BarPrefs()).search("test", poolsOf(apps + pages + pages.map { row("more." + $0.id, $0.title) }))
        #expect(mixed.rows.count == 12)
        #expect(mixed.rows.allSatisfy { $0.source == .lowtide })
    }

    @Test func quitRowsOnlyWhenAskedFor() {
        let quit = [row("quit.safari", "Quit Safari", source: .quit, keywords: ["quit", "close"])]
        let pools = poolsOf([row("app.safari", "Safari", source: .apps)], quit: quit)
        #expect(ids(BarSearch(prefs: BarPrefs()).search("safari", pools)) == ["app.safari"])
        #expect(ids(BarSearch(prefs: BarPrefs()).search("qu safari", pools)) == ["quit.safari"])
    }

    @Test func macFactsNeedThreeLettersOfTheirTitle() {
        let facts = [row("answer.battery", "Battery", source: .answers, keywords: ["answer"])]
        #expect(ids(BarSearch(prefs: BarPrefs()).search("ba", poolsOf(facts))).isEmpty)
        #expect(ids(BarSearch(prefs: BarPrefs()).search("bat", poolsOf(facts))) == ["answer.battery"])
    }

    @Test func answersLeadAndAColourPreviewYieldsToAnExactRow() {
        var pools = poolsOf([row("x", "#1234 notes")])
        pools.answer = row("answer.colorPreview", "#1234", source: .calculator)
        let results = BarSearch(prefs: BarPrefs()).search("#1234", pools)
        #expect(ids(results) == ["x", "answer.colorPreview"])
        var math = poolsOf([row("y", "2 apps")])
        math.answer = row("answer.math", "4", source: .calculator)
        #expect(ids(BarSearch(prefs: BarPrefs()).search("2+2", math)).first == "answer.math")
    }

    @Test func emojiSearchWithAColon() {
        let emoji = [row("emoji.🔥", "fire", source: .emoji), row("emoji.🚒", "fire engine", source: .emoji),
                     row("emoji.😂", "face with tears of joy", source: .emoji, keywords: ["lol"])]
        let pools = poolsOf([row("lowtide.fire", "Firewall")], emoji: emoji)
        #expect(ids(BarSearch(prefs: BarPrefs()).search(":fire", pools)) == ["emoji.🔥", "emoji.🚒"])
        #expect(ids(BarSearch(prefs: BarPrefs()).search(":lol", pools)) == ["emoji.😂"])
    }

    @Test func pinnedTitleMatchesBeatOtherExactNames() {
        var prefs = BarPrefs()
        prefs.pins = ["lowtide.newTerminal"]
        let pools = poolsOf([row("app.terminal", "Terminal", source: .apps), row("lowtide.newTerminal", "New terminal")])
        #expect(ids(BarSearch(prefs: prefs).search("terminal", pools)).first == "lowtide.newTerminal")
        prefs.pins = []
        #expect(ids(BarSearch(prefs: prefs).search("terminal", pools)).first == "app.terminal")
    }

    @Test func categoryListsBrowseByPinThenUse() {
        var prefs = BarPrefs()
        prefs.pins = ["c"]
        prefs.record("b")
        let rows = [row("a", "Alpha"), row("b", "Beta"), row("c", "Gamma")]
        let browse = BarSearch(prefs: prefs).results("", category: ("Things", rows), pools: BarPools())
        #expect(ids(browse) == ["c", "b", "a"])
        #expect(browse.headings == [0: "Things · 3"])
        let typed = BarSearch(prefs: prefs).results("alp", category: ("Things", rows), pools: BarPools())
        #expect(ids(typed) == ["a"])
        #expect(typed.headings == [0: "Things · 1"])
    }

    @Test func trailingNumbersGoToNumberRows() {
        let rows = [row("action.volume", "Volume", source: .system, keywords: ["sound"], number: 0...100), row("x", "Volumes")]
        #expect(BarSearch.splitNumber("volume 40", rows: rows) == ("volume", 40))
        #expect(BarSearch.splitNumber("volume 40%", rows: rows) == ("volume", 40))
        #expect(BarSearch.splitNumber("iphone 15", rows: rows) == ("iphone 15", nil))
        #expect(BarSearch.splitNumber("40", rows: rows) == ("40", nil))
    }

    @Test func prefsRecordPinNameHideAndForget() {
        var prefs = BarPrefs()
        prefs.pins = []
        for i in 0..<205 { prefs.record("row\(i)", now: Date(timeIntervalSince1970: Double(i))) }
        #expect(prefs.usage.count == 200)
        #expect(prefs.usage["row0"] == nil && prefs.usage["row204"] != nil)
        prefs.forget("row204")
        #expect(prefs.usage["row204"] == nil)
        prefs.forget()
        #expect(prefs.usage.isEmpty)

        prefs.togglePin("a")
        prefs.togglePin("b")
        prefs.movePin("b", by: -1)
        #expect(prefs.pins == ["b", "a"])
        prefs.movePin("b", by: -1)
        #expect(prefs.pins == ["b", "a"])
        prefs.togglePin("b")
        #expect(prefs.pins == ["a"])
        for i in 0..<40 { prefs.togglePin("p\(i)") }
        #expect(prefs.pins.count == 30 && prefs.pins.last == "p39")

        prefs.setAlias("a", "  gh  ")
        #expect(prefs.aliases["a"] == "gh")
        #expect(prefs.aliasClash(key: "b", alias: "my gh") == "a")
        #expect(prefs.aliasClash(key: "a", alias: "gh") == nil)
        prefs.setAlias("a", "")
        #expect(prefs.aliases["a"] == nil)

        prefs.toggleHidden("x")
        #expect(prefs.hidden == ["x"])
        prefs.toggle(.emoji)
        #expect(!prefs.isOn(.emoji))
        prefs.addColor("#111111")
        prefs.addColor("#222222")
        prefs.addColor("#111111")
        #expect(prefs.colors == ["#111111", "#222222"])
    }

    @Test func prefsReadOlderFiles() throws {
        let json = #"{"glass": 60, "pins": ["a"], "disabled": ["emoji", "windows"]}"#
        let prefs = try JSONDecoder().decode(BarPrefs.self, from: Data(json.utf8))
        #expect(prefs.glass == 60 && prefs.pins == ["a"] && prefs.hotkey == .defaultBar)
        // An unknown source in an old file drops the whole list rather than failing.
        #expect(prefs.disabled.isEmpty)
        let round = try JSONDecoder().decode(BarPrefs.self, from: JSONEncoder().encode(prefs))
        #expect(round == prefs)
    }

    @Test func linksTakeWhatFollowsTheirName() {
        let gh = BarLink(kind: .link, name: "gh", destination: "github.com/search?q={query}")
        #expect(gh.argument(in: "gh swift testing") == "swift testing")
        #expect(gh.argument(in: "GH") == "")
        #expect(gh.argument(in: "ghost") == nil)
        #expect(gh.needsArgument)
        #expect(gh.expanded("a&b c") == "https://github.com/search?q=a%26b%20c")
        let mail = BarLink(kind: .link, name: "mail", destination: "mailto:me@example.com")
        #expect(mail.expanded("") == "mailto:me@example.com")
        let docs = BarLink(kind: .place, name: "docs", destination: "~/Documents")
        #expect(docs.expanded("") == Paths.home.path + "/Documents")
        #expect(!docs.needsArgument)
        let script = BarLink(kind: .script, name: "up", destination: "/bin/echo", runsWithoutArgument: true)
        #expect(!script.needsArgument)
    }

    /// A loose match prefers the precise title: "pkts" opens Packets, not
    /// "Capture packets".
    @Test func looseMatchPrefersTheShorterTitle() {
        let page = Ranking.textMatch("pkts", Ranking.Candidate(title: "Packets", keywords: []))
        let action = Ranking.textMatch("pkts", Ranking.Candidate(title: "Capture packets", keywords: []))
        #expect(page != nil && action != nil)
        #expect(page!.score > action!.score)
    }
}
