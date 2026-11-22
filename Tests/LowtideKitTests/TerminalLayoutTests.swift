import Foundation
import Testing
@testable import LowtideKit

@Suite struct TerminalLayoutTests {
    /// a | (b over c)
    var tree: PaneLayout {
        PaneLayout.leaf("a").splitting("a", axis: .row, with: "b").splitting("b", axis: .column, with: "c")
    }

    @Test func splitsAndListsLeavesInOrder() {
        #expect(tree.leaves == ["a", "b", "c"])
        #expect(tree.contains("c") && !tree.contains("x"))
        // Splitting a missing pane changes nothing.
        #expect(tree.splitting("x", axis: .row, with: "y") == tree)
    }

    @Test func findsNeighbours() {
        #expect(tree.neighbor(of: "a", .right) == "b")
        #expect(tree.neighbor(of: "c", .up) == "b")
        #expect(tree.neighbor(of: "b", .left) == "a")
        #expect(tree.neighbor(of: "c", .left) == "a")
        #expect(tree.neighbor(of: "a", .left) == nil)
        #expect(tree.neighbor(of: "b", .down) == "c")
    }

    @Test func placesPanes() {
        let rects = Dictionary(uniqueKeysWithValues: tree.rects().map { ($0.id, $0.rect) })
        #expect(rects["a"] == PaneLayout.Rect(x: 0, y: 0, w: 0.5, h: 1))
        #expect(rects["b"] == PaneLayout.Rect(x: 0.5, y: 0, w: 0.5, h: 0.5))
        #expect(rects["c"] == PaneLayout.Rect(x: 0.5, y: 0.5, w: 0.5, h: 0.5))
        let dividers = tree.dividers()
        #expect(dividers.map(\.path) == ["", "b"])
        #expect(dividers[1].axis == .column && dividers[1].rect == PaneLayout.Rect(x: 0.5, y: 0, w: 0.5, h: 1))
    }

    @Test func equalizesRunsOfTheSameDirection() {
        // a | b | c, built by splitting a twice: ratios 0.5 then 0.5 of the rest.
        let three = PaneLayout.leaf("a").splitting("a", axis: .row, with: "b").splitting("b", axis: .row, with: "c")
        let before = Dictionary(uniqueKeysWithValues: three.rects().map { ($0.id, $0.rect.w) })
        #expect(before["a"] == 0.5)
        let after = Dictionary(uniqueKeysWithValues: three.equalized().rects().map { ($0.id, $0.rect.w) })
        for id in ["a", "b", "c"] { #expect(abs((after[id] ?? 0) - 1.0 / 3) < 1e-9) }
        let mixed = Dictionary(uniqueKeysWithValues: tree.equalized().rects().map { ($0.id, $0.rect) })
        #expect(abs((mixed["c"]?.h ?? 0) - 0.5) < 1e-9)
    }

    @Test func removesAndSwaps() {
        #expect(tree.removing("b")?.leaves == ["a", "c"])
        #expect(PaneLayout.leaf("a").removing("a") == nil)
        #expect(tree.swapping("a", "c").leaves == ["c", "b", "a"])
    }

    @Test func clampsRatiosAndNudges() {
        let squeezed = tree.settingRatio(at: "", to: 0.01)
        #expect(squeezed.rects().first { $0.id == "a" }?.rect.w == 0.1)
        let nudged = Dictionary(uniqueKeysWithValues: tree.nudging("a", .right, by: 0.1).rects().map { ($0.id, $0.rect) })
        #expect(abs((nudged["a"]?.w ?? 0) - 0.6) < 1e-9)
        // c's top edge moves up: the column split above it.
        let taller = Dictionary(uniqueKeysWithValues: tree.nudging("c", .up, by: 0.1).rects().map { ($0.id, $0.rect) })
        #expect(abs((taller["c"]?.h ?? 0) - 0.6) < 1e-9)
        // No split runs that way: unchanged.
        #expect(PaneLayout.leaf("a").splitting("a", axis: .row, with: "b").nudging("a", .down, by: 0.1)
            == PaneLayout.leaf("a").splitting("a", axis: .row, with: "b"))
    }

    @Test func roundTripsThroughCodable() throws {
        let data = try JSONEncoder().encode(tree)
        #expect(try JSONDecoder().decode(PaneLayout.self, from: data) == tree)
    }
}

@Suite struct TerminalWorkspaceTests {
    func tab(_ id: String, pinned: Bool = false, oneShot: Bool = false) -> TerminalTab {
        TerminalTab(id: id, kind: .local, title: id.uppercased(), command: TabCommand(program: "/bin/zsh", args: ["-l"]),
                    oneShot: oneShot, pinned: pinned)
    }

    @Test func addsPinnedTabsBeforeUnpinnedOnes() {
        var w = TerminalWorkspace()
        w.add(tab("a"))
        w.add(tab("b"))
        w.add(tab("p", pinned: true))
        #expect(w.roots.map(\.id) == ["p", "a", "b"])
        #expect(w.activeID == "p")
        w.togglePin("b")
        #expect(w.roots.map(\.id) == ["p", "b", "a"])
    }

