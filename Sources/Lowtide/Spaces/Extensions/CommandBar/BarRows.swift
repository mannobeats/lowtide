import LowtideKit
import SwiftUI

/// The rows each source gives the bar. Rows only describe; running one goes through the model,
/// which hides the bar, counts the use and shows errors.
enum BarRows {
    /// Puts the bar away first, so the next app gets the screen and focus.
    static func hideFirst(_ model: CommandBarModel, _ work: @escaping @MainActor (Int?) async throws -> Void)
        -> @MainActor (Int?) async throws -> Void {
        { arg in
            model.hide()
            try await work(arg)
        }
    }

    // MARK: Extensions

    /// Each bar extension as a row, like an app: running it opens its view.
    static func extensions(_ model: CommandBarModel) -> [BarRow] {
        BarExtension.catalog.filter(\.opens).map { ext in
            var row = BarRow(id: "ext.\(ext.id.rawValue)", source: ext.id, title: ext.name, subtitle: ext.description,
                             keywords: [ext.keywords, "extension"], icon: .symbol(ext.symbol)) { _ in
                model.setCategory(.source(ext.id))
            }
            row.counts = true
            row.group = "Extensions"
            row.keepsOpen = true
            row.kind = "Extension"
            return row
        }
    }

    // MARK: Lowtide

    static func lowtide(_ model: CommandBarModel, query: String, hosts: [CommandBarHooks.Host]) -> [BarRow] {
        var rows: [BarRow] = []
        var ask = BarRow(id: "lowtide.ask", source: .lowtide, title: "Ask about this Mac", subtitle: "Answered on this Mac by Apple Intelligence",
                         keywords: ["question ai assistant apple intelligence ask the floor", "lowtide"], icon: .glyph("ask")) { _ in
            model.enterAsk(nil)
        }
        ask.counts = true
        ask.group = "Lowtide"
        ask.keepsOpen = true
        ask.shortcut = "⌘J"
        rows.append(ask)

        let question = query.trimmingCharacters(in: .whitespaces)
        if question.count >= 3, question.contains(" ") || question.hasSuffix("?") {
            var asking = BarRow(id: "lowtide.ask.query", source: .lowtide, title: "Ask “\(question)”",
                                subtitle: "Answered on this Mac by Apple Intelligence", keywords: [question], icon: .glyph("ask")) { _ in
                model.enterAsk(question)
            }
            asking.keepsOpen = true
            asking.kind = "Ask"
            rows.append(asking)
        }

        // The bar's own Ask row and the bar itself aren't actions inside it.
        for action in ActionRegistry.all where action.id != "ask" && action.id != "commandbar.open" {
            var row = BarRow(id: "lowtide.action:\(action.id)", source: .lowtide, title: action.title, subtitle: action.subtitle,
                             keywords: [action.keywords, "lowtide"], icon: action.glyph.map(BarIcon.glyph) ?? .symbol(action.symbol)) { _ in
                model.hide()
                if model.host == .panel, action.opensWindow { WindowRouter.showMain() }
                action.run()
            }
            row.opensWindow = action.opensWindow
            row.counts = true
            row.group = "Lowtide"
            rows.append(row)
        }
        // Each saved host connects straight away, in a terminal tab.
        for host in hosts {
            var row = BarRow(id: "lowtide.ssh:\(host.id)", source: .lowtide, title: host.name, subtitle: host.address,
                             keywords: ["ssh connect server", host.address], icon: .glyph("hosts")) { _ in
                model.hide()
                WindowRouter.showMain()
                host.connect()
            }
            row.opensWindow = true
            row.counts = true
            row.group = "Lowtide · Hosts"
            row.kind = "SSH"
            rows.append(row)
        }
        for page in Page.allCases {
            let space = page.space.title
            var row = BarRow(id: "lowtide.page:\(page.rawValue)", source: .lowtide, title: page.title,
                             subtitle: space == page.title || page.space == .home ? nil : space,
                             keywords: [page.keywords, space, "lowtide"], icon: .glyph(page.glyph)) { _ in
                model.hide()
                AppModel.shared.show(page)
            }
            row.opensWindow = true
            row.counts = true
            row.group = page.space == .home ? "Lowtide" : "Lowtide · \(space)"
            rows.append(row)
        }
        return rows
    }

    // MARK: Answers about this Mac and its network

