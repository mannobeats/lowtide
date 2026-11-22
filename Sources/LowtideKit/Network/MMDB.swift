import Foundation

/// A value from a MaxMind DB data section.
public enum MMDBValue: Sendable, Equatable {
    case string(String)
    case double(Double)
    case float(Float)
    case bytes([UInt8])
    case uint(UInt64)
    case int(Int32)
    case bool(Bool)
    case map([String: MMDBValue])
    case array([MMDBValue])

    public subscript(_ key: String) -> MMDBValue? {
        if case .map(let map) = self { return map[key] }
        return nil
    }

    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var uint: UInt64? { if case .uint(let n) = self { n } else { nil } }
}

/// A reader for MaxMind DB files (the format DB-IP's free databases ship
/// in), memory-mapped: the binary search tree over the address bits, then
/// the data section the tree's leaves point into.
/// https://maxmind.github.io/MaxMind-DB/
public struct MMDBReader: Sendable {
    public enum Failure: Error, Equatable { case notMMDB, unsupported(String), corrupt }

    private let data: Data
    public let nodeCount: Int
    public let recordSize: Int
    public let ipVersion: Int
    public let databaseType: String
    private let nodeBytes: Int
    private let treeSize: Int
    private let dataStart: Int
    /// The node an IPv4 lookup starts from in an IPv6 tree (after 96 zero bits).
    private let ipv4Start: Int

    private static let marker: [UInt8] = [0xAB, 0xCD, 0xEF] + Array("MaxMind.com".utf8)

