import Foundation

/// Small Mac tools the command bar, ⌘K and the widgets run: keep awake,
/// display brightness and extra XDR brightness, the screen colour picker,
/// and sound. None needs root or leaves anything running after the app quits.
public enum Tools {
    /// Posted (on the main queue) whenever a tool's state changes, so menus,
    /// the command bar and the widgets redraw.
    public static let changedNotification = Notification.Name("Lowtide.toolsChanged")

    static func changed() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: changedNotification, object: nil) }
    }

    /// Everything the command bar shows about the tools, in one read.
    public struct State: Sendable {
        public var awake: KeepAwake.State
        public var boost: XDRBoost.State
        /// 0–1; nil when the display's brightness can't be read.
        public var brightness: Double?
        public var volume: Double?
        public var muted: Bool?
        public var microphoneMuted: Bool
        public var outputs: [Sound.Output]
    }

    @MainActor
    public static func state() async -> State {
        async let mic = Sound.isMicrophoneMuted()
        let readings = await Task.detached { (Brightness.level, Sound.volume, Sound.isMuted, Sound.outputs()) }.value
        return State(awake: KeepAwake.shared.state, boost: XDRBoost.shared.state, brightness: readings.0,
                     volume: readings.1, muted: readings.2, microphoneMuted: await mic, outputs: readings.3)
    }
}
