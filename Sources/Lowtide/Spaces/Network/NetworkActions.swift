import LowtideKit
import SwiftUI

/// The Network space's actions for ⌘K, the command bar and menus.
enum NetworkActions {
    static var all: [AppAction] {
        let model = NetworkModel.shared
        let capturing = model.overview.capture.running
        return [
            AppAction(id: "network.capture", title: capturing ? "Stop Packet Capture" : "Capture Packets",
                      subtitle: capturing ? "Stop recording packets" : "Record DNS names, TLS server names and HTTP requests",
                      symbol: capturing ? "stop.circle" : "record.circle", glyph: "packets", keywords: "pcap wireshark sniff bpf",
                      space: .network) {
                Task { await model.toggleCapture() }
            },
            AppAction(id: "network.brief", title: "Brief Me on the Last Hour", subtitle: "Who used the network and what broke the pattern",
                      symbol: "moon.stars", glyph: "overnight", keywords: "report summary night shift away", space: .network) {
                OvernightPage.briefNow = true
                AppModel.shared.show(.overnight)
            },
            AppAction(id: "network.city", title: "Set This Mac's City",
                      subtitle: model.home.city.map { "Now \($0.name)" } ?? "Places this Mac on the map and judges server distances",
                      symbol: "mappin.and.ellipse", keywords: "home location map where", space: .network) {
                model.pendingTarget = .home
                AppModel.shared.show(.networkLive)
            },
            AppAction(id: "network.connections", title: "Show Connections", subtitle: "Every socket on this Mac",
                      symbol: "point.3.connected.trianglepath.dotted", glyph: "connections", keywords: "sockets lsof netstat", space: .network) {
                model.liveView = .connections
                AppModel.shared.show(.networkLive)
            },
            AppAction(id: "network.sound", title: model.ping ? "Mute Network Alert Sound" : "Play a Sound on Network Alerts",
                      symbol: model.ping ? "speaker.slash" : "speaker.wave.2", keywords: "beep ping audio", space: .network) {
                model.ping.toggle()
            },
        ]
    }
}
