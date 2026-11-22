import AppKit

/// The screen colour picker: macOS's own magnifier loupe (NSColorSampler).
/// Needs no Screen Recording permission.
@MainActor
public enum ColorPicker {
    public struct Picked: Sendable, Equatable {
        /// `#RRGGBB`, sRGB.
        public let hex: String
        public let r: UInt8, g: UInt8, b: UInt8

        public init(r: Double, g: Double, b: Double) {
            func channel(_ v: Double) -> UInt8 { UInt8((min(max(v, 0), 1) * 255).rounded()) }
            self.r = channel(r)
            self.g = channel(g)
            self.b = channel(b)
            hex = String(format: "#%02X%02X%02X", self.r, self.g, self.b)
        }
    }

    private static var sampler: NSColorSampler?

    /// Shows the loupe; copies the colour clicked as hex and returns it, or
    /// nil on Escape.
    public static func pick(copy: Bool = true) async -> Picked? {
        await withCheckedContinuation { continuation in
            let sampler = NSColorSampler()
            Self.sampler = sampler
            sampler.show { color in
                MainActor.assumeIsolated {
                    Self.sampler = nil
                    guard let srgb = color?.usingColorSpace(.sRGB) else { return continuation.resume(returning: nil) }
                    let picked = Picked(r: srgb.redComponent, g: srgb.greenComponent, b: srgb.blueComponent)
                    if copy {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(picked.hex, forType: .string)
                    }
                    continuation.resume(returning: picked)
                }
            }
        }
    }
}
