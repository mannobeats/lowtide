import LowtideKit
import SwiftUI

/// The System space's actions for ⌘K, the command bar and menus: the quick
/// controls (keep awake, the colour picker, extra brightness, the mic).
enum SystemActions {
    static var all: [AppAction] {
        let awake = KeepAwake.shared.state.on
        var actions = [
            AppAction(id: "system.awake", title: awake ? "Stop Keeping the Mac Awake" : "Keep the Mac Awake",
                      subtitle: awake ? "Let it sleep as usual again" : "Until you turn it off; the screen may still dim",
                      symbol: awake ? "moon.zzz" : "cup.and.saucer", keywords: "caffeinate amphetamine sleep awake",
                      space: .system) {
                if awake {
                    KeepAwake.shared.stop()
                    Toasts.shared.show("The Mac can sleep again")
                } else {
                    do {
                        try KeepAwake.shared.start()
                        Toasts.shared.show("Keeping the Mac awake")
                    } catch {
                        Toasts.shared.failure("Couldn't keep the Mac awake", error)
                    }
                }
            },
            AppAction(id: "system.pick-colour", title: "Pick a Colour from the Screen",
                      subtitle: "Copies its hex code", symbol: "eyedropper", keywords: "color picker hex eyedropper",
                      space: .system) {
                Task {
                    if let picked = await ColorPicker.pick() { Toasts.shared.show("Copied \(picked.hex)") }
                }
            },
            AppAction(id: "system.microphone", title: "Mute or Unmute the Microphone", subtitle: "Puts its level back on unmute",
                      symbol: "mic.slash", keywords: "mic mute input", space: .system) {
                Task {
                    do {
                        let muted = try await Sound.toggleMicrophone()
                        Toasts.shared.show(muted ? "Microphone muted" : "Microphone on")
                    } catch {
                        Toasts.shared.failure("Couldn't change the microphone", error)
                    }
                }
            },
        ]
        if XDRBoost.shared.isAvailable {
            let on = XDRBoost.shared.state.level > 0
            actions.append(AppAction(id: "system.boost", title: on ? "Turn Extra Brightness Off" : "Turn Extra Brightness On",
                                     subtitle: "Brighter than the brightest setting, on this XDR display",
                                     symbol: "sun.max", keywords: "xdr hdr nits brightness boost", space: .system) {
                do {
                    try XDRBoost.shared.set(level: on ? 0 : 1)
                } catch {
                    Toasts.shared.failure("Couldn't change the brightness", error)
                }
            })
        }
        return actions
    }
}