    static func facts(_ facts: MacFacts?, watch: CommandBarHooks.WatchFacts?) -> [BarRow] {
        var rows: [BarRow] = []
        func answer(_ id: String, _ title: String, _ subtitle: String, _ value: String, _ symbol: String, copy: String? = nil) {
            let text = copy ?? value
            var row = BarRow(id: "answer.\(id)", source: .answers, title: title, subtitle: subtitle, keywords: ["answer"],
                             icon: .symbol(symbol)) { _ in Opener.copy(text) }
            row.copy = text
            row.group = "Answers"
            row.value = value
            rows.append(row)
        }
        if let watch {
            let rates = "↓ \(LowtideKitFormat.rate(watch.rateIn))   ↑ \(LowtideKitFormat.rate(watch.rateOut))"
            answer("network", "Network now", rates, "↓ \(LowtideKitFormat.rate(watch.rateIn))", "arrow.up.arrow.down",
                   copy: "↓ \(LowtideKitFormat.rate(watch.rateIn)) ↑ \(LowtideKitFormat.rate(watch.rateOut))")
            answer("traffic", "Traffic today", "↓ \(LowtideKitFormat.bytes(watch.todayIn))   ↑ \(LowtideKitFormat.bytes(watch.todayOut))",
                   LowtideKitFormat.bytes(watch.todayIn + watch.todayOut), "chart.bar")
            answer("alerts", "Alerts", watch.lastAlert ?? "Nothing in the last 24 hours", "\(watch.alerts)", "bell",
                   copy: watch.lastAlert ?? "No alerts")
        }
        if let battery = facts?.battery {
            let state = battery.charging ? "Charging" : battery.onPower ? "On power" : "Battery"
            answer("battery", "Battery", state, "\(battery.percent)%", battery.charging ? "battery.100.bolt" : "battery.75")
        }
        if let facts {
            let used = LowtideKitFormat.bytes(Int64(facts.memoryUsed)), total = LowtideKitFormat.bytes(Int64(facts.memoryTotal))
            answer("memory", "Memory", "\(used) of \(total) in use",
                   LowtideKitFormat.percent(Double(facts.memoryUsed) / Double(max(1, facts.memoryTotal))), "memorychip", copy: "\(used) / \(total)")
            let free = LowtideKitFormat.bytes(facts.storageAvailable)
            answer("storage", "Storage", "\(free) available of \(LowtideKitFormat.bytes(facts.storageTotal))",
                   LowtideKitFormat.percent(Double(facts.storageAvailable) / Double(max(1, facts.storageTotal))), "internaldrive", copy: free)
        }
        let now = Date()
        answer("date", "Today", now.formatted(date: .complete, time: .omitted), now.formatted(.dateTime.day().month(.abbreviated)),
               "calendar", copy: now.formatted(date: .numeric, time: .omitted))
        answer("time", "Time now", now.formatted(date: .omitted, time: .standard), now.formatted(date: .omitted, time: .shortened), "clock")
        return rows
    }

    /// The inline result for the typed text: sum, conversion, colour or date.
    static func answer(_ answer: BarAnswer) -> BarRow {
        let icon: BarIcon = answer.swatch.map(BarIcon.swatch) ?? .symbol(answer.kind == .date ? "calendar" : "equal")
        var row = BarRow(id: "answer.\(answer.kind.rawValue)", source: .calculator, title: answer.title, subtitle: answer.subtitle,
                         icon: icon) { _ in Opener.copy(answer.copy) }
        row.answer = true
        row.copy = answer.copy
        row.reuse = answer.reuse
        return row
    }

    static func url(_ url: String, _ model: CommandBarModel) -> BarRow {
        BarRow(id: "action.openURL", source: .links, title: url.replacingOccurrences(of: "https://", with: ""),
               subtitle: "Open in browser", icon: .symbol("arrow.up.forward.square"), run: hideFirst(model) { _ in try await Opener.open(url) })
    }

    static func scriptAnswer(_ output: String) -> BarRow {
        var row = BarRow(id: "script.answer", source: .links, title: output, subtitle: "Return copies",
                         icon: .symbol("terminal")) { _ in Opener.copy(output) }
        row.answer = true
        row.copy = output
        return row
    }

    // MARK: Apps

