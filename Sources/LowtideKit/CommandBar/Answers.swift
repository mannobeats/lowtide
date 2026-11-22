import Foundation

/// The inline result for what was typed in the command bar: a strict
/// calculator, unit and colour conversions, colour previews, relative dates,
/// "days until" and the time in another city. Everything runs locally.
public struct BarAnswer: Equatable, Sendable {
    public enum Kind: String, Sendable { case math, units, color, colorPreview, date }

    public var kind: Kind
    /// What the row shows big (the result).
    public var title: String
    /// "Return copies", "2+(3) · Return copies", "Tuesday", "Tokyo · Tuesday, 29 September 2026".
    public var subtitle: String
    /// What Return copies.
    public var copy: String
    /// Calculator only: what Tab puts back in the field (ungrouped,
    /// shortest round trip, parenthesised when negative).
    public var reuse: String?
    /// Colour kinds only: the colour, for a swatch.
    public var swatch: RGBA?

    init(_ kind: Kind, title: String, subtitle: String, reuse: String? = nil, swatch: RGBA? = nil) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        copy = title
        self.reuse = reuse
        self.swatch = swatch
    }
}

/// A colour with 0–255 channels (unrounded) and 0–1 alpha.
public struct RGBA: Equatable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// `rgba(255, 0, 0, 1)`.
    public var css: String { "rgba(\(Answers.byte(r)), \(Answers.byte(g)), \(Answers.byte(b)), \(Answers.alphaText(a)))" }
}

/// The moment, and the local time zone's offset from UTC at that moment.
public struct AnswerClock: Sendable {
    public var unix: Int
    public var offset: Int

    public init(unix: Int, offset: Int) {
        self.unix = unix
        self.offset = offset
    }

    public static var now: AnswerClock {
        let date = Date()
        return AnswerClock(unix: Int(date.timeIntervalSince1970), offset: TimeZone.current.secondsFromGMT(for: date))
    }

    var localDay: Int { (unix + offset).floorDiv(86_400) }
}

public enum Answers {
    static let returnCopies = "Return copies"

    /// Words that join a value and its target: "100 km to mi", "#f00 em rgb".
    static let toWords: Set<String> = ["to", "in", "into", "as", "em", "para", "pra", "en", "a", "nach", "zu", "su", "->", ">", "→"]

