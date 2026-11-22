import CoreGraphics
import Foundation

/// Display brightness through DisplayServices, the private framework the
/// brightness keys use. It drives the built-in panel and Apple displays;
/// other monitors would need DDC.
public enum Brightness {
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private struct Services: @unchecked Sendable {
        // @unchecked: two immutable C function pointers.
        let get: Get
        let set: Set
    }

    private static let services: Services? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
              let get = dlsym(handle, "DisplayServicesGetBrightness"),
              let set = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        return Services(get: unsafeBitCast(get, to: Get.self), set: unsafeBitCast(set, to: Set.self))
    }()

    /// The display meant by "the screen": the built-in one when it's on,
    /// else the main display.
    static func target() -> CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        if CGGetActiveDisplayList(16, &ids, &count) == .success,
           let builtIn = ids.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) {
            return builtIn
        }
        return CGMainDisplayID()
    }

    /// 0–1, or nil when this display's brightness can't be read.
    public static var level: Double? {
        guard let services else { return nil }
        var value: Float = 0
        return services.get(target(), &value) == 0 ? Double(value) : nil
    }

    /// Sets brightness, 0–1.
    public static func set(_ level: Double) throws {
        guard let services else { throw LowtideError.denied("This Mac doesn't offer brightness control.") }
        guard services.set(target(), Float(min(max(level, 0), 1))) == 0 else {
            throw LowtideError.denied("This display doesn't let Lowtide change its brightness.")
        }
        Tools.changed()
    }
}
