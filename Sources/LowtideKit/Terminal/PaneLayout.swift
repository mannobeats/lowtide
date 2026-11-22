import Foundation

/// Tiling for terminal panes, as in tmux: a tab holds a binary tree of
/// splits whose leaves are sessions. Pure values; the workspace keeps one
/// tree per tab.
public indirect enum PaneLayout: Equatable, Sendable, Codable {
    case leaf(String)
    case split(a: PaneLayout, b: PaneLayout, axis: Axis, ratio: Double)

    /// `row`: side by side (a vertical divider). `column`: stacked.
    public enum Axis: String, Sendable, Codable { case row, column }
    public enum Direction: Sendable, CaseIterable { case left, right, up, down }

    /// Fractions of the tab's area, 0–1.
    public struct Rect: Equatable, Sendable {
        public var x, y, w, h: Double
        public init(x: Double, y: Double, w: Double, h: Double) {
            self.x = x; self.y = y; self.w = w; self.h = h
        }
        public static let full = Rect(x: 0, y: 0, w: 1, h: 1)
    }

    public struct Divider: Equatable, Sendable {
        public let axis: Axis
        /// Where to find the split: "a"/"b" steps from the root.
        public let path: String
        public let ratio: Double
        /// The whole area the split divides.
        public let rect: Rect
    }

    static let minRatio = 0.1

    public var leaves: [String] {
        switch self {
        case .leaf(let id): [id]
        case .split(let a, let b, _, _): a.leaves + b.leaves
        }
    }

    public func contains(_ id: String) -> Bool {
        switch self {
        case .leaf(let leaf): leaf == id
        case .split(let a, let b, _, _): a.contains(id) || b.contains(id)
        }
    }

    /// Puts `newID` beside `target`, after it (right or below).
    public func splitting(_ target: String, axis: Axis, with newID: String) -> PaneLayout {
        switch self {
        case .leaf(let id):
            return id == target ? .split(a: self, b: .leaf(newID), axis: axis, ratio: 0.5) : self
        case .split(let a, let b, let dir, let ratio):
            return .split(a: a.splitting(target, axis: axis, with: newID), b: b.splitting(target, axis: axis, with: newID),
                          axis: dir, ratio: ratio)
        }
    }

    /// Removes a leaf; its sibling takes the parent's place. Nil when it was the last.
    public func removing(_ id: String) -> PaneLayout? {
        switch self {
        case .leaf(let leaf):
            return leaf == id ? nil : self
        case .split(let a, let b, let axis, let ratio):
            let na = a.removing(id), nb = b.removing(id)
            guard let na else { return nb }
            guard let nb else { return na }
            return .split(a: na, b: nb, axis: axis, ratio: ratio)
        }
    }

    public func settingRatio(at path: Substring, to value: Double) -> PaneLayout {
        guard case .split(let a, let b, let axis, let ratio) = self else { return self }
        guard let step = path.first else {
            return .split(a: a, b: b, axis: axis, ratio: min(1 - Self.minRatio, max(Self.minRatio, value)))
        }
        let rest = path.dropFirst()
        return step == "a"
            ? .split(a: a.settingRatio(at: rest, to: value), b: b, axis: axis, ratio: ratio)
            : .split(a: a, b: b.settingRatio(at: rest, to: value), axis: axis, ratio: ratio)
    }

    public func settingRatio(at path: String, to value: Double) -> PaneLayout {
        settingRatio(at: Substring(path), to: value)
    }

    /// Every pane the same size along each run of same-direction splits.
    public func equalized() -> PaneLayout {
        guard case .split(let a, let b, let axis, _) = self else { return self }
        func span(_ node: PaneLayout) -> Int {
            if case .split(let x, let y, let dir, _) = node, dir == axis { return span(x) + span(y) }
            return 1
        }
        let left = Double(span(a))
        return .split(a: a.equalized(), b: b.equalized(), axis: axis, ratio: left / (left + Double(span(b))))
    }

    /// Swaps two panes' places.
    public func swapping(_ x: String, _ y: String) -> PaneLayout {
        switch self {
        case .leaf(let id): id == x ? .leaf(y) : id == y ? .leaf(x) : self
        case .split(let a, let b, let axis, let ratio):
            .split(a: a.swapping(x, y), b: b.swapping(x, y), axis: axis, ratio: ratio)
        }
    }

    static func halves(_ rect: Rect, _ axis: Axis, _ ratio: Double) -> (Rect, Rect) {
        switch axis {
        case .row:
            let w = rect.w * ratio
            return (Rect(x: rect.x, y: rect.y, w: w, h: rect.h), Rect(x: rect.x + w, y: rect.y, w: rect.w - w, h: rect.h))
        case .column:
            let h = rect.h * ratio
            return (Rect(x: rect.x, y: rect.y, w: rect.w, h: h), Rect(x: rect.x, y: rect.y + h, w: rect.w, h: rect.h - h))
        }
    }

    /// Each pane's place, in layout order.
    public func rects(in rect: Rect = .full) -> [(id: String, rect: Rect)] {
        switch self {
        case .leaf(let id): return [(id, rect)]
        case .split(let a, let b, let axis, let ratio):
            let (ra, rb) = Self.halves(rect, axis, ratio)
            return a.rects(in: ra) + b.rects(in: rb)
        }
    }

    public func dividers(in rect: Rect = .full, path: String = "") -> [Divider] {
        guard case .split(let a, let b, let axis, let ratio) = self else { return [] }
        let (ra, rb) = Self.halves(rect, axis, ratio)
        return [Divider(axis: axis, path: path, ratio: ratio, rect: rect)]
            + a.dividers(in: ra, path: path + "a") + b.dividers(in: rb, path: path + "b")
    }

    /// The pane next to `from` in a direction: touching it, most overlap.
    public func neighbor(of from: String, _ direction: Direction) -> String? {
        let all = rects()
        guard let r = all.first(where: { $0.id == from })?.rect else { return nil }
        let eps = 1e-6
        var best: String?
        var bestScore = 0.0
        func overlap(_ a0: Double, _ a1: Double, _ b0: Double, _ b1: Double) -> Double { min(a1, b1) - max(a0, b0) }
        for (id, o) in all where id != from {
            let touching = switch direction {
            case .down: abs(o.y - (r.y + r.h)) < eps
            case .up: abs(o.y + o.h - r.y) < eps
            case .left: abs(o.x + o.w - r.x) < eps
            case .right: abs(o.x - (r.x + r.w)) < eps
            }
            let shared = direction == .left || direction == .right
                ? overlap(r.y, r.y + r.h, o.y, o.y + o.h)
                : overlap(r.x, r.x + r.w, o.x, o.x + o.w)
            if touching, shared > bestScore + eps {
                best = id
                bestScore = shared
            }
        }
        return best
    }

    /// Path to the nearest split above `id` that runs along `axis`.
    func ancestor(of id: String, along axis: Axis, path: String = "") -> String? {
        guard case .split(let a, let b, let dir, _) = self else { return nil }
        let side = a.contains(id) ? "a" : "b"
        if let deeper = (side == "a" ? a : b).ancestor(of: id, along: axis, path: path + side) { return deeper }
        return dir == axis && contains(id) ? path : nil
    }

    func node(at path: String) -> PaneLayout {
        var current = self
        for step in path {
            guard case .split(let a, let b, _, _) = current else { break }
            current = step == "a" ? a : b
        }
        return current
    }

    /// Moves the edge of `id` that faces `direction` by `delta` of the split.
    public func nudging(_ id: String, _ direction: Direction, by delta: Double) -> PaneLayout {
        let axis: Axis = direction == .left || direction == .right ? .row : .column
        guard let path = ancestor(of: id, along: axis),
              case .split(_, _, _, let ratio) = node(at: path) else { return self }
        let grow = direction == .right || direction == .down ? delta : -delta
        return settingRatio(at: path, to: ratio + grow)
    }
}
