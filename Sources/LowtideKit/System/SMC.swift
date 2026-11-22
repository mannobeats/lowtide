import Foundation
import IOKit

/// The System Management Controller (AppleSMC): every temperature sensor,
/// the fans and the whole Mac's power draw, readable without root.
///
/// The driver takes an 80-byte `SMCKeyData_t`. Its nested structs have tail
/// padding Swift would pack differently, so the struct is a byte buffer with
/// the C offsets spelled out.
final class SMC {
    private let connection: io_connect_t

    private enum Offset {
        static let key = 0
        static let dataSize = 28
        static let dataType = 32
        static let result = 40
        static let data8 = 42
        static let data32 = 44
        static let bytes = 48
        static let size = 80
    }

    private enum Command: UInt8 {
        case readBytes = 5
        case readIndex = 8
        case readKeyInfo = 9
    }

    init?() {
        let entries = IORegistry.services("AppleSMC")
        defer { IORegistry.release(entries) }
        guard let first = entries.first else { return nil }
        var connection: io_connect_t = 0
        guard IOServiceOpen(first, mach_task_self_, 0, &connection) == KERN_SUCCESS, connection != 0 else { return nil }
        self.connection = connection
    }

    deinit { IOServiceClose(connection) }

    static func fourCC(_ key: String) -> UInt32 {
        key.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    private func call(_ input: [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: Offset.size)
        var size = Offset.size
        let status = input.withUnsafeBytes { inBytes in
            output.withUnsafeMutableBytes { outBytes in
                IOConnectCallStructMethod(connection, 2, inBytes.baseAddress, Offset.size, outBytes.baseAddress, &size)
            }
        }
        return status == KERN_SUCCESS && output[Offset.result] == 0 ? output : nil
    }

    private static func put(_ value: UInt32, at offset: Int, in buffer: inout [UInt8]) {
        withUnsafeBytes(of: value) { for (i, b) in $0.enumerated() { buffer[offset + i] = b } }
    }

    private static func get(at offset: Int, in buffer: [UInt8]) -> UInt32 {
        buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }

    /// A key's size and type.
    private func info(_ key: String) -> (size: Int, type: UInt32)? {
        var input = [UInt8](repeating: 0, count: Offset.size)
        Self.put(Self.fourCC(key), at: Offset.key, in: &input)
        input[Offset.data8] = Command.readKeyInfo.rawValue
        guard let out = call(input) else { return nil }
        return (Int(Self.get(at: Offset.dataSize, in: out)), Self.get(at: Offset.dataType, in: out))
    }

    /// A key's value as a number (`flt `, `ui8 `, `ui16`, `ui32`).
    func read(_ key: String) -> Double? {
        guard let info = info(key) else { return nil }
        var input = [UInt8](repeating: 0, count: Offset.size)
        Self.put(Self.fourCC(key), at: Offset.key, in: &input)
        Self.put(UInt32(info.size), at: Offset.dataSize, in: &input)
        input[Offset.data8] = Command.readBytes.rawValue
        guard let out = call(input) else { return nil }
        return Self.decode(Array(out[Offset.bytes..<Offset.bytes + 32]), size: info.size, type: info.type)
    }

    static func decode(_ bytes: [UInt8], size: Int, type: UInt32) -> Double? {
        switch type {
        case fourCC("flt ") where size >= 4:
            return Double(Float(bitPattern: UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24))
        case fourCC("ui8 "):
            return Double(bytes[0])
        case fourCC("ui16"):
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case fourCC("ui32"):
            return Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        default:
            return nil
        }
    }

    private func key(at index: UInt32) -> String? {
        var input = [UInt8](repeating: 0, count: Offset.size)
        input[Offset.data8] = Command.readIndex.rawValue
        Self.put(index, at: Offset.data32, in: &input)
        guard let out = call(input) else { return nil }
        let raw = Self.get(at: Offset.key, in: out)
        let bytes = [UInt8(raw >> 24 & 0xff), UInt8(raw >> 16 & 0xff), UInt8(raw >> 8 & 0xff), UInt8(raw & 0xff)]
        return String(bytes: bytes, encoding: .ascii)
    }

    /// Every temperature key this Mac's SMC offers (`T…`, floats). Slow-ish
    /// (two calls per key): read once and kept.
    func temperatureKeys() -> [String] {
        let count = UInt32(read("#KEY") ?? 0)
        let flt = Self.fourCC("flt ")
        return (0..<min(count, 4000)).compactMap { key(at: $0) }
            .filter { $0.hasPrefix("T") && info($0)?.type == flt }
    }

    func temperatures(_ keys: [String]) -> [Sensor] {
        keys.compactMap { key -> Sensor? in
            guard let celsius = read(key), (10..<130).contains(celsius) else { return nil }
            let (kind, label) = SensorNames.smc(key)
            return Sensor(name: "\(label) · \(key)", kind: kind, celsius: celsius)
        }
        .sorted { ($0.kind.order, $0.name) < ($1.kind.order, $1.name) }
    }

    func fans() -> [Fan] {
        let count = Int(read("FNum") ?? 0)
        return (0..<min(count, 4)).compactMap { i in
            guard let rpm = read("F\(i)Ac") else { return nil }
            return Fan(rpm: rpm, min: read("F\(i)Mn") ?? 0, max: read("F\(i)Mx") ?? 0)
        }
    }

    /// The whole Mac's draw in watts.
    func systemPower() -> Double? { read("PSTR") }
}

extension Sensor.Kind {
    /// Groups in the order the Sensors page lists them.
    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// What a sensor measures, from its SMC key or HID product name.
enum SensorNames {
    /// An SMC temperature key's kind and a readable label, by its prefix.
    static func smc(_ key: String) -> (Sensor.Kind, String) {
        let chars = Array(key)
        let c1 = chars.count > 1 ? chars[1] : " "
        let c2 = chars.count > 2 ? chars[2] : " "
        switch (c1, c2) {
        case ("C", "M"), ("C", "D"): return (.cpu, "CPU die")
        case ("P", _): return (.soc, "SoC package")
        case ("R", _), ("g", _): return (.gpu, "GPU")
        case ("p", _), ("f", _): return (.cpu, "Performance core")
        case ("e", _): return (.cpu, "Efficiency core")
        case ("C", _), ("c", _): return (.cpu, "CPU core")
        case ("m", _), ("M", _): return (.memory, "Memory")
        case ("s", _), ("S", _), ("H", _), ("N", _): return (.storage, "SSD")
        case ("a", _), ("A", _), ("F", _): return (.other, "Airflow")
        // TB0T, TB1T…: the battery cells.
        case ("B", _): return (.battery, "Battery")
        case ("b", _): return (.other, "Board")
        case ("V", _): return (.other, "Power regulator")
        case ("T", _), ("I", _): return (.other, "Thunderbolt")
        case ("w", _), ("W", _): return (.other, "Wireless")
        case ("D", _), ("d", _), ("L", _): return (.other, "Display")
        default: return (.other, "Sensor")
        }
    }

