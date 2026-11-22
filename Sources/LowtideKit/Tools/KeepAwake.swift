import Foundation
import IOKit.pwr_mgt

/// Keep awake: an IOKit power assertion held by this process. macOS drops it
/// by itself if the app quits, so nothing can be left keeping the Mac up.
@MainActor
public final class KeepAwake {
    public static let shared = KeepAwake()

    public struct State: Sendable, Equatable {
        public var on: Bool
        /// Keeps the screen on too (not just the Mac).
        public var display: Bool
        /// When it ends; nil for "until I turn it off".
        public var until: Date?
    }

    private var assertion: IOPMAssertionID?
    private var timer: Task<Void, Never>?
    public private(set) var state = State(on: false, display: false, until: nil)

    /// Starts (or replaces) keeping awake, for `minutes` or until turned off.
    /// With `display`, the screen stays lit too.
    public func start(minutes: Int? = nil, display: Bool = false) throws {
        var id: IOPMAssertionID = 0
        let kind = (display ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep) as CFString
        guard IOPMAssertionCreateWithName(kind, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                          "Lowtide keeps this Mac awake" as CFString, &id) == kIOReturnSuccess
        else { throw LowtideError.denied("macOS refused to keep the Mac awake.") }
        releaseAssertion()
        assertion = id
        let until = minutes.map { Date.now.addingTimeInterval(Double($0) * 60) }
        state = State(on: true, display: display, until: until)
        if let minutes {
            timer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(minutes * 60))
                // Only the run that set this timer may end it.
                guard !Task.isCancelled else { return }
                self?.stop()
            }
        }
        Tools.changed()
    }

    public func stop() {
        releaseAssertion()
        state = State(on: false, display: false, until: nil)
        Tools.changed()
    }

    private func releaseAssertion() {
        timer?.cancel()
        timer = nil
        if let assertion { IOPMAssertionRelease(assertion) }
        assertion = nil
    }
}
