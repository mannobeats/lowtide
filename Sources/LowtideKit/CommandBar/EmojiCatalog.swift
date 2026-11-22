import CoreText
import Foundation

/// One emoji the bar offers.
public struct Emoji: Equatable, Sendable {
    public var char: String
    /// Its lowercase Unicode name ("face with tears of joy").
    public var name: String
    /// Words people type for it beyond the name ("lol", "ship", "yes").
    public var keywords: [String]
    /// Accepts a skin-tone modifier.
    public var tones: Bool

    /// The emoji with `tone` applied, when it takes one.
    public func toned(_ tone: SkinTone) -> String {
        guard tones, let modifier = tone.modifier, let base = char.unicodeScalars.first else { return char }
        return String(base) + modifier
    }
}

/// The emoji catalog: a popular list in usage order, then every other
/// single-scalar emoji the system font draws, sorted by name. Built once.
public enum EmojiCatalog {
    public static let all: [Emoji] = build()

    /// The most used emoji, most popular first.
    static let popular = """
    😂 ❤️ 🤣 👍 😭 🙏 😘 🥰 😍 😊 🎉 🔥 ✅ 🚀 👀 😁 💕 🥺 😅 🤔 😎 😆 😉 😢 🤗 \
    🙌 👏 💯 ✨ 😡 😱 😴 🤩 😇 🙂 🙃 😋 😜 😝 🤪 😏 😒 😔 😞 😩 😫 😤 😠 🤬 😳 🥵 🥶 😬 🙄 😐 😑 \
    😶 🤐 🤫 🤭 🥱 😪 🤤 😷 🤒 🤕 🤢 🤮 🤧 🥳 🤠 🤓 🧐 😕 😟 🙁 ☹️ 😮 😯 😲 🥹 😦 😧 😨 😰 😥 😓 \
    🤯 😈 👿 💀 ☠️ 💩 🤡 👻 👽 🤖 😺 😸 😹 😻 🙈 🙉 🙊 💋 💌 💘 💝 💖 💗 💓 💞 💔 🧡 💛 💚 💙 💜 \
    🖤 🤍 🤎 💥 💫 💦 💨 💬 💭 💤 👋 🤚 ✋ 👌 🤌 🤏 ✌️ 🤞 🤟 🤘 🤙 👈 👉 👆 👇 ☝️ 👎 ✊ 👊 🤛 🤜 \
    🤝 💪 🧠 👑 💎 🎂 🎁 🎈 🎊 🥂 🍾 🍻 ☕ 🍕 🍔 🌮 🍿 🍩 🍪 🍰 🍎 🥑 🌹 🌸 🌻 🌈 ☀️ 🌙 ⭐ 🌟 ⚡ \
    ❄️ 🌊 🐶 🐱 🦄 🐍 🐛 🦋 🐢 🎵 🎶 🎮 🏆 🥇 ⚽ 🏀 💰 💸 📈 📉 📌 📎 📝 📅 📦 💡 🔑 🔒 🔔 📣 💻 \
    📱 ⌨️ 🖥️ 🛠️ ⚙️ 🧪 🐞 ❌ ⚠️ ❓ ❗ ⛔ 🚫 ✔️ ➕ 🆗 🆕 ⏰ ⏳ 🌍 🏠 ✈️ 🚗 🎯 🙋 🤷 🤦 💁 🙆 🙅 🏃 💃 🕺 👶
    """

    /// Intent words people type for an emoji, beyond its Unicode name.
    static let aliases: [String: String] = [
        "😂": "haha lol laugh funny crying", "❤️": "love heart like", "🤣": "rofl lmao laugh haha",
        "👍": "yes good approve like okay ok agree thumbs", "😭": "sad cry sob tears",
        "🙏": "please thanks thank you pray hope", "😘": "kiss love", "🥰": "love adore crush",
        "😍": "love crush heart eyes", "😊": "happy smile blush", "🎉": "party congrats celebrate tada hooray",
        "🔥": "fire hot lit trending", "✅": "done check yes complete ok", "🚀": "launch ship rocket fast",
        "👀": "look eyes see watching", "🤔": "think hmm wonder", "😎": "cool sunglasses", "😅": "phew nervous sweat",
        "👏": "clap applause bravo", "💯": "hundred perfect score", "✨": "sparkle magic new shiny",
        "😡": "angry mad rage", "😱": "scared shock scream omg", "😴": "sleep tired zzz", "🤯": "mind blown wow",
        "💀": "dead dying lol skull", "💩": "poop crap", "🙈": "oops embarrassed", "👋": "hello hi bye wave",
        "👌": "ok okay perfect fine", "🤞": "luck hope fingers crossed", "💪": "strong muscle gym flex",
        "🤝": "deal handshake agree partner", "🐛": "bug insect", "🐞": "bug ladybug defect",
        "❌": "no wrong cross cancel fail", "⚠️": "warning caution alert", "💡": "idea tip light bulb",
        "💰": "money cash rich", "📈": "growth up chart stonks increase", "📉": "down decline chart loss",
        "🤷": "shrug dunno whatever idk", "🤦": "facepalm ugh", "☕": "coffee tea break", "🍻": "beer cheers drinks",
        "🏆": "win winner trophy champion", "🎂": "birthday cake", "🥳": "party birthday celebrate",
        "🤖": "robot bot ai", "😬": "awkward yikes grimace", "🥺": "please pleading puppy", "🧠": "brain smart think",
        "⏳": "wait loading time", "🛠️": "tools fix build",
    ]

    /// The standard emoji blocks, plus the emoji parts of the symbol blocks.
    static let ranges: [ClosedRange<UInt32>] = [0x2600...0x27BF, 0x1F300...0x1F5FF, 0x1F600...0x1F64F, 0x1F680...0x1F6FF,
                                                0x1F900...0x1F9FF, 0x1FA70...0x1FAFF]