    /// A HID sensor hub product name's kind.
    static func hidKind(_ label: String) -> Sensor.Kind {
        let l = label.lowercased()
        if l.contains("pacc") || l.contains("eacc") || l.contains("cpu") { return .cpu }
        if l.contains("gpu") { return .gpu }
        if l.contains("nand") || l.contains("ssd") { return .storage }
        if l.contains("gas gauge") || l.contains("battery") { return .battery }
        if l.contains("tdie") || l.contains("soc") || l.contains("pmu") { return .soc }
        if l.contains("dram") || l.contains("mem") { return .memory }
        return .other
    }

    /// `pACC MTR Temp Sensor3` reads as "Performance cores 3".
    static func hidName(_ label: String) -> String {
        let digits = String(label.reversed().prefix { $0.isNumber }.reversed())
        func with(_ base: String) -> String { digits.isEmpty ? base : "\(base) \(digits)" }
        let l = label.lowercased()
        if l.hasPrefix("pacc") { return with("Performance cores") }
        if l.hasPrefix("eacc") { return with("Efficiency cores") }
        if l.hasPrefix("gpu") { return with("GPU") }
        if l.hasPrefix("nand") { return "SSD" }
        if l.contains("gas gauge") { return "Battery" }
        if l.contains("tdie") { return with("SoC die") }
        return label
    }
}
