import Foundation
import IOKit

/// Temperatures from the HID sensor hub: the fallback when the SMC lists
/// none. The event-system client functions are exported by IOKit but not
/// declared in its headers, so they're looked up at run time.
final class HIDThermals {
    private typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias FloatValue = @convention(c) (AnyObject, Int64) -> Double

    private static let temperatureEvent: Int64 = 15

    private let client: AnyObject
    private let copyServices: CopyServices
    private let copyProperty: CopyProperty
    private let copyEvent: CopyEvent
    private let floatValue: FloatValue

    init?() {
        let handle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        func load<T>(_ name: String, _: T.Type) -> T? { dlsym(handle, name).map { unsafeBitCast($0, to: T.self) } }
        guard let create = load("IOHIDEventSystemClientCreate", Create.self),
              let setMatching = load("IOHIDEventSystemClientSetMatching", SetMatching.self),
              let copyServices = load("IOHIDEventSystemClientCopyServices", CopyServices.self),
              let copyProperty = load("IOHIDServiceClientCopyProperty", CopyProperty.self),
              let copyEvent = load("IOHIDServiceClientCopyEvent", CopyEvent.self),
              let floatValue = load("IOHIDEventGetFloatValue", FloatValue.self),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue()
        else { return nil }
        // Apple vendor page 0xff00, usage 5: temperature sensors.
        _ = setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        self.client = client
        self.copyServices = copyServices
        self.copyProperty = copyProperty
        self.copyEvent = copyEvent
        self.floatValue = floatValue
    }

    func read() -> [Sensor] {
        guard let services = copyServices(client)?.takeRetainedValue() as? [AnyObject] else { return [] }
        var out: [Sensor] = []
        for service in services {
            guard let label = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String,
                  let event = copyEvent(service, Self.temperatureEvent, 0, 0)?.takeRetainedValue()
            else { continue }
            let celsius = floatValue(event, Self.temperatureEvent << 16)
            // Freshly booted sensors can report a few degrees; not real.
            guard (10..<130).contains(celsius) else { continue }
            out.append(Sensor(name: SensorNames.hidName(label), kind: SensorNames.hidKind(label), celsius: celsius))
        }
        // Several hub services can share a product name: average them.
        var merged: [String: (Sensor, Int)] = [:]
        for sensor in out {
            if let (seen, n) = merged[sensor.name] {
                var avg = seen
                avg.celsius = (seen.celsius * Double(n) + sensor.celsius) / Double(n + 1)
                merged[sensor.name] = (avg, n + 1)
            } else {
                merged[sensor.name] = (sensor, 1)
            }
        }
        return merged.values.map(\.0).sorted { ($0.kind.order, $0.name) < ($1.kind.order, $1.name) }
    }
}
