import Foundation

/// An analytic damped spring, after Hex's `rune_hud/spring.rs`. The
/// closed-form step is exact for any `dt`, so motion is the same at 60, 120
/// or 240 Hz and a spring retargeted mid-flight keeps its momentum.
public struct HUDSpring: Sendable, Equatable {
    /// Seconds to settle and how much it overshoots, as SwiftUI's springs.
    public struct Spec: Sendable, Equatable {
        public var bounce: Double
        public var duration: Double
        public init(bounce: Double, duration: Double) {
            self.bounce = bounce
            self.duration = duration
        }

        /// Geometry: width, scale, the filament's span. A little bounce.
        public static let morph = Spec(bounce: 0.15, duration: 0.34)
        /// Opacity, blur and colour: the same time, no bounce.
        public static let fade = Spec(bounce: 0, duration: 0.3)
        /// Reduce Motion: every change is this crossfade.
        public static let reduced = Spec(bounce: 0, duration: 0.16)
        /// The filament's own ring: quick, a few visible swings.
        public static let ring = Spec(bounce: 0.5, duration: 0.2)
    }

    public var x: Double
    public var v: Double
    public var target: Double

    public init(_ x: Double) {
        self.x = x
        v = 0
        target = x
    }

    /// Snaps to `x` with no velocity (first paint, Reduce Motion).
    public mutating func jump(_ value: Double) {
        x = value
        v = 0
        target = value
    }

    /// Advances toward `target` by `dt` seconds.
    public mutating func step(_ spec: Spec, _ dt: Double) {
        guard dt > 0 else { return }
        let omega = 2 * Double.pi / max(spec.duration, 0.01)
        let zeta = spec.bounce >= 0 ? max(1 - spec.bounce, 0) : 1 / max(1 + spec.bounce, 0.01)
        let x0 = x - target
        let v0 = v
        if zeta < 1 - 1e-4 {
            let decay = zeta * omega
            let wd = omega * (1 - zeta * zeta).squareRoot()
            let e = exp(-decay * dt)
            let sn = sin(wd * dt), cs = cos(wd * dt)
            let sd = sn / wd
            x = target + e * (x0 * (cs + decay * sd) + v0 * sd)
            v = e * (-x0 * omega * omega * sd + v0 * (cs - decay * sd))
        } else if zeta > 1 + 1e-4 {
            let root = (zeta * zeta - 1).squareRoot()
            let slow = -omega / (zeta + root)
            let fast = -omega * (zeta + root)
            let d = slow - fast
            let es = exp(slow * dt), ef = exp(fast * dt)
            x = target + ((-fast * es + slow * ef) / d) * x0 + ((es - ef) / d) * v0
            v = ((slow * fast * (ef - es)) / d) * x0 + ((slow * es - fast * ef) / d) * v0
        } else {
            let e = exp(-omega * dt)
            let c = v0 + omega * x0
            x = target + (x0 + c * dt) * e
            v = (v0 - omega * c * dt) * e
        }
    }

    /// Come to rest on its target.
    public func settled(_ eps: Double = 1e-3) -> Bool {
        abs(x - target) < eps && abs(v) < eps * 10
    }
}

/// The overlay's filament: one bright thread pinned at both ends that your
/// voice plucks. Six standing modes ride analytic springs at a fixed 240 Hz,
/// so every syllable rings and settles the same at any frame rate; the
/// thread warms as it carries more energy. The level gets Hex's kind of
/// automatic gain (a peak with a slow release over a tracked room floor), so
/// a quiet voice moves it as much as a loud one.
public struct Filament: Sendable {
    /// The newest level from the helper, 0 to 1 ((dB + 55) / 55).
    public var input = 0.0
    /// Whether the voice drives it (recording), else it rests.
    public var live = false
    /// Reduce Motion: no ringing, the thread just swells with the voice.
    public var reduced = false
    /// The voice's smoothed, auto-gained level.
    public private(set) var energy = 0.0

