import SwiftUI

/// Type scale for SF (macOS sizes, not web sizes). Body is 13.
enum TextSize: CGFloat {
    case xxs = 11, xs = 12, sm = 13, md = 14, base = 15, lg = 17, xl = 22, xxl = 26, display = 36
}

extension Font {
    /// UI text at a step of the scale.
    static func ui(_ size: TextSize, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size.rawValue, weight: weight)
    }
    /// Page titles and a hero's sentence: SF Pro Display, semibold.
    static func title(_ size: TextSize = .xl) -> Font {
        .system(size: size.rawValue, weight: .semibold, design: .default)
    }
    /// Code, paths, hostnames, versions and columns of numbers.
    static func mono(_ size: TextSize = .xs, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size.rawValue, weight: weight, design: .monospaced)
    }
}

/// Corners: chips 6, controls and rows 8, lists and panes 12, sheets and hero tiles 16,
/// the content card 14.
enum Radius {
    static let sm: CGFloat = 6
    static let md: CGFloat = 8
    static let lg: CGFloat = 12
    static let sheet: CGFloat = 14
    static let xl: CGFloat = 16
}

/// A 4-point grid.
enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 28
    static let page: CGFloat = 24
}

/// Motion. The spring settles (response 0.3 s, bounce 0.15), never wobbles.
/// Under Reduce Motion movement goes and fades stay: use `Motion.spring(reduce)`.
enum Motion {
    static let spring = Animation.spring(duration: 0.3, bounce: 0.15)
    static let fast = Animation.easeOut(duration: 0.14)
    static let base = Animation.easeOut(duration: 0.22)
    static let slow = Animation.easeOut(duration: 0.36)
    static let page = Animation.easeOut(duration: 0.18)

    static func spring(_ reduce: Bool) -> Animation { reduce ? .easeOut(duration: 0.14) : spring }
}