    static func apps(_ apps: [LaunchableApp], running: [RunningApp], _ model: CommandBarModel) -> [BarRow] {
        var live: [String: RunningApp] = [:]
        for app in running {
            if let id = app.bundleID { live[id] = app }
            if let path = app.path { live[path] = app }
        }
        return apps.map { app in
            let open = live[app.bundleID] ?? live[app.path]
            var row = BarRow(id: "app.\(app.path)", stableKey: app.bundleID == app.path ? "app.\(app.path)" : "app.bundle.\(app.bundleID)",
                             source: .apps, title: app.name, subtitle: "Application",
                             keywords: app.fileName == app.name ? [] : [app.fileName], icon: .file(app.path),
                             run: hideFirst(model) { _ in try await Opener.open(app.path) })
            row.active = open != nil
            row.counts = true
            row.path = app.path
            if let open {
                row.actions += [
                    BarRowAction(id: "quit", title: "Quit \(app.name)", symbol: "stop") { try await RunningApps.quit(open.pid, force: false) },
                    BarRowAction(id: "restart", title: "Restart \(app.name)", symbol: "arrow.clockwise.circle") {
                        try await RunningApps.restart(open.pid)
                    },
                    BarRowAction(id: "force", title: "Force Quit \(app.name)…", symbol: "xmark.octagon",
                                 confirm: "Force quit \(app.name)? Unsaved work is lost.", destructive: true) {
                        try await RunningApps.quit(open.pid, force: true)
                    },
                ]
            }
            row.actions += [
                BarRowAction(id: "network", title: "See its network traffic in Lowtide", symbol: "network") { AppModel.shared.show(.networkLive) },
                BarRowAction(id: "permissions", title: "See its permissions in Lowtide", symbol: "lock") { AppModel.shared.show(.permissions) },
            ]
            return row
        }
    }

    static func quit(_ running: [RunningApp], _ model: CommandBarModel) -> [BarRow] {
        running.map { app in
            let key = "quit.\(app.bundleID ?? "\(app.pid)")"
            var row = BarRow(id: key, source: .quit, title: "Quit \(app.name)", subtitle: "Quit", keywords: ["quit", "close"],
                             icon: app.path.map(BarIcon.file) ?? .symbol("macwindow"),
                             run: hideFirst(model) { _ in try await RunningApps.quit(app.pid, force: false) })
            row.confirm = "Quit \(app.name)?"
            row.counts = app.bundleID != nil
            return row
        }
    }

    // MARK: System Settings, folders, files

    static func panes(_ panes: [SettingsPane], _ model: CommandBarModel) -> [BarRow] {
        panes.map { pane in
            var row = BarRow(id: "macsettings.\(pane.id)", source: .macSettings, title: pane.name, subtitle: "System Settings",
                             keywords: pane.keywords + ["settings", "system settings"], icon: .symbol("gearshape"),
                             run: hideFirst(model) { _ in try await Opener.open("x-apple.systempreferences:\(pane.id)") })
            row.counts = true
            row.group = "System Settings"
            return row
        }
    }

    static func reveal(_ path: String) -> BarRowAction {
        BarRowAction(id: "reveal", title: "Show in Finder", symbol: "folder") { try Opener.reveal(path) }
    }

    static func folders(_ folders: [StandardFolders.Folder], _ model: CommandBarModel) -> [BarRow] {
        folders.map { folder in
            var row = BarRow(id: "folder.\(folder.path)", source: .folders, title: folder.name, subtitle: "Folder", keywords: ["folder"],
                             icon: .file(folder.path), run: hideFirst(model) { _ in try await Opener.open(folder.path) })
            row.actions = [reveal(folder.path)]
            row.counts = true
            row.group = "Folders"
            row.path = folder.path
            return row
        }
    }

    static func files(_ hits: [FileSearch.Hit], _ model: CommandBarModel) -> [BarRow] {
        hits.map { hit in
            var row = BarRow(id: "file.\(hit.path)", source: .files, title: hit.name, subtitle: hit.parent, icon: .file(hit.path),
                             run: hideFirst(model) { _ in try await Opener.open(hit.path) })
            row.actions = [reveal(hit.path)]
            row.path = hit.path
            return row
        }
    }

    // MARK: System controls