    /// math → units → colour conversion → colour preview → date, first hit wins.
    public static func answer(_ query: String, clock: AnswerClock = .now) -> BarAnswer? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        return math(q) ?? units(q) ?? colorConversion(q) ?? colorPreview(q) ?? dateAnswer(q, clock: clock)
    }

    // MARK: Folding

    /// The base letter of a Latin or Cyrillic letter with a diacritic.
    static func baseLetter(_ c: Unicode.Scalar) -> Unicode.Scalar {
        switch c {
        case "à", "á", "â", "ã", "ä", "å", "ā": "a"
        case "ç", "č", "ć": "c"
        case "è", "é", "ê", "ë", "ē": "e"
        case "ì", "í", "î", "ï", "ı", "ī": "i"
        case "ñ", "ń": "n"
        case "ò", "ó", "ô", "õ", "ö", "ø", "ō": "o"
        case "ù", "ú", "û", "ü", "ū": "u"
        case "ý", "ÿ": "y"
        case "ş", "ś", "š": "s"
        case "ğ": "g"
        case "ł": "l"
        case "ž", "ź", "ż": "z"
        case "ř": "r"
        case "ё": "е"
        default: c
        }
    }

    /// Soft hyphen, zero-width and direction marks, and combining accents.
    static func isInvisible(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0xAD, 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2064, 0xFEFF, 0x300...0x36F: true
        default: false
        }
    }

    /// Lowercase, accent-free, single-spaced text, independent of the locale.
    static func fold(_ s: String) -> String {
        var scalars = String.UnicodeScalarView()
        for c in s.lowercased().unicodeScalars where !isInvisible(c) {
            scalars.append(baseLetter(c))
        }
        return String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: Numbers

    /// Digits with "," every three places.
    static func groupDigits(_ int: String) -> String {
        let chars = Array(int)
        var out = ""
        for (i, c) in chars.enumerated() {
            if i > 0, (chars.count - i) % 3 == 0 { out.append(",") }
            out.append(c)
        }
        return out
    }

    /// Grouped, with at most `maxFraction` fraction digits and no trailing zeros.
    static func formatFixed(_ v: Double, _ maxFraction: Int) -> String {
        let s = String(format: "%.\(maxFraction)f", abs(v))
        let parts = s.split(separator: ".", maxSplits: 1).map(String.init)
        let int = parts[0]
        var frac = parts.count > 1 ? parts[1] : ""
        while frac.hasSuffix("0") { frac.removeLast() }
        let zero = int.allSatisfy { $0 == "0" } && frac.isEmpty
        var out = v < 0 && !zero ? "-" : ""
        out += groupDigits(int)
        if !frac.isEmpty { out += "." + frac }
        return out
    }

    /// Rounded to 10 significant digits.
    static func roundSignificant(_ x: Double) -> Double {
        Double(String(format: "%.9e", x)) ?? x
    }

    /// A calculator result: 10 significant digits, grouped with up to 8
    /// fraction digits, or scientific ("1.5e12") when huge or tiny.
    static func formatNumber(_ value: Double) -> String {
        let x = roundSignificant(value)
        if x == 0 { return "0" }
        let a = abs(x)
        guard a >= 1e-6, a < 1e12 else {
            let s = String(format: "%.7e", x)
            let parts = s.split(separator: "e", maxSplits: 1).map(String.init)
            var mantissa = parts[0]
            if mantissa.contains(".") {
                while mantissa.hasSuffix("0") { mantissa.removeLast() }
                if mantissa.hasSuffix(".") { mantissa.removeLast() }
            }
            let exponent = Int(parts.count > 1 ? parts[1] : "0") ?? 0
            return "\(mantissa)e\(exponent)"
        }
        return formatFixed(x, 8)
    }

    /// What Tab puts back in the field.
    static func reuseText(_ value: Double) -> String {
        let x = roundSignificant(value)
        if x == 0 { return "0" }
        let plain = x.rounded() == x && abs(x) < 1e15 ? String(Int64(x)) : "\(x)"
        return x < 0 ? "(\(plain))" : plain
    }

    /// "1,234,567"-style: 1–3 digits, then groups of exactly 3.
    static func isGrouped(_ s: String, _ separator: Character) -> Bool {
        let parts = s.split(separator: separator, omittingEmptySubsequences: false)
        guard let first = parts.first, (1...3).contains(first.count), first.allSatisfy(\.isASCIIDigit) else { return false }
        return parts.dropFirst().allSatisfy { $0.count == 3 && $0.allSatisfy(\.isASCIIDigit) }
    }

    /// An unsigned number with "." / "," separators and an optional exponent.
    /// With both separators the last one is the decimal point; a lone "," is
    /// grouping only when the groups are exactly three digits.
    static func parseNumber(_ s: String) -> Double? {
        let mantissa: String
        let exponent: String?
        if let i = s.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = String(s[..<i])
            exponent = String(s[s.index(after: i)...])
        } else {
            mantissa = s
            exponent = nil
        }
        guard mantissa.contains(where: \.isASCIIDigit),
              mantissa.allSatisfy({ $0.isASCIIDigit || $0 == "." || $0 == "," }) else { return nil }
        let dots = mantissa.count { $0 == "." }
        let commas = mantissa.count { $0 == "," }
        var plain: String
        if dots > 0, commas > 0 {
            let lastDot = mantissa.lastIndex(of: ".")!, lastComma = mantissa.lastIndex(of: ",")!
            let (decimal, grouping): (Character, String) = lastDot > lastComma ? (".", ",") : (",", ".")
            guard mantissa.count(where: { $0 == decimal }) == 1 else { return nil }
            plain = mantissa.replacingOccurrences(of: grouping, with: "").replacingOccurrences(of: String(decimal), with: ".")
        } else if commas > 0 {
            if isGrouped(mantissa, ",") {
                plain = mantissa.replacingOccurrences(of: ",", with: "")
            } else if commas == 1 {
                plain = mantissa.replacingOccurrences(of: ",", with: ".")
            } else {
                return nil
            }
        } else if dots > 1 {
            return nil
        } else {
            plain = mantissa
        }
        if let exponent {
            guard Int32(exponent) != nil else { return nil }
            plain += "e" + exponent
        }
        // Swift's Double("5.") is nil; Rust reads it as 5.
        if plain.hasSuffix(".") { plain.removeLast() }
        if plain.hasPrefix(".") { plain = "0" + plain }
        return Double(plain).flatMap { $0.isFinite ? $0 : nil }
    }

    /// A number with an optional leading sign.
    static func parseSigned(_ s: String) -> Double? {
        if s.hasPrefix("-") || s.hasPrefix("−") { return parseNumber(String(s.dropFirst())).map { -$0 } }
        return parseNumber(s.hasPrefix("+") ? String(s.dropFirst()) : s)
    }

    // MARK: Calculator

    enum Token: Equatable {
        case number(Double), op(Character), open(Character), close(Character), percent, word(String)
    }

    /// The "of" in "10% of 50", in several languages.
    static let ofWords: Set<String> = ["of", "de", "da", "do", "von", "di", "del", "dal"]

    /// The length of the number starting at `chars[i]`, exponent included.
    static func numberLength(_ chars: [Character], _ i: Int) -> Int {
        var j = i
        while j < chars.count, chars[j].isASCIIDigit || chars[j] == "." || chars[j] == "," { j += 1 }
        if j < chars.count, chars[j] == "e" || chars[j] == "E" {
            let sign = j + 1 < chars.count && (chars[j + 1] == "+" || chars[j + 1] == "-") ? 1 : 0
            if j + 1 + sign < chars.count, chars[j + 1 + sign].isASCIIDigit {
                j += 1 + sign
                while j < chars.count, chars[j].isASCIIDigit { j += 1 }
            }
        }
        return j - i
    }

    /// Splits a calculation into tokens, or nil on any foreign character.
    static func lex(_ input: String) -> [Token]? {
        let chars = Array(input)
        var tokens: [Token] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace {
                i += 1
            } else if c.isASCIIDigit || c == "." {
                let n = numberLength(chars, i)
                guard let value = parseNumber(String(chars[i..<i + n])) else { return nil }
                tokens.append(.number(value))
                i += n
            } else if c.isASCII, c.isLetter {
                let start = i
                while i < chars.count, chars[i].isASCII, chars[i].isLetter { i += 1 }
                var word = String(chars[start..<i]).lowercased()
                if word == "log", i + 1 < chars.count, chars[i] == "1", chars[i + 1] == "0" {
                    word += "10"
                    i += 2
                }
                tokens.append(word == "x" ? .op("*") : .word(word))
            } else {
                switch c {
                case "+": tokens.append(.op("+"))
                case "-", "−": tokens.append(.op("-"))
                case "*", "×": tokens.append(.op("*"))
                case "/", "÷": tokens.append(.op("/"))
                case "^": tokens.append(.op("^"))
                case "%": tokens.append(.percent)
                case "(", "[": tokens.append(.open(c))
                case ")", "]": tokens.append(.close(c))
                case "π": tokens.append(.word("pi"))
                default: return nil
                }
                i += 1
            }
        }
        return tokens
    }

    static func function(_ name: String) -> ((Double) -> Double)? {
        switch name {
        case "sqrt": { $0.squareRoot() }
        case "abs": { abs($0) }
        case "sin": { Foundation.sin($0) }
        case "cos": { Foundation.cos($0) }
        case "tan": { Foundation.tan($0) }
        case "asin": { Foundation.asin($0) }
        case "acos": { Foundation.acos($0) }
        case "atan": { Foundation.atan($0) }
        case "ln": { Foundation.log($0) }
        case "log", "log10": { Foundation.log10($0) }
        case "exp": { Foundation.exp($0) }
        case "floor": { $0.rounded(.down) }
        case "ceil": { $0.rounded(.up) }
        case "round": { $0.rounded() }
        default: nil
        }
    }

    /// A recursive-descent evaluator. Values carry a flag saying the term was
    /// a bare percentage, which `a + b%` reads relative to `a`.
    struct Calc {
        var tokens: [Token]
        var pos = 0
        /// Closing brackets still owed, innermost last.
        var open: [Character] = []
        /// Brackets never closed, in the order they were closed virtually.
        var closedVirtually = ""
        /// Whether an operator, function or implicit product appeared.
        var hasOp = false

        init(_ tokens: [Token]) { self.tokens = tokens }

        var peek: Token? { pos < tokens.count ? tokens[pos] : nil }

        mutating func next() -> Token? {
            defer { pos += 1 }
            return peek
        }

        static func finite(_ x: Double) -> Double? { x.isFinite ? x : nil }

        mutating func expr() -> Double? {
            guard var (v, _) = term() else { return nil }
            while case .op(let op)? = peek, op == "+" || op == "-" {
                pos += 1
                hasOp = true
                guard let (r0, percent) = term() else { return nil }
                let r = percent ? v * r0 : r0
                guard let sum = Self.finite(op == "+" ? v + r : v - r) else { return nil }
                v = sum
            }
            return v
        }

        /// The next token starts an implicit product, as in `2π` or `2(3)`.
        var implicitNext: Bool {
            switch peek {
            case .open?: true
            case .word(let w)?: !ofWords.contains(w)
            default: false
            }
        }

        mutating func term() -> (Double, Bool)? {
            guard var (v, percent) = unary() else { return nil }
            while true {
                if case .op(let op)? = peek, op == "*" || op == "/" {
                    pos += 1
                    guard let (r, _) = unary(), let product = Self.finite(op == "*" ? v * r : v / r) else { return nil }
                    v = product
                } else if implicitNext {
                    guard let (r, _) = power(), let product = Self.finite(v * r) else { return nil }
                    v = product
                } else {
                    return (v, percent)
                }
                hasOp = true
                percent = false
            }
        }

        /// A sign applies to the whole power, so `-2^2` is -4.
        mutating func unary() -> (Double, Bool)? {
            switch peek {
            case .op("-")?:
                pos += 1
                return unary().map { (-$0.0, $0.1) }
            case .op("+")?:
                pos += 1
                return unary()
            default:
                return power()
            }
        }

        /// `^` is right-associative: `2^3^2` is `2^9`.
        mutating func power() -> (Double, Bool)? {
            guard let (base, percent) = postfix() else { return nil }
            guard peek == .op("^") else { return (base, percent) }
            pos += 1
            hasOp = true
            guard let (exp, _) = unary(), let v = Self.finite(pow(base, exp)) else { return nil }
            return (v, false)
        }

        /// `N%` and "X% of Y".
        mutating func postfix() -> (Double, Bool)? {
            guard var v = primary() else { return nil }
            var percent = false
            while peek == .percent {
                pos += 1
                hasOp = true
                v /= 100
                percent = true
            }
            if percent, case .word(let w)? = peek, ofWords.contains(w) {
                pos += 1
                guard let (of, _) = unary(), let product = Self.finite(v * of) else { return nil }
                return (product, false)
            }
            return (v, percent)
        }

        mutating func primary() -> Double? {
            switch next() {
            case .number(let n)?: return n
            case .open(let c)?: return group(c)
            case .word("pi")?: return .pi
            case .word("e")?: return M_E
            case .word(let name)?:
                guard let f = function(name), case .open(let c)? = next() else { return nil }
                hasOp = true
                return group(c).flatMap { Self.finite(f($0)) }
            default: return nil
            }
        }

        /// A bracketed expression; brackets left open at the end close virtually.
        mutating func group(_ open: Character) -> Double? {
            guard self.open.count < 32 else { return nil }
            self.open.append(open == "[" ? "]" : ")")
            guard let v = expr(), let want = self.open.popLast() else { return nil }
            switch peek {
            case nil: closedVirtually.append(want)
            case .close(let c)? where c == want: pos += 1
            default: return nil
            }
            return v
        }
    }

    /// The value of a whole calculation, and the brackets it closed virtually.
    static func calculate(_ input: String) -> (Double, String)? {
        guard let tokens = lex(input) else { return nil }
        var calc = Calc(tokens)
        guard let v = calc.expr(), calc.pos == calc.tokens.count, calc.hasOp else { return nil }
        return (v, calc.closedVirtually)
    }

    /// "2026-07-27", "27/07/2026" and "10:30" are dates and times, not sums.
    static func looksLikeDate(_ s: String) -> Bool {
        func groups(_ separator: Character) -> Int? {
            let parts = s.split(separator: separator, omittingEmptySubsequences: false)
            return parts.allSatisfy { (1...4).contains($0.count) && $0.allSatisfy(\.isASCIIDigit) } ? parts.count : nil
        }
        return groups("-") == 3 || groups("/") == 3 || [2, 3].contains(groups(":") ?? 0)
    }

    static func math(_ q: String) -> BarAnswer? {
        guard q.count <= 120 else { return nil }
        var body = q
        if body.hasSuffix("=") { body.removeLast() }
        while body.last?.isWhitespace == true { body.removeLast() }
        guard !body.contains("="), !looksLikeDate(body), let (v, closers) = calculate(body) else { return nil }
        let subtitle = closers.isEmpty ? returnCopies : "\(body)\(closers) · \(returnCopies)"
        return BarAnswer(.math, title: formatNumber(v), subtitle: subtitle, reuse: reuseText(v))
    }

    // MARK: Units

    enum Family { case temperature, length, mass, data, duration, volume }

    struct Unit {
        let names: Set<String>
        let family: Family
        /// Size in the family's base unit (m, g, byte, s, mL). Unused for temperature.
        let factor: Double
        let symbol: String
    }

    static let units: [Unit] = [
        Unit(names: ["c", "celsius", "°c", "centigrade"], family: .temperature, factor: 1, symbol: "°C"),
        Unit(names: ["f", "fahrenheit", "°f"], family: .temperature, factor: 1, symbol: "°F"),
        Unit(names: ["k", "kelvin"], family: .temperature, factor: 1, symbol: "K"),
        Unit(names: ["mm", "millimeter", "millimeters", "millimetre", "millimetres", "milimetro", "milimetros"],
             family: .length, factor: 0.001, symbol: "mm"),
        Unit(names: ["cm", "centimeter", "centimeters", "centimetre", "centimetres", "centimetro", "centimetros"],
             family: .length, factor: 0.01, symbol: "cm"),
        Unit(names: ["m", "meter", "meters", "metre", "metres", "metro", "metros"], family: .length, factor: 1, symbol: "m"),
        Unit(names: ["km", "kilometer", "kilometers", "kilometre", "kilometres", "quilometro", "quilometros", "kilometro", "kilometros"],
             family: .length, factor: 1000, symbol: "km"),
        Unit(names: ["in", "inch", "inches", "\"", "polegada", "polegadas", "pulgada", "pulgadas"],
             family: .length, factor: 0.0254, symbol: "in"),
        Unit(names: ["ft", "foot", "feet", "pe", "pes", "pie", "pies"], family: .length, factor: 0.3048, symbol: "ft"),
        Unit(names: ["yd", "yard", "yards", "jarda", "jardas", "yarda", "yardas"], family: .length, factor: 0.9144, symbol: "yd"),
        Unit(names: ["mi", "mile", "miles", "milha", "milhas", "milla", "millas"], family: .length, factor: 1609.344, symbol: "mi"),
        Unit(names: ["mg", "milligram", "milligrams", "miligrama", "miligramas", "miligramo", "miligramos"],
             family: .mass, factor: 0.001, symbol: "mg"),
        Unit(names: ["g", "gram", "grams", "gramme", "grammes", "grama", "gramas", "gramo", "gramos"], family: .mass, factor: 1, symbol: "g"),
        Unit(names: ["kg", "kilogram", "kilograms", "kilo", "kilos", "quilo", "quilos", "quilograma", "quilogramas", "kilogramo", "kilogramos"],
             family: .mass, factor: 1000, symbol: "kg"),
        Unit(names: ["t", "ton", "tons", "tonne", "tonnes", "tonelada", "toneladas"], family: .mass, factor: 1e6, symbol: "t"),
        Unit(names: ["oz", "ounce", "ounces", "onca", "oncas", "onza", "onzas"], family: .mass, factor: 28.349_523_125, symbol: "oz"),
        Unit(names: ["lb", "lbs", "pound", "pounds", "libra", "libras"], family: .mass, factor: 453.592_37, symbol: "lb"),
        Unit(names: ["b", "byte", "bytes"], family: .data, factor: 1, symbol: "B"),
        Unit(names: ["kb", "kilobyte", "kilobytes"], family: .data, factor: 1e3, symbol: "kB"),
        Unit(names: ["mb", "megabyte", "megabytes"], family: .data, factor: 1e6, symbol: "MB"),
        Unit(names: ["gb", "gigabyte", "gigabytes"], family: .data, factor: 1e9, symbol: "GB"),
        Unit(names: ["tb", "terabyte", "terabytes"], family: .data, factor: 1e12, symbol: "TB"),
        Unit(names: ["kib", "kibibyte", "kibibytes"], family: .data, factor: 1024, symbol: "KiB"),
        Unit(names: ["mib", "mebibyte", "mebibytes"], family: .data, factor: 1_048_576, symbol: "MiB"),
        Unit(names: ["gib", "gibibyte", "gibibytes"], family: .data, factor: 1_073_741_824, symbol: "GiB"),
        Unit(names: ["tib", "tebibyte", "tebibytes"], family: .data, factor: 1_099_511_627_776, symbol: "TiB"),
        Unit(names: ["bit", "bits"], family: .data, factor: 0.125, symbol: "bit"),
        Unit(names: ["ms", "millisecond", "milliseconds", "milissegundo", "milissegundos", "milisegundo", "milisegundos"],
             family: .duration, factor: 0.001, symbol: "ms"),
        Unit(names: ["s", "sec", "secs", "second", "seconds", "segundo", "segundos"], family: .duration, factor: 1, symbol: "s"),
        Unit(names: ["min", "mins", "minute", "minutes", "minuto", "minutos"], family: .duration, factor: 60, symbol: "min"),
        Unit(names: ["h", "hr", "hrs", "hour", "hours", "hora", "horas"], family: .duration, factor: 3600, symbol: "h"),
        Unit(names: ["ml", "milliliter", "milliliters", "millilitre", "millilitres", "mililitro", "mililitros"],
             family: .volume, factor: 1, symbol: "mL"),
        Unit(names: ["l", "liter", "liters", "litre", "litres", "litro", "litros"], family: .volume, factor: 1000, symbol: "L"),
        Unit(names: ["gal", "gallon", "gallons", "galao", "galoes", "galon", "galones"], family: .volume, factor: 3_785.411_784, symbol: "gal"),
        Unit(names: ["qt", "quart", "quarts"], family: .volume, factor: 946.352_946, symbol: "qt"),
        Unit(names: ["floz", "fl oz", "fluidounce", "fluid ounce", "fluid ounces"], family: .volume, factor: 29.573_529_562_5, symbol: "fl oz"),
        Unit(names: ["cup", "cups", "xicara", "xicaras", "taza", "tazas"], family: .volume, factor: 236.588_236_5, symbol: "cup"),
    ]

    /// The unit spelled by `words`, joined with or without spaces.
    static func findUnit(_ words: ArraySlice<String>) -> Unit? {
        let spaced = words.joined(separator: " "), joined = words.joined()
        return units.first { $0.names.contains(spaced) || $0.names.contains(joined) }
    }

    static func toKelvin(_ v: Double, _ symbol: String) -> Double {
        switch symbol {
        case "°C": v + 273.15
        case "°F": (v - 32) * 5 / 9 + 273.15
        default: v
        }
    }

    static func fromKelvin(_ k: Double, _ symbol: String) -> Double {
        switch symbol {
        case "°C": k - 273.15
        case "°F": (k - 273.15) * 9 / 5 + 32
        default: k
        }
    }

    static func convert(_ v: Double, from: Unit, to: Unit) -> Double {
        from.family == .temperature ? fromKelvin(toKelvin(v, from.symbol), to.symbol) : v * from.factor / to.factor
    }

    /// Fraction digits for a measurement: 4 below 1, 2 below 100, else 1.
    static func measureDigits(_ v: Double) -> Int {
        abs(v) < 1 ? 4 : abs(v) < 100 ? 2 : 1
    }

    /// Feet of at least one, as feet and inches: "5 ft 10.5 in".
    static func feetAndInches(_ v: Double) -> String {
        var feet = v.rounded(.down)
        var inches = ((v - feet) * 120).rounded() / 10
        if inches >= 12 {
            feet += 1
            inches = 0
        }
        return inches == 0 ? "\(formatFixed(feet, 0)) ft" : "\(formatFixed(feet, 0)) ft \(formatFixed(inches, 1)) in"
    }

    static func formatMeasure(_ v: Double, _ unit: Unit) -> String {
        if unit.symbol == "ft", v >= 1 { return feetAndInches(v) }
        return "\(formatFixed(v, measureDigits(v))) \(unit.symbol)"
    }

    /// Words of folded text, with a leading number split from what follows
    /// it: "100km" → "100", "km".
    static func tokensWithSplitNumber(_ text: String) -> [String] {
        var tokens: [String] = []
        for (i, word) in text.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
            let chars = Array(word)
            let bodyStart = chars.first == "-" || chars.first == "+" ? 1 : 0
            let cut = chars.indices.dropFirst(bodyStart).first { !(chars[$0].isASCIIDigit || chars[$0] == "." || chars[$0] == ",") }
            if let cut, cut > bodyStart, i == 0 || chars[cut].isLetter {
                tokens.append(String(chars[..<cut]))
                tokens.append(String(chars[cut...]))
            } else {
                tokens.append(String(word))
            }
        }
        return tokens
    }

    static func units(_ q: String) -> BarAnswer? {
        let tokens = tokensWithSplitNumber(fold(q))
        guard (3...8).contains(tokens.count), let value = parseSigned(tokens[0]) else { return nil }
        // The to-word is tried from the right, which is how "5 in to cm" works.
        for i in stride(from: tokens.count - 2, through: 2, by: -1) where toWords.contains(tokens[i]) {
            guard let from = findUnit(tokens[1..<i]), let to = findUnit(tokens[(i + 1)...]), from.family == to.family else { continue }
            return BarAnswer(.units, title: formatMeasure(convert(value, from: from, to: to), to), subtitle: returnCopies)
        }
        return nil
    }

    // MARK: Colours

    static func plainNumber(_ p: some StringProtocol) -> Double? {
        Double(p.trimmingCharacters(in: .whitespaces)).flatMap { $0.isFinite ? $0 : nil }
    }

    /// A 0–255 channel, or a percentage of 255.
    static func channel(_ p: String) -> Double? {
        let v = p.hasSuffix("%") ? plainNumber(p.dropLast()).map { $0 * 2.55 } : plainNumber(p)
        return v.flatMap { (0...255).contains($0) ? $0 : nil }
    }

    /// A 0–1 value, or a percentage.
    static func unitInterval(_ p: String) -> Double? {
        let v = p.hasSuffix("%") ? plainNumber(p.dropLast()).map { $0 / 100 } : plainNumber(p)
        return v.flatMap { (0...1).contains($0) ? $0 : nil }
    }

    static func parseHex(_ hex: String) -> RGBA? {
        guard hex.allSatisfy(\.isHexDigit) else { return nil }
        let nibbles = hex.compactMap { $0.hexDigitValue }.map(Double.init)
        let bytes: [Double]
        switch nibbles.count {
        case 3, 4: bytes = nibbles.map { $0 * 17 }
        case 6, 8: bytes = stride(from: 0, to: nibbles.count, by: 2).map { nibbles[$0] * 16 + nibbles[$0 + 1] }
        default: return nil
        }
        return RGBA(r: bytes[0], g: bytes[1], b: bytes[2], a: bytes.count > 3 ? bytes[3] / 255 : 1)
    }

    /// The parts of "255 0 0 / 50%" or "255, 0, 0, 0.5".
    static func colorParts(_ inner: String) -> [String] {
        inner.split { $0 == "," || $0 == "/" || $0.isWhitespace }.map(String.init)
    }

    static func optionalAlpha(_ parts: [String]) -> Double? {
        parts.count > 3 ? unitInterval(parts[3]) : 1
    }

    static func parseRGB(_ inner: String) -> RGBA? {
        let parts = colorParts(inner)
        guard (3...4).contains(parts.count), let r = channel(parts[0]), let g = channel(parts[1]), let b = channel(parts[2]),
              let a = optionalAlpha(parts) else { return nil }
        return RGBA(r: r, g: g, b: b, a: a)
    }

    /// A 0–100 percentage, with or without the "%".
    static func percent(_ p: String) -> Double? {
        plainNumber(p.hasSuffix("%") ? String(p.dropLast()) : p).flatMap { (0...100).contains($0) ? $0 / 100 : nil }
    }

    static func parseHSL(_ inner: String) -> RGBA? {
        let parts = colorParts(inner)
        guard (3...4).contains(parts.count),
              let h = plainNumber(parts[0].hasSuffix("deg") ? String(parts[0].dropLast(3)) : parts[0]),
              let s = percent(parts[1]), let l = percent(parts[2]), let a = optionalAlpha(parts) else { return nil }
        let (r, g, b) = hslToRGB(h, s, l)
        return RGBA(r: r, g: g, b: b, a: a)
    }

    /// SwiftUI's `Color(red: 0.2, green: 0.4, blue: 0.6, opacity: 0.5)`.
    static func parseSwift(_ inner: String) -> RGBA? {
        var c = RGBA(r: .nan, g: .nan, b: .nan)
        for pair in inner.split(separator: ",", omittingEmptySubsequences: false) {
            let kv = pair.split(separator: ":", maxSplits: 1)
            guard kv.count == 2, let v = plainNumber(kv[1]), (0...1).contains(v) else { return nil }
            switch kv[0].trimmingCharacters(in: .whitespaces) {
            case "red": c.r = v * 255
            case "green": c.g = v * 255
            case "blue": c.b = v * 255
            case "opacity": c.a = v
            default: return nil
            }
        }
        return c.r.isFinite && c.g.isFinite && c.b.isFinite ? c : nil
    }

    /// A colour typed as hex, rgb(), hsl() or SwiftUI `Color(...)`.
    public static func parseColor(_ text: String) -> RGBA? {
        let s = text.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasPrefix("#") { return parseHex(String(s.dropFirst())) }
        guard s.hasSuffix(")"), let open = s.firstIndex(of: "(") else { return nil }
        let name = s[..<open].trimmingCharacters(in: .whitespaces)
        let inner = String(s[s.index(after: open)..<s.index(before: s.endIndex)])
        switch name {
        case "rgb", "rgba": return parseRGB(inner)
        case "hsl", "hsla": return parseHSL(inner)
        case "color": return parseSwift(inner)
        default: return nil
        }
    }

    /// `h` in degrees, `s` and `l` in 0–1, to 0–255 channels.
    static func hslToRGB(_ h: Double, _ s: Double, _ l: Double) -> (Double, Double, Double) {
        let c = (1 - abs(2 * l - 1)) * s
        let hp = h.truncatingRemainder(dividingBy: 360).addingIfNegative(360) / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double) = switch Int(hp) {
        case 0: (c, x, 0)
        case 1: (x, c, 0)
        case 2: (0, c, x)
        case 3: (0, x, c)
        case 4: (x, 0, c)
        default: (c, 0, x)
        }
        let m = l - c / 2
        return ((r + m) * 255, (g + m) * 255, (b + m) * 255)
    }

    /// Hue in degrees, saturation and lightness in 0–1.
    static func rgbToHSL(_ c: RGBA) -> (Double, Double, Double) {
        let (r, g, b) = (c.r / 255, c.g / 255, c.b / 255)
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2, d = mx - mn
        guard d != 0 else { return (0, 0, l) }
        let s = d / (1 - abs(2 * l - 1))
        let h: Double = if mx == r {
            60 * ((g - b) / d).truncatingRemainder(dividingBy: 6).addingIfNegative(6)
        } else if mx == g {
            60 * ((b - r) / d + 2)
        } else {
            60 * ((r - g) / d + 4)
        }
        return (h, s, l)
    }

    static func byte(_ v: Double) -> Int { Int(min(max(v.rounded(), 0), 255)) }

    static func alphaText(_ a: Double) -> String { formatFixed(a, 3) }

    /// `c` written in `target`; the "a" forms always include alpha, the
    /// others only when the colour is translucent.
    static func formatColor(_ c: RGBA, _ target: String) -> String? {
        let translucent = c.a < 1
        switch target {
        case "hex":
            var s = String(format: "#%02X%02X%02X", byte(c.r), byte(c.g), byte(c.b))
            if translucent { s += String(format: "%02X", byte(c.a * 255)) }
            return s
        case "rgb" where !translucent:
            return "rgb(\(byte(c.r)), \(byte(c.g)), \(byte(c.b)))"
        case "rgb", "rgba":
            return c.css
        case "hsl", "hsla":
            let (h, s, l) = rgbToHSL(c)
            let (hi, si, li) = (Int(h.rounded()), Int((s * 100).rounded()), Int((l * 100).rounded()))
            return target == "hsl" && !translucent ? "hsl(\(hi), \(si)%, \(li)%)" : "hsla(\(hi), \(si)%, \(li)%, \(alphaText(c.a)))"
        case "swift", "swiftui":
            var s = String(format: "Color(red: %.3f, green: %.3f, blue: %.3f", c.r / 255, c.g / 255, c.b / 255)
            if translucent { s += ", opacity: \(alphaText(c.a))" }
            return s + ")"
        default:
            return nil
        }
    }

    /// Splits off the last whitespace-separated word.
    static func splitLast(_ s: String) -> (String, String)? {
        guard let i = s.lastIndex(where: \.isWhitespace) else { return nil }
        return (String(s[..<i]), String(s[s.index(after: i)...]))
    }

    /// "<colour> <to-word> <target>", e.g. "#f00 to rgb".
    static func colorConversion(_ q: String) -> BarAnswer? {
        guard let (rest, target) = splitLast(q) else { return nil }
        var trimmed = rest
        while trimmed.last?.isWhitespace == true { trimmed.removeLast() }
        guard let (colour, word) = splitLast(trimmed), toWords.contains(fold(word)),
              let c = parseColor(colour), let title = formatColor(c, target.lowercased()) else { return nil }
        return BarAnswer(.color, title: title, subtitle: returnCopies, swatch: c)
    }

    /// Input that is only a colour value gets a swatch row.
    static func colorPreview(_ q: String) -> BarAnswer? {
        guard q.utf8.count <= 96, let c = parseColor(q) else { return nil }
        return BarAnswer(.colorPreview, title: q, subtitle: returnCopies, swatch: c)
    }

    // MARK: Dates

    static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
                         "October", "November", "December"]
    static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    /// Days since 1970-01-01 of a proleptic Gregorian date.
    static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civilFromDays(_ z0: Int) -> (Int, Int, Int) {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }

    static func daysInMonth(_ y: Int, _ m: Int) -> Int {
        (m == 12 ? daysFromCivil(y + 1, 1, 1) : daysFromCivil(y, m + 1, 1)) - daysFromCivil(y, m, 1)
    }

    /// `n` months later, clamping the day (31 January + 1 month = 28 February).
    static func addMonths(_ day: Int, _ n: Int) -> Int {
        let (y, m, d) = civilFromDays(day)
        let total = y * 12 + (m - 1) + n
        let ny = total.floorDiv(12), nm = total - ny * 12 + 1
        return daysFromCivil(ny, nm, min(d, daysInMonth(ny, nm)))
    }

    static func weekday(_ day: Int) -> String { weekdays[(day + 4).floorMod(7)] }

    /// "29 September 2026".
    static func longDate(_ day: Int) -> String {
        let (y, m, d) = civilFromDays(day)
        return "\(d) \(months[m - 1]) \(y)"
    }

    /// "Tuesday, 29 September 2026".
    static func fullDate(_ day: Int) -> String { "\(weekday(day)), \(longDate(day))" }

    /// "3:04 PM" for seconds since midnight.
    static func shortTime(_ seconds: Int) -> String {
        let minutes = seconds.floorMod(86_400) / 60
        let (h, m) = (minutes / 60, minutes % 60)
        return "\(h % 12 == 0 ? 12 : h % 12):\(String(format: "%02d", m)) \(h < 12 ? "AM" : "PM")"
    }

    /// City names the zone identifiers don't spell, folded.
    static let cityAliases: [String: String] = [
        "londres": "Europe/London", "nova york": "America/New_York", "nova iorque": "America/New_York",
        "nueva york": "America/New_York", "нью-йорк": "America/New_York", "washington": "America/New_York",
        "toquio": "Asia/Tokyo", "tokio": "Asia/Tokyo", "токио": "Asia/Tokyo", "beijing": "Asia/Shanghai",
        "pequim": "Asia/Shanghai", "pekin": "Asia/Shanghai", "пекин": "Asia/Shanghai", "москва": "Europe/Moscow",
        "moscou": "Europe/Moscow", "moscu": "Europe/Moscow", "санкт-петербург": "Europe/Moscow",
        "лондон": "Europe/London", "париж": "Europe/Paris", "берлин": "Europe/Berlin", "berlim": "Europe/Berlin",
        "roma": "Europe/Rome", "lisboa": "Europe/Lisbon", "madri": "Europe/Madrid", "viena": "Europe/Vienna",
        "atenas": "Europe/Athens", "varsovia": "Europe/Warsaw", "praga": "Europe/Prague",
        "estocolmo": "Europe/Stockholm", "bruxelas": "Europe/Brussels", "bruselas": "Europe/Brussels",
        "genebra": "Europe/Zurich", "ginebra": "Europe/Zurich", "киев": "Europe/Kiev", "kyiv": "Europe/Kiev",
        "istambul": "Europe/Istanbul", "estambul": "Europe/Istanbul", "el cairo": "Africa/Cairo",
        "cidade do mexico": "America/Mexico_City", "ciudad de mexico": "America/Mexico_City",
        "mexico city": "America/Mexico_City", "rio de janeiro": "America/Sao_Paulo", "seul": "Asia/Seoul",
        "singapura": "Asia/Singapore", "singapur": "Asia/Singapore", "nova deli": "Asia/Kolkata",
        "nueva delhi": "Asia/Kolkata", "new delhi": "Asia/Kolkata", "delhi": "Asia/Kolkata",
        "mumbai": "Asia/Kolkata", "san francisco": "America/Los_Angeles", "utc": "UTC",
    ]

    /// "America/New_York" → "New York".
    static func zoneCity(_ id: String) -> String {
        (id.split(separator: "/").last.map(String.init) ?? id).replacingOccurrences(of: "_", with: " ")
    }

    static let zoneNames = TimeZone.knownTimeZoneIdentifiers

    static func findZone(_ place: String) -> String? {
        cityAliases[place] ?? zoneNames.first { fold(zoneCity($0)) == place }
    }

    static let todayWords: Set<String> = ["today", "hoje", "heute", "hoy", "oggi", "aujourd'hui", "сегодня", "bugun", "今日", "오늘", "今天"]
    static let futureWords: Set<String> = ["in", "em", "daqui", "dentro", "nach", "tra", "fra", "dans", "через", "sonra", "後", "후", "后", "from"]
    static let pastWords: Set<String> = ["ago", "atras", "ha", "hace", "vor", "fa", "назад", "once", "前", "전"]
    /// Words that may sit around a relative date without changing it.
    static let relativeFillers: Set<String> = ["+", "de", "a", "da", "now", "jetzt", "ahora", "agora", "adesso", "maintenant"]
    static let untilWords: Set<String> = ["until", "till", "ate", "hasta", "bis", "fino", "до", "kadar", "까지"]
    static let timeWords: Set<String> = ["time", "hora", "hour", "uhrzeit", "uhr", "ora", "heure", "время", "saat", "時刻", "時間", "시간", "时间", "现在"]

    enum Span { case day, week, month, year }

    static let spanWords: [(String, Span)] = [
        ("day", .day), ("days", .day), ("dia", .day), ("dias", .day), ("tag", .day), ("tage", .day), ("tagen", .day),
        ("giorno", .day), ("giorni", .day), ("jour", .day), ("jours", .day), ("день", .day), ("дня", .day), ("дней", .day),
        ("gun", .day), ("日", .day), ("일", .day), ("天", .day),
        ("week", .week), ("weeks", .week), ("semana", .week), ("semanas", .week), ("woche", .week), ("wochen", .week),
        ("settimana", .week), ("settimane", .week), ("semaine", .week), ("semaines", .week), ("неделя", .week),
        ("недели", .week), ("недель", .week), ("неделю", .week), ("hafta", .week), ("週", .week), ("週間", .week),
        ("주", .week), ("周", .week), ("星期", .week),
        ("month", .month), ("months", .month), ("mes", .month), ("meses", .month), ("monat", .month), ("monate", .month),
        ("monaten", .month), ("mese", .month), ("mesi", .month), ("mois", .month), ("месяц", .month), ("месяца", .month),
        ("месяцев", .month), ("ay", .month), ("ヶ月", .month), ("か月", .month), ("개월", .month), ("달", .month),
        ("个月", .month), ("月", .month),
        ("year", .year), ("years", .year), ("ano", .year), ("anos", .year), ("jahr", .year), ("jahre", .year),
        ("jahren", .year), ("anno", .year), ("anni", .year), ("an", .year), ("ans", .year), ("annee", .year),
        ("annees", .year), ("год", .year), ("года", .year), ("лет", .year), ("yil", .year), ("年", .year), ("년", .year),
    ]

    /// A span word at the start of `token`, and what follows it ("日後" → 日, 後).
    static func spanPrefix(_ token: String) -> (Span, String)? {
        if let (_, span) = spanWords.first(where: { $0.0 == token }) { return (span, "") }
        for (word, span) in spanWords where token.hasPrefix(word) {
            let rest = String(token.dropFirst(word.count))
            if futureWords.contains(rest) || pastWords.contains(rest) { return (span, rest) }
        }
        return nil
    }

    /// "in 3 weeks", "3 days ago", "today + 10 days".
    static func relativeDate(_ tokens: [String], today: Int) -> BarAnswer? {
        var found: (Int, Int, Span, String)?
        for (i, t) in tokens.enumerated() {
            guard let n = Int(t), i + 1 < tokens.count, let (span, rest) = spanPrefix(tokens[i + 1]) else { continue }
            found = (i, n, span, rest)
            break
        }
        guard let (i, n0, span, rest) = found, abs(n0) <= 10_000 else { return nil }
        var others = tokens.enumerated().filter { $0.offset != i && $0.offset != i + 1 }.map(\.element)
        if !rest.isEmpty { others.append(rest) }
        var direction = 0
        for word in others {
            if pastWords.contains(word) || word == "-" {
                direction = -1
            } else if todayWords.contains(word) || futureWords.contains(word) {
                if direction == 0 { direction = 1 }
            } else if !relativeFillers.contains(word) {
                return nil
            }
        }
        guard direction != 0 else { return nil }
        let n = n0 * direction
        let target = switch span {
        case .day: today + n
        case .week: today + 7 * n
        case .month: addMonths(today, n)
        case .year: addMonths(today, 12 * n)
        }
        return BarAnswer(.date, title: longDate(target), subtitle: weekday(target))
    }

    /// A short date ("12/25", "12/25/2026", "2026-12-25"), month first.
    /// Without a year it is the next 12/25 on or after today.
    static func parseShortDate(_ text: String, today: Int) -> Int? {
        func num(_ p: Substring) -> Int? {
            !p.isEmpty && p.count <= 4 && p.allSatisfy(\.isASCIIDigit) ? Int(p) : nil
        }
        var trimmed = Substring(text)
        while trimmed.hasSuffix(".") { trimmed = trimmed.dropLast() }
        let parts = trimmed.split(omittingEmptySubsequences: false) { $0 == "/" || $0 == "." || $0 == "-" }
        let y: Int?, m: Int, d: Int
        switch parts.count {
        case 3 where parts[0].count == 4:
            guard let yy = num(parts[0]), let mm = num(parts[1]), let dd = num(parts[2]) else { return nil }
            (y, m, d) = (yy, mm, dd)
        case 3:
            guard let yy = num(parts[2]), let mm = num(parts[0]), let dd = num(parts[1]) else { return nil }
            (y, m, d) = (yy < 100 ? 2000 + yy : yy, mm, dd)
        case 2:
            guard let mm = num(parts[0]), let dd = num(parts[1]) else { return nil }
            (y, m, d) = (nil, mm, dd)
        default:
            return nil
        }
        func valid(_ y: Int) -> Bool { (1...12).contains(m) && d >= 1 && d <= daysInMonth(y, m) }
        if let y { return valid(y) ? daysFromCivil(y, m, d) : nil }
        let thisYear = civilFromDays(today).0
        return (thisYear..<thisYear + 8).lazy.filter(valid).map { daysFromCivil($0, m, d) }.first { $0 >= today }
    }

    /// "days until 12/25".
    static func daysUntil(_ tokens: [String], today: Int) -> BarAnswer? {
        guard let at = tokens.firstIndex(where: { untilWords.contains($0) || $0.hasPrefix("jusqu") }) else { return nil }
        let after = tokens[(at + 1)...].filter { !["a", "al", "el", "o", "the", "zum", "le"].contains($0) }
        let before = tokens[..<at].filter { spanPrefix($0) == nil }
        let text = after.isEmpty ? before.joined(separator: " ") : after.joined(separator: " ")
        guard let target = parseShortDate(text, today: today) else { return nil }
        let n = target - today
        let count = formatFixed(Double(abs(n)), 0)
        let unit = abs(n) == 1 ? "day" : "days"
        return BarAnswer(.date, title: n < 0 ? "\(count) \(unit) ago" : "\(count) \(unit)", subtitle: fullDate(target))
    }

    /// "time in tokyo", "hora em nova york".
    static func timeIn(_ tokens: [String], clock: AnswerClock) -> BarAnswer? {
        guard tokens.contains(where: timeWords.contains) else { return nil }
        func isFiller(_ t: String) -> Bool { ["a", "at", "de"].contains(t) || futureWords.contains(t) }
        let place = Array(tokens.filter { !timeWords.contains($0) }.drop(while: isFiller))
        let candidates = [place.joined(separator: " "), place.filter { !isFiller($0) }.joined(separator: " "), place.last ?? ""]
        guard let zone = candidates.filter({ !$0.isEmpty }).lazy.compactMap(findZone).first,
              let tz = TimeZone(identifier: zone) else { return nil }
        let there = clock.unix + tz.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(clock.unix)))
        return BarAnswer(.date, title: shortTime(there), subtitle: "\(zoneCity(zone)) · \(fullDate(there.floorDiv(86_400)))")
    }

    static func dateAnswer(_ q: String, clock: AnswerClock) -> BarAnswer? {
        guard q.count <= 80 else { return nil }
        let tokens = tokensWithSplitNumber(fold(q))
        guard tokens.count >= 2 else { return nil }
        let today = clock.localDay
        return relativeDate(tokens, today: today) ?? daysUntil(tokens, today: today) ?? timeIn(tokens, clock: clock)
    }

    // MARK: Web addresses

    static let genericTLDs: Set<String> = [
        "com", "org", "net", "edu", "gov", "mil", "int", "io", "dev", "app", "ai", "co", "me", "info", "biz", "xyz",
        "tech", "site", "online", "store", "shop", "blog", "cloud", "page", "news", "live", "pro", "name", "mobi", "art",
        "design", "studio", "agency", "space", "website", "link", "club", "top", "email", "network", "digital", "media",
        "one", "world", "today", "life", "run", "gg", "fm", "tv", "ly", "so", "to", "sh",
    ]

    /// Two-letter file extensions that are also country codes: "readme.md" is a file, not a site.
    static let fileExtensions: Set<String> = [
        "md", "py", "rs", "js", "ts", "cs", "cc", "hs", "ml", "mk", "pl", "pm", "ps", "rb", "gz", "xz", "db", "kt", "jl",
        "el", "vb", "fs", "ex", "go", "sql", "txt",
    ]

    static func isTLD(_ tld: String) -> Bool {
        tld.allSatisfy { $0.isASCII && $0.isLetter } && !fileExtensions.contains(tld) && (genericTLDs.contains(tld) || tld.count == 2)
    }

    /// "example.com" or "example.com:8080": dotted labels ending in a known TLD.
    static func isDomain(_ host: String) -> Bool {
        let pieces = host.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(pieces[0]), port = pieces.count > 1 ? String(pieces[1]) : ""
        let portOK = (port.isEmpty && !host.hasSuffix(":")) || (!port.isEmpty && port.count <= 5 && port.allSatisfy(\.isASCIIDigit))
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        let labelsOK = labels.allSatisfy { l in
            !l.isEmpty && !l.hasPrefix("-") && !l.hasSuffix("-") && l.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
        return portOK && labels.count >= 2 && labelsOK && isTLD(String(labels.last!).lowercased())
    }

    /// When the whole query is a web address (http/https, or scheme-less
    /// like "example.com/x"), the URL to open. Emails and plain file names
    /// ("notes.txt") are not addresses.
    public static func webAddress(_ query: String) -> String? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !q.contains(where: \.isWhitespace) else { return nil }
        let lower = q.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://"), let scheme = q.range(of: "://") {
            let rest = q[scheme.upperBound...]
            let authority = rest.split(omittingEmptySubsequences: false) { "/?#".contains($0) }.first ?? ""
            let host = authority.split(separator: "@", omittingEmptySubsequences: false).last ?? ""
            return host.isEmpty ? nil : q
        }
        guard !q.contains("://"), !q.contains("@") else { return nil }
        let host = q.split(omittingEmptySubsequences: false) { "/?#".contains($0) }.first.map(String.init) ?? ""
        return isDomain(host) ? "https://\(q)" : nil
    }
}

extension Int {
    func floorDiv(_ d: Int) -> Int {
        let q = self / d
        return self % d != 0 && (self < 0) != (d < 0) ? q - 1 : q
    }
    func floorMod(_ d: Int) -> Int { ((self % d) + d) % d }
}

extension Double {
    fileprivate func addingIfNegative(_ v: Double) -> Double { self < 0 ? self + v : self }
}

extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
