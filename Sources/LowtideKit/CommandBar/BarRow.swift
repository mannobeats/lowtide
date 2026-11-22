import Foundation

/// Where a command bar row comes from: one per bar extension
/// (`BarExtension.catalog`). Each can be switched off except Lowtide's own.
public enum BarSource: String, Codable, CaseIterable, Sendable {
    case lowtide = "lowtide"
    case apps, quit, macSettings, folders, answers, calculator, emoji, links, files, processes, system
    case colors, awake, display, sound
}

/// How a row draws its icon. Data only: the app decides what each looks like.
public enum BarIcon: Equatable, Sendable {
    /// Finder's icon for a file, folder or app.
    case file(String)
    /// An SF Symbol, optionally in the destructive colour.
    case symbol(String, destructive: Bool = false)
    /// One of the app's own glyphs (`Resources/glyphs`).
    case glyph(String)
    case emoji(String)
    case swatch(RGBA)
}

/// One more thing to do with a row, listed under ⌘K.
public struct BarRowAction: Identifiable {
    public var id: String
    public var title: String
    public var symbol: String
    /// Asks "…?" before running.
    public var confirm: String?
    public var destructive = false
    public var run: @MainActor () async throws -> Void

    public init(id: String, title: String, symbol: String, confirm: String? = nil, destructive: Bool = false,
                run: @escaping @MainActor () async throws -> Void) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.confirm = confirm
        self.destructive = destructive
        self.run = run
    }
}

/// A live 0 to 100 slider a row opens instead of asking for a number.
public struct BarSlider {
    public var level: Int
    public var apply: @MainActor (Int) async throws -> Void

    public init(level: Int, apply: @escaping @MainActor (Int) async throws -> Void) {
        self.level = level
        self.apply = apply
    }
}

/// One result in the command bar.
public struct BarRow: Identifiable {
    public var id: String
    /// Where pins, names and hiding are kept (app rows survive moving).
    public var stableKey: String
    public var source: BarSource
    public var title: String
    public var subtitle: String?
    public var keywords: [String] = []
    public var icon: BarIcon
    /// Section heading on the empty bar.
    public var group: String?
    /// Right-hand label when the source's own doesn't fit ("Extension").
    public var kind: String?
    /// Right-hand value, e.g. "84%".
    public var value: String?
    public var shortcut: String?
    public var path: String?
    /// What Return copies (answers, emoji, colours).
    public var copy: String?
    /// What Tab puts in the field (calculator results).
    public var reuse: String?
    /// Asks "…?" before running.
    public var confirm: String?
    /// Asks for a number in this range when none was typed.
    public var number: ClosedRange<Int>?
    public var slider: BarSlider?
    /// Extra ⌘K actions (pin, name, hide and forget are added by the bar).
    public var actions: [BarRowAction] = []
    /// A running app, a toggle that is on.
    public var active = false
    /// Answer styling: big result, Return copies `copy`.
    public var answer = false
    /// Counts toward "most used" and learned habits.
    public var counts = false
    /// Stays open after running (it changes the field or the view).
    public var keepsOpen = false
    /// Running it brings Lowtide's window forward.
    public var opensWindow = false
    /// Runs it. The argument is the typed number for number rows.
    public var run: @MainActor (Int?) async throws -> Void
    /// The folded title and keywords, worked out once (`indexed()`) so
    /// ranking doesn't fold a thousand emoji names on every keystroke.
    public private(set) var candidate: Ranking.Candidate?

    /// The row with its search text folded in advance.
    public func indexed() -> BarRow {
        var row = self
        row.candidate = Ranking.Candidate(title: title, keywords: keywords)
        return row
    }

    public init(id: String, stableKey: String? = nil, source: BarSource, title: String, subtitle: String? = nil,
                keywords: [String] = [], icon: BarIcon, run: @escaping @MainActor (Int?) async throws -> Void) {
        self.id = id
        self.stableKey = stableKey ?? id
        self.source = source
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.icon = icon
        self.run = run
    }
}