    static func system(_ facts: MacFacts?, _ model: CommandBarModel) -> [BarRow] {
        struct Control {
            var action: SystemAction, title: String, symbol: String, keywords: String
            var confirm: String? = nil, number: ClosedRange<Int>? = nil, active = false
        }
        let dark = facts?.darkMode ?? false, muted = facts?.muted ?? false
        var list = [
            Control(action: .darkMode, title: dark ? "Switch to light" : "Switch to dark", symbol: dark ? "sun.max" : "moon",
                    keywords: "appearance theme dark light mode"),
            Control(action: .lockScreen, title: "Lock screen", symbol: "lock", keywords: "lock screen"),
            Control(action: .displayOff, title: "Turn the display off", symbol: "display", keywords: "display sleep screen off"),
            Control(action: .screenSaver, title: "Start the screen saver", symbol: "moon.stars", keywords: "screen saver"),
            Control(action: .ejectDisks, title: "Eject all disks", symbol: "eject", keywords: "eject unmount disks drives usb"),
            Control(action: .hiddenFiles, title: facts?.hiddenFiles == true ? "Hide hidden files" : "Show hidden files", symbol: "eye",
                    keywords: "finder show hidden files dotfiles"),
            Control(action: .desktopIcons, title: facts?.desktopIcons == false ? "Show desktop icons" : "Hide desktop icons",
                    symbol: "menubar.dock.rectangle", keywords: "finder desktop icons clean desktop"),
            Control(action: .emptyTrash, title: "Empty the Trash", symbol: "trash", keywords: "empty trash bin delete",
                    confirm: "Empty the Trash? This can't be undone."),
            Control(action: .volume, title: "Volume", symbol: "speaker.wave.2", keywords: "volume sound loudness", number: 0...100),
            Control(action: .soundMute, title: muted ? "Turn the sound back on" : "Mute the sound",
                    symbol: muted ? "speaker.wave.2" : "speaker.slash", keywords: "mute sound audio", active: muted),
            Control(action: .sleep, title: "Sleep", symbol: "zzz", keywords: "sleep suspend"),
            Control(action: .restart, title: "Restart", symbol: "arrow.clockwise", keywords: "restart reboot", confirm: "Restart the Mac?"),
            Control(action: .shutDown, title: "Shut down", symbol: "power", keywords: "shut down power off turn off",
                    confirm: "Shut down the Mac?"),
            Control(action: .logOut, title: "Log out", symbol: "rectangle.portrait.and.arrow.right", keywords: "log out sign out logout",
                    confirm: "Log out?"),
        ]
        if let wifi = facts?.wifi {
            list.append(Control(action: .wifi, title: wifi ? "Turn Wi-Fi off" : "Turn Wi-Fi on", symbol: "wifi",
                                keywords: "wifi wi-fi wireless internet", active: wifi))
        }
        return list.map { c in
            var row = BarRow(id: "action.\(c.action.rawValue)", source: .system, title: c.title, keywords: [c.keywords],
                             icon: .symbol(c.symbol), run: hideFirst(model) { arg in try await c.action.run(value: arg) })
            row.active = c.active
            row.confirm = c.confirm
            row.counts = true
            row.group = "System"
            row.number = c.number
            if let level = facts?.volume, c.action == .volume { row.value = "\(level)%" }
            return row
        }
    }

    // MARK: Emoji

    static func emoji(_ list: [Emoji], tone: SkinTone, _ model: CommandBarModel) -> [BarRow] {
        list.map { e in
            let char = e.toned(tone)
            var row = BarRow(id: "emoji.\(e.char)", source: .emoji, title: e.name, subtitle: "Copies it", keywords: e.keywords + ["emoji"],
                             icon: .emoji(char), run: hideFirst(model) { _ in Opener.copy(char) })
            row.copy = char
            row.counts = true
            if e.tones {
                row.actions = SkinTone.allCases.filter { $0 != tone }.map { other in
                    let variant = e.toned(other)
                    return BarRowAction(id: "tone.\(other.rawValue)", title: "Copy \(variant)", symbol: "face.smiling") {
                        model.hide()
                        Opener.copy(variant)
                    }
                }
            }
            return row.indexed()
        }
    }

    // MARK: Processes and dev servers

