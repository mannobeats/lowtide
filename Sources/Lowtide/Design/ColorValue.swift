import SwiftUI

/// A colour in Display P3 (gamma-encoded components), parsed from a theme:
/// `oklch(L C H)`, `oklch(L C H / a)`, `#rrggbb`, `#rrggbbaa` or `rgba(r, g, b, a)`.
struct ColorValue: Equatable, Sendable {
    var r: Double, g: Double, b: Double, a: Double

    var color: Color { Color(.displayP3, red: r, green: g, blue: b, opacity: a) }
    var nsColor: NSColor { NSColor(displayP3Red: r, green: g, blue: b, alpha: a) }

    func opacity(_ value: Double) -> ColorValue { ColorValue(r: r, g: g, b: b, a: a * value) }

    /// `color-mix(self amount, other)`.
    func mixed(with other: ColorValue, _ amount: Double) -> ColorValue {
        let t = 1 - amount
        return ColorValue(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t, a: a + (other.a - a) * t)
    }

    /// Relative luminance, for picking legible text on a fill.
    var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2289 * lin(r) + 0.6917 * lin(g) + 0.0793 * lin(b)
    }

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    static func oklch(_ l: Double, _ c: Double, _ h: Double, _ alpha: Double = 1) -> ColorValue {
        let hr = h * .pi / 180
        let A = c * cos(hr), B = c * sin(hr)
        let l_ = l + 0.3963377774 * A + 0.2158037573 * B
        let m_ = l - 0.1055613458 * A - 0.0638541728 * B
        let s_ = l - 0.0894841775 * A - 1.2914855480 * B
        let L = l_ * l_ * l_, M = m_ * m_ * m_, S = s_ * s_ * s_
        // Linear sRGB, then linear Display P3 (wider, so P3 themes keep their richness).
        let rs = 4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S
        let gs = -1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S
        let bs = -0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S
        let rp = 0.8224621 * rs + 0.1775380 * gs
        let gp = 0.0331941 * rs + 0.9668058 * gs
        let bp = 0.0170827 * rs + 0.0723974 * gs + 0.9105199 * bs
        func encode(_ v: Double) -> Double {
            let x = min(max(v, 0), 1)
            return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        }
        return ColorValue(r: encode(rp), g: encode(gp), b: encode(bp), a: alpha)
    }

    /// sRGB components, converted to P3 so they render the same.
    static func srgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> ColorValue {
        let ns = NSColor(srgbRed: r, green: g, blue: b, alpha: a).usingColorSpace(.displayP3)
        return ColorValue(r: ns.map { Double($0.redComponent) } ?? r, g: ns.map { Double($0.greenComponent) } ?? g,
                          b: ns.map { Double($0.blueComponent) } ?? b, a: a)
    }

    static func parse(_ text: String) -> ColorValue? {
        let s = text.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasPrefix("#") {
            let hex = String(s.dropFirst())
            guard hex.count == 6 || hex.count == 8, let v = UInt64(hex, radix: 16) else { return nil }
            let has = hex.count == 8
            let r = Double((v >> (has ? 24 : 16)) & 0xff) / 255
            let g = Double((v >> (has ? 16 : 8)) & 0xff) / 255
            let b = Double((v >> (has ? 8 : 0)) & 0xff) / 255
            return .srgb(r, g, b, has ? Double(v & 0xff) / 255 : 1)
        }
        guard let open = s.firstIndex(of: "("), s.hasSuffix(")") else { return nil }
        let name = s[..<open]
        let body = s[s.index(after: open)..<s.index(before: s.endIndex)]
            .replacingOccurrences(of: ",", with: " ").replacingOccurrences(of: "/", with: " ")
        let parts = body.split(separator: " ").compactMap { part -> Double? in
            part.hasSuffix("%") ? Double(part.dropLast()).map { $0 / 100 } : Double(part)
        }
        switch name {
        case "oklch" where parts.count >= 3:
            return .oklch(parts[0], parts[1], parts[2], parts.count > 3 ? parts[3] : 1)
        case "rgb", "rgba":
            guard parts.count >= 3 else { return nil }
            return .srgb(parts[0] / 255, parts[1] / 255, parts[2] / 255, parts.count > 3 ? parts[3] : 1)
        default: return nil
        }
    }
}