    /// Emoji in 2600–27BF that already draw as emoji without U+FE0F.
    static let emojiPresentation: [ClosedRange<UInt32>] = [
        0x2614...0x2615, 0x2648...0x2653, 0x267F...0x267F, 0x2693...0x2693, 0x26A1...0x26A1, 0x26AA...0x26AB,
        0x26BD...0x26BE, 0x26C4...0x26C5, 0x26CE...0x26CE, 0x26D4...0x26D4, 0x26EA...0x26EA, 0x26F2...0x26F3,
        0x26F5...0x26F5, 0x26FA...0x26FA, 0x26FD...0x26FD, 0x2705...0x2705, 0x270A...0x270B, 0x2728...0x2728,
        0x274C...0x274C, 0x274E...0x274E, 0x2753...0x2755, 0x2757...0x2757, 0x2795...0x2797, 0x27B0...0x27B0,
        0x27BF...0x27BF,
    ]

    /// Emoji that take a skin-tone modifier (Unicode `Emoji_Modifier_Base`).
    static let toneBases: [ClosedRange<UInt32>] = [
        0x261D...0x261D, 0x26F9...0x26F9, 0x270A...0x270D, 0x1F385...0x1F385, 0x1F3C2...0x1F3C4, 0x1F3C7...0x1F3C7,
        0x1F3CA...0x1F3CC, 0x1F442...0x1F443, 0x1F446...0x1F450, 0x1F466...0x1F469,
        // 1F46A, the legacy family, takes no tone.
        0x1F46B...0x1F478, 0x1F47C...0x1F47C, 0x1F481...0x1F483, 0x1F485...0x1F487, 0x1F48F...0x1F48F,
        0x1F491...0x1F491, 0x1F4AA...0x1F4AA, 0x1F574...0x1F575, 0x1F57A...0x1F57A, 0x1F590...0x1F590,
        0x1F595...0x1F596, 0x1F645...0x1F647, 0x1F64B...0x1F64F, 0x1F6A3...0x1F6A3, 0x1F6B4...0x1F6B6,
        0x1F6C0...0x1F6C0, 0x1F6CC...0x1F6CC, 0x1F90C...0x1F90C, 0x1F90F...0x1F90F, 0x1F918...0x1F91F,
        0x1F926...0x1F926, 0x1F930...0x1F939, 0x1F93C...0x1F93E, 0x1F977...0x1F977, 0x1F9B5...0x1F9B6,
        0x1F9B8...0x1F9B9, 0x1F9BB...0x1F9BB, 0x1F9CD...0x1F9CF, 0x1F9D1...0x1F9DD, 0x1FAC3...0x1FAC5,
        0x1FAF0...0x1FAF8,
    ]

    static func inRanges(_ cp: UInt32, _ ranges: [ClosedRange<UInt32>]) -> Bool { ranges.contains { $0.contains(cp) } }

    /// Not an emoji of its own: skin-tone modifiers, regional indicators, hair components.
    static func isComponent(_ cp: UInt32) -> Bool {
        (0x1F3FB...0x1F3FF).contains(cp) || (0x1F1E6...0x1F1FF).contains(cp) || (0x1F9B0...0x1F9B3).contains(cp)
    }

    /// As it should be typed: text-default symbols get U+FE0F.
    static func presented(_ scalar: Unicode.Scalar) -> String {
        let cp = scalar.value
        let textDefault = (0x2600...0x27BF).contains(cp) && !inRanges(cp, emojiPresentation)
        return textDefault ? String(scalar) + "\u{FE0F}" : String(scalar)
    }

    /// Lowercase Unicode name of one scalar, or nil if unassigned.
    static func unicodeName(_ scalar: Unicode.Scalar) -> String? {
        guard let named = String(scalar).applyingTransform(.toUnicodeName, reverse: false),
              named.hasPrefix("\\N{"), named.hasSuffix("}") else { return nil }
        let name = named.dropFirst(3).dropLast()
        return name.isEmpty || name.contains("<") ? nil : name.lowercased()
    }

    static func aliases(_ base: Unicode.Scalar) -> [String] {
        aliases.filter { $0.key.unicodeScalars.first == base }.sorted { $0.key < $1.key }
            .flatMap { $0.value.split(separator: " ").map(String.init) }
    }

    static func entry(_ glyph: String, name: String) -> Emoji? {
        guard let base = glyph.unicodeScalars.first else { return nil }
        return Emoji(char: glyph, name: name, keywords: aliases(base), tones: inRanges(base.value, toneBases))
    }

    static func build() -> [Emoji] {
        var seen = Set<UInt32>()
        var list: [Emoji] = []
        for glyph in popular.split(whereSeparator: \.isWhitespace).map(String.init) {
            guard let base = glyph.unicodeScalars.first, let name = unicodeName(base), seen.insert(base.value).inserted,
                  let emoji = entry(glyph, name: name) else { continue }
            list.append(emoji)
        }
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 16, nil)
        var rest: [Emoji] = []
        for range in ranges {
            for cp in range {
                guard !isComponent(cp), !seen.contains(cp), let scalar = Unicode.Scalar(cp), drawn(font, scalar),
                      let name = unicodeName(scalar), let emoji = entry(presented(scalar), name: name) else { continue }
                seen.insert(cp)
                rest.append(emoji)
            }
        }
        return list + rest.sorted { $0.name < $1.name }
    }

    /// Whether Apple Color Emoji draws this scalar: how a single scalar is
    /// told apart from a plain symbol.
    static func drawn(_ font: CTFont, _ scalar: Unicode.Scalar) -> Bool {
        var units = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        return CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count)
    }
}