    static func processes(_ processes: [Processes.Info], listeners: [LocalServices.Listener], _ model: CommandBarModel) -> [BarRow] {
        let own = Set(processes.map(\.pid))
        let servers = listeners.filter { own.contains(pid_t($0.pid)) }.map { l in
            var row = BarRow(id: "kill.port.\(l.port)", source: .processes, title: l.process,
                             subtitle: "localhost:\(l.port)\(l.exposed ? " · reachable from the network" : "")",
                             keywords: [String(l.port), "port server localhost"], icon: .symbol("server.rack")) { _ in
                try Processes.kill(pid_t(l.pid), mode: .term)
                BarData.shared.wantProcesses()
            }
            row.confirm = "Stop \(l.process) on port \(l.port)?"
            row.actions = [
                BarRowAction(id: "browser", title: "Open in browser", symbol: "arrow.up.forward.square") {
                    model.hide()
                    try await Opener.open("http://localhost:\(l.port)")
                },
                BarRowAction(id: "force", title: "Force stop", symbol: "xmark.octagon", confirm: "Force stop \(l.process)?", destructive: true) {
                    try Processes.kill(pid_t(l.pid), mode: .kill)
                },
            ]
            return row
        }
        let procs = processes.map { p in
            let appPath = p.path.flatMap { path in path.range(of: ".app/").map { String(path[..<$0.lowerBound]) + ".app" } }
            var row = BarRow(id: "kill.\(p.pid)", source: .processes, title: p.name, subtitle: "PID \(p.pid)", keywords: [String(p.pid)],
                             icon: appPath.map(BarIcon.file) ?? .symbol("cpu")) { _ in
                try Processes.kill(p.pid, mode: .term)
                BarData.shared.wantProcesses()
            }
            row.confirm = "Kill \(p.name)?"
            row.actions = [
                BarRowAction(id: "kill", title: "Force kill", symbol: "xmark.octagon", confirm: "Force kill \(p.name)?", destructive: true) {
                    try Processes.kill(p.pid, mode: .kill)
                },
                BarRowAction(id: "all", title: "Kill all \(p.name)", symbol: "xmark.octagon", confirm: "Kill every \(p.name)?",
                             destructive: true) { try Processes.kill(p.pid, mode: .all) },
                BarRowAction(id: "tree", title: "Kill process tree", symbol: "xmark.octagon",
                             confirm: "Kill \(p.name) and everything it started?", destructive: true) { try Processes.kill(p.pid, mode: .tree) },
            ]
            return row
        }
        return servers + procs
    }

    // MARK: Your shortcuts

    static func links(_ links: [BarLink], query: String, _ model: CommandBarModel) -> [BarRow] {
        links.map { link in
            let arg = link.argument(in: query)
            let waiting = link.needsArgument && (arg ?? "").isEmpty
            let symbol = switch link.kind {
            case .link: "link"
            case .place: "folder"
            case .script: "terminal"
            }
            let subtitle = link.kind == .script
                ? (link.runsWithoutArgument ? "Runs on its own, or type what to send" : "Type what to send after the name")
                : (link.destination.contains("{query}") ? "Type what to look for after the name" : "Your shortcut")
            // Once something follows the name, the whole query matches the row.
            var row = BarRow(id: "link.\(link.id)", source: .links, title: link.name, subtitle: subtitle,
                             keywords: (arg ?? "").isEmpty ? [link.destination] : [query], icon: .symbol(symbol)) { _ in
                if waiting {
                    model.setQuery("\(link.name) ")
                } else if link.kind == .script {
                    let result = await UserScript.run(link.destination, argument: (arg ?? "").isEmpty ? nil : arg)
                    model.message = result.output.isEmpty ? "Done" : result.output
                } else {
                    model.hide()
                    try await Opener.open(link.expanded(arg ?? ""))
                }
            }
            row.counts = true
            row.group = "Your shortcuts"
            row.keepsOpen = waiting || link.kind == .script
            row.path = link.kind == .place ? link.expanded("") : nil
            return row
        }
    }

    // MARK: Tools