    public init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    public init(data: Data) throws {
        self.data = data
        // The metadata sits after the last marker, within the final 128 KB.
        let found: Int? = data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let marker = Self.marker
            let floor = max(0, bytes.count - 128 * 1024)
            var i = bytes.count - marker.count
            while i >= floor {
                if bytes[i] == marker[0], bytes[i + 1] == marker[1], bytes[i + 2] == marker[2] {
                    var hit = true
                    for k in 3..<marker.count where bytes[i + k] != marker[k] { hit = false; break }
                    if hit { return i + marker.count }
                }
                i -= 1
            }
            return nil
        }
        guard let metaStart = found else { throw Failure.notMMDB }
        var decoder = Decoder(data: data, base: metaStart)
        guard case .map(let meta) = try decoder.decode(at: metaStart).value else { throw Failure.corrupt }
        guard let nodes = meta["node_count"]?.uint, let size = meta["record_size"]?.uint,
              let version = meta["ip_version"]?.uint else { throw Failure.corrupt }
        guard [24, 28, 32].contains(size) else { throw Failure.unsupported("record size \(size)") }
        nodeCount = Int(nodes)
        recordSize = Int(size)
        ipVersion = Int(version)
        databaseType = meta["database_type"]?.string ?? ""
        nodeBytes = recordSize * 2 / 8
        treeSize = nodeCount * nodeBytes
        dataStart = treeSize + 16
        guard dataStart <= metaStart else { throw Failure.corrupt }
        var start = 0
        if ipVersion == 6 {
            for _ in 0..<96 where start < nodeCount {
                start = Self.record(data, node: start, right: false, nodeBytes: nodeBytes, recordSize: recordSize)
            }
        }
        ipv4Start = start
    }

    /// The record for an address (`8.8.8.8`, `2606:4700::1111`), or nil
    /// when the database has nothing for it.
    public func lookup(_ address: String) -> MMDBValue? {
        guard let offset = offset(for: address) else { return nil }
        var decoder = Decoder(data: data, base: dataStart)
        return try? decoder.decode(at: dataStart + offset).value
    }

    /// One value inside the record, decoding only what lies on `path`
    /// (`["country", "iso_code"]`): a country record carries names in eight
    /// languages that a lookup never needs.
    public func lookup(_ address: String, path: [String]) -> MMDBValue? {
        guard let offset = offset(for: address) else { return nil }
        var decoder = Decoder(data: data, base: dataStart)
        return try? decoder.find(at: dataStart + offset, path: path[...])
    }

    /// Where the address's record starts in the data section.
    func offset(for address: String) -> Int? {
        guard let bits = Self.parse(address) else { return nil }
        if bits.count == 16, ipVersion != 6 { return nil }
        var node = bits.count == 4 && ipVersion == 6 ? ipv4Start : 0
        let total = bits.count * 8
        var i = 0
        while i < total, node < nodeCount {
            let bit = (bits[i >> 3] >> (7 - UInt8(i & 7))) & 1
            node = Self.record(data, node: node, right: bit == 1, nodeBytes: nodeBytes, recordSize: recordSize)
            i += 1
        }
        guard node > nodeCount else { return nil }
        let resolved = node - nodeCount - 16
        guard resolved >= 0, dataStart + resolved < data.count else { return nil }
        return resolved
    }

    private static func record(_ data: Data, node: Int, right: Bool, nodeBytes: Int, recordSize: Int) -> Int {
        data.withUnsafeBytes { raw -> Int in
            let b = raw.bindMemory(to: UInt8.self)
            let base = node * nodeBytes
            // Off the end of the file: treat as "no record".
            guard base + nodeBytes <= b.count else { return 0 }
            func be(_ at: Int, _ n: Int) -> Int {
                var v = 0
                for k in 0..<n { v = v << 8 | Int(b[at + k]) }
                return v
            }
            switch recordSize {
            case 24:
                return be(base + (right ? 3 : 0), 3)
            case 28:
                let middle = Int(b[base + 3])
                return right ? (middle & 0x0F) << 24 | be(base + 4, 3) : (middle & 0xF0) << 20 | be(base, 3)
            default:
                return be(base + (right ? 4 : 0), 4)
            }
        }
    }

    /// The address's bytes: 4 for IPv4, 16 for IPv6. A zone (`%en0`) is dropped.
    public static func parse(_ address: String) -> [UInt8]? {
        let plain = address.split(separator: "%", maxSplits: 1).first.map(String.init) ?? address
        var v4 = in_addr()
        if inet_pton(AF_INET, plain, &v4) == 1 {
            return withUnsafeBytes(of: &v4) { Array($0) }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, plain, &v6) == 1 {
            return withUnsafeBytes(of: &v6) { Array($0) }
        }
        return nil
    }

    /// The data section decoder. `base` is where pointers count from.
    struct Decoder {
        let data: Data
        let base: Int
        private var depth = 0

        init(data: Data, base: Int) {
            self.data = data
            self.base = base
        }

        private func byte(_ at: Int) throws -> UInt8 {
            guard at >= 0, at < data.count else { throw Failure.corrupt }
            return data.withUnsafeBytes { $0[at] }
        }

        private func uint(_ at: Int, _ n: Int) throws -> UInt64 {
            guard at >= 0, n >= 0, at + n <= data.count else { throw Failure.corrupt }
            return data.withUnsafeBytes { raw in
                var v: UInt64 = 0
                for k in 0..<n { v = v << 8 | UInt64(raw[at + k]) }
                return v
            }
        }

        /// The control byte at `offset`: type, size, and where the payload starts.
        private func control(_ offset: Int) throws -> (type: Int, size: Int, payload: Int) {
            let ctrl = try byte(offset)
            var type = Int(ctrl >> 5)
            var at = offset + 1
            if type == 1 {
                // A pointer: its size bits are part of the address.
                return (1, Int(ctrl & 0x1F), at)
            }
            if type == 0 {
                type = 7 + Int(try byte(at))
                at += 1
            }
            var size = Int(ctrl & 0x1F)
            switch size {
            case 29:
                size = 29 + Int(try byte(at)); at += 1
            case 30:
                size = 285 + Int(try uint(at, 2)); at += 2
            case 31:
                size = 65_821 + Int(try uint(at, 3)); at += 3
            default: break
            }
            return (type, size, at)
        }

        /// A pointer's target and the offset after it.
        private func pointer(_ sizeBits: Int, at: Int) throws -> (target: Int, next: Int) {
            let ss = (sizeBits >> 3) & 0x3
            let vvv = sizeBits & 0x7
            switch ss {
            case 0: return (base + (vvv << 8 | Int(try byte(at))), at + 1)
            case 1: return (base + (vvv << 16 | Int(try uint(at, 2))) + 2048, at + 2)
            case 2: return (base + (vvv << 24 | Int(try uint(at, 3))) + 526_336, at + 3)
            default: return (base + Int(try uint(at, 4)), at + 4)
            }
        }

        mutating func decode(at offset: Int) throws -> (value: MMDBValue, next: Int) {
            depth += 1
            defer { depth -= 1 }
            guard depth < 64 else { throw Failure.corrupt }
            let (type, size, at) = try control(offset)
            switch type {
            case 1:
                let (target, next) = try pointer(size, at: at)
                // A pointer never points at a pointer.
                guard try (byte(target) >> 5) != 1 else { throw Failure.corrupt }
                return (try decode(at: target).value, next)
            case 2:
                guard at + size <= data.count else { throw Failure.corrupt }
                let text = String(decoding: data[at..<at + size], as: UTF8.self)
                return (.string(text), at + size)
            case 3:
                guard size == 8 else { throw Failure.corrupt }
                return (.double(Double(bitPattern: try uint(at, 8))), at + 8)
            case 4:
                guard at + size <= data.count else { throw Failure.corrupt }
                return (.bytes(Array(data[at..<at + size])), at + size)
            case 5, 6, 9:
                guard size <= 8 else { throw Failure.corrupt }
                return (.uint(try uint(at, size)), at + size)
            case 10:
                guard size <= 16 else { throw Failure.corrupt }
                // 128-bit: the low 64 bits are enough for anything shown.
                let low = size > 8 ? try uint(at + size - 8, 8) : try uint(at, size)
                return (.uint(low), at + size)
            case 7:
                var map: [String: MMDBValue] = [:]
                var next = at
                for _ in 0..<size {
                    let key = try decode(at: next)
                    guard case .string(let name) = key.value else { throw Failure.corrupt }
                    let value = try decode(at: key.next)
                    map[name] = value.value
                    next = value.next
                }
                return (.map(map), next)
            case 8:
                guard size <= 4 else { throw Failure.corrupt }
                let raw = UInt32(truncatingIfNeeded: try uint(at, size))
                // Shorter encodings are zero-padded, so the sign only lives in a full 4 bytes.
                return (.int(Int32(bitPattern: raw)), at + size)
            case 11:
                var items: [MMDBValue] = []
                var next = at
                for _ in 0..<size {
                    let item = try decode(at: next)
                    items.append(item.value)
                    next = item.next
                }
                return (.array(items), next)
            case 14:
                return (.bool(size != 0), at)
            case 15:
                guard size == 4 else { throw Failure.corrupt }
                return (.float(Float(bitPattern: UInt32(try uint(at, 4)))), at + 4)
            default:
                throw Failure.unsupported("type \(type)")
            }
        }

        /// The offset after the value at `offset`, without building it.
        mutating func skip(at offset: Int) throws -> Int {
            depth += 1
            defer { depth -= 1 }
            guard depth < 64 else { throw Failure.corrupt }
            let (type, size, at) = try control(offset)
            switch type {
            case 1: return try pointer(size, at: at).next
            case 7:
                var next = at
                for _ in 0..<size {
                    next = try skip(at: next)
                    next = try skip(at: next)
                }
                return next
            case 11:
                var next = at
                for _ in 0..<size { next = try skip(at: next) }
                return next
            case 14: return at
            default: return at + size
            }
        }

        /// Follows `path` through maps, decoding only the value at its end.
        mutating func find(at offset: Int, path: ArraySlice<String>) throws -> MMDBValue? {
            guard let key = path.first else { return try decode(at: offset).value }
            depth += 1
            defer { depth -= 1 }
            guard depth < 64 else { throw Failure.corrupt }
            let (type, size, at) = try control(offset)
            if type == 1 { return try find(at: try pointer(size, at: at).target, path: path) }
            guard type == 7 else { return nil }
            var next = at
            for _ in 0..<size {
                let name = try decode(at: next)
                if case .string(let text) = name.value, text == key {
                    return try find(at: name.next, path: path.dropFirst())
                }
                next = try skip(at: name.next)
            }
            return nil
        }
    }
}
