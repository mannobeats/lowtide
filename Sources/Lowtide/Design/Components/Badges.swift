import SwiftUI

/// A state, always with a word: ok, needs a look (amber = act), broken (red).
enum Tone: Sendable {
    case neutral, brand, ok, warn, bad

    func color(_ p: Palette) -> ColorValue {
        switch self {
        case .neutral: p.ink3
        case .brand: p.brand
        case .ok: p.ok
        case .warn: p.warn
        case .bad: p.bad
        }
    }

    func soft(_ p: Palette) -> ColorValue {
        switch self {
        case .neutral: p.fill
        case .brand: p.brandSoft
        case .ok: p.okSoft
        case .warn: p.warnSoft
        case .bad: p.badSoft
        }
    }
}

struct Badge: View {
    @Environment(\.palette) private var palette
    let text: String
    var tone: Tone = .neutral
    var symbol: String?

    init(_ text: String, tone: Tone = .neutral, symbol: String? = nil) {
        self.text = text
        self.tone = tone
        self.symbol = symbol
    }

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
            Text(text).font(.ui(.xxs, .medium)).lineLimit(1)
        }
        .foregroundStyle((tone == .neutral ? palette.ink2 : tone.color(palette)).color)
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(tone.soft(palette).color, in: .rect(cornerRadius: Radius.sm))
    }
}

/// A small coloured dot that pulses while something is live.
struct StatusDot: View {
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var tone: Tone = .ok
    var pulsing = false
    @State private var phase = false

    var body: some View {
        Circle()
            .fill(tone.color(palette).color)
            .frame(width: 7, height: 7)
            .background {
                if pulsing && !reduceMotion {
                    Circle().fill(tone.color(palette).color)
                        .scaleEffect(phase ? 2.6 : 1).opacity(phase ? 0 : 0.5)
                        .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false), value: phase)
                }
            }
            .onAppear { phase = pulsing }
    }
}

/// A keyboard shortcut, drawn as keycaps.
struct KeyCap: View {
    @Environment(\.palette) private var palette
    let keys: String
    var body: some View {
        Text(keys)
            .font(.ui(.xxs, .medium))
            .foregroundStyle(palette.ink3.color)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(palette.fill.color, in: .rect(cornerRadius: Radius.sm - 2))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm - 2).strokeBorder(palette.line.color))
    }
}