    static func tools(_ state: QuickControlsState?, _ model: CommandBarModel) -> [BarRow] {
        guard let state else { return [] }
        let controls = CommandBarHooks.quickControls
        func tool(_ id: String, _ source: BarSource, _ title: String, _ subtitle: String?, _ symbol: String, keywords: String,
                  run: @escaping @MainActor (Int?) async throws -> Void) -> BarRow {
            var row = BarRow(id: id, source: source, title: title, subtitle: subtitle, keywords: [keywords], icon: .symbol(symbol), run: run)
            row.counts = true
            row.group = "Tools"
            return row
        }
        var rows = [pick(model)]

        let awakeWords = "caffeine amphetamine awake insomnia no sleep stay"
        if state.awake.on {
            var off = tool("tools.awake.off", .awake, "Stop keeping awake", state.awake.display ? "Screen and Mac" : "Mac only",
                           "cup.and.saucer.fill", keywords: awakeWords, run: hideFirst(model) { _ in try await controls.stopKeepingAwake() })
            off.active = true
            off.value = state.awake.until.map { "until \($0.formatted(date: .omitted, time: .shortened))" } ?? "On"
            rows.append(off)
        } else {
            var on = tool("tools.awake", .awake, "Keep awake", "Until you turn it off", "cup.and.saucer", keywords: awakeWords,
                          run: hideFirst(model) { _ in try await controls.keepAwake(minutes: nil, display: true) })
            on.actions = [BarRowAction(id: "mac", title: "Keep only the Mac awake (the screen may sleep)", symbol: "cup.and.saucer") {
                model.hide()
                try await controls.keepAwake(minutes: nil, display: false)
            }]
            rows.append(on)
        }
        // "awake 90" keeps it up for 90 minutes.
        var awakeFor = tool("tools.awake.for", .awake, "Keep awake for…", "Type the minutes, like “awake 90”", "cup.and.saucer",
                            keywords: awakeWords, run: hideFirst(model) { minutes in try await controls.keepAwake(minutes: minutes ?? 60, display: true) })
        awakeFor.number = 1...1440
        rows.append(awakeFor)

        if let brightness = state.brightness {
            var row = tool("tools.brightness", .display, "Screen brightness", "Type a level, like “brightness 70”", "sun.max",
                           keywords: "brightness screen display dim light") { level in
                try await controls.setBrightness(Double(level ?? 100) / 100)
                BarData.shared.refreshQuick()
            }
            row.number = 0...100
            row.value = LowtideKitFormat.percent(brightness)
            rows.append(row)
        }
        if state.boostSupported != false {
            var row = tool("tools.boost", .display, "Extra brightness", "Beyond the maximum, on XDR screens", "sun.max.fill",
                           keywords: "extra brightness xdr hdr boost brighter outdoor sun nits",
                           run: hideFirst(model) { level in try await controls.setBoost(level ?? 100) })
            row.active = state.boostLevel > 0
            // "extra 60" still sets it in one go; Return alone opens the slider.
            row.number = 0...100
            row.slider = BarSlider(level: state.boostLevel) { level in try await controls.setBoost(level) }
            row.value = state.boostLevel > 0 ? "\(state.boostLevel)%" : "Off"
            rows.append(row)
        }

        var mic = tool("tools.mic", .sound, state.micMuted ? "Unmute the microphone" : "Mute the microphone", nil,
                       state.micMuted ? "mic.slash" : "mic", keywords: "microphone mic mute input call zoom",
                       run: hideFirst(model) { _ in _ = try await controls.toggleMicrophone() })
        mic.active = state.micMuted
        rows.append(mic)
        // One output is nothing to switch between.
        if state.outputs.count > 1 {
            for output in state.outputs {
                var row = tool("tools.output.\(output.name)", .sound, "Play sound through \(output.name)",
                               output.current ? "Playing here now" : "Sound output", "headphones",
                               keywords: "sound output speakers headphones airpods audio device",
                               run: hideFirst(model) { _ in try await controls.setOutput(output.id) })
                row.active = output.current
                row.group = nil
                rows.append(row)
            }
        }
        return rows
    }

    static func pick(_ model: CommandBarModel, title: String = "Pick a color") -> BarRow {
        var row = BarRow(id: "tools.pickColor", source: .colors, title: title, subtitle: "Click any pixel; its HEX is copied",
                         keywords: ["color colour picker eyedropper pipette sample hex screen"], icon: .symbol("eyedropper")) { _ in
            model.hide()
            // The picker copies the HEX as it's picked.
            if let hex = await CommandBarHooks.quickControls.pickColor() { model.picked(hex) }
        }
        row.counts = true
        row.group = "Tools"
        return row
    }

    /// The Colors view: the latest colour in every format, then the rest.
    static func colors(_ colors: [String], _ model: CommandBarModel) -> [BarRow] {
        guard let latest = colors.first, let swatch = Answers.parseColor(latest) else { return [pick(model)] }
        let formats = ColorFormats.all(latest).map { label, text in
            var row = BarRow(id: "colors.format.\(label)", source: .colors, title: text, subtitle: label, keywords: [label, "color"],
                             icon: .swatch(swatch), run: hideFirst(model) { _ in Opener.copy(text) })
            row.copy = text
            return row
        }
        let history = colors.dropFirst().map { hex in
            var row = BarRow(id: "colors.recent.\(hex)", source: .colors, title: hex, subtitle: "Picked earlier", keywords: ["color recent"],
                             icon: Answers.parseColor(hex).map(BarIcon.swatch) ?? .symbol("paintpalette"),
                             run: hideFirst(model) { _ in Opener.copy(hex) })
            row.copy = hex
            row.actions = ColorFormats.all(hex).dropFirst().map { label, text in
                BarRowAction(id: label, title: "Copy \(label): \(text)", symbol: "paintpalette") { Opener.copy(text) }
            }
            return row
        }
        return formats + history + [pick(model, title: "Pick another color")]
    }
}
