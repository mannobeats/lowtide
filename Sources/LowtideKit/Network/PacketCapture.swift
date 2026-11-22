import Darwin
import Foundation
import Synchronization

/// The system libpcap, called through `dlsym` with C function types (it's
/// linked into the app; no Swift module ships for it).
enum PCap {
    typealias Handle = OpaquePointer
    typealias Raw = UnsafeMutableRawPointer

    // Pointer-sized offsets in the C structs (arm64 and x86_64 alike):
    // pcap_if { next, name, description, addresses, flags },
    // pcap_addr { next, addr, netmask, broadaddr, dstaddr },
    // pcap_pkthdr { timeval ts (16), caplen, len }, pcap_stat { recv, drop, ifdrop }.
    private static let word = MemoryLayout<UnsafeRawPointer>.size

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        // dlopen is reference-counted: the same handle each time.
        guard let library = dlopen("/usr/lib/libpcap.A.dylib", RTLD_NOW) ?? dlopen(nil, RTLD_NOW),
              let raw = dlsym(library, name) else { return nil }
        return unsafeBitCast(raw, to: type)
    }

    static let findAllDevs = symbol("pcap_findalldevs", as: (@convention(c) (UnsafeMutablePointer<Raw?>, UnsafeMutablePointer<CChar>) -> Int32).self)
    static let freeAllDevs = symbol("pcap_freealldevs", as: (@convention(c) (Raw?) -> Void).self)
    static let create = symbol("pcap_create", as: (@convention(c) (UnsafePointer<CChar>, UnsafeMutablePointer<CChar>) -> Handle?).self)
    static let setSnaplen = symbol("pcap_set_snaplen", as: (@convention(c) (Handle, Int32) -> Int32).self)
    static let setPromisc = symbol("pcap_set_promisc", as: (@convention(c) (Handle, Int32) -> Int32).self)
    static let setTimeout = symbol("pcap_set_timeout", as: (@convention(c) (Handle, Int32) -> Int32).self)
    static let setImmediate = symbol("pcap_set_immediate_mode", as: (@convention(c) (Handle, Int32) -> Int32).self)
    static let activate = symbol("pcap_activate", as: (@convention(c) (Handle) -> Int32).self)
    static let nextEx = symbol("pcap_next_ex",
        as: (@convention(c) (Handle, UnsafeMutablePointer<Raw?>, UnsafeMutablePointer<UnsafePointer<UInt8>?>) -> Int32).self)
    static let datalink = symbol("pcap_datalink", as: (@convention(c) (Handle) -> Int32).self)
    static let stats = symbol("pcap_stats", as: (@convention(c) (Handle, UnsafeMutablePointer<UInt32>) -> Int32).self)
    static let close = symbol("pcap_close", as: (@convention(c) (Handle) -> Void).self)
    static let geterr = symbol("pcap_geterr", as: (@convention(c) (Handle) -> UnsafeMutablePointer<CChar>?).self)

    /// A captured frame's header: when, how much was kept, how long it was.
    static func header(_ raw: Raw) -> (t: Millis, caplen: Int, length: Int) {
        let seconds = raw.load(as: Int.self)
        let micros = raw.load(fromByteOffset: word, as: Int32.self)
        return (Millis(seconds) * 1000 + Millis(micros) / 1000,
                Int(raw.load(fromByteOffset: 16, as: UInt32.self)), Int(raw.load(fromByteOffset: 20, as: UInt32.self)))
    }

    private static func pointer(_ raw: Raw, _ index: Int) -> Raw? {
        raw.load(fromByteOffset: index * word, as: Raw?.self)
    }

    /// Interfaces with an address, other than loopback, and their addresses.
    static func interfaces() -> [(name: String, addresses: [String])] {
        guard let findAllDevs, let freeAllDevs else { return [] }
        var list: Raw?
        var error = [CChar](repeating: 0, count: 256)
        guard findAllDevs(&list, &error) == 0 else { return [] }
        defer { freeAllDevs(list) }
        var out: [(String, [String])] = []
        var cursor = list
        while let entry = cursor {
            let name = pointer(entry, 1).map { String(cString: $0.assumingMemoryBound(to: CChar.self)) } ?? ""
            var addresses: [String] = []
            var address = pointer(entry, 3)
            while let item = address {
                if let sa = pointer(item, 1), let text = text(sa) { addresses.append(text) }
                address = pointer(item, 0)
            }
            if !addresses.isEmpty, name != "lo0" { out.append((name, addresses)) }
            cursor = pointer(entry, 0)
        }
        return out
    }

    static func text(_ raw: Raw) -> String? {
        let sa = raw.assumingMemoryBound(to: sockaddr.self)
        switch Int32(sa.pointee.sa_family) {
        case AF_INET:
            return raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { v4 in
                withUnsafeBytes(of: v4.pointee.sin_addr) { PacketDecoder.addressText(Array($0)) }
            }
        case AF_INET6:
            return raw.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { v6 in
                withUnsafeBytes(of: v6.pointee.sin6_addr) { PacketDecoder.addressText(Array($0)) }
            }
        default:
            return nil
        }
    }
}

