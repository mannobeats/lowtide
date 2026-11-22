import Foundation
import Testing
@testable import LowtideKit

@Suite struct SystemToolsTests {
    private let r600 = XDRBoostMath.Reference(edr: 2.66, bonus: 0.48)
    private let r500 = XDRBoostMath.Reference(edr: 3.2, bonus: 0.58)

    private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-4 }

    @Test func panelCurveFollowsTheGeneration() {
        #expect(XDRBoostMath.reference(model: "MacBookPro18,1") == r500)
        #expect(XDRBoostMath.reference(model: "Mac16,7") == r600)
        #expect(XDRBoostMath.reference(model: "Mac99,9") == r600)
        #expect(XDRBoostMath.reference(model: nil) == r600)
    }

    @Test func boostNeverPassesWhatThePanelSustains() {
        #expect(XDRBoostMath.boostFactor(level: 0, maxEDR: 2.66, reference: r600) == 1)
        #expect(near(XDRBoostMath.boostFactor(level: 1, maxEDR: 2.66, reference: r600), 1.48))
        #expect(near(XDRBoostMath.boostFactor(level: 1, maxEDR: 16, reference: r600), 1.48))
        #expect(near(XDRBoostMath.boostFactor(level: 1, maxEDR: 3.2, reference: r500), 1.58))
        #expect(near(XDRBoostMath.boostFactor(level: 1, maxEDR: 1.33, reference: r600), 1.24))
        #expect(near(XDRBoostMath.boostFactor(level: 0.5, maxEDR: 2.66, reference: r600), 1.24))
    }

    @Test func renderFactorFollowsTheGrant() {
        #expect(XDRBoostMath.renderFactor(level: 1, current: 1, potential: 16, reference: r600) == XDRBoostMath.engagementFactor)
        #expect(near(XDRBoostMath.renderFactor(level: 0.1, current: 1, potential: 16, reference: r600), 1.048))
        #expect(near(XDRBoostMath.renderFactor(level: 1, current: 2.66, potential: 16, reference: r600), 1.48))
        #expect(XDRBoostMath.renderFactor(level: 0, current: 2.66, potential: 16, reference: r600) == 1)
        #expect(near(XDRBoostMath.renderFactor(level: 1, current: 1.2, potential: 16, reference: r600), 1.2))
        #expect(XDRBoostMath.renderFactor(level: 1, current: 1, potential: 1, reference: r600) == 1)
    }

    @Test func onlyRealXDRPanelsQualify() {
        let name = "Built-in Retina Display"
        for model in ["MacBookPro18,1", "Mac14,10", "Mac15,3", "Mac16,1", "Mac17,9"] {
            #expect(XDRBoostMath.isSupportedPanel(model: model, name: name, potential: 2), "\(model)")
        }
        for model in ["Mac16,12", "Mac15,12", "Mac14,2", "MacBookPro17,1", "Mac16,2"] {
            #expect(!XDRBoostMath.isSupportedPanel(model: model, name: name, potential: 2), "\(model)")
        }
        #expect(XDRBoostMath.isSupportedPanel(model: "Mac99,1", name: name, potential: 16))
        #expect(!XDRBoostMath.isSupportedPanel(model: nil, name: name, potential: 1))
        #expect(XDRBoostMath.isSupportedPanel(model: nil, name: "Liquid Retina XDR Display", potential: 1))
        #expect(!XDRBoostMath.isSupportedPanel(model: nil, name: "Built-in Liquid Retina Display", potential: 1))
    }

    @Test func rampMovesInSmallSteps() {
        #expect(near(XDRBoostMath.ramped(1, toward: 1.48), 1.03))
        #expect(XDRBoostMath.ramped(1.46, toward: 1.48) == 1.48)
        #expect(near(XDRBoostMath.ramped(1.48, toward: 1.10), 1.385))
        #expect(XDRBoostMath.ramped(1.105, toward: 1.10) == 1.10)
        #expect(XDRBoostMath.ramped(1.48, toward: 1.48) == 1.48)
        var glide = 1.0
        for _ in 0..<16 { glide = XDRBoostMath.ramped(glide, toward: 1.48) }
        #expect(glide == 1.48)
    }

    @Test func graceRidesOutABlackoutButNotARevocation() {
        let grace = XDRBoostMath.dropoutGraceTicks
        #expect(XDRBoostMath.graced(1.10, previous: 1.48, engaged: false, disengagedTicks: 1) == 1.48)
        #expect(XDRBoostMath.graced(1.10, previous: 1.48, engaged: false, disengagedTicks: grace) == 1.48)
        #expect(XDRBoostMath.graced(1.10, previous: 1.48, engaged: false, disengagedTicks: grace + 1) == 1.10)
        #expect(XDRBoostMath.graced(1.40, previous: 1.48, engaged: true, disengagedTicks: 0) == 1.40)
        // A fullscreen-transition blackout leaves the boost untouched.
        var factor = 1.48, low = 0
        for engaged in [true, false, false, false, true, true] {
            low = engaged ? 0 : low + 1
            factor = XDRBoostMath.ramped(factor, toward: XDRBoostMath.graced(engaged ? 1.48 : 1.10, previous: factor,
                                                                             engaged: engaged, disengagedTicks: low))
            #expect(factor == 1.48)
        }
        // A real revocation ramps down over seconds, never one slam.
        factor = 1.48
        var biggest = 0.0
        for low in 1...12 {
            let next = XDRBoostMath.ramped(factor, toward: XDRBoostMath.graced(1.10, previous: factor, engaged: false,
                                                                               disengagedTicks: low))
            biggest = max(biggest, factor - next)
            factor = next
        }
        #expect((1.10..<1.13).contains(factor) && biggest < 0.0951)
    }

    @Test func spaceWindowsAreReusedOnlyWhenBothFollowed() {
        #expect(XDRBoostMath.canReuseSpaceWindows(sameDisplay: true, overlayOn: true, triggerOn: true))
        #expect(!XDRBoostMath.canReuseSpaceWindows(sameDisplay: false, overlayOn: true, triggerOn: true))
        #expect(!XDRBoostMath.canReuseSpaceWindows(sameDisplay: true, overlayOn: false, triggerOn: true))
        #expect(!XDRBoostMath.canReuseSpaceWindows(sameDisplay: true, overlayOn: true, triggerOn: false))
    }

    @Test @MainActor func pickedColoursFormatAsHex() {
        #expect(ColorPicker.Picked(r: 1, g: 0.5, b: 0).hex == "#FF8000")
        #expect(ColorPicker.Picked(r: -0.1, g: 1.2, b: 0.2).hex == "#00FF33")
    }

    @Test @MainActor func keepAwakeHoldsAndReleasesAnAssertion() async throws {
        let awake = KeepAwake.shared
        try awake.start(minutes: 5)
        #expect(awake.state.on && awake.state.until != nil)
        let held = try await Shell.run("/usr/bin/pmset", ["-g", "assertions"]).stdout
        #expect(held.contains("Lowtide keeps this Mac awake"))
        awake.stop()
        #expect(!awake.state.on)
        let after = try await Shell.run("/usr/bin/pmset", ["-g", "assertions"]).stdout
        #expect(!after.contains("Lowtide keeps this Mac awake"))
    }

    @Test func soundOutputsMarkTheCurrentOne() {
        let outputs = Sound.outputs()
        // A Mac with any output has exactly one current one.
        if !outputs.isEmpty { #expect(outputs.filter(\.isCurrent).count == 1) }
        if let volume = Sound.volume { #expect((0...1).contains(volume)) }
    }
}