    @Test func closingPicksTheNextTab() {
        var w = TerminalWorkspace()
        for id in ["a", "b", "c"] { w.add(tab(id)) }
        w.activeID = "b"
        w.close("b")
        #expect(w.activeID == "c")
        w.close("c")
        #expect(w.activeID == "a")
        w.close("a")
        #expect(w.activeID == nil && w.tabs.isEmpty)
    }

    @Test func splitsFocusAndClosesPanes() {
        var w = TerminalWorkspace()
        w.add(tab("a"))
        let b = w.split("a", axis: .row, with: tab("b"))
        #expect(b == "b" && w.focusedPane == "b")
        #expect(w.roots.map(\.id) == ["a"] && w.panes(of: "a") == ["a", "b"])
        w.split("b", axis: .column, with: tab("c"))
        w.focus(.left)
        #expect(w.focusedPane == "a")
        // Closing a child pane leaves the tab where it was.
        w.closePane("c")
        #expect(w.panes(of: "a") == ["a", "b"])
        #expect(w.split("gone", axis: .row, with: tab("x")) == nil)
    }

    @Test func closingTheTabsOwnPanePromotesTheNext() {
        var w = TerminalWorkspace()
        w.add(tab("a", pinned: true))
        w.split("a", axis: .row, with: tab("b"))
        w.split("b", axis: .column, with: tab("c"))
        w.setFocus("c")
        w.closePane("a")
        #expect(w.roots.map(\.id) == ["b"])
        #expect(w.tab("b")?.pinned == true && w.tab("b")?.parent == nil)
        #expect(w.tab("c")?.parent == "b")
        #expect(w.activeID == "b" && w.panes(of: "b") == ["b", "c"])
        #expect(w.focusedPane == "c")
        w.closePane("c")
        #expect(w.layouts["b"] == nil && w.panes(of: "b") == ["b"])
        w.closePane("b")
        #expect(w.tabs.isEmpty)
    }

    @Test func zoomMoveAndResizeFollowFocus() {
        var w = TerminalWorkspace()
        w.add(tab("a"))
        w.split("a", axis: .row, with: tab("b"))
        w.toggleZoom("a")
        #expect(w.zoomedPane(in: "a") == "b")
        w.toggleZoom("a")
        #expect(w.zoomedPane(in: "a") == nil)
        w.move(.left)
        #expect(w.panes(of: "a") == ["b", "a"])
        w.resize(.left)
        let rects = Dictionary(uniqueKeysWithValues: w.layout(of: "a").rects().map { ($0.id, $0.rect.w) })
        #expect(abs((rects["b"] ?? 0) - 0.45) < 1e-9)
        w.equalize("a")
        #expect(abs((Dictionary(uniqueKeysWithValues: w.layout(of: "a").rects().map { ($0.id, $0.rect.w) })["b"] ?? 0) - 0.5) < 1e-9)
    }

    @Test func cyclesSelectsDuplicatesAndClosesOthers() {
        var w = TerminalWorkspace()
        for id in ["a", "b", "c"] { w.add(tab(id)) }
        w.add(tab("once", oneShot: true))
        w.cycle(1)
        #expect(w.activeID == "a")
        w.cycle(-1)
        #expect(w.activeID == "once")
        #expect(w.duplicate("once") == nil)
        w.select(index: 1)
        let copy = w.duplicate("b")
        #expect(copy != nil && w.roots.map(\.id)[2] == copy)
        w.togglePin("a")
        w.closeOthers("c")
        #expect(Set(w.roots.map(\.id)) == ["a", "c"])
    }

    @Test func movesTabsWithinTheirGroup() {
        var w = TerminalWorkspace()
        for id in ["a", "b", "c"] { w.add(tab(id)) }
        w.add(tab("p", pinned: true))
        w.split("a", axis: .row, with: tab("a2"))
        w.moveTab("a", to: "c")
        #expect(w.roots.map(\.id) == ["p", "b", "c", "a"])
        w.moveTab("a", to: "b")
        #expect(w.roots.map(\.id) == ["p", "a", "b", "c"])
        #expect(w.panes(of: "a") == ["a", "a2"])
        w.moveTab("c", to: "p")
        w.moveTab("a2", to: "c")
        #expect(w.roots.map(\.id) == ["p", "a", "b", "c"])
    }

    @Test func restoresOnlyPinnedTabsAsSinglePanes() {
        var w = TerminalWorkspace()
        w.add(tab("a", pinned: true))
        w.split("a", axis: .row, with: tab("b"))
        w.add(tab("c"))
        w.add(tab("run", oneShot: true))
        let saved = w.pinnedForRestore
        #expect(saved.map(\.id) == ["a"])
        var fresh = TerminalWorkspace()
        fresh.restore(saved)
        #expect(fresh.roots.map(\.id) == ["a"] && fresh.layouts.isEmpty && fresh.activeID == "a")
        let data = try? JSONEncoder().encode(saved)
        #expect(data.flatMap { try? JSONDecoder().decode([TerminalTab].self, from: $0) } == saved)
    }
}