    private var room = -48.0
    private var peak = -30.0
    private var carry = 0.0
    private var clock = 0.0
    private var modes = [HUDSpring](repeating: HUDSpring(0), count: Filament.shapes.count)

    public static let points = 72
    static let step = 1.0 / 240
    static let dbRange = 55.0
    static let noiseFloor = -50.0
    /// The gain never stretches less than this many dB to full.
    static let minSpan = 14.0
    /// How long the gain takes to forget a loud peak, s.
    static let release = 3.0
    /// How hard a syllable's onset plucks.
    static let pluck = 0.05
    /// Each mode: shape number, gain, how fast the voice turns it (Hz).
    static let shapes: [(Double, Double, Double)] = [
        (1, 0.3, 0.55), (2, 0.85, 1.3), (3, 0.62, 1.9), (4, 0.45, 2.6), (5, 0.3, 3.3), (6, 0.2, 4.1),
    ]

    public init() {}

    private static func follow(_ value: Double, _ target: Double, _ tau: Double, _ h: Double) -> Double {
        value + (target - value) * (1 - exp(-h / tau))
    }

    /// Runs the simulation forward by `dt` seconds in fixed steps.
    public mutating func advance(_ dt: Double) {
        carry += min(max(dt, 0), 0.1)
        while carry >= Self.step {
            carry -= Self.step
            tick(Self.step)
        }
    }

    private mutating func gain(_ h: Double) -> Double {
        let db = min(max(input, 0), 1) * Self.dbRange - Self.dbRange
        room = Self.follow(room, db, db < room ? 0.3 : 4, h)
        let floor = max(room, Self.noiseFloor)
        let lowest = floor + Self.minSpan
        peak = db > peak ? Self.follow(peak, db, 0.04, h) : Self.follow(peak, lowest, Self.release, h)
        peak = max(peak, lowest)
        let over = (db - floor - 2) / (peak - floor - 2)
        return min(max(over, 0), 1)
    }

    private mutating func tick(_ h: Double) {
        clock += h
        let target = live ? gain(h) : 0
        let before = energy
        energy = Self.follow(energy, target, target > energy ? 0.03 : 0.14, h)
        let rise = max(0, (energy - before) / h)
        // A held breath of motion so an armed thread is never dead flat.
        let drive = live ? 0.06 + energy * 0.94 : 0
        let t = clock
        for i in modes.indices {
            let (_, gain, hz) = Self.shapes[i]
            // Two slow beats per mode, so no two syllables look alike.
            let wobble = sin(t * hz * 2 * .pi + Double(i) * 1.7)
                * (0.65 + 0.35 * sin(t * (0.37 + Double(i) * 0.11) * 2 * .pi + Double(i)))
            modes[i].target = reduced ? 0 : drive * gain * wobble
            if !reduced { modes[i].v += rise * Self.pluck * gain * (i % 2 == 1 ? -1 : 1) }
            modes[i].step(.ring, h)
        }
    }

    /// The thread's shape: `points` offsets from the middle line for the
    /// bright swing and the faint second plane, within ±`room`.
    public func shape(room: Double) -> (main: [Double], depth: [Double]) {
        let swell = reduced ? energy * 0.8 : 0
        var main = [Double](repeating: 0, count: Self.points)
        var depth = [Double](repeating: 0, count: Self.points)
        for j in 0..<Self.points {
            let u = Double(j) / Double(Self.points - 1)
            let taper = pow(sin(.pi * u), 0.6)
            var y = swell * sin(.pi * u)
            var q = 0.0
            for i in modes.indices {
                let shape = sin(Self.shapes[i].0 * .pi * u)
                y += modes[i].x * shape
                q += modes[i].v * 0.025 * shape
            }
            main[j] = room * tanh(y * taper * 1.6)
            depth[j] = room * tanh(q * taper * 1.6)
        }
        return (main, depth)
    }

    /// How hot the thread runs, 0 to 1.
    public var heat: Double { min(1, energy * 1.1) }
}
