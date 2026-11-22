import Foundation

/// The current state of a privacy permission, read without prompting, from
/// TCC's `TCCAccessPreflight` (private, loaded at run time; nil when it's
/// missing or macOS can't tell).
public enum TCCPreflight {
    private typealias Function = @convention(c) (CFString, CFDictionary?) -> Int

    private static let function: Function? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_LAZY),
              let symbol = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(symbol, to: Function.self)
    }()

    /// true allowed, false refused or never asked, nil unknown.
    public static func state(_ service: String) -> Bool? {
        guard let function else { return nil }
        switch function(service as CFString, nil) {
        case 0: return true
        case 1, 2: return false
        default: return nil
        }
    }
}
