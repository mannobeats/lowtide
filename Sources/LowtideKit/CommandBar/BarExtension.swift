import Foundation

/// What the bar can do, as the person switches it on and off on the Command
/// bar page. The id is the `BarSource` its rows carry.
public struct BarExtension: Identifiable, Sendable {
    public enum Category: String, CaseIterable, Sendable { case core = "Core", mac = "Mac", tools = "Tools", lowtide = "Lowtide" }

    public var id: BarSource
    public var name: String
    public var description: String
    public var symbol: String
    public var category: Category
    /// Words that find it.
    public var keywords: String
    /// Has its own list in the bar, opened from its row.
    public var opens: Bool
    /// Can't be switched off.
    public var alwaysOn = false

    public static let catalog: [BarExtension] = [
        BarExtension(id: .apps, name: "Apps", description: "Open any app", symbol: "square.grid.2x2",
                     category: .core, keywords: "applications launch open", opens: true),
        BarExtension(id: .files, name: "Files", description: "Find files by name in folders you choose",
                     symbol: "doc.text.magnifyingglass", category: .core, keywords: "file search find documents folders ignore", opens: true),
        BarExtension(id: .folders, name: "Folders", description: "Home, Downloads, Documents and more", symbol: "folder",
                     category: .core, keywords: "folder finder places", opens: true),
        BarExtension(id: .links, name: "Your shortcuts", description: "Links, places and scripts you name", symbol: "link",
                     category: .core, keywords: "shortcuts links bookmarks scripts quicklinks", opens: true),
        BarExtension(id: .calculator, name: "Calculator", description: "Sums, units, colours, dates and time zones",
                     symbol: "plus.forwardslash.minus", category: .core,
                     keywords: "calculator math convert conversion units colour color date time zone", opens: false),
        BarExtension(id: .system, name: "System controls", description: "Dark mode, lock, sleep, volume, Wi-Fi",
                     symbol: "slider.horizontal.3", category: .mac,
                     keywords: "system controls commands dark lock sleep volume wifi trash", opens: true),
        BarExtension(id: .macSettings, name: "System Settings", description: "Open any System Settings pane", symbol: "gearshape",
                     category: .mac, keywords: "system settings preferences panes", opens: true),
        BarExtension(id: .quit, name: "Quit apps", description: "Quit running apps by name", symbol: "xmark.square",
                     category: .mac, keywords: "quit close running apps", opens: true),
        BarExtension(id: .processes, name: "Processes", description: "Stop a process or dev server", symbol: "cpu",
                     category: .mac, keywords: "processes kill stop port server localhost", opens: true),
        BarExtension(id: .answers, name: "Mac facts", description: "Battery, memory, storage, network, time", symbol: "laptopcomputer",
                     category: .mac, keywords: "mac facts battery memory storage network time date", opens: true),
        BarExtension(id: .colors, name: "Color picker", description: "Pick any pixel, copy it as HEX, RGB or OKLCH",
                     symbol: "eyedropper", category: .tools, keywords: "color colour picker eyedropper recent palette", opens: true),
        BarExtension(id: .awake, name: "Keep awake", description: "Stop the Mac from sleeping", symbol: "cup.and.saucer",
                     category: .tools, keywords: "keep awake caffeine amphetamine no sleep", opens: true),
        BarExtension(id: .display, name: "Brightness", description: "Screen brightness, and extra on XDR screens", symbol: "sun.max",
                     category: .tools, keywords: "brightness display screen xdr", opens: true),
        BarExtension(id: .sound, name: "Sound", description: "Mute the mic, switch the output", symbol: "speaker.wave.2",
                     category: .tools, keywords: "sound audio microphone mic output speakers headphones", opens: true),
        BarExtension(id: .emoji, name: "Emoji", description: "Search and copy emoji, or type : and a word", symbol: "face.smiling",
                     category: .tools, keywords: "emoji smiley skin tone", opens: true),
        BarExtension(id: .lowtide, name: "Lowtide", description: "Every page and action of this app, and Ask", symbol: "eye",
                     category: .lowtide, keywords: "lowtide pages actions ask", opens: true, alwaysOn: true),
    ]

    public static func of(_ source: BarSource) -> BarExtension? { catalog.first { $0.id == source } }
}

extension BarExtension: Hashable {
    public static func == (a: BarExtension, b: BarExtension) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A list of its own in the bar: an extension's view, or all the tools.
public enum BarCategory: Hashable, Sendable {
    case source(BarSource)
    case tools

    public var label: String {
        switch self {
        case .tools: "Tools"
        case .source(let source): BarExtension.of(source)?.name ?? source.rawValue
        }
    }

    /// The views the chips under the field switch between, in order.
    public static let chips: [BarCategory] = [
        .source(.lowtide), .source(.apps), .tools, .source(.system), .source(.macSettings), .source(.folders),
        .source(.links), .source(.emoji), .source(.processes), .source(.colors),
    ]
}