/// A capture running on one interface, on its own thread: libpcap's read
/// blocks (200 ms at most, so a stop is noticed quickly).
final class CaptureSession: Sendable {
    struct Packet: Sendable {
        var t: Millis
        var length: Int
        var link: Int32
        var bytes: [UInt8]
    }

    let interface: String
    let local: Set<String>
    private let stopFlag = Atomic<Bool>(false)
    private let running = Atomic<Bool>(false)
    let stats = Mutex<(received: Int, dropped: Int, error: String?)>((0, 0, nil))

    /// Bytes of each frame kept: enough for every header and a TLS hello's start.
    static let snaplen: Int32 = 2048

    init(interface: String, local: Set<String>) {
        self.interface = interface
        self.local = local
    }

    var isRunning: Bool { running.load(ordering: .relaxed) }

    /// Opens the device; throws when this user can't read `/dev/bpf*`.
    func start(onPacket: @escaping @Sendable (Packet) -> Void) throws {
        guard let create = PCap.create, let activate = PCap.activate, let close = PCap.close else {
            throw LowtideError.commandFailed("libpcap isn't available")
        }
        var error = [CChar](repeating: 0, count: 256)
        guard let handle = interface.withCString({ create($0, &error) }) else {
            throw LowtideError.commandFailed(String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        _ = PCap.setSnaplen?(handle, Self.snaplen)
        _ = PCap.setPromisc?(handle, 0)
        _ = PCap.setTimeout?(handle, 200)
        _ = PCap.setImmediate?(handle, 1)
        let status = activate(handle)
        if status < 0 {
            let text = PCap.geterr?(handle).map { String(cString: $0) } ?? "error \(status)"
            close(handle)
            throw text.contains("ermission") ? LowtideError.denied("This user can't read the capture devices (/dev/bpf*).")
                : LowtideError.commandFailed(text)
        }
        stopFlag.store(false, ordering: .relaxed)
        running.store(true, ordering: .relaxed)
        // The handle never leaves this thread.
        let box = HandleBox(handle)
        let thread = Thread { [self] in
            self.loop(box.handle, onPacket: onPacket)
            close(box.handle)
            self.running.store(false, ordering: .relaxed)
        }
        thread.name = "net-capture"
        thread.qualityOfService = .utility
        thread.start()
    }

    func stop() { stopFlag.store(true, ordering: .relaxed) }

    private func loop(_ handle: PCap.Handle, onPacket: @Sendable (Packet) -> Void) {
        guard let next = PCap.nextEx else { return }
        let link = PCap.datalink?(handle) ?? 1
        var lastStats = Date()
        var header: PCap.Raw?
        var data: UnsafePointer<UInt8>?
        while !stopFlag.load(ordering: .relaxed) {
            let result = next(handle, &header, &data)
            if result == 1, let header, let data {
                let h = PCap.header(header)
                onPacket(Packet(t: h.t, length: h.length, link: link, bytes: Array(UnsafeBufferPointer(start: data, count: h.caplen))))
            } else if result < 0 {
                let text = PCap.geterr?(handle).map { String(cString: $0) } ?? "capture stopped"
                stats.withLock { $0.error = text }
                return
            }
            if Date().timeIntervalSince(lastStats) >= 1, let read = PCap.stats {
                lastStats = Date()
                var stat = [UInt32](repeating: 0, count: 4)
                if read(handle, &stat) == 0 {
                    stats.withLock { $0.received = Int(stat[0]); $0.dropped = Int(stat[1]) }
                }
            }
        }
    }

    /// The pcap handle, handed to the capture thread once and used only there.
    private final class HandleBox: @unchecked Sendable {
        let handle: PCap.Handle
        init(_ handle: PCap.Handle) { self.handle = handle }
    }
}

/// Read access to the capture devices.
public enum CaptureAccess {
    /// `/dev/bpf*` is readable by this user.
    public static var permitted: Bool {
        let fd = open("/dev/bpf0", O_RDONLY)
        if fd >= 0 { Darwin.close(fd); return true }
        // Busy means it exists and we may open it; another device is free.
        return errno == EBUSY
    }

    /// The group Wireshark's ChmodBPF uses for the same thing.
    public static let group = "access_bpf"

    /// Opens the capture devices to this user until the next restart. As
    /// ChmodBPF does, the `access_bpf` group may read them; the group is made
    /// when this Mac has none (no Wireshark), with this user in it. The user
    /// also owns them, so capture starts at once rather than once macOS
    /// refreshes the user's groups. Run through `Admin.run` (one password
    /// prompt). Nil for a user name that isn't safe in a command.
    public static func allowCommand(user: String) -> String? {
        guard Paths.safeID(user) != nil else { return nil }
        return "/usr/bin/dscl . -read /Groups/\(group) >/dev/null 2>&1 || /usr/sbin/dseditgroup -o create -r 'Packet capture' \(group); "
            + "/usr/sbin/dseditgroup -o edit -a \(user) -t user \(group); "
            + "/usr/sbin/chown \(user):\(group) /dev/bpf* && /bin/chmod 0640 /dev/bpf*"
    }
}
