import Foundation
import IOKit

/// Small helpers over the IOKit registry: find entries of a class, read
/// their properties, release them.
enum IORegistry {
    /// Every registry entry of an IOKit class. The caller releases them
    /// (`release`), or uses `withServices`.
    static func services(_ className: String) -> [io_object_t] {
        var iterator: io_iterator_t = 0
        // IOServiceMatching's dictionary is consumed by the call.
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var out: [io_object_t] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 { out.append(entry) }
        return out
    }

    static func release(_ entries: [io_object_t]) {
        for entry in entries { IOObjectRelease(entry) }
    }

    /// Runs `body` over the entries of a class and releases them after.
    static func withServices<T>(_ className: String, _ body: ([io_object_t]) -> T) -> T {
        let entries = services(className)
        defer { release(entries) }
        return body(entries)
    }

    static func name(_ entry: io_object_t) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        IORegistryEntryGetName(entry, &buffer)
        return String(cBuffer: buffer)
    }

    /// All of an entry's properties (costly for big entries; prefer `property`).
    static func properties(_ entry: io_object_t) -> [String: Any]? {
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() else { return nil }
        return dict as? [String: Any]
    }

    /// One property of an entry.
    static func property(_ entry: io_object_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// The children of an entry in the service plane.
    static func children(_ entry: io_object_t) -> [io_object_t] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var out: [io_object_t] = []
        while case let child = IOIteratorNext(iterator), child != 0 { out.append(child) }
        return out
    }
}

/// `sysctlbyname` reads.
enum Sysctl {
    static func value<T>(_ name: String, as type: T.Type = T.self) -> T? {
        var size = MemoryLayout<T>.size
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard sysctlbyname(name, pointer, &size, nil, 0) == 0, size == MemoryLayout<T>.size else { return nil }
        return pointer.load(as: T.self)
    }

    /// An integer sysctl, whether the kernel answers in 4 or 8 bytes.
    static func int(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = 8
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        switch size {
        case 4: return Int64(Int32(truncatingIfNeeded: value))
        case 8: return value
        default: return nil
        }
    }

    static func string(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cBuffer: buffer)
    }
}

extension String {
    /// A NUL-terminated C buffer as text.
    init(cBuffer: [CChar]) {
        self = String(decoding: cBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
